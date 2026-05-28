#!/usr/bin/env bash
# Runs INSIDE the BirenTech container to launch hetero_proxy_server.py.
#
# Usage:
#   bash proxy_server.sh <proxy_conf_file>
#
# proxy_conf_file fields: proxy_host, proxy_port, proxy_zmq_port

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

# quart is not pre-installed in the container image; install if missing
python3 -c "from quart import Quart" 2>/dev/null || {
    _info "Installing quart (not in container image)..."
    pip3 install quart --quiet --root-user-action=ignore
}

usage() {
    echo ""
    echo "Usage: $0 <proxy_conf_file>"
    echo ""
    echo "Available proxy confs:"
    for f in "${SCRIPT_DIR}/proxy_conf/"*.proxy.conf; do
        [[ -f "$f" ]] && echo "  $(basename "$f")"
    done
    echo ""
    exit 1
}

[[ $# -lt 1 ]] && { _err "A proxy conf file is required."; usage; }

PROXY_ARG="$1"
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

# Defaults
proxy_host="0.0.0.0"
proxy_port=35111
proxy_zmq_port=34367

# shellcheck source=/dev/null
source "$PROXY_FILE"

_info "Proxy conf    : $(basename "$PROXY_FILE")"
_info "HTTP listen   : ${proxy_host}:${proxy_port}"
_info "ZMQ discovery : ${proxy_host}:${proxy_zmq_port}"
echo ""

PROXY_PY="${SCRIPT_DIR}/hetero_proxy_server.py"
[[ ! -f "$PROXY_PY" ]] && { _err "hetero_proxy_server.py not found: $PROXY_PY"; exit 1; }

_ok "Starting proxy server..."
echo ""
exec python3 "$PROXY_PY" \
    --host "${proxy_host}" \
    --port "${proxy_port}" \
    --zmq-port "${proxy_zmq_port}"
