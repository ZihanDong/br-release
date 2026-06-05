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
elif [[ "${launch_mode}" == "video_gen" ]]; then
    _info "Model key   : $model_weights  |  port=$port  |  gpus=$tensor_parallel_size  usp=$ulysses_degree ring=$ring_degree cfg=$enable_cfg_parallel  [video_gen]"
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

# ── Build the launch (env + pre-steps + command) from the shared launch library ─
# sglang_launch.sh is the SINGLE source of truth for the launch_mode branching
# (standard LLM / multimodal_gen image / video_gen). run_docker.sh sources the same
# library and bakes the identical launch into its run script, so Docker and k8s
# (this script is the k8s INNER_SCRIPT) start servers identically.
# shellcheck source=./sglang_launch.sh
source "${SCRIPT_DIR}/sglang_launch.sh"
sglang_build_launch

# Export mode-specific BirenTech env (+ conf extra_env), then run pre-launch steps
# (mkdir outputs / source base env / ensure deps), if any.
for _kv in "${LAUNCH_ENV[@]}"; do export "$_kv"; done
[[ -n "$LAUNCH_PRE" ]] && eval "$LAUNCH_PRE"

# ── Launch ─────────────────────────────────────────────────────────────────────
_ok "Launching   : ${LAUNCH_CMD[*]}"
echo ""

exec "${LAUNCH_CMD[@]}"
