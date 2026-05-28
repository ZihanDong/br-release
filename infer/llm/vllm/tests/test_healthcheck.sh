#!/usr/bin/env bash
# Poll a vLLM server's /health endpoint until it responds or times out.
#
# Usage:
#   bash tests/test_healthcheck.sh <port> [host] [timeout_sec]
#
#   port         HTTP port to check (required)
#   host         Host address (default: 127.0.0.1)
#   timeout_sec  Max seconds to wait (default: 600)
#
# For PD proxy mode, poll the proxy port:
#   bash tests/test_healthcheck.sh 35111 172.25.198.36

set -euo pipefail

PORT="${1:-}"
HOST="${2:-127.0.0.1}"
TIMEOUT="${3:-600}"

_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

[[ -z "$PORT" ]] && {
    echo "Usage: $0 <port> [host] [timeout_sec]"
    exit 1
}

URL="http://${HOST}:${PORT}/health"
_info "Polling $URL  (timeout=${TIMEOUT}s)"

start=$(date +%s)
attempt=0
while true; do
    attempt=$(( attempt + 1 ))
    if curl -sf "$URL" &>/dev/null; then
        elapsed=$(( $(date +%s) - start ))
        _ok "Server ready after ${elapsed}s  (${URL})"
        echo ""
        echo "── Quick smoke test ──────────────────────────────────────────"
        echo "curl -s http://${HOST}:${PORT}/v1/models | python3 -m json.tool"
        echo ""
        echo "curl -s http://${HOST}:${PORT}/v1/chat/completions \\"
        echo "  -H 'Content-Type: application/json' \\"
        echo "  -d '{\"model\": \"Minimax-M2.5-INT8\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}], \"max_tokens\": 64}' \\"
        echo "  | python3 -m json.tool"
        exit 0
    fi
    now=$(date +%s)
    elapsed=$(( now - start ))
    if (( elapsed >= TIMEOUT )); then
        _warn "Server did not respond within ${TIMEOUT}s. It may still be loading."
        _warn "Check logs or re-run: bash $0 $PORT $HOST $TIMEOUT"
        exit 1
    fi
    printf "  [%3ds] waiting...\r" "$elapsed"
    sleep 5
done
