#!/usr/bin/env bash
# Install and configure containerd as the container runtime (Kylin / RPM-based).
# Supports Kylin V10/V11 (amd64 / arm64).
# Handles both containerd v1.x and v2.x config formats.

set -euo pipefail
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

CONTAINERD_VERSION="${CONTAINERD_VERSION:-}"
CONTAINERD_CONFIG=/etc/containerd/config.toml
_CONTAINERD_SVC=/usr/lib/systemd/system/containerd.service

# ── Detect containerd major version (robust, handles v1 hash suffix) ──────────
_containerd_major_version() {
    containerd --version 2>/dev/null \
        | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1 \
        | sed 's/^v//' \
        | cut -d. -f1
}

# ── Architecture ──────────────────────────────────────────────────────────────
_arch() {
    uname -m   # x86_64 or aarch64
}

# ── Resolve the correct pause image version ───────────────────────────────────
_pause_image() {
    local pause_ver="3.9"
    if [[ -n "${K8S_VERSION:-}" ]]; then
        if   version_gte "${K8S_VERSION}" "1.27"; then pause_ver="3.9"
        elif version_gte "${K8S_VERSION}" "1.25"; then pause_ver="3.8"
        elif version_gte "${K8S_VERSION}" "1.24"; then pause_ver="3.7"
        elif version_gte "${K8S_VERSION}" "1.22"; then pause_ver="3.6"
        else                                           pause_ver="3.5"
        fi
    fi
    local base="registry.k8s.io"
    [[ -n "${REGISTRY_MIRROR:-}" ]] && base="${REGISTRY_MIRROR}"
    echo "${base}/pause:${pause_ver}"
}

# ── Create containerd systemd service file if missing ────────────────────────
# On Kylin, containerd may be installed as a standalone binary without a
# systemd unit file (e.g. extracted from the GitHub release tarball).
_write_service_file() {
    [[ -f "${_CONTAINERD_SVC}" ]] && return 0
    log_info "Creating containerd systemd service file: ${_CONTAINERD_SVC}"
    cat > "${_CONTAINERD_SVC}" <<'EOF'
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/bin/containerd
Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=1048576
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    log_info "containerd service file created."
}

# ── Install containerd from Docker CE yum repo ────────────────────────────────
_install_containerd_docker_repo_yum() {
    log_info "Adding Docker CE yum repository for containerd..."
    # Ensure yum-utils is available for yum-config-manager
    command_exists yum-config-manager || yum_install yum-utils

    yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

    local pkg="containerd.io"
    [[ -n "${CONTAINERD_VERSION}" ]] && pkg="containerd.io-${CONTAINERD_VERSION}"
    yum_install "${pkg}"
}

# ── Install containerd from distro repo (fallback) ────────────────────────────
_install_containerd_distro_repo_yum() {
    log_info "Installing containerd from distro repository (yum)..."
    yum_install containerd
}

# ── Fix containerd running in Docker mode (disabled_plugins = ["cri"]) ────────
_fix_docker_mode_config() {
    local cfg="${CONTAINERD_CONFIG}"
    grep -qE '^\s*disabled_plugins\s*=.*"cri"' "${cfg}" 2>/dev/null || return 0
    log_warn "检测到 containerd 以 Docker 模式运行（disabled_plugins 包含 \"cri\"）。"
    log_warn "  k8s 需要 CRI 插件，正在重新生成 containerd 配置..."
    cp -p "${cfg}" "${cfg}.docker-bak.$(date +%s)"
    containerd config default > "${cfg}"
    log_info "containerd 配置已重新生成（原配置备份为 ${cfg}.docker-bak.*）。"
}

# ── Patch an existing config in-place (preserves custom runtimes) ─────────────
_patch_existing_config() {
    local cfg="${CONTAINERD_CONFIG}"
    local pause_image; pause_image=$(_pause_image)
    local ctrd_major; ctrd_major=$(_containerd_major_version)

    log_info "Patching existing containerd config (preserving custom runtimes)..."
    _fix_docker_mode_config
    cp -p "${cfg}" "${cfg}.bak.$(date +%s)"

    if [[ "${ctrd_major:-1}" -ge 2 ]]; then
        awk '
            /^\[plugins\."io\.containerd\.cri\.v1\.runtime"/ { in_new_cri=1 }
            /^\[plugins\."io\.containerd\./ && !/io\.containerd\.cri\.v1\.runtime/ { in_new_cri=0 }
            in_new_cri && /SystemdCgroup = false/ { sub(/SystemdCgroup = false/, "SystemdCgroup = true") }
            { print }
        ' "${cfg}" > "${cfg}.tmp" && mv "${cfg}.tmp" "${cfg}"
        sed -i "s|sandbox = \"registry\.k8s\.io/pause:.*\"|sandbox = \"${pause_image}\"|g" "${cfg}"
        sed -i "s|sandbox_image = .*|sandbox_image = \"${pause_image}\"|g" "${cfg}"
    else
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "${cfg}"
        sed -i "s|sandbox_image = .*|sandbox_image = \"${pause_image}\"|g" "${cfg}"
    fi

    # Enable certs.d so registry trust (hosts.toml) files are actually read.
    # containerd ships with config_path = "" which silently ignores certs.d/.
    sed -i 's|config_path\s*=\s*""|config_path = "/etc/containerd/certs.d"|g' "${cfg}"
    mkdir -p /etc/containerd/certs.d

    log_info "Config patched: ${cfg}  (backup saved as ${cfg}.bak.*)"
}

# ── Generate a fresh config for a newly-installed containerd ──────────────────
_write_fresh_config() {
    local pause_image; pause_image=$(_pause_image)

    log_info "Writing fresh containerd config (SystemdCgroup=true)..."
    mkdir -p /etc/containerd
    containerd config default > "${CONTAINERD_CONFIG}"

    local ctrd_major; ctrd_major=$(_containerd_major_version)
    if [[ "${ctrd_major:-1}" -ge 2 ]]; then
        awk '
            /^\[plugins\."io\.containerd\.cri\.v1\.runtime"/ { in_new_cri=1 }
            /^\[plugins\."io\.containerd\./ && !/io\.containerd\.cri\.v1\.runtime/ { in_new_cri=0 }
            in_new_cri && /SystemdCgroup = false/ { sub(/SystemdCgroup = false/, "SystemdCgroup = true") }
            { print }
        ' "${CONTAINERD_CONFIG}" > "${CONTAINERD_CONFIG}.tmp" \
            && mv "${CONTAINERD_CONFIG}.tmp" "${CONTAINERD_CONFIG}"
        sed -i "s|sandbox = \"registry\.k8s\.io/pause:.*\"|sandbox = \"${pause_image}\"|g" "${CONTAINERD_CONFIG}"
        sed -i "s|sandbox_image = .*|sandbox_image = \"${pause_image}\"|g" "${CONTAINERD_CONFIG}"
    else
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "${CONTAINERD_CONFIG}"
        sed -i "s|sandbox_image = .*|sandbox_image = \"${pause_image}\"|" "${CONTAINERD_CONFIG}"
    fi

    # Enable certs.d so registry trust (hosts.toml) files are actually read.
    sed -i 's|config_path\s*=\s*""|config_path = "/etc/containerd/certs.d"|g' "${CONTAINERD_CONFIG}"
    mkdir -p /etc/containerd/certs.d

    log_info "containerd config written: ${CONTAINERD_CONFIG}"
}

# ── Registry mirror (optional) ────────────────────────────────────────────────
_configure_registry_mirror() {
    [[ -z "${REGISTRY_MIRROR:-}" ]] && return
    log_info "Configuring registry mirror: ${REGISTRY_MIRROR}"
    local mirror_dir="/etc/containerd/certs.d/registry.k8s.io"
    mkdir -p "${mirror_dir}"
    cat > "${mirror_dir}/hosts.toml" <<EOF
server = "https://registry.k8s.io"

[host."${REGISTRY_MIRROR}"]
  capabilities = ["pull", "resolve"]
EOF
    log_info "Registry mirror configured."
}

# ── Start & enable ────────────────────────────────────────────────────────────
_enable_containerd() {
    _write_service_file
    systemctl daemon-reload
    systemctl enable --now containerd
    log_info "containerd service enabled and started."
}

# ── Public entry point ────────────────────────────────────────────────────────
install_container_runtime() {
    if command_exists containerd; then
        local ver; ver=$(containerd --version 2>&1 | head -1)
        log_info "containerd already installed (${ver}); ensuring service and config..."
        _write_service_file
        if [[ ! -f "${CONTAINERD_CONFIG}" ]]; then
            mkdir -p /etc/containerd
            containerd config default > "${CONTAINERD_CONFIG}"
            _write_fresh_config
        else
            _patch_existing_config
        fi
        _configure_registry_mirror
        _enable_containerd
        return
    fi

    # Not installed — try Docker CE yum repo first
    if _install_containerd_docker_repo_yum 2>/dev/null; then
        log_info "containerd installed from Docker CE repository."
    else
        log_warn "Docker CE repository unavailable; falling back to distro repo."
        _install_containerd_distro_repo_yum
    fi

    _write_service_file
    _write_fresh_config
    _configure_registry_mirror
    _enable_containerd
    log_info "Container runtime (containerd) ready."
}
