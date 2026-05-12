#!/usr/bin/env bash
# 示例 04：完整清除流程
#
# 按顺序清除：Registry → k8s
# 两步都会打印操作摘要并等待用户确认，可安全中途退出。
#
# 使用方式：
#   sudo bash setup/samples/04-full-cleanup.sh
#
# 环境变量：
#   SKIP_REGISTRY_CLEAN   设为 true 则跳过 registry 清除步骤
#   SKIP_K8S_CLEAN        设为 true 则跳过 k8s 清除步骤

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../kubernets"

: "${SKIP_REGISTRY_CLEAN:=false}"
: "${SKIP_K8S_CLEAN:=false}"

_info()  { echo -e "\033[0;32m[INFO]\033[0m  $*"; }
_step()  { echo; echo -e "\033[1;34m══════════════════════════════════════════\033[0m"; \
           echo -e "\033[1;34m  $*\033[0m"; \
           echo -e "\033[1;34m══════════════════════════════════════════\033[0m"; }

[[ "$(id -u)" -eq 0 ]] || { echo "请以 root 身份运行（sudo）"; exit 1; }

echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   完整清除流程                               ║"
echo "║  顺序：Registry 清除 → k8s 清除                             ║"
echo "║  每步均需独立确认，输入 N 可跳过该步骤                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"

if [[ "${SKIP_REGISTRY_CLEAN}" != "true" ]]; then
    _step "Step 1/2: Registry 清除"
    bash "${K8S_DIR}/registry/registry_clean.sh" \
        "${K8S_DIR}/registry/registry.conf" || true
else
    _step "Step 1/2: 跳过 Registry 清除（SKIP_REGISTRY_CLEAN=true）"
fi

if [[ "${SKIP_K8S_CLEAN}" != "true" ]]; then
    _step "Step 2/2: k8s 清除"
    bash "${K8S_DIR}/k8s_clean.sh" || true
else
    _step "Step 2/2: 跳过 k8s 清除（SKIP_K8S_CLEAN=true）"
fi

echo
_info "清除流程结束。"
_info "如需重新部署，运行: sudo bash setup/samples/01-single-node-full-setup.sh"
