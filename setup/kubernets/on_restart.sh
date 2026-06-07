#!/bin/bash
# on_restart.sh — post-reboot recovery for k8s + Biren GPU on this cluster.
#
# Works on BOTH control-plane and worker nodes:
#   * Worker (no /etc/kubernetes/admin.conf): node-local recovery only —
#     reload the transient 1.12.0 Biren vGPU KMD (`insmod` reverts to the in-tree
#     1.11.0 on reboot, which has no vGPU ioctls -> br_vgpu_tool EINVAL).
#   * Control-plane (admin.conf present): the above, plus k8s recovery —
#       - re-IP via fix_reip.sh if the node IP changed,
#       - restart stale static pods (controller-manager, scheduler),
#       - fix the kube-proxy ConfigMap server URL,
#       - sync the invoking user's ~/.kube/config from admin.conf (after a
#         `kubeadm reset`+`init` the cluster CA is regenerated, so a stale
#         ~/.kube/config fails with "x509: certificate signed by unknown
#         authority"),
#       - verify critical pods + the private registry.
#
# Usage (as root / sudo):  sudo bash .../on_restart.sh   [BIREN_KO=/path/biren.ko]
# Idempotent — safe to run multiple times.

set -euo pipefail

KUBECONFIG_FILE="/etc/kubernetes/admin.conf"
MANIFESTS_DIR="/etc/kubernetes/manifests"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Path to the kernel-matched 1.12.0 KMD (built from source for this Kylin/kernel).
BIREN_KO="${BIREN_KO:-/home/br166/hami_br_deploy/kmd/kylin-x86_64-4.19.90/biren.ko}"
BIREN_KMD_WANT="1.12.0"

log() { echo "[on_restart] $(date '+%H:%M:%S') $*"; }

# ── Node-local: reload the Biren vGPU KMD 1.12.0 (KMD fix) ────────────────────
# `insmod` is transient — a reboot reverts to the in-tree 1.11.0 driver (no vGPU
# ioctls -> br_vgpu_tool EINVAL, vGPU pods fail). Reload the kernel-matched
# 1.12.0 build while the card is idle (refcnt 0 right after boot). Whole-card and
# SVI work on 1.11.0 too; only vGPU soft-partition needs 1.12.0.
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
        log "Biren KMD now $(cat /sys/module/biren/version 2>/dev/null); $(/usr/local/bin/br_vgpu_tool status --dbdf 0 2>&1 | head -1)"
    else
        log "ERROR: insmod ${BIREN_KO} failed (vermagic mismatch? rebuild with build-kylin.sh)"
    fi
}

# ── 1. Determine current node IP ─────────────────────────────────────────────
log "Detecting primary node IP..."
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

# ── Worker node? (no admin.conf) → node-local recovery only, then done ────────
if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
    log "Worker node (no ${KUBECONFIG_FILE}) — node-local recovery only (KMD)."
    reload_biren_kmd || log "WARNING: KMD reload step failed"
    log "on_restart.sh (worker) complete."
    exit 0
fi

# ════════════════════════ Control-plane recovery ═════════════════════════════
# ── 3. Detect IP used by k8s and fix if needed ───────────────────────────────
K8S_IP="$(grep 'server:' "${KUBECONFIG_FILE}" 2>/dev/null | awk -F'[:/]+' '{print $3}' | head -1 || true)"
log "K8s configured IP: ${K8S_IP}, current IP: ${CURRENT_IP}"

if [[ -n "${K8S_IP}" && "${K8S_IP}" != "${CURRENT_IP}" ]]; then
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
restart_static_pod() {
    local name="$1"
    local manifest="${MANIFESTS_DIR}/${name}.yaml"
    if [[ ! -f "${manifest}" ]]; then
        log "Manifest not found: ${manifest}, skipping"
        return
    fi
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

if [[ -n "${K8S_IP}" && "${K8S_IP}" != "${CURRENT_IP}" ]]; then
    restart_static_pod "kube-controller-manager"
    restart_static_pod "kube-scheduler"
fi

# ── 6. Update kube-proxy ConfigMap if needed (only on a real IP change) ──────
if [[ -n "${K8S_IP}" && "${K8S_IP}" != "${CURRENT_IP}" ]]; then
    PROXY_SERVER="$(kubectl get cm kube-proxy -n kube-system -o jsonpath='{.data.kubeconfig\.conf}' 2>/dev/null \
        | grep 'server:' | awk '{print $2}' || true)"
    if [[ "${PROXY_SERVER}" == *"${K8S_IP}"* ]]; then
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
fi

# ── 8b. Reload the Biren vGPU KMD 1.12.0 (KMD fix) ───────────────────────────
reload_biren_kmd || log "WARNING: KMD reload step failed"

# ── 9. Final summary ──────────────────────────────────────────────────────────
log "=== Cluster status ==="
kubectl get nodes -o wide 2>&1
log "=== Pod status (non-Running) ==="
kubectl get pods -A 2>&1 | grep -v Running || true

log "on_restart.sh complete."
