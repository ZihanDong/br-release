#!/usr/bin/env bash
# Install kubeadm, kubelet, kubectl for Kylin V10/V11 (yum/dnf based).
# Handles both the legacy (≤1.27) and new (≥1.28) Kubernetes yum repo layout.

set -euo pipefail
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ── Repo helpers ──────────────────────────────────────────────────────────────

# New repo layout (k8s ≥ 1.28): pkgs.k8s.io provides RPM packages
_add_repo_new_yum() {
    local minor="$1"
    log_info "Adding Kubernetes yum repo (pkgs.k8s.io) for v${minor}..."

    local keyfile=/etc/pki/rpm-gpg/kubernetes-${minor}.gpg
    mkdir -p /etc/pki/rpm-gpg
    curl -fsSL --retry 3 --retry-delay 2 \
        "https://pkgs.k8s.io/core:/stable:/v${minor}/rpm/repodata/repomd.xml.key" \
        -o "${keyfile}" 2>/dev/null \
        || log_warn "Failed to download k8s GPG key, disabling gpgcheck."

    cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes ${minor}
baseurl=https://pkgs.k8s.io/core:/stable:/v${minor}/rpm/
enabled=1
gpgcheck=$(  [[ -f "${keyfile}" ]] && echo 1 || echo 0 )
gpgkey=file://${keyfile}
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
    yum makecache -q --disablerepo='*' --enablerepo=kubernetes 2>/dev/null \
        || log_warn "k8s repo cache refresh failed; continuing..."
}

# Legacy repo layout (k8s ≤ 1.27): use Aliyun mirror (Google is blocked in China)
_add_repo_legacy_yum() {
    log_info "Adding legacy Kubernetes yum repo (aliyun mirror)..."
    cat > /etc/yum.repos.d/kubernetes.repo <<'EOF'
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=0
repo_gpgcheck=0
exclude=kubelet kubeadm kubectl
EOF
    yum makecache -q --disablerepo='*' --enablerepo=kubernetes 2>/dev/null \
        || log_warn "k8s repo cache refresh failed; continuing..."
}

# ── Resolve the latest patch for a given minor version ───────────────────────
_latest_patch_version_yum() {
    local minor="$1"
    yum list available --showduplicates kubelet \
        --disableexcludes=kubernetes 2>/dev/null \
        | awk '{print $2}' \
        | grep "^${minor}\." \
        | sed 's/-[0-9]*$//' \
        | sort -V \
        | tail -1
}

# ── Install the three binaries ────────────────────────────────────────────────
_install_packages_yum() {
    local pkg_ver="$1"

    local kubelet kubectl kubeadm
    if [[ -n "${pkg_ver}" ]]; then
        kubelet="kubelet-${pkg_ver}"
        kubectl="kubectl-${pkg_ver}"
        kubeadm="kubeadm-${pkg_ver}"
    else
        kubelet="kubelet"
        kubectl="kubectl"
        kubeadm="kubeadm"
    fi

    log_info "Installing: ${kubelet} ${kubectl} ${kubeadm}"
    yum install -y --disableexcludes=kubernetes \
        "${kubelet}" "${kubectl}" "${kubeadm}"

    # Version lock using versionlock plugin (if available)
    if yum list installed python3-dnf-plugin-versionlock &>/dev/null \
       || yum list installed yum-plugin-versionlock &>/dev/null; then
        yum versionlock add kubelet kubeadm kubectl 2>/dev/null \
            || log_warn "versionlock failed; packages may be auto-upgraded."
    else
        log_warn "yum-plugin-versionlock not installed; packages not pinned."
    fi
    log_info "Packages installed."
}

# ── Configure kubelet cgroup driver ──────────────────────────────────────────
_configure_kubelet() {
    log_info "Configuring kubelet extra args..."
    mkdir -p /etc/systemd/system/kubelet.service.d
    cat > /etc/systemd/system/kubelet.service.d/10-kubeadm-extra.conf <<'EOF'
[Service]
Environment="KUBELET_EXTRA_ARGS=--container-runtime-endpoint=unix:///run/containerd/containerd.sock"
EOF
    systemctl daemon-reload
    systemctl enable kubelet
    log_info "kubelet configured."
}

# ── Public entry point ────────────────────────────────────────────────────────
# Expects K8S_VERSION exported by the caller (e.g. "1.28" or "1.28.5")
install_kubernetes() {
    local requested="${K8S_VERSION:-latest}"
    log_info "Requested Kubernetes version: ${requested}"

    local minor
    if [[ "${requested}" == "latest" ]]; then
        minor="1.30"
    else
        local norm; norm=$(normalise_version "${requested}")
        IFS='.' read -r maj min _ <<< "${norm}"
        minor="${maj}.${min}"
    fi

    version_gte "${minor}" "1.19" \
        || die "Kubernetes version must be ≥ 1.19 (requested: ${minor})"

    # If k8s tools are already installed at any version, skip package install.
    # Just ensure the kubelet drop-in config is present.
    if command_exists kubelet && command_exists kubeadm && command_exists kubectl; then
        local installed_minor
        installed_minor=$(kubelet --version 2>/dev/null \
            | grep -oE 'v[0-9]+\.[0-9]+' | head -1 | sed 's/^v//')
        if [[ -n "${installed_minor}" ]]; then
            log_info "Kubernetes already installed (v${installed_minor}), skipping package install."
            _configure_kubelet
            return
        fi
    fi

    # Choose repo layout
    if version_gte "${minor}" "1.28"; then
        _add_repo_new_yum "${minor}"
    else
        _add_repo_legacy_yum
    fi

    # Resolve exact package version
    local pkg_ver=""
    if [[ "${requested}" == "latest" ]]; then
        pkg_ver=$(_latest_patch_version_yum "${minor}")
        log_info "Latest available patch for ${minor}: ${pkg_ver:-<none, installing latest>}"
    else
        local norm; norm=$(normalise_version "${requested}")
        pkg_ver="${norm}"
    fi

    _install_packages_yum "${pkg_ver}"
    _configure_kubelet

    log_info "Kubernetes tools installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>&1 | head -1)"
}
