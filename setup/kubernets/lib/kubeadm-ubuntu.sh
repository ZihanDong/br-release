#!/usr/bin/env bash
# Install kubeadm, kubelet, kubectl for the requested Kubernetes version.
# Handles both the legacy (≤1.27) and new (≥1.28) Kubernetes apt repo layout.

set -euo pipefail
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# ── Repo helpers ──────────────────────────────────────────────────────────────

# New repo layout (k8s ≥ 1.28): one repo per minor version
# https://pkgs.k8s.io/core:/stable:/v<MAJOR>.<MINOR>/deb/
_add_repo_new() {
    local minor="$1"   # e.g. "1.28"
    local arch; arch=$(dpkg --print-architecture)
    local keyring=/etc/apt/keyrings/kubernetes-apt-keyring.gpg

    log_info "Adding Kubernetes apt repo (pkgs.k8s.io) for v${minor}..."
    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL --retry 3 --retry-delay 2 \
        "https://pkgs.k8s.io/core:/stable:/v${minor}/deb/Release.key" \
        | gpg --batch --yes --dearmor -o "${keyring}"
    chmod a+r "${keyring}"

    echo "deb [signed-by=${keyring}] https://pkgs.k8s.io/core:/stable:/v${minor}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list

    # Only refresh the k8s repo — avoids failures from other broken apt sources
    # (stale mirrors, proxy-intercepted repos, etc.) in the environment.
    apt-get update -qq \
        -o Dir::Etc::sourcelist="sources.list.d/kubernetes.list" \
        -o Dir::Etc::sourceparts="-" \
        -o APT::Get::List-Cleanup="0" \
        2>&1 || {
        log_warn "k8s repo 刷新失败，尝试全量 apt-get update..."
        apt-get update -qq 2>&1 || log_warn "apt-get update 出现部分错误，继续..."
    }
}

# Legacy repo layout (k8s ≤ 1.27): packages.cloud.google.com
_add_repo_legacy() {
    local arch; arch=$(dpkg --print-architecture)
    local keyring=/etc/apt/keyrings/kubernetes-archive-keyring.gpg

    log_info "Adding legacy Kubernetes apt repo (packages.cloud.google.com)..."
    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL --retry 3 --retry-delay 2 \
        "https://packages.cloud.google.com/apt/doc/apt-key.gpg" \
        | gpg --batch --yes --dearmor -o "${keyring}"
    chmod a+r "${keyring}"

    echo "deb [signed-by=${keyring}] https://apt.kubernetes.io/ kubernetes-xenial main" \
        > /etc/apt/sources.list.d/kubernetes.list

    apt-get update -qq \
        -o Dir::Etc::sourcelist="sources.list.d/kubernetes.list" \
        -o Dir::Etc::sourceparts="-" \
        -o APT::Get::List-Cleanup="0" \
        2>&1 || {
        log_warn "k8s repo 刷新失败，尝试全量 apt-get update..."
        apt-get update -qq 2>&1 || log_warn "apt-get update 出现部分错误，继续..."
    }
}

# ── Resolve the latest patch for a given minor version ───────────────────────
_latest_patch_version() {
    local minor="$1"   # e.g. "1.28"
    # Query apt for the highest available patch in the pinned minor
    apt-cache madison kubelet 2>/dev/null \
        | awk -F'|' '{print $2}' \
        | tr -d ' ' \
        | grep -E "^${minor}\.[0-9]+" \
        | sort -V \
        | tail -1
}

# ── Install the three binaries ────────────────────────────────────────────────
_install_packages() {
    local pkg_ver="$1"   # full debian version string, e.g. "1.28.5-1.1" or ""

    local kubelet kubectl kubeadm
    if [[ -n "${pkg_ver}" ]]; then
        kubelet="kubelet=${pkg_ver}"
        kubectl="kubectl=${pkg_ver}"
        kubeadm="kubeadm=${pkg_ver}"
    else
        kubelet="kubelet"
        kubectl="kubectl"
        kubeadm="kubeadm"
    fi

    log_info "Installing: ${kubelet} ${kubectl} ${kubeadm}"
    apt_install "${kubelet}" "${kubectl}" "${kubeadm}"

    # Pin to prevent accidental upgrades
    apt-mark hold kubelet kubeadm kubectl
    log_info "Packages held at current version."
}

# ── Configure kubelet cgroup driver ──────────────────────────────────────────
_configure_kubelet() {
    log_info "Configuring kubelet extra args..."
    mkdir -p /etc/systemd/system/kubelet.service.d
    # Pass the cgroup driver; kubeadm will also write its own config but this
    # ensures the right driver is used even before kubeadm init.
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

    # Derive minor (x.y) from the requested version
    local minor
    if [[ "${requested}" == "latest" ]]; then
        # Default to the most recent stable minor supported by the new repo
        minor="1.30"
    else
        local norm; norm=$(normalise_version "${requested}")
        IFS='.' read -r maj min _ <<< "${norm}"
        minor="${maj}.${min}"
    fi

    version_gte "${minor}" "1.19" \
        || die "Kubernetes version must be ≥ 1.19 (requested: ${minor})"

    # Choose repo layout
    if version_gte "${minor}" "1.28"; then
        _add_repo_new "${minor}"
    else
        _add_repo_legacy
    fi

    # Resolve exact package version
    local pkg_ver=""
    if [[ "${requested}" == "latest" ]]; then
        pkg_ver=$(_latest_patch_version "${minor}")
        log_info "Latest available patch for ${minor}: ${pkg_ver:-<none, installing latest>}"
    else
        local norm; norm=$(normalise_version "${requested}")
        # apt package versions have the form <semver>-<rev>, e.g. 1.28.5-1.1
        # Try to find the closest match
        pkg_ver=$( apt-cache madison kubelet 2>/dev/null \
            | awk -F'|' '{print $2}' \
            | tr -d ' ' \
            | grep "^${norm}" \
            | sort -V | tail -1 )
        [[ -z "${pkg_ver}" ]] && log_warn "Exact version ${norm} not found; installing closest available."
    fi

    _install_packages "${pkg_ver}"
    _configure_kubelet

    log_info "Kubernetes tools installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>&1 | head -1)"
}
