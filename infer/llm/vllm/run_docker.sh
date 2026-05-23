#!/usr/bin/env bash
# Launch a BirenTech Docker container and start vLLM via vllm_server.sh inside it.
#
# Usage:
#   sudo bash run_docker.sh <config_file>
#
# config_file may be:
#   - a bare model name: bge-m3  (resolved to configs/bge-m3.conf)
#   - a relative path:   configs/bge-m3.conf
#   - an absolute path:  /path/to/any.conf
#
# The script:
#   1. Selects free BirenTech GPUs via brsmi
#   2. Starts the container (maps only the required /dev/biren/card_N devices)
#   3. Inside the container, calls vllm_server.sh to launch vLLM
#   4. Polls /health until the server is ready
#
# /home is bind-mounted into the container so vllm_server.sh, model_registry.conf,
# and configs/ are accessible at the same paths as on the host.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Paths ──────────────────────────────────────────────────────────────────────
_REGISTRY_SH="${SCRIPT_DIR}/../model_registry.sh"
LOG_DIR="${SCRIPT_DIR}/logs"
CONTAINER_IMAGE='birensupa-smartinfer-vllm:26.04.rc2-py310-pt2.8.0-br1xx'

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
    echo "Usage: $0 <config_file>"
    echo ""
    echo "Available configs:"
    for f in "${SCRIPT_DIR}/configs/"*.conf; do
        [[ -f "$f" ]] && echo "  $(basename "$f" .conf)"
    done
    echo ""
    exit 1
}

# ── Resolve config ─────────────────────────────────────────────────────────────
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

# ── Load config ────────────────────────────────────────────────────────────────
port=8000
served_model_name=""
task=""
dtype="auto"
max_model_len=8192
max_num_seqs=64
pipeline_parallel_size=1
tensor_parallel_size=1
gpu_memory_utilization=0.8
enable_chunked_prefill=false
enforce_eager=false
distributed_executor_backend=""
compilation_config=""
model_weights=""

# shellcheck source=/dev/null
source "$CONFIG_FILE"

[[ -z "$model_weights" ]] && { _err "model_weights not set in $(basename "$CONFIG_FILE")"; exit 1; }

_info "Config      : $(basename "$CONFIG_FILE")"
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
LOG_FILE="${LOG_DIR}/vllm_${model_weights}_${TIMESTAMP}.log"
CONTAINER_NAME="vllm_${model_weights}"

if $DOCKER_CMD inspect "$CONTAINER_NAME" &>/dev/null; then
    _warn "Removing existing container: $CONTAINER_NAME"
    $DOCKER_CMD rm -f "$CONTAINER_NAME" >/dev/null
fi

_info "Container   : $CONTAINER_NAME"
_info "Log file    : $LOG_FILE"
echo ""

$DOCKER_CMD image inspect "$CONTAINER_IMAGE" &>/dev/null || {
    _err "Docker image not found: $CONTAINER_IMAGE"
    _err "Pull or build the image first."; exit 1; }

# ── Start container ────────────────────────────────────────────────────────────
# /home is bind-mounted so SCRIPT_DIR and CONFIG_FILE are at the same paths inside the container.
# The image ENTRYPOINT (biren_entrypoint.sh) runs first to set LD_LIBRARY_PATH, then exec's args.
INNER_SCRIPT="${SCRIPT_DIR}/vllm_server.sh"

# shellcheck disable=SC2086
$DOCKER_CMD run -d \
    --name "$CONTAINER_NAME" \
    --cap-add=IPC_LOCK \
    --shm-size='256g' \
    --ulimit memlock=-1 \
    --ulimit nofile=1048576 \
    -v /home:/home \
    -v /data:/data \
    -v "${SCRIPT_DIR}/patches/vllm_br_parameter.py:/usr/local/lib/python3.10/dist-packages/vllm_br/model_executor/parameter.py:ro" \
    --net host \
    $device_args \
    -e "BIREN_VISIBLE_DEVICES=${biren_visible}" \
    "$CONTAINER_IMAGE" \
    bash -c "bash '${INNER_SCRIPT}' '${CONFIG_FILE}' 2>&1 | tee '${LOG_FILE}'" >/dev/null

_ok "Container started. Waiting for server on port $port..."
echo "  (tail -f ${LOG_FILE}  or  ${DOCKER_CMD} logs -f ${CONTAINER_NAME})"
echo ""

# ── Poll /health ───────────────────────────────────────────────────────────────
READY=false
for _ in $(seq 1 120); do
    if curl -sf "http://127.0.0.1:${port}/health" &>/dev/null; then
        READY=true; break
    fi
    running=$($DOCKER_CMD inspect "$CONTAINER_NAME" --format '{{.State.Running}}' 2>/dev/null || echo "false")
    if [[ "$running" != "true" ]]; then
        _err "Container exited unexpectedly. Last 30 log lines:"
        $DOCKER_CMD logs "$CONTAINER_NAME" --tail 30 2>&1 || true
        exit 1
    fi
    printf "."
    sleep 5
done
echo ""

MODEL_API="${served_model_name:-${WEIGHTS_PATH}}"

if $READY; then
    _ok "═══════════════════════════════════════════════════"
    _ok " vLLM server ready — ${CONTAINER_NAME}  :${port}"
    _ok "═══════════════════════════════════════════════════"
else
    _warn "Server did not respond within 600 s. It may still be loading."
    _warn "Check: ${DOCKER_CMD} logs -f ${CONTAINER_NAME}"
fi

# ── Print test commands ────────────────────────────────────────────────────────
echo ""
if [[ "$task" == "embed" ]]; then
    echo "── Embedding test ────────────────────────────────────────"
    echo "curl -s http://127.0.0.1:${port}/v1/embeddings \\"
    echo "  -H 'Content-Type: application/json' \\"
    echo "  -d '{\"model\": \"${MODEL_API}\", \"input\": \"Hello, world!\"}' \\"
    echo "  | python3 -m json.tool"
else
    echo "── Chat completion test ───────────────────────────────────"
    echo "curl -s http://127.0.0.1:${port}/v1/chat/completions \\"
    echo "  -H 'Content-Type: application/json' \\"
    echo "  -d '{\"model\": \"${MODEL_API}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}], \"max_tokens\": 64}' \\"
    echo "  | python3 -m json.tool"
fi

echo ""
echo "── Container management ──────────────────────────────────"
echo "  ${DOCKER_CMD} logs -f ${CONTAINER_NAME}"
echo "  ${DOCKER_CMD} stop ${CONTAINER_NAME}"
echo "  ${DOCKER_CMD} rm   ${CONTAINER_NAME}"
