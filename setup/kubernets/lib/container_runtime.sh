#!/usr/bin/env bash
# Install and configure containerd as the container runtime.
# Supports Ubuntu 20.04/22.04/24.04 and Kylin V10/V11 (amd64 / arm64).
# Handles both containerd v1.x and v2.x config formats.

set -euo pipefail
# shellcheck source=./common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Minimum containerd version; anything in the apt repo satisfies k8s ≥ 1.19
CONTAINERD_VERSION="${CONTAINERD_VERSION:-}"   # empty = latest from repo
CONTAINERD_CONFIG=/etc/containerd/config.toml

# ── Architecture map ──────────────────────────────────────────────────────────
_arch() {
    local m; m=$(uname -m)
    case "$m" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *)       die "Unsupported architecture: $m" ;;
    esac
}

# ── containerd from Docker's apt repo ────────────────────────────────────────
_install_containerd_docker_repo() {
    local arch; arch=$(_arch)
    local keyring=/etc/apt/keyrings/docker.gpg

    log_info "Adding Docker apt repository for containerd..."
    install -m 0755 -d /etc/apt/keyrings

    # Download with retries; fall back to insecure only if explicitly set
    local curl_opts=(-fsSL --retry 3 --retry-delay 2)
    curl "${curl_opts[@]}" "https://download.docker.com/linux/${OS_ID}/gpg" \
        | gpg --batch --yes --dearmor -o "${keyring}"
    chmod a+r "${keyring}"

    local distro="${OS_ID}"
    # Kylin doesn't have its own Docker repo — use Ubuntu's
    [[ "${OS_ID}" == "kylin" ]] && distro="ubuntu"

    echo \
        "deb [arch=${arch} signed-by=${keyring}] https://download.docker.com/linux/${distro} ${OS_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq

    local pkg="containerd.io"
    [[ -n "${CONTAINERD_VERSION}" ]] && pkg="containerd.io=${CONTAINERD_VERSION}*"
    apt_install "$pkg"
}

# ── containerd from distro repo (fallback for air-gapped / Kylin official) ───
_install_containerd_distro_repo() {
    log_info "Installing containerd from distro repository..."
    apt-get update -qq
    apt_install containerd
}

# ── Detect containerd major version ──────────────────────────────────────────
_containerd_major_version() {
    # 输出示例: "containerd github.com/containerd/containerd/v2 2.2.1"
    # 取最后一个空格分隔字段（版本号），再取主版本号
    containerd --version 2>/dev/null \
        | awk '{print $NF}' \
        | cut -d. -f1
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

# ── Fix containerd running in Docker mode (disabled_plugins = ["cri"]) ────────
# When Docker installs containerd it writes a minimal config with CRI disabled.
# k8s requires CRI. Regenerate from scratch in that case — Docker's config has
# no custom runtimes worth preserving.
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
# Used when containerd is already installed (e.g. has vendor GPU runtime configs).
_patch_existing_config() {
    local cfg="${CONTAINERD_CONFIG}"
    local pause_image; pause_image=$(_pause_image)
    local ctrd_major; ctrd_major=$(_containerd_major_version)

    log_info "Patching existing containerd config (preserving custom runtimes)..."

    # Must run before backup so the backup reflects the fixed state
    _fix_docker_mode_config

    cp -p "${cfg}" "${cfg}.bak.$(date +%s)"

    if [[ "${ctrd_major}" -ge 2 ]]; then
        # containerd v2: CRI runtime plugin is io.containerd.cri.v1.runtime
        # Only set SystemdCgroup=true inside the runc.options block of that plugin.
        # We use awk to scope the replacement precisely.
        awk '
            /^\[plugins\."io\.containerd\.cri\.v1\.runtime"/ { in_new_cri=1 }
            /^\[plugins\."io\.containerd\.grpc\.v1\.cri"/ { in_new_cri=0 }
            in_new_cri && /SystemdCgroup = false/ { sub(/SystemdCgroup = false/, "SystemdCgroup = true") }
            { print }
        ' "${cfg}" > "${cfg}.tmp" && mv "${cfg}.tmp" "${cfg}"

        # Update sandbox image in the new CRI images plugin section
        # (field name: sandbox in pinned_images, or sandbox_image elsewhere)
        sed -i "s|sandbox = \"registry\.k8s\.io/pause:.*\"|sandbox = \"${pause_image}\"|g" "${cfg}"
        sed -i "s|sandbox_image = .*|sandbox_image = \"${pause_image}\"|g" "${cfg}"
    else
        # containerd v1: single CRI plugin io.containerd.grpc.v1.cri
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "${cfg}"
        sed -i "s|sandbox_image = .*|sandbox_image = \"${pause_image}\"|g" "${cfg}"
    fi

    log_info "Config patched: ${cfg}  (backup saved as ${cfg}.bak.*)"
}

# ── Generate a fresh config for a newly-installed containerd ──────────────────
_write_fresh_config() {
    local pause_image; pause_image=$(_pause_image)

    log_info "Writing fresh containerd config (SystemdCgroup=true)..."
    mkdir -p /etc/containerd
    containerd config default > "${CONTAINERD_CONFIG}"

    local ctrd_major; ctrd_major=$(_containerd_major_version)
    if [[ "${ctrd_major}" -ge 2 ]]; then
        # v2 default config has SystemdCgroup only in io.containerd.cri.v1.runtime
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

    log_info "containerd config written: ${CONTAINERD_CONFIG}"
}

# ── Registry mirror (optional) ────────────────────────────────────────────────
_configure_registry_mirror() {
    [[ -z "${REGISTRY_MIRROR:-}" ]] && return
    log_info "Configuring registry mirror: ${REGISTRY_MIRROR}"
    # containerd ≥ 1.5 uses /etc/containerd/certs.d/<host>/hosts.toml
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
    systemctl daemon-reload
    systemctl enable --now containerd
    log_info "containerd service enabled and started."
}

# ── Public entry point ────────────────────────────────────────────────────────
install_container_runtime() {
    if command_exists containerd; then
        local ver; ver=$(containerd --version 2>&1 | head -1)
        log_info "containerd already installed (${ver}); patching config in-place..."
        # Patch rather than overwrite — preserves vendor/GPU runtime entries
        [[ -f "${CONTAINERD_CONFIG}" ]] || containerd config default > "${CONTAINERD_CONFIG}"
        _patch_existing_config
        _configure_registry_mirror
        _enable_containerd
        return
    fi

    # Try Docker repo first; fall back to distro repo
    if _install_containerd_docker_repo 2>/dev/null; then
        log_info "containerd installed from Docker repository."
    else
        log_warn "Docker repository unavailable; falling back to distro repo."
        _install_containerd_distro_repo
    fi

    _write_fresh_config
    _configure_registry_mirror
    _enable_containerd
    log_info "Container runtime (containerd) ready."
}
