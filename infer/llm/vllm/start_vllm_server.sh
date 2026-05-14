#!/usr/bin/env bash
# Start a vLLM OpenAI-compatible server in a BirenTech Docker container.
#
# Usage:
#   ./start_vllm_server.sh <config_file>
#
# config_file may be:
#   - a bare model name: bge-m3  (resolved to configs/bge-m3.conf)
#   - a relative name:  configs/bge-m3.conf
#   - an absolute path: /path/to/any.conf

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Paths ──────────────────────────────────────────────────────────────────────
MODEL_REGISTRY="${SCRIPT_DIR}/model_registry.conf"
LOG_DIR="${SCRIPT_DIR}/logs"
CONTAINER_IMAGE='birensupa-smartinfer-vllm:26.04.beta1-py310-pt2.8.0-br1xx'

# ── Helpers ────────────────────────────────────────────────────────────────────
_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

# Use sudo for docker if current user cannot access the Docker socket directly
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

# ── Require config argument ────────────────────────────────────────────────────
[[ $# -lt 1 ]] && { _err "A config file is required."; usage; }

CONFIG_ARG="$1"
CONFIG_FILE=""

# Resolve config file path: bare name → configs/<name>.conf, else relative/absolute
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

# ── Load config (defaults cover all optional fields) ───────────────────────────
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

[[ -z "$model_weights" ]] && {
    _err "model_weights is not set in $(basename "$CONFIG_FILE")"; exit 1; }

_info "Config      : $(basename "$CONFIG_FILE")"
_info "Model key   : $model_weights  |  port=$port  |  tp=$tensor_parallel_size  pp=$pipeline_parallel_size"

# ── Lookup model in registry ───────────────────────────────────────────────────
[[ ! -f "$MODEL_REGISTRY" ]] && { _err "Registry not found: $MODEL_REGISTRY"; exit 1; }

registry_get() {
    local section="$1" field="$2"
    awk -v sec="[$1]" -v fld="$2" '
        /^\[/ { cur = $0 }
        cur == sec && match($0, "^" fld "=") {
            print substr($0, length(fld) + 2); exit
        }
    ' "$MODEL_REGISTRY"
}

MODEL_LOCAL_PATH=$(registry_get "$model_weights" "local_path")
MODEL_HF_ID=$(registry_get "$model_weights" "huggingface_id")
MODEL_MS_ID=$(registry_get "$model_weights" "modelscope_id")

[[ -z "$MODEL_HF_ID$MODEL_MS_ID" ]] && {
    _err "Model '$model_weights' not found in $MODEL_REGISTRY"; exit 1; }

_info "Registry    : local=${MODEL_LOCAL_PATH:-(not set)}  hf=$MODEL_HF_ID  ms=$MODEL_MS_ID"

# ── Check / download model weights ─────────────────────────────────────────────
WEIGHTS_PATH=""
if [[ -n "$MODEL_LOCAL_PATH" && -d "$MODEL_LOCAL_PATH" ]]; then
    WEIGHTS_PATH="$MODEL_LOCAL_PATH"
    _ok "Weights     : $WEIGHTS_PATH"
else
    _warn "Local weights not found (${MODEL_LOCAL_PATH:-(path not configured)})"
    read -rp "  Download now? [y/N]: " yn
    if [[ ! "$yn" =~ ^[Yy]$ ]]; then
        _err "Cannot start vLLM server without model weights. Exiting."; exit 1
    fi
    echo "  Download source:"
    echo "    1) modelscope  —  modelscope download --model $MODEL_MS_ID"
    echo "    2) huggingface —  huggingface-cli download $MODEL_HF_ID"
    read -rp "  Choose [1/2]: " src
    DEST="${MODEL_LOCAL_PATH:-/data/models/${MODEL_HF_ID}}"
    mkdir -p "$(dirname "$DEST")"
    case "$src" in
        1)
            _info "Downloading via modelscope: $MODEL_MS_ID → $DEST"
            modelscope download --model "$MODEL_MS_ID" --local_dir "$DEST"
            ;;
        2)
            _info "Downloading via huggingface: $MODEL_HF_ID → $DEST"
            huggingface-cli download "$MODEL_HF_ID" --local-dir "$DEST"
            ;;
        *)
            _err "Invalid choice."; exit 1 ;;
    esac
    WEIGHTS_PATH="$DEST"
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

# Build --device flags for docker run (individual card devices + management device)
device_args="--device /dev/biren-m"
for idx in "${free_gpus[@]}"; do
    device_args+=" --device /dev/biren/card_${idx}"
done

# ── Build vLLM server command ──────────────────────────────────────────────────
vllm_cmd="VLLM_USE_V1=1 VLLM_WORKER_MULTIPROC_METHOD=spawn VLLM_BR_WEIGHT_TYPE=NUMA"
vllm_cmd+=" python3 -m vllm.entrypoints.openai.api_server"
vllm_cmd+=" --host 0.0.0.0"
vllm_cmd+=" --port ${port}"
vllm_cmd+=" --model ${WEIGHTS_PATH}"
[[ -n "$served_model_name" ]]         && vllm_cmd+=" --served_model_name ${served_model_name}"
[[ -n "$task" ]]                      && vllm_cmd+=" --task ${task}"
vllm_cmd+=" --trust_remote_code"
vllm_cmd+=" --dtype ${dtype}"
vllm_cmd+=" --kv_cache_dtype auto"
vllm_cmd+=" --max_model_len ${max_model_len}"
vllm_cmd+=" --max_num_seqs ${max_num_seqs}"
vllm_cmd+=" --tensor_parallel_size ${tensor_parallel_size}"
vllm_cmd+=" --pipeline_parallel_size ${pipeline_parallel_size}"
vllm_cmd+=" --data_parallel_size 1"
vllm_cmd+=" --gpu_memory_utilization ${gpu_memory_utilization}"
[[ "$enforce_eager" == "true" ]]          && vllm_cmd+=" --enforce_eager"
[[ "$enable_chunked_prefill" == "true" ]] && vllm_cmd+=" --enable_chunked_prefill"
[[ -n "$distributed_executor_backend" ]]  && vllm_cmd+=" --distributed_executor_backend ${distributed_executor_backend}"
[[ -n "$compilation_config" ]]            && vllm_cmd+=" --compilation_config '${compilation_config}'"

# ── Container setup ────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/vllm_${model_weights}_${TIMESTAMP}.log"
CONTAINER_NAME="vllm_${model_weights}"

# Remove any existing container with this name (stopped or running)
if $DOCKER_CMD inspect "$CONTAINER_NAME" &>/dev/null; then
    _warn "Removing existing container: $CONTAINER_NAME"
    $DOCKER_CMD rm -f "$CONTAINER_NAME" >/dev/null
fi

_info "Container   : $CONTAINER_NAME"
_info "Log file    : $LOG_FILE"
echo ""

# Verify image exists
$DOCKER_CMD image inspect "$CONTAINER_IMAGE" &>/dev/null || {
    _err "Docker image not found: $CONTAINER_IMAGE"
    _err "Pull or build the image first."; exit 1; }

# Start container in detached mode; vllm output is tee'd to log file
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
    bash -c "${vllm_cmd} 2>&1 | tee ${LOG_FILE}" >/dev/null

_ok "Container started. Waiting for server on port $port..."
echo "  (tail -f ${LOG_FILE}  or  ${DOCKER_CMD} logs -f ${CONTAINER_NAME})"
echo ""

# Poll /health endpoint — vllm returns 200 when the engine is fully loaded
READY=false
for i in $(seq 1 120); do
    if curl -sf "http://127.0.0.1:${port}/health" &>/dev/null; then
        READY=true
        break
    fi
    # Abort early if container died
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
MODEL_API="${served_model_name:-${WEIGHTS_PATH}}"

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
