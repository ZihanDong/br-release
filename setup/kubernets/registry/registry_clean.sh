#!/usr/bin/env bash
# 完全清除私有 Registry 的配置、存储及相关资源
#
# 执行内容：
#   1. 删除 k8s 中的 Registry Deployment 和 Service
#   2. 移除本机 containerd 信任配置（/etc/containerd/certs.d/<addr>/）
#   3. 删除 Registry 存储目录（由 registry.conf 中 REGISTRY_STORAGE 指定）
#   4. 从 containerd k8s.io 命名空间中删除 registry:2 镜像
#   5. 删除生成的信任配置文件（registry-trust.conf）
#
# 用法：
#   sudo ./registry_clean.sh [配置文件路径]
#   配置文件默认为同目录下的 registry.conf

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/../lib"
source "${LIB_DIR}/common.sh"

require_root

CONFIG_FILE="${1:-${SCRIPT_DIR}/registry.conf}"

# ── 读取配置 ───────────────────────────────────────────────────────────────────
REGISTRY_STORAGE=/data/registry
REGISTRY_PORT=32000
REGISTRY_HTTP=true
REGISTRY_K8S_NAMESPACE=kube-system

if [[ -f "${CONFIG_FILE}" ]]; then
    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# || "${line}" =~ ^\[ ]] && continue
        [[ "${line}" =~ ^([A-Z_]+)=(.*)$ ]] || continue
        case "${BASH_REMATCH[1]}" in
            REGISTRY_STORAGE)       REGISTRY_STORAGE="${BASH_REMATCH[2]}"      ;;
            REGISTRY_PORT)          REGISTRY_PORT="${BASH_REMATCH[2]}"          ;;
            REGISTRY_HTTP)          REGISTRY_HTTP="${BASH_REMATCH[2]}"          ;;
            REGISTRY_K8S_NAMESPACE) REGISTRY_K8S_NAMESPACE="${BASH_REMATCH[2]}" ;;
        esac
    done < "${CONFIG_FILE}"
fi

# 读取信任配置中的 Registry 地址
TRUST_CONF="${SCRIPT_DIR}/registry-trust.conf"
REGISTRY_ADDR=""
if [[ -f "${TRUST_CONF}" ]]; then
    while IFS= read -r line; do
        [[ "${line}" =~ ^TRUST_REGISTRY_ADDR=(.+)$ ]] && REGISTRY_ADDR="${BASH_REMATCH[1]}" && break
    done < "${TRUST_CONF}"
fi
# 若无信任配置，尝试从当前节点 IP 推算
if [[ -z "${REGISTRY_ADDR}" ]]; then
    local_ip=$(ip route show default 2>/dev/null \
        | awk '/default/{print $5}' | head -1 \
        | xargs -I{} ip -4 addr show {} 2>/dev/null \
        | awk '/inet /{split($2,a,"/"); print a[1]}' | head -1 || true)
    [[ -n "${local_ip}" ]] && REGISTRY_ADDR="${local_ip}:${REGISTRY_PORT}"
fi

# ── 检查 k8s 资源是否存在 ─────────────────────────────────────────────────────
KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
_K8S_AVAILABLE=false
_REGISTRY_DEPLOY=false
_REGISTRY_SVC=false

if [[ -f "${KUBECONFIG}" ]] && command -v kubectl &>/dev/null; then
    if kubectl get nodes --kubeconfig "${KUBECONFIG}" &>/dev/null 2>&1; then
        _K8S_AVAILABLE=true
        kubectl get deployment registry -n "${REGISTRY_K8S_NAMESPACE}" \
            --kubeconfig "${KUBECONFIG}" &>/dev/null && _REGISTRY_DEPLOY=true || true
        kubectl get svc registry -n "${REGISTRY_K8S_NAMESPACE}" \
            --kubeconfig "${KUBECONFIG}" &>/dev/null && _REGISTRY_SVC=true || true
    fi
fi

# containerd 中的 registry:2 镜像
_CTR_IMAGES=()
if command -v ctr &>/dev/null; then
    while IFS= read -r img; do
        [[ -n "${img}" ]] && _CTR_IMAGES+=("${img}")
    done < <(ctr -n k8s.io images ls 2>/dev/null \
        | awk 'NR>1 && /registry:2|registry:latest/{print $1}' || true)
fi

# containerd 信任目录
_TRUST_DIR=""
[[ -n "${REGISTRY_ADDR}" && -d "/etc/containerd/certs.d/${REGISTRY_ADDR}" ]] \
    && _TRUST_DIR="/etc/containerd/certs.d/${REGISTRY_ADDR}"

# ── 打印 Summary ───────────────────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Registry 清理 —— 待执行操作摘要                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo

echo "【1】删除 k8s Registry 资源（命名空间: ${REGISTRY_K8S_NAMESPACE}）"
if ${_K8S_AVAILABLE}; then
    if ${_REGISTRY_DEPLOY}; then
        echo "    - Deployment/registry"
    else
        echo "    Deployment/registry 不存在，跳过。"
    fi
    if ${_REGISTRY_SVC}; then
        echo "    - Service/registry"
    else
        echo "    Service/registry 不存在，跳过。"
    fi
else
    echo "    k8s API Server 不可达，跳过（集群已清理或未运行）。"
fi
echo

echo "【2】移除 containerd 信任配置"
if [[ -n "${_TRUST_DIR}" ]]; then
    echo "    - ${_TRUST_DIR}/"
else
    if [[ -n "${REGISTRY_ADDR}" ]]; then
        echo "    /etc/containerd/certs.d/${REGISTRY_ADDR}/ 不存在，跳过。"
    else
        echo "    未知 Registry 地址，跳过。"
    fi
fi
echo

echo "【3】删除 Registry 存储目录"
if [[ -d "${REGISTRY_STORAGE}" ]]; then
    local_size=$(du -sh "${REGISTRY_STORAGE}" 2>/dev/null | cut -f1 || echo "未知")
    echo "    - ${REGISTRY_STORAGE}  (占用: ${local_size})"
else
    echo "    ${REGISTRY_STORAGE} 不存在，跳过。"
fi
echo

echo "【4】从 containerd 删除 registry:2 镜像"
if [[ ${#_CTR_IMAGES[@]} -gt 0 ]]; then
    for img in "${_CTR_IMAGES[@]}"; do echo "    - ${img}"; done
else
    echo "    containerd 中未找到 registry:2 镜像。"
fi
echo

echo "【5】删除信任配置文件"
if [[ -f "${TRUST_CONF}" ]]; then
    echo "    - ${TRUST_CONF}"
else
    echo "    ${TRUST_CONF} 不存在，跳过。"
fi
echo

echo "──────────────────────────────────────────────────────────────"
echo "  不影响：k8s 集群本身、其他 Deployment/Service、"
echo "           containerd 主配置、BirenTech runtime"
echo "──────────────────────────────────────────────────────────────"
echo

# ── 用户确认 ───────────────────────────────────────────────────────────────────
read -rp "确认执行以上所有清理操作？[y/N] " _CONFIRM
case "${_CONFIRM}" in
    y|Y|yes|YES) ;;
    *) echo "已取消。"; exit 0 ;;
esac

echo

# ── 执行清理 ───────────────────────────────────────────────────────────────────

# 1. 删除 k8s 资源
log_info "Step 1/5: 删除 k8s Registry 资源..."
if ${_K8S_AVAILABLE}; then
    if ${_REGISTRY_DEPLOY}; then
        kubectl delete deployment registry -n "${REGISTRY_K8S_NAMESPACE}" \
            --kubeconfig "${KUBECONFIG}" --timeout=60s 2>&1 || true
        log_info "  Deployment/registry 已删除。"
    fi
    if ${_REGISTRY_SVC}; then
        kubectl delete svc registry -n "${REGISTRY_K8S_NAMESPACE}" \
            --kubeconfig "${KUBECONFIG}" --timeout=30s 2>&1 || true
        log_info "  Service/registry 已删除。"
    fi
    if ! ${_REGISTRY_DEPLOY} && ! ${_REGISTRY_SVC}; then
        log_info "  无需删除。"
    fi
else
    log_info "  k8s 不可达，跳过。"
fi

# 2. 移除 containerd 信任配置
log_info "Step 2/5: 移除 containerd 信任配置..."
if [[ -n "${_TRUST_DIR}" ]]; then
    rm -rf "${_TRUST_DIR}"
    log_info "  已删除: ${_TRUST_DIR}"
else
    log_info "  无需清理。"
fi

# 3. 删除存储目录
log_info "Step 3/5: 删除 Registry 存储目录..."
if [[ -d "${REGISTRY_STORAGE}" ]]; then
    rm -rf "${REGISTRY_STORAGE}"
    log_info "  已删除: ${REGISTRY_STORAGE}"
else
    log_info "  目录不存在，跳过。"
fi

# 4. 删除 containerd 中的 registry:2 镜像
log_info "Step 4/5: 从 containerd 删除 registry:2 镜像..."
if [[ ${#_CTR_IMAGES[@]} -gt 0 ]]; then
    for img in "${_CTR_IMAGES[@]}"; do
        ctr -n k8s.io images rm "${img}" 2>/dev/null && log_info "  已删除镜像: ${img}" || true
    done
else
    log_info "  无需清理。"
fi

# 5. 删除信任配置文件
log_info "Step 5/5: 删除信任配置文件..."
if [[ -f "${TRUST_CONF}" ]]; then
    rm -f "${TRUST_CONF}"
    log_info "  已删除: ${TRUST_CONF}"
else
    log_info "  文件不存在，跳过。"
fi

echo
log_info "════════════════════════════════════════════════════════"
log_info "  Registry 清理完成！"
log_info "  如需重新部署，运行: sudo ./setup-registry.sh"
log_info "════════════════════════════════════════════════════════"
