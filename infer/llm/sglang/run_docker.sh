#!/usr/bin/env bash
# Launch a BirenTech Docker container for SGLang serving.
#
# Usage:
#   sudo bash run_docker.sh [--run] <config_ref>
#
#   (default)  Start the container, write a server run script to the log
#              directory, then enter an interactive shell there.  The user
#              starts the server manually:  bash run_sglang_<model>_server.sh
#
#   --run      Write the run script, then exec the server directly (no
#              interactive shell).  Polls /health and prints test commands
#              once the server is ready.
#
# config_ref is resolved by utils/parse_config.sh:
#   - a bare model name:  qwen3-vl-32b   (-> configs/sglang_qwen3-vl-32b.conf)
#   - a prefixed name:    sglang_qwen3-vl-32b
#   - a path under configs/ or an absolute path
# The config's framework= field must be 'sglang'.
#
# /home and /data are bind-mounted so sglang_server.sh, the unified parser,
# model weights, and configs are accessible at the same paths inside the container.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Paths ──────────────────────────────────────────────────────────────────────
LOG_DIR="${SCRIPT_DIR}/logs"
CONTAINER_IMAGE='birensupa-smartinfer-sglang:26.04.rc2-py310-pt2.9.0-br1xx'

# ── Helpers ────────────────────────────────────────────────────────────────────
_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

# parse_config.sh provides parse_config + port_in_use/ensure_dir helpers.
# shellcheck source=../utils/parse_config.sh
source "${LLM_DIR}/utils/parse_config.sh"

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
    echo "Usage: $0 [--run] <config_ref>"
    echo ""
    echo "  (default)  Enter interactive shell; start server manually inside"
    echo "  --run      Write run script then exec server directly (no interactive shell)"
    echo ""
    echo "Available SGLang configs:"
    for f in "${LLM_DIR}/configs/"sglang_*.conf; do
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

# ── Load + validate config (framework must be sglang; defaults filled) ─────────
parse_config "$CONFIG_ARG" sglang || usage
[[ -n "${docker_image:-}" ]] && CONTAINER_IMAGE="$docker_image"

_info "Config      : $(basename "$CONFIG_FILE")  [mode=$( $RUN_MODE && echo --run || echo interactive)]"
if [[ "${launch_mode}" == "multimodal_gen" ]]; then
    _info "Model key   : $model_weights  |  port=$port  |  tp=$tensor_parallel_size  [multimodal_gen]"
else
    _info "Model key   : $model_weights  |  port=$port  |  tp=$tensor_parallel_size  pp=$pipeline_parallel_size"
fi

# ── Host port availability (server runs with --net host) ───────────────────────
if port_in_use "$port"; then
    _err "Port ${port} is already in use on this host (--net host)."
    _err "Stop the conflicting process or change 'port' in $(basename "$CONFIG_FILE")."; exit 1
fi

# ── Registry lookup (via model_registry.sh) ───────────────────────────────────
# shellcheck source=../model_registry.sh
source "${LLM_DIR}/model_registry.sh"
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
if [[ "${launch_mode}" == "multimodal_gen" ]]; then
    gpu_needed=$tensor_parallel_size
else
    gpu_needed=$((tensor_parallel_size * pipeline_parallel_size))
fi
_info "GPU needed  : tp=$tensor_parallel_size × pp=$pipeline_parallel_size = $gpu_needed"

mapfile -t free_gpus < <(
    brsmi gpu --query-gpu=index,memory.used --format=csv,noheader,nounits 2>/dev/null \
    | awk -F',' '{ gsub(/ /,"",$1); gsub(/ /,"",$2); if ($2+0 < 512) print $1 }' \
    | head -n "$gpu_needed"
)

if [[ ${#free_gpus[@]} -lt $gpu_needed ]]; then
    _err "Not enough free GPUs: need $gpu_needed, found ${#free_gpus[@]} with <512 MiB used."
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
ensure_dir "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/sglang_${model_weights}_${TIMESTAMP}.log"
CONTAINER_NAME="sglang_${model_weights}"
INNER_SCRIPT="${SCRIPT_DIR}/sglang_server.sh"

if $DOCKER_CMD inspect "$CONTAINER_NAME" &>/dev/null; then
    _warn "Removing existing container: $CONTAINER_NAME"
    $DOCKER_CMD rm -f "$CONTAINER_NAME" >/dev/null
fi

_info "Container   : $CONTAINER_NAME"
_info "Image       : $CONTAINER_IMAGE"
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
