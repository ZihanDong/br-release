#!/usr/bin/env bash
# Unit tests for k8s_yaml_gen.sh — model: qwen3-vl-32b
#
# Tests validate YAML generation correctness (structure, field values, filename)
# without applying anything to the cluster.
#
# Usage:
#   cd infer/llm/sglang
#   bash tests/test_k8s_yaml_gen.sh
#
# Exit code: 0 if all tests pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SGLANG_DIR="${SCRIPT_DIR}/.."
GEN="${SGLANG_DIR}/k8s_yaml_gen.sh"
YAML_DIR="${SGLANG_DIR}/k8s_yaml_gen"
MODEL="qwen3-vl-32b"

PASS=0
FAIL=0

_pass() { printf "  \033[1;32m[PASS]\033[0m %s\n" "$*"; PASS=$((PASS+1)); }
_fail() { printf "  \033[0;31m[FAIL]\033[0m %s\n" "$*" >&2; FAIL=$((FAIL+1)); }

_has() {
    local file="$1" pat="$2" desc="$3"
    if grep -q -- "$pat" "$file" 2>/dev/null; then
        _pass "$desc"
    else
        _fail "$desc  [pattern not found: $pat]"
    fi
}

_hasnt() {
    local file="$1" pat="$2" desc="$3"
    if ! grep -q -- "$pat" "$file" 2>/dev/null; then
        _pass "$desc"
    else
        _fail "$desc  [unexpected pattern found: $pat]"
    fi
}

_file_exists() {
    local f="$1" desc="$2"
    if [[ -f "$f" ]]; then
        _pass "$desc"
    else
        _fail "$desc  [file not found: $f]"
    fi
}

_gen() {
    bash "$GEN" "$@" >/dev/null 2>&1
    return $?
}

section() { echo ""; echo "── $* ──"; }

section "1. Deploy — default (no scheduling, default resources)"
_gen --task deploy "$MODEL"
_yaml="${YAML_DIR}/${MODEL}-deploy-p28800-r1.yaml"
_file_exists "$_yaml" "deploy: filename contains port and replicas"
_has "$_yaml" 'kind: Deployment'             "deploy: kind=Deployment"
_has "$_yaml" 'replicas: 1'                  "deploy: replicas=1 (default)"
_has "$_yaml" 'kind: Service'                "deploy: Service included"
_has "$_yaml" 'nodePort: 30900'              "deploy: nodePort from config"
_has "$_yaml" 'containerPort: 28800'         "deploy: containerPort from config"
_has "$_yaml" 'birentech.com/gpu: "4"'      "deploy: 4 GPUs (tp=4)"
_has "$_yaml" 'cpu: "32"'                    "deploy: cpu request=32 (default)"
_has "$_yaml" 'cpu: "64"'                    "deploy: cpu limit=64 (2×default)"
_has "$_yaml" 'memory: "512Gi"'              "deploy: mem=512Gi (4GPU×128)"
_has "$_yaml" 'BIREN_VISIBLE_DEVICES'        "deploy: BIREN_VISIBLE_DEVICES env set"
_has "$_yaml" 'value: "0,1,2,3"'            "deploy: BIREN_VISIBLE_DEVICES=0,1,2,3"
_has "$_yaml" 'readinessProbe:'              "deploy: readinessProbe present"
_has "$_yaml" 'livenessProbe:'               "deploy: livenessProbe present"
_has "$_yaml" 'BRTB_PLAN_ID_RENEW'          "deploy: BirenTech BRTB env set"
_has "$_yaml" 'sglang.io/config-file:'      "deploy: sglang config-file annotation"
_has "$_yaml" 'sglang.io/server-script:'    "deploy: sglang server-script annotation"
_has "$_yaml" 'namespace: sglang'           "deploy: namespace=sglang"
_hasnt "$_yaml" 'nodeName:'                  "deploy: no nodeName (no --node)"
_hasnt "$_yaml" 'nodeSelector:'              "deploy: no nodeSelector (no --label)"
_hasnt "$_yaml" 'VLLM_USE_V1'               "deploy: no vLLM env vars"

section "2. Deploy — --node scheduling"
_gen --task deploy --node brhost-02 "$MODEL"
_yaml="${YAML_DIR}/${MODEL}-deploy-node-brhost-02-p28800-r1.yaml"
_file_exists "$_yaml" "deploy+node: filename includes node"
_has "$_yaml" 'nodeName: brhost-02'          "deploy+node: nodeName set"
_hasnt "$_yaml" 'nodeSelector:'              "deploy+node: no nodeSelector"

section "3. Deploy — --label scheduling"
_gen --task deploy --label "kubernetes.io/hostname=brhost-02" "$MODEL"
_yaml="${YAML_DIR}/${MODEL}-deploy-label-brhost-02-p28800-r1.yaml"
_file_exists "$_yaml" "deploy+label: filename includes label value"
_has "$_yaml" 'nodeSelector:'                "deploy+label: nodeSelector set"
_has "$_yaml" 'kubernetes.io/hostname: brhost-02' "deploy+label: correct label kv"
_hasnt "$_yaml" 'nodeName:'                  "deploy+label: no nodeName"

section "4. Deploy — --replicas override"
_gen --task deploy --node brhost-02 --replicas 3 "$MODEL"
_yaml="${YAML_DIR}/${MODEL}-deploy-node-brhost-02-p28800-r3.yaml"
_file_exists "$_yaml" "deploy+replicas: filename includes r3"
_has "$_yaml" 'replicas: 3'                  "deploy+replicas: replicas=3"
_has "$_yaml" 'task=deploy  replicas=3'      "deploy+replicas: comment header correct"

section "5. Deploy — --cpu and --mem-per-gpu overrides"
_gen --task deploy --node brhost-02 --cpu 16 --mem-per-gpu 64 "$MODEL"
_yaml="${YAML_DIR}/${MODEL}-deploy-node-brhost-02-p28800-r1.yaml"
_has "$_yaml" 'cpu: "16"'                    "deploy+resources: cpu request=16"
_has "$_yaml" 'cpu: "32"'                    "deploy+resources: cpu limit=32 (2×16)"
_has "$_yaml" 'memory: "256Gi"'              "deploy+resources: mem=256Gi (4GPU×64)"

section "6. Pod — default (no scheduling)"
_gen --task pod "$MODEL"
_yaml="${YAML_DIR}/${MODEL}-pod-p28800.yaml"
_file_exists "$_yaml" "pod: filename contains port (no replicas)"
_has "$_yaml" 'kind: Pod'                    "pod: kind=Pod"
_has "$_yaml" 'restartPolicy: Never'         "pod: restartPolicy=Never"
_has "$_yaml" 'sleep'                        "pod: args contains sleep"
_has "$_yaml" 'infinity'                     "pod: args contains infinity"
_hasnt "$_yaml" 'kind: Service'              "pod: no Service"
_hasnt "$_yaml" 'kind: Deployment'           "pod: no Deployment"
_hasnt "$_yaml" 'readinessProbe:'            "pod: no readinessProbe"
_hasnt "$_yaml" 'nodeName:'                  "pod: no nodeName (no --node)"
_has "$_yaml" 'sglang.io/config-file:'      "pod: config-file annotation present"
_has "$_yaml" 'sglang.io/server-script:'    "pod: server-script annotation present"

section "7. Pod — --node scheduling"
_gen --task pod --node brhost-02 "$MODEL"
_yaml="${YAML_DIR}/${MODEL}-pod-node-brhost-02-p28800.yaml"
_file_exists "$_yaml" "pod+node: filename includes node"
_has "$_yaml" 'nodeName: brhost-02'          "pod+node: nodeName set"

section "8. Pod — --label scheduling"
_gen --task pod --label "node-pool=gpu-a" "$MODEL"
_yaml="${YAML_DIR}/${MODEL}-pod-label-gpu-a-p28800.yaml"
_file_exists "$_yaml" "pod+label: filename uses label value"
_has "$_yaml" 'nodeSelector:'                "pod+label: nodeSelector set"
_has "$_yaml" 'node-pool: gpu-a'             "pod+label: correct label kv"

section "9. Error cases"

if _gen --task deploy --node brhost-02 --label gpu=high "$MODEL" 2>/dev/null; then
    _fail "mutual exclusion: --node + --label should exit non-zero"
else
    _pass "mutual exclusion: --node + --label rejected"
fi

if _gen "$MODEL" 2>/dev/null; then
    _fail "missing --task: should exit non-zero"
else
    _pass "missing --task: rejected"
fi

if _gen --task deploy --replicas 0 "$MODEL" 2>/dev/null; then
    _fail "invalid --replicas 0: should exit non-zero"
else
    _pass "invalid --replicas 0: rejected"
fi

if _gen --task deploy --label badlabel "$MODEL" 2>/dev/null; then
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
