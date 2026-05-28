#!/usr/bin/env bash
# 切换节点的算力角色
#
# 用法：
#   sudo ./set-node-mode.sh <mode> [节点名1,节点名2,...]
#
# mode 可选值：
#   cpu   去除 control-plane:NoSchedule 污点，节点以纯 CPU 算力参与调度
#   biren 去除污点，打 GPU 标签，部署 BirenTech device plugin，节点作为 GPU 算力节点
#   none  恢复 control-plane:NoSchedule 隔离污点，移出调度池
#
# 不指定节点时默认对本机 hostname 对应节点操作。
# 多节点用逗号分隔，如：node1,node2
#
# 环境变量（biren 模式需要）：
#   PLUGIN_DIR       device plugin 文件目录
#                    （默认 <脚本目录>/../../packages/biren，需包含 *.tar 镜像和 biren-device-plugin.yaml）
#   KUBECONFIG       kubectl 配置文件（默认 /etc/kubernetes/admin.conf）
#   PLUGIN_NAMESPACE device plugin 命名空间（默认 biren-gpu）
#
# 示例：
#   sudo ./set-node-mode.sh cpu                        # 本机作为 CPU 节点
#   sudo ./set-node-mode.sh biren                      # 本机作为 BirenTech GPU 节点
#   sudo ./set-node-mode.sh none                       # 恢复隔离
#   sudo ./set-node-mode.sh biren node1,node2          # 批量设为 GPU 节点

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

source "${LIB_DIR}/common.sh"

# ── 默认值 ────────────────────────────────────────────────────────────────────
: "${KUBECONFIG:=/etc/kubernetes/admin.conf}"
: "${PLUGIN_NAMESPACE:=biren-gpu}"
: "${PLUGIN_DIR:=${SCRIPT_DIR}/../../packages/biren}"
KC="--kubeconfig ${KUBECONFIG}"

CONTROL_PLANE_TAINT="node-role.kubernetes.io/control-plane:NoSchedule"
GPU_LABEL="birentech.com=gpu"

# ── 参数解析 ──────────────────────────────────────────────────────────────────
MODE="${1:-}"
NODE_ARG="${2:-}"

usage() {
    echo "用法: sudo $0 <cpu|biren|none> [节点名1,节点名2,...]"
    echo "  cpu   - 纯 CPU 算力节点"
    echo "  biren - BirenTech GPU 算力节点"
    echo "  none  - 恢复 control-plane 隔离"
    exit 1
}

[[ "${MODE}" == "cpu" || "${MODE}" == "biren" || "${MODE}" == "none" ]] \
    || usage

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
        log_info "device plugin Pod 状态:"
        kubectl get pods -n "${PLUGIN_NAMESPACE}" -o wide ${KC} 2>/dev/null || true
        echo
        log_info "GPU allocatable（需 device plugin 启动后约 30s 刷新）:"
        kubectl get nodes ${KC} \
            -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.birentech\.com/gpu' \
            2>/dev/null || true
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
    log_info "── 模式: biren（BirenTech GPU 算力节点）──"

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
