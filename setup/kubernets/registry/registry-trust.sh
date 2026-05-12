#!/usr/bin/env bash
# Registry 信任配置管理脚本
# 将私有 Registry 的 containerd 信任配置注入到本机或远程节点
#
# 用法：
#   sudo ./registry-trust.sh apply   [--config FILE] [节点1,节点2,...]
#   sudo ./registry-trust.sh remove  [--config FILE] [节点1,节点2,...]
#   sudo ./registry-trust.sh list    [节点1,节点2,...]
#
# 子命令：
#   apply   将信任配置写入节点的 /etc/containerd/certs.d/<addr>/hosts.toml
#   remove  移除信任配置；未指定 --config 时先列出当前所有生效配置
#   list    列出节点上已生效的所有 Registry 信任配置
#
# 通用选项：
#   --config FILE    指定信任配置文件（默认自动查找同目录的 registry-trust.conf）
#   --ssh-user USER  SSH 登录用户（远程节点，默认 root）
#   --ssh-key  FILE  SSH 私钥路径（远程节点，默认使用系统默认密钥）
#
# 节点列表：逗号或空格分隔的主机名或 IP，不指定时仅操作本机
#
# 示例：
#   # 注入信任到本机
#   sudo ./registry-trust.sh apply
#
#   # 注入信任到远程节点
#   sudo ./registry-trust.sh apply worker01,worker02
#
#   # 指定 SSH 用户和密钥
#   sudo ./registry-trust.sh apply --ssh-user zanedong --ssh-key ~/.ssh/id_rsa worker01
#
#   # 查看本机所有生效的信任配置
#   ./registry-trust.sh list
#
#   # 查看远程节点的信任配置
#   ./registry-trust.sh list worker01
#
#   # 列出当前生效配置后退出（用于决定要移除哪个）
#   ./registry-trust.sh remove
#
#   # 移除指定信任配置
#   sudo ./registry-trust.sh remove --config registry-trust.conf
#
#   # 移除远程节点的信任配置
#   sudo ./registry-trust.sh remove --config registry-trust.conf worker01,worker02

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"
source "${LIB_DIR}/common.sh"

# ── 参数解析 ───────────────────────────────────────────────────────────────────
SUBCMD=""
TRUST_CONF=""
_CONFIG_EXPLICIT=false   # true = 用户通过 --config 显式指定
SSH_USER="root"
SSH_KEY=""
NODE_ARG=""

_usage() {
    echo "用法:"
    echo "  sudo $0 apply   [--config FILE] [节点,...]"
    echo "  sudo $0 remove  [--config FILE] [节点,...]"
    echo "       $0 list    [节点,...]"
    echo ""
    echo "  --config FILE    信任配置文件（默认: ${SCRIPT_DIR}/registry-trust.conf）"
    echo "  --ssh-user USER  SSH 用户（默认: root）"
    echo "  --ssh-key  FILE  SSH 私钥路径"
    exit 1
}

# 解析子命令
[[ $# -ge 1 ]] || _usage
case "$1" in
    apply|remove|list) SUBCMD="$1"; shift ;;
    *) _usage ;;
esac

# 解析剩余选项
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)    TRUST_CONF="$2"; _CONFIG_EXPLICIT=true; shift 2 ;;
        --ssh-user)  SSH_USER="$2";    shift 2 ;;
        --ssh-key)   SSH_KEY="$2";     shift 2 ;;
        --*)         log_warn "未知选项: $1"; shift ;;
        *)           NODE_ARG="$1";    shift   ;;
    esac
done

# ── 加载信任配置 ───────────────────────────────────────────────────────────────
TRUST_REGISTRY_ADDR=""
TRUST_HTTP="true"

load_trust_conf() {
    # 自动查找
    [[ -z "${TRUST_CONF}" ]] && TRUST_CONF="${SCRIPT_DIR}/registry-trust.conf"

    if [[ "${SUBCMD}" == "remove" && -z "${TRUST_CONF}" && ! -f "${SCRIPT_DIR}/registry-trust.conf" ]]; then
        return  # remove 无配置时走列出逻辑，不报错
    fi

    [[ -f "${TRUST_CONF}" ]] || die "信任配置文件不存在: ${TRUST_CONF}
请先执行 setup-registry.sh 或通过 --config 指定文件。"

    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# || -z "${line}" ]] && continue
        [[ "${line}" =~ ^([A-Z_]+)=(.*)$ ]] || continue
        case "${BASH_REMATCH[1]}" in
            TRUST_REGISTRY_ADDR) TRUST_REGISTRY_ADDR="${BASH_REMATCH[2]}" ;;
            TRUST_HTTP)          TRUST_HTTP="${BASH_REMATCH[2]}"           ;;
        esac
    done < "${TRUST_CONF}"

    [[ -n "${TRUST_REGISTRY_ADDR}" ]] \
        || die "信任配置文件中未找到 TRUST_REGISTRY_ADDR: ${TRUST_CONF}"
}

# ── 解析节点列表 ───────────────────────────────────────────────────────────────
_NODES=()

resolve_nodes() {
    if [[ -n "${NODE_ARG}" ]]; then
        IFS=', ' read -ra _NODES <<< "${NODE_ARG}"
    fi
    # 空列表 = 仅本机
}

# ── 生成 hosts.toml 内容 ───────────────────────────────────────────────────────
_hosts_toml_content() {
    local addr="$1" http="$2"
    local scheme; [[ "${http}" == "true" ]] && scheme="http" || scheme="https"
    cat <<EOF
server = "${scheme}://${addr}"

[host."${scheme}://${addr}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF
}

# ── 本机操作 ───────────────────────────────────────────────────────────────────
_local_apply() {
    local addr="$1" http="$2"
    require_root
    local trust_dir="/etc/containerd/certs.d/${addr}"
    mkdir -p "${trust_dir}"
    _hosts_toml_content "${addr}" "${http}" > "${trust_dir}/hosts.toml"
    log_info "  [本机] 信任配置已写入: ${trust_dir}/hosts.toml"
}

_local_remove() {
    local addr="$1"
    require_root
    local trust_dir="/etc/containerd/certs.d/${addr}"
    if [[ -d "${trust_dir}" ]]; then
        rm -rf "${trust_dir}"
        log_info "  [本机] 已移除信任配置: ${trust_dir}"
    else
        log_warn "  [本机] 未找到信任配置目录: ${trust_dir}，跳过。"
    fi
}

_local_list() {
    local certs_dir="/etc/containerd/certs.d"
    if [[ ! -d "${certs_dir}" ]]; then
        echo "  [本机] ${certs_dir} 不存在，无任何信任配置。"
        return
    fi
    local found=0
    while IFS= read -r -d '' htf; do
        local reg_addr; reg_addr=$(basename "$(dirname "${htf}")")
        echo "  ── ${reg_addr} ──"
        cat "${htf}" | sed 's/^/    /'
        found=1
    done < <(find "${certs_dir}" -name "hosts.toml" -print0 2>/dev/null | sort -z)
    if [[ $found -eq 0 ]]; then
        echo "  [本机] 无已配置的 Registry 信任。"
    fi
}

# ── 远程操作（SSH）────────────────────────────────────────────────────────────
_ssh_opts() {
    local opts=(-o StrictHostKeyChecking=no -o ConnectTimeout=10)
    [[ -n "${SSH_KEY}" ]] && opts+=(-i "${SSH_KEY}")
    echo "${opts[@]}"
}

_remote_apply() {
    local node="$1" addr="$2" http="$3"
    local ssh_opts; read -ra ssh_opts <<< "$(_ssh_opts)"
    local toml; toml=$(_hosts_toml_content "${addr}" "${http}")
    local trust_dir="/etc/containerd/certs.d/${addr}"

    if ssh "${ssh_opts[@]}" "${SSH_USER}@${node}" \
        "mkdir -p '${trust_dir}' && cat > '${trust_dir}/hosts.toml'" <<< "${toml}" 2>&1; then
        log_info "  [${node}] 信任配置已写入: ${trust_dir}/hosts.toml"
    else
        log_warn "  [${node}] 写入失败，请检查 SSH 连接和权限。"
    fi
}

_remote_remove() {
    local node="$1" addr="$2"
    local ssh_opts; read -ra ssh_opts <<< "$(_ssh_opts)"
    local trust_dir="/etc/containerd/certs.d/${addr}"

    if ssh "${ssh_opts[@]}" "${SSH_USER}@${node}" \
        "[ -d '${trust_dir}' ] && rm -rf '${trust_dir}' && echo removed || echo not_found" 2>/dev/null \
        | grep -q "removed"; then
        log_info "  [${node}] 已移除信任配置: ${trust_dir}"
    else
        log_warn "  [${node}] 未找到信任配置或连接失败: ${node}"
    fi
}

_remote_list() {
    local node="$1"
    local ssh_opts; read -ra ssh_opts <<< "$(_ssh_opts)"
    local certs_dir="/etc/containerd/certs.d"

    echo "  ── ${node} ──"
    ssh "${ssh_opts[@]}" "${SSH_USER}@${node}" \
        "find '${certs_dir}' -name 'hosts.toml' 2>/dev/null | sort | while read f; do echo \"    \$(basename \$(dirname \$f))\"; cat \"\$f\" | sed 's/^/      /'; done || echo '    无已配置的 Registry 信任。'" \
        2>/dev/null || log_warn "  [${node}] SSH 连接失败。"
}

# ── list 命令中的本机活跃信任配置（用于 remove 无参时显示）──────────────────
list_all_trust_configs() {
    local certs_dir="/etc/containerd/certs.d"
    local -a configs=()
    if [[ -d "${certs_dir}" ]]; then
        while IFS= read -r -d '' htf; do
            configs+=("$(basename "$(dirname "${htf}")")")
        done < <(find "${certs_dir}" -name "hosts.toml" -print0 2>/dev/null | sort -z)
    fi
    echo "${configs[@]:-}"
}

# ── 子命令实现 ─────────────────────────────────────────────────────────────────
do_apply() {
    log_info "注入 Registry 信任配置: ${TRUST_REGISTRY_ADDR}"

    if [[ ${#_NODES[@]} -eq 0 ]]; then
        _local_apply "${TRUST_REGISTRY_ADDR}" "${TRUST_HTTP}"
    else
        for node in "${_NODES[@]}"; do
            [[ "${node}" == "$(hostname -s)" || "${node}" == "localhost" || "${node}" == "127.0.0.1" ]] \
                && _local_apply "${TRUST_REGISTRY_ADDR}" "${TRUST_HTTP}" \
                || _remote_apply "${node}" "${TRUST_REGISTRY_ADDR}" "${TRUST_HTTP}"
        done
    fi
    log_info "完成。containerd 动态读取 certs.d，无需重启即生效。"
}

do_remove() {
    # 未显式指定 --config 时，列出活跃配置后退出（不执行删除）
    if [[ "${_CONFIG_EXPLICIT}" != "true" ]]; then
        echo
        log_info "当前本机生效的 Registry 信任配置："
        echo
        _local_list
        echo
        local configs; configs=$(list_all_trust_configs)
        if [[ -n "${configs}" ]]; then
            log_info "移除指定配置请运行："
            for c in ${configs}; do
                log_info "  sudo $0 remove --config <trust-conf>  # 或直接移除: sudo rm -rf /etc/containerd/certs.d/${c}"
            done
        fi
        return
    fi

    log_info "移除 Registry 信任配置: ${TRUST_REGISTRY_ADDR}"
    if [[ ${#_NODES[@]} -eq 0 ]]; then
        require_root
        _local_remove "${TRUST_REGISTRY_ADDR}"
    else
        for node in "${_NODES[@]}"; do
            [[ "${node}" == "$(hostname -s)" || "${node}" == "localhost" || "${node}" == "127.0.0.1" ]] \
                && { require_root; _local_remove "${TRUST_REGISTRY_ADDR}"; } \
                || _remote_remove "${node}" "${TRUST_REGISTRY_ADDR}"
        done
    fi
    log_info "完成。"
}

do_list() {
    echo
    if [[ ${#_NODES[@]} -eq 0 ]]; then
        log_info "本机 Registry 信任配置："
        echo
        _local_list
    else
        log_info "节点 Registry 信任配置："
        echo
        for node in "${_NODES[@]}"; do
            [[ "${node}" == "$(hostname -s)" || "${node}" == "localhost" || "${node}" == "127.0.0.1" ]] \
                && { echo "  ── 本机 ──"; _local_list; } \
                || _remote_list "${node}"
        done
    fi
    echo
}

# ── 主流程 ──────────────────────────────────────────────────────────────────────
main() {
    resolve_nodes

    case "${SUBCMD}" in
        apply)
            load_trust_conf
            do_apply
            ;;
        remove)
            # remove 允许无配置（用于列出）
            load_trust_conf 2>/dev/null || true
            do_remove
            ;;
        list)
            do_list
            ;;
    esac
}

main "$@"
