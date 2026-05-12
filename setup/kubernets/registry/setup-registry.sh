#!/usr/bin/env bash
# 在当前 Kubernetes 集群中部署私有 Registry（registry:2）
#
# 用法：
#   sudo ./setup-registry.sh [配置文件路径]
#   配置文件默认为同目录下的 registry.conf
#
# 功能：
#   1. 拉取 registry:2 镜像（优先本地，否则从公网）
#   2. 在 k8s 中部署 Registry Deployment + NodePort Service
#   3. 等待 Registry 就绪
#   4. 配置本机 containerd 信任并生成 registry-trust.conf
#
# 镜像导入/管理请使用 update_images.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"
source "${LIB_DIR}/common.sh"

CONFIG_FILE="${1:-${SCRIPT_DIR}/registry.conf}"

# ── 配置解析 ───────────────────────────────────────────────────────────────────
REGISTRY_STORAGE=/data/registry
REGISTRY_PORT=32000
REGISTRY_HTTP=true
REGISTRY_K8S_NAMESPACE=kube-system

parse_config() {
    [[ -f "${CONFIG_FILE}" ]] || die "配置文件不存在: ${CONFIG_FILE}"
    log_info "读取配置文件: ${CONFIG_FILE}"

    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ "${line}" =~ ^\[.*\]$ ]] && continue

        if [[ "${line}" =~ ^([A-Z_]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
            case "${key}" in
                REGISTRY_STORAGE)       REGISTRY_STORAGE="${val}"      ;;
                REGISTRY_PORT)          REGISTRY_PORT="${val}"          ;;
                REGISTRY_HTTP)          REGISTRY_HTTP="${val}"          ;;
                REGISTRY_K8S_NAMESPACE) REGISTRY_K8S_NAMESPACE="${val}" ;;
            esac
        fi
    done < "${CONFIG_FILE}"

    log_info "  存储路径 : ${REGISTRY_STORAGE}"
    log_info "  NodePort : ${REGISTRY_PORT}"
}

# ── 前置检查 ────────────────────────────────────────────────────────────────────
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"

preflight_check() {
    require_root
    command_exists kubectl || die "未找到 kubectl。"
    command_exists ctr     || die "未找到 ctr（containerd CLI）。"
    command_exists curl    || die "未找到 curl。"
    [[ -f "${KUBECONFIG}" ]] || die "kubeconfig 不存在: ${KUBECONFIG}"

    local retries=12 interval=5
    for ((i=1; i<=retries; i++)); do
        kubectl get nodes --kubeconfig "${KUBECONFIG}" &>/dev/null && break
        log_info "  等待 API Server... (${i}/${retries})"; sleep "${interval}"
        [[ $i -eq $retries ]] && die "API Server 无法访问。"
    done

    MASTER_IP=$(kubectl get nodes --kubeconfig "${KUBECONFIG}" \
        -l node-role.kubernetes.io/control-plane \
        -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
    [[ -n "${MASTER_IP}" ]] || \
        MASTER_IP=$(ip route show default 2>/dev/null \
            | awk '/default/{print $5}' | head -1 \
            | xargs -I{} ip -4 addr show {} 2>/dev/null \
            | awk '/inet /{split($2,a,"/"); print a[1]}' | head -1)
    [[ -n "${MASTER_IP}" ]] || die "无法检测 Master IP。"

    REGISTRY_ADDR="${MASTER_IP}:${REGISTRY_PORT}"
    log_info "  Registry 地址 : ${REGISTRY_ADDR}"
}

# ── 拉取 registry:2 镜像 ────────────────────────────────────────────────────────
REGISTRY_IMAGE="docker.io/library/registry:2"

pull_registry_image() {
    if ctr -n k8s.io images ls 2>/dev/null | grep -q "registry:2"; then
        log_info "registry:2 镜像已存在，跳过拉取。"
        return
    fi
    log_info "拉取 registry:2 镜像..."
    ctr -n k8s.io images pull "${REGISTRY_IMAGE}" \
        || die "registry:2 拉取失败，请检查网络或手动导入镜像。"
    log_info "registry:2 镜像已就绪。"
}

# ── 创建存储目录 ────────────────────────────────────────────────────────────────
create_storage_dir() {
    mkdir -p "${REGISTRY_STORAGE}"
    log_info "存储目录已就绪: ${REGISTRY_STORAGE}"
}

# ── 部署 Registry 到 k8s ────────────────────────────────────────────────────────
deploy_registry() {
    log_info "部署 Registry..."
    local node_name
    node_name=$(kubectl get nodes --kubeconfig "${KUBECONFIG}" \
        -l node-role.kubernetes.io/control-plane \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    kubectl apply --kubeconfig "${KUBECONFIG}" -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: ${REGISTRY_K8S_NAMESPACE}
  labels:
    app: registry
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      nodeName: ${node_name}
      tolerations:
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      containers:
      - name: registry
        image: ${REGISTRY_IMAGE}
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 5000
          name: registry
        env:
        - name: REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY
          value: /var/lib/registry
        - name: REGISTRY_HTTP_ADDR
          value: "0.0.0.0:5000"
        - name: REGISTRY_STORAGE_DELETE_ENABLED
          value: "true"
        volumeMounts:
        - name: storage
          mountPath: /var/lib/registry
        readinessProbe:
          httpGet:
            path: /v2/
            port: 5000
          initialDelaySeconds: 3
          periodSeconds: 5
      volumes:
      - name: storage
        hostPath:
          path: ${REGISTRY_STORAGE}
          type: DirectoryOrCreate
---
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: ${REGISTRY_K8S_NAMESPACE}
  labels:
    app: registry
spec:
  type: NodePort
  selector:
    app: registry
  ports:
  - name: registry
    port: 5000
    targetPort: 5000
    nodePort: ${REGISTRY_PORT}
EOF
    log_info "Registry 资源已提交。"
}

# ── 等待 Registry 就绪 ──────────────────────────────────────────────────────────
wait_for_registry() {
    log_info "等待 Registry Pod 就绪（最多 3 分钟）..."
    kubectl rollout status deployment/registry \
        -n "${REGISTRY_K8S_NAMESPACE}" \
        --kubeconfig "${KUBECONFIG}" \
        --timeout=180s \
        || die "Registry Pod 未就绪，请检查: kubectl get pods -n ${REGISTRY_K8S_NAMESPACE}"

    log_info "等待 Registry HTTP 端点可达..."
    local retries=24 interval=5
    for ((i=1; i<=retries; i++)); do
        curl -sf "http://${REGISTRY_ADDR}/v2/" &>/dev/null && {
            log_info "Registry 已就绪: http://${REGISTRY_ADDR}/v2/"
            return
        }
        log_info "  等待中... (${i}/${retries})"; sleep "${interval}"
    done
    die "Registry HTTP 端点无法访问: http://${REGISTRY_ADDR}/v2/"
}

# ── 配置本机 containerd 信任 + 生成 registry-trust.conf ────────────────────────
_write_hosts_toml() {
    local dest="$1" addr="$2" http="$3"
    local scheme; [[ "${http}" == "true" ]] && scheme="http" || scheme="https"
    cat > "${dest}" <<EOF
server = "${scheme}://${addr}"

[host."${scheme}://${addr}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF
}

TRUST_CONF_FILE=""

configure_trust() {
    local trust_dir="/etc/containerd/certs.d/${REGISTRY_ADDR}"
    log_info "配置 containerd 信任 Registry（${REGISTRY_ADDR}）..."
    mkdir -p "${trust_dir}"
    _write_hosts_toml "${trust_dir}/hosts.toml" "${REGISTRY_ADDR}" "${REGISTRY_HTTP}"
    log_info "containerd 信任配置已写入: ${trust_dir}/hosts.toml"

    TRUST_CONF_FILE="${SCRIPT_DIR}/registry-trust.conf"
    cat > "${TRUST_CONF_FILE}" <<EOF
# Registry 信任配置文件
# 由 setup-registry.sh 生成，供 registry-trust.sh 使用
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
TRUST_REGISTRY_ADDR=${REGISTRY_ADDR}
TRUST_HTTP=${REGISTRY_HTTP}
TRUST_GENERATED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF
    log_info "信任配置文件已生成: ${TRUST_CONF_FILE}"
}

# ── 打印汇总 ────────────────────────────────────────────────────────────────────
print_summary() {
    echo
    log_info "════════════════════════════════════════════════════════"
    log_info "  私有 Registry 部署完成！"
    log_info "════════════════════════════════════════════════════════"
    log_info "  地址    : http://${REGISTRY_ADDR}"
    log_info "  存储    : ${REGISTRY_STORAGE}"
    log_info "  Catalog : http://${REGISTRY_ADDR}/v2/_catalog"
    echo
    log_info "  信任配置文件 : ${TRUST_CONF_FILE}"
    log_info "  注入信任到节点（本机）  : sudo ./registry-trust.sh apply"
    log_info "  注入信任到远程节点      : sudo ./registry-trust.sh apply worker01,worker02"
    echo
    log_info "  导入/同步镜像 : sudo ./update_images.sh [add|purge|conf_gen]"
    log_info "  镜像配置文件  : $(dirname "${CONFIG_FILE}")/images.conf"
    log_info "════════════════════════════════════════════════════════"
}

# ── 主流程 ──────────────────────────────────────────────────────────────────────
main() {
    parse_config

    log_info "=== Step 1/5: 前置检查 ==="
    preflight_check

    log_info "=== Step 2/5: 拉取 registry:2 镜像 ==="
    pull_registry_image

    log_info "=== Step 3/5: 准备存储目录 ==="
    create_storage_dir

    log_info "=== Step 4/5: 部署 Registry 到 k8s ==="
    deploy_registry

    log_info "=== Step 5/5: 等待就绪 + 配置信任 ==="
    wait_for_registry
    configure_trust

    print_summary
}

main "$@"
