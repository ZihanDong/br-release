#!/bin/bash
# fix_worker_master_side.sh — Run ON the MASTER after fix_worker_reip.sh completes.
#
# Usage (on the master node):
#   bash fix_worker_master_side.sh <WORKER_HOSTNAME> <NEW_WORKER_IP>
#
# Example:
#   bash fix_worker_master_side.sh pj-3f-server002 10.50.36.200
#
# What this script does:
#   1. Waits for the worker's kubelet to reconnect and the node to become Ready.
#   2. Updates the flannel public-ip annotation on the node.
#   3. Force-restarts the flannel pod on the worker so it picks up the new IP.
#   4. Verifies the worker pods are Running.
set -euo pipefail

WORKER_NODE="${1:?Usage: $0 <WORKER_HOSTNAME> <NEW_WORKER_IP>}"
NEW_WORKER_IP="${2:?Usage: $0 <WORKER_HOSTNAME> <NEW_WORKER_IP>}"

log() { echo "[fix_worker_master] $(date '+%H:%M:%S') $*"; }

# ── 1. Wait for worker to reconnect ──────────────────────────────────────────
log "[1/4] Waiting for node ${WORKER_NODE} to become Ready ..."
for i in $(seq 1 60); do
    status="$(kubectl get node "${WORKER_NODE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo 'NotFound')"
    if [[ "${status}" == "True" ]]; then
        log "  node is Ready"
        break
    fi
    if [[ "${i}" -eq 60 ]]; then
        log "WARNING: node not Ready after 120s (status: ${status}). Proceeding anyway..."
    fi
    sleep 2
done

# ── 2. Update flannel public-ip annotation ────────────────────────────────────
log "[2/4] Updating flannel public-ip annotation → ${NEW_WORKER_IP} ..."
kubectl annotate node "${WORKER_NODE}" \
    "flannel.alpha.coreos.com/public-ip=${NEW_WORKER_IP}" --overwrite
log "  annotation updated"

# ── 3. Restart flannel pod on worker (picks up new public IP for VXLAN) ──────
log "[3/4] Restarting flannel pod on ${WORKER_NODE} ..."
FLANNEL_POD="$(kubectl get pods -n kube-flannel \
    --field-selector="spec.nodeName=${WORKER_NODE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ -n "${FLANNEL_POD}" ]]; then
    kubectl delete pod -n kube-flannel "${FLANNEL_POD}" --force 2>/dev/null || true
    log "  deleted ${FLANNEL_POD} (DaemonSet will recreate it)"
else
    log "  no flannel pod found on ${WORKER_NODE}, DaemonSet will create one"
fi

# ── 4. Verify ─────────────────────────────────────────────────────────────────
log "[4/4] Waiting for worker pods to stabilise (30s) ..."
sleep 30

echo ""
echo "=== Node status ==="
kubectl get nodes -o wide
echo ""
echo "=== Pods on ${WORKER_NODE} ==="
kubectl get pods -A --field-selector="spec.nodeName=${WORKER_NODE}" -o wide 2>/dev/null \
    || kubectl get pods -A -o wide | grep "${WORKER_NODE}"

echo ""
log "Done. If flannel or kube-proxy are still Pending, wait a minute and re-check."
