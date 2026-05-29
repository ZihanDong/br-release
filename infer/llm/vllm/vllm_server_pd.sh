#!/usr/bin/env bash
# Runs INSIDE the BirenTech container to launch a vLLM PD-disaggregated server.
#
# The image ENTRYPOINT (biren_entrypoint.sh) must have already run to set
# LD_LIBRARY_PATH before this script is called.
#
# Usage:
#   bash vllm_server_pd.sh <pd_config_file> <proxy_conf_file>
#
# pd_config_file suffix determines the KV role:
#   *.p.conf  →  kv_producer (Prefill node)
#   *.d.conf  →  kv_consumer (Decode node)
#
# proxy_conf_file (*.proxy.conf) provides: proxy_host, proxy_port, proxy_zmq_port

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REGISTRY_SH="${SCRIPT_DIR}/../model_registry.sh"

_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

usage() {
    echo ""
    echo "Usage: $0 <pd_config_file> <proxy_conf_file>"
    echo ""
    echo "  pd_config_file  : *.p.conf (Prefill) or *.d.conf (Decode)"
    echo "  proxy_conf_file : *.proxy.conf — provides proxy_host/port/zmq_port"
    echo ""
    echo "Available PD configs:"
    for f in "${SCRIPT_DIR}/configs/"*.p.conf "${SCRIPT_DIR}/configs/"*.d.conf; do
        [[ -f "$f" ]] && echo "  $(basename "$f")"
    done
    echo ""
    exit 1
}

[[ $# -lt 2 ]] && { _err "Two config files required."; usage; }

# ── Resolve PD config ─────────────────────────────────────────────────────────
CONFIG_ARG="$1"
CONFIG_FILE=""

if [[ "$CONFIG_ARG" == /* ]]; then
    CONFIG_FILE="$CONFIG_ARG"
elif [[ -f "${SCRIPT_DIR}/configs/${CONFIG_ARG}" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/configs/${CONFIG_ARG}"
elif [[ -f "${SCRIPT_DIR}/${CONFIG_ARG}" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_ARG}"
elif [[ -f "$CONFIG_ARG" ]]; then
    CONFIG_FILE="$CONFIG_ARG"
fi

[[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]] && {
    _err "PD config not found: $CONFIG_ARG"; usage; }

# ── Detect role from suffix ───────────────────────────────────────────────────
CONFIG_BASENAME="$(basename "$CONFIG_FILE")"
if [[ "$CONFIG_BASENAME" == *.p.conf ]]; then
    KV_ROLE="kv_producer"
    NODE_LABEL="Prefill"
elif [[ "$CONFIG_BASENAME" == *.d.conf ]]; then
    KV_ROLE="kv_consumer"
    NODE_LABEL="Decode"
else
    _err "Config must end with .p.conf or .d.conf: $CONFIG_BASENAME"; exit 1
fi

# ── Resolve proxy config ──────────────────────────────────────────────────────
PROXY_ARG="$2"
PROXY_FILE=""

if [[ "$PROXY_ARG" == /* ]]; then
    PROXY_FILE="$PROXY_ARG"
elif [[ -f "${SCRIPT_DIR}/proxy_conf/${PROXY_ARG}" ]]; then
    PROXY_FILE="${SCRIPT_DIR}/proxy_conf/${PROXY_ARG}"
elif [[ -f "${SCRIPT_DIR}/${PROXY_ARG}" ]]; then
    PROXY_FILE="${SCRIPT_DIR}/${PROXY_ARG}"
elif [[ -f "$PROXY_ARG" ]]; then
    PROXY_FILE="$PROXY_ARG"
fi

[[ -z "$PROXY_FILE" || ! -f "$PROXY_FILE" ]] && {
    _err "Proxy conf not found: $PROXY_ARG"; usage; }

# ── Defaults (optional params) ────────────────────────────────────────────────
served_model_name=""
dtype="bfloat16"
dp_size=1
http_ip="0.0.0.0"
gpu_memory_utilization=0.75
enable_chunked_prefill=false
enforce_eager=false
distributed_executor_backend="mp"
compilation_config=""
succl_socket_ifname=""
extra_env=""
extra_vllm_args=""

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Proxy defaults
proxy_host=""
proxy_port=35111
proxy_zmq_port=34367

# shellcheck source=/dev/null
source "$PROXY_FILE"

# ── Validate required params ──────────────────────────────────────────────────
_missing=()
[[ -z "${model_weights:-}" ]]           && _missing+=(model_weights)
[[ -z "${port:-}" ]]                     && _missing+=(port)
[[ -z "${tensor_parallel_size:-}" ]]     && _missing+=(tensor_parallel_size)
[[ -z "${pipeline_parallel_size:-}" ]]   && _missing+=(pipeline_parallel_size)
[[ -z "${max_model_len:-}" ]]            && _missing+=(max_model_len)
[[ -z "${max_num_seqs:-}" ]]             && _missing+=(max_num_seqs)
[[ -z "${max_num_batched_tokens:-}" ]]   && _missing+=(max_num_batched_tokens)
[[ -z "${proxy_host:-}" ]]               && _missing+=(proxy_host)
[[ ${#_missing[@]} -gt 0 ]] && {
    _err "Required params not set: ${_missing[*]}"; exit 1; }

_info "Role        : ${NODE_LABEL} (${KV_ROLE})"
_info "Config      : $(basename "$CONFIG_FILE")  |  proxy=$(basename "$PROXY_FILE")"
_info "Model key   : $model_weights  |  port=$port  |  tp=$tensor_parallel_size  pp=$pipeline_parallel_size"
_info "http_ip     : $http_ip  |  proxy=${proxy_host}:${proxy_port}  zmq=:${proxy_zmq_port}"

# ── Registry lookup ───────────────────────────────────────────────────────────
[[ ! -f "$_REGISTRY_SH" ]] && { _err "model_registry.sh not found: $_REGISTRY_SH"; exit 1; }
# shellcheck source=../model_registry.sh
source "$_REGISTRY_SH"
parse_model "$model_weights" || exit 1
MODEL_LOCAL_PATH="$MODEL_PATH"

[[ ! -d "${MODEL_LOCAL_PATH}" ]] && {
    _err "Model weights not found: ${MODEL_LOCAL_PATH}"; exit 1; }
_ok "Weights     : ${MODEL_LOCAL_PATH}"

# ── Set fixed env vars ────────────────────────────────────────────────────────
export VLLM_USE_V1=1
export VLLM_WORKER_MULTIPROC_METHOD=spawn
export VLLM_BR_WEIGHT_TYPE=NUMA
export BRTB_LOG_LEVEL=Warning
export BRTB_LOG_DIR=/root/vllm_logs
[[ -n "${succl_socket_ifname:-}" ]] && export SUCCL_SOCKET_IFNAME="${succl_socket_ifname}"

if [[ -n "${extra_env:-}" ]]; then
    for _kv in ${extra_env}; do
        export "$_kv"
    done
fi

ulimit -n 65535 2>/dev/null || true
mkdir -p /root/vllm_logs 2>/dev/null || true

# Patch envs.py to point VLLM_SCCL_SO_PATH at the real SDK path rather than
# the base/latest alias (which may not exist).  This avoids creating a symlink.
_envs_py="/usr/local/lib/python3.10/dist-packages/vllm_br/envs.py"
_sdk_dir=$(find /usr/local/birensupa/sdk -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V | tail -1)
if [[ -n "$_sdk_dir" ]]; then
    _succl_so="${_sdk_dir}/succl/lib/x86_64-linux-gnu/libsuccl.so"
    if [[ -f "$_succl_so" && -f "$_envs_py" ]]; then
        sed -i "s|/usr/local/birensupa/base/latest/succl/lib/x86_64-linux-gnu/libsuccl.so|${_succl_so}|g" \
            "$_envs_py"
        rm -f "$(dirname "$_envs_py")/__pycache__/envs.cpython-310.pyc" 2>/dev/null || true
        _info "SUCCL path  : envs.py patched → ${_succl_so}"
    fi
fi
unset _envs_py _sdk_dir _succl_so

# ── Build --kv-transfer-config JSON ──────────────────────────────────────────
kv_port=$(( RANDOM % 1001 + 4000 ))
_info "KV port     : ${kv_port}  (random, for SUCCL handshake)"

KV_TRANSFER_CONFIG="{\"kv_connector\":\"HeteroSucclConnector\",\"kv_role\":\"${KV_ROLE}\",\"kv_buffer_size\":\"5e9\",\"kv_port\":\"${kv_port}\",\"kv_connector_extra_config\":{\"dp_size\":\"${dp_size}\",\"proxy_ip\":\"${proxy_host}\",\"proxy_port\":\"${proxy_zmq_port}\",\"http_ip\":\"${http_ip}\",\"http_port\":\"${port}\"}}"

# ── Build vllm args ───────────────────────────────────────────────────────────
vllm_args=(
    python3 -m vllm.entrypoints.openai.api_server
    --host 0.0.0.0
    --port "${port}"
    --model "${MODEL_LOCAL_PATH}"
)
[[ -n "$served_model_name" ]] && vllm_args+=(--served-model-name "${served_model_name}")
vllm_args+=(
    --trust-remote-code
    --dtype "${dtype}"
    --kv-cache-dtype auto
    --max-model-len "${max_model_len}"
    --max-num-seqs "${max_num_seqs}"
    --max-num-batched-tokens "${max_num_batched_tokens}"
    --tensor-parallel-size "${tensor_parallel_size}"
    --pipeline-parallel-size "${pipeline_parallel_size}"
    --data-parallel-size "${dp_size}"
    --gpu-memory-utilization "${gpu_memory_utilization}"
    --distributed-executor-backend "${distributed_executor_backend}"
    --seed 1024
)
[[ "$enforce_eager" == "true" ]]          && vllm_args+=(--enforce-eager)
[[ "$enable_chunked_prefill" == "true" ]] && vllm_args+=(--enable-chunked-prefill)
if [[ -n "$compilation_config" ]]; then
    vllm_args+=(--compilation-config "${compilation_config}")
fi
if [[ -n "${extra_vllm_args:-}" ]]; then
    read -ra _extra_arr <<< "${extra_vllm_args}"
    vllm_args+=("${_extra_arr[@]}")
fi
vllm_args+=(--kv-transfer-config "${KV_TRANSFER_CONFIG}")

# ── Launch ────────────────────────────────────────────────────────────────────
_ok "Launching   : ${NODE_LABEL} node  role=${KV_ROLE}  port=${port}"
echo ""

exec "${vllm_args[@]}"
