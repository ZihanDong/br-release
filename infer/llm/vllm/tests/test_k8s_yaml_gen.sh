#!/usr/bin/env bash
# Unit tests for k8s_yaml_gen.sh — whole-card model: qwen3-32b (tp=2),
# single-GPU model (for SVI/vGPU): bge-m3 (tp=1).
#
# Tests validate YAML generation correctness (structure, field values, filename)
# without applying anything to the cluster.
#
# Usage:
#   cd infer/llm/vllm
#   bash tests/test_k8s_yaml_gen.sh
#
# Exit code: 0 if all tests pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VLLM_DIR="${SCRIPT_DIR}/.."
GEN="${VLLM_DIR}/k8s_yaml_gen.sh"
YAML_DIR="${VLLM_DIR}/k8s_yaml_gen"
MODEL="qwen3-32b"      # tp=2 → whole-card tests
GPU1_MODEL="bge-m3"    # tp=1 → SVI/vGPU tests (single-GPU required)

PASS=0
FAIL=0

_pass() { printf "  \033[1;32m[PASS]\033[0m %s\n" "$*"; PASS=$((PASS+1)); }
_fail() { printf "  \033[0;31m[FAIL]\033[0m %s\n" "$*" >&2; FAIL=$((FAIL+1)); }

# _has file pattern description
_has() {
    local file="$1" pat="$2" desc="$3"
    if grep -q -- "$pat" "$file" 2>/dev/null; then
        _pass "$desc"
    else
        _fail "$desc  [pattern not found: $pat]"
    fi
}

# _hasnt file pattern description
_hasnt() {
    local file="$1" pat="$2" desc="$3"
    if ! grep -q -- "$pat" "$file" 2>/dev/null; then
        _pass "$desc"
    else
        _fail "$desc  [unexpected pattern found: $pat]"
    fi
}

# _file_exists path description
_file_exists() {
    local f="$1" desc="$2"
    if [[ -f "$f" ]]; then
        _pass "$desc"
    else
        _fail "$desc  [file not found: $f]"
    fi
}

# Run generator; capture exit code without triggering set -e
_gen() {
    bash "$GEN" "$@" >/dev/null 2>&1
    return $?
}

# ─────────────────────────────────────────────────────────────────────────────
section() { echo ""; echo "── $* ──"; }
# ─────────────────────────────────────────────────────────────────────────────

# Clean prior outputs for the test models so stale files can't cause false
# positives when a generation is expected to fail.
rm -f "${YAML_DIR}/${MODEL}-"*.yaml "${YAML_DIR}/${GPU1_MODEL}-"*.yaml 2>/dev/null || true

section "1. Deploy — --gpu whole card (default scheduling/resources)"
_gen --task deploy --gpu "$MODEL"
_yaml="${YAML_DIR}/${MODEL}-deploy-p28800-r1.yaml"
_file_exists "$_yaml" "deploy: filename contains port and replicas"
_has "$_yaml" 'kind: Deployment'            "deploy: kind=Deployment"
_has "$_yaml" 'replicas: 1'                  "deploy: replicas=1 (default)"
_has "$_yaml" 'kind: Service'               "deploy: Service included"
_has "$_yaml" 'nodePort: 30801'             "deploy: nodePort from config"
_has "$_yaml" 'containerPort: 28800'        "deploy: containerPort from config"
_has "$_yaml" 'birentech.com/gpu: "2"'     "deploy: 2 whole GPUs (tp=2)"
_has "$_yaml" 'schedulerName: hami-scheduler' "deploy: routed through HAMi scheduler"
_has "$_yaml" 'runtimeClassName: biren'     "deploy: runtimeClassName=biren"
_has "$_yaml" 'birentech.com: gpu'          "deploy: default nodeSelector birentech.com=gpu"
_has "$_yaml" 'cpu: "32"'                   "deploy: cpu request=32 (default)"
_has "$_yaml" 'cpu: "64"'                   "deploy: cpu limit=64 (2x default)"
_has "$_yaml" 'memory: "256Gi"'             "deploy: mem=256Gi (2GPU×128)"
_has "$_yaml" 'readinessProbe:'             "deploy: readinessProbe present"
_has "$_yaml" 'livenessProbe:'             "deploy: livenessProbe present"
_hasnt "$_yaml" 'nodeName:'                 "deploy: no nodeName (no --node)"

section "2. Deploy — --node scheduling"
_gen --task deploy --gpu --node brhost-02 "$MODEL"
_yaml="${YAML_DIR}/${MODEL}-deploy-node-brhost-02-p28800-r1.yaml"
_file_exists "$_yaml" "deploy+node: filename includes node"
_has "$_yaml" 'nodeName: brhost-02'         "deploy+node: nodeName set"
_hasnt "$_yaml" 'nodeSelector:'             "deploy+node: no nodeSelector"

section "3. Deploy — --label scheduling"
_gen --task deploy --gpu --label "kubernetes.io/hostname=brhost-02" "$MODEL"
_yaml="${YAML_DIR}/${MODEL}-deploy-label-brhost-02-p28800-r1.yaml"
_file_exists "$_yaml" "deploy+label: filename includes label value"
_has "$_yaml" 'nodeSelector:'               "deploy+label: nodeSelector set"
_has "$_yaml" 'kubernetes.io/hostname: brhost-02' "deploy+label: correct label kv"
_hasnt "$_yaml" 'nodeName:'                 "deploy+label: no nodeName"

section "4. Deploy — --replicas override"
_gen --task deploy --gpu --node brhost-02 --replicas 3 "$MODEL"
_yaml="${YAML_DIR}/${MODEL}-deploy-node-brhost-02-p28800-r3.yaml"
_file_exists "$_yaml" "deploy+replicas: filename includes r3"
_has "$_yaml" 'replicas: 3'                 "deploy+replicas: replicas=3"
_has "$_yaml" 'task=deploy  replicas=3'     "deploy+replicas: comment header correct"

section "5. Deploy — --cpu and --mem-per-gpu overrides"
_gen --task deploy --gpu --node brhost-02 --cpu 16 --mem-per-gpu 64 "$MODEL"
_yaml="${YAML_DIR}/${MODEL}-deploy-node-brhost-02-p28800-r1.yaml"
_has "$_yaml" 'cpu: "16"'                   "deploy+resources: cpu request=16"
_has "$_yaml" 'cpu: "32"'                   "deploy+resources: cpu limit=32 (2x16)"
_has "$_yaml" 'memory: "128Gi"'             "deploy+resources: mem=128Gi (2GPU×64)"

section "6. Pod — --gpu (default scheduling)"
_gen --task pod --gpu "$MODEL"
_yaml="${YAML_DIR}/${MODEL}-pod-p28800.yaml"
_file_exists "$_yaml" "pod: filename contains port (no replicas)"
_has "$_yaml" 'kind: Pod'                   "pod: kind=Pod"
_has "$_yaml" 'restartPolicy: Never'        "pod: restartPolicy=Never"
_has "$_yaml" 'sleep'                       "pod: args contains sleep"
_has "$_yaml" 'infinity'                    "pod: args contains infinity"
_has "$_yaml" 'schedulerName: hami-scheduler' "pod: routed through HAMi scheduler"
_hasnt "$_yaml" 'kind: Service'             "pod: no Service"
_hasnt "$_yaml" 'kind: Deployment'          "pod: no Deployment"
_hasnt "$_yaml" 'readinessProbe:'           "pod: no readinessProbe"
_hasnt "$_yaml" 'nodeName:'                 "pod: no nodeName (no --node)"
_has "$_yaml" 'vllm.io/config-file:'       "pod: config-file annotation present"
_has "$_yaml" 'vllm.io/server-script:'     "pod: server-script annotation present"

section "7. Pod — --node scheduling"
_gen --task pod --gpu --node brhost-02 "$MODEL"
_yaml="${YAML_DIR}/${MODEL}-pod-node-brhost-02-p28800.yaml"
_file_exists "$_yaml" "pod+node: filename includes node"
_has "$_yaml" 'nodeName: brhost-02'         "pod+node: nodeName set"

section "8. Pod — --label scheduling"
_gen --task pod --gpu --label "node-pool=gpu-a" "$MODEL"
_yaml="${YAML_DIR}/${MODEL}-pod-label-gpu-a-p28800.yaml"
_file_exists "$_yaml" "pod+label: filename uses label value"
_has "$_yaml" 'nodeSelector:'               "pod+label: nodeSelector set"
_has "$_yaml" 'node-pool: gpu-a'            "pod+label: correct label kv"

section "8b. Deploy — --svi 1in2 (Biren SVI 1/2, single-GPU model)"
_gen --task deploy --svi 1in2 "$GPU1_MODEL"
_yaml="${YAML_DIR}/${GPU1_MODEL}-deploy-svi-1in2-p28800-r1.yaml"
_file_exists "$_yaml" "svi-1in2: filename has -svi-1in2 suffix"
_has   "$_yaml" 'birentech.com/1-2-gpu: "1"'  "svi-1in2: requests one 1/2 SVI instance"
_has   "$_yaml" 'schedulerName: hami-scheduler' "svi-1in2: routed through HAMi scheduler"
_has   "$_yaml" 'name: vllm-bge-m3-svi-1in2' "svi-1in2: k8s name carries svi suffix"
_hasnt "$_yaml" 'birentech.com/gpu: '          "svi-1in2: no whole-card resource"

section "8c. Deploy — --svi 1in4 (Biren SVI 1/4)"
_gen --task deploy --svi 1in4 "$GPU1_MODEL"
_yaml="${YAML_DIR}/${GPU1_MODEL}-deploy-svi-1in4-p28800-r1.yaml"
_file_exists "$_yaml" "svi-1in4: filename has -svi-1in4 suffix"
_has   "$_yaml" 'birentech.com/1-4-gpu: "1"'  "svi-1in4: requests one 1/4 SVI instance"
_hasnt "$_yaml" 'birentech.com/gpu: '          "svi-1in4: no whole-card resource"

section "8d. Deploy — --vgpu-core/--vgpu-mem (Biren vGPU soft partition)"
_gen --task deploy --vgpu-core 8 --vgpu-mem 16 "$GPU1_MODEL"
_yaml="${YAML_DIR}/${GPU1_MODEL}-deploy-vgpu-c8-m16g-p28800-r1.yaml"
_file_exists "$_yaml" "vgpu: filename has -vgpu-c8-m16g suffix"
_has   "$_yaml" 'birentech.com/vgpu: "1"'        "vgpu: requests one vgpu device"
_has   "$_yaml" 'birentech.com/vgpu-cores: "8"'  "vgpu: vgpu-cores=8 (SPC)"
_has   "$_yaml" 'birentech.com/vgpu-memory: "16384"' "vgpu: vgpu-memory=16384MB (16GiB)"
_has   "$_yaml" 'schedulerName: hami-scheduler' "vgpu: routed through HAMi scheduler"
_hasnt "$_yaml" 'birentech.com/gpu: '            "vgpu: no whole-card resource"
_hasnt "$_yaml" 'birentech.com/1-2-gpu'          "vgpu: no SVI resource"

section "9. Error cases"

# A GPU mode is required
if _gen --task deploy "$MODEL" 2>/dev/null; then
    _fail "missing GPU mode: should exit non-zero"
else
    _pass "missing GPU mode (--gpu/--svi/--vgpu): rejected"
fi

# GPU modes are mutually exclusive
if _gen --task deploy --gpu --svi 1in2 "$GPU1_MODEL" 2>/dev/null; then
    _fail "mode mutual exclusion: --gpu + --svi should exit non-zero"
else
    _pass "mode mutual exclusion: --gpu + --svi rejected"
fi

# vGPU needs both core and mem
if _gen --task deploy --vgpu-core 8 "$GPU1_MODEL" 2>/dev/null; then
    _fail "vgpu missing --vgpu-mem: should exit non-zero"
else
    _pass "vgpu requires both --vgpu-core and --vgpu-mem: rejected"
fi

# --svi/--vgpu require a single-GPU config
if _gen --task deploy --svi 1in2 "$MODEL" 2>/dev/null; then
    _fail "svi on multi-GPU config: should exit non-zero"
else
    _pass "svi requires single-GPU config (qwen3-32b tp=2): rejected"
fi

# invalid --svi value
if _gen --task deploy --svi 1in3 "$GPU1_MODEL" 2>/dev/null; then
    _fail "invalid --svi 1in3: should exit non-zero"
else
    _pass "invalid --svi 1in3: rejected"
fi

# --vgpu-core out of range (1..32)
if _gen --task deploy --vgpu-core 40 --vgpu-mem 16 "$GPU1_MODEL" 2>/dev/null; then
    _fail "--vgpu-core 40 (>32): should exit non-zero"
else
    _pass "--vgpu-core out of range (1..32): rejected"
fi

# --vgpu-mem > 64
if _gen --task deploy --vgpu-core 8 --vgpu-mem 128 "$GPU1_MODEL" 2>/dev/null; then
    _fail "--vgpu-mem 128 (>64): should exit non-zero"
else
    _pass "--vgpu-mem > 64G: rejected"
fi

# --node and --label together should fail
if _gen --task deploy --gpu --node brhost-02 --label gpu=high "$MODEL" 2>/dev/null; then
    _fail "mutual exclusion: --node + --label should exit non-zero"
else
    _pass "mutual exclusion: --node + --label rejected"
fi

# --task missing should fail
if _gen --gpu bge-m3 2>/dev/null; then
    _fail "missing --task: should exit non-zero"
else
    _pass "missing --task: rejected"
fi

# invalid --replicas should fail
if _gen --task deploy --gpu --replicas 0 "$MODEL" 2>/dev/null; then
    _fail "invalid --replicas 0: should exit non-zero"
else
    _pass "invalid --replicas 0: rejected"
fi

# --label without = should fail
if _gen --task deploy --gpu --label badlabel "$MODEL" 2>/dev/null; then
    _fail "malformed --label (no =): should exit non-zero"
else
    _pass "malformed --label (no =): rejected"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
printf "  Results: \033[1;32m%d passed\033[0m / \033[0;31m%d failed\033[0m / %d total\n" \
    "$PASS" "$FAIL" "$TOTAL"
echo "════════════════════════════════════════"
echo ""

[[ "$FAIL" -eq 0 ]]
