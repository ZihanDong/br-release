#!/usr/bin/env bash
# 切换节点的算力角色（仅做节点模式切换：污点 + GPU 标签）
#
# 本脚本只负责把节点切到某个算力角色，不再安装任何 device plugin。
# 安装 / 卸载插件请用同目录下的两个脚本（二者互斥，同一资源名只能由一个插件注册）：
#   · install-biren-device-plugin.sh  原厂整卡 device plugin（仅整卡 birentech.com/gpu）
#   · install-hami.sh                 HAMi 统一插件（整卡 + SVI 1/2,1/4 + vGPU 软切分）
# 两个安装脚本都支持 --remove 做环境重置。
#
# 用法：
#   sudo ./set-node-mode.sh <cpu|biren|none> [节点名1,节点名2,...]
#
# mode：
#   cpu    去除 control-plane:NoSchedule 污点 + 去 GPU 标签，节点以纯 CPU 算力参与调度
#   biren  去除污点 + 打 GPU 标签（birentech.com=gpu），把节点设为 GPU 算力角色；
#          之后再用 install-biren-device-plugin.sh 或 install-hami.sh 安装插件
#   none   恢复 control-plane:NoSchedule 隔离污点 + 去 GPU 标签，移出调度池
#
# 不指定节点时默认对本机 hostname 对应节点操作；多节点用逗号分隔（node1,node2）。
#
# 环境变量：
#   KUBECONFIG   kubectl 配置文件（默认 /etc/kubernetes/admin.conf）
#
# 典型流程：
#   sudo ./set-node-mode.sh biren                 # 1) 节点设为 GPU 角色
#   sudo ./install-hami.sh                         # 2) 安装 HAMi 统一插件（或原厂插件）
#   ...
#   sudo ./install-hami.sh --remove                # 卸载插件
#   sudo ./set-node-mode.sh none                   # 节点移出调度池

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
source "${LIB_DIR}/common.sh"

# ── 默认值 ────────────────────────────────────────────────────────────────────
: "${KUBECONFIG:=/etc/kubernetes/admin.conf}"
KC="--kubeconfig ${KUBECONFIG}"

CONTROL_PLANE_TAINT="node-role.kubernetes.io/control-plane:NoSchedule"
GPU_LABEL="birentech.com=gpu"

# ── 参数解析 ──────────────────────────────────────────────────────────────────
usage() {
    echo "用法: sudo $0 <cpu|biren|none> [节点名1,节点名2,...]"
    echo "  cpu    - 纯 CPU 算力节点（去污点 + 去 GPU 标签）"
    echo "  biren  - GPU 算力角色（去污点 + 打 GPU 标签）；插件另用 install-*.sh 安装"
    echo "  none   - 恢复 control-plane 隔离（加污点 + 去 GPU 标签）"
    echo
    echo "插件安装/卸载（互斥）："
    echo "  sudo ${SCRIPT_DIR}/install-biren-device-plugin.sh [--remove]   原厂整卡插件"
    echo "  sudo ${SCRIPT_DIR}/install-hami.sh               [--remove]   HAMi 统一插件"
    exit 1
}

MODE=""
NODE_ARG=""
_positional=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        -*)        echo "未知选项: $1"; usage ;;
        *)         _positional+=("$1"); shift ;;
    esac
done
MODE="${_positional[0]:-}"
NODE_ARG="${_positional[1]:-}"

[[ "${MODE}" == "cpu" || "${MODE}" == "biren" || "${MODE}" == "none" ]] || usage

# ── 前置检查 ──────────────────────────────────────────────────────────────────
preflight_check() {
    require_root
    command_exists kubectl || die "未找到 kubectl。"
    [[ -f "${KUBECONFIG}" ]] || die "kubeconfig 不存在: ${KUBECONFIG}"
    local retries=12 interval=5
    for ((i=1; i<=retries; i++)); do
        kubectl get nodes ${KC} &>/dev/null && break
        log_info "  等待 API Server 可达... (${i}/${retries})"
        sleep "${interval}"
        [[ $i -eq $retries ]] && die "API Server 无法访问。"
    done
}

resolve_nodes() {
    if [[ -n "${NODE_ARG}" ]]; then
        IFS=',' read -ra _NODES <<< "${NODE_ARG}"
    else
        _NODES=("$(hostname -s)")
        log_info "未指定节点，默认操作本机节点: ${_NODES[0]}"
    fi
    log_info "目标节点: ${_NODES[*]}"
}

# ── 污点 / 标签操作 ───────────────────────────────────────────────────────────
add_taint() {
    local node="$1"
    if kubectl get node "${node}" ${KC} -o jsonpath='{.spec.taints}' 2>/dev/null | grep -q "control-plane"; then
        log_info "  节点 ${node}: control-plane:NoSchedule 污点已存在，跳过。"
    else
        kubectl taint node "${node}" "${CONTROL_PLANE_TAINT}" ${KC} \
            && log_info "  节点 ${node}: 已添加 control-plane:NoSchedule 污点。" \
            || log_warn "  节点 ${node}: 添加污点失败。"
    fi
}

remove_taint() {
    local node="$1"
    if kubectl get node "${node}" ${KC} -o jsonpath='{.spec.taints}' 2>/dev/null | grep -q "control-plane"; then
        kubectl taint node "${node}" "${CONTROL_PLANE_TAINT}-" ${KC} \
            && log_info "  节点 ${node}: 已去除 control-plane:NoSchedule 污点。" \
            || log_warn "  节点 ${node}: 去除污点失败。"
    else
        log_info "  节点 ${node}: 无 control-plane:NoSchedule 污点，跳过。"
    fi
}

add_gpu_label() {
    local node="$1"
    kubectl label node "${node}" "${GPU_LABEL}" ${KC} --overwrite \
        && log_info "  节点 ${node}: 已添加标签 ${GPU_LABEL}。" \
        || log_warn "  节点 ${node}: 标签添加失败。"
}

remove_gpu_label() {
    local node="$1"
    if kubectl get node "${node}" ${KC} -o jsonpath='{.metadata.labels}' 2>/dev/null | grep -q "birentech.com"; then
        kubectl label node "${node}" "birentech.com-" ${KC} \
            && log_info "  节点 ${node}: 已移除 GPU 标签。" \
            || log_warn "  节点 ${node}: 移除 GPU 标签失败。"
    else
        log_info "  节点 ${node}: 无 GPU 标签，跳过。"
    fi
}

# ── 模式处理 ──────────────────────────────────────────────────────────────────
mode_none() {
    log_info "── 模式: none（恢复 control-plane 隔离）──"
    for node in "${_NODES[@]}"; do
        add_taint        "${node}"
        remove_gpu_label "${node}"
    done
}

mode_cpu() {
    log_info "── 模式: cpu（纯 CPU 算力节点）──"
    for node in "${_NODES[@]}"; do
        remove_taint     "${node}"
        remove_gpu_label "${node}"
    done
}

mode_biren() {
    log_info "── 模式: biren（GPU 算力角色：去污点 + 打 GPU 标签）──"
    for node in "${_NODES[@]}"; do
        remove_taint  "${node}"
        add_gpu_label "${node}"
    done
    log_info "节点已就绪为 GPU 角色。下一步安装插件（二选一，互斥）："
    log_info "  原厂整卡:  sudo ${SCRIPT_DIR}/install-biren-device-plugin.sh"
    log_info "  HAMi统一:  sudo ${SCRIPT_DIR}/install-hami.sh"
}

# ── 打印状态 ──────────────────────────────────────────────────────────────────
print_status() {
    echo
    log_info "════════════════════════════════════════════════════"
    log_info "  节点算力角色切换完成（模式: ${MODE}）"
    log_info "════════════════════════════════════════════════════"
    echo
    log_info "节点污点 / 标签:"
    for node in "${_NODES[@]}"; do
        echo "  ── ${node} ──"
        kubectl get node "${node}" ${KC} \
            -o custom-columns='TAINTS:.spec.taints,LABELS:.metadata.labels' 2>/dev/null | tail -1 || true
    done
    echo
    log_info "（本脚本不安装插件；用 install-biren-device-plugin.sh / install-hami.sh 安装或 --remove 卸载）"
    log_info "════════════════════════════════════════════════════"
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
    preflight_check
    resolve_nodes
    case "${MODE}" in
        none)  mode_none  ;;
        cpu)   mode_cpu   ;;
        biren) mode_biren ;;
    esac
    print_status
}

main "$@"
