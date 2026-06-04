#!/usr/bin/env bash
# parse_config.sh — unified model-config parser/validator for infer/llm.
#
# All model serving configs live in infer/llm/configs/ as
# <framework>_<model>.conf, where the first meaningful line is `framework=`.
# This script is the single place that resolves a config reference, fills in
# default values for optional params, and validates that all required params
# are present for the declared framework. Once parse_config succeeds, every
# parameter is guaranteed to have a value, so callers can use them directly
# (they still own runtime checks: port availability, weight paths, log dirs).
#
# ── Library usage (source this script) ───────────────────────────────────────
#   source utils/parse_config.sh
#   parse_config <config_ref> [expected_framework]   # sets vars in caller scope
#   # -> framework, model_weights, port, ... all set & validated; CONFIG_FILE set.
#
#   parse_config exits non-zero (returns 1) on: config not found, missing/unknown
#   framework, framework mismatch, or missing required params. Callers typically:
#       parse_config "$1" vllm || exit 1
#
# Helper functions (also exported for callers):
#   port_in_use <port>     # returns 0 if a local TCP port is already listening
#   ensure_dir  <dir>      # mkdir -p
#
# ── Standalone usage (validate configs) ──────────────────────────────────────
#   parse_config.sh --list                 # list configs + framework
#   parse_config.sh --check <ref>          # validate one config
#   parse_config.sh --check-all            # validate every configs/*.conf
#   parse_config.sh --show  <ref>          # print resolved (defaults-filled) values

# ── Locations (relative to this script) ──────────────────────────────────────
_PC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_DIR="$(cd "${_PC_DIR}/.." && pwd)"
CONFIGS_DIR="${LLM_DIR}/configs"

RECOGNIZED_FRAMEWORKS="vllm sglang suinferllm"

# ── Helpers ───────────────────────────────────────────────────────────────────
_pc_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }
_pc_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*" >&2; }

# ══════════════════════════════════════════════════════════════════════════════
# DEFAULTS — optional params only. Required params have NO default and MUST be
# set in the config file (validated below). Edit defaults here, in one place.
# ══════════════════════════════════════════════════════════════════════════════
_apply_defaults_common() {
    served_model_name=""
    extra_env=""
    docker_image=""        # per-config Docker image override (run_docker.sh)
    k8s_image=""           # per-config K8s image override (k8s_yaml_gen.sh)
    k8s_nodeport=""        # required only for k8s deploy (checked by k8s_yaml_gen)
}

# vLLM standard server.
#   Required: model_weights, port, tensor_parallel_size, max_model_len, max_num_seqs
_apply_defaults_vllm() {
    task=""
    dtype="auto"
    pipeline_parallel_size=1
    gpu_memory_utilization=0.8
    enable_chunked_prefill=false
    enforce_eager=false
    distributed_executor_backend=""
    compilation_config=""
    extra_vllm_args=""
}

# SGLang server.
#   standard mode    required: model_weights, port, tensor_parallel_size,
#                              max_model_len, max_running_requests
#   multimodal_gen   required: model_weights, port, tensor_parallel_size
_apply_defaults_sglang() {
    launch_mode=standard
    pipeline_parallel_size=1
    mem_fraction_static=0.85
    page_size=128
    disable_radix_cache=false
    trust_remote_code=false
    max_model_len=""
    max_running_requests=""
    extra_sglang_args=""
    # multimodal_gen-specific
    output_path=./outputs/
    dit_cpu_offload=False
    dit_layerwise_offload=False
    image_encoder_cpu_offload=False
    text_encoder_cpu_offload=False
    vae_cpu_offload=False
}

# ── Path resolution ─────────────────────────────────────────────────────────
# Accepts: absolute path | configs/<arg>.conf | configs/<arg> |
#          (when a framework is known) configs/<framework>_<arg>.conf | cwd-relative.
# The framework-prefixed fallback lets `vllm_server.sh qwen3-vl-32b` find
# configs/vllm_qwen3-vl-32b.conf without the caller typing the prefix.
_pc_resolve() {
    local arg="$1" fw="${2:-}" f=""
    if [[ "$arg" == /* ]]; then
        f="$arg"
    elif [[ -f "${CONFIGS_DIR}/${arg}.conf" ]]; then
        f="${CONFIGS_DIR}/${arg}.conf"
    elif [[ -f "${CONFIGS_DIR}/${arg}" ]]; then
        f="${CONFIGS_DIR}/${arg}"
    elif [[ -n "$fw" && -f "${CONFIGS_DIR}/${fw}_${arg}.conf" ]]; then
        f="${CONFIGS_DIR}/${fw}_${arg}.conf"
    elif [[ -n "$fw" && -f "${CONFIGS_DIR}/${fw}_${arg}" ]]; then
        f="${CONFIGS_DIR}/${fw}_${arg}"
    elif [[ -f "$arg" ]]; then
        f="$arg"
    fi
    [[ -n "$f" && -f "$f" ]] || return 1
    printf '%s' "$f"
}

# Read the framework value from a config without sourcing it.
# Strips inline comments, whitespace, and surrounding quotes.
_pc_peek_framework() {
    awk -F= '
        /^[[:space:]]*framework[[:space:]]*=/ {
            v=$2; sub(/#.*/, "", v); gsub(/[[:space:]"'\'']/, "", v); print v; exit
        }' "$1"
}

# ── Required-param validation (per framework / mode) ─────────────────────────
_pc_validate() {
    local fw="$1" missing=() v
    local -a req=(model_weights port tensor_parallel_size)
    case "$fw" in
        vllm)
            req+=(max_model_len max_num_seqs) ;;
        sglang)
            if [[ "${launch_mode:-standard}" != "multimodal_gen" ]]; then
                req+=(max_model_len max_running_requests)
            fi ;;
    esac
    for v in "${req[@]}"; do
        [[ -z "${!v:-}" ]] && missing+=("$v")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        _pc_err "Required params not set in $(basename "$CONFIG_FILE"): ${missing[*]}"
        return 1
    fi
    return 0
}

# ══════════════════════════════════════════════════════════════════════════════
# parse_config <config_ref> [expected_framework]
#   On success (return 0): CONFIG_FILE + framework + all params set in caller scope.
#   On failure (return 1): prints an error to stderr.
# ══════════════════════════════════════════════════════════════════════════════
parse_config() {
    local _ref="$1" _expect="${2:-}" _file _fw

    _file="$(_pc_resolve "$_ref" "$_expect")" || {
        _pc_err "Config not found: ${_ref}  (looked under ${CONFIGS_DIR}/)"; return 1; }

    _fw="$(_pc_peek_framework "$_file")"
    if [[ -z "$_fw" ]]; then
        _pc_err "$(basename "$_file"): missing required 'framework=' field"; return 1
    fi
    if [[ " $RECOGNIZED_FRAMEWORKS " != *" $_fw "* ]]; then
        _pc_err "$(basename "$_file"): unknown framework '${_fw}' (expected: ${RECOGNIZED_FRAMEWORKS// /|})"; return 1
    fi
    if [[ -n "$_expect" && "$_fw" != "$_expect" ]]; then
        _pc_err "Framework mismatch in $(basename "$_file"): config declares '${_fw}', but '${_expect}' was requested."; return 1
    fi

    # Defaults first, then the config overrides them.
    _apply_defaults_common
    case "$_fw" in
        vllm)       _apply_defaults_vllm ;;
        sglang)     _apply_defaults_sglang ;;
        suinferllm) _pc_err "framework 'suinferllm' is reserved but not yet implemented."; return 1 ;;
    esac

    CONFIG_FILE="$_file"
    # shellcheck disable=SC1090
    source "$_file"
    framework="$_fw"   # canonical (comment/quote-stripped) value

    _pc_validate "$_fw" || return 1
    return 0
}

# ── Runtime helpers for callers ──────────────────────────────────────────────
# Returns 0 if a local TCP port already has a listener (i.e. NOT free).
port_in_use() {
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
    elif command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1
    else
        # /dev/tcp probe: connect success => something is listening
        (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null && { exec 3>&- 3<&-; return 0; }
        return 1
    fi
}

ensure_dir() { mkdir -p "$1"; }

# ── Guard: stop here when sourced ────────────────────────────────────────────
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

# ══════════════════════════════════════════════════════════════════════════════
# Standalone CLI — validate / list / show configs
# ══════════════════════════════════════════════════════════════════════════════
set -uo pipefail

_pc_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_pc_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }

_cli_list() {
    _pc_info "Configs under ${CONFIGS_DIR}/"
    local f fw
    shopt -s nullglob
    for f in "${CONFIGS_DIR}"/*.conf; do
        fw="$(_pc_peek_framework "$f")"
        printf "  %-34s framework=%s\n" "$(basename "$f")" "${fw:-<missing>}"
    done
    shopt -u nullglob
}

# Validate one config in a subshell so its sourced vars never leak between checks.
_cli_check_one() {
    local ref="$1"
    ( parse_config "$ref" >/dev/null ) && return 0 || return 1
}

_cli_check() {
    local ref="$1"
    if _cli_check_one "$ref"; then
        _pc_ok "valid: ${ref}"
    else
        return 1
    fi
}

_cli_check_all() {
    local f pass=0 fail=0
    shopt -s nullglob
    local files=("${CONFIGS_DIR}"/*.conf)
    shopt -u nullglob
    if [[ ${#files[@]} -eq 0 ]]; then
        _pc_warn "No configs found under ${CONFIGS_DIR}/"; return 1
    fi
    for f in "${files[@]}"; do
        if _cli_check_one "$f"; then
            _pc_ok "valid:   $(basename "$f")"
            pass=$((pass+1))
        else
            _pc_err "INVALID: $(basename "$f")"
            fail=$((fail+1))
        fi
    done
    echo ""
    _pc_info "Results: ${pass} valid / ${fail} invalid / $(( pass + fail )) total"
    [[ $fail -eq 0 ]]
}

_cli_show() {
    local ref="$1"
    parse_config "$ref" || return 1
    _pc_ok "Resolved: ${CONFIG_FILE}"
    echo "  framework               = ${framework}"
    echo "  model_weights           = ${model_weights}"
    echo "  port                    = ${port}"
    echo "  served_model_name       = ${served_model_name}"
    echo "  tensor_parallel_size    = ${tensor_parallel_size}"
    echo "  pipeline_parallel_size  = ${pipeline_parallel_size:-}"
    echo "  k8s_nodeport            = ${k8s_nodeport}"
    echo "  k8s_image               = ${k8s_image:-<framework default>}"
    case "$framework" in
        vllm)
            echo "  max_model_len           = ${max_model_len}"
            echo "  max_num_seqs            = ${max_num_seqs}"
            echo "  gpu_memory_utilization  = ${gpu_memory_utilization}"
            echo "  task                    = ${task:-<chat>}" ;;
        sglang)
            echo "  launch_mode             = ${launch_mode}"
            echo "  max_model_len           = ${max_model_len:-<n/a>}"
            echo "  max_running_requests    = ${max_running_requests:-<n/a>}"
            echo "  mem_fraction_static     = ${mem_fraction_static}" ;;
    esac
}

_cli_usage() {
    cat <<EOF
Usage:
  $(basename "$0") --list
  $(basename "$0") --check <config_ref>
  $(basename "$0") --check-all
  $(basename "$0") --show  <config_ref>

<config_ref> may be a bare name (qwen3-vl-32b or vllm_qwen3-vl-32b),
a path under configs/, or an absolute path.
EOF
}

case "${1:-}" in
    --list)      _cli_list ;;
    --check)     [[ $# -lt 2 ]] && { _pc_err "--check needs a config_ref"; exit 1; }; _cli_check "$2" ;;
    --check-all) _cli_check_all ;;
    --show)      [[ $# -lt 2 ]] && { _pc_err "--show needs a config_ref"; exit 1; }; _cli_show "$2" ;;
    -h|--help|"") _cli_usage ;;
    *)           _pc_err "Unknown option: $1"; _cli_usage; exit 1 ;;
esac
