#!/usr/bin/env bash
# 安装 / 卸载壁仞「原厂」整卡 device plugin（遵循壁仞官方 k8s 支持）。
#
# 该插件只提供整卡调度资源 birentech.com/gpu，并依赖 RuntimeClass 'biren'
# （handler: biren，壁仞容器运行时）向 GPU 容器注入 /dev/biren-m 与分配的
# /dev/biren/card_N。与 HAMi 统一插件互斥（同一资源名只能由一个插件注册）——
# 安装前若检测到 HAMi 已部署会拒绝执行，请先 install-hami.sh --remove。
#
# 用法：
#   sudo ./install-biren-device-plugin.sh [节点名1,节点名2,...]      # 安装
#   sudo ./install-biren-device-plugin.sh --remove [节点名,...]      # 卸载/重置
#
# 前提：目标节点已是 GPU 角色（先跑 set-node-mode.sh biren：去污点 + 打标签）。
#   本脚本只确保 GPU 标签（DaemonSet 的 nodeSelector），不动 control-plane 污点。
#
# 环境变量：
#   KUBECONFIG        默认 /etc/kubernetes/admin.conf
#   PLUGIN_DIR        原厂插件目录（默认 <脚本目录>/../../packages/biren，
#                     含 *.tar 镜像与 biren-device-plugin.yaml）
#   PLUGIN_NAMESPACE  默认 biren-gpu

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

: "${KUBECONFIG:=/etc/kubernetes/admin.conf}"
: "${PLUGIN_DIR:=${SCRIPT_DIR}/../../packages/biren}"
: "${PLUGIN_NAMESPACE:=biren-gpu}"
KC="--kubeconfig ${KUBECONFIG}"
GPU_LABEL="birentech.com=gpu"
DS_NAME="biren-device-plugin-daemonset"
PLUGIN_IMAGE=""

usage() {
    echo "用法: sudo $0 [--remove] [节点名1,节点名2,...]"
    echo "  （无 --remove）安装原厂整卡 device plugin"
    echo "  --remove      卸载该插件并重置（删 DaemonSet/命名空间，RuntimeClass 恢复 runc）"
    exit 1
}

REMOVE=false
NODE_ARG=""
_positional=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --remove)  REMOVE=true; shift ;;
        -h|--help) usage ;;
        -*)        echo "未知选项: $1"; usage ;;
        *)         _positional+=("$1"); shift ;;
    esac
done
NODE_ARG="${_positional[0]:-}"

preflight_check() {
    require_root
    command_exists kubectl || die "未找到 kubectl。"
    [[ -f "${KUBECONFIG}" ]] || die "kubeconfig 不存在: ${KUBECONFIG}"
    kubectl get nodes ${KC} &>/dev/null || die "API Server 无法访问。"
}

resolve_nodes() {
    if [[ -n "${NODE_ARG}" ]]; then IFS=',' read -ra _NODES <<< "${NODE_ARG}"
    else _NODES=("$(hostname -s)"); fi
    log_info "目标节点: ${_NODES[*]}"
}

# RuntimeClass 'biren' 的 handler 不可变更，需先删后建。
set_biren_runtimeclass() {
    local handler="$1" current
    current=$(kubectl get runtimeclass biren ${KC} -o jsonpath='{.handler}' 2>/dev/null || echo "")
    [[ "${current}" == "${handler}" ]] && { log_info "  RuntimeClass 'biren' handler 已为 ${handler}。"; return; }
    [[ -n "${current}" ]] && kubectl delete runtimeclass biren ${KC} >/dev/null 2>&1 || true
    kubectl apply ${KC} -f - <<EOF >/dev/null
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: biren
handler: ${handler}
EOF
    log_info "  RuntimeClass 'biren' handler 设为: ${handler}。"
}

ensure_gpu_label() {
    for node in "${_NODES[@]}"; do
        kubectl label node "${node}" "${GPU_LABEL}" ${KC} --overwrite >/dev/null \
            && log_info "  节点 ${node}: 确保标签 ${GPU_LABEL}。" || log_warn "  节点 ${node}: 标签设置失败。"
        if kubectl get node "${node}" ${KC} -o jsonpath='{.spec.taints}' 2>/dev/null | grep -q "control-plane"; then
            log_warn "  节点 ${node} 仍有 control-plane:NoSchedule 污点，原厂插件 DaemonSet 不容忍该污点，"
            log_warn "  会一直 Pending。请先：sudo ${SCRIPT_DIR}/set-node-mode.sh biren ${node}"
        fi
    done
}

hami_installed() {
    kubectl get ds biren-hami-deviceplugin -n "${PLUGIN_NAMESPACE}" ${KC} >/dev/null 2>&1 \
        || { command_exists helm && KUBECONFIG="${KUBECONFIG}" helm status hami -n hami-system >/dev/null 2>&1; }
}

# ── 安装 ──────────────────────────────────────────────────────────────────────
check_plugin_dir() {
    [[ -d "${PLUGIN_DIR}" ]] || die "原厂插件目录不存在: ${PLUGIN_DIR}（需含 *.tar 镜像 + biren-device-plugin.yaml）"
    PLUGIN_TAR=$(find -L "${PLUGIN_DIR}" -maxdepth 1 -name "*.tar" ! -name "*.tar.gz" | head -1)
    [[ -n "${PLUGIN_TAR}" ]] || die "原厂插件目录无镜像 tar: ${PLUGIN_DIR}"
    [[ -f "${PLUGIN_DIR}/biren-device-plugin.yaml" ]] || die "缺少 biren-device-plugin.yaml: ${PLUGIN_DIR}"
}

load_plugin_image() {
    command_exists ctr || die "未找到 ctr（containerd CLI）。"
    PLUGIN_IMAGE=$(tar -xOf "${PLUGIN_TAR}" manifest.json 2>/dev/null | grep -oP '"RepoTags":\["\K[^"]+' | head -1)
    [[ -n "${PLUGIN_IMAGE}" ]] || die "无法从 ${PLUGIN_TAR} 读取镜像名。"
    if ctr -n k8s.io images ls 2>/dev/null | grep -q "${PLUGIN_IMAGE}"; then
        log_info "镜像已存在，跳过导入: ${PLUGIN_IMAGE}"
    else
        log_info "导入原厂插件镜像: ${PLUGIN_IMAGE}"; ctr -n k8s.io images import "${PLUGIN_TAR}" 2>&1 | tail -2
    fi
}

render_manifest() {   # -> echoes a temp manifest path with image + hostPath fixes
    local m; m=$(mktemp /tmp/biren-plugin-XXXXXX.yaml)
    cp "${PLUGIN_DIR}/biren-device-plugin.yaml" "${m}"
    sed -i "s|image: *$|image: ${PLUGIN_IMAGE}|" "${m}"
    # brml/brsmi hostPath 默认 /usr/lib、/usr/bin（本机为指向 birensupa 的符号链接）；
    # 改挂解析后的真实目录，容器内才有实际 .so 与二进制。
    local real_lib real_bin
    real_lib=$(dirname "$(realpath /usr/lib/libbiren-ml.so.1 2>/dev/null)" 2>/dev/null || true)
    [[ -n "${real_lib}" && "${real_lib}" != "/usr/lib" ]] && sed -i "s|path: /usr/lib$|path: ${real_lib}|" "${m}"
    real_bin=$(dirname "$(realpath "$(command -v brsmi 2>/dev/null)" 2>/dev/null)" 2>/dev/null || true)
    [[ -n "${real_bin}" && "${real_bin}" != "/usr/bin" ]] && sed -i "s|path: /usr/bin$|path: ${real_bin}|" "${m}"
    grep -q 'mount-host-path' "${m}" || sed -i 's|"--container-runtime", "runc"\]|"--container-runtime", "runc", "--mount-host-path"]|' "${m}"
    echo "${m}"
}

do_install() {
    log_info "── 安装原厂整卡 device plugin ──"
    hami_installed && die "检测到 HAMi 统一插件已部署（与原厂插件互斥）。请先：sudo ${SCRIPT_DIR}/install-hami.sh --remove"
    check_plugin_dir
    ensure_gpu_label
    load_plugin_image
    set_biren_runtimeclass biren
    local m; m=$(render_manifest); trap "rm -f '${m}'" RETURN
    kubectl apply -f "${m}" ${KC}
    log_info "等待 DaemonSet 就绪（最多 3 分钟）..."
    kubectl rollout status daemonset/${DS_NAME} -n "${PLUGIN_NAMESPACE}" --timeout=180s ${KC} 2>/dev/null \
        || log_warn "DaemonSet 未在 3 分钟内就绪，请手动检查。"
}

# ── 卸载 / 重置 ───────────────────────────────────────────────────────────────
do_remove() {
    log_info "── 卸载原厂整卡 device plugin（环境重置）──"
    if [[ -f "${PLUGIN_DIR}/biren-device-plugin.yaml" ]]; then
        # 用原始清单整体删除（Namespace/SA/ClusterRole/Binding/DaemonSet）
        kubectl delete -f "${PLUGIN_DIR}/biren-device-plugin.yaml" ${KC} --ignore-not-found 2>/dev/null || true
    else
        kubectl delete ds ${DS_NAME} -n "${PLUGIN_NAMESPACE}" ${KC} --ignore-not-found 2>/dev/null || true
        kubectl delete ns "${PLUGIN_NAMESPACE}" ${KC} --ignore-not-found 2>/dev/null || true
    fi
    set_biren_runtimeclass runc
    log_info "原厂插件已卸载；RuntimeClass 'biren' 恢复 handler: runc。"
}

print_status() {
    echo; log_info "════════ 原厂整卡 device plugin 状态 ════════"
    kubectl get pods -n "${PLUGIN_NAMESPACE}" -o wide ${KC} 2>/dev/null | grep -iE 'NAME|device-plugin' || log_info "  （命名空间无插件 Pod）"
    echo
    log_info "GPU allocatable（插件就绪约 30s 后刷新）:"
    kubectl get nodes ${KC} -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.birentech\.com/gpu' 2>/dev/null || true
    log_info "RuntimeClass 'biren' handler: $(kubectl get runtimeclass biren ${KC} -o jsonpath='{.handler}' 2>/dev/null || echo 未创建)"
    echo "════════════════════════════════════════════"
}

main() {
    preflight_check
    resolve_nodes
    if [[ "${REMOVE}" == true ]]; then do_remove; else do_install; fi
    print_status
}
main "$@"
