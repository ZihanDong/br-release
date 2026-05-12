#!/usr/bin/env bash
# Preflight: disable swap, load kernel modules, apply sysctl, install base deps.

set -euo pipefail
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ── Swap ──────────────────────────────────────────────────────────────────────
disable_swap() {
    log_info "Disabling swap..."
    swapoff -a
    # Remove swap entries from fstab permanently
    sed -i.bak '/\bswap\b/d' /etc/fstab
    log_info "Swap disabled."
}

# ── Kernel modules ────────────────────────────────────────────────────────────
load_kernel_modules() {
    log_info "Loading required kernel modules..."
    local modules=(overlay br_netfilter)
    for mod in "${modules[@]}"; do
        modprobe "$mod" || log_warn "modprobe $mod failed (may already be built-in)"
    done

    cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
    log_info "Kernel modules configured."
}

# ── sysctl ────────────────────────────────────────────────────────────────────
configure_sysctl() {
    log_info "Applying sysctl settings for Kubernetes..."
    cat > /etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    sysctl --system >/dev/null
    log_info "sysctl settings applied."
}

# ── Firewall ──────────────────────────────────────────────────────────────────
# Open the minimum ports required by kubeadm.  If ufw is inactive this is a
# no-op — the caller can manage firewall rules independently.
configure_firewall() {
    if command_exists ufw && ufw status | grep -q "Status: active"; then
        log_info "Configuring ufw rules for Kubernetes..."
        local ports=(
            "6443/tcp"   # API server
            "2379/tcp"   # etcd client
            "2380/tcp"   # etcd peer
            "10250/tcp"  # kubelet
            "10251/tcp"  # kube-scheduler
            "10252/tcp"  # kube-controller-manager
            "10255/tcp"  # kubelet read-only
            "30000:32767/tcp"  # NodePort range
        )
        for p in "${ports[@]}"; do
            ufw allow "$p" >/dev/null
        done
        log_info "ufw rules applied."
    else
        log_info "ufw not active — skipping firewall configuration."
    fi
}

# ── Hostname / hosts ──────────────────────────────────────────────────────────
configure_hostname() {
    local hostname
    hostname=$(hostname -s)
    if ! grep -q "127.0.0.1.*${hostname}" /etc/hosts 2>/dev/null; then
        echo "127.0.0.1 ${hostname}" >> /etc/hosts
        log_info "Added ${hostname} to /etc/hosts."
    fi
}

# ── Base packages ─────────────────────────────────────────────────────────────
install_base_deps() {
    log_info "Installing base dependencies..."
    apt-get update -qq
    apt_install \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release \
        socat \
        conntrack \
        ipset \
        ipvsadm \
        nfs-common
    log_info "Base dependencies installed."
}

# ── IPVS (optional but recommended for large clusters) ───────────────────────
configure_ipvs() {
    log_info "Loading IPVS kernel modules..."
    local mods=(ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack)
    for mod in "${mods[@]}"; do
        modprobe "$mod" 2>/dev/null || true
    done
    cat > /etc/modules-load.d/ipvs.conf <<'EOF'
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF
    log_info "IPVS modules configured."
}

run_preflight() {
    disable_swap
    load_kernel_modules
    configure_ipvs
    configure_sysctl
    install_base_deps
    configure_firewall
    configure_hostname
    log_info "Preflight checks complete."
}
