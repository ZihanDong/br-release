#!/usr/bin/env bash
# 切换节点的算力角色
#
# 用法：
#   sudo ./set-node-mode.sh <mode> [--vgpu] [节点名1,节点名2,...]
#
# mode 可选值：
#   cpu   去除 control-plane:NoSchedule 污点，节点以纯 CPU 算力参与调度
#   biren 去除污点，打 GPU 标签，部署 BirenTech device plugin，节点作为 GPU 算力节点
#   none  恢复 control-plane:NoSchedule 隔离污点，移出调度池
#
# --vgpu（仅 biren 模式）：部署统一的 HAMi-Biren 设备插件，使节点用同一套插件
#   同时调度三种形态的壁仞 GPU 资源：
#     · 整卡        birentech.com/gpu
#     · SVI 硬切分   birentech.com/1-2-gpu、birentech.com/1-4-gpu（按需动态切分）
#     · vGPU 软切分  birentech.com/vgpu + vgpu-cores + vgpu-memory（按需动态切分）
#   该模式用 biren-hami-deviceplugin 取代壁仞原厂整卡 device plugin，并通过 Helm
#   安装 HAMi 调度器 + biren-mode-manager（按需动态 SVI/vGPU 切分与回收）。整卡、
#   SVI 依赖现有驱动即可；vGPU 软切分额外需要节点加载与内核匹配的 1.12.0 KMD
#   （kmd/biren.ko，由管理员手动加载；未加载时整卡/SVI 不受影响，仅 vGPU 暂不可用）。
#   所需文件来自 HAMI_BUNDLE_DIR（默认 packages/hami-biren，见 packages/README.md）。
#
# 不指定节点时默认对本机 hostname 对应节点操作。
# 多节点用逗号分隔，如：node1,node2
#
# 环境变量：
#   KUBECONFIG       kubectl 配置文件（默认 /etc/kubernetes/admin.conf）
#   PLUGIN_DIR       原厂整卡 device plugin 目录（plain biren 模式用；默认
#                    <脚本目录>/../../packages/biren，含 *.tar 镜像和 biren-device-plugin.yaml）
#   PLUGIN_NAMESPACE device plugin 命名空间（默认 biren-gpu）
#   HAMI_BUNDLE_DIR  HAMi-Biren 安装包目录（--vgpu 用；默认 packages/hami-biren，
#                    含 images/、chart/、deploy/、kmd/）
#   HAMI_NAMESPACE   HAMi 命名空间（默认 hami-system）
#   HELM_VERSION     未安装 helm 时自动下载的版本（默认 v3.14.4，经 https_proxy）
#   KUBE_SCHED_*     HAMi 调度器内置 kube-scheduler 镜像（默认复用集群已缓存的
#                    registry.aliyuncs.com/google_containers/kube-scheduler:v<集群版本>）
#   HAMI_SCHEDULER_NODE  固定 hami-scheduler 所在节点（默认自动取 control-plane 节点）
#
# 示例：
#   sudo ./set-node-mode.sh cpu                        # 本机作为 CPU 节点
#   sudo ./set-node-mode.sh biren                      # 本机作为 GPU 节点（原厂整卡插件）
#   sudo ./set-node-mode.sh biren --vgpu               # 本机作为 GPU 节点（HAMi 统一插件：整卡+SVI+vGPU）
#   sudo ./set-node-mode.sh biren --vgpu node1,node2   # 批量部署统一插件
#   sudo ./set-node-mode.sh none                       # 恢复隔离

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

source "${LIB_DIR}/common.sh"

# ── 默认值 ────────────────────────────────────────────────────────────────────
: "${KUBECONFIG:=/etc/kubernetes/admin.conf}"
: "${PLUGIN_NAMESPACE:=biren-gpu}"
: "${PLUGIN_DIR:=${SCRIPT_DIR}/../../packages/biren}"
# HAMi-Biren unified bundle (for --vgpu): images/ chart/ deploy/ kmd/
# (copied from hami_br_deploy; see packages/README.md).
: "${HAMI_BUNDLE_DIR:=${SCRIPT_DIR}/../../packages/hami-biren}"
: "${HAMI_NAMESPACE:=hami-system}"
: "${HELM_VERSION:=v3.14.4}"
# HAMi scheduler's embedded kube-scheduler sidecar image. Must match the cluster's
# k8s minor version; defaults reuse the image the control plane already caches.
: "${KUBE_SCHED_REGISTRY:=registry.aliyuncs.com}"
: "${KUBE_SCHED_REPO:=google_containers/kube-scheduler}"
: "${KUBE_SCHED_TAG:=}"   # empty → auto-detect from the API server version
# Pin hami-scheduler to a node guaranteed to have the kube-scheduler image
# (the control plane). Empty → auto-detect the control-plane node.
: "${HAMI_SCHEDULER_NODE:=}"
KC="--kubeconfig ${KUBECONFIG}"

CONTROL_PLANE_TAINT="node-role.kubernetes.io/control-plane:NoSchedule"
GPU_LABEL="birentech.com=gpu"

# ── 参数解析 ──────────────────────────────────────────────────────────────────
usage() {
    echo "用法: sudo $0 <cpu|biren|none> [--vgpu] [节点名1,节点名2,...]"
    echo "  cpu     - 纯 CPU 算力节点"
    echo "  biren   - BirenTech GPU 算力节点（原厂 device plugin，仅整卡调度）"
    echo "  none    - 恢复 control-plane 隔离"
    echo "  --vgpu  - 仅 biren 模式：部署 HAMi-Biren 统一插件取代原厂整卡插件，"
    echo "            使节点用同一套插件同时调度整卡 + SVI 硬切分（1/2、1/4）+ vGPU"
    echo "            软切分（vgpu-cores/vgpu-memory）。vGPU 需节点加载 1.12.0 KMD。"
    exit 1
}

MODE=""
NODE_ARG=""
VGPU=false
_positional=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vgpu)    VGPU=true; shift ;;
        -h|--help) usage ;;
        -*)        echo "未知选项: $1"; usage ;;
        *)         _positional+=("$1"); shift ;;
    esac
done
MODE="${_positional[0]:-}"
NODE_ARG="${_positional[1]:-}"

[[ "${MODE}" == "cpu" || "${MODE}" == "biren" || "${MODE}" == "none" ]] \
    || usage
[[ "${VGPU}" == true && "${MODE}" != "biren" ]] \
    && { echo "错误: --vgpu 仅适用于 biren 模式"; usage; }

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

# ── 解析目标节点列表 ──────────────────────────────────────────────────────────
resolve_nodes() {
    if [[ -n "${NODE_ARG}" ]]; then
        IFS=',' read -ra _NODES <<< "${NODE_ARG}"
    else
        local self
        self=$(hostname -s)
        _NODES=("${self}")
        log_info "未指定节点，默认操作本机节点: ${self}"
    fi
    log_info "目标节点: ${_NODES[*]}"
}

# ── 污点操作 ──────────────────────────────────────────────────────────────────
add_taint() {
    local node="$1"
    if kubectl get node "${node}" ${KC} -o jsonpath='{.spec.taints}' 2>/dev/null \
            | grep -q "control-plane"; then
        log_info "  节点 ${node}: control-plane:NoSchedule 污点已存在，跳过。"
    else
        kubectl taint node "${node}" "${CONTROL_PLANE_TAINT}" ${KC} \
            && log_info "  节点 ${node}: 已添加 control-plane:NoSchedule 污点。" \
            || log_warn "  节点 ${node}: 添加污点失败。"
    fi
}

remove_taint() {
    local node="$1"
    if kubectl get node "${node}" ${KC} -o jsonpath='{.spec.taints}' 2>/dev/null \
            | grep -q "control-plane"; then
        kubectl taint node "${node}" "${CONTROL_PLANE_TAINT}-" ${KC} \
            && log_info "  节点 ${node}: 已去除 control-plane:NoSchedule 污点。" \
            || log_warn "  节点 ${node}: 去除污点失败。"
    else
        log_info "  节点 ${node}: 无 control-plane:NoSchedule 污点，跳过。"
    fi
}

# ── 标签操作 ──────────────────────────────────────────────────────────────────
add_gpu_label() {
    local node="$1"
    kubectl label node "${node}" "${GPU_LABEL}" ${KC} --overwrite \
        && log_info "  节点 ${node}: 已添加标签 ${GPU_LABEL}。" \
        || log_warn "  节点 ${node}: 标签添加失败。"
}

remove_gpu_label() {
    local node="$1"
    if kubectl get node "${node}" ${KC} -o jsonpath='{.metadata.labels}' 2>/dev/null \
            | grep -q "birentech.com"; then
        kubectl label node "${node}" "birentech.com-" ${KC} \
            && log_info "  节点 ${node}: 已移除 GPU 标签。" \
            || log_warn "  节点 ${node}: 移除 GPU 标签失败。"
    else
        log_info "  节点 ${node}: 无 GPU 标签，跳过。"
    fi
}

# ── 检查 plugin 目录完整性 ────────────────────────────────────────────────────
check_plugin_dir() {
    if [[ ! -d "${PLUGIN_DIR}" ]]; then
        die "device plugin 目录不存在: ${PLUGIN_DIR}
请将 plugin 所需文件放置在该目录下：
  *.tar                    — 镜像文件（如 k8s_device_plugin_*.tar）
  biren-device-plugin.yaml — DaemonSet 配置"
    fi
    local image_tar
    image_tar=$(find -L "${PLUGIN_DIR}" -maxdepth 1 -name "*.tar" ! -name "*.tar.gz" | head -1)
    if [[ -z "${image_tar}" ]]; then
        die "device plugin 目录中未找到镜像文件（*.tar）: ${PLUGIN_DIR}
请将镜像 tar 文件放置在该目录下。"
    fi
    if [[ ! -f "${PLUGIN_DIR}/biren-device-plugin.yaml" ]]; then
        die "device plugin 目录中未找到 biren-device-plugin.yaml: ${PLUGIN_DIR}
请将 DaemonSet 配置文件放置在该目录下。"
    fi
}

# ── 加载 device plugin 镜像（biren 模式）─────────────────────────────────────
load_plugin_image() {
    command_exists ctr || die "未找到 ctr（containerd CLI）。"
    check_plugin_dir

    local image_tar
    image_tar=$(find -L "${PLUGIN_DIR}" -maxdepth 1 -name "*.tar" ! -name "*.tar.gz" | head -1)

    local img_name
    img_name=$(tar -xOf "${image_tar}" manifest.json 2>/dev/null \
        | grep -oP '"RepoTags":\["\K[^"]+' | head -1)

    PLUGIN_IMAGE="${img_name}"
    [[ -n "${PLUGIN_IMAGE}" ]] || die "无法从镜像文件中读取镜像名: ${image_tar}"

    # 若镜像已存在则跳过导入
    if ctr -n k8s.io images ls 2>/dev/null | grep -q "${PLUGIN_IMAGE}"; then
        log_info "镜像已存在，跳过导入: ${PLUGIN_IMAGE}"
        return
    fi

    log_info "导入 device plugin 镜像: ${PLUGIN_IMAGE}"
    ctr -n k8s.io images import "${image_tar}" 2>&1 | tail -3
    log_info "镜像导入完成: ${PLUGIN_IMAGE}"
}

# ── 部署 / 更新 device plugin DaemonSet ──────────────────────────────────────
deploy_plugin() {
    log_info "部署 BirenTech device plugin..."

    local manifest
    manifest=$(mktemp /tmp/biren-plugin-XXXXXX.yaml)
    # shellcheck disable=SC2064
    trap "rm -f '${manifest}'" RETURN

    cp "${PLUGIN_DIR}/biren-device-plugin.yaml" "${manifest}"

    # 填入镜像名
    sed -i "s|image: *$|image: ${PLUGIN_IMAGE}|" "${manifest}"

    # Fix brml/brsmi hostPath: the yaml defaults to /usr/lib and /usr/bin, but those
    # are symlinks on this host pointing into /usr/local/birensupa/... via absolute paths.
    # Mounting the symlink-containing dir into the container leaves broken absolute symlinks;
    # mounting the resolved real dir gives the container actual .so files and binaries.
    local real_lib_dir
    real_lib_dir=$(dirname "$(realpath /usr/lib/libbiren-ml.so.1 2>/dev/null)" 2>/dev/null || true)
    if [[ -n "${real_lib_dir}" && "${real_lib_dir}" != "/usr/lib" ]]; then
        log_info "修正 brml volume hostPath: /usr/lib → ${real_lib_dir}"
        sed -i "s|path: /usr/lib$|path: ${real_lib_dir}|" "${manifest}"
    fi

    local real_brsmi_dir
    real_brsmi_dir=$(dirname "$(realpath "$(command -v brsmi 2>/dev/null)" 2>/dev/null)" 2>/dev/null || true)
    if [[ -n "${real_brsmi_dir}" && "${real_brsmi_dir}" != "/usr/bin" ]]; then
        log_info "修正 brsmi volume hostPath: /usr/bin → ${real_brsmi_dir}"
        sed -i "s|path: /usr/bin$|path: ${real_brsmi_dir}|" "${manifest}"
    fi

    # Enable propagation of brml/brsmi mounts into GPU-allocated pods (doc §7.2).
    if ! grep -q 'mount-host-path' "${manifest}"; then
        sed -i 's|"--container-runtime", "runc"\]|"--container-runtime", "runc", "--mount-host-path"]|' "${manifest}"
        log_info "已启用 --mount-host-path（GPU pod 内可用 brsmi）。"
    fi

    kubectl apply -f "${manifest}" ${KC}
    log_info "device plugin DaemonSet 已提交。"

    # 等待就绪
    log_info "等待 DaemonSet 就绪（最多 3 分钟）..."
    kubectl rollout status daemonset/biren-device-plugin-daemonset \
        -n "${PLUGIN_NAMESPACE}" --timeout=180s ${KC} 2>/dev/null \
        || log_warn "DaemonSet 未在 3 分钟内就绪，请手动检查。"
}

# ── 删除 device plugin（当所有 GPU 标签节点被移除后可选）────────────────────
_no_gpu_nodes_left() {
    local count
    count=$(kubectl get nodes ${KC} -l birentech.com=gpu \
        --no-headers 2>/dev/null | wc -l)
    [[ "${count}" -eq 0 ]]
}

# ── RuntimeClass 管理 ─────────────────────────────────────────────────────────
# handler 字段不可变更（immutable），需先删后建。
# biren 模式：handler: biren → containerd 使用 biren-container-runtime，
#             注入 /dev/biren-m 和分配的 /dev/biren/card_N，GPU 容器可正常运行。
# cpu/none 模式：集群内无 GPU 节点时恢复 handler: runc（标准容器运行时）。
_set_runtimeclass_handler() {
    local handler="$1"
    local current
    current=$(kubectl get runtimeclass biren ${KC} \
        -o jsonpath='{.handler}' 2>/dev/null || echo "")

    if [[ "${current}" == "${handler}" ]]; then
        log_info "  RuntimeClass 'biren' handler 已为 ${handler}，无需变更。"
        return
    fi

    if [[ -n "${current}" ]]; then
        kubectl delete runtimeclass biren ${KC} >/dev/null 2>&1 || true
    fi

    kubectl apply ${KC} -f - <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: biren
handler: ${handler}
EOF
    log_info "  RuntimeClass 'biren' handler 已设为: ${handler}。"
}

apply_biren_runtimeclass() {
    log_info "确保 RuntimeClass 'biren' 使用 biren-container-runtime..."
    _set_runtimeclass_handler biren
}

restore_runc_runtimeclass() {
    if _no_gpu_nodes_left; then
        log_info "集群中已无 GPU 节点，恢复 RuntimeClass 'biren' → handler: runc..."
        _set_runtimeclass_handler runc
    else
        log_info "集群中仍有其他 GPU 节点，RuntimeClass 保持 handler: biren。"
    fi
}

# ── HAMi-Biren 统一插件（--vgpu）──────────────────────────────────────────────
# 用 biren-hami-deviceplugin 取代原厂整卡 device plugin，并通过 Helm 安装 HAMi
# 调度器 + biren-mode-manager，使节点用同一套插件同时调度整卡 + SVI 硬切分
# （1/2、1/4）+ vGPU 软切分（mode-manager 按需动态切分 / 空闲回收）。

HAMI_HAMI_IMG=""   # hami/hami:biren-vgpu（调度器 extender + biren-mode-manager）
HAMI_DP_IMG=""     # biren-hami-deviceplugin:vgpu（设备插件）

_tar_image_name() { tar -xOf "$1" manifest.json 2>/dev/null | grep -oP '"RepoTags":\["\K[^"]+' | head -1; }

check_hami_bundle() {
    [[ -d "${HAMI_BUNDLE_DIR}" ]] || die "HAMi-Biren 安装包目录不存在: ${HAMI_BUNDLE_DIR}
请将 hami_br_deploy 安装包复制到该目录（见 packages/README.md）。"
    local f
    for f in images/hami-biren-vgpu.tar images/biren-hami-deviceplugin-vgpu.tar \
             chart/hami/Chart.yaml chart/values-biren-vgpu.yaml \
             deploy/biren-hami-deviceplugin.yaml kmd/br_vgpu_tool; do
        [[ -e "${HAMI_BUNDLE_DIR}/${f}" ]] || die "HAMi-Biren 安装包缺少文件: ${f}（位于 ${HAMI_BUNDLE_DIR}）"
    done
    HAMI_HAMI_IMG=$(_tar_image_name "${HAMI_BUNDLE_DIR}/images/hami-biren-vgpu.tar")
    HAMI_DP_IMG=$(_tar_image_name "${HAMI_BUNDLE_DIR}/images/biren-hami-deviceplugin-vgpu.tar")
    [[ -n "${HAMI_HAMI_IMG}" && -n "${HAMI_DP_IMG}" ]] \
        || die "无法从安装包镜像 tar 读取镜像名（images/*.tar）。"
    log_info "  HAMi 镜像:     ${HAMI_HAMI_IMG}"
    log_info "  设备插件镜像: ${HAMI_DP_IMG}"
}

ensure_helm() {
    if command_exists helm; then
        log_info "  helm 已安装: $(helm version --short 2>/dev/null || true)"
        return
    fi
    log_info "未找到 helm，下载 ${HELM_VERSION}（经 https_proxy=${https_proxy:-<未设置>}）..."
    local tmp; tmp=$(mktemp -d /tmp/helm-XXXXXX)
    # shellcheck disable=SC2064
    trap "rm -rf '${tmp}'" RETURN
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" -o "${tmp}/helm.tgz" \
        || die "下载 helm 失败；请手动安装 helm 后重试（或设置可用的 https_proxy）。"
    tar -xzf "${tmp}/helm.tgz" -C "${tmp}"
    install -m0755 "${tmp}/linux-amd64/helm" /usr/local/bin/helm
    log_info "  helm 已安装到 /usr/local/bin/helm: $(helm version --short 2>/dev/null || true)"
}

# kube-scheduler sidecar tag：默认探测 API server 版本（须与集群 k8s 小版本一致）。
_resolve_kube_scheduler_tag() {
    if [[ -n "${KUBE_SCHED_TAG}" ]]; then echo "${KUBE_SCHED_TAG}"; return; fi
    local v
    v=$(kubectl version -o json ${KC} 2>/dev/null \
        | python3 -c "import sys,json;print(json.load(sys.stdin)['serverVersion']['gitVersion'])" 2>/dev/null || true)
    echo "${v:-v1.30.0}"
}

# hami-scheduler 固定节点：默认取 control-plane 节点（必定缓存了 kube-scheduler 镜像）。
_resolve_scheduler_node() {
    if [[ -n "${HAMI_SCHEDULER_NODE}" ]]; then echo "${HAMI_SCHEDULER_NODE}"; return; fi
    kubectl get nodes ${KC} -l node-role.kubernetes.io/control-plane \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

_import_image_local() {   # tar img
    local tar="$1" img="$2"
    if ctr -n k8s.io images ls 2>/dev/null | grep -q "${img}"; then
        log_info "    镜像已存在，跳过: ${img}"
    else
        log_info "    导入镜像: ${img}"
        ctr -n k8s.io images import "${tar}" 2>&1 | tail -1
    fi
}

_warn_kmd() {   # version-string node-label
    local v="$1" where="$2"
    if [[ "${v}" == "1.12.0" ]]; then
        log_info "    ${where} KMD 版本 ${v} — vGPU 软切分可用。"
    else
        log_warn "    ${where} KMD 版本为 '${v:-未知}'（非 1.12.0）：整卡 + SVI 正常工作，"
        log_warn "    vGPU 软切分需手动加载与内核匹配的 1.12.0 KMD（kmd/biren.ko）后方可用。"
    fi
}

_prep_local_for_vgpu() {
    command_exists ctr || die "未找到 ctr（containerd CLI）。"
    log_info "  [本机] 准备节点 $(hostname -s)..."
    _import_image_local "${HAMI_BUNDLE_DIR}/images/hami-biren-vgpu.tar"            "${HAMI_HAMI_IMG}"
    _import_image_local "${HAMI_BUNDLE_DIR}/images/biren-hami-deviceplugin-vgpu.tar" "${HAMI_DP_IMG}"
    install -m0755 "${HAMI_BUNDLE_DIR}/kmd/br_vgpu_tool" /usr/local/bin/br_vgpu_tool
    log_info "    已安装 br_vgpu_tool → /usr/local/bin/br_vgpu_tool"
    _warn_kmd "$(cat /sys/module/biren/version 2>/dev/null || true)" "本机"
}

# 远端 ssh/scp：脚本经 sudo 以 root 运行时，root 通常没有到 worker 的免密配置，
# 故在 root 下降级为发起 sudo 的原始用户（SUDO_USER）执行，复用其 ~/.ssh/config 与密钥。
_ssh() {
    if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" ]]; then
        sudo -u "${SUDO_USER}" -H ssh "$@"
    else
        ssh "$@"
    fi
}
_scp() {
    if [[ ${EUID} -eq 0 && -n "${SUDO_USER:-}" ]]; then
        sudo -u "${SUDO_USER}" -H scp "$@"
    else
        scp "$@"
    fi
}

# 远端节点经 SSH 准备（远端需 NOPASSWD sudo）。任一步骤失败仅告警并跳过该节点，
# 不中断集群级安装。
_prep_remote_for_vgpu() {
    local node="$1" rdir="/tmp/hami-biren-prep"
    log_info "  [SSH] 准备远端节点 ${node}（ssh 以 ${SUDO_USER:-$(id -un)} 身份）..."
    if ! _ssh -o BatchMode=yes -o ConnectTimeout=10 "${node}" 'sudo -n true' >/dev/null 2>&1; then
        log_warn "  无法对 ${node} 执行免密 SSH+sudo，跳过自动准备。请在 ${node} 上手动执行 packages/hami-biren/images/load-images.sh，"
        log_warn "  并 install -m0755 kmd/br_vgpu_tool /usr/local/bin/br_vgpu_tool（vGPU 另需加载 1.12.0 KMD）。"
        return 0
    fi
    _ssh "${node}" "mkdir -p ${rdir}" || { log_warn "  ${node}: 创建临时目录失败，跳过。"; return 0; }
    local t img
    for pair in "hami-biren-vgpu.tar|${HAMI_HAMI_IMG}" "biren-hami-deviceplugin-vgpu.tar|${HAMI_DP_IMG}"; do
        t="${pair%%|*}"; img="${pair##*|}"
        if _ssh "${node}" "sudo -n ctr -n k8s.io images ls 2>/dev/null | grep -q '${img}'"; then
            log_info "    ${img} 已存在于 ${node}，跳过。"
            continue
        fi
        log_info "    传输并导入 ${img} → ${node}..."
        _scp -q "${HAMI_BUNDLE_DIR}/images/${t}" "${node}:${rdir}/" \
            && _ssh "${node}" "sudo -n ctr -n k8s.io images import ${rdir}/${t}" 2>&1 | tail -1 \
            || { log_warn "    ${node}: 导入 ${img} 失败，跳过该节点。"; return 0; }
    done
    _scp -q "${HAMI_BUNDLE_DIR}/kmd/br_vgpu_tool" "${node}:${rdir}/" \
        && _ssh "${node}" "sudo -n install -m0755 ${rdir}/br_vgpu_tool /usr/local/bin/br_vgpu_tool" \
        || { log_warn "    ${node}: 安装 br_vgpu_tool 失败，跳过。"; return 0; }
    log_info "    已在 ${node} 安装 br_vgpu_tool。"
    _warn_kmd "$(_ssh "${node}" 'cat /sys/module/biren/version 2>/dev/null' 2>/dev/null || true)" "${node}"
}

# 在单个节点上准备镜像 + br_vgpu_tool（mode-manager 以文件形式挂载该工具，必须先就位）。
prep_node_for_vgpu() {
    local node="$1" self
    self=$(hostname -s)
    if [[ "${node}" == "${self}" ]]; then
        _prep_local_for_vgpu
    else
        _prep_remote_for_vgpu "${node}"
    fi
}

# 删除原厂整卡 device plugin（与统一插件互斥：同一资源名只能由一个插件注册）。
remove_stock_plugin() {
    if kubectl get ds biren-device-plugin-daemonset -n "${PLUGIN_NAMESPACE}" ${KC} >/dev/null 2>&1; then
        log_info "  删除原厂整卡 device plugin（biren-device-plugin-daemonset），改由统一插件接管..."
        kubectl delete ds biren-device-plugin-daemonset -n "${PLUGIN_NAMESPACE}" ${KC} 2>/dev/null \
            || log_warn "  删除原厂 device plugin 失败，请手动检查（资源名冲突会导致计数异常）。"
    else
        log_info "  未发现原厂整卡 device plugin，跳过。"
    fi
}

# Helm 安装 HAMi 调度器 + biren-mode-manager，并部署 biren-hami-deviceplugin。
install_hami_bundle() {
    local sched_tag sched_node
    sched_tag=$(_resolve_kube_scheduler_tag)
    sched_node=$(_resolve_scheduler_node)
    log_info "  kube-scheduler sidecar 镜像: ${KUBE_SCHED_REGISTRY}/${KUBE_SCHED_REPO}:${sched_tag}"
    [[ -n "${sched_node}" ]] && log_info "  hami-scheduler 固定到节点: ${sched_node}"

    log_info "  Helm 安装/升级 HAMi（命名空间 ${HAMI_NAMESPACE}）..."
    local helm_args=(
        upgrade --install hami "${HAMI_BUNDLE_DIR}/chart/hami"
        -n "${HAMI_NAMESPACE}" --create-namespace
        -f "${HAMI_BUNDLE_DIR}/chart/values-biren-vgpu.yaml"
        --set "scheduler.kubeScheduler.image.registry=${KUBE_SCHED_REGISTRY}"
        --set "scheduler.kubeScheduler.image.repository=${KUBE_SCHED_REPO}"
        --set "scheduler.kubeScheduler.image.tag=${sched_tag}"
        --wait --timeout 5m
    )
    [[ -n "${sched_node}" ]] && helm_args+=(--set "scheduler.nodeName=${sched_node}")
    if ! KUBECONFIG="${KUBECONFIG}" helm "${helm_args[@]}"; then
        log_warn "  helm 未在超时内就绪，仍继续部署设备插件并在最后打印状态供排查。"
    fi

    log_info "  部署 biren-hami-deviceplugin..."
    local manifest
    manifest=$(mktemp /tmp/biren-hami-dp-XXXXXX.yaml)
    # shellcheck disable=SC2064
    trap "rm -f '${manifest}'" RETURN
    sed "s#image: biren-hami-deviceplugin:latest#image: ${HAMI_DP_IMG}#" \
        "${HAMI_BUNDLE_DIR}/deploy/biren-hami-deviceplugin.yaml" > "${manifest}"
    kubectl apply -f "${manifest}" ${KC}
    log_info "  等待 biren-hami-deviceplugin 就绪（最多 3 分钟）..."
    kubectl rollout status daemonset/biren-hami-deviceplugin -n "${PLUGIN_NAMESPACE}" \
        --timeout=180s ${KC} 2>/dev/null \
        || log_warn "  biren-hami-deviceplugin 未在 3 分钟内就绪，请手动检查。"
}

enable_vgpu() {
    log_info "── HAMi-Biren 统一插件（整卡 + SVI + vGPU）──"
    command_exists kubectl || die "未找到 kubectl。"
    check_hami_bundle
    ensure_helm

    # 1) 先打标签去污点，使 DaemonSet 可调度到目标节点
    for node in "${_NODES[@]}"; do
        remove_taint  "${node}"
        add_gpu_label "${node}"
    done
    # 2) 每节点导入镜像 + 安装 br_vgpu_tool（mode-manager 文件挂载，须先就位）
    for node in "${_NODES[@]}"; do
        prep_node_for_vgpu "${node}"
    done
    # 3) 移除原厂整卡插件，避免与统一插件资源名冲突
    remove_stock_plugin
    # 4) 集群级安装：HAMi 调度器 + biren-mode-manager + biren-hami-deviceplugin
    install_hami_bundle
}

# ── 打印当前节点状态 ──────────────────────────────────────────────────────────
print_status() {
    echo
    log_info "════════════════════════════════════════════════════"
    log_info "  节点算力角色切换完成（模式: ${MODE}）"
    log_info "════════════════════════════════════════════════════"
    echo
    kubectl get nodes -o wide ${KC} 2>/dev/null || true
    echo
    log_info "节点污点 / 标签详情:"
    for node in "${_NODES[@]}"; do
        echo "  ── ${node} ──"
        kubectl get node "${node}" ${KC} \
            -o custom-columns='TAINTS:.spec.taints,LABELS:.metadata.labels' \
            2>/dev/null | tail -1 || true
    done
    echo
    local rc_handler
    rc_handler=$(kubectl get runtimeclass biren ${KC} \
        -o jsonpath='{.handler}' 2>/dev/null || echo "未创建")
    log_info "RuntimeClass 'biren' handler: ${rc_handler}"
    echo
    if [[ "${MODE}" == "biren" ]]; then
        log_info "device plugin Pod 状态（命名空间 ${PLUGIN_NAMESPACE}）:"
        kubectl get pods -n "${PLUGIN_NAMESPACE}" -o wide ${KC} 2>/dev/null || true
        echo
        log_info "GPU allocatable（device plugin 启动后约 30s 刷新；SVI/vGPU 静态为 0，按需切分）:"
        kubectl get nodes ${KC} \
            -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.birentech\.com/gpu,1/2:.status.allocatable.birentech\.com/1-2-gpu,1/4:.status.allocatable.birentech\.com/1-4-gpu,VGPU:.status.allocatable.birentech\.com/vgpu' \
            2>/dev/null || true
        if [[ "${VGPU}" == true ]]; then
            echo
            log_info "HAMi 组件状态（命名空间 ${HAMI_NAMESPACE}：hami-scheduler + biren-mode-manager）:"
            kubectl get pods -n "${HAMI_NAMESPACE}" -o wide ${KC} 2>/dev/null || true
            echo
            log_info "统一插件已部署：同一套 biren-hami-deviceplugin 调度三种形态——"
            log_info "  · 整卡:  birentech.com/gpu"
            log_info "  · SVI:   birentech.com/1-2-gpu、birentech.com/1-4-gpu（mode-manager 动态切分）"
            log_info "  · vGPU:  birentech.com/vgpu + vgpu-cores + vgpu-memory（需节点加载 1.12.0 KMD）"
            log_info "  Pod 须指定 schedulerName: hami-scheduler（本部署未启用 webhook）。"
            log_info "  模板:  ${SCRIPT_DIR}/templates/biren-{whole-gpu,svi-half,svi-quarter,vgpu}.yaml"
            log_info "  验证:  sudo NODE=<节点> bash ${SCRIPT_DIR}/tests/test-unified-plugin.sh [all|whole|svi|vgpu]"
        fi
    fi
    log_info "════════════════════════════════════════════════════"
}

# ── 模式处理 ──────────────────────────────────────────────────────────────────
mode_none() {
    log_info "── 模式: none（恢复 control-plane 隔离）──"
    for node in "${_NODES[@]}"; do
        add_taint        "${node}"
        remove_gpu_label "${node}"
    done
    restore_runc_runtimeclass
}

mode_cpu() {
    log_info "── 模式: cpu（纯 CPU 算力节点）──"
    for node in "${_NODES[@]}"; do
        remove_taint     "${node}"
        remove_gpu_label "${node}"
    done
    restore_runc_runtimeclass
}

mode_biren() {
    # --vgpu: 部署 HAMi 统一插件（整卡 + SVI + vGPU），取代原厂整卡插件。
    if [[ "${VGPU}" == true ]]; then
        log_info "── 模式: biren --vgpu（HAMi 统一插件：整卡 + SVI + vGPU）──"
        enable_vgpu   # 内部完成 去污点/打标签 + 镜像/工具准备 + Helm 安装 + 设备插件部署
        return
    fi

    log_info "── 模式: biren（BirenTech GPU 算力节点，原厂整卡插件）──"
    load_plugin_image
    deploy_plugin
    apply_biren_runtimeclass

    for node in "${_NODES[@]}"; do
        remove_taint  "${node}"
        add_gpu_label "${node}"
    done
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
