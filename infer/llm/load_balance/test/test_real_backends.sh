#!/bin/bash
# Load balancer functional test — request-side only.
#
# Assumes the LB is already running (started via start_lb.sh).
# Sends non-streaming and streaming requests, then verifies:
#   - round-robin distribution via X-LB-Backend header
#   - strict A→B→A→B alternation
#   - SSE streaming end-to-end
#   - HTTP 404 for unknown model
#
# Usage:  ./test_real_backends.sh [--lb-url URL] [--requests N]

set -euo pipefail

LB_URL="http://127.0.0.1:20080"
N_REQUESTS=6
MODEL="/data/models/MiniMax/MiniMax-M2.5-INT8"
BACKEND_A="172.25.198.36:20027"
BACKEND_B="172.25.198.37:20027"

while [[ $# -gt 0 ]]; do
    case $1 in
        --lb-url)   LB_URL="$2";    shift 2 ;;
        --requests) N_REQUESTS="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ─── colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
pass()    { echo -e "${GREEN}[PASS]${RESET} $*"; }
fail()    { echo -e "${RED}[FAIL]${RESET} $*"; FAILURES=$((FAILURES+1)); }
info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
section() { echo -e "\n${BOLD}${YELLOW}=== $* ===${RESET}"; }
FAILURES=0

# ─── 0. Verify LB is up ──────────────────────────────────────────────────────
section "Pre-flight: LB connectivity"

code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "${LB_URL}/health")
if [[ "$code" == "200" ]]; then
    pass "LB is reachable at $LB_URL"
else
    fail "LB not reachable at $LB_URL (HTTP $code) — start it first with start_lb.sh"
    exit 1
fi

info "Registered models:"
curl -s "${LB_URL}/v1/models" \
    | python3 -c "import sys,json; [print(f'    {m[\"id\"]}  ({m[\"backends\"]} backend(s))') for m in json.load(sys.stdin)['data']]"

# ─── Helper ──────────────────────────────────────────────────────────────────
# Send one chat request; returns full HTTP response including headers.
lb_chat() {
    local prompt="$1"
    local stream="${2:-false}"
    curl -sS --max-time 60 \
        -D - \
        -H "Content-Type: application/json" \
        -d "{\"model\": \"${MODEL}\", \"messages\": [{\"role\": \"user\", \"content\": \"${prompt}\"}], \"max_tokens\": 32, \"stream\": ${stream}}" \
        "${LB_URL}/v1/chat/completions"
}

# ─── 1. Round-robin distribution test ────────────────────────────────────────
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

if [[ "${backend_counts[$BACKEND_A]}" -ge 1 && "${backend_counts[$BACKEND_B]}" -ge 1 ]]; then
    pass "Both backends received traffic"
else
    fail "Load not distributed to both backends"
fi

diff=$(( backend_counts[$BACKEND_A] - backend_counts[$BACKEND_B] ))
diff=${diff#-}
if [[ "$diff" -le 1 ]]; then
    pass "Distribution is even (diff=$diff)"
else
    fail "Skewed distribution (diff=$diff > 1)"
fi

# ─── 2. Strict round-robin order check ───────────────────────────────────────
section "Strict round-robin order verification"

FIRST="${ROUTE_LOG[0]}"
SECOND="${ROUTE_LOG[1]}"
ORDER_OK=true

if [[ "$FIRST" == "$SECOND" ]]; then
    fail "First two requests went to the same backend — not alternating"
    ORDER_OK=false
else
    for i in $(seq 0 $(( ${#ROUTE_LOG[@]} - 1 ))); do
        if (( i % 2 == 0 )); then expected="$FIRST"; else expected="$SECOND"; fi
        actual="${ROUTE_LOG[$i]}"
        if [[ "$actual" != "$expected" ]]; then
            fail "  Req $((i+1)): expected $expected, got $actual"
            ORDER_OK=false
        fi
    done
fi
$ORDER_OK && pass "Requests alternate A→B→A→B in strict round-robin"

# ─── 3. Streaming test ───────────────────────────────────────────────────────
section "Streaming (SSE) test"

stream_raw=$(lb_chat "Count to 3" "true")
stream_backend=$(echo "$stream_raw" | grep -i "^x-lb-backend:" | tr -d '\r' | awk '{print $2}' | sed 's|http://||')
chunk_count=$(echo "$stream_raw" | grep -c '^data:' || true)
has_done=$(echo "$stream_raw"   | grep -c 'data: \[DONE\]' || true)

info "  Backend : $stream_backend"
info "  Chunks  : $chunk_count"
info "  [DONE]  : $has_done"
echo "$stream_raw" | grep '^data:' | head -4 | while read -r line; do echo "    $line"; done

if [[ "$chunk_count" -ge 2 && "$has_done" -ge 1 ]]; then
    pass "SSE streaming works ($chunk_count chunks, [DONE] received)"
else
    fail "SSE streaming issue (chunks=$chunk_count done=$has_done)"
fi

# ─── 4. Unknown model → 404 ──────────────────────────────────────────────────
section "Error handling: unknown model"

status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
    -H "Content-Type: application/json" \
    -d '{"model":"no-such-model","messages":[{"role":"user","content":"hi"}]}' \
    "${LB_URL}/v1/chat/completions")
[[ "$status" == "404" ]] && pass "Unknown model → HTTP 404 ✓" || fail "Expected 404, got $status"

# ─── Summary ─────────────────────────────────────────────────────────────────
section "Summary"
if [[ "$FAILURES" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All tests passed!${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed.${RESET}"
    exit 1
fi
