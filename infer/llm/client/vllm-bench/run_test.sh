#!/usr/bin/env bash
# Run vllm bench serve tests against a live vllm server using a client container.
#
# Usage:
#   bash run_test.sh <config_file> [log_dir]
#
# config_file may be:
#   - a bare name: minimax-m2.5-perf-siming  (resolved to configs/<name>.conf)
#   - a relative path inside this directory
#   - an absolute path
#
# log_dir defaults to <this_script_dir>/logs
#
# The script:
#   1. Loads the config (model API info + test_cases list)
#   2. Creates a timestamped log directory: <log_dir>/vllm_bench_<timestamp>/
#   3. Generates a self-contained bench runner inside that log dir
#   4. Starts a client Docker container (no GPU) and runs all test cases sequentially
#   5. Each case's output is saved to a file named by its four variable parameters

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_IMAGE='birensupa-smartinfer-vllm:26.05.14-py310-pt2.8.0-br1xx'
BENCH_CONTAINER_NAME='vllm_bench_client'

_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

usage() {
    echo ""
    echo "Usage: $0 <config_file> [log_dir]"
    echo ""
    echo "Available configs:"
    for f in "${SCRIPT_DIR}/configs/"*.conf; do
        [[ -f "$f" ]] && echo "  $(basename "$f" .conf)"
    done
    echo ""
    exit 1
}

[[ $# -lt 1 ]] && { _err "A config file is required."; usage; }

# ── Resolve config ─────────────────────────────────────────────────────────────
CONFIG_ARG="$1"
CONFIG_FILE=""

if [[ "$CONFIG_ARG" == /* ]]; then
    CONFIG_FILE="$CONFIG_ARG"
elif [[ -f "${SCRIPT_DIR}/configs/${CONFIG_ARG}.conf" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/configs/${CONFIG_ARG}.conf"
elif [[ -f "${SCRIPT_DIR}/configs/${CONFIG_ARG}" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/configs/${CONFIG_ARG}"
elif [[ -f "${SCRIPT_DIR}/${CONFIG_ARG}" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_ARG}"
elif [[ -f "$CONFIG_ARG" ]]; then
    CONFIG_FILE="$CONFIG_ARG"
fi

[[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]] && {
    _err "Config not found: $CONFIG_ARG"; usage; }

BASE_LOG_DIR="${2:-${SCRIPT_DIR}/logs}"

# ── Load config defaults then source ───────────────────────────────────────────
model_weights=""
port=8000
served_model_name=""
api_format=openai
host=127.0.0.1
dataset_name=random
tokenizer=""
trust_remote_code=false
ignore_eos=false
top_p=1
top_k=-1
temperature=0
declare -a test_cases=()

# shellcheck source=/dev/null
source "$CONFIG_FILE"

[[ -z "$model_weights" ]] && { _err "model_weights not set in $(basename "$CONFIG_FILE")"; exit 1; }
[[ ${#test_cases[@]} -eq 0 ]] && { _err "test_cases is empty in $(basename "$CONFIG_FILE")"; exit 1; }

# API model identifier: prefer served_model_name, fall back to model_weights path
MODEL_ID="${served_model_name:-${model_weights}}"

_info "Config     : $(basename "$CONFIG_FILE")"
_info "Server     : ${host}:${port}  format=${api_format}"
_info "Model ID   : ${MODEL_ID}"
_info "Test cases : ${#test_cases[@]}"
echo ""

# ── Create log directory ───────────────────────────────────────────────────────
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOG_DIR="${BASE_LOG_DIR}/vllm_bench_${TIMESTAMP}"
mkdir -p "$LOG_DIR"
_info "Log dir    : $LOG_DIR"

# ── Docker command ─────────────────────────────────────────────────────────────
DOCKER_CMD="docker"
if ! docker info &>/dev/null 2>&1; then
    if sudo -n docker info &>/dev/null 2>&1; then
        DOCKER_CMD="sudo docker"
    else
        _warn "Docker requires sudo (may prompt for password)."
        DOCKER_CMD="sudo docker"
    fi
fi

if ! $DOCKER_CMD image inspect "$CONTAINER_IMAGE" &>/dev/null 2>&1; then
    _err "Docker image not found: $CONTAINER_IMAGE"
    _err "Pull or build the image first."; exit 1
fi

# Remove any leftover container with the same name
if $DOCKER_CMD inspect "$BENCH_CONTAINER_NAME" &>/dev/null 2>&1; then
    _warn "Removing stale container: $BENCH_CONTAINER_NAME"
    $DOCKER_CMD rm -f "$BENCH_CONTAINER_NAME" >/dev/null
fi

# ── Build optional flag strings ────────────────────────────────────────────────
tr_flag=""
[[ "$trust_remote_code" == "true" ]] && tr_flag="--trust-remote-code"
eos_flag=""
[[ "$ignore_eos" == "true" ]] && eos_flag="--ignore-eos"

# ── Generate Python wrapper (bypasses vllm CLI GPU check) ─────────────────────
# The BirenTech vllm CLI entrypoint fails without GPU, but vllm.benchmarks.serve
# (which is just an HTTP client) can be imported and called directly.
BENCH_WRAPPER="${LOG_DIR}/.bench_wrapper.py"
cat > "$BENCH_WRAPPER" << 'PYWRAPPER'
#!/usr/bin/env python3
"""
Direct entry point for vllm.benchmarks.serve.main.
Bypasses the vllm CLI arg-parser which initialises VllmConfig (requires GPU).
"""
import sys

def try_vllm_benchmarks():
    try:
        from vllm.benchmarks.serve import add_cli_args, main
        import argparse
        parser = argparse.ArgumentParser(description="vllm benchmark serving")
        add_cli_args(parser)
        args = parser.parse_args()
        main(args)
        return True
    except ImportError:
        return False

if not try_vllm_benchmarks():
    print("[ERR] vllm.benchmarks.serve not available. Install open-source vllm.", file=sys.stderr)
    sys.exit(1)
PYWRAPPER

# ── Generate inner runner script ───────────────────────────────────────────────
INNER_SCRIPT="${LOG_DIR}/.bench_runner.sh"

cat > "$INNER_SCRIPT" << 'HEADER'
#!/usr/bin/env bash
set -euo pipefail

_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

# ── Detect bench method ────────────────────────────────────────────────────────
_info "Checking vllm.benchmarks.serve availability..."
if python3 -c "from vllm.benchmarks.serve import main" &>/dev/null 2>&1; then
    _info "Using: python3 .bench_wrapper.py (direct vllm.benchmarks.serve call)"
    BENCH_PY=true
else
    _warn "vllm.benchmarks.serve not importable, installing open-source vllm..."
    pip install vllm -q
    if python3 -c "from vllm.benchmarks.serve import main" &>/dev/null 2>&1; then
        _info "Using newly installed vllm.benchmarks.serve"
        BENCH_PY=true
    elif command -v vllm &>/dev/null && vllm bench serve --help &>/dev/null 2>&1; then
        _info "Falling back to: vllm bench serve"
        BENCH_PY=false
    else
        _err "Cannot find usable vllm bench tool"; exit 1
    fi
fi
echo ""
HEADER

# Append one block per test case
TOTAL=${#test_cases[@]}
IDX=0
for tc in "${test_cases[@]}"; do
    read -r input_len output_len concurrency num_prompts <<< "$tc"
    IDX=$((IDX + 1))
    log_name="bench_in${input_len}_out${output_len}_conc${concurrency}_req${num_prompts}.log"
    log_file="${LOG_DIR}/${log_name}"

    _info "  [${IDX}/${TOTAL}] in=${input_len} out=${output_len} conc=${concurrency} req=${num_prompts} -> ${log_name}"

    # Build the argument list (use hyphen format matching vllm 0.11.0 arg names)
    bench_args="--host ${host} --port ${port} --model '${MODEL_ID}'"
    bench_args+=" --dataset-name ${dataset_name}"
    bench_args+=" --random-input-len ${input_len}"
    bench_args+=" --random-output-len ${output_len}"
    bench_args+=" --max-concurrency ${concurrency}"
    bench_args+=" --num-prompts ${num_prompts}"
    bench_args+=" --top-p ${top_p} --top-k ${top_k} --temperature ${temperature}"
    [[ -n "$tokenizer" ]]  && bench_args+=" --tokenizer '${tokenizer}'"
    [[ -n "$tr_flag" ]]    && bench_args+=" ${tr_flag}"
    [[ -n "$eos_flag" ]]   && bench_args+=" ${eos_flag}"

    cat >> "$INNER_SCRIPT" << EOF
_info "[${IDX}/${TOTAL}] Starting: in=${input_len} out=${output_len} conc=${concurrency} req=${num_prompts}"
if \$BENCH_PY; then
    python3 '${BENCH_WRAPPER}' ${bench_args} 2>&1 | tee '${log_file}'
else
    vllm bench serve ${bench_args} 2>&1 | tee '${log_file}'
fi
_ok "Done [${IDX}/${TOTAL}]: ${log_name}"
echo ""
EOF

done

cat >> "$INNER_SCRIPT" << 'FOOTER'
_ok "All benchmark tests complete."
FOOTER

chmod +x "$INNER_SCRIPT"

echo ""
_info "Generated runner : $INNER_SCRIPT"
_info "Generated wrapper: $BENCH_WRAPPER"
_info "Starting container: $BENCH_CONTAINER_NAME"
echo ""

# ── Run client container (no GPU devices needed) ───────────────────────────────
# VLLM_PLUGINS="" prevents the BirenTech plugin from loading (it needs GPU drivers).
# NO_PROXY / no_proxy bypass any system HTTP proxy so bench requests reach the server.
$DOCKER_CMD run --rm \
    --name "$BENCH_CONTAINER_NAME" \
    --net host \
    -v /home:/home \
    -v /data:/data \
    -e VLLM_PLUGINS="" \
    -e NO_PROXY="*" \
    -e no_proxy="*" \
    -e http_proxy="" \
    -e https_proxy="" \
    -e HF_HUB_OFFLINE=1 \
    -e TRANSFORMERS_OFFLINE=1 \
    "$CONTAINER_IMAGE" \
    bash "$INNER_SCRIPT"

echo ""
_ok "═══════════════════════════════════════════════════════"
_ok " Benchmark complete. Results in:"
_ok "   $LOG_DIR"
_ok "═══════════════════════════════════════════════════════"
