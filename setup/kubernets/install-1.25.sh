#!/usr/bin/env bash
# install-1.25.sh — the PRE-UPGRADE baseline this cluster ran before 2026-06-06.
#
# Versions captured from the running nodes (Kylin V10, kernel 4.19, cgroup v1):
#   Kubernetes : 1.25.3   (kubelet/kubeadm/kubectl, RPM)
#   containerd : 1.7.15   (static binary in /usr/bin)
#   Docker     : 26.1.3   (static binary in /usr/bin)
#   runc       : 1.1.12   (static binary)
#   pause      : 3.8      CNI: flannel
#
# This is the version-named record of the original install (the generic, still-present
# ./install.sh is parameterized; this wrapper pins the 1.25 baseline). The new target
# is ./install-1.31.sh (Kubernetes 1.31 + Docker 28.x + containerd 2.x).
#
# Usage (reproduce the 1.25 baseline via the generic installer):
#   sudo ROLE=control-plane ./install-1.25.sh
#   sudo ROLE=worker JOIN_COMMAND="kubeadm join ..." ./install-1.25.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export K8S_VERSION="${K8S_VERSION:-1.25.3}"
export CONTAINERD_VERSION="${CONTAINERD_VERSION:-1.7.15}"
export CNI_PLUGIN="${CNI_PLUGIN:-flannel}"
export REGISTRY_MIRROR="${REGISTRY_MIRROR:-registry.aliyuncs.com/google_containers}"

# Map ROLE -> the generic install.sh's INIT_CLUSTER/NODE_ROLE interface.
case "${ROLE:-}" in
  control-plane) export INIT_CLUSTER=true NODE_ROLE=control-plane ;;
  worker)        export INIT_CLUSTER=true NODE_ROLE=worker ;;
  *)             : ;;  # packages only
esac

echo "[install-1.25] reproducing baseline: k8s=${K8S_VERSION} containerd=${CONTAINERD_VERSION} (delegating to install.sh)"
exec "${SCRIPT_DIR}/install.sh" "$@"
