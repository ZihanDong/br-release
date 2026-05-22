#!/usr/bin/env bash
# Master 节点初始化脚本
# 前提：已在本机执行过 install.sh
#
# 用法：
#   sudo ./master.sh [选项]
#
# 环境变量（均可选）：
#   K8S_VERSION       Kubernetes 版本，需与 install.sh 保持一致（默认 1.30）
#   API_SERVER_ADDR   apiserver 对外广播的 IP（多网卡时必填，默认自动检测）
#   POD_CIDR          Pod 网段（默认 10.244.0.0/16）
#   SVC_CIDR          Service 网段（默认 10.96.0.0/12）
#   CNI_PLUGIN        CNI 插件：flannel（默认）/ calico / none
#   REGISTRY_MIRROR   镜像仓库镜像地址（国内环境推荐填写）
#   TOKEN_TTL         join token 有效期（默认 24h，填 0 表示永不过期）
#   JOIN_FILE         join 命令保存路径（默认 /root/k8s-join.sh）
#
# 示例：
#   # 最简单用法（自动检测本机 IP）：
#   sudo ./master.sh
#
#   # 指定 API server 地址和版本：
#   sudo K8S_VERSION=1.28 API_SERVER_ADDR=192.168.1.10 ./master.sh
#
#   # 国内环境（阿里云镜像 + Calico CNI）：
#   sudo REGISTRY_MIRROR=registry.aliyuncs.com/google_containers \
#        CNI_PLUGIN=calico ./master.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

source "${LIB_DIR}/common.sh"

# ── 默认值 ────────────────────────────────────────────────────────────────────
: "${K8S_VERSION:=1.30}"
: "${API_SERVER_ADDR:=}"
: "${POD_CIDR:=10.244.0.0/16}"
: "${SVC_CIDR:=10.96.0.0/12}"
: "${CNI_PLUGIN:=flannel}"
: "${REGISTRY_MIRROR:=}"
: "${TOKEN_TTL:=24h}"
: "${JOIN_FILE:=/root/k8s-join.sh}"

# kubeadm 要求完整三段版本号（如 1.30.0），将 "1.30" 规范化为 "1.30.0"
K8S_VERSION=$(normalise_version "${K8S_VERSION}")

export K8S_VERSION API_SERVER_ADDR POD_CIDR SVC_CIDR CNI_PLUGIN REGISTRY_MIRROR

# ── 前置检查 ──────────────────────────────────────────────────────────────────
preflight_check() {
    require_root

    command_exists kubeadm  || die "未找到 kubeadm，请先执行 install.sh"
    command_exists kubelet  || die "未找到 kubelet，请先执行 install.sh"
    command_exists kubectl  || die "未找到 kubectl，请先执行 install.sh"
    command_exists containerd || die "未找到 containerd，请先执行 install.sh"

    systemctl is-active containerd &>/dev/null \
        || die "containerd 服务未运行，请检查: systemctl status containerd"

    # 若已初始化过则终止，避免重复 init
    if [[ -f /etc/kubernetes/admin.conf ]]; then
        log_warn "检测到 /etc/kubernetes/admin.conf 已存在，集群可能已初始化。"
        log_warn "如需重新初始化，请先执行: sudo kubeadm reset -f"
        die "中止，避免重复初始化。"
    fi
}

# ── 修复 containerd sandbox_image（当 install.sh 未传 REGISTRY_MIRROR 时）────
# 若 REGISTRY_MIRROR 已设置，但 containerd 配置中的 sandbox_image 仍指向
# registry.k8s.io，则在 kubeadm init 之前重新修正，避免 kubelet 无法拉取 pause 镜像。
patch_sandbox_image() {
    [[ -z "${REGISTRY_MIRROR}" ]] && return
    local cfg=/etc/containerd/config.toml
    [[ -f "${cfg}" ]] || return

    if grep -q 'sandbox_image.*registry\.k8s\.io' "${cfg}" 2>/dev/null; then
        # Derive pause version from K8S_VERSION (same logic as container_runtime libs)
        local pause_ver="3.9"
        if   version_gte "${K8S_VERSION}" "1.27"; then pause_ver="3.9"
        elif version_gte "${K8S_VERSION}" "1.25"; then pause_ver="3.8"
        elif version_gte "${K8S_VERSION}" "1.24"; then pause_ver="3.7"
        elif version_gte "${K8S_VERSION}" "1.22"; then pause_ver="3.6"
        else                                           pause_ver="3.5"
        fi
        local pause_image="${REGISTRY_MIRROR}/pause:${pause_ver}"
        log_info "修正 containerd sandbox_image → ${pause_image}"
        cp -p "${cfg}" "${cfg}.bak.$(date +%s)"
        sed -i "s|sandbox_image = .*|sandbox_image = \"${pause_image}\"|g" "${cfg}"
        systemctl restart containerd
        log_info "containerd 已重启，sandbox_image 修正完成。"
    fi
}

# ── 自动检测本机 IP ───────────────────────────────────────────────────────────
detect_api_server_addr() {
    [[ -n "${API_SERVER_ADDR}" ]] && return

    # 优先取默认路由出口的 IP
    local iface ip
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
    if [[ -n "${iface}" ]]; then
        ip=$(ip -4 addr show "${iface}" 2>/dev/null \
            | awk '/inet / {split($2,a,"/"); print a[1]}' | head -1)
    fi

    # fallback: hostname -I 第一个非 127 地址
    if [[ -z "${ip}" ]]; then
        ip=$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^127\.' | head -1)
    fi

    [[ -n "${ip}" ]] || die "无法自动检测本机 IP，请手动设置 API_SERVER_ADDR=<ip>"
    API_SERVER_ADDR="${ip}"
    log_info "自动检测到 API Server 地址: ${API_SERVER_ADDR}"
}

# ── 拉取控制面镜像 ────────────────────────────────────────────────────────────
pull_images() {
    log_info "预拉取控制面镜像（可能需要几分钟）..."
    local pull_args=()
    [[ -n "${K8S_VERSION}"    ]] && pull_args+=(--kubernetes-version "${K8S_VERSION}")
    [[ -n "${REGISTRY_MIRROR}" ]] && pull_args+=(--image-repository "${REGISTRY_MIRROR}")

    kubeadm config images pull "${pull_args[@]}" \
        --cri-socket=unix:///run/containerd/containerd.sock \
        2>&1 | tee /tmp/kubeadm-pull.log \
        || log_warn "部分镜像拉取失败，kubeadm init 阶段会重试。"
}

# ── kubeadm init ──────────────────────────────────────────────────────────────
run_kubeadm_init() {
    log_info "初始化 Kubernetes 控制面..."

    local init_args=(
        --apiserver-advertise-address="${API_SERVER_ADDR}"
        --pod-network-cidr="${POD_CIDR}"
        --service-cidr="${SVC_CIDR}"
        --cri-socket=unix:///run/containerd/containerd.sock
    )
    [[ -n "${K8S_VERSION}"     ]] && init_args+=(--kubernetes-version "${K8S_VERSION}")
    [[ -n "${REGISTRY_MIRROR}" ]] && init_args+=(--image-repository "${REGISTRY_MIRROR}")

    kubeadm init "${init_args[@]}" 2>&1 | tee /tmp/kubeadm-init.log

    grep -q "Your Kubernetes control-plane has initialized successfully" /tmp/kubeadm-init.log \
        || die "kubeadm init 失败，详见 /tmp/kubeadm-init.log"

    log_info "控制面初始化成功。"
}

# ── 配置 kubeconfig ───────────────────────────────────────────────────────────
setup_kubeconfig() {
    local target_user="${SUDO_USER:-root}"
    local home_dir
    home_dir=$(getent passwd "${target_user}" | cut -d: -f6)
    local kube_dir="${home_dir}/.kube"

    mkdir -p "${kube_dir}"
    cp /etc/kubernetes/admin.conf "${kube_dir}/config"
    chown -R "${target_user}:$(id -gn "${target_user}")" "${kube_dir}"

    # 让当前 root 会话也能用 kubectl
    export KUBECONFIG=/etc/kubernetes/admin.conf

    log_info "kubeconfig 已写入: ${kube_dir}/config（所有者: ${target_user}）"
}

# ── 等待控制面就绪 ────────────────────────────────────────────────────────────
wait_for_control_plane() {
    log_info "等待控制面组件就绪..."
    local retries=30 interval=6

    for ((i=1; i<=retries; i++)); do
        if kubectl get nodes --kubeconfig /etc/kubernetes/admin.conf \
                &>/dev/null 2>&1; then
            log_info "API Server 可访问。"
            break
        fi
        log_info "  等待中... (${i}/${retries})"
        sleep "${interval}"
    done

    # 等待 kube-system 核心 Pod 就绪
    log_info "等待 kube-system 核心 Pod 就绪（最多等 3 分钟）..."
    kubectl wait --for=condition=Ready pod \
        -l tier=control-plane \
        -n kube-system \
        --timeout=180s \
        --kubeconfig /etc/kubernetes/admin.conf 2>/dev/null || true
}

# ── 安装 CNI ──────────────────────────────────────────────────────────────────
install_cni() {
    local kc="--kubeconfig /etc/kubernetes/admin.conf"

    case "${CNI_PLUGIN}" in
        flannel)
            log_info "安装 Flannel CNI（Pod CIDR: ${POD_CIDR}）..."
            # 下载 manifest 并替换 CIDR（保证与 kubeadm init 一致）
            curl -fsSL --retry 3 \
                https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml \
                -o /tmp/kube-flannel.yml
            sed -i "s|10\.244\.0\.0/16|${POD_CIDR}|g" /tmp/kube-flannel.yml
            kubectl apply -f /tmp/kube-flannel.yml ${kc}
            ;;
        calico)
            log_info "安装 Calico CNI..."
            curl -fsSL --retry 3 \
                https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml \
                -o /tmp/calico.yaml
            # 如果自定义了 POD_CIDR 则写入 calico 配置
            if [[ "${POD_CIDR}" != "192.168.0.0/16" ]]; then
                sed -i "s|# - name: CALICO_IPV4POOL_CIDR|- name: CALICO_IPV4POOL_CIDR|" /tmp/calico.yaml
                sed -i "s|#   value: \"192\.168\.0\.0/16\"|  value: \"${POD_CIDR}\"|"  /tmp/calico.yaml
            fi
            kubectl apply -f /tmp/calico.yaml ${kc}
            ;;
        none)
            log_warn "CNI_PLUGIN=none，跳过 CNI 安装，节点将保持 NotReady 直到手动安装 CNI。"
            ;;
        *)
            log_warn "未知 CNI_PLUGIN='${CNI_PLUGIN}'，跳过。请手动安装 CNI 插件。"
            ;;
    esac
}

# ── 生成 join 命令并保存 ──────────────────────────────────────────────────────
generate_join_file() {
    log_info "生成 Worker 节点 join 命令..."

    # 重新生成 token（支持自定义 TTL）
    local token
    token=$(kubeadm token create --ttl "${TOKEN_TTL}" 2>/dev/null)

    # 获取 CA 证书哈希
    local ca_hash
    ca_hash=$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt \
        | openssl rsa -pubin -outform der 2>/dev/null \
        | openssl dgst -sha256 -hex \
        | awk '{print $2}')

    # API Server 端点
    local endpoint="${API_SERVER_ADDR}:6443"

    # 写入 join 脚本
    cat > "${JOIN_FILE}" <<EOF
#!/usr/bin/env bash
# Worker 节点加入集群的命令
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
# Token 有效期: ${TOKEN_TTL}（0=永不过期）
# Master IP: ${API_SERVER_ADDR}
#
# 使用方法：在每个 Worker 节点上执行：
#   sudo bash $(basename "${JOIN_FILE}")
# 或者直接执行下方 kubeadm join 命令。

set -euo pipefail

kubeadm join ${endpoint} \\
    --token ${token} \\
    --discovery-token-ca-cert-hash sha256:${ca_hash} \\
    --cri-socket unix:///run/containerd/containerd.sock
EOF
    chmod 600 "${JOIN_FILE}"

    log_info "join 命令已保存至: ${JOIN_FILE}"
}


# ── 打印最终状态 ──────────────────────────────────────────────────────────────
print_summary() {
    local kc="--kubeconfig /etc/kubernetes/admin.conf"

    echo
    log_info "════════════════════════════════════════════════════════"
    log_info "  Master 节点初始化完成！"
    log_info "════════════════════════════════════════════════════════"
    echo
    kubectl get nodes -o wide ${kc} 2>/dev/null || true
    echo
    kubectl get pods -n kube-system ${kc} 2>/dev/null || true
    echo
    log_info "join 命令文件: ${JOIN_FILE}"
    log_info "  → 将该文件复制到每个 Worker 节点，执行: sudo bash $(basename "${JOIN_FILE}")"
    log_info "  → 或直接使用 join.sh 脚本（自动读取该文件）"
    echo
    log_info "节点算力角色切换（初始为 control-plane 隔离状态）："
    log_info "  纯 CPU 节点  : sudo ./set-node-mode.sh cpu"
    log_info "  BirenTech GPU: sudo ./set-node-mode.sh biren"
    log_info "  恢复隔离     : sudo ./set-node-mode.sh none"
    echo
    log_info "后续常用命令："
    log_info "  查看节点状态  : kubectl get nodes -o wide"
    log_info "  查看系统 Pod  : kubectl get pods -n kube-system"
    log_info "  重新生成 token: kubeadm token create --print-join-command"
    log_info "════════════════════════════════════════════════════════"
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
    detect_os
    preflight_check
    detect_api_server_addr
    patch_sandbox_image

    log_info "=== Step 1/5: 拉取控制面镜像 ==="
    pull_images

    log_info "=== Step 2/5: kubeadm init ==="
    run_kubeadm_init

    log_info "=== Step 3/5: 配置 kubeconfig ==="
    setup_kubeconfig

    log_info "=== Step 4/5: 安装 CNI 插件 ==="
    wait_for_control_plane
    install_cni

    log_info "=== Step 5/5: 生成 join 命令 ==="
    generate_join_file

    print_summary
}

main "$@"
