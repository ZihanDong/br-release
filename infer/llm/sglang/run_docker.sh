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

# parse_image_list.sh provides parse_image_list (optional --env base-image selection).
# shellcheck source=../utils/parse_image_list.sh
source "${LLM_DIR}/utils/parse_image_list.sh"

# Default image-list file for this framework (override with --env-list).
ENV_LIST="${SCRIPT_DIR}/sglang_images.list"
ENV_NAME=""

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
    echo "Usage: $0 [--run] [--env <name>] [--env-list <file>] <config_ref>"
    echo ""
    echo "  (default)   Enter interactive shell; start server manually inside"
    echo "  --run       Write run script then exec server directly (no interactive shell)"
    echo "  --env       Pick a base image (+ in-container setup) from the image list"
    echo "  --env-list  Image-list file (default: ${ENV_LIST})"
    echo ""
    echo "Available SGLang configs:"
    for f in "${LLM_DIR}/configs/"sglang_*.conf; do
        [[ -f "$f" ]] && echo "  $(basename "$f" .conf)"
    done
    if [[ -f "$ENV_LIST" ]]; then
        echo ""
        echo "Available --env entries (${ENV_LIST}):"
        list_image_envs "$ENV_LIST"
    fi
    echo ""
    exit 1
}

# ── Parse arguments ────────────────────────────────────────────────────────────
RUN_MODE=false
CONFIG_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run)      RUN_MODE=true; shift ;;
        --env)      [[ $# -lt 2 ]] && { _err "--env requires a name argument"; usage; }; ENV_NAME="$2"; shift 2 ;;
        --env-list) [[ $# -lt 2 ]] && { _err "--env-list requires a file argument"; usage; }; ENV_LIST="$2"; shift 2 ;;
        -*)         _err "Unknown option: $1"; usage ;;
        *)          CONFIG_ARG="$1"; shift ;;
    esac
done

[[ -z "$CONFIG_ARG" ]] && { _err "A config file is required."; usage; }

# ── Load + validate config (framework must be sglang; defaults filled) ─────────
parse_config "$CONFIG_ARG" sglang || usage
[[ -n "${docker_image:-}" ]] && CONTAINER_IMAGE="$docker_image"

# ── Optional --env: base image (+ in-container setup) from the image list ──────
# Overrides the config's docker_image; the setup runs inside the container right
# after it starts (below), bringing the image up to a model-runnable state.
ENV_SETUP=""
if [[ -n "$ENV_NAME" ]]; then
    parse_image_list "$ENV_LIST" "$ENV_NAME" || exit 1
    CONTAINER_IMAGE="$IMG_NAME"
    ENV_SETUP="$IMG_SETUP"
    _info "Env         : ${ENV_NAME}  (${ENV_LIST##*/})${IMG_DESC:+  — ${IMG_DESC}}"
fi

_info "Config      : $(basename "$CONFIG_FILE")  [mode=$( $RUN_MODE && echo --run || echo interactive)]"
if [[ "${launch_mode}" == "multimodal_gen" ]]; then
    _info "Model key   : $model_weights  |  port=$port  |  tp=$tensor_parallel_size  [multimodal_gen]"
elif [[ "${launch_mode}" == "video_gen" ]]; then
    _info "Model key   : $model_weights  |  port=$port  |  gpus=$tensor_parallel_size  usp=$ulysses_degree ring=$ring_degree cfg=$enable_cfg_parallel  [video_gen]"
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
# Diffusion modes (multimodal_gen / video_gen) treat tensor_parallel_size as the
# TOTAL card count; standard mode needs tp × pp cards.
if [[ "${launch_mode}" == "multimodal_gen" || "${launch_mode}" == "video_gen" ]]; then
    gpu_needed=$tensor_parallel_size
    _info "GPU needed  : $gpu_needed (total cards, ${launch_mode})"
else
    gpu_needed=$((tensor_parallel_size * pipeline_parallel_size))
    _info "GPU needed  : tp=$tensor_parallel_size × pp=$pipeline_parallel_size = $gpu_needed"
fi

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

# ── Optional --env in-container setup (bring the image up to a runnable state) ──
if [[ -n "${ENV_SETUP:-}" ]]; then
    _info "Env setup   : ${ENV_SETUP}"
    if $DOCKER_CMD exec "$CONTAINER_NAME" bash -c "${ENV_SETUP}"; then
        _ok "Env setup complete."
    else
        rc=$?; _err "Env setup failed (exit ${rc}). Removing container."
        $DOCKER_CMD rm -f "$CONTAINER_NAME" >/dev/null 2>&1; exit 1
    fi
    echo ""
fi

# ── Write server run script into LOG_DIR ──────────────────────────────────────
# The launch_mode branching (standard LLM / multimodal_gen / video_gen) lives in
# the in-container launcher sglang_server.sh (via the shared sglang_launch.sh
# library), which is also the k8s INNER_SCRIPT — so Docker and k8s start servers
# identically. multimodal_gen launches via launch_multimodal_gen.py (spawn-safe),
# mirroring the LLM `python3 -m sglang.launch_server` style.
INNER_SCRIPT="${SCRIPT_DIR}/sglang_server.sh"
RUN_SCRIPT_NAME="run_sglang_${model_weights}_server.sh"
RUN_SCRIPT_PATH="${LOG_DIR}/${RUN_SCRIPT_NAME}"

cat > "${RUN_SCRIPT_PATH}" <<'RUNSCRIPT'
#!/usr/bin/env bash
# Inherit the BirenTech entrypoint env (PYTHONPATH / LD_LIBRARY_PATH / PATH / …)
# that biren_entrypoint.sh set on PID 1. `docker exec` does NOT inherit it, and
# the SUDNN JIT compiler needs PYTHONPATH (sdk .../sulib/lib → br_generator) or
# VAE-decode kernel compilation fails ("No module named 'br_generator'" →
# SUDNN "build graph failed"). Propagate the whole PID-1 environ, not just LD path.
while IFS= read -r -d '' _kv; do export "$_kv"; done < /proc/1/environ
unset _kv
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
    if [[ "${launch_mode}" == "video_gen" ]]; then
        echo "── Wan2.2 video test (4-step quick check) ─────────────────"
        echo "  bash ${SCRIPT_DIR}/wan_video_client.sh --port ${port} --steps 4 \\"
        echo "    --prompt 'a white cat wearing sunglasses on a surfboard' --size 832x480"
        echo "  # i2v: add  --image /path/to/first_frame.jpg"
    else
        echo "── Chat completion test ───────────────────────────────────"
        echo "curl -s http://127.0.0.1:${port}/v1/chat/completions \\"
        echo "  -H 'Content-Type: application/json' \\"
        echo "  -d '{\"model\": \"${MODEL_API}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}], \"max_tokens\": 64}' \\"
        echo "  | python3 -m json.tool"
    fi

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
# Inherit the full BirenTech entrypoint env from PID 1 (PYTHONPATH for br_generator,
# LD_LIBRARY_PATH, PATH, …) — docker exec does not get it. See run-script note above.
while IFS= read -r -d '' _kv; do export "\$_kv"; done < /proc/1/environ
unset _kv
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
