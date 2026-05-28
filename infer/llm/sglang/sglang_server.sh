#!/usr/bin/env bash
# Runs INSIDE the BirenTech container to launch an SGLang OpenAI-compatible server.
#
# The image ENTRYPOINT (biren_entrypoint.sh) must have already run to set
# LD_LIBRARY_PATH for the BirenTech SDK before this script is called.
#
# Usage:
#   bash sglang_server.sh <config_file>
#
# config_file may be:
#   - a bare model name: qwen3-vl-32b  (resolved to configs/qwen3-vl-32b.conf)
#   - a relative path:   configs/qwen3-vl-32b.conf
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
#   max_model_len, max_running_requests
served_model_name=""
mem_fraction_static=0.85
page_size=128
disable_radix_cache=false
trust_remote_code=false
extra_env=""
extra_sglang_args=""

# shellcheck source=/dev/null
source "$CONFIG_FILE"

_missing=()
[[ -z "${model_weights:-}" ]]         && _missing+=(model_weights)
[[ -z "${port:-}" ]]                   && _missing+=(port)
[[ -z "${tensor_parallel_size:-}" ]]   && _missing+=(tensor_parallel_size)
[[ -z "${pipeline_parallel_size:-}" ]] && _missing+=(pipeline_parallel_size)
[[ -z "${max_model_len:-}" ]]          && _missing+=(max_model_len)
[[ -z "${max_running_requests:-}" ]]   && _missing+=(max_running_requests)
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

[[ ! -d "${MODEL_LOCAL_PATH}" ]] && {
    _err "Model weights not found: ${MODEL_LOCAL_PATH}"
    _err "Download weights to the host before launching the container."; exit 1; }
_ok "Weights     : ${MODEL_LOCAL_PATH}"

# ── BirenTech SGLang env vars ──────────────────────────────────────────────────
export BRTB_PLAN_ID_RENEW=1
export BRTB_DISABLE_ZERO_REORDER=1
export BRTB_DISABLE_ZERO_OUTPUT_NUMA=1
export BRTB_DISABLE_ZERO_OUTPUT_UMA=1
export BRTB_DISABLE_ZERO_WS=1
export BRTB_DISABLE_L2_FLUSH=1
export BRTB_ENABLE_SUPA_FILL=1

# Extra model-specific env vars (space-separated KEY=VALUE pairs from conf)
if [[ -n "${extra_env:-}" ]]; then
    for _kv in ${extra_env}; do
        export "$_kv"
    done
fi

# ── Build sglang args array ────────────────────────────────────────────────────
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

# Extra model-specific sglang flags (e.g. --enable-mixed-chunk)
if [[ -n "${extra_sglang_args:-}" ]]; then
    read -ra _extra_arr <<< "${extra_sglang_args}"
    sglang_args+=("${_extra_arr[@]}")
fi

# ── Launch ─────────────────────────────────────────────────────────────────────
_ok "Launching   : ${sglang_args[*]}"
echo ""

exec "${sglang_args[@]}"
