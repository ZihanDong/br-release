#!/usr/bin/env bash
# Unit tests for the unified utils/k8s_yaml_gen.sh.
#
# Covers both frameworks without applying anything to a cluster:
#   vllm whole-card  : qwen3-32b (tp=2)
#   vllm single-GPU  : bge-m3    (tp=1) for SVI / vGPU partitions
#   sglang whole-card: qwen3-vl-32b (tp=4)
#
# Usage:
#   bash utils/tests/test_k8s_yaml_gen.sh
# Exit code: 0 if all tests pass, 1 otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UTILS_DIR="${SCRIPT_DIR}/.."
LLM_DIR="$(cd "${UTILS_DIR}/.." && pwd)"
GEN="${UTILS_DIR}/k8s_yaml_gen.sh"
POD_DIR="${LLM_DIR}/configs/pod"
DEPLOY_DIR="${LLM_DIR}/configs/deploy"

V_MODEL="vllm_qwen3-32b"      # vllm tp=2 -> whole-card
V_GPU1="vllm_bge-m3"          # vllm tp=1 -> SVI/vGPU
S_MODEL="sglang_qwen3-vl-32b" # sglang tp=4 -> whole-card

PASS=0; FAIL=0
_pass() { printf "  \033[1;32m[PASS]\033[0m %s\n" "$*"; PASS=$((PASS+1)); }
_fail() { printf "  \033[0;31m[FAIL]\033[0m %s\n" "$*" >&2; FAIL=$((FAIL+1)); }

_has()  { grep -q -- "$2" "$1" 2>/dev/null && _pass "$3" || _fail "$3  [missing: $2]"; }
_hasnt(){ grep -q -- "$2" "$1" 2>/dev/null && _fail "$3  [unexpected: $2]" || _pass "$3"; }
_file_exists() { [[ -f "$1" ]] && _pass "$2" || _fail "$2  [no file: $1]"; }
_gen()  { bash "$GEN" "$@" >/dev/null 2>&1; return $?; }
section() { echo ""; echo "── $* ──"; }

# Clean prior outputs for the test models so stale files can't false-pass.
rm -f "${POD_DIR}/${V_MODEL}-"*.yaml "${DEPLOY_DIR}/${V_MODEL}-"*.yaml \
      "${POD_DIR}/${V_GPU1}-"*.yaml "${DEPLOY_DIR}/${V_GPU1}-"*.yaml \
      "${POD_DIR}/${S_MODEL}-"*.yaml "${DEPLOY_DIR}/${S_MODEL}-"*.yaml 2>/dev/null || true

section "1. vLLM deploy — --gpu whole card (default sched/resources)"
_gen --task deploy --gpu "$V_MODEL"
y="${DEPLOY_DIR}/${V_MODEL}-deploy-p28800-r1.yaml"
_file_exists "$y" "vllm deploy: filename has framework prefix, port, replicas"
_has "$y" 'kind: Deployment'                  "vllm deploy: kind=Deployment"
_has "$y" 'replicas: 1'                        "vllm deploy: replicas=1"
_has "$y" 'kind: Service'                       "vllm deploy: Service included"
_has "$y" 'nodePort: 30801'                     "vllm deploy: nodePort from config"
_has "$y" 'containerPort: 28800'                "vllm deploy: containerPort from config"
_has "$y" 'birentech.com/gpu: "2"'             "vllm deploy: 2 whole GPUs (tp=2)"
_has "$y" 'schedulerName: hami-scheduler'       "vllm deploy: HAMi scheduler"
_has "$y" 'runtimeClassName: biren'             "vllm deploy: runtimeClassName=biren"
_has "$y" 'birentech.com: gpu'                  "vllm deploy: default nodeSelector"
_has "$y" 'cpu: "32"'                           "vllm deploy: cpu req=32"
_has "$y" 'cpu: "64"'                           "vllm deploy: cpu lim=64"
_has "$y" 'memory: "256Gi"'                     "vllm deploy: mem=256Gi (2×128)"
_has "$y" 'namespace: vllm'                     "vllm deploy: namespace=vllm"
_has "$y" 'framework: vllm'                     "vllm deploy: framework label"
_has "$y" 'infer.birentech.com/config-file:'    "vllm deploy: unified config annotation"
_has "$y" 'infer.birentech.com/server-script:'  "vllm deploy: unified server annotation"
_has "$y" 'VLLM_USE_V1'                         "vllm deploy: VLLM env present"
_has "$y" 'name: llm-tree'                       "vllm deploy: llm-tree volume"
_has "$y" 'readinessProbe:'                      "vllm deploy: readinessProbe"
_hasnt "$y" 'nodeName:'                          "vllm deploy: no nodeName"
_hasnt "$y" 'BRTB_PLAN_ID_RENEW'                 "vllm deploy: no sglang env"

section "2. vLLM deploy — --node / --label / --replicas / resources"
_gen --task deploy --gpu --node brhost-02 "$V_MODEL"
y="${DEPLOY_DIR}/${V_MODEL}-deploy-node-brhost-02-p28800-r1.yaml"
_file_exists "$y" "vllm deploy+node: filename includes node"
_has "$y" 'nodeName: brhost-02'  "vllm deploy+node: nodeName set"
_hasnt "$y" 'nodeSelector:'       "vllm deploy+node: no nodeSelector"
_gen --task deploy --gpu --label "kubernetes.io/hostname=brhost-02" "$V_MODEL"
y="${DEPLOY_DIR}/${V_MODEL}-deploy-label-brhost-02-p28800-r1.yaml"
_file_exists "$y" "vllm deploy+label: filename includes label value"
_has "$y" 'kubernetes.io/hostname: brhost-02' "vllm deploy+label: label kv"
_gen --task deploy --gpu --node brhost-02 --replicas 3 "$V_MODEL"
y="${DEPLOY_DIR}/${V_MODEL}-deploy-node-brhost-02-p28800-r3.yaml"
_file_exists "$y" "vllm deploy+replicas: filename has r3"
_has "$y" 'replicas: 3'  "vllm deploy+replicas: replicas=3"
_gen --task deploy --gpu --node brhost-02 --cpu 16 --mem-per-gpu 64 "$V_MODEL"
y="${DEPLOY_DIR}/${V_MODEL}-deploy-node-brhost-02-p28800-r1.yaml"
_has "$y" 'cpu: "16"'        "vllm resources: cpu req=16"
_has "$y" 'memory: "128Gi"'  "vllm resources: mem=128Gi (2×64)"

section "3. vLLM pod — --gpu"
_gen --task pod --gpu "$V_MODEL"
y="${POD_DIR}/${V_MODEL}-pod-p28800.yaml"
_file_exists "$y" "vllm pod: filename (no replicas)"
_has "$y" 'kind: Pod'             "vllm pod: kind=Pod"
_has "$y" 'restartPolicy: Never'  "vllm pod: restartPolicy=Never"
_has "$y" 'sleep'                 "vllm pod: args sleep"
_has "$y" 'schedulerName: hami-scheduler' "vllm pod: HAMi scheduler"
_hasnt "$y" 'kind: Service'       "vllm pod: no Service"
_hasnt "$y" 'readinessProbe:'     "vllm pod: no readinessProbe"

section "4. vLLM SVI / vGPU (single-GPU model bge-m3)"
_gen --task deploy --svi 1in2 "$V_GPU1"
y="${DEPLOY_DIR}/${V_GPU1}-deploy-svi-1in2-p28800-r1.yaml"
_file_exists "$y" "svi-1in2: filename suffix"
_has "$y" 'birentech.com/1-2-gpu: "1"'   "svi-1in2: one 1/2 SVI instance"
_has "$y" 'name: vllm-bge-m3-svi-1in2'   "svi-1in2: k8s name carries suffix"
_hasnt "$y" 'birentech.com/gpu: '         "svi-1in2: no whole-card resource"
_gen --task deploy --svi 1in4 "$V_GPU1"
y="${DEPLOY_DIR}/${V_GPU1}-deploy-svi-1in4-p28800-r1.yaml"
_has "$y" 'birentech.com/1-4-gpu: "1"'   "svi-1in4: one 1/4 SVI instance"
_gen --task deploy --vgpu-core 8 --vgpu-mem 16 "$V_GPU1"
y="${DEPLOY_DIR}/${V_GPU1}-deploy-vgpu-c8-m16g-p28800-r1.yaml"
_file_exists "$y" "vgpu: filename suffix"
_has "$y" 'birentech.com/vgpu: "1"'          "vgpu: one vgpu device"
_has "$y" 'birentech.com/vgpu-cores: "8"'    "vgpu: cores=8"
_has "$y" 'birentech.com/vgpu-memory: "16384"' "vgpu: memory=16384MB (16GiB)"

section "5. SGLang deploy / pod — --gpu whole card (tp=4)"
_gen --task deploy --gpu "$S_MODEL"
y="${DEPLOY_DIR}/${S_MODEL}-deploy-p28800-r1.yaml"
_file_exists "$y" "sglang deploy: filename"
_has "$y" 'namespace: sglang'             "sglang deploy: namespace=sglang"
_has "$y" 'birentech.com/gpu: "4"'       "sglang deploy: 4 GPUs (tp=4)"
_has "$y" 'memory: "512Gi"'               "sglang deploy: mem=512Gi (4×128)"
_has "$y" 'nodePort: 30900'               "sglang deploy: nodePort from config"
_has "$y" 'framework: sglang'             "sglang deploy: framework label"
_has "$y" 'BRTB_PLAN_ID_RENEW'            "sglang deploy: BRTB env present"
_has "$y" 'schedulerName: hami-scheduler' "sglang deploy: HAMi scheduler"
_hasnt "$y" 'VLLM_USE_V1'                 "sglang deploy: no vLLM env"
_gen --task pod --gpu "$S_MODEL"
y="${POD_DIR}/${S_MODEL}-pod-p28800.yaml"
_file_exists "$y" "sglang pod: filename"
_has "$y" 'kind: Pod'                     "sglang pod: kind=Pod"
_has "$y" 'infer.birentech.com/framework:' "sglang pod: unified framework annotation"

section "6. Error cases"
_gen --task deploy "$V_MODEL"                         && _fail "missing GPU mode: should fail"   || _pass "missing GPU mode rejected"
_gen --task deploy --gpu --svi 1in2 "$V_GPU1"         && _fail "gpu+svi: should fail"            || _pass "mode mutual exclusion (--gpu+--svi) rejected"
_gen --task deploy --vgpu-core 8 "$V_GPU1"            && _fail "vgpu missing mem: should fail"   || _pass "vgpu requires both core+mem rejected"
_gen --task deploy --svi 1in2 "$V_MODEL"             && _fail "svi on multi-GPU: should fail"   || _pass "svi requires single-GPU (qwen3-32b tp=2) rejected"
_gen --task deploy --svi 1in3 "$V_GPU1"              && _fail "invalid svi: should fail"        || _pass "invalid --svi 1in3 rejected"
_gen --task deploy --vgpu-core 40 --vgpu-mem 16 "$V_GPU1" && _fail "vgpu-core>32: should fail"  || _pass "--vgpu-core out of range rejected"
_gen --task deploy --vgpu-core 8 --vgpu-mem 128 "$V_GPU1" && _fail "vgpu-mem>64: should fail"   || _pass "--vgpu-mem > 64G rejected"
_gen --task deploy --gpu --node n1 --label k=v "$V_MODEL" && _fail "node+label: should fail"    || _pass "--node + --label rejected"
_gen --gpu "$V_MODEL"                                 && _fail "missing --task: should fail"    || _pass "missing --task rejected"
_gen --task deploy --gpu --replicas 0 "$V_MODEL"      && _fail "replicas 0: should fail"        || _pass "invalid --replicas 0 rejected"
_gen --task deploy --gpu --label badlabel "$V_MODEL"  && _fail "bad label: should fail"         || _pass "malformed --label rejected"

echo ""
echo "════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
printf "  Results: \033[1;32m%d passed\033[0m / \033[0;31m%d failed\033[0m / %d total\n" "$PASS" "$FAIL" "$TOTAL"
echo "════════════════════════════════════════"
echo ""
[[ "$FAIL" -eq 0 ]]
