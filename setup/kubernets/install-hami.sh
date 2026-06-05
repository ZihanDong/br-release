#!/usr/bin/env bash
# 安装 / 卸载 HAMi 统一插件（取代壁仞原厂整卡插件），使节点用同一套插件同时调度：
#   · 整卡       birentech.com/gpu
#   · SVI 硬切分  birentech.com/1-2-gpu、birentech.com/1-4-gpu（biren-mode-manager 动态切分）
#   · vGPU 软切分 birentech.com/vgpu + vgpu-cores + vgpu-memory（动态切分；需 1.12.0 KMD）
#
# 组件：Helm 安装 HAMi 调度器 + biren-mode-manager；DaemonSet biren-hami-deviceplugin。
# 与原厂整卡插件互斥（同一资源名只能由一个插件注册）——安装时会自动删除原厂插件。
# 整卡 / SVI 用现有驱动即可；vGPU 另需节点加载与内核匹配的 1.12.0 KMD（kmd/biren.ko）。
#
# 用法：
#   sudo ./install-hami.sh [节点名1,节点名2,...]      # 安装（默认本机；多节点经 SSH 准备）
#   sudo ./install-hami.sh --remove                   # 卸载/重置（helm uninstall + 删插件 + 命名空间）
#
# 前提：目标节点已是 GPU 角色（先跑 set-node-mode.sh biren）。本脚本确保 GPU 标签。
#
# 环境变量：
#   KUBECONFIG          默认 /etc/kubernetes/admin.conf
#   HAMI_BUNDLE_DIR     HAMi-Biren 安装包（默认 <脚本目录>/../../packages/hami-biren；
#                       含 images/ chart/ deploy/ kmd/，由 hami_br_deploy 复制而来）
#   HAMI_NAMESPACE      默认 hami-system
#   PLUGIN_NAMESPACE    设备插件命名空间，默认 biren-gpu
#   HELM_VERSION        未装 helm 时下载版本（默认 v3.14.4，经 https_proxy）
#   KUBE_SCHED_REGISTRY/REPO/TAG  HAMi 内置 kube-scheduler sidecar 镜像（默认探测集群版本）
#   HAMI_SCHEDULER_NODE 固定 hami-scheduler 所在节点（默认 control-plane 节点）

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

: "${KUBECONFIG:=/etc/kubernetes/admin.conf}"
: "${HAMI_BUNDLE_DIR:=${SCRIPT_DIR}/../../packages/hami-biren}"
: "${HAMI_NAMESPACE:=hami-system}"
: "${PLUGIN_NAMESPACE:=biren-gpu}"
: "${HELM_VERSION:=v3.14.4}"
: "${KUBE_SCHED_REGISTRY:=registry.aliyuncs.com}"
: "${KUBE_SCHED_REPO:=google_containers/kube-scheduler}"
: "${KUBE_SCHED_TAG:=}"
: "${HAMI_SCHEDULER_NODE:=}"
KC="--kubeconfig ${KUBECONFIG}"
GPU_LABEL="birentech.com=gpu"
HAMI_HAMI_IMG=""; HAMI_DP_IMG=""

usage() {
    echo "用法: sudo $0 [--remove] [节点名1,节点名2,...]"
    echo "  （无 --remove）安装 HAMi 统一插件（整卡 + SVI + vGPU）"
    echo "  --remove      卸载并重置（helm uninstall hami + 删 biren-hami-deviceplugin + 命名空间）"
    exit 1
}

REMOVE=false; NODE_ARG=""; _positional=()
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
            log_warn "  节点 ${node} 仍有 control-plane:NoSchedule 污点，插件会 Pending。"
            log_warn "  请先：sudo ${SCRIPT_DIR}/set-node-mode.sh biren ${node}"
        fi
    done
}

_tar_image_name() { tar -xOf "$1" manifest.json 2>/dev/null | grep -oP '"RepoTags":\["\K[^"]+' | head -1; }
check_hami_bundle() {
    [[ -d "${HAMI_BUNDLE_DIR}" ]] || die "HAMi-Biren 安装包目录不存在: ${HAMI_BUNDLE_DIR}（见 packages/README.md：cp -a hami_br_deploy/. packages/hami-biren/）"
    local f
    for f in images/hami-biren-vgpu.tar images/biren-hami-deviceplugin-vgpu.tar \
             chart/hami/Chart.yaml chart/values-biren-vgpu.yaml \
             deploy/biren-hami-deviceplugin.yaml kmd/br_vgpu_tool; do
        [[ -e "${HAMI_BUNDLE_DIR}/${f}" ]] || die "安装包缺少文件: ${f}（位于 ${HAMI_BUNDLE_DIR}）"
    done
    HAMI_HAMI_IMG=$(_tar_image_name "${HAMI_BUNDLE_DIR}/images/hami-biren-vgpu.tar")
    HAMI_DP_IMG=$(_tar_image_name "${HAMI_BUNDLE_DIR}/images/biren-hami-deviceplugin-vgpu.tar")
    [[ -n "${HAMI_HAMI_IMG}" && -n "${HAMI_DP_IMG}" ]] || die "无法从安装包镜像 tar 读取镜像名。"
    log_info "  HAMi 镜像:     ${HAMI_HAMI_IMG}"
    log_info "  设备插件镜像: ${HAMI_DP_IMG}"
}
ensure_helm() {
    command_exists helm && { log_info "  helm 已安装: $(helm version --short 2>/dev/null || true)"; return; }
    log_info "未找到 helm，下载 ${HELM_VERSION}（经 https_proxy=${https_proxy:-<未设置>}）..."
    local tmp; tmp=$(mktemp -d /tmp/helm-XXXXXX); trap "rm -rf '${tmp}'" RETURN
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o "${tmp}/helm.tgz" \
        || die "下载 helm 失败；请手动安装 helm 或设置 https_proxy。"
    tar -xzf "${tmp}/helm.tgz" -C "${tmp}"; install -m0755 "${tmp}/linux-amd64/helm" /usr/local/bin/helm
    log_info "  helm 已安装: $(helm version --short 2>/dev/null || true)"
}
_resolve_kube_scheduler_tag() {
    [[ -n "${KUBE_SCHED_TAG}" ]] && { echo "${KUBE_SCHED_TAG}"; return; }
    local v; v=$(kubectl version -o json ${KC} 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['serverVersion']['gitVersion'])" 2>/dev/null || true)
    echo "${v:-v1.30.0}"
}
_resolve_scheduler_node() {
    [[ -n "${HAMI_SCHEDULER_NODE}" ]] && { echo "${HAMI_SCHEDULER_NODE}"; return; }
    kubectl get nodes ${KC} -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}
_import_image_local() {
    local tar="$1" img="$2"
    if ctr -n k8s.io images ls 2>/dev/null | grep -q "${img}"; then log_info "    镜像已存在，跳过: ${img}"
    else log_info "    导入镜像: ${img}"; ctr -n k8s.io images import "${tar}" 2>&1 | tail -1; fi
}
_warn_kmd() {
    local v="$1" where="$2"
    if [[ "${v}" == "1.12.0" ]]; then log_info "    ${where} KMD 版本 ${v} — vGPU 软切分可用。"
    else log_warn "    ${where} KMD 版本 '${v:-未知}'（非 1.12.0）：整卡+SVI 正常，vGPU 需先加载 1.12.0 KMD（kmd/）。"; fi
}
_ssh() { if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" ]]; then sudo -u "${SUDO_USER}" -H ssh "$@"; else ssh "$@"; fi; }
_scp() { if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" ]]; then sudo -u "${SUDO_USER}" -H scp "$@"; else scp "$@"; fi; }
_prep_local() {
    command_exists ctr || die "未找到 ctr。"
    log_info "  [本机] 准备节点 $(hostname -s)..."
    _import_image_local "${HAMI_BUNDLE_DIR}/images/hami-biren-vgpu.tar"             "${HAMI_HAMI_IMG}"
    _import_image_local "${HAMI_BUNDLE_DIR}/images/biren-hami-deviceplugin-vgpu.tar" "${HAMI_DP_IMG}"
    install -m0755 "${HAMI_BUNDLE_DIR}/kmd/br_vgpu_tool" /usr/local/bin/br_vgpu_tool
    [[ -f "${HAMI_BUNDLE_DIR}/kmd/br_container_id" ]] && install -m0755 "${HAMI_BUNDLE_DIR}/kmd/br_container_id" /usr/local/bin/br_container_id || true
    log_info "    已安装 br_vgpu_tool → /usr/local/bin/br_vgpu_tool"
    _warn_kmd "$(cat /sys/module/biren/version 2>/dev/null || true)" "本机"
}
_prep_remote() {
    local node="$1" rdir="/tmp/hami-biren-prep"
    log_info "  [SSH] 准备远端节点 ${node}（ssh 以 ${SUDO_USER:-$(id -un)}）..."
    if ! _ssh -o BatchMode=yes -o ConnectTimeout=10 "${node}" 'sudo -n true' >/dev/null 2>&1; then
        log_warn "  ${node}: 无法免密 SSH+sudo，跳过自动准备。请在该节点手动跑 images/load-images.sh 并安装 br_vgpu_tool。"; return 0
    fi
    _ssh "${node}" "mkdir -p ${rdir}" || { log_warn "  ${node}: 创建临时目录失败，跳过。"; return 0; }
    local t img
    for pair in "hami-biren-vgpu.tar|${HAMI_HAMI_IMG}" "biren-hami-deviceplugin-vgpu.tar|${HAMI_DP_IMG}"; do
        t="${pair%%|*}"; img="${pair##*|}"
        _ssh "${node}" "sudo -n ctr -n k8s.io images ls 2>/dev/null | grep -q '${img}'" && { log_info "    ${img} 已存在于 ${node}。"; continue; }
        log_info "    传输并导入 ${img} → ${node}..."
        _scp -q "${HAMI_BUNDLE_DIR}/images/${t}" "${node}:${rdir}/" \
            && _ssh "${node}" "sudo -n ctr -n k8s.io images import ${rdir}/${t}" 2>&1 | tail -1 \
            || { log_warn "    ${node}: 导入 ${img} 失败，跳过。"; return 0; }
    done
    _scp -q "${HAMI_BUNDLE_DIR}/kmd/br_vgpu_tool" "${node}:${rdir}/" \
        && _ssh "${node}" "sudo -n install -m0755 ${rdir}/br_vgpu_tool /usr/local/bin/br_vgpu_tool" \
        || { log_warn "    ${node}: 安装 br_vgpu_tool 失败，跳过。"; return 0; }
    _warn_kmd "$(_ssh "${node}" 'cat /sys/module/biren/version 2>/dev/null' 2>/dev/null || true)" "${node}"
}
prep_node() { local n="$1"; [[ "${n}" == "$(hostname -s)" ]] && _prep_local || _prep_remote "${n}"; }

remove_stock_plugin() {
    if kubectl get ds biren-device-plugin-daemonset -n "${PLUGIN_NAMESPACE}" ${KC} >/dev/null 2>&1; then
        log_info "  删除原厂整卡 device plugin（与统一插件互斥）..."
        kubectl delete ds biren-device-plugin-daemonset -n "${PLUGIN_NAMESPACE}" ${KC} 2>/dev/null || log_warn "  删除原厂插件失败，请手动检查。"
    fi
}
install_hami_bundle() {
    local sched_tag sched_node
    sched_tag=$(_resolve_kube_scheduler_tag); sched_node=$(_resolve_scheduler_node)
    log_info "  kube-scheduler sidecar: ${KUBE_SCHED_REGISTRY}/${KUBE_SCHED_REPO}:${sched_tag}"
    [[ -n "${sched_node}" ]] && log_info "  hami-scheduler 固定节点: ${sched_node}"
    log_info "  Helm 安装/升级 HAMi（命名空间 ${HAMI_NAMESPACE}）..."
    local args=( upgrade --install hami "${HAMI_BUNDLE_DIR}/chart/hami"
        -n "${HAMI_NAMESPACE}" --create-namespace -f "${HAMI_BUNDLE_DIR}/chart/values-biren-vgpu.yaml"
        --set "scheduler.kubeScheduler.image.registry=${KUBE_SCHED_REGISTRY}"
        --set "scheduler.kubeScheduler.image.repository=${KUBE_SCHED_REPO}"
        --set "scheduler.kubeScheduler.image.tag=${sched_tag}" --wait --timeout 5m )
    [[ -n "${sched_node}" ]] && args+=(--set "scheduler.nodeName=${sched_node}")
    KUBECONFIG="${KUBECONFIG}" helm "${args[@]}" || log_warn "  helm 未在超时内就绪，仍继续部署设备插件，末尾打印状态供排查。"
    log_info "  部署 biren-hami-deviceplugin..."
    local m; m=$(mktemp /tmp/biren-hami-dp-XXXXXX.yaml); trap "rm -f '${m}'" RETURN
    sed "s#image: biren-hami-deviceplugin:latest#image: ${HAMI_DP_IMG}#" \
        "${HAMI_BUNDLE_DIR}/deploy/biren-hami-deviceplugin.yaml" > "${m}"
    kubectl apply -f "${m}" ${KC}
    kubectl rollout status daemonset/biren-hami-deviceplugin -n "${PLUGIN_NAMESPACE}" --timeout=180s ${KC} 2>/dev/null \
        || log_warn "  biren-hami-deviceplugin 未在 3 分钟内就绪，请手动检查。"
}

do_install() {
    log_info "── 安装 HAMi 统一插件（整卡 + SVI + vGPU）──"
    check_hami_bundle
    ensure_helm
    ensure_gpu_label
    for node in "${_NODES[@]}"; do prep_node "${node}"; done
    remove_stock_plugin                 # 移除原厂插件，避免资源名冲突
    set_biren_runtimeclass runc         # HAMi 设备由插件直接注入，不用 biren 运行时
    install_hami_bundle
}

do_remove() {
    log_info "── 卸载 HAMi 统一插件（环境重置）──"
    if command_exists helm && KUBECONFIG="${KUBECONFIG}" helm status hami -n "${HAMI_NAMESPACE}" >/dev/null 2>&1; then
        log_info "  helm uninstall hami..."; KUBECONFIG="${KUBECONFIG}" helm uninstall hami -n "${HAMI_NAMESPACE}" 2>/dev/null || log_warn "  helm uninstall 失败。"
    fi
    kubectl delete ds biren-hami-deviceplugin -n "${PLUGIN_NAMESPACE}" ${KC} --ignore-not-found 2>/dev/null || true
    if [[ -f "${HAMI_BUNDLE_DIR}/deploy/biren-hami-deviceplugin.yaml" ]]; then
        kubectl delete -f "${HAMI_BUNDLE_DIR}/deploy/biren-hami-deviceplugin.yaml" ${KC} --ignore-not-found 2>/dev/null || true
    fi
    kubectl delete ns "${HAMI_NAMESPACE}" ${KC} --ignore-not-found 2>/dev/null || true
    # biren-gpu 命名空间可能被原厂插件共用；仅在空时删除
    if [[ -z "$(kubectl get all -n "${PLUGIN_NAMESPACE}" ${KC} --no-headers 2>/dev/null)" ]]; then
        kubectl delete ns "${PLUGIN_NAMESPACE}" ${KC} --ignore-not-found 2>/dev/null || true
    fi
    set_biren_runtimeclass runc
    log_info "HAMi 组件已卸载；RuntimeClass 'biren' → handler: runc。"
}

print_status() {
    echo; log_info "════════ HAMi 统一插件状态 ════════"
    log_info "HAMi 组件（${HAMI_NAMESPACE}）:"; kubectl get pods -n "${HAMI_NAMESPACE}" -o wide ${KC} 2>/dev/null || true
    echo; log_info "设备插件（${PLUGIN_NAMESPACE}）:"; kubectl get pods -n "${PLUGIN_NAMESPACE}" -o wide ${KC} 2>/dev/null | grep -iE 'NAME|deviceplugin' || true
    echo; log_info "GPU allocatable（SVI/vGPU 静态为 0，按需切分）:"
    kubectl get nodes ${KC} -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.birentech\.com/gpu,1/2:.status.allocatable.birentech\.com/1-2-gpu,1/4:.status.allocatable.birentech\.com/1-4-gpu,VGPU:.status.allocatable.birentech\.com/vgpu' 2>/dev/null || true
    if [[ "${REMOVE}" != true ]]; then
        echo; log_info "Pod 须指定 schedulerName: hami-scheduler（本部署未启用 webhook）。"
        log_info "  模板:  ${SCRIPT_DIR}/templates/biren-{whole-gpu,svi-half,svi-quarter,vgpu}.yaml"
    fi
    echo "════════════════════════════════════════════"
}

main() {
    preflight_check
    resolve_nodes
    if [[ "${REMOVE}" == true ]]; then do_remove; else do_install; fi
    print_status
}
main "$@"
