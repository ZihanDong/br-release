#!/usr/bin/env bash
# Launch a BirenTech Docker container for vLLM serving.
#
# Usage:
#   sudo bash run_docker.sh [--run] <config_file> [proxy_conf]
#
#   (default)  Start the container, write a server run script to the log
#              directory, then enter an interactive shell there.
#
#   --run      Write the run script, then exec the server directly (no
#              interactive shell).
#
# Config file types (detected by suffix):
#   *.conf          → normal vLLM server via vllm_server.sh
#   *.p.conf        → PD Prefill node via vllm_server_pd.sh (requires proxy_conf)
#   *.d.conf        → PD Decode node via vllm_server_pd.sh (requires proxy_conf)
#   *.proxy.conf    → Proxy server only via proxy_server.sh (no GPU needed)
#
# For *.p.conf / *.d.conf, pass the proxy conf as the second positional arg:
#   sudo bash run_docker.sh --run configs/minimax-m2.5.p.conf proxy_conf/minimax-m2.5.proxy.conf
#
# Health check: use tests/test_healthcheck.sh after the server is up.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Paths ──────────────────────────────────────────────────────────────────────
LOG_DIR="${SCRIPT_DIR}/logs"
CONTAINER_IMAGE='birensupa-smartinfer-vllm:26.05.28-py310-pt2.8.0-c059s001t003b24145-br1xx'

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
    echo "Usage: $0 [--run] <config_file> [proxy_conf]"
    echo ""
    echo "  (default)  Enter interactive shell; start server manually inside"
    echo "  --run      Write run script then exec server directly"
    echo ""
    echo "Config types:"
    echo "  *.conf         — normal vLLM server"
    echo "  *.p.conf       — PD Prefill node (requires proxy_conf)"
    echo "  *.d.conf       — PD Decode node (requires proxy_conf)"
    echo "  *.proxy.conf   — Proxy server only (no GPU)"
    echo ""
    echo "Available configs:"
    for f in "${SCRIPT_DIR}/configs/"*.conf; do
        [[ -f "$f" ]] && echo "  $(basename "$f")"
    done
    echo ""
    echo "Available proxy confs:"
    for f in "${SCRIPT_DIR}/proxy_conf/"*.proxy.conf; do
        [[ -f "$f" ]] && echo "  proxy_conf/$(basename "$f")"
    done
    echo ""
    exit 1
}

# ── Parse arguments ────────────────────────────────────────────────────────────
RUN_MODE=false
CONFIG_ARG=""
PROXY_CONF_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run) RUN_MODE=true; shift ;;
        -*)    _err "Unknown option: $1"; usage ;;
        *)
            if [[ -z "$CONFIG_ARG" ]]; then
                CONFIG_ARG="$1"
            elif [[ -z "$PROXY_CONF_ARG" ]]; then
                PROXY_CONF_ARG="$1"
            else
                _err "Unexpected argument: $1"; usage
            fi
            shift ;;
    esac
done

[[ -z "$CONFIG_ARG" ]] && { _err "A config file is required."; usage; }

# ── Detect config type from suffix ────────────────────────────────────────────
CONFIG_BASENAME="$(basename "$CONFIG_ARG")"
if [[ "$CONFIG_BASENAME" == *.proxy.conf ]]; then
    MODE="proxy"
elif [[ "$CONFIG_BASENAME" == *.p.conf ]]; then
    MODE="pd"
elif [[ "$CONFIG_BASENAME" == *.d.conf ]]; then
    MODE="pd"
else
    MODE="normal"
fi

_info "Mode        : $MODE"

# ── Helper: resolve config path ────────────────────────────────────────────────
resolve_config() {
    local arg="$1" search_dirs=("${@:2}")
    local file=""
    if [[ "$arg" == /* ]]; then
        file="$arg"
    else
        for dir in "${search_dirs[@]}"; do
            [[ -f "${dir}/${arg}" ]] && { file="${dir}/${arg}"; break; }
        done
        [[ -z "$file" && -f "${SCRIPT_DIR}/${arg}" ]] && file="${SCRIPT_DIR}/${arg}"
        [[ -z "$file" && -f "$arg" ]] && file="$arg"
    fi
    echo "$file"
}

# ══════════════════════════════════════════════════════════════════════════════
# PROXY MODE — no GPU, just run proxy_server.sh
# ══════════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "proxy" ]]; then

    PROXY_FILE="$(resolve_config "$CONFIG_ARG" \
        "${SCRIPT_DIR}/proxy_conf" "${SCRIPT_DIR}/configs")"
    [[ -z "$PROXY_FILE" || ! -f "$PROXY_FILE" ]] && {
        _err "Proxy conf not found: $CONFIG_ARG"; usage; }

    proxy_host="0.0.0.0"; proxy_port=35111; proxy_zmq_port=34367
    # shellcheck source=/dev/null
    source "$PROXY_FILE"

    MODEL_NAME="$(basename "$PROXY_FILE" .proxy.conf)"
    CONTAINER_NAME="proxy_${MODEL_NAME}"

    [[ -n "${docker_image:-}" ]] && CONTAINER_IMAGE="$docker_image"

    _info "Proxy conf  : $(basename "$PROXY_FILE")"
    _info "HTTP        : ${proxy_host}:${proxy_port}  ZMQ=:${proxy_zmq_port}"
    _info "Container   : $CONTAINER_NAME"
    echo ""

    $DOCKER_CMD image inspect "$CONTAINER_IMAGE" &>/dev/null || {
        _err "Docker image not found: $CONTAINER_IMAGE"; exit 1; }

    if $DOCKER_CMD inspect "$CONTAINER_NAME" &>/dev/null; then
        _warn "Removing existing container: $CONTAINER_NAME"
        $DOCKER_CMD rm -f "$CONTAINER_NAME" >/dev/null
    fi

    mkdir -p "$LOG_DIR"
    $DOCKER_CMD run -d \
        --name "$CONTAINER_NAME" \
        --ulimit nofile=1048576 \
        -v /home:/home \
        -v /data:/data \
        --net host \
        "$CONTAINER_IMAGE" \
        sleep infinity >/dev/null

    _ok "Container started."

    INNER_SCRIPT="${SCRIPT_DIR}/proxy_server.sh"
    RUN_SCRIPT_NAME="run_proxy_${MODEL_NAME}.sh"
    RUN_SCRIPT_PATH="${LOG_DIR}/${RUN_SCRIPT_NAME}"

    cat > "${RUN_SCRIPT_PATH}" <<'RUNSCRIPT'
#!/usr/bin/env bash
_ld=$(tr '\0' '\n' < /proc/1/environ | sed -n 's/^LD_LIBRARY_PATH=//p' | head -1)
[[ -n "$_ld" ]] && export LD_LIBRARY_PATH="$_ld"
unset _ld
exec bash "__INNER_SCRIPT__" "__PROXY_FILE__"
RUNSCRIPT
    sed -i "s|__INNER_SCRIPT__|${INNER_SCRIPT}|g; s|__PROXY_FILE__|${PROXY_FILE}|g" \
        "${RUN_SCRIPT_PATH}"
    chmod +x "${RUN_SCRIPT_PATH}"
    _ok "Run script  : ${RUN_SCRIPT_PATH}"
    echo ""

    if $RUN_MODE; then
        LOG_FILE="${LOG_DIR}/proxy_${MODEL_NAME}.log"
        _info "Starting proxy server (logs → ${LOG_FILE})..."
        $DOCKER_CMD exec -d "$CONTAINER_NAME" \
            bash -c "bash '${RUN_SCRIPT_PATH}' > '${LOG_FILE}' 2>&1"
        _ok "Proxy server launched."
        echo "  tail -f ${LOG_FILE}"
        echo "  ${DOCKER_CMD} stop ${CONTAINER_NAME}"
    else
        _env_tmp=$(mktemp /tmp/vllm_docker_env_XXXXXX.sh)
        cat > "$_env_tmp" <<ENVSCRIPT
_ld=\$(tr '\0' '\n' < /proc/1/environ | sed -n 's/^LD_LIBRARY_PATH=//p' | head -1)
[[ -n "\$_ld" ]] && export LD_LIBRARY_PATH="\$_ld"
unset _ld
cd '${LOG_DIR}'
echo ""
echo "  Docker shell — Proxy server"
echo "  Start server with:  bash ${RUN_SCRIPT_NAME}"
echo ""
ENVSCRIPT
        $DOCKER_CMD exec -i "$CONTAINER_NAME" tee /tmp/.biren_env.sh < "$_env_tmp" >/dev/null
        rm -f "$_env_tmp"
        _info "Entering interactive shell..."
        $DOCKER_CMD exec -it "$CONTAINER_NAME" bash -c "source /tmp/.biren_env.sh && exec bash -i"
    fi
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# NORMAL / PD MODE — common config loading and GPU selection
# ══════════════════════════════════════════════════════════════════════════════

# ── Resolve main config ────────────────────────────────────────────────────────
CONFIG_FILE="$(resolve_config "$CONFIG_ARG" "${SCRIPT_DIR}/configs")"
[[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]] && {
    _err "Config not found: $CONFIG_ARG"; usage; }

# ── Load config with defaults ─────────────────────────────────────────────────
served_model_name=""
task=""
dtype="auto"
gpu_memory_utilization=0.8
enable_chunked_prefill=false
enforce_eager=false
distributed_executor_backend=""
compilation_config=""
docker_image=""
extra_env=""
extra_vllm_args=""
# PD-mode extras
dp_size=1
http_ip="0.0.0.0"
max_num_batched_tokens=""
succl_socket_ifname=""

# shellcheck source=/dev/null
source "$CONFIG_FILE"

[[ -n "${docker_image:-}" ]] && CONTAINER_IMAGE="$docker_image"

# ── Validate required params ──────────────────────────────────────────────────
_missing=()
[[ -z "${model_weights:-}" ]]         && _missing+=(model_weights)
[[ -z "${port:-}" ]]                   && _missing+=(port)
[[ -z "${tensor_parallel_size:-}" ]]   && _missing+=(tensor_parallel_size)
[[ -z "${pipeline_parallel_size:-}" ]] && _missing+=(pipeline_parallel_size)
[[ -z "${max_model_len:-}" ]]          && _missing+=(max_model_len)
[[ -z "${max_num_seqs:-}" ]]           && _missing+=(max_num_seqs)
if [[ "$MODE" == "pd" ]]; then
    [[ -z "${max_num_batched_tokens:-}" ]] && _missing+=(max_num_batched_tokens)
fi
[[ ${#_missing[@]} -gt 0 ]] && {
    _err "Required params not set in $(basename "$CONFIG_FILE"): ${_missing[*]}"; exit 1; }

# ── PD mode: resolve proxy conf ───────────────────────────────────────────────
PROXY_FILE=""
if [[ "$MODE" == "pd" ]]; then
    [[ -z "$PROXY_CONF_ARG" ]] && {
        _err "PD mode requires a proxy conf file as the second argument."
        _err "Example: $0 --run configs/minimax-m2.5.p.conf proxy_conf/minimax-m2.5.proxy.conf"
        exit 1; }
    PROXY_FILE="$(resolve_config "$PROXY_CONF_ARG" \
        "${SCRIPT_DIR}/proxy_conf" "${SCRIPT_DIR}/configs")"
    [[ -z "$PROXY_FILE" || ! -f "$PROXY_FILE" ]] && {
        _err "Proxy conf not found: $PROXY_CONF_ARG"; exit 1; }
fi

_info "Config      : $(basename "$CONFIG_FILE")  [mode=$( $RUN_MODE && echo --run || echo interactive)]"
_info "Model key   : $model_weights  |  port=$port  |  tp=$tensor_parallel_size  pp=$pipeline_parallel_size"
[[ -n "$PROXY_FILE" ]] && _info "Proxy conf  : $(basename "$PROXY_FILE")"

# ── GPU selection ──────────────────────────────────────────────────────────────
gpu_needed=$((tensor_parallel_size * pipeline_parallel_size))
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
mkdir -p "$LOG_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
CONTAINER_NAME="vllm_${model_weights}"

if $DOCKER_CMD inspect "$CONTAINER_NAME" &>/dev/null; then
    _warn "Removing existing container: $CONTAINER_NAME"
    $DOCKER_CMD rm -f "$CONTAINER_NAME" >/dev/null
fi

_info "Container   : $CONTAINER_NAME"
_info "Log dir     : $LOG_DIR"
echo ""

$DOCKER_CMD image inspect "$CONTAINER_IMAGE" &>/dev/null || {
    _err "Docker image not found: $CONTAINER_IMAGE"; exit 1; }

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

# Apply nan_to_num(0) patch to the D-side KV connector inside the fresh container.
# Biren GPU profiling warmup leaves NaN in KV block padding slots; those NaN
# values propagate through attention on the Decode node and corrupt generation.
# The patch zeroes them out immediately after supa_kvcache_pcp_recv receives the
# block, before injection into the KV cache.  Idempotent: skips if already present.
_connector_py="/usr/local/lib/python3.10/dist-packages/vllm_br/distributed/kv_transfer/kv_connector/v1/p2p/hetero_succl_connector.py"
$DOCKER_CMD exec "$CONTAINER_NAME" python3 - "$_connector_py" <<'PYPATCH'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
if not path.exists():
    print("[SKIP]  Connector patch : file not found, skipping")
    raise SystemExit(0)
src = path.read_text()
target = "            torch_br.supa_kvcache_pcp_recv(layer, kv_cache, block_ids_supa)"
patch  = "            kv_cache = [kv.nan_to_num(nan=0.0) for kv in kv_cache]"
if target in src and "nan_to_num" not in src:
    path.write_text(src.replace(target, patch + "\n" + target))
    pathlib.Path(path.parent / "__pycache__" / (path.stem + ".cpython-310.pyc")).unlink(missing_ok=True)
    print("[INFO]  Connector patch : nan_to_num(0) applied to hetero_succl_connector.py")
elif "nan_to_num" in src:
    print("[INFO]  Connector patch : nan_to_num already present, skipped")
else:
    print("[WARN]  Connector patch : target line not found — connector may have changed")
PYPATCH
echo ""

# ── Write server run script ───────────────────────────────────────────────────
if [[ "$MODE" == "pd" ]]; then
    INNER_SCRIPT="${SCRIPT_DIR}/vllm_server_pd.sh"
    RUN_SCRIPT_NAME="run_vllm_${model_weights}_$(basename "$CONFIG_FILE" .conf)_server.sh"
else
    INNER_SCRIPT="${SCRIPT_DIR}/vllm_server.sh"
    RUN_SCRIPT_NAME="run_vllm_${model_weights}_server.sh"
fi
RUN_SCRIPT_PATH="${LOG_DIR}/${RUN_SCRIPT_NAME}"

if [[ "$MODE" == "pd" ]]; then
    cat > "${RUN_SCRIPT_PATH}" <<'RUNSCRIPT'
#!/usr/bin/env bash
_ld=$(tr '\0' '\n' < /proc/1/environ | sed -n 's/^LD_LIBRARY_PATH=//p' | head -1)
[[ -n "$_ld" ]] && export LD_LIBRARY_PATH="$_ld"
unset _ld
exec bash "__INNER_SCRIPT__" "__CONFIG_FILE__" "__PROXY_FILE__"
RUNSCRIPT
    sed -i "s|__INNER_SCRIPT__|${INNER_SCRIPT}|g; \
            s|__CONFIG_FILE__|${CONFIG_FILE}|g; \
            s|__PROXY_FILE__|${PROXY_FILE}|g" "${RUN_SCRIPT_PATH}"
else
    cat > "${RUN_SCRIPT_PATH}" <<'RUNSCRIPT'
#!/usr/bin/env bash
_ld=$(tr '\0' '\n' < /proc/1/environ | sed -n 's/^LD_LIBRARY_PATH=//p' | head -1)
[[ -n "$_ld" ]] && export LD_LIBRARY_PATH="$_ld"
unset _ld
exec bash "__INNER_SCRIPT__" "__CONFIG_FILE__"
RUNSCRIPT
    sed -i "s|__INNER_SCRIPT__|${INNER_SCRIPT}|g; \
            s|__CONFIG_FILE__|${CONFIG_FILE}|g" "${RUN_SCRIPT_PATH}"
fi
chmod +x "${RUN_SCRIPT_PATH}"

_ok "Run script  : ${RUN_SCRIPT_PATH}"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
# --run mode: exec server directly
# ══════════════════════════════════════════════════════════════════════════════
if $RUN_MODE; then

    LOG_FILE="${LOG_DIR}/vllm_${model_weights}_${TIMESTAMP}.log"
    _info "Starting vLLM server (logs → ${LOG_FILE})..."
    $DOCKER_CMD exec -d "$CONTAINER_NAME" \
        bash -c "bash '${RUN_SCRIPT_PATH}' > '${LOG_FILE}' 2>&1"

    _ok "Server process launched inside container."
    echo "  tail -f ${LOG_FILE}"
    echo ""

    MODEL_API="${served_model_name:-${model_weights}}"
    echo "── Test commands (run after server is ready) ─────────────────"
    echo "  bash ${SCRIPT_DIR}/tests/test_healthcheck.sh ${port}"
    echo ""
    if [[ "$task" == "embed" ]]; then
        echo "── Embedding test ────────────────────────────────────────────"
        echo "curl -s http://127.0.0.1:${port}/v1/embeddings \\"
        echo "  -H 'Content-Type: application/json' \\"
        echo "  -d '{\"model\": \"${MODEL_API}\", \"input\": \"Hello, world!\"}' \\"
        echo "  | python3 -m json.tool"
    else
        echo "── Chat completion test ──────────────────────────────────────"
        echo "curl -s http://127.0.0.1:${port}/v1/chat/completions \\"
        echo "  -H 'Content-Type: application/json' \\"
        echo "  -d '{\"model\": \"${MODEL_API}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}], \"max_tokens\": 64}' \\"
        echo "  | python3 -m json.tool"
    fi
    echo ""
    echo "── Container management ──────────────────────────────────────"
    echo "  ${DOCKER_CMD} exec -it ${CONTAINER_NAME} bash"
    echo "  ${DOCKER_CMD} stop ${CONTAINER_NAME}"
    echo "  ${DOCKER_CMD} rm   ${CONTAINER_NAME}"

# ══════════════════════════════════════════════════════════════════════════════
# Default (interactive): enter shell at LOG_DIR
# ══════════════════════════════════════════════════════════════════════════════
else

    _env_tmp=$(mktemp /tmp/vllm_docker_env_XXXXXX.sh)
    cat > "$_env_tmp" <<ENVSCRIPT
_ld=\$(tr '\0' '\n' < /proc/1/environ | sed -n 's/^LD_LIBRARY_PATH=//p' | head -1)
[[ -n "\$_ld" ]] && export LD_LIBRARY_PATH="\$_ld"
unset _ld
cd '${LOG_DIR}'
echo ""
echo "  Docker shell — vLLM interactive session"
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
    echo "── Container management ──────────────────────────────────────"
    echo "  ${DOCKER_CMD} stop ${CONTAINER_NAME}"
    echo "  ${DOCKER_CMD} rm   ${CONTAINER_NAME}"
    echo ""
    _info "Entering interactive shell inside container at ${LOG_DIR} ..."
    _info "(Type 'exit' or Ctrl-D to leave; container keeps running)"
    echo ""

    $DOCKER_CMD exec -it "$CONTAINER_NAME" \
        bash -c "source /tmp/.biren_env.sh && exec bash -i"

fi
