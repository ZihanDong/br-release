#!/bin/bash
# fix_worker_reip.sh — Run ON the worker node after master IP and/or worker IP changes.
#
# Usage (on the worker node):
#   sudo bash fix_worker_reip.sh <OLD_MASTER_IP> <NEW_MASTER_IP>
#
# Example:
#   sudo bash fix_worker_reip.sh 10.49.4.248 10.50.36.126
#
# What this script does (worker side):
#   1. Updates /etc/kubernetes/kubelet.conf to point at the new master IP.
#   2. Updates containerd registry trust config (certs.d).
#   3. Updates /etc/docker/daemon.json insecure-registries (if docker is present).
#   4. Restarts kubelet.
#   5. Prints the master-side commands that must be run after the worker reconnects.
#
# After running this script, SSH to the MASTER and run the printed commands
# (or use fix_worker_master_side.sh).
set -euo pipefail

OLD_MASTER_IP="${1:?Usage: $0 <OLD_MASTER_IP> <NEW_MASTER_IP>}"
NEW_MASTER_IP="${2:?Usage: $0 <OLD_MASTER_IP> <NEW_MASTER_IP>}"
OLD_REGISTRY="${OLD_MASTER_IP}:32000"
NEW_REGISTRY="${NEW_MASTER_IP}:32000"
KUBELET_CONF="/etc/kubernetes/kubelet.conf"

log() { echo "[fix_worker] $(date '+%H:%M:%S') $*"; }

# ── 1. Update kubelet.conf ────────────────────────────────────────────────────
log "[1/4] Updating kubelet.conf ..."
if [[ ! -f "${KUBELET_CONF}" ]]; then
    echo "ERROR: ${KUBELET_CONF} not found. Is this a k8s worker node?" >&2
    exit 1
fi

# Verify old IP is actually in the file
if ! grep -q "${OLD_MASTER_IP}" "${KUBELET_CONF}"; then
    log "WARNING: ${OLD_MASTER_IP} not found in ${KUBELET_CONF}"
    log "Current server line: $(grep 'server:' "${KUBELET_CONF}" || echo 'not found')"
    log "Continuing anyway..."
fi

cp "${KUBELET_CONF}" "${KUBELET_CONF}.bak.$(date +%Y%m%d%H%M%S)"
sed -i "s|https://${OLD_MASTER_IP}:6443|https://${NEW_MASTER_IP}:6443|g" "${KUBELET_CONF}"
log "  kubelet.conf updated: $(grep 'server:' "${KUBELET_CONF}")"

# ── 2. Update containerd registry trust ──────────────────────────────────────
log "[2/4] Updating containerd registry trust ..."
NEW_TRUST_DIR="/etc/containerd/certs.d/${NEW_REGISTRY}"
mkdir -p "${NEW_TRUST_DIR}"
cat > "${NEW_TRUST_DIR}/hosts.toml" <<EOF
server = "http://${NEW_REGISTRY}"

[host."http://${NEW_REGISTRY}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF
log "  wrote ${NEW_TRUST_DIR}/hosts.toml"

OLD_TRUST_DIR="/etc/containerd/certs.d/${OLD_REGISTRY}"
if [[ -d "${OLD_TRUST_DIR}" ]]; then
    rm -rf "${OLD_TRUST_DIR}"
    log "  removed old trust dir: ${OLD_TRUST_DIR}"
fi

# ── 3. Update docker daemon.json (optional) ──────────────────────────────────
log "[3/4] Updating docker daemon.json (if present) ..."
DOCKER_DAEMON="/etc/docker/daemon.json"
if [[ -f "${DOCKER_DAEMON}" ]]; then
    python3 - <<PYEOF
import json
with open("${DOCKER_DAEMON}") as f:
    d = json.load(f)
regs = d.get("insecure-registries", [])
changed = False
if "${OLD_REGISTRY}" in regs:
    regs.remove("${OLD_REGISTRY}")
    changed = True
if "${NEW_REGISTRY}" not in regs:
    regs.append("${NEW_REGISTRY}")
    changed = True
d["insecure-registries"] = regs
with open("${DOCKER_DAEMON}", "w") as f:
    json.dump(d, f, indent=2)
print("  docker daemon.json updated" if changed else "  docker daemon.json: no change needed")
PYEOF
else
    log "  docker not present, skipping"
fi

# ── 4. Restart kubelet ────────────────────────────────────────────────────────
log "[4/4] Restarting kubelet ..."
systemctl restart kubelet
log "  kubelet restarted"

# ── Detect current worker IP ──────────────────────────────────────────────────
WORKER_IP="$(ip route get 8.8.8.8 2>/dev/null | awk '/src/{print $7; exit}' || hostname -I | awk '{print $1}')"
WORKER_HOSTNAME="$(hostname)"

# ── Print master-side instructions ───────────────────────────────────────────
cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Worker-side fix complete. Now SSH to the MASTER node and run:

  bash fix_worker_master_side.sh ${WORKER_HOSTNAME} ${WORKER_IP}

or manually:

  # Wait for worker kubelet to reconnect (30–60s), then:
  kubectl annotate node ${WORKER_HOSTNAME} \\
      "flannel.alpha.coreos.com/public-ip=${WORKER_IP}" --overwrite

  # Verify
  kubectl get nodes -o wide
  kubectl get pods -A -o wide | grep ${WORKER_HOSTNAME}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
