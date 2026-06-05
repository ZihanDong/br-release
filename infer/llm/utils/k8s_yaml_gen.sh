#!/usr/bin/env bash
# Generate a Kubernetes YAML for a vLLM or SGLang server (unified generator).
#
# Reads a model config from infer/llm/configs/ via utils/parse_config.sh, then
# branches on its framework= field (vllm | sglang) to pick namespace, image,
# server script, and BirenTech env vars. The scheduling / resource / GPU-mode
# logic is identical for both frameworks. Saves the result to
#   configs/pod/<framework>_<model>[...].yaml      (--task pod)
#   configs/deploy/<framework>_<model>[...].yaml   (--task deploy)
# and does NOT apply it.
#
# Usage:
#   bash utils/k8s_yaml_gen.sh --task <pod|deploy> <gpu-mode> [options] <config_ref>
#
# Required:
#   --task <pod|deploy>    Workload type.
#
# GPU resource mode (REQUIRED — exactly one; all scheduled by hami-scheduler):
#   --gpu                  Whole card(s): birentech.com/gpu = tensor*pipeline size.
#   --svi <1in2|1in4>      ONE SVI hard-partition instance
#                          (1in2 -> birentech.com/1-2-gpu, 1in4 -> birentech.com/1-4-gpu = 1).
#   --vgpu-core <1-32>     ONE vGPU soft-partition (used together): birentech.com/vgpu=1 +
#   --vgpu-mem  <1-64>     vgpu-cores=<core> + vgpu-memory=<mem×1024 MB> (GiB, <= 64G).
#   --svi and --vgpu are single-device partitions, so they REQUIRE a single-GPU
#   config (tensor*pipeline = 1) and add a "-svi-<g>" / "-vgpu-c<n>-m<g>g" suffix.
#
# Scheduling (mutually exclusive; default: nodeSelector birentech.com=gpu):
#   --node <nodename>      Hard-pin to a specific node (nodeName).
#   --label <key=value>    Node label selector (nodeSelector).
#
# Resources (per-instance; defaults: cpu=32, mem=128Gi/GPU):
#   --cpu <n>              CPU cores (request=n, limit=2n). Default: 32.
#   --mem-per-gpu <n>      Memory per GPU in Gi (request=limit=n×gpus). Default: 128.
#
# Scale (deploy only):
#   --replicas <n>         Number of Deployment replicas. Default: 1.
#
# config_ref is resolved by parse_config.sh (bare name / prefixed / path / absolute).
#
# After generating, review the YAML and apply with:
#   bash utils/k8s_apply.sh <generated.yaml>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # .../infer/llm/utils
LLM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"                    # .../infer/llm

# parse_config.sh sets CONFIGS_DIR and provides parse_config.
# shellcheck source=./parse_config.sh
source "${SCRIPT_DIR}/parse_config.sh"

# parse_image_list.sh provides parse_image_list (optional --env base-image selection).
# shellcheck source=./parse_image_list.sh
source "${SCRIPT_DIR}/parse_image_list.sh"

# ── Framework defaults (used when a config omits k8s_image) ────────────────────
_VLLM_K8S_IMAGE='172.25.198.36:32000/infer/birensupa-smartinfer-vllm:26.04.rc2-py310-pt2.8.0-br1xx'
_SGLANG_K8S_IMAGE='172.25.198.36:32000/infer/birensupa-smartinfer-sglang:26.04.rc2-py310-pt2.9.0-br1xx'

# ── Helpers ────────────────────────────────────────────────────────────────────
_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

usage() {
    echo ""
    echo "Usage: $0 --task <pod|deploy> <--gpu|--svi <1in2|1in4>|--vgpu-core N --vgpu-mem G> [options] <config_ref>"
    echo ""
    echo "  --task <pod|deploy>    Required. Workload type."
    echo ""
    echo "  GPU resource mode (REQUIRED — pick exactly one; all use the HAMi scheduler):"
    echo "  --gpu                  Whole card(s): birentech.com/gpu = tp×pp (from the config)."
    echo "  --svi <1in2|1in4>      One SVI hard-partition instance (birentech.com/1-2-gpu|1-4-gpu=1)."
    echo "  --vgpu-core <1-32>     vGPU soft-partition SPC quota.            } use together;"
    echo "  --vgpu-mem  <1-64>     vGPU soft-partition HBM quota in GiB(<=64G).} birentech.com/vgpu=1"
    echo "                         (--svi and --vgpu require a single-GPU config, i.e. tp×pp=1)."
    echo ""
    echo "  Scheduling (mutually exclusive; default: nodeSelector birentech.com=gpu):"
    echo "  --node <nodename>      Pin to a specific node (nodeName)."
    echo "  --label <key=value>    Node label selector."
    echo ""
    echo "  Resources:"
    echo "  --cpu <n>              CPU cores per replica (default: 32; limit=2n)."
    echo "  --mem-per-gpu <n>      Memory in Gi per GPU (default: 128; request=limit=n×gpus)."
    echo ""
    echo "  Scale (deploy only):"
    echo "  --replicas <n>         Deployment replicas (default: 1)."
    echo ""
    echo "  Base image (optional; default: image from the model config):"
    echo "  --env <name>           Use a base image (+ in-container setup) from the image list."
    echo "  --env-list <file>      Image-list file (default: <framework>/<framework>_images.list)."
    echo ""
    echo "Available configs:"
    for f in "${CONFIGS_DIR}/"*.conf; do
        [[ -f "$f" ]] && echo "  $(basename "$f" .conf)"
    done
    echo ""
    exit 1
}

# ── Parse arguments ────────────────────────────────────────────────────────────
K8S_TYPE=""
CONFIG_ARG=""
OPT_NODE=""
OPT_LABEL=""
OPT_CPU=32
OPT_MEM_PER_GPU=128
OPT_REPLICAS=1
OPT_GPU=false        # --gpu               whole card(s), count = tp*pp
OPT_SVI=""           # --svi <1in2|1in4>   one SVI hard-partition instance
OPT_VGPU_CORE=""     # --vgpu-core <1-32>  vGPU soft-partition SPC quota
OPT_VGPU_MEM=""      # --vgpu-mem  <1-64>  vGPU soft-partition HBM quota (GiB)
ENV_NAME=""          # --env <name>        base image from the framework image list
ENV_LIST=""          # --env-list <file>   override the default image-list file

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)        [[ $# -lt 2 ]] && { _err "--task requires an argument (pod|deploy)"; usage; }; K8S_TYPE="$2"; shift 2 ;;
        --env)         [[ $# -lt 2 ]] && { _err "--env requires a name argument"; usage; }; ENV_NAME="$2"; shift 2 ;;
        --env-list)    [[ $# -lt 2 ]] && { _err "--env-list requires a file argument"; usage; }; ENV_LIST="$2"; shift 2 ;;
        --node)        [[ $# -lt 2 ]] && { _err "--node requires a nodename argument"; usage; }; OPT_NODE="$2"; shift 2 ;;
        --label)       [[ $# -lt 2 ]] && { _err "--label requires a key=value argument"; usage; }; OPT_LABEL="$2"; shift 2 ;;
        --cpu)         [[ $# -lt 2 ]] && { _err "--cpu requires a numeric argument"; usage; }; OPT_CPU="$2"; shift 2 ;;
        --mem-per-gpu) [[ $# -lt 2 ]] && { _err "--mem-per-gpu requires a numeric argument"; usage; }; OPT_MEM_PER_GPU="$2"; shift 2 ;;
        --replicas)    [[ $# -lt 2 ]] && { _err "--replicas requires a numeric argument"; usage; }; OPT_REPLICAS="$2"; shift 2 ;;
        --gpu)         OPT_GPU=true; shift ;;
        --svi)         [[ $# -lt 2 ]] && { _err "--svi requires an argument (1in2|1in4)"; usage; }; OPT_SVI="$2"; shift 2 ;;
        --vgpu-core)   [[ $# -lt 2 ]] && { _err "--vgpu-core requires a numeric argument (1-32)"; usage; }; OPT_VGPU_CORE="$2"; shift 2 ;;
        --vgpu-mem)    [[ $# -lt 2 ]] && { _err "--vgpu-mem requires a numeric argument (1-64, GiB)"; usage; }; OPT_VGPU_MEM="$2"; shift 2 ;;
        -*)            _err "Unknown option: $1"; usage ;;
        *)             CONFIG_ARG="$1"; shift ;;
    esac
done

# ── Validate arguments ─────────────────────────────────────────────────────────
[[ -z "$K8S_TYPE" ]] && { _err "--task is required."; usage; }
[[ "$K8S_TYPE" != "pod" && "$K8S_TYPE" != "deploy" ]] && { _err "--task must be 'pod' or 'deploy', got: '${K8S_TYPE}'"; usage; }
[[ -z "$CONFIG_ARG" ]] && { _err "A config file is required."; usage; }
[[ -n "$OPT_NODE" && -n "$OPT_LABEL" ]] && { _err "--node and --label are mutually exclusive."; usage; }
[[ -n "$OPT_LABEL" && "$OPT_LABEL" != *=* ]] && { _err "--label must be in key=value format, got: '${OPT_LABEL}'"; exit 1; }
[[ ! "$OPT_CPU" =~ ^[0-9]+$ || "$OPT_CPU" -lt 1 ]] && { _err "--cpu must be a positive integer"; exit 1; }
[[ ! "$OPT_MEM_PER_GPU" =~ ^[0-9]+$ || "$OPT_MEM_PER_GPU" -lt 1 ]] && { _err "--mem-per-gpu must be a positive integer"; exit 1; }
[[ ! "$OPT_REPLICAS" =~ ^[0-9]+$ || "$OPT_REPLICAS" -lt 1 ]] && { _err "--replicas must be a positive integer"; exit 1; }

# ── GPU resource mode: --gpu | --svi | --vgpu (mutually exclusive, exactly one) ──
GPU_MODE=""
_modes=0
$OPT_GPU                                         && { GPU_MODE="gpu";  _modes=$((_modes+1)); }
[[ -n "$OPT_SVI" ]]                              && { GPU_MODE="svi";  _modes=$((_modes+1)); }
[[ -n "$OPT_VGPU_CORE" || -n "$OPT_VGPU_MEM" ]]  && { GPU_MODE="vgpu"; _modes=$((_modes+1)); }
[[ "$_modes" -eq 0 ]] && { _err "A GPU resource mode is required: --gpu | --svi <1in2|1in4> | --vgpu-core <N> --vgpu-mem <G>"; usage; }
[[ "$_modes" -gt 1 ]] && { _err "--gpu, --svi and --vgpu-core/--vgpu-mem are mutually exclusive — pick exactly one."; usage; }

if [[ "$GPU_MODE" == "svi" ]]; then
    case "$OPT_SVI" in
        1in2|1in4) ;;
        *) _err "--svi must be '1in2' or '1in4', got: '${OPT_SVI}'"; usage ;;
    esac
fi
if [[ "$GPU_MODE" == "vgpu" ]]; then
    [[ -z "$OPT_VGPU_CORE" || -z "$OPT_VGPU_MEM" ]] && { _err "vGPU mode needs BOTH --vgpu-core <N> and --vgpu-mem <G>."; usage; }
    [[ ! "$OPT_VGPU_CORE" =~ ^[0-9]+$ || "$OPT_VGPU_CORE" -lt 1 || "$OPT_VGPU_CORE" -gt 32 ]] && {
        _err "--vgpu-core must be an integer in 1..32 (SPC compute units), got: '${OPT_VGPU_CORE}'"; exit 1; }
    _vmem="${OPT_VGPU_MEM%[Gg]i}"; _vmem="${_vmem%[Gg]}"
    [[ ! "$_vmem" =~ ^[0-9]+$ || "$_vmem" -lt 1 || "$_vmem" -gt 64 ]] && {
        _err "--vgpu-mem must be an integer in 1..64 (GiB HBM, <= 64G), got: '${OPT_VGPU_MEM}'"; exit 1; }
    VGPU_MEM_GIB="$_vmem"
    VGPU_MEM_MB=$(( _vmem * 1024 ))   # birentech.com/vgpu-memory is in MB
fi

# ── Parse + validate config (framework read from the config) ───────────────────
parse_config "$CONFIG_ARG" || usage

# ── Framework-specific selections ──────────────────────────────────────────────
case "$framework" in
    vllm)
        K8S_NAMESPACE="vllm"
        INNER_SCRIPT="${LLM_DIR}/vllm/vllm_server.sh"
        DEFAULT_IMAGE="$_VLLM_K8S_IMAGE"
        DEFAULT_ENV_LIST="${LLM_DIR}/vllm/vllm_images.list"
        SERVER_CONTAINER="vllm-server" ;;
    sglang)
        K8S_NAMESPACE="sglang"
        INNER_SCRIPT="${LLM_DIR}/sglang/sglang_server.sh"
        DEFAULT_IMAGE="$_SGLANG_K8S_IMAGE"
        DEFAULT_ENV_LIST="${LLM_DIR}/sglang/sglang_images.list"
        SERVER_CONTAINER="sglang-server" ;;
    *)
        _err "framework '${framework}' has no k8s generator support yet."; exit 1 ;;
esac
CONTAINER_IMAGE="${k8s_image:-$DEFAULT_IMAGE}"

# ── Optional --env: base image (+ in-container setup) from the framework image list ──
# Overrides the image; IMG_SETUP (if any) is prepended to the container's auto-run
# command in the generated YAML (run before everything else). No --env -> unchanged.
[[ -z "$ENV_LIST" ]] && ENV_LIST="$DEFAULT_ENV_LIST"
ENV_SETUP=""
if [[ -n "$ENV_NAME" ]]; then
    parse_image_list "$ENV_LIST" "$ENV_NAME" || exit 1
    CONTAINER_IMAGE="$IMG_NAME"
    ENV_SETUP="$IMG_SETUP"
    _info "Env         : ${ENV_NAME}  (${ENV_LIST##*/})${IMG_DESC:+  — ${IMG_DESC}}"
fi

[[ "$K8S_TYPE" == "deploy" && -z "${k8s_nodeport:-}" ]] && {
    _err "k8s_nodeport not set in $(basename "$CONFIG_FILE") (required for deploy type)"; exit 1; }

_info "Config      : $(basename "$CONFIG_FILE")  [framework=${framework} task=${K8S_TYPE}]"
_info "Model key   : $model_weights  |  port=$port  |  tp=$tensor_parallel_size  pp=$pipeline_parallel_size"
_info "Image       : $CONTAINER_IMAGE"

# ── Registry lookup + weight check/download ────────────────────────────────────
# shellcheck source=../model_registry.sh
source "${LLM_DIR}/model_registry.sh"
parse_model "$model_weights" || exit 1
MODEL_LOCAL_PATH="$MODEL_PATH"
_info "Registry    : path=$MODEL_LOCAL_PATH  download=$DOWNLOAD_NAME  status=$DIR_STATUS"

if [[ "$DIR_STATUS" == "ok" ]]; then
    _ok "Weights     : $MODEL_LOCAL_PATH"
else
    _warn "Local weights not found (${MODEL_LOCAL_PATH:-(path not configured)}, status: $DIR_STATUS)"
    read -rp "  Download now? [y/N]: " yn
    [[ ! "$yn" =~ ^[Yy]$ ]] && { _err "Cannot generate YAML without model weights. Exiting."; exit 1; }
    echo "  1) modelscope   2) huggingface"
    read -rp "  Choose [1/2]: " src
    mkdir -p "$MODEL_LOCAL_PATH"
    case "$src" in
        1) modelscope download --model "$DOWNLOAD_NAME" --local_dir "$MODEL_LOCAL_PATH" ;;
        2) huggingface-cli download "$DOWNLOAD_NAME" --local-dir "$MODEL_LOCAL_PATH" ;;
        *) _err "Invalid choice."; exit 1 ;;
    esac
    _ok "Downloaded  : $MODEL_LOCAL_PATH"
fi

# ── GPU count and resource sizing ─────────────────────────────────────────────
gpu_needed=$((tensor_parallel_size * pipeline_parallel_size))

# All three forms are scheduled by the unified HAMi-Biren plugin (no admission
# webhook), so every GPU workload sets schedulerName: hami-scheduler.
GPU_RES_NAME="birentech.com/gpu"
GPU_RES_QTY="$gpu_needed"
VGPU_SUFFIX=""
_hami_sched_deploy="      schedulerName: hami-scheduler"
_hami_sched_pod="  schedulerName: hami-scheduler"

case "$GPU_MODE" in
    gpu) : ;;  # whole card(s): birentech.com/gpu = tp*pp (set above)
    svi)
        [[ "$gpu_needed" -ne 1 ]] && {
            _err "--svi requires a single-GPU model config, but $(basename "$CONFIG_FILE") has tp*pp=${gpu_needed} (tp=${tensor_parallel_size}, pp=${pipeline_parallel_size})."; exit 1; }
        case "$OPT_SVI" in
            1in2) GPU_RES_NAME="birentech.com/1-2-gpu"; VGPU_SUFFIX="-svi-1in2" ;;
            1in4) GPU_RES_NAME="birentech.com/1-4-gpu"; VGPU_SUFFIX="-svi-1in4" ;;
        esac
        GPU_RES_QTY=1 ;;
    vgpu)
        [[ "$gpu_needed" -ne 1 ]] && {
            _err "--vgpu requires a single-GPU model config, but $(basename "$CONFIG_FILE") has tp*pp=${gpu_needed} (tp=${tensor_parallel_size}, pp=${pipeline_parallel_size})."; exit 1; }
        GPU_RES_NAME="birentech.com/vgpu"
        GPU_RES_QTY=1
        VGPU_SUFFIX="-vgpu-c${OPT_VGPU_CORE}-m${VGPU_MEM_GIB}g" ;;
esac

cpu_lim=$((OPT_CPU * 2))
mem_gi=$((gpu_needed * OPT_MEM_PER_GPU))

case "$GPU_MODE" in
    gpu)  _info "GPU mode    : whole card  ${GPU_RES_NAME}=${GPU_RES_QTY}  (tp=${tensor_parallel_size} × pp=${pipeline_parallel_size})" ;;
    svi)  _info "GPU mode    : SVI ${OPT_SVI}  ${GPU_RES_NAME}=1  (hard partition)" ;;
    vgpu) _info "GPU mode    : vGPU  birentech.com/vgpu=1 cores=${OPT_VGPU_CORE} memory=${VGPU_MEM_MB}MB (${VGPU_MEM_GIB}GiB)  (soft partition)" ;;
esac

# GPU resource line(s) for the requests/limits blocks. vGPU adds cores + memory.
# Deployment container indent = 12 spaces, Pod container = 8 spaces.
_gpu_res_lines() {
    local ind="$1"
    printf '%s%s: "%s"\n' "$ind" "$GPU_RES_NAME" "$GPU_RES_QTY"
    if [[ "$GPU_MODE" == "vgpu" ]]; then
        printf '%sbirentech.com/vgpu-cores: "%s"\n'  "$ind" "$OPT_VGPU_CORE"
        printf '%sbirentech.com/vgpu-memory: "%s"\n' "$ind" "$VGPU_MEM_MB"
    fi
}
GPU_RES_DEPLOY="$(_gpu_res_lines '            ')"   # 12-space indent (Deployment)
GPU_RES_POD="$(_gpu_res_lines '        ')"          # 8-space indent (Pod)
_info "Resources   : cpu req=${OPT_CPU} lim=${cpu_lim}  mem=${mem_gi}Gi (${OPT_MEM_PER_GPU}Gi/GPU)"
[[ "$K8S_TYPE" == "deploy" ]] && _info "Replicas    : ${OPT_REPLICAS}"

# ── BirenTech env block (framework-specific) ───────────────────────────────────
_env_lines() {  # $1 = indent for "- name:"
    local ind="$1"
    if [[ "$framework" == "vllm" ]]; then
        printf '%s- name: VLLM_USE_V1\n%s  value: "1"\n' "$ind" "$ind"
        printf '%s- name: VLLM_WORKER_MULTIPROC_METHOD\n%s  value: spawn\n' "$ind" "$ind"
        printf '%s- name: VLLM_BR_WEIGHT_TYPE\n%s  value: NUMA\n' "$ind" "$ind"
    else
        local v
        for v in BRTB_PLAN_ID_RENEW BRTB_DISABLE_ZERO_REORDER BRTB_DISABLE_ZERO_OUTPUT_NUMA \
                 BRTB_DISABLE_ZERO_OUTPUT_UMA BRTB_DISABLE_ZERO_WS BRTB_DISABLE_L2_FLUSH BRTB_ENABLE_SUPA_FILL; do
            printf '%s- name: %s\n%s  value: "1"\n' "$ind" "$v" "$ind"
        done
    fi
}
ENV_DEPLOY="$(_env_lines '        ')"   # 8-space indent (Deployment container)
ENV_POD="$(_env_lines '    ')"          # 4-space indent (Pod container)

# ── Resolve node scheduling ───────────────────────────────────────────────────
_DEFAULT_LABEL=false
if [[ -n "$OPT_NODE" ]]; then
    SCHED_TYPE="node"
    _info "Scheduling  : nodeName=${OPT_NODE}"
elif [[ -n "$OPT_LABEL" ]]; then
    SCHED_TYPE="label"
    LABEL_KEY="${OPT_LABEL%%=*}"
    LABEL_VAL="${OPT_LABEL#*=}"
    _info "Scheduling  : nodeSelector ${LABEL_KEY}=${LABEL_VAL}"
else
    SCHED_TYPE="label"
    LABEL_KEY="birentech.com"
    LABEL_VAL="gpu"
    _DEFAULT_LABEL=true
    # Whole-card: check a node has enough free birentech.com/gpu. SVI/vGPU are
    # provisioned on demand (allocatable 0 at rest), so only check a GPU node exists.
    if [[ "$GPU_MODE" == "gpu" ]]; then
        _avail=$(kubectl get nodes -l birentech.com=gpu -o json 2>/dev/null | python3 -c "
import sys, json
need=$gpu_needed; res='$GPU_RES_NAME'; ok=0
try:
    for n in json.load(sys.stdin).get('items', []):
        q = n.get('status', {}).get('allocatable', {}).get(res, '0')
        if int(q) >= need: ok = 1
except Exception:
    pass
print(ok)" 2>/dev/null || echo 0)
        [[ "$_avail" != "1" ]] && _warn "No GPU node with >= $gpu_needed ${GPU_RES_NAME} found; pod will stay Pending."
    else
        _ncount=$(kubectl get nodes -l birentech.com=gpu --no-headers 2>/dev/null | wc -l)
        [[ "${_ncount:-0}" -eq 0 ]] && _warn "No birentech.com=gpu node found; ${GPU_MODE} pod will stay Pending."
    fi
    _info "Scheduling  : nodeSelector birentech.com=gpu (default)"
fi

# ── Scheduling YAML snippets (deploy template.spec = 6 spaces; pod spec = 2) ───
if [[ "$SCHED_TYPE" == "node" ]]; then
    _sched_deploy="      nodeName: ${OPT_NODE}"
    _sched_pod="  nodeName: ${OPT_NODE}"
else
    _sched_deploy="      nodeSelector:
        ${LABEL_KEY}: ${LABEL_VAL}"
    _sched_pod="  nodeSelector:
    ${LABEL_KEY}: ${LABEL_VAL}"
fi

# ── Build output filename ─────────────────────────────────────────────────────
_sched_suffix=""
if [[ "$SCHED_TYPE" == "node" ]]; then
    _sched_suffix="-node-${OPT_NODE//./-}"
elif [[ "$SCHED_TYPE" == "label" ]] && ! $_DEFAULT_LABEL; then
    _safe_val="${LABEL_VAL//[^a-zA-Z0-9_-]/-}"
    _sched_suffix="-label-${_safe_val}"
fi

if [[ "$K8S_TYPE" == "deploy" ]]; then
    OUT_DIR="${CONFIGS_DIR}/deploy"
    OUT_YAML="${OUT_DIR}/${framework}_${model_weights}-deploy${VGPU_SUFFIX}${_sched_suffix}-p${port}-r${OPT_REPLICAS}.yaml"
else
    OUT_DIR="${CONFIGS_DIR}/pod"
    OUT_YAML="${OUT_DIR}/${framework}_${model_weights}-pod${VGPU_SUFFIX}${_sched_suffix}-p${port}.yaml"
fi
mkdir -p "$OUT_DIR"

# ── k8s names (DNS-1035: dots -> dashes). Framework prefix keeps vllm/sglang ───
# variants of the same model distinct. vGPU suffix keeps half/quarter distinct.
k8s_name="${framework}-${model_weights//./-}${VGPU_SUFFIX}"
APP_LABEL="$k8s_name"
DEPLOY_NAME="$k8s_name"
SVC_NAME="$k8s_name"
POD_NAME="$k8s_name"

initial_delay_ready=$(( gpu_needed * 120 + 60 ))
initial_delay_live=$(( gpu_needed * 180 + 60 ))

# ── Shared volume/volumeMount snippets ─────────────────────────────────────────
# Mount the whole infer/llm tree read-only (covers the server script, configs/,
# utils/parse_config.sh, and model_registry.*) at the same host path, plus model
# weights, the BirenTech driver, and a shared-memory emptyDir.
_vol_mounts="        volumeMounts:
        - name: llm-tree
          mountPath: ${LLM_DIR}
          readOnly: true
        - name: model-weights
          mountPath: /data/models
          readOnly: true
        - name: biren-driver
          mountPath: /usr/local/birensupa/driver
          readOnly: true
        - name: dshm
          mountPath: /dev/shm"

_volumes="      volumes:
      - name: llm-tree
        hostPath:
          path: ${LLM_DIR}
          type: Directory
      - name: model-weights
        hostPath:
          path: /data/models
          type: Directory
      - name: biren-driver
        hostPath:
          path: /usr/local/birensupa/driver
          type: Directory
      - name: dshm
        emptyDir:
          medium: Memory
          sizeLimit: 256Gi"

# Pod-level indents: container fields = 4 spaces, volumes = 2 spaces.
_pod_vol_mounts="    volumeMounts:
    - name: llm-tree
      mountPath: ${LLM_DIR}
      readOnly: true
    - name: model-weights
      mountPath: /data/models
      readOnly: true
    - name: biren-driver
      mountPath: /usr/local/birensupa/driver
      readOnly: true
    - name: dshm
      mountPath: /dev/shm"

_pod_volumes="  volumes:
  - name: llm-tree
    hostPath:
      path: ${LLM_DIR}
      type: Directory
  - name: model-weights
    hostPath:
      path: /data/models
      type: Directory
  - name: biren-driver
    hostPath:
      path: /usr/local/birensupa/driver
      type: Directory
  - name: dshm
    emptyDir:
      medium: Memory
      sizeLimit: 256Gi"

# ── Container args (optionally prepend --env setup before the auto-run command) ──
# No 'command:' field is set, so the image ENTRYPOINT (biren_entrypoint.sh) runs
# first and sets LD_LIBRARY_PATH, then exec's these args. With --env setup, the
# args become a single `bash -c` so the setup runs before the server / idle loop.
if [[ -n "$ENV_SETUP" ]]; then
    ARGS_DEPLOY=$(printf '        args:\n        - bash\n        - -c\n        - "%s && exec bash %s %s"' "$ENV_SETUP" "$INNER_SCRIPT" "$CONFIG_FILE")
    ARGS_POD=$(printf '    args:\n    - bash\n    - -c\n    - "%s; exec sleep infinity"' "$ENV_SETUP")
else
    ARGS_DEPLOY=$(printf '        args:\n        - bash\n        - "%s"\n        - "%s"' "$INNER_SCRIPT" "$CONFIG_FILE")
    ARGS_POD=$(printf '    args:\n    - sleep\n    - infinity')
fi

# ══════════════════════════════════════════════════════════════════════════════
# Write YAML
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$K8S_TYPE" == "deploy" ]]; then

cat > "$OUT_YAML" <<YAML
# Generated by utils/k8s_yaml_gen.sh  framework=${framework}  model=${model_weights}  config=$(basename "$CONFIG_FILE")  task=deploy  replicas=${OPT_REPLICAS}
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${K8S_NAMESPACE}

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NAME}
  namespace: ${K8S_NAMESPACE}
  annotations:
    infer.birentech.com/framework: "${framework}"
    infer.birentech.com/config-file: "${CONFIG_FILE}"
    infer.birentech.com/server-script: "${INNER_SCRIPT}"
  labels:
    app: ${APP_LABEL}
    model: ${model_weights}
    framework: ${framework}
spec:
  replicas: ${OPT_REPLICAS}
  selector:
    matchLabels:
      app: ${APP_LABEL}
  template:
    metadata:
      labels:
        app: ${APP_LABEL}
        model: ${model_weights}
        framework: ${framework}
    spec:
      # RuntimeClass 'biren' injects /dev/biren-m and the allocated /dev/biren/card_N
      # devices (BirenTech Container Toolkit). The unified HAMi-Biren plugin places
      # GPU pods via hami-scheduler (topology-aware; <=4 cards land in one 4-card
      # high-speed interconnect group). No admission webhook -> schedulerName explicit.
      runtimeClassName: biren
${_hami_sched_deploy}
${_sched_deploy}
      containers:
      - name: ${SERVER_CONTAINER}
        image: ${CONTAINER_IMAGE}
        imagePullPolicy: IfNotPresent
        # No 'command' field — preserves the image ENTRYPOINT (biren_entrypoint.sh),
        # which sets LD_LIBRARY_PATH before exec'ing the args.
${ARGS_DEPLOY}
        env:
${ENV_DEPLOY}
        ports:
        - name: http
          containerPort: ${port}
          protocol: TCP
        resources:
          requests:
${GPU_RES_DEPLOY}
            cpu: "${OPT_CPU}"
            memory: "${mem_gi}Gi"
          limits:
${GPU_RES_DEPLOY}
            cpu: "${cpu_lim}"
            memory: "${mem_gi}Gi"
        securityContext:
          capabilities:
            add:
            - IPC_LOCK
        readinessProbe:
          httpGet:
            path: /health
            port: ${port}
          initialDelaySeconds: ${initial_delay_ready}
          periodSeconds: 15
          failureThreshold: 8
          timeoutSeconds: 10
        livenessProbe:
          httpGet:
            path: /health
            port: ${port}
          initialDelaySeconds: ${initial_delay_live}
          periodSeconds: 30
          failureThreshold: 3
          timeoutSeconds: 10
${_vol_mounts}
${_volumes}

---
apiVersion: v1
kind: Service
metadata:
  name: ${SVC_NAME}
  namespace: ${K8S_NAMESPACE}
  labels:
    app: ${APP_LABEL}
    model: ${model_weights}
    framework: ${framework}
spec:
  type: NodePort
  selector:
    app: ${APP_LABEL}
  ports:
  - name: http
    port: ${port}
    targetPort: ${port}
    nodePort: ${k8s_nodeport}
    protocol: TCP
YAML

else  # pod

cat > "$OUT_YAML" <<YAML
# Generated by utils/k8s_yaml_gen.sh  framework=${framework}  model=${model_weights}  config=$(basename "$CONFIG_FILE")  task=pod
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${K8S_NAMESPACE}

---
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${K8S_NAMESPACE}
  annotations:
    infer.birentech.com/framework: "${framework}"
    infer.birentech.com/config-file: "${CONFIG_FILE}"
    infer.birentech.com/server-script: "${INNER_SCRIPT}"
  labels:
    app: ${APP_LABEL}
    model: ${model_weights}
    framework: ${framework}
spec:
  # RuntimeClass 'biren'; placed by hami-scheduler (topology-aware multi-card).
  # Pod stays alive (sleep infinity); user enters via 'kubectl exec -it' and runs
  # the server run script written by k8s_apply.sh.
  runtimeClassName: biren
${_hami_sched_pod}
${_sched_pod}
  restartPolicy: Never
  containers:
  - name: ${SERVER_CONTAINER}
    image: ${CONTAINER_IMAGE}
    imagePullPolicy: IfNotPresent
    # No 'command' — preserves ENTRYPOINT (biren_entrypoint.sh) for LD_LIBRARY_PATH setup.
${ARGS_POD}
    env:
${ENV_POD}
    resources:
      requests:
${GPU_RES_POD}
        cpu: "${OPT_CPU}"
        memory: "${mem_gi}Gi"
      limits:
${GPU_RES_POD}
        cpu: "${cpu_lim}"
        memory: "${mem_gi}Gi"
    securityContext:
      capabilities:
        add:
        - IPC_LOCK
${_pod_vol_mounts}
${_pod_volumes}
YAML

fi

_ok "YAML saved  : $OUT_YAML"
echo ""
echo "  Review the YAML, then apply with:"
echo "    bash ${SCRIPT_DIR}/k8s_apply.sh ${OUT_YAML}"
