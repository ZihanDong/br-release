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
#   3. 配置本机 containerd 信任该 Registry（HTTP）
#   4. 按命名空间导入镜像并推送（<addr>/<namespace>/<image>:<tag>）
#   5. 生成信任配置文件（registry-trust.conf）供其他节点使用

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

# 命名空间 → 路径列表的关联数组
declare -A NS_PATHS   # NS_PATHS[ns]="path1\npath2\n..."
declare -a NS_ORDER   # 保持声明顺序

parse_config() {
    [[ -f "${CONFIG_FILE}" ]] || die "配置文件不存在: ${CONFIG_FILE}"
    log_info "读取配置文件: ${CONFIG_FILE}"

    local cur_ns=""
    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue

        # 命名空间节标记 [namespace.<name>]
        if [[ "${line}" =~ ^\[namespace\.([a-zA-Z0-9_-]+)\]$ ]]; then
            cur_ns="${BASH_REMATCH[1]}"
            if [[ -z "${NS_PATHS[${cur_ns}]+x}" ]]; then
                NS_ORDER+=("${cur_ns}")
                NS_PATHS["${cur_ns}"]=""
            fi
            continue
        fi

        # 未知节标记（跳过）
        if [[ "${line}" =~ ^\[.*\]$ ]]; then
            cur_ns=""
            continue
        fi

        # 键值对（节外）
        if [[ -z "${cur_ns}" && "${line}" =~ ^([A-Z_]+)=(.*)$ ]]; then
            local key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
            case "${key}" in
                REGISTRY_STORAGE)       REGISTRY_STORAGE="${val}"      ;;
                REGISTRY_PORT)          REGISTRY_PORT="${val}"          ;;
                REGISTRY_HTTP)          REGISTRY_HTTP="${val}"          ;;
                REGISTRY_K8S_NAMESPACE) REGISTRY_K8S_NAMESPACE="${val}" ;;
            esac
            continue
        fi

        # 节内路径
        [[ -n "${cur_ns}" ]] && NS_PATHS["${cur_ns}"]+="${line}"$'\n'
    done < "${CONFIG_FILE}"

    log_info "  存储路径       : ${REGISTRY_STORAGE}"
    log_info "  NodePort       : ${REGISTRY_PORT}"
    log_info "  镜像命名空间   : ${NS_ORDER[*]:-（未定义）}"
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
    log_info "  Registry 地址  : ${REGISTRY_ADDR}"
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

# ── 配置本机 containerd 信任 ────────────────────────────────────────────────────
configure_containerd_trust() {
    local trust_dir="/etc/containerd/certs.d/${REGISTRY_ADDR}"
    log_info "配置 containerd 信任 Registry（${REGISTRY_ADDR}）..."
    mkdir -p "${trust_dir}"
    _write_hosts_toml "${trust_dir}/hosts.toml" "${REGISTRY_ADDR}" "${REGISTRY_HTTP}"
    log_info "containerd 信任配置已写入: ${trust_dir}/hosts.toml"
}

# 生成 hosts.toml 内容（供本地写入和远程分发复用）
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

# ── 镜像名规范化（与 containerd 导入行为一致）──────────────────────────────────
# containerd import 时对无 registry 前缀的名称自动补全：
#   name:tag        → docker.io/library/name:tag
#   org/name:tag    → docker.io/org/name:tag
#   registry/name   → 保持（第一分段含 . 或为 localhost）
_normalize_image_ref() {
    local img="$1"
    local host="${img%%/*}"
    host="${host%%:*}"   # 去掉 :tag，只保留 host 或 image name
    if [[ "${host}" != *"."* && "${host}" != "localhost" ]]; then
        [[ "${img}" != *"/"* ]] && echo "docker.io/library/${img}" || echo "docker.io/${img}"
    else
        echo "${img}"
    fi
}

# ── 从 tar 文件读取镜像名列表 ─────────────────────────────────────────────────
_images_from_tar()    { tar -xOf "$1" manifest.json 2>/dev/null  | grep -oP '"RepoTags":\["\K[^"]+' || true; }
_images_from_tar_gz() { tar -xzOf "$1" manifest.json 2>/dev/null | grep -oP '"RepoTags":\["\K[^"]+' || true; }

# ── 导入单个文件到 containerd，输出镜像名列表 ─────────────────────────────────
_import_file() {
    local file="$1"
    local -n _out_names="$2"   # nameref

    if [[ "${file}" == *.tar.gz ]]; then
        if tar -tzf "${file}" 2>/dev/null | grep -q "^manifest.json$"; then
            ctr -n k8s.io images import "${file}" &>/dev/null
            mapfile -t _out_names < <(_images_from_tar_gz "${file}")
        else
            # wrapper 包（内含镜像 .tar）
            local wdir; wdir=$(mktemp -d /tmp/reg-import-XXXXXX)
            trap "rm -rf '${wdir}'" RETURN
            tar -xzf "${file}" -C "${wdir}"
            while IFS= read -r -d '' inner; do
                if tar -tf "${inner}" 2>/dev/null | grep -q "^manifest.json$"; then
                    ctr -n k8s.io images import "${inner}" &>/dev/null
                    mapfile -t -O "${#_out_names[@]}" _out_names < <(_images_from_tar "${inner}")
                fi
            done < <(find "${wdir}" -name "*.tar" ! -name "*.tar.gz" -print0)
        fi
    elif [[ "${file}" == *.tar ]]; then
        if tar -tf "${file}" 2>/dev/null | grep -q "^manifest.json$"; then
            ctr -n k8s.io images import "${file}" &>/dev/null
            mapfile -t _out_names < <(_images_from_tar "${file}")
        fi
    fi
}

# ── 按命名空间导入并推送镜像 ────────────────────────────────────────────────────
PUSHED_IMAGES=()

import_and_push_by_namespace() {
    [[ ${#NS_ORDER[@]} -eq 0 ]] && { log_warn "配置中未定义任何命名空间，跳过镜像处理。"; return; }

    for ns in "${NS_ORDER[@]}"; do
        local paths="${NS_PATHS[${ns}]}"
        [[ -z "${paths}" ]] && continue

        log_info "── 命名空间: ${ns} ──"
        local -a files=()

        while IFS= read -r path; do
            [[ -z "${path}" ]] && continue
            if [[ -d "${path}" ]]; then
                while IFS= read -r -d '' f; do
                    files+=("${f}")
                done < <(find "${path}" -type f \( -name "*.tar" -o -name "*.tar.gz" \) -print0 | sort -z)
                log_info "  扫描目录 ${path}：$(find "${path}" -type f \( -name "*.tar" -o -name "*.tar.gz" \) | wc -l) 个文件"
            elif [[ -f "${path}" ]]; then
                files+=("${path}")
            else
                log_warn "  路径不存在，跳过: ${path}"
            fi
        done <<< "${paths}"

        for f in "${files[@]}"; do
            log_info "  处理: $(basename "${f}")"
            local -a img_names=()
            _import_file "${f}" img_names

            if [[ ${#img_names[@]} -eq 0 ]]; then
                log_warn "    无法读取镜像名（RepoTags 为空），跳过: $(basename "${f}")"
                continue
            fi

            for img in "${img_names[@]}"; do
                [[ -z "${img}" ]] && continue
                local full_img; full_img=$(_normalize_image_ref "${img}")
                local short_name="${img##*/}"
                local reg_tag="${REGISTRY_ADDR}/${ns}/${short_name}"

                log_info "  → ${reg_tag}"
                if ctr -n k8s.io images tag "${full_img}" "${reg_tag}" 2>&1; then
                    if ctr -n k8s.io images push --plain-http "${reg_tag}" 2>&1 | tail -1; then
                        PUSHED_IMAGES+=("${reg_tag}")
                        log_info "    ✓ 推送成功"
                    else
                        log_warn "    ✗ 推送失败: ${reg_tag}"
                    fi
                else
                    log_warn "    tag 失败（源镜像: ${full_img}），跳过"
                fi
            done
        done
    done
}

# ── 生成信任配置文件 ────────────────────────────────────────────────────────────
TRUST_CONF_FILE=""

generate_trust_conf() {
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

# ── 验证 Registry ───────────────────────────────────────────────────────────────
verify_registry() {
    log_info "验证 Registry Catalog..."
    local catalog
    catalog=$(curl -sf "http://${REGISTRY_ADDR}/v2/_catalog" 2>/dev/null \
        || echo '{"repositories":[]}')
    local repos
    repos=$(echo "${catalog}" | python3 -c "
import sys,json
data=json.load(sys.stdin)
repos=data.get('repositories',[])
print(f'  共 {len(repos)} 个仓库: {repos}')
" 2>/dev/null || echo "  ${catalog}")
    log_info "${repos}"
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
    if [[ ${#PUSHED_IMAGES[@]} -gt 0 ]]; then
        log_info "  已推送镜像（${#PUSHED_IMAGES[@]} 个）："
        local cur_ns=""
        for img in "${PUSHED_IMAGES[@]}"; do
            local ns_part="${img#*/}"
            ns_part="${ns_part%%/*}"
            [[ "${ns_part}" != "${cur_ns}" ]] && {
                cur_ns="${ns_part}"
                log_info "  [${cur_ns}]"
            }
            log_info "    ${img}"
        done
    else
        log_warn "  未推送任何镜像。"
    fi
    echo
    log_info "  信任配置文件 : ${TRUST_CONF_FILE}"
    log_info "  注入信任到节点（本机）  : sudo ./registry-trust.sh apply"
    log_info "  注入信任到远程节点      : sudo ./registry-trust.sh apply worker01,worker02"
    log_info "  查看/移除信任配置       : ./registry-trust.sh list"
    log_info "════════════════════════════════════════════════════════"
}

# ── 主流程 ──────────────────────────────────────────────────────────────────────
main() {
    parse_config

    log_info "=== Step 1/7: 前置检查 ==="
    preflight_check

    log_info "=== Step 2/7: 拉取 registry:2 镜像 ==="
    pull_registry_image

    log_info "=== Step 3/7: 准备存储目录 ==="
    create_storage_dir

    log_info "=== Step 4/7: 部署 Registry 到 k8s ==="
    deploy_registry

    log_info "=== Step 5/7: 等待 Registry 就绪 ==="
    wait_for_registry

    log_info "=== Step 6/7: 配置本机 containerd 信任 ==="
    configure_containerd_trust

    log_info "=== Step 7/7: 按命名空间导入并推送镜像 ==="
    import_and_push_by_namespace
    verify_registry

    generate_trust_conf
    print_summary
}

main "$@"
