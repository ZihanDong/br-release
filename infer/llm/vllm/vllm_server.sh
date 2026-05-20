#!/usr/bin/env bash
# Runs INSIDE the BirenTech container to launch a vLLM OpenAI-compatible server.
#
# The image ENTRYPOINT (biren_entrypoint.sh) must have already run to set
# LD_LIBRARY_PATH for the BirenTech SDK before this script is called.
#
# Usage:
#   bash vllm_server.sh <config_file>
#
# config_file may be:
#   - a bare model name: bge-m3  (resolved to configs/bge-m3.conf)
#   - a relative path:   configs/bge-m3.conf
#   - an absolute path:  /path/to/any.conf

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_REGISTRY="${SCRIPT_DIR}/model_registry.conf"

_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

usage() {
    echo ""
    echo "Usage: $0 <config_file>"
    echo ""
    echo "Available configs:"
    for f in "${SCRIPT_DIR}/configs/"*.conf; do
        [[ -f "$f" ]] && echo "  $(basename "$f" .conf)"
    done
    echo ""
    exit 1
}

[[ $# -lt 1 ]] && { _err "A config file is required."; usage; }

CONFIG_ARG="$1"
CONFIG_FILE=""

if [[ "$CONFIG_ARG" == /* ]]; then
    CONFIG_FILE="$CONFIG_ARG"
elif [[ -f "${SCRIPT_DIR}/configs/${CONFIG_ARG}.conf" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/configs/${CONFIG_ARG}.conf"
elif [[ -f "${SCRIPT_DIR}/${CONFIG_ARG}" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_ARG}"
elif [[ -f "${CONFIG_ARG}" ]]; then
    CONFIG_FILE="${CONFIG_ARG}"
fi

[[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]] && {
    _err "Config not found: $CONFIG_ARG"; usage; }

# ── Defaults ───────────────────────────────────────────────────────────────────
port=8000
served_model_name=""
task=""
dtype="auto"
max_model_len=8192
max_num_seqs=64
pipeline_parallel_size=1
tensor_parallel_size=1
gpu_memory_utilization=0.8
enable_chunked_prefill=false
enforce_eager=false
distributed_executor_backend=""
compilation_config=""
model_weights=""
extra_env=""
extra_vllm_args=""

# shellcheck source=/dev/null
source "$CONFIG_FILE"

[[ -z "$model_weights" ]] && { _err "model_weights not set in $(basename "$CONFIG_FILE")"; exit 1; }

_info "Config      : $(basename "$CONFIG_FILE")"
_info "Model key   : $model_weights  |  port=$port  |  tp=$tensor_parallel_size  pp=$pipeline_parallel_size"

# ── Registry lookup ────────────────────────────────────────────────────────────
[[ ! -f "$MODEL_REGISTRY" ]] && { _err "Registry not found: $MODEL_REGISTRY"; exit 1; }

registry_get() {
    awk -v sec="[$1]" -v fld="$2" '
        /^\[/ { cur = $0 }
        cur == sec && match($0, "^" fld "=") { print substr($0, length(fld)+2); exit }
    ' "$MODEL_REGISTRY"
}

MODEL_LOCAL_PATH=$(registry_get "$model_weights" "local_path")
MODEL_HF_ID=$(registry_get "$model_weights" "huggingface_id")
MODEL_MS_ID=$(registry_get "$model_weights" "modelscope_id")

[[ -z "$MODEL_HF_ID$MODEL_MS_ID" ]] && {
    _err "Model '$model_weights' not found in $MODEL_REGISTRY"; exit 1; }

_info "Registry    : local=${MODEL_LOCAL_PATH:-(not set)}  hf=$MODEL_HF_ID  ms=$MODEL_MS_ID"

# Weights must already exist — download should happen on the host before container start
[[ ! -d "${MODEL_LOCAL_PATH}" ]] && {
    _err "Model weights not found: ${MODEL_LOCAL_PATH}"
    _err "Download weights to the host before launching the container."; exit 1; }
_ok "Weights     : ${MODEL_LOCAL_PATH}"

# ── Build vllm args array ──────────────────────────────────────────────────────
vllm_args=(
    python3 -m vllm.entrypoints.openai.api_server
    --host 0.0.0.0
    --port "${port}"
    --model "${MODEL_LOCAL_PATH}"
)
[[ -n "$served_model_name" ]] && vllm_args+=(--served_model_name "${served_model_name}")
[[ -n "$task" ]]              && vllm_args+=(--task "${task}")
vllm_args+=(
    --trust_remote_code
    --dtype "${dtype}"
    --kv_cache_dtype auto
    --max_model_len "${max_model_len}"
    --max_num_seqs "${max_num_seqs}"
    --tensor_parallel_size "${tensor_parallel_size}"
    --pipeline_parallel_size "${pipeline_parallel_size}"
    --data_parallel_size 1
    --gpu_memory_utilization "${gpu_memory_utilization}"
)
[[ "$enforce_eager" == "true" ]]          && vllm_args+=(--enforce_eager)
[[ "$enable_chunked_prefill" == "true" ]] && vllm_args+=(--enable_chunked_prefill)
[[ -n "$distributed_executor_backend" ]] && vllm_args+=(--distributed_executor_backend "${distributed_executor_backend}")
if [[ -n "$compilation_config" ]]; then
    # bash 'source' already strips the single-quotes used in .conf for safety
    vllm_args+=(--compilation_config "${compilation_config}")
fi
# Extra model-specific vLLM flags (e.g. --enable_expert_parallel)
if [[ -n "${extra_vllm_args:-}" ]]; then
    read -ra _extra_arr <<< "${extra_vllm_args}"
    vllm_args+=("${_extra_arr[@]}")
fi

# ── Launch ─────────────────────────────────────────────────────────────────────
export VLLM_USE_V1=1
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export VLLM_BR_WEIGHT_TYPE=NUMA
# Extra model-specific env vars (space-separated KEY=VALUE pairs from conf)
if [[ -n "${extra_env:-}" ]]; then
    for _kv in ${extra_env}; do
        export "$_kv"
    done
fi

_ok "Launching   : ${vllm_args[*]}"
echo ""

exec "${vllm_args[@]}"
