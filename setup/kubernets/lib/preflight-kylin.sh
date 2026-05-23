#!/usr/bin/env bash
# Preflight for Kylin V10/V11 (yum/dnf based, RPM distro).
# Drop-in replacement for preflight-ubuntu.sh on Kylin systems.

set -euo pipefail
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ── Swap ──────────────────────────────────────────────────────────────────────
disable_swap() {
    log_info "Disabling swap..."
    swapoff -a
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
# Kylin uses firewalld instead of ufw.
configure_firewall() {
    if command_exists firewall-cmd && firewall-cmd --state 2>/dev/null | grep -q "running"; then
        log_info "Configuring firewalld rules for Kubernetes..."
        local tcp_ports=(6443 2379 2380 10250 10251 10252 10255)
        for p in "${tcp_ports[@]}"; do
            firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null
        done
        firewall-cmd --permanent --add-port=30000-32767/tcp >/dev/null
        firewall-cmd --reload >/dev/null
        log_info "firewalld rules applied."
    else
        log_info "firewalld not active — skipping firewall configuration."
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
# Package name differences from Ubuntu:
#   conntrack     -> conntrack-tools
#   nfs-common    -> nfs-utils (usually already installed)
#   apt-transport-https / gnupg / lsb-release -> not needed on yum-based systems
install_base_deps() {
    log_info "Installing base dependencies (yum)..."

    # Kylin V10: if /usr/bin/python3 points to a user-compiled Python (e.g. 3.10)
    # instead of system Python 3.7, dnf/yum silently breaks.  Detect and work around.
    local _yum="yum"
    if ! yum --version &>/dev/null 2>&1; then
        local sys_py3
        sys_py3=$(ls /usr/bin/python3.{7,8,9} 2>/dev/null | head -1)
        if [[ -n "${sys_py3}" ]]; then
            log_warn "yum/dnf non-functional (python3 symlink points to wrong version)."
            log_warn "Retrying with system python: ${sys_py3}"
            _yum="${sys_py3} /usr/bin/dnf"
        fi
    fi

    # Non-fatal: some packages may already be installed or unavailable in limited repos.
    ${_yum} install -y socat conntrack-tools ipset ipvsadm nfs-utils containernetworking-plugins 2>&1 \
        || log_warn "Some base packages failed to install; continuing..."
    log_info "Base dependencies installed."
}

# ── CNI plugin binaries ────────────────────────────────────────────────────────
# On Kylin, containernetworking-plugins installs to /usr/libexec/cni/ but
# k8s/flannel expects binaries in /opt/cni/bin/. Copy them over.
install_cni_plugins() {
    local src_dir="/usr/libexec/cni"
    local dst_dir="/opt/cni/bin"
    if [[ ! -d "${src_dir}" ]]; then
        log_warn "CNI plugin source dir not found: ${src_dir} — skipping copy."
        return
    fi
    mkdir -p "${dst_dir}"
    log_info "Copying CNI plugins: ${src_dir} → ${dst_dir}"
    cp -a "${src_dir}/." "${dst_dir}/"
    log_info "CNI plugins installed to ${dst_dir}."
}

# ── IPVS ──────────────────────────────────────────────────────────────────────
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
    install_cni_plugins
    configure_firewall
    configure_hostname
    log_info "Preflight checks complete."
}
