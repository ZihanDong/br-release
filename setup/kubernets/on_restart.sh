#!/bin/bash
# on_restart.sh — Run after system reboot to verify/recover k8s and registry.
#
# Typical usage (as root or via sudo):
#   sudo bash /home/zanedong/br-release/setup/kubernets/on_restart.sh
#
# What this script does:
#   1. Waits for the network to be ready with the expected IP.
#   2. Checks whether the k8s API server is reachable.
#   3. If the API server used a different IP than what's now active,
#      calls fix_reip.sh to update all certs/configs/manifests.
#   4. Restarts static-pod containers that might have loaded stale configs
#      (controller-manager, scheduler) by briefly removing their manifests.
#   5. Verifies the cluster is healthy and all critical pods are Running.
#   6. Verifies the private registry is accessible.
#   7. Syncs the invoking user's ~/.kube/config from admin.conf — after a
#      `kubeadm reset`+`init` (e.g. the 1.31 upgrade) the cluster CA is
#      regenerated, so a stale ~/.kube/config fails with
#      "x509: certificate signed by unknown authority". (k8s fix)
#   8. Reloads the Biren vGPU KMD 1.12.0 — `insmod` is transient and a reboot
#      reverts to the in-tree 1.11.0 (no vGPU ioctls), so reload it while the
#      card is idle. (KMD fix)
#
# NOTE: This script is idempotent — safe to run multiple times.

set -euo pipefail

KUBECONFIG_FILE="/etc/kubernetes/admin.conf"
MANIFESTS_DIR="/etc/kubernetes/manifests"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Path to the kernel-matched 1.12.0 KMD (built from source for this Kylin/kernel).
BIREN_KO="${BIREN_KO:-/home/br166/hami_br_deploy/kmd/kylin-x86_64-4.19.90/biren.ko}"
BIREN_KMD_WANT="1.12.0"

log() { echo "[on_restart] $(date '+%H:%M:%S') $*"; }

# ── 1. Determine current node IP ─────────────────────────────────────────────
log "Detecting primary node IP..."
# Try to get the IP of the interface that has the default route
CURRENT_IP="$(ip route get 8.8.8.8 2>/dev/null | awk '/src/{print $7; exit}' || true)"
if [[ -z "${CURRENT_IP}" ]]; then
    CURRENT_IP="$(hostname -I | awk '{print $1}')"
fi
log "Current IP: ${CURRENT_IP}"

# ── 2. Wait for network readiness ─────────────────────────────────────────────
log "Waiting for network interface to be up..."
for i in $(seq 1 30); do
    if ip addr | grep -q "${CURRENT_IP}"; then
        log "Network ready (${CURRENT_IP})"
        break
    fi
    [ "${i}" -eq 30 ] && { log "ERROR: network not ready after 30s"; exit 1; }
    sleep 1
done

# ── 3. Detect IP used by k8s and fix if needed ───────────────────────────────
K8S_IP="$(grep 'server:' "${KUBECONFIG_FILE}" 2>/dev/null | awk -F'[:/]+' '{print $3}' | head -1 || true)"
log "K8s configured IP: ${K8S_IP}, current IP: ${CURRENT_IP}"

if [[ "${K8S_IP}" != "${CURRENT_IP}" ]]; then
    log "IP mismatch detected! Running fix_reip.sh..."
    bash "${SCRIPT_DIR}/fix_reip.sh" "${K8S_IP}" "${CURRENT_IP}"
fi

# ── 4. Wait for API server ────────────────────────────────────────────────────
log "Waiting for API server at ${CURRENT_IP}:6443..."
export KUBECONFIG="${KUBECONFIG_FILE}"
for i in $(seq 1 60); do
    if kubectl get nodes &>/dev/null; then
        log "API server is up"
        break
    fi
    [ "${i}" -eq 60 ] && { log "ERROR: API server not reachable after 60s"; exit 1; }
    sleep 2
done

# ── 4b. Sync the invoking user's kubeconfig (k8s fix) ─────────────────────────
# After a kubeadm reset+init the cluster CA is new; a stale ~/.kube/config then
# fails TLS ("certificate signed by unknown authority"). Refresh it from the
# authoritative admin.conf for whoever invoked this (sudo) or the login user.
sync_user_kubeconfig() {
    local u home grp
    u="${SUDO_USER:-$(logname 2>/dev/null || echo root)}"
    home="$(getent passwd "$u" | cut -d: -f6)"
    [[ -z "${home}" || ! -f "${KUBECONFIG_FILE}" ]] && { log "skip kubeconfig sync (user/home/admin.conf missing)"; return 0; }
    grp="$(id -gn "$u" 2>/dev/null || echo "$u")"
    install -d -o "$u" -g "$grp" "${home}/.kube"
    install -m600 -o "$u" -g "$grp" "${KUBECONFIG_FILE}" "${home}/.kube/config"
    log "Synced ${home}/.kube/config from admin.conf (user=${u}) — kubectl works without sudo now"
}
sync_user_kubeconfig || log "WARNING: kubeconfig sync failed"

# ── 5. Restart static-pod containers that may have stale in-memory config ────
# controller-manager and scheduler read their kubeconfig once at startup.
# After an IP change + fix, they need a hard restart to pick up the new URL.
restart_static_pod() {
    local name="$1"
    local manifest="${MANIFESTS_DIR}/${name}.yaml"
    if [[ ! -f "${manifest}" ]]; then
        log "Manifest not found: ${manifest}, skipping"
        return
    fi

    # Check if the running pod is using the old IP
    local pod_log
    pod_log="$(kubectl logs -n kube-system "${name}-$(hostname)" --tail=5 2>/dev/null || true)"
    if echo "${pod_log}" | grep -q "${K8S_IP:-NONE}"; then
        log "Restarting ${name} (was using stale IP ${K8S_IP})..."
        mv "${manifest}" /tmp/"${name}-restart.yaml"
        sleep 5
        mv /tmp/"${name}-restart.yaml" "${manifest}"
        log "${name} restarted"
    else
        log "${name} is using correct IP, no restart needed"
    fi
}

if [[ "${K8S_IP}" != "${CURRENT_IP}" ]]; then
    restart_static_pod "kube-controller-manager"
    restart_static_pod "kube-scheduler"
fi

# ── 6. Update kube-proxy ConfigMap if needed ─────────────────────────────────
PROXY_SERVER="$(kubectl get cm kube-proxy -n kube-system -o jsonpath='{.data.kubeconfig\.conf}' 2>/dev/null \
    | grep 'server:' | awk '{print $2}' || true)"
if [[ "${PROXY_SERVER}" == *"${K8S_IP:-NONE}"* ]]; then
    log "Updating kube-proxy ConfigMap server URL..."
    kubectl get cm kube-proxy -n kube-system -o json | \
        python3 -c "
import json, sys
d = json.load(sys.stdin)
d['data']['kubeconfig.conf'] = d['data']['kubeconfig.conf'].replace(
    'https://${K8S_IP}:6443', 'https://${CURRENT_IP}:6443')
print(json.dumps(d))
" | kubectl apply -f -
    kubectl rollout restart ds/kube-proxy -n kube-system
fi

# ── 7. Wait for critical pods ─────────────────────────────────────────────────
log "Waiting for critical pods to be Running..."
CRITICAL_PODS=(
    "kube-system/etcd-$(hostname)"
    "kube-system/kube-apiserver-$(hostname)"
    "kube-system/kube-controller-manager-$(hostname)"
    "kube-system/kube-scheduler-$(hostname)"
)
for podref in "${CRITICAL_PODS[@]}"; do
    ns="${podref%%/*}"
    pod="${podref##*/}"
    for i in $(seq 1 30); do
        status="$(kubectl get pod "${pod}" -n "${ns}" -o jsonpath='{.status.phase}' 2>/dev/null || echo 'NotFound')"
        if [[ "${status}" == "Running" ]]; then
            log "  ${pod}: Running"
            break
        fi
        [ "${i}" -eq 30 ] && log "  WARNING: ${pod} not Running after 60s (status: ${status})"
        sleep 2
    done
done

# ── 8. Verify registry ────────────────────────────────────────────────────────
REGISTRY_PORT=32000
log "Checking registry at ${CURRENT_IP}:${REGISTRY_PORT}..."
if curl -sf "http://${CURRENT_IP}:${REGISTRY_PORT}/v2/_catalog" --max-time 5 &>/dev/null; then
    log "Registry is accessible"
else
    log "WARNING: registry not reachable at http://${CURRENT_IP}:${REGISTRY_PORT}"
    log "  Check: kubectl get pods -n kube-system | grep registry"
fi

# ── 8b. Reload the Biren vGPU KMD 1.12.0 (KMD fix) ───────────────────────────
# `insmod` is transient — a reboot reverts to the in-tree 1.11.0 driver (no vGPU
# ioctls -> br_vgpu_tool EINVAL, vGPU pods fail). Reload the kernel-matched
# 1.12.0 build while the card is idle (refcnt 0 right after boot).
reload_biren_kmd() {
    local cur refcnt
    cur="$(cat /sys/module/biren/version 2>/dev/null || echo none)"
    if [[ "${cur}" == "${BIREN_KMD_WANT}" ]]; then
        log "Biren KMD already ${BIREN_KMD_WANT}"; return 0
    fi
    if [[ ! -f "${BIREN_KO}" ]]; then
        log "WARNING: ${BIREN_KO} not found; skip KMD reload (vGPU will be unavailable)"; return 0
    fi
    refcnt="$(lsmod | awk '$1=="biren"{print $3}')"
    if [[ "${refcnt:-0}" != "0" ]]; then
        log "WARNING: biren in use (refcnt=${refcnt}); stop GPU workloads, then: sudo rmmod biren && sudo insmod ${BIREN_KO}"
        return 0
    fi
    log "Reloading Biren KMD ${cur} -> ${BIREN_KMD_WANT} (insmod ${BIREN_KO})..."
    rmmod biren 2>/dev/null || true
    if insmod "${BIREN_KO}"; then
        log "Biren KMD now $(cat /sys/module/biren/version 2>/dev/null)"
    else
        log "ERROR: insmod ${BIREN_KO} failed (vermagic mismatch? rebuild with build-kylin.sh)"
    fi
}
reload_biren_kmd || log "WARNING: KMD reload step failed"

# ── 9. Final summary ──────────────────────────────────────────────────────────
log "=== Cluster status ==="
kubectl get nodes -o wide 2>&1
log "=== Pod status ==="
kubectl get pods -A 2>&1 | grep -v Running || true

log "on_restart.sh complete."
