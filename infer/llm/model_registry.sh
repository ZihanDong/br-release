#!/usr/bin/env bash
# model_registry.sh — Query and manage model weights defined in model_registry.conf
#
# ── Library usage (source this script) ──────────────────────────────────────
#   source ./model_registry.sh
#   parse_model <model_name>          # sets MODEL_PATH, DOWNLOAD_NAME, DIR_STATUS
#   echo "$MODEL_PATH $DOWNLOAD_NAME $DIR_STATUS"
#
# ── Subprocess usage (eval into calling script) ──────────────────────────────
#   eval "$(./model_registry.sh parse_model <model_name>)"
#   echo "$MODEL_PATH $DOWNLOAD_NAME $DIR_STATUS"
#
# ── Standalone usage ─────────────────────────────────────────────────────────
#   ./model_registry.sh <model>[,model,...] | all [--download mc|hf]
#
# DIR_STATUS values: ok (exists, non-empty) | empty (exists, empty) | missing

# ── Config path (relative to this script) ────────────────────────────────────
_REG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REG_CONF="${_REG_SCRIPT_DIR}/model_registry.conf"

# ── ANSI color helpers ────────────────────────────────────────────────────────
_C_RED='\033[0;31m'; _C_GRN='\033[0;32m'; _C_YLW='\033[0;33m'
_C_BLD='\033[1m';    _C_RST='\033[0m'

_reg_info() { printf "${_C_BLD}[INFO]${_C_RST}  %s\n"           "$*"; }
_reg_warn() { printf "${_C_YLW}[WARN]${_C_RST}  %s\n"           "$*"; }
_reg_ok()   { printf "${_C_GRN}[OK]${_C_RST}    %s\n"           "$*"; }
_reg_err()  { printf "${_C_RED}[ERROR]${_C_RST} %s\n" "$*" >&2; }

# ── Internal parsing helpers ──────────────────────────────────────────────────

_reg_check_conf() {
    if [[ ! -f "$_REG_CONF" ]]; then
        _reg_err "Registry config not found: $_REG_CONF"
        return 1
    fi
}

# Read ROOT_PATH from the [DEFAULT] section
_reg_root_path() {
    awk -F= '
        /^\[DEFAULT\]/                       { in_def=1; next }
        in_def && /^\[/ && !/^\[DEFAULT\]/  { in_def=0; next }
        in_def && /^ROOT_PATH=/             { print $2; exit }
    ' "$_REG_CONF"
}

# Read a single field from a named model section
_reg_field() {
    local model="$1" field="$2"
    awk -v sec="[$model]" -v f="$field" '
        $0 == sec       { in_sec=1; next }
        in_sec && /^\[/ { exit }
        in_sec          { if ($0 ~ "^" f "=") { sub("^" f "=", ""); print; exit } }
    ' "$_REG_CONF"
}

# List all model names (excludes [DEFAULT])
_reg_list_models() {
    awk '/^\[/ && !/^\[DEFAULT\]/ { gsub(/[\[\]]/, ""); print }' "$_REG_CONF"
}

# Substitute ${ROOT_PATH} in a raw path string; no-op if absent
_reg_resolve_path() {
    local raw="$1" root="$2"
    printf '%s' "${raw/\$\{ROOT_PATH\}/$root}"
}

# Returns: ok | empty | missing
_reg_dir_status() {
    local path="$1"
    [[ -z "$path" ]]   && { echo "missing"; return; }
    [[ ! -d "$path" ]] && { echo "missing"; return; }
    [[ -z "$(ls -A "$path" 2>/dev/null)" ]] && { echo "empty"; return; }
    echo "ok"
}

# ── Public library function ───────────────────────────────────────────────────
# parse_model <model_name>
#
# When sourced:     sets MODEL_PATH, DOWNLOAD_NAME, DIR_STATUS in caller scope
# When subprocess:  prints eval-able key=value lines on stdout
# Returns 0 on success, 1 on error (model not found / config missing)
parse_model() {
    local _pm_model="$1"
    _reg_check_conf || return 1

    if [[ -z "$_pm_model" ]]; then
        _reg_err "parse_model: model name required"
        return 1
    fi

    if ! grep -q "^\[$_pm_model\]$" "$_REG_CONF"; then
        _reg_err "parse_model: model '$_pm_model' not found in $_REG_CONF"
        return 1
    fi

    local _pm_root _pm_raw _pm_dl _pm_path _pm_status
    _pm_root=$(_reg_root_path)
    _pm_raw=$(_reg_field  "$_pm_model" "local_path")
    _pm_dl=$(_reg_field   "$_pm_model" "download_name")
    _pm_path=$(_reg_resolve_path "$_pm_raw" "$_pm_root")
    _pm_status=$(_reg_dir_status "$_pm_path")

    if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
        # Sourced mode: set variables directly in caller's scope
        MODEL_PATH="$_pm_path"
        DOWNLOAD_NAME="$_pm_dl"
        DIR_STATUS="$_pm_status"
    else
        # Subprocess mode: print eval-able output
        printf 'MODEL_PATH=%q\n'    "$_pm_path"
        printf 'DOWNLOAD_NAME=%q\n' "$_pm_dl"
        printf 'DIR_STATUS=%q\n'    "$_pm_status"
    fi
}

# ── Guard: stop here when sourced ────────────────────────────────────────────
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

# ─────────────────────────────────────────────────────────────────────────────
# Standalone mode below — only executed when the script is run directly
# ─────────────────────────────────────────────────────────────────────────────

_sep() { printf '%0.s-' {1..62}; echo; }

_do_download() {
    local dl_name="$1" path="$2" mode="$3"
    mkdir -p "$path" 2>/dev/null || true
    case "$mode" in
        mc)
            if ! command -v modelscope &>/dev/null; then
                _reg_err "modelscope not installed — run: pip install modelscope"
                return 1
            fi
            _reg_info "Downloading via ModelScope: $dl_name → $path"
            modelscope download --model "$dl_name" --local_dir "$path"
            ;;
        hf)
            if ! command -v huggingface-cli &>/dev/null; then
                _reg_err "huggingface-cli not installed — run: pip install huggingface_hub"
                return 1
            fi
            _reg_info "Downloading via HuggingFace: $dl_name → $path"
            huggingface-cli download "$dl_name" --local-dir "$path"
            ;;
        *)
            _reg_err "Unknown download mode '$mode' — use 'mc' (ModelScope) or 'hf' (HuggingFace)"
            return 1
            ;;
    esac
}

_process_model() {
    local model="$1" download_mode="$2"

    _sep
    printf "${_C_BLD}Model: %s${_C_RST}\n" "$model"

    if ! grep -q "^\[$model\]$" "$_REG_CONF"; then
        _reg_err "Model '$model' not found in registry — skipping."
        return 0
    fi

    local root raw_path dl_name path status
    root=$(_reg_root_path)
    raw_path=$(_reg_field "$model" "local_path")
    dl_name=$(_reg_field  "$model" "download_name")
    path=$(_reg_resolve_path "$raw_path" "$root")
    status=$(_reg_dir_status "$path")

    printf "  %-16s %s\n" "Path:"          "$path"
    printf "  %-16s %s\n" "Download name:" "$dl_name"
    printf "  %-16s %s\n" "Status:"        "$status"

    case "$status" in
        ok)
            local file_count
            file_count=$(find "$path" -maxdepth 1 -mindepth 1 | wc -l)
            _reg_ok "$file_count item(s) found under $path"
            echo "  Files:"
            ls "$path" | sed 's/^/    /'
            if [[ -n "$download_mode" ]]; then
                _reg_info "Weights already present — skipping download."
            fi
            ;;
        empty|missing)
            _reg_warn "No weights available (${status})."
            echo "  To download, run one of:"
            printf "    [ModelScope]  modelscope download --model %s --local_dir %s\n" \
                "$dl_name" "$path"
            printf "    [HuggingFace] huggingface-cli download %s --local-dir %s\n" \
                "$dl_name" "$path"
            if [[ -n "$download_mode" ]]; then
                _do_download "$dl_name" "$path" "$download_mode" || true
            fi
            ;;
    esac
}

_usage() {
    cat <<EOF
Usage:
  $(basename "$0") <model>[,model,...] | all [--download mc|hf]
  $(basename "$0") parse_model <model_name>

Arguments:
  <model>          Comma-separated model name(s) from model_registry.conf
  all              Process every model defined in the registry
  --download mc    Auto-download missing/empty weights via ModelScope
  --download hf    Auto-download missing/empty weights via HuggingFace
  parse_model      Subprocess mode: print eval-able MODEL_PATH/DOWNLOAD_NAME/DIR_STATUS

Available models:
$(awk '/^\[/ && !/^\[DEFAULT\]/ { gsub(/[\[\]]/, ""); printf "  %s\n", $0 }' "$_REG_CONF" 2>/dev/null || echo "  (config not found)")
EOF
}

main() {
    # Sub-mode: subprocess eval bridge
    if [[ "${1:-}" == "parse_model" ]]; then
        parse_model "${2:-}"
        exit $?
    fi

    # Parse flags
    local download_mode="" model_arg=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --download)
                if [[ -z "${2:-}" ]]; then
                    _reg_err "--download requires an argument: mc or hf"
                    exit 1
                fi
                download_mode="$2"
                shift 2
                ;;
            -h|--help)
                _usage; exit 0
                ;;
            -*)
                _reg_err "Unknown option: $1"
                _usage; exit 1
                ;;
            *)
                if [[ -n "$model_arg" ]]; then
                    _reg_err "Unexpected argument: $1"
                    _usage; exit 1
                fi
                model_arg="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$model_arg" ]]; then
        _reg_err "No model specified."
        _usage; exit 1
    fi

    _reg_check_conf || exit 1

    # Build the model list
    local -a models=()
    if [[ "$model_arg" == "all" ]]; then
        while IFS= read -r m; do
            models+=("$m")
        done < <(_reg_list_models)
    else
        IFS=',' read -ra models <<< "$model_arg"
    fi

    if [[ ${#models[@]} -eq 0 ]]; then
        _reg_warn "No models found in registry."
        exit 0
    fi

    for model in "${models[@]}"; do
        model="${model//[[:space:]]/}"   # strip any surrounding whitespace
        [[ -z "$model" ]] && continue
        _process_model "$model" "$download_mode"
    done
    _sep
}

main "$@"
