#!/usr/bin/env bash
# Runs INSIDE the BirenTech container to launch an SGLang OpenAI-compatible server.
#
# The image ENTRYPOINT (biren_entrypoint.sh) must have already run to set
# LD_LIBRARY_PATH for the BirenTech SDK before this script is called.
#
# Usage:
#   bash sglang_server.sh <config_ref>
#
# config_ref is resolved by utils/parse_config.sh and may be:
#   - a bare model name:  qwen3-vl-32b   (-> configs/sglang_qwen3-vl-32b.conf)
#   - a prefixed name:    sglang_qwen3-vl-32b
#   - a path under configs/ or an absolute path
# The config's framework= field must be 'sglang'.

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
    echo "Available SGLang configs:"
    for f in "${LLM_DIR}/configs/"sglang_*.conf; do
        [[ -f "$f" ]] && echo "  $(basename "$f" .conf)"
    done
    echo ""
    exit 1
}

[[ $# -lt 1 ]] && { _err "A config file is required."; usage; }

# ── Parse + validate config (framework must be sglang; defaults filled) ───────
# multimodal_gen mode relaxes pipeline_parallel_size/max_model_len/max_running_requests.
# shellcheck source=../utils/parse_config.sh
source "${LLM_DIR}/utils/parse_config.sh"
parse_config "$1" sglang || usage

_info "Config      : $(basename "$CONFIG_FILE")"
if [[ "${launch_mode}" == "multimodal_gen" ]]; then
    _info "Model key   : $model_weights  |  port=$port  |  tp=$tensor_parallel_size  [multimodal_gen]"
else
    _info "Model key   : $model_weights  |  port=$port  |  tp=$tensor_parallel_size  pp=$pipeline_parallel_size"
fi

# ── Registry lookup (via model_registry.sh) ───────────────────────────────────
# shellcheck source=../model_registry.sh
source "${LLM_DIR}/model_registry.sh"
parse_model "$model_weights" || exit 1
MODEL_LOCAL_PATH="$MODEL_PATH"

_info "Registry    : path=$MODEL_LOCAL_PATH  download=$DOWNLOAD_NAME  status=$DIR_STATUS"

[[ ! -d "${MODEL_LOCAL_PATH}" ]] && {
    _err "Model weights not found: ${MODEL_LOCAL_PATH}"
    _err "Download weights to the host before launching the container."; exit 1; }
_ok "Weights     : ${MODEL_LOCAL_PATH}"

# ── BirenTech env vars ─────────────────────────────────────────────────────────
if [[ "${launch_mode}" == "multimodal_gen" ]]; then
    # Image generation backend requires different BRTB flags (set inside run_qwen-image.sh)
    export BRTB_ENABLE_SUPA_FALLBACK=1
    export BRTB_ENABLE_NCDHW=1
    export BRTB_ENABLE_FORCE_EAGER_CONV2D=1
    export SUDNN_EAGER_ENABLE_ALPHA_BETA=false
else
    export BRTB_PLAN_ID_RENEW=1
    export BRTB_DISABLE_ZERO_REORDER=1
    export BRTB_DISABLE_ZERO_OUTPUT_NUMA=1
    export BRTB_DISABLE_ZERO_OUTPUT_UMA=1
    export BRTB_DISABLE_ZERO_WS=1
    export BRTB_DISABLE_L2_FLUSH=1
    export BRTB_ENABLE_SUPA_FILL=1
fi

# Extra model-specific env vars (space-separated KEY=VALUE pairs from conf)
if [[ -n "${extra_env:-}" ]]; then
    for _kv in ${extra_env}; do
        export "$_kv"
    done
fi

# ── Build launch args array ────────────────────────────────────────────────────
if [[ "${launch_mode}" == "multimodal_gen" ]]; then
    mkdir -p "${output_path}"
    sglang_args=(
        python3 "${SCRIPT_DIR}/run_qwen-image.sh"
        --model-path "${MODEL_LOCAL_PATH}"
        --num-gpus "${tensor_parallel_size}"
        --tp-size "${tensor_parallel_size}"
        --host 0.0.0.0
        --port "${port}"
        --output-path "${output_path}"
        --dit-cpu-offload "${dit_cpu_offload}"
        --dit-layerwise-offload "${dit_layerwise_offload}"
        --image-encoder-cpu-offload "${image_encoder_cpu_offload}"
        --text-encoder-cpu-offload "${text_encoder_cpu_offload}"
        --vae-cpu-offload "${vae_cpu_offload}"
    )
    [[ -n "$served_model_name" ]] && sglang_args+=(--served-model-name "${served_model_name}")
else
    sglang_args=(
        python3 -m sglang.launch_server
        --host 0.0.0.0
        --port "${port}"
        --model-path "${MODEL_LOCAL_PATH}"
        --tp-size "${tensor_parallel_size}"
        --pp-size "${pipeline_parallel_size}"
        --mem-fraction-static "${mem_fraction_static}"
        --max-model-len "${max_model_len}"
        --max-running-requests "${max_running_requests}"
        --page-size "${page_size}"
    )
    [[ "$trust_remote_code" == "true" ]] && sglang_args+=(--trust-remote-code)
    [[ "$disable_radix_cache" == "true" ]] && sglang_args+=(--disable-radix-cache)
    [[ -n "$served_model_name" ]]          && sglang_args+=(--served-model-name "${served_model_name}")
fi

# Extra model-specific sglang flags (e.g. --enable-mixed-chunk)
if [[ -n "${extra_sglang_args:-}" ]]; then
    read -ra _extra_arr <<< "${extra_sglang_args}"
    sglang_args+=("${_extra_arr[@]}")
fi

# ── Launch ─────────────────────────────────────────────────────────────────────
_ok "Launching   : ${sglang_args[*]}"
echo ""

exec "${sglang_args[@]}"
