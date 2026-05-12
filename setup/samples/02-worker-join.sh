#!/usr/bin/env bash
# 示例 02：Worker 节点加入集群
#
# 在 Worker 节点上：
#   - 安装 k8s 基础环境
#   - 加入已有集群（支持 CPU / GPU 模式）
#   - 注入 Registry 信任配置（可选）
#
# 前提：
#   - Master 节点已执行 master.sh
#   - /root/k8s-join.sh 已从 Master 节点复制到本机（或填写下方环境变量）
#
# 使用方式：
#   # CPU worker（读取 /root/k8s-join.sh）
#   sudo bash setup/samples/02-worker-join.sh cpu
#
#   # GPU worker，手动指定 join 参数
#   sudo MASTER_IP=10.49.4.248 JOIN_TOKEN=abc.xyz CA_CERT_HASH=sha256:xxx \
#        bash setup/samples/02-worker-join.sh biren
#
#   # 注入 Registry 信任（需先从 Master 复制 registry-trust.conf）
#   sudo REGISTRY_TRUST_CONF=/path/to/registry-trust.conf \
#        bash setup/samples/02-worker-join.sh cpu

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../kubernets"

# ── 可配置参数 ─────────────────────────────────────────────────────────────────
NODE_MODE="${1:-cpu}"                     # cpu | biren | worker
: "${K8S_VERSION:=1.30}"
: "${JOIN_FILE:=/root/k8s-join.sh}"
: "${MASTER_IP:=}"
: "${JOIN_TOKEN:=}"
: "${CA_CERT_HASH:=}"
: "${REGISTRY_TRUST_CONF:=}"             # 填写后自动注入 Registry 信任

_info()  { echo -e "\033[0;32m[INFO]\033[0m  $*"; }
_step()  { echo; echo -e "\033[1;34m══════════════════════════════════════════\033[0m"; \
           echo -e "\033[1;34m  $*\033[0m"; \
           echo -e "\033[1;34m══════════════════════════════════════════\033[0m"; }

[[ "$(id -u)" -eq 0 ]] || { echo "请以 root 身份运行（sudo）"; exit 1; }

case "${NODE_MODE}" in
    cpu|worker|biren) ;;
    *) echo "用法: $0 <cpu|worker|biren>"; exit 1 ;;
esac

_step "Step 1/3: 安装 k8s 基础环境"
K8S_VERSION="${K8S_VERSION}" bash "${K8S_DIR}/install.sh"

_step "Step 2/3: 加入集群（模式: ${NODE_MODE}）"
JOIN_FILE="${JOIN_FILE}" \
MASTER_IP="${MASTER_IP}" \
JOIN_TOKEN="${JOIN_TOKEN}" \
CA_CERT_HASH="${CA_CERT_HASH}" \
    bash "${K8S_DIR}/join.sh" "${NODE_MODE}"

if [[ -n "${REGISTRY_TRUST_CONF}" && -f "${REGISTRY_TRUST_CONF}" ]]; then
    _step "Step 3/3: 注入 Registry 信任配置"
    bash "${K8S_DIR}/registry/registry-trust.sh" apply \
        --config "${REGISTRY_TRUST_CONF}"
else
    _step "Step 3/3: 跳过 Registry 信任（未提供 REGISTRY_TRUST_CONF）"
    _info "  如需注入信任，在 Master 执行："
    _info "    sudo ./registry/registry-trust.sh apply $(hostname -s)"
fi

echo
_info "节点 $(hostname -s) 已加入集群（${NODE_MODE} 模式）。"
