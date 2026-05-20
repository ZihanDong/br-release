#!/usr/bin/env bash
# Two-stage weight quantization pipeline for MiniMax M2.5:
#   Stage 1 — FP8 → BF16  (cast_fp8_bf16.py,        single-process)
#   Stage 2 — BF16 → INT8 (convert-to-compressed.py, torchrun distributed)
#
# Both stages run inside the BirenTech vLLM container.  The script mounts
# /home and /data so the quant scripts and model weights are accessible at
# the same paths as on the host.
#
# Usage: sudo bash run_quant.sh
# Edit the Configuration section below before running.

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
FP8_PATH="/data/models/MiniMax/MiniMax-M2.5"
TEMP_BF16_PATH="/data/models/MiniMax/MiniMax-M2.5-TEMP"
INT8_PATH="/data/models/MiniMax/MiniMax-M2.5-INT8"

# Same image as the vLLM server (provides torch + BirenTech SDK + biren_entrypoint.sh)
CONTAINER_IMAGE="birensupa-smartinfer-vllm:26.05.14-py310-pt2.8.0-br1xx"

# Number of GPUs for the distributed INT8 quantization step (Stage 2).
# Set to the number of available BirenTech GPU cards.
NUM_GPUS=8

# ── Script internals ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="vllm_quant_m2.5"
LOG_DIR="${SCRIPT_DIR}/../logs"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_FILE="${LOG_DIR}/quant_m2.5_${TIMESTAMP}.log"

_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

DOCKER_CMD="docker"
if ! docker info &>/dev/null 2>&1; then
    if sudo -n docker info &>/dev/null 2>&1; then
        DOCKER_CMD="sudo docker"
    else
        _err "Docker not accessible. Run with sudo or fix Docker socket permissions."
        exit 1
    fi
fi

# ── Pre-flight checks ─────────────────────────────────────────────────────────
[[ ! -d "$FP8_PATH" ]] && { _err "FP8 weights not found: $FP8_PATH"; exit 1; }
$DOCKER_CMD image inspect "$CONTAINER_IMAGE" &>/dev/null || {
    _err "Docker image not found: $CONTAINER_IMAGE"
    _err "Ensure the BirenTech smartinfer-vllm image is loaded."; exit 1; }

mkdir -p "$LOG_DIR" "$TEMP_BF16_PATH" "$INT8_PATH"

# Remove leftover container from a previous interrupted run
$DOCKER_CMD inspect "$CONTAINER_NAME" &>/dev/null && \
    $DOCKER_CMD rm -f "$CONTAINER_NAME" >/dev/null

# ── Map all GPU devices ───────────────────────────────────────────────────────
device_args="--device /dev/biren-m"
BIREN_VISIBLE=""
for i in $(seq 0 $((NUM_GPUS - 1))); do
    device_args+=" --device /dev/biren/card_${i}"
    BIREN_VISIBLE+="${i},"
done
BIREN_VISIBLE="${BIREN_VISIBLE%,}"

_info "FP8 source  : $FP8_PATH"
_info "BF16 temp   : $TEMP_BF16_PATH"
_info "INT8 output : $INT8_PATH"
_info "Image       : $CONTAINER_IMAGE"
_info "GPUs        : [${BIREN_VISIBLE}]"
_info "Log file    : $LOG_FILE"
echo ""

# ── Start container and run pipeline ─────────────────────────────────────────
# The image ENTRYPOINT (biren_entrypoint.sh) sets LD_LIBRARY_PATH then exec's args.
# We pass the pipeline as 'bash -c "..."' so the ENTRYPOINT runs first.
#
# Paths are injected via -e so they are available as env vars inside the container.
_info "Starting quantization container..."
echo ""

# shellcheck disable=SC2086
$DOCKER_CMD run \
    --name "$CONTAINER_NAME" \
    --cap-add=IPC_LOCK \
    --ipc=host \
    --shm-size='256g' \
    --ulimit memlock=-1 \
    --ulimit nofile=1048576 \
    -v /home:/home \
    -v /data:/data \
    $device_args \
    -e "BIREN_VISIBLE_DEVICES=${BIREN_VISIBLE}" \
    -e "_FP8=${FP8_PATH}" \
    -e "_TEMP=${TEMP_BF16_PATH}" \
    -e "_INT8=${INT8_PATH}" \
    -e "_QDIR=${SCRIPT_DIR}" \
    -e "_NGPU=${NUM_GPUS}" \
    "$CONTAINER_IMAGE" \
    bash -c '
set -e
echo "[INFO]  Installing Python dependencies..."
pip install -q --no-cache-dir accelerate compressed-tensors transformers 2>&1 | tail -3

# ── Stage 1: FP8 → BF16 (CPU mode — BirenTech PyTorch has no CUDA backend) ──
if [ -f "${_TEMP}/model.safetensors.index.json" ]; then
    echo "[ OK ]  BF16 temp weights already exist, skipping Stage 1"
else
    echo "[INFO]  Stage 1: Casting FP8 → BF16 (CPU)..."
    # Patch device="cuda" → device="cpu"; run from QDIR so kernel.py is importable
    cd "${_QDIR}"
    export PYTHONPATH="${_QDIR}:${PYTHONPATH:-}"
    _CAST_CPU="/tmp/cast_fp8_bf16_cpu.py"
    sed "s/device=\"cuda\"/device=\"cpu\"/g" "cast_fp8_bf16.py" > "${_CAST_CPU}"
    python3 "${_CAST_CPU}" \
        --input-fp8-hf-path  "${_FP8}" \
        --output-bf16-hf-path "${_TEMP}"

    # Copy config / tokenizer / modeling files (not safetensors, not the updated index)
    find "${_FP8}" -maxdepth 1 -type f \
        ! -name "*.safetensors" \
        ! -name "model.safetensors.index.json" \
        -exec cp -n {} "${_TEMP}/" \;

    echo "[ OK ]  Stage 1 complete: ${_TEMP}"
fi

# ── Stage 2: BF16 → INT8 (CPU single-process, shard-index driven) ────────────
if [ -f "${_INT8}/model.safetensors.index.json" ]; then
    echo "[ OK ]  INT8 weights already exist, skipping Stage 2"
else
    echo "[INFO]  Stage 2: Quantizing BF16 → INT8 (CPU, single-process)..."
    cd "${_QDIR}"
    export PYTHONPATH="${_QDIR}:${PYTHONPATH:-}"
    python3 convert_int8_cpu.py \
        --model-name-or-path "${_TEMP}" \
        --packed-model-path  "${_INT8}" \
        --dtype bfloat16
    echo "[ OK ]  Stage 2 complete: ${_INT8}"
fi

echo ""
echo "[ OK ]  ══════════════════════════════════════════════════"
echo "[ OK ]   Quantization finished.  INT8 weights ready."
echo "[ OK ]   ${_INT8}"
echo "[ OK ]  ══════════════════════════════════════════════════"
' 2>&1 | tee "$LOG_FILE"
