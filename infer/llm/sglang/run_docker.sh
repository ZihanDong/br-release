#!/usr/bin/env bash
# Launch a BirenTech Docker container for SGLang serving.
#
# Usage:
#   sudo bash run_docker.sh [--run] <config_file>
#
#   (default)  Start the container, write a server run script to the log
#              directory, then enter an interactive shell there.  The user
#              starts the server manually:  bash run_sglang_<model>_server.sh
#
#   --run      Write the run script, then exec the server directly (no
#              interactive shell).  Polls /health and prints test commands
#              once the server is ready.
#
# config_file may be:
#   - a bare model name: qwen3-vl-32b  (resolved to configs/qwen3-vl-32b.conf)
#   - a relative path:   configs/qwen3-vl-32b.conf
#   - an absolute path:  /path/to/any.conf
#
# /home and /data are bind-mounted so sglang_server.sh, model weights, and
# configs are accessible at the same paths inside the container.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Paths ──────────────────────────────────────────────────────────────────────
_REGISTRY_SH="${SCRIPT_DIR}/../model_registry.sh"
LOG_DIR="${SCRIPT_DIR}/logs"
CONTAINER_IMAGE='birensupa-smartinfer-sglang:26.04.rc2-py310-pt2.9.0-br1xx'

# ── Helpers ────────────────────────────────────────────────────────────────────
_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

DOCKER_CMD="docker"
if ! docker info &>/dev/null 2>&1; then
    if sudo -n docker info &>/dev/null 2>&1; then
        DOCKER_CMD="sudo docker"
    else
        _warn "Docker not accessible without password. Will use 'sudo docker' (may prompt)."
        DOCKER_CMD="sudo docker"
    fi
fi

usage() {
    echo ""
    echo "Usage: $0 [--run] <config_file>"
    echo ""
    echo "  (default)  Enter interactive shell; start server manually inside"
    echo "  --run      Write run script then exec server directly (no interactive shell)"
    echo ""
    echo "Available configs:"
    for f in "${SCRIPT_DIR}/configs/"*.conf; do
        [[ -f "$f" ]] && echo "  $(basename "$f" .conf)"
    done
    echo ""
    exit 1
}

# ── Parse arguments ────────────────────────────────────────────────────────────
RUN_MODE=false
CONFIG_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run) RUN_MODE=true; shift ;;
        -*)    _err "Unknown option: $1"; usage ;;
        *)     CONFIG_ARG="$1"; shift ;;
    esac
done

[[ -z "$CONFIG_ARG" ]] && { _err "A config file is required."; usage; }

# ── Resolve config ─────────────────────────────────────────────────────────────
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

# ── Load config ────────────────────────────────────────────────────────────────
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

_info "Config      : $(basename "$CONFIG_FILE")  [mode=$( $RUN_MODE && echo --run || echo interactive)]"
_info "Model key   : $model_weights  |  port=$port  |  tp=$tensor_parallel_size  pp=$pipeline_parallel_size"

# ── Registry lookup (via model_registry.sh) ───────────────────────────────────
[[ ! -f "$_REGISTRY_SH" ]] && { _err "model_registry.sh not found: $_REGISTRY_SH"; exit 1; }
# shellcheck source=../model_registry.sh
source "$_REGISTRY_SH"
parse_model "$model_weights" || exit 1

_info "Registry    : path=$MODEL_PATH  download=$DOWNLOAD_NAME  status=$DIR_STATUS"

# ── Weight check / download (on host, before starting container) ───────────────
WEIGHTS_PATH=""
if [[ "$DIR_STATUS" == "ok" ]]; then
    WEIGHTS_PATH="$MODEL_PATH"
    _ok "Weights     : $WEIGHTS_PATH"
else
    _warn "Local weights not found (${MODEL_PATH:-(path not configured)}, status: $DIR_STATUS)"
    read -rp "  Download now? [y/N]: " yn
    if [[ ! "$yn" =~ ^[Yy]$ ]]; then
        _err "Cannot start without model weights. Exiting."; exit 1
    fi
    echo "  Download source:"
    echo "    1) modelscope  —  modelscope download --model $DOWNLOAD_NAME --local_dir $MODEL_PATH"
    echo "    2) huggingface —  huggingface-cli download $DOWNLOAD_NAME --local-dir $MODEL_PATH"
    read -rp "  Choose [1/2]: " src
    mkdir -p "$MODEL_PATH"
    case "$src" in
        1) modelscope download --model "$DOWNLOAD_NAME" --local_dir "$MODEL_PATH" ;;
        2) huggingface-cli download "$DOWNLOAD_NAME" --local-dir "$MODEL_PATH" ;;
        *) _err "Invalid choice."; exit 1 ;;
    esac
    WEIGHTS_PATH="$MODEL_PATH"
    _ok "Downloaded  : $WEIGHTS_PATH"
fi

# ── GPU selection ──────────────────────────────────────────────────────────────
gpu_needed=$((tensor_parallel_size * pipeline_parallel_size))
_info "GPU needed  : tp=$tensor_parallel_size × pp=$pipeline_parallel_size = $gpu_needed"

mapfile -t free_gpus < <(
    brsmi gpu --query-gpu=index,memory.used --format=csv,noheader,nounits 2>/dev/null \
    | awk -F',' '{ gsub(/ /,"",$1); gsub(/ /,"",$2); if ($2+0 == 0) print $1 }' \
    | head -n "$gpu_needed"
)

if [[ ${#free_gpus[@]} -lt $gpu_needed ]]; then
    _err "Not enough free GPUs: need $gpu_needed, found ${#free_gpus[@]} with 0 MiB used."
    echo ""
    brsmi gpu --query-gpu=index,memory.used,memory.free --format=csv,noheader 2>/dev/null || true
    exit 1
fi

biren_visible=$(IFS=','; echo "${free_gpus[*]}")
card_list=$(for i in "${free_gpus[@]}"; do printf "card_%s " "$i"; done)
_ok "GPUs        : [${biren_visible}]  (${card_list})"

device_args="--device /dev/biren-m"
for idx in "${free_gpus[@]}"; do
    device_args+=" --device /dev/biren/card_${idx}"
done

# ── Container setup ────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/sglang_${model_weights}_${TIMESTAMP}.log"
CONTAINER_NAME="sglang_${model_weights}"
INNER_SCRIPT="${SCRIPT_DIR}/sglang_server.sh"

if $DOCKER_CMD inspect "$CONTAINER_NAME" &>/dev/null; then
    _warn "Removing existing container: $CONTAINER_NAME"
    $DOCKER_CMD rm -f "$CONTAINER_NAME" >/dev/null
fi

_info "Container   : $CONTAINER_NAME"
_info "Log dir     : $LOG_DIR"
echo ""

$DOCKER_CMD image inspect "$CONTAINER_IMAGE" &>/dev/null || {
    _err "Docker image not found: $CONTAINER_IMAGE"
    _err "Load it with: docker load -i /data/release/2604rc2/images/birensupa-smartinfer-sglang-26.04.rc2-py310-pt2.9.0-br1xx.tar"
    exit 1; }

# ── Start container (sleep infinity — server started separately below) ─────────
# shellcheck disable=SC2086
$DOCKER_CMD run -d \
    --name "$CONTAINER_NAME" \
    --cap-add=IPC_LOCK \
    --shm-size='256g' \
    --ulimit memlock=-1 \
    --ulimit nofile=1048576 \
    -v /home:/home \
    -v /data:/data \
    --net host \
    $device_args \
    -e "BIREN_VISIBLE_DEVICES=${biren_visible}" \
    "$CONTAINER_IMAGE" \
    sleep infinity >/dev/null

_ok "Container started."
echo ""

# ── Write server run script into LOG_DIR ──────────────────────────────────────
RUN_SCRIPT_NAME="run_sglang_${model_weights}_server.sh"
RUN_SCRIPT_PATH="${LOG_DIR}/${RUN_SCRIPT_NAME}"

cat > "${RUN_SCRIPT_PATH}" <<'RUNSCRIPT'
#!/usr/bin/env bash
_ld=$(tr '\0' '\n' < /proc/1/environ | sed -n 's/^LD_LIBRARY_PATH=//p' | head -1)
[[ -n "$_ld" ]] && export LD_LIBRARY_PATH="$_ld"
unset _ld
exec bash "__INNER_SCRIPT__" "__CONFIG_FILE__"
RUNSCRIPT
sed -i "s|__INNER_SCRIPT__|${INNER_SCRIPT}|g; s|__CONFIG_FILE__|${CONFIG_FILE}|g" "${RUN_SCRIPT_PATH}"
chmod +x "${RUN_SCRIPT_PATH}"

_ok "Run script  : ${RUN_SCRIPT_PATH}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# --run mode: exec server directly, poll /health, print test commands
# ══════════════════════════════════════════════════════════════════════════════
if $RUN_MODE; then

    _info "Starting SGLang server (logs → ${LOG_FILE})..."
    $DOCKER_CMD exec -d "$CONTAINER_NAME" \
        bash -c "bash '${RUN_SCRIPT_PATH}' > '${LOG_FILE}' 2>&1"

    _ok "Server process launched inside container."
    echo "  (tail -f ${LOG_FILE})"
    echo ""

    READY=false
    for _ in $(seq 1 120); do
        if curl -sf "http://127.0.0.1:${port}/health" &>/dev/null; then
            READY=true; break
        fi
        printf "."
        sleep 5
    done
    echo ""

    MODEL_API="${served_model_name:-${WEIGHTS_PATH}}"

    if $READY; then
        _ok "═══════════════════════════════════════════════════"
        _ok " SGLang server ready — ${CONTAINER_NAME}  :${port}"
        _ok "═══════════════════════════════════════════════════"
    else
        _warn "Server did not respond within 600 s. It may still be loading."
        _warn "Check: tail -f ${LOG_FILE}"
    fi

    echo ""
    echo "── Chat completion test ───────────────────────────────────"
    echo "curl -s http://127.0.0.1:${port}/v1/chat/completions \\"
    echo "  -H 'Content-Type: application/json' \\"
    echo "  -d '{\"model\": \"${MODEL_API}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}], \"max_tokens\": 64}' \\"
    echo "  | python3 -m json.tool"

    echo ""
    echo "── Container management ──────────────────────────────────"
    echo "  tail -f ${LOG_FILE}"
    echo "  ${DOCKER_CMD} exec -it ${CONTAINER_NAME} bash"
    echo "  ${DOCKER_CMD} stop ${CONTAINER_NAME}"
    echo "  ${DOCKER_CMD} rm   ${CONTAINER_NAME}"

# ══════════════════════════════════════════════════════════════════════════════
# Default (interactive): enter shell at LOG_DIR, user runs the script manually
# ══════════════════════════════════════════════════════════════════════════════
else

    _env_tmp=$(mktemp /tmp/sglang_docker_env_XXXXXX.sh)
    cat > "$_env_tmp" <<ENVSCRIPT
_ld=\$(tr '\0' '\n' < /proc/1/environ | sed -n 's/^LD_LIBRARY_PATH=//p' | head -1)
[[ -n "\$_ld" ]] && export LD_LIBRARY_PATH="\$_ld"
unset _ld
cd '${LOG_DIR}'
echo ""
echo "  Docker shell — SGLang interactive session"
echo "  Model      : ${model_weights}"
echo "  Log dir    : ${LOG_DIR}"
echo "  Start server with:"
echo "    bash ${RUN_SCRIPT_NAME}"
echo ""
ENVSCRIPT
    $DOCKER_CMD exec -i "$CONTAINER_NAME" tee /tmp/.biren_env.sh < "$_env_tmp" > /dev/null
    rm -f "$_env_tmp"

    echo "  To start the server, run inside the container:"
    echo "    bash ${RUN_SCRIPT_NAME}"
    echo ""
    echo "── Container management ──────────────────────────────────"
    echo "  ${DOCKER_CMD} stop ${CONTAINER_NAME}"
    echo "  ${DOCKER_CMD} rm   ${CONTAINER_NAME}"
    echo ""
    _info "Entering interactive shell inside container at ${LOG_DIR} ..."
    _info "(Type 'exit' or Ctrl-D to leave; container keeps running)"
    echo ""

    $DOCKER_CMD exec -it "$CONTAINER_NAME" \
        bash -c "source /tmp/.biren_env.sh && exec bash -i"

fi
