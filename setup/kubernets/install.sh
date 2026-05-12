#!/usr/bin/env bash
# Kubernetes auto-installer — Ubuntu 20.04/22.04/24.04 and Kylin V10/V11
#
# Usage:
#   sudo ./install.sh [OPTIONS]
#
# Options / environment variables (all optional):
#   K8S_VERSION        Kubernetes version to install, e.g. "1.28" or "1.28.5"
#                      (default: 1.30, must be ≥ 1.19)
#   INIT_CLUSTER       Set to "true" to run kubeadm init/join after install
#   NODE_ROLE          "control-plane" (default) or "worker" (when INIT_CLUSTER=true)
#   JOIN_COMMAND       Full 'kubeadm join ...' string (required for worker nodes)
#   POD_CIDR           Pod network CIDR (default: 10.244.0.0/16)
#   SVC_CIDR           Service CIDR   (default: 10.96.0.0/12)
#   API_SERVER_ADDR    --apiserver-advertise-address for kubeadm init
#   REGISTRY_MIRROR    Alternative image registry (e.g. registry.aliyuncs.com/google_containers)
#   CONTAINERD_VERSION Pin a specific containerd.io version (default: latest)
#   CNI_PLUGIN         "flannel" (default), "calico", or "none"
#
# Examples:
#   # Install latest 1.30 (node only):
#   sudo ./install.sh
#
#   # Install 1.28, then init a control-plane with Calico CNI:
#   sudo K8S_VERSION=1.28 INIT_CLUSTER=true CNI_PLUGIN=calico ./install.sh
#
#   # Install 1.28 on a worker and join an existing cluster:
#   sudo K8S_VERSION=1.28 INIT_CLUSTER=true NODE_ROLE=worker \
#        JOIN_COMMAND="kubeadm join 192.168.1.10:6443 --token abc.xyz \
#          --discovery-token-ca-cert-hash sha256:..." \
#        ./install.sh
#
#   # Air-gapped / China mainland — use Aliyun mirror:
#   sudo K8S_VERSION=1.28 REGISTRY_MIRROR=registry.aliyuncs.com/google_containers \
#        ./install.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# ── Source libraries ──────────────────────────────────────────────────────────
# shellcheck source=./lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=./lib/preflight.sh
source "${LIB_DIR}/preflight.sh"
# shellcheck source=./lib/container_runtime.sh
source "${LIB_DIR}/container_runtime.sh"
# shellcheck source=./lib/kubeadm.sh
source "${LIB_DIR}/kubeadm.sh"
# shellcheck source=./lib/init_cluster.sh
source "${LIB_DIR}/init_cluster.sh"

# ── Defaults ──────────────────────────────────────────────────────────────────
: "${K8S_VERSION:=1.30}"
: "${INIT_CLUSTER:=false}"
: "${NODE_ROLE:=control-plane}"
: "${POD_CIDR:=10.244.0.0/16}"
: "${SVC_CIDR:=10.96.0.0/12}"
: "${CNI_PLUGIN:=flannel}"
: "${REGISTRY_MIRROR:=}"
: "${CONTAINERD_VERSION:=}"
: "${JOIN_COMMAND:=}"
: "${API_SERVER_ADDR:=}"

export K8S_VERSION INIT_CLUSTER NODE_ROLE POD_CIDR SVC_CIDR CNI_PLUGIN \
       REGISTRY_MIRROR CONTAINERD_VERSION JOIN_COMMAND API_SERVER_ADDR

# ── Banner ────────────────────────────────────────────────────────────────────
print_banner() {
    cat <<EOF

  K8S_VERSION    : ${K8S_VERSION}
  INIT_CLUSTER   : ${INIT_CLUSTER}
  NODE_ROLE      : ${NODE_ROLE}
  CNI_PLUGIN     : ${CNI_PLUGIN}
  REGISTRY_MIRROR: ${REGISTRY_MIRROR:-<none>}

EOF
}

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
    sed -n 's/^# //p' "$0" | head -40
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)  usage ;;
        --version)  echo "Kubernetes installer — K8S_VERSION=${K8S_VERSION}"; exit 0 ;;
        *) die "Unknown option: $1 (use --help for usage)" ;;
    esac
    shift
done

# ── Pre-run validation ────────────────────────────────────────────────────────
validate_args() {
    version_gte "${K8S_VERSION}" "1.19" \
        || die "K8S_VERSION must be ≥ 1.19 (got: ${K8S_VERSION})"

    if [[ "${INIT_CLUSTER}" == "true" && "${NODE_ROLE}" == "worker" && -z "${JOIN_COMMAND}" ]]; then
        die "JOIN_COMMAND must be set when NODE_ROLE=worker and INIT_CLUSTER=true"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    require_root
    detect_os
    print_banner
    validate_args

    log_info "=== Step 1/4: Preflight ==="
    run_preflight

    log_info "=== Step 2/4: Container runtime ==="
    install_container_runtime

    log_info "=== Step 3/4: Kubernetes packages ==="
    install_kubernetes

    log_info "=== Step 4/4: Cluster init ==="
    init_cluster

    echo
    log_info "============================================================"
    log_info "Installation complete!"
    log_info "  kubelet  : $(kubelet --version 2>/dev/null)"
    log_info "  kubeadm  : $(kubeadm version -o short 2>/dev/null)"
    log_info "  kubectl  : $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>&1 | head -1)"
    if [[ "${INIT_CLUSTER}" != "true" ]]; then
        log_info ""
        log_info "Next steps:"
        log_info "  Control-plane : sudo kubeadm init [options]"
        log_info "  Worker node   : sudo kubeadm join <endpoint> --token ... --discovery-token-ca-cert-hash ..."
        log_info "  Or re-run with INIT_CLUSTER=true to let this script bootstrap the cluster."
    fi
    log_info "============================================================"
}

main "$@"
