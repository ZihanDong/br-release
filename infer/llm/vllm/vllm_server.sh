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
_REGISTRY_SH="${SCRIPT_DIR}/../model_registry.sh"

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

# ── Defaults (optional params only) ───────────────────────────────────────────
# Required params have NO defaults and MUST be set in the config file:
#   model_weights, port, tensor_parallel_size, pipeline_parallel_size,
#   max_model_len, max_num_seqs
served_model_name=""
task=""
dtype="auto"
gpu_memory_utilization=0.8
enable_chunked_prefill=false
enforce_eager=false
distributed_executor_backend=""
compilation_config=""
extra_env=""
extra_vllm_args=""

# shellcheck source=/dev/null
source "$CONFIG_FILE"

_missing=()
[[ -z "${model_weights:-}" ]]         && _missing+=(model_weights)
[[ -z "${port:-}" ]]                   && _missing+=(port)
[[ -z "${tensor_parallel_size:-}" ]]   && _missing+=(tensor_parallel_size)
[[ -z "${pipeline_parallel_size:-}" ]] && _missing+=(pipeline_parallel_size)
[[ -z "${max_model_len:-}" ]]          && _missing+=(max_model_len)
[[ -z "${max_num_seqs:-}" ]]           && _missing+=(max_num_seqs)
[[ ${#_missing[@]} -gt 0 ]] && {
    _err "Required params not set in $(basename "$CONFIG_FILE"): ${_missing[*]}"; exit 1; }

_info "Config      : $(basename "$CONFIG_FILE")"
_info "Model key   : $model_weights  |  port=$port  |  tp=$tensor_parallel_size  pp=$pipeline_parallel_size"

# ── Registry lookup (via model_registry.sh) ───────────────────────────────────
[[ ! -f "$_REGISTRY_SH" ]] && { _err "model_registry.sh not found: $_REGISTRY_SH"; exit 1; }
# shellcheck source=../model_registry.sh
source "$_REGISTRY_SH"
parse_model "$model_weights" || exit 1
MODEL_LOCAL_PATH="$MODEL_PATH"

_info "Registry    : path=$MODEL_LOCAL_PATH  download=$DOWNLOAD_NAME  status=$DIR_STATUS"

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
# Task selection: vLLM >= 0.10 replaced `--task` with `--runner {generate,pooling}`
# (+ `--convert`); `--task` is rejected on vLLM 0.16. Detect the installed vLLM and
# map the config's `task` accordingly so the same conf works on old and new images.
if [[ -n "$task" ]]; then
    _vllm_new=$(python3 -c "import vllm
from packaging.version import parse
print('1' if parse(vllm.__version__) >= parse('0.10.0') else '0')" 2>/dev/null || echo "")
    if [[ "$_vllm_new" == "1" ]]; then
        case "$task" in
            generate)                                  vllm_args+=(--runner generate) ;;
            embed|embedding|classify|score|reward|pooling) vllm_args+=(--runner pooling) ;;
            *) _warn "unrecognized task='${task}' for vLLM>=0.10; defaulting to --runner pooling"; vllm_args+=(--runner pooling) ;;
        esac
        _info "Task        : ${task} -> --runner $([[ "$task" == generate ]] && echo generate || echo pooling) (vLLM $(python3 -c 'import vllm;print(vllm.__version__)' 2>/dev/null))"
    else
        vllm_args+=(--task "${task}")   # older vLLM still accepts --task
    fi
fi
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
