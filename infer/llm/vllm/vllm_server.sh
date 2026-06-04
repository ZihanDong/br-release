#!/usr/bin/env bash
# Runs INSIDE the BirenTech container to launch a vLLM OpenAI-compatible server.
#
# The image ENTRYPOINT (biren_entrypoint.sh) must have already run to set
# LD_LIBRARY_PATH for the BirenTech SDK before this script is called.
#
# Usage:
#   bash vllm_server.sh <config_ref>
#
# config_ref is resolved by utils/parse_config.sh and may be:
#   - a bare model name:  qwen3-vl-32b   (-> configs/vllm_qwen3-vl-32b.conf)
#   - a prefixed name:    vllm_qwen3-vl-32b
#   - a path under configs/ or an absolute path
# The config's framework= field must be 'vllm'.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

usage() {
    echo ""
    echo "Usage: $0 <config_ref>"
    echo ""
    echo "Available vLLM configs:"
    for f in "${LLM_DIR}/configs/"vllm_*.conf; do
        [[ -f "$f" ]] && echo "  $(basename "$f" .conf)"
    done
    echo ""
    exit 1
}

[[ $# -lt 1 ]] && { _err "A config file is required."; usage; }

# ── Parse + validate config (framework must be vllm; defaults filled) ─────────
# After this, every param has a value — no per-script defaults needed.
# shellcheck source=../utils/parse_config.sh
source "${LLM_DIR}/utils/parse_config.sh"
parse_config "$1" vllm || usage

_info "Config      : $(basename "$CONFIG_FILE")"
_info "Model key   : $model_weights  |  port=$port  |  tp=$tensor_parallel_size  pp=$pipeline_parallel_size"

# ── Registry lookup (via model_registry.sh) ───────────────────────────────────
# shellcheck source=../model_registry.sh
source "${LLM_DIR}/model_registry.sh"
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
