#!/usr/bin/env bash
# Optional cluster bootstrap via kubeadm init (control-plane) or join (worker).
# Only runs when INIT_CLUSTER=true is exported by the caller.

set -euo pipefail
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ── kubeadm init (control-plane) ──────────────────────────────────────────────
_kubeadm_init() {
    local pod_cidr="${POD_CIDR:-10.244.0.0/16}"
    local svc_cidr="${SVC_CIDR:-10.96.0.0/12}"
    local api_addr="${API_SERVER_ADDR:-}"           # advertise address (optional)
    local k8s_ver="${K8S_VERSION:-}"

    log_info "Pulling required control-plane images..."
    kubeadm config images pull \
        ${k8s_ver:+--kubernetes-version "${k8s_ver}"} \
        ${REGISTRY_MIRROR:+--image-repository "${REGISTRY_MIRROR}"} \
        2>&1 | tee /tmp/kubeadm-pull.log

    local init_args=(
        --pod-network-cidr="${pod_cidr}"
        --service-cidr="${svc_cidr}"
        --cri-socket=unix:///run/containerd/containerd.sock
    )
    [[ -n "${api_addr}"     ]] && init_args+=(--apiserver-advertise-address="${api_addr}")
    [[ -n "${k8s_ver}"      ]] && init_args+=(--kubernetes-version="${k8s_ver}")
    [[ -n "${REGISTRY_MIRROR:-}" ]] && init_args+=(--image-repository="${REGISTRY_MIRROR}")

    log_info "Running: kubeadm init ${init_args[*]}"
    kubeadm init "${init_args[@]}" 2>&1 | tee /tmp/kubeadm-init.log

    # Set up kubeconfig for the invoking user
    local home_dir
    if [[ -n "${SUDO_USER:-}" ]]; then
        home_dir=$(getent passwd "${SUDO_USER}" | cut -d: -f6)
        local kubeconf="${home_dir}/.kube"
        mkdir -p "${kubeconf}"
        cp /etc/kubernetes/admin.conf "${kubeconf}/config"
        chown -R "${SUDO_USER}:$(id -gn "${SUDO_USER}")" "${kubeconf}"
        log_info "kubeconfig written to ${kubeconf}/config (owner: ${SUDO_USER})"
    else
        mkdir -p "${HOME}/.kube"
        cp /etc/kubernetes/admin.conf "${HOME}/.kube/config"
        log_info "kubeconfig written to ${HOME}/.kube/config"
    fi

    # Install Flannel CNI (default) unless CNI_PLUGIN is set
    local cni="${CNI_PLUGIN:-flannel}"
    _install_cni "${cni}" "${pod_cidr}"

    log_info "Control-plane initialised."
    log_info "Join token command is in /tmp/kubeadm-init.log"
    grep -A2 "kubeadm join" /tmp/kubeadm-init.log | tail -3 || true
}

# ── CNI plugin installation ───────────────────────────────────────────────────
_install_cni() {
    local cni="$1" pod_cidr="$2"

    case "${cni}" in
        flannel)
            log_info "Installing Flannel CNI..."
            # Apply upstream manifest; will use the pod_cidr from kubeadm init
            kubectl apply \
                -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml \
                --kubeconfig /etc/kubernetes/admin.conf
            ;;
        calico)
            log_info "Installing Calico CNI..."
            kubectl apply \
                -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml \
                --kubeconfig /etc/kubernetes/admin.conf
            ;;
        none)
            log_warn "CNI_PLUGIN=none — skipping CNI installation. Install a CNI plugin manually."
            ;;
        *)
            log_warn "Unknown CNI_PLUGIN '${cni}' — skipping. Install a CNI plugin manually."
            ;;
    esac
}

# ── kubeadm join (worker) ─────────────────────────────────────────────────────
_kubeadm_join() {
    [[ -n "${JOIN_COMMAND:-}" ]] || die "JOIN_COMMAND must be set to join as a worker node."
    log_info "Joining cluster as worker node..."
    # JOIN_COMMAND should contain the full 'kubeadm join ...' string
    eval "${JOIN_COMMAND}" \
        --cri-socket=unix:///run/containerd/containerd.sock \
        2>&1 | tee /tmp/kubeadm-join.log
    log_info "Node joined the cluster."
}

# ── Public entry point ────────────────────────────────────────────────────────
init_cluster() {
    [[ "${INIT_CLUSTER:-false}" == "true" ]] || return 0

    local role="${NODE_ROLE:-control-plane}"
    case "${role}" in
        control-plane|master)
            _kubeadm_init ;;
        worker|node)
            _kubeadm_join ;;
        *)
            die "Unknown NODE_ROLE '${role}'. Use 'control-plane' or 'worker'." ;;
    esac
}
