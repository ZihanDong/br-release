#!/usr/bin/env bash
# 校验 HAMi-Biren 统一插件（set-node-mode.sh biren --vgpu 部署）的三种调度形态，
# 直接复用 ../templates 下的 Pod 模板，自包含、无需安装包目录。
#
# 用法:
#   sudo [NODE=<gpu-node>] [TEST_IMAGE=<img>] ./test-unified-plugin.sh [all|whole|svi|vgpu]
#
# 环境变量:
#   KUBECONFIG    默认 /etc/kubernetes/admin.conf（需 root 读取）
#   NODE          查询 allocatable 的节点（默认本机 hostname -s）
#   NS            测试 Pod 命名空间（默认 default）
#   TEST_IMAGE    Pod 镜像；须已存在于 GPU 节点（IfNotPresent，不走 registry）。默认 ubuntu:22.04
#   RUN_TIMEOUT   等待 Running 的秒数（默认 300；首次冷切分 SVI/vGPU 约 2 分钟）
#   BR_VGPU_TOOL  host 工具路径（默认 /usr/local/bin/br_vgpu_tool）
#
# vGPU 组需目标节点已加载 1.12.0 KMD；未加载时 vGPU Pod 无法 provision（whole/svi 不受影响）。
# 驱动级检查（卡 vGPU MODE=ACTIVE）仅在 GPU 节点本机执行且工具可用时运行，否则 SKIP。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TPL="${HERE}/../templates"
: "${KUBECONFIG:=/etc/kubernetes/admin.conf}"; export KUBECONFIG
: "${NODE:=$(hostname -s)}"
: "${NS:=default}"
: "${TEST_IMAGE:=ubuntu:22.04}"
: "${RUN_TIMEOUT:=300}"
: "${BR_VGPU_TOOL:=/usr/local/bin/br_vgpu_tool}"
GROUP="${1:-all}"

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
skip() { echo "  SKIP: $1"; SKIP=$((SKIP+1)); }
hdr()  { echo; echo "=== $1 ==="; }

alloc()   { kubectl get node "$NODE" -o jsonpath="{.status.allocatable.birentech\.com/$1}" 2>/dev/null; }
phase()   { kubectl -n "$NS" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
logline() { kubectl -n "$NS" logs "$1" 2>/dev/null | head -1; }
del()     { kubectl -n "$NS" delete pod "$1" --ignore-not-found --wait=false >/dev/null 2>&1; }

# apply_tpl FILE  —— 用 TEST_IMAGE 替换模板镜像后 apply
apply_tpl() { sed "s|image: ubuntu:22.04|image: ${TEST_IMAGE}|" "${TPL}/$1" | kubectl -n "$NS" apply -f - >/dev/null 2>&1; }

wait_running() { # NAME TIMEOUT
  local name="$1" t="$2" i=0
  while [ "$i" -lt "$t" ]; do
    case "$(phase "$name")" in
      Running) return 0 ;;
      Failed)  return 2 ;;
    esac
    sleep 5; i=$((i+5))
  done
  return 1
}

wait_clean() { # 等待 SVI/vGPU 计数回到 0（卡回收为整卡）
  local i=0
  while [ "$i" -lt 240 ]; do
    [ "$(alloc 1-2-gpu)" = "0" ] && [ "$(alloc 1-4-gpu)" = "0" ] && \
      { [ "$(alloc vgpu)" = "0" ] || [ -z "$(alloc vgpu)" ]; } && return 0
    sleep 10; i=$((i+10))
  done
  return 1
}

echo "node=$NODE ns=$NS image=$TEST_IMAGE run_timeout=${RUN_TIMEOUT}s group=$GROUP"
echo "baseline: gpu=$(alloc gpu) 1-2-gpu=$(alloc 1-2-gpu) 1-4-gpu=$(alloc 1-4-gpu) vgpu=$(alloc vgpu)"

# ───────────────────────── 整卡 ─────────────────────────
if [ "$GROUP" = all ] || [ "$GROUP" = whole ]; then
  hdr "整卡 (whole-card)"
  apply_tpl biren-whole-gpu.yaml
  if wait_running biren-whole-gpu "$RUN_TIMEOUT"; then
    cards=$(logline biren-whole-gpu | grep -oE 'card_[0-9]+' | sort -u | tr '\n' ' ')
    [ -n "$cards" ] && ok "整卡 Running，注入 BR_PHY_CARDS=$cards" || bad "整卡 Running 但未注入 BR_PHY_CARDS"
  else bad "整卡 Pod 未在 ${RUN_TIMEOUT}s 内 Running"; fi
  del biren-whole-gpu
fi

# ───────────────────────── SVI ─────────────────────────
if [ "$GROUP" = all ] || [ "$GROUP" = svi ]; then
  hdr "SVI 硬切分 1/2 + 1/4（动态切分）"
  apply_tpl biren-svi-half.yaml
  if wait_running biren-svi-half "$RUN_TIMEOUT"; then
    ok "SVI 1/2 Running ($(logline biren-svi-half | grep -oE 'card_[0-9]+' | tr '\n' ' '))"
  else bad "SVI 1/2 未在 ${RUN_TIMEOUT}s 内 Running"; fi
  del biren-svi-half; wait_clean || true

  apply_tpl biren-svi-quarter.yaml
  if wait_running biren-svi-quarter "$RUN_TIMEOUT"; then
    ok "SVI 1/4 Running ($(logline biren-svi-quarter | grep -oE 'card_[0-9]+' | tr '\n' ' '))"
  else bad "SVI 1/4 未在 ${RUN_TIMEOUT}s 内 Running"; fi
  del biren-svi-quarter; wait_clean || true
fi

# ───────────────────────── vGPU ─────────────────────────
if [ "$GROUP" = all ] || [ "$GROUP" = vgpu ]; then
  hdr "vGPU 软切分（provision + 注入 + 驱动 ACTIVE + 回收）"
  have_tool=0; sudo "$BR_VGPU_TOOL" status --dbdf 0 >/dev/null 2>&1 && have_tool=1
  [ "$have_tool" = 1 ] || skip "br_vgpu_tool 驱动级检查（需在装有 1.12.0 KMD 的 GPU 节点本机执行）"

  apply_tpl biren-vgpu.yaml
  if wait_running biren-vgpu "$RUN_TIMEOUT"; then
    ok "vGPU Pod Running"
    logline biren-vgpu | grep -q 'BR_VGPU_UUID=[0-9a-f]' && ok "vGPU Pod 已注入 BR_VGPU_UUID" || bad "vGPU Pod 未注入 BR_VGPU_UUID"
    if [ "$have_tool" = 1 ]; then
      sleep 10
      # 每实例 profile 注册在容器 cgroup，host root cgroup 看不到 list/query；
      # host 可见的证据是该卡 vGPU MODE = ACTIVE。
      dbdf=$(kubectl -n "$NS" get pod biren-vgpu -o jsonpath='{.metadata.annotations.hami\.io/biren-vgpu-instance}' 2>/dev/null | grep -oE '"dbdf":[0-9]+' | grep -oE '[0-9]+')
      if [ -n "$dbdf" ] && sudo "$BR_VGPU_TOOL" status --dbdf "$(printf '0x%x' "$dbdf")" 2>/dev/null | grep -q 'ACTIVE (1)'; then
        ok "驱动确认卡处于 vGPU ACTIVE 模式 (dbdf=$(printf '0x%x' "$dbdf"))"
      else bad "驱动未显示卡处于 vGPU ACTIVE 模式"; fi
    fi
  else bad "vGPU Pod 未在 ${RUN_TIMEOUT}s 内 Running（vGPU 需节点加载 1.12.0 KMD + br_vgpu_tool）"; fi
  del biren-vgpu
  if wait_clean; then ok "回收: vgpu/1-2/1-4 归零（卡回收为整卡）"; else bad "回收: 资源未归零"; fi
fi

echo; echo "=================================================="
echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
echo "=================================================="
[ "$FAIL" -eq 0 ]
