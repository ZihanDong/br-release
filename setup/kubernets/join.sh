#!/usr/bin/env bash
# 节点加入集群脚本（支持 worker / cpu / biren 三种算力角色）
#
# 用法：
#   sudo ./join.sh <mode> [选项]
#
# mode 可选值：
#   worker  加入为标准 worker 节点，参与 CPU 调度（默认）
#   cpu     同 worker，明确声明为纯 CPU 算力节点
#   biren   加入为 BirenTech GPU 算力节点，自动导入 device plugin 镜像并打 GPU 标签
#
# Join 参数来源（三种方式按优先级自动选择）：
#   方式一：JOIN_FILE 文件（默认 /root/k8s-join.sh，由 master.sh 生成）
#   方式二：环境变量 MASTER_IP + JOIN_TOKEN + CA_CERT_HASH
#   方式三：交互式输入
#
# 通用可选变量：
#   JOIN_FILE     join 文件路径（默认 /root/k8s-join.sh）
#   MASTER_IP     Master IP
#   MASTER_PORT   API Server 端口（默认 6443）
#   JOIN_TOKEN    kubeadm token
#   CA_CERT_HASH  CA 证书哈希（sha256:...）
#   NODE_NAME     覆盖本机 hostname 作为节点名
#   NODE_LABELS   追加标签，逗号分隔，如 "zone=cn-east,rack=01"
#   NODE_TAINTS   追加 taint，逗号分隔，如 "gpu=true:NoSchedule"
#
# biren 模式额外变量：
#   PLUGIN_DIR   device plugin 文件目录
#                （默认 <脚本目录>/../../packages/biren，需包含 *.tar 镜像和 biren-device-plugin.yaml）
#   KUBECONFIG   管理员 kubeconfig，用于首次部署 DaemonSet
#                （默认 /etc/kubernetes/admin.conf；若不存在则跳过 DaemonSet 部署，
#                  假设 master 已通过 set-node-mode.sh biren 完成首次部署）
#
# 示例：
#   sudo ./join.sh worker                         # 标准 CPU worker
#   sudo ./join.sh cpu                            # 同上，明确 CPU 角色
#   sudo ./join.sh biren                          # GPU worker，读取默认 join 文件
#   sudo MASTER_IP=192.168.1.10 \
#        JOIN_TOKEN=abc.xyz \
#        CA_CERT_HASH=sha256:xxx \
#        ./join.sh biren                          # GPU worker，环境变量传参

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

source "${LIB_DIR}/common.sh"

# ── 参数解析 ──────────────────────────────────────────────────────────────────
MODE="${1:-worker}"
case "${MODE}" in
    worker|cpu|biren) ;;
    *)
        log_error "未知模式: ${MODE}"
        echo "用法: sudo $0 <worker|cpu|biren> [选项]"
        exit 1
        ;;
esac

# ── 默认值 ────────────────────────────────────────────────────────────────────
: "${JOIN_FILE:=/root/k8s-join.sh}"
: "${MASTER_IP:=}"
: "${MASTER_PORT:=6443}"
: "${JOIN_TOKEN:=}"
: "${CA_CERT_HASH:=}"
: "${NODE_NAME:=}"
: "${NODE_LABELS:=}"
: "${NODE_TAINTS:=}"
: "${PLUGIN_DIR:=${SCRIPT_DIR}/../../packages/biren}"
: "${KUBECONFIG:=/etc/kubernetes/admin.conf}"
: "${PLUGIN_NAMESPACE:=biren-gpu}"

# ── 前置检查 ──────────────────────────────────────────────────────────────────
preflight_check() {
    require_root
    detect_os

    command_exists kubeadm    || die "未找到 kubeadm，请先执行 install.sh"
    command_exists kubelet    || die "未找到 kubelet，请先执行 install.sh"
    command_exists containerd || die "未找到 containerd，请先执行 install.sh"

    systemctl is-active containerd &>/dev/null \
        || die "containerd 服务未运行，请检查: systemctl status containerd"

    if [[ -f /etc/kubernetes/kubelet.conf ]]; then
        log_warn "检测到 /etc/kubernetes/kubelet.conf 已存在，节点可能已加入集群。"
        log_warn "如需重新加入，请先执行: sudo kubeadm reset -f"
        die "中止，避免重复加入。"
    fi

    if [[ "${MODE}" == "biren" ]]; then
        command_exists ctr || die "biren 模式需要 ctr（containerd CLI），请确认 containerd 已安装。"
        _check_plugin_dir
    fi
}

# ── 解析 join 参数 ────────────────────────────────────────────────────────────
resolve_join_params() {
    if [[ -f "${JOIN_FILE}" ]] && grep -q "kubeadm join" "${JOIN_FILE}"; then
        log_info "从 join 文件读取参数: ${JOIN_FILE}"
        _parse_join_file
        return
    fi

    if [[ -n "${MASTER_IP}" && -n "${JOIN_TOKEN}" && -n "${CA_CERT_HASH}" ]]; then
        log_info "从环境变量读取 join 参数。"
        return
    fi

    log_warn "未找到 join 文件（${JOIN_FILE}），且环境变量不完整，进入交互输入模式..."
    _interactive_input
}

_parse_join_file() {
    local endpoint token ca_hash
    endpoint=$(grep -oP '(?<=kubeadm join )\S+' "${JOIN_FILE}" | head -1)
    token=$(grep -oP '(?<=--token )\S+' "${JOIN_FILE}" | head -1)
    ca_hash=$(grep -oP '(?<=--discovery-token-ca-cert-hash )\S+' "${JOIN_FILE}" | head -1)

    [[ -n "${endpoint}" ]] || die "join 文件中未找到 endpoint，文件格式不正确。"
    [[ -n "${token}"    ]] || die "join 文件中未找到 --token。"
    [[ -n "${ca_hash}"  ]] || die "join 文件中未找到 --discovery-token-ca-cert-hash。"

    MASTER_IP="${endpoint%%:*}"
    MASTER_PORT="${endpoint##*:}"
    JOIN_TOKEN="${token}"
    CA_CERT_HASH="${ca_hash}"

    log_info "  Master 端点 : ${MASTER_IP}:${MASTER_PORT}"
    log_info "  Token       : ${JOIN_TOKEN:0:6}...（已截断）"
}

_interactive_input() {
    read -rp "Master IP 地址: " MASTER_IP
    read -rp "API Server 端口 [6443]: " _port
    MASTER_PORT="${_port:-6443}"
    read -rp "Join Token: " JOIN_TOKEN
    read -rp "CA Cert Hash (sha256:...): " CA_CERT_HASH

    [[ -n "${MASTER_IP}"    ]] || die "Master IP 不能为空。"
    [[ -n "${JOIN_TOKEN}"   ]] || die "Join Token 不能为空。"
    [[ -n "${CA_CERT_HASH}" ]] || die "CA Cert Hash 不能为空。"
}

# ── 执行 kubeadm join ─────────────────────────────────────────────────────────
run_kubeadm_join() {
    log_info "加入集群: ${MASTER_IP}:${MASTER_PORT}（角色: ${MODE}）..."

    local join_args=(
        "${MASTER_IP}:${MASTER_PORT}"
        --token "${JOIN_TOKEN}"
        --discovery-token-ca-cert-hash "${CA_CERT_HASH}"
        --cri-socket unix:///run/containerd/containerd.sock
    )
    [[ -n "${NODE_NAME}" ]] && join_args+=(--node-name "${NODE_NAME}")

    kubeadm join "${join_args[@]}" 2>&1 | tee /tmp/kubeadm-join.log

    grep -q "This node has joined the cluster" /tmp/kubeadm-join.log \
        || die "kubeadm join 失败，详见 /tmp/kubeadm-join.log"

    log_info "节点成功加入集群。"
}

# ── 等待本节点 Ready ──────────────────────────────────────────────────────────
wait_for_node_ready() {
    log_info "等待本节点进入 Ready 状态（最多 3 分钟）..."
    local retries=36 interval=5
    local node_name="${NODE_NAME:-$(hostname -s)}"

    for ((i=1; i<=retries; i++)); do
        local status
        status=$(kubectl get node "${node_name}" \
            --kubeconfig /etc/kubernetes/kubelet.conf \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        if [[ "${status}" == "True" ]]; then
            log_info "节点 ${node_name} 已 Ready。"
            return 0
        fi
        log_info "  等待中... (${i}/${retries}，当前状态: ${status:-Unknown})"
        sleep "${interval}"
    done

    log_warn "超时：节点未在预期时间内 Ready，请检查 CNI 插件是否已在 Master 上安装。"
}

# ── 设置 worker / cpu 角色的标签和 Taint ─────────────────────────────────────
apply_worker_role() {
    [[ -z "${NODE_LABELS}" && -z "${NODE_TAINTS}" ]] && return

    local node_name="${NODE_NAME:-$(hostname -s)}"
    local kc="--kubeconfig /etc/kubernetes/kubelet.conf"

    if [[ -n "${NODE_LABELS}" ]]; then
        log_info "为节点添加自定义标签: ${NODE_LABELS}"
        IFS=',' read -ra labels <<< "${NODE_LABELS}"
        kubectl label node "${node_name}" "${labels[@]}" ${kc} --overwrite 2>/dev/null \
            || log_warn "标签设置失败（权限不足，可在 Master 上手动执行）"
    fi

    if [[ -n "${NODE_TAINTS}" ]]; then
        log_info "为节点添加 Taint: ${NODE_TAINTS}"
        IFS=',' read -ra taints <<< "${NODE_TAINTS}"
        kubectl taint node "${node_name}" "${taints[@]}" ${kc} 2>/dev/null \
            || log_warn "Taint 设置失败（权限不足，可在 Master 上手动执行）"
    fi
}

# ── 设置 biren 角色 ───────────────────────────────────────────────────────────
apply_biren_role() {
    local node_name="${NODE_NAME:-$(hostname -s)}"

    # 1. 在本机导入 device plugin 镜像
    _load_plugin_image

    # 2. 为本节点打 GPU 标签
    #    优先用 admin.conf（权限充足），否则用 kubelet.conf（kubelet 可 patch 自身节点）
    local kc
    if [[ -f "${KUBECONFIG}" ]]; then
        kc="--kubeconfig ${KUBECONFIG}"
    else
        kc="--kubeconfig /etc/kubernetes/kubelet.conf"
        log_warn "未找到 ${KUBECONFIG}，使用 kubelet.conf 标记节点（DaemonSet 部署需在 Master 上执行）"
    fi

    kubectl label node "${node_name}" birentech.com=gpu ${kc} --overwrite \
        && log_info "节点 ${node_name} 已标记为 GPU 节点（birentech.com=gpu）" \
        || log_warn "GPU 标签设置失败，请在 Master 上执行: kubectl label node ${node_name} birentech.com=gpu"

    # 追加用户自定义标签
    apply_worker_role

    # 3. 部署/确认 DaemonSet（需要 admin 权限）
    if [[ -f "${KUBECONFIG}" ]]; then
        _deploy_plugin_daemonset
    else
        log_warn "跳过 DaemonSet 部署（无 admin.conf）。"
        log_warn "请在 Master 上执行以下命令完成首次 DaemonSet 部署："
        log_warn "  sudo ./set-node-mode.sh biren ${node_name}"
    fi
}

# ── 检查 plugin 目录完整性 ────────────────────────────────────────────────────
_check_plugin_dir() {
    if [[ ! -d "${PLUGIN_DIR}" ]]; then
        die "device plugin 目录不存在: ${PLUGIN_DIR}
请将 plugin 所需文件放置在该目录下：
  *.tar                   — 镜像文件（如 k8s_device_plugin_*.tar）
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

# ── 导入 device plugin 镜像到本地 containerd ─────────────────────────────────
_load_plugin_image() {
    local image_tar
    image_tar=$(find -L "${PLUGIN_DIR}" -maxdepth 1 -name "*.tar" ! -name "*.tar.gz" | head -1)

    local img_name
    img_name=$(tar -xOf "${image_tar}" manifest.json 2>/dev/null \
        | grep -oP '"RepoTags":\["\K[^"]+' | head -1)

    PLUGIN_IMAGE="${img_name}"
    [[ -n "${PLUGIN_IMAGE}" ]] || die "无法从镜像文件中读取镜像名: ${image_tar}"

    if ctr -n k8s.io images ls 2>/dev/null | grep -q "${PLUGIN_IMAGE}"; then
        log_info "device plugin 镜像已存在，跳过导入: ${PLUGIN_IMAGE}"
        return
    fi

    log_info "导入 device plugin 镜像: ${PLUGIN_IMAGE}"
    ctr -n k8s.io images import "${image_tar}" 2>&1 | tail -3
    log_info "镜像导入完成: ${PLUGIN_IMAGE}"
}

# ── 部署 device plugin DaemonSet（幂等）──────────────────────────────────────
_deploy_plugin_daemonset() {
    log_info "部署/更新 BirenTech device plugin DaemonSet..."

    local manifest
    manifest=$(mktemp /tmp/biren-plugin-XXXXXX.yaml)
    # shellcheck disable=SC2064
    trap "rm -f '${manifest}'" RETURN

    cp "${PLUGIN_DIR}/biren-device-plugin.yaml" "${manifest}"

    sed -i "s|image: *$|image: ${PLUGIN_IMAGE}|" "${manifest}"

    # 修正 brml volume hostPath（解决绝对符号链接在容器内断裂问题）
    local real_lib_dir
    real_lib_dir=$(dirname "$(realpath /usr/lib/libbiren-ml.so.1 2>/dev/null)" 2>/dev/null || true)
    if [[ -n "${real_lib_dir}" && "${real_lib_dir}" != "/usr/lib" ]]; then
        log_info "修正 brml volume hostPath: /usr/lib → ${real_lib_dir}"
        sed -i "s|path: /usr/lib$|path: ${real_lib_dir}|" "${manifest}"
    fi

    kubectl apply -f "${manifest}" --kubeconfig "${KUBECONFIG}"
    log_info "DaemonSet 已提交。"
}

# ── 打印最终状态 ──────────────────────────────────────────────────────────────
print_summary() {
    local node_name="${NODE_NAME:-$(hostname -s)}"
    echo
    log_info "════════════════════════════════════════════════════════"
    log_info "  节点加入完成！"
    log_info "  节点名称: ${node_name}"
    log_info "  Master  : ${MASTER_IP}:${MASTER_PORT}"
    log_info "  角色    : ${MODE}"
    log_info "════════════════════════════════════════════════════════"
    echo
    log_info "在 Master 节点上验证:"
    log_info "  kubectl get nodes -o wide"
    log_info "  kubectl describe node ${node_name}"
    if [[ "${MODE}" == "biren" ]]; then
        log_info "  kubectl get pods -n ${PLUGIN_NAMESPACE} -o wide"
        log_info "  kubectl get node ${node_name} -o jsonpath='{.status.allocatable}'"
    fi
    log_info "────────────────────────────────────────────────────────"
    log_info "后续切换节点角色（在 Master 上执行）："
    log_info "  纯 CPU 节点  : sudo ./set-node-mode.sh cpu  ${node_name}"
    log_info "  BirenTech GPU: sudo ./set-node-mode.sh biren ${node_name}"
    log_info "  恢复隔离     : sudo ./set-node-mode.sh none  ${node_name}"
    log_info "════════════════════════════════════════════════════════"
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
    log_info "节点加入模式: ${MODE}"
    preflight_check
    resolve_join_params

    log_info "=== Step 1/3: 执行 kubeadm join ==="
    run_kubeadm_join

    log_info "=== Step 2/3: 等待节点就绪 ==="
    wait_for_node_ready

    log_info "=== Step 3/3: 配置节点角色（${MODE}）==="
    case "${MODE}" in
        worker|cpu) apply_worker_role ;;
        biren)      apply_biren_role  ;;
    esac

    print_summary
}

main "$@"
