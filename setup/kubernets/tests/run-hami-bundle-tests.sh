#!/usr/bin/env bash
# 校验 `set-node-mode.sh biren --vgpu` 部署的 HAMi-Biren 统一插件：
# 整卡（单卡/多卡 + NUMA 拓扑）、SVI 硬切分（1/2、1/4 动态切分）、vGPU 软切分
# （provision / 共享 / 利用率 / 回收）。本脚本是对安装包内 test/run-tests.sh 的薄封装，
# 自动指向 packages/hami-biren 并补默认值。
#
# 用法:
#   sudo [NODE=<gpu-node>] [TEST_IMAGE=<img>] ./run-hami-bundle-tests.sh [all|whole|svi|vgpu]
#
# 环境变量:
#   HAMI_BUNDLE_DIR  安装包目录（默认 ../../../packages/hami-biren）
#   KUBECONFIG       默认 /etc/kubernetes/admin.conf（需 root 读取）
#   NODE             目标 GPU 节点（默认本机 hostname -s）
#   NS               测试 Pod 命名空间（默认 default）
#   TEST_IMAGE       Pod 镜像；须已存在于 GPU 节点（IfNotPresent，不走 registry 拉取）。
#                    默认 ubuntu:22.04 —— 若节点上没有，请先 ctr import 或指定已有镜像。
#   RUN_TIMEOUT      等待 Running 的秒数（默认 300；首次冷切分 SVI/vGPU 约 2 分钟）
#   BR_VGPU_TOOL     host 工具路径（默认 /usr/local/bin/br_vgpu_tool）
#
# 说明: vGPU 组需要目标节点已加载与内核匹配的 1.12.0 KMD；未加载时 vGPU Pod 无法
# provision，该组失败，但 whole + svi 组仍会通过。driver 级检查（sysfs NUMA、
# br_vgpu_tool list）仅在 GPU 节点本机执行时运行，否则自动 SKIP。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${HAMI_BUNDLE_DIR:=${HERE}/../../../packages/hami-biren}"
: "${KUBECONFIG:=/etc/kubernetes/admin.conf}"
: "${NODE:=$(hostname -s)}"
export KUBECONFIG NODE

RUNNER="${HAMI_BUNDLE_DIR}/test/run-tests.sh"
if [[ ! -f "${RUNNER}" ]]; then
    echo "找不到安装包测试脚本: ${RUNNER}" >&2
    echo "请确认 HAMI_BUNDLE_DIR 指向 packages/hami-biren（见 packages/README.md）。" >&2
    exit 1
fi

echo ">> 校验 HAMi-Biren 统一插件: NODE=${NODE} NS=${NS:-default} TEST_IMAGE=${TEST_IMAGE:-ubuntu:22.04} group=${1:-all}"
exec bash "${RUNNER}" "${@:-all}"
