#!/usr/bin/env bash
# 示例 01：单节点完整部署流程
#
# 在同一台机器上完成：
#   - k8s 环境安装
#   - 控制面初始化
#   - 节点切换为 BirenTech GPU 算力节点
#   - 私有 Registry 部署（镜像导入请在完成后执行 update_images.sh add）
#
# 适用场景：开发机、单机测试环境、单节点 GPU 集群
#
# 使用方式：
#   sudo bash setup/samples/01-single-node-full-setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../kubernets"

# ── 可配置参数 ─────────────────────────────────────────────────────────────────
: "${K8S_VERSION:=1.30}"
: "${NODE_MODE:=biren}"              # biren | cpu | none
: "${DEPLOY_REGISTRY:=true}"         # true | false
: "${REGISTRY_CONF:=}"               # 默认使用 registry/registry.conf
# 镜像加速地址：国内/Kylin 环境必填（registry.k8s.io 不可达）
# 示例：registry.aliyuncs.com/google_containers
: "${REGISTRY_MIRROR:=}"

# ── 颜色输出 ───────────────────────────────────────────────────────────────────
_info()  { echo -e "\033[0;32m[INFO]\033[0m  $*"; }
_step()  { echo; echo -e "\033[1;34m══════════════════════════════════════════\033[0m"; \
           echo -e "\033[1;34m  $*\033[0m"; \
           echo -e "\033[1;34m══════════════════════════════════════════\033[0m"; }

# ── 前置检查 ───────────────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "请以 root 身份运行（sudo）"; exit 1; }

_step "Step 1/5: 安装 k8s 基础环境"
K8S_VERSION="${K8S_VERSION}" REGISTRY_MIRROR="${REGISTRY_MIRROR}" bash "${K8S_DIR}/install.sh"

_step "Step 2/5: 初始化控制面"
K8S_VERSION="${K8S_VERSION}" REGISTRY_MIRROR="${REGISTRY_MIRROR}" bash "${K8S_DIR}/master.sh"

_step "Step 3/5: 等待节点 Ready"
export KUBECONFIG=/etc/kubernetes/admin.conf
for i in $(seq 1 30); do
    status=$(kubectl get node "$(hostname -s)" -o jsonpath='{.status.conditions[-1].type}' 2>/dev/null || true)
    [[ "${status}" == "Ready" ]] && { _info "节点已 Ready。"; break; }
    _info "  等待中... (${i}/30)"
    sleep 5
done

_step "Step 4/5: 切换节点模式为 ${NODE_MODE}"
bash "${K8S_DIR}/set-node-mode.sh" "${NODE_MODE}"

if [[ "${DEPLOY_REGISTRY}" == "true" ]]; then
    _step "Step 5/5: 部署私有 Registry"
    CONF_ARG="${REGISTRY_CONF:-${K8S_DIR}/registry/registry.conf}"
    bash "${K8S_DIR}/registry/setup-registry.sh" "${CONF_ARG}"
else
    _step "Step 5/5: 跳过 Registry 部署（DEPLOY_REGISTRY=false）"
fi

echo
_info "════════════════════════════════════════"
_info "  单节点完整部署完成！"
_info "════════════════════════════════════════"
_info "  节点状态: $(kubectl get nodes --no-headers 2>/dev/null | head -1)"
if [[ "${DEPLOY_REGISTRY}" == "true" ]]; then
    REG_ADDR=$(grep TRUST_REGISTRY_ADDR "${K8S_DIR}/registry/registry-trust.conf" 2>/dev/null | cut -d= -f2 || true)
    [[ -n "${REG_ADDR}" ]] && _info "  Registry : http://${REG_ADDR}/v2/_catalog"
    _info "  下一步：编辑 registry/images.conf 后运行: sudo bash registry/update_images.sh add"
fi
_info "  GPU 资源: $(kubectl get node "$(hostname -s)" -o jsonpath='{.status.allocatable.birentech\.com/gpu}' 2>/dev/null || echo 'N/A')"
