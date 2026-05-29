#!/bin/bash
# Real-backend load balancer test for MiniMax-M2.5-INT8.
#
# Starts the LB (vllm-lb:latest) pointing at the two real vLLM servers
# on 172.25.198.36:20027 and 172.25.198.37:20027, then sends multiple
# requests and verifies round-robin distribution via the X-LB-Backend header.
#
# Usage:  ./test_real_backends.sh [--port PORT] [--requests N]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LB_DIR="$(dirname "$SCRIPT_DIR")"

LB_PORT=20080
N_REQUESTS=6
MODEL="/data/models/MiniMax/MiniMax-M2.5-INT8"
BACKEND_A="172.25.198.36:20027"
BACKEND_B="172.25.198.37:20027"
CONFIG="$LB_DIR/configs/minimax-m2.5-lb.yaml"
CONTAINER="lb-real-test"
IMAGE="vllm-lb:latest"

while [[ $# -gt 0 ]]; do
    case $1 in
        --port)     LB_PORT="$2";     shift 2 ;;
        --requests) N_REQUESTS="$2";  shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# ─── colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
pass()    { echo -e "${GREEN}[PASS]${RESET} $*"; }
fail()    { echo -e "${RED}[FAIL]${RESET} $*"; FAILURES=$((FAILURES+1)); }
info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
section() { echo -e "\n${BOLD}${YELLOW}=== $* ===${RESET}"; }
FAILURES=0

cleanup() {
    info "Stopping container $CONTAINER..."
    docker stop "$CONTAINER" 2>/dev/null && docker rm "$CONTAINER" 2>/dev/null || true
}
trap cleanup EXIT

# ─── 1. Verify both backends are reachable ───────────────────────────────────
section "Pre-flight: checking backend connectivity"

for backend in "$BACKEND_A" "$BACKEND_B"; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${backend}/health" 2>/dev/null || true)
    # vllm may not have /health; fall back to /v1/models
    if [[ "$code" != "200" ]]; then
        code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "http://${backend}/v1/models" 2>/dev/null || true)
    fi
    if [[ "$code" == "200" ]]; then
        pass "  $backend reachable (HTTP $code)"
    else
        fail "  $backend NOT reachable (HTTP $code) — aborting"
        exit 1
    fi
done

# ─── 2. Start load balancer ──────────────────────────────────────────────────
section "Starting load balancer (port $LB_PORT)"

docker stop "$CONTAINER" 2>/dev/null || true
docker rm  "$CONTAINER" 2>/dev/null || true

docker run -d \
    --name "$CONTAINER" \
    --network host \
    -v "$(dirname "$CONFIG"):/app/config:ro" \
    "$IMAGE" \
    --host 0.0.0.0 \
    --port "$LB_PORT" \
    --config "/app/config/$(basename "$CONFIG")" \
    --timeout 120

info "Waiting for LB to be ready..."
for i in $(seq 1 30); do
    curl -sf "http://127.0.0.1:${LB_PORT}/health" > /dev/null 2>&1 && break
    [[ "$i" -eq 30 ]] && { fail "LB timed out"; docker logs "$CONTAINER" | tail -20; exit 1; }
    sleep 1
done
pass "LB ready on :$LB_PORT"

info "LB registered models:"
curl -s "http://127.0.0.1:${LB_PORT}/v1/models" \
    | python3 -c "import sys,json; [print(f'    {m[\"id\"]}  ({m[\"backends\"]} backend(s))') for m in json.load(sys.stdin)['data']]"

# ─── Helper ──────────────────────────────────────────────────────────────────
# Send a request through the LB; print the X-LB-Backend header + response content.
lb_chat() {
    local prompt="$1"
    local stream="${2:-false}"
    curl -sS --max-time 60 \
        -D - \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"${MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"${prompt}\"}], \"max_tokens\": 32, \"stream\": ${stream}}" \
        "http://127.0.0.1:${LB_PORT}/v1/chat/completions"
}

# ─── 3. Round-robin distribution test ────────────────────────────────────────
section "Round-robin test: $N_REQUESTS non-streaming requests"

declare -A backend_counts
backend_counts["$BACKEND_A"]=0
backend_counts["$BACKEND_B"]=0
ROUTE_LOG=()

for i in $(seq 1 "$N_REQUESTS"); do
    raw=$(lb_chat "Reply with one word only: word${i}")
    backend=$(echo "$raw" | grep -i "^x-lb-backend:" | tr -d '\r' | awk '{print $2}' | sed 's|http://||')
    content=$(echo "$raw" | tail -1 | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d['choices'][0]['message']['content'].strip()[:60])
except Exception as e:
    print(f'PARSE_ERR: {e}')
" 2>/dev/null)

    ROUTE_LOG+=("$backend")
    backend_counts["$backend"]=$(( ${backend_counts["$backend"]:-0} + 1 ))

    if [[ -n "$backend" ]]; then
        pass "  Req $i → $backend  |  \"$content\""
    else
        fail "  Req $i → (no X-LB-Backend header)"
    fi
done

echo ""
info "Distribution:"
info "  $BACKEND_A : ${backend_counts[$BACKEND_A]} request(s)"
info "  $BACKEND_B : ${backend_counts[$BACKEND_B]} request(s)"

# Verify both backends got traffic (for N>=2)
if [[ "${backend_counts[$BACKEND_A]}" -ge 1 && "${backend_counts[$BACKEND_B]}" -ge 1 ]]; then
    pass "Both backends received traffic"
else
    fail "Load not distributed — check LB or backends"
fi

# Verify roughly even split (diff <= ceil(N/2))
diff=$(( backend_counts[$BACKEND_A] - backend_counts[$BACKEND_B] ))
diff=${diff#-}
threshold=$(( (N_REQUESTS + 1) / 2 ))
if [[ "$diff" -le 1 ]]; then
    pass "Distribution is even (diff=$diff)"
else
    fail "Skewed distribution (diff=$diff > 1)"
fi

# ─── 4. Strict round-robin order check ───────────────────────────────────────
section "Strict round-robin order verification"

FIRST="${ROUTE_LOG[0]}"
SECOND="${ROUTE_LOG[1]}"
ORDER_OK=true

if [[ "$FIRST" == "$SECOND" ]]; then
    fail "First two requests went to the same backend ($FIRST) — not alternating"
    ORDER_OK=false
else
    for i in $(seq 0 $(( ${#ROUTE_LOG[@]} - 1 )) ); do
        expected_mod=$(( i % 2 ))
        if [[ "$expected_mod" -eq 0 ]]; then
            expected="$FIRST"
        else
            expected="$SECOND"
        fi
        actual="${ROUTE_LOG[$i]}"
        if [[ "$actual" != "$expected" ]]; then
            fail "  Req $((i+1)): expected $expected, got $actual"
            ORDER_OK=false
        fi
    done
fi

$ORDER_OK && pass "Requests alternate A→B→A→B in strict round-robin"

# ─── 5. Streaming test ───────────────────────────────────────────────────────
section "Streaming (SSE) test"

stream_raw=$(lb_chat "Count to 3" "true")
stream_backend=$(echo "$stream_raw" | grep -i "^x-lb-backend:" | tr -d '\r' | awk '{print $2}' | sed 's|http://||')
chunk_count=$(echo "$stream_raw" | grep -c '^data:' || true)
has_done=$(echo "$stream_raw" | grep -c 'data: \[DONE\]' || true)

info "  Backend : $stream_backend"
info "  Chunks  : $chunk_count"
info "  [DONE]  : $has_done"

# Print first few data lines
echo "$stream_raw" | grep '^data:' | head -5 | while read -r line; do
    echo "    $line"
done

if [[ "$chunk_count" -ge 2 && "$has_done" -ge 1 ]]; then
    pass "SSE streaming works ($chunk_count chunks, [DONE] received)"
else
    fail "SSE streaming issue (chunks=$chunk_count done=$has_done)"
fi

# ─── 6. Unknown model → 404 ──────────────────────────────────────────────────
section "Error handling: unknown model"

status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -H "Content-Type: application/json" \
    -d '{"model":"no-such-model","messages":[{"role":"user","content":"hi"}]}' \
    "http://127.0.0.1:${LB_PORT}/v1/chat/completions")
[[ "$status" == "404" ]] && pass "Unknown model → HTTP 404 ✓" || fail "Expected 404, got $status"

# ─── Summary ─────────────────────────────────────────────────────────────────
section "Summary"
if [[ "$FAILURES" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All tests passed!${RESET}"
    echo ""
    echo "  LB endpoint : http://127.0.0.1:${LB_PORT}/v1/chat/completions"
    echo "  Model       : $MODEL"
    echo "  Backends    : $BACKEND_A  $BACKEND_B"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed.${RESET}"
    info "Container logs:"
    docker logs "$CONTAINER" 2>&1 | tail -20
    exit 1
fi
