#!/bin/bash
# End-to-end test for the vLLM load balancer.
#
# Starts 3 mock vLLM backends locally, then launches the load balancer
# inside a Docker container (python:3.11-slim, --network=host), then
# sends simulated curl requests and validates round-robin distribution.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LB_DIR="$(dirname "$SCRIPT_DIR")"

LB_PORT=18080
BACKEND_PORTS=(18001 18002 18003)
BACKEND_IDS=("A-1" "A-2" "B-1")
IMAGE="vllm-lb:latest"
CONTAINER="lb-test"
PIDS=()

# ─── colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
pass() { echo -e "${GREEN}[PASS]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; FAILURES=$((FAILURES+1)); }
info() { echo -e "${CYAN}[INFO]${RESET} $*"; }
section() { echo -e "\n${BOLD}${YELLOW}=== $* ===${RESET}"; }
FAILURES=0

# ─── cleanup ────────────────────────────────────────────────────────────────
cleanup() {
    info "Cleaning up..."
    docker stop "$CONTAINER" 2>/dev/null && docker rm "$CONTAINER" 2>/dev/null || true
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    wait 2>/dev/null || true
}
trap cleanup EXIT

# ─── 1. Ensure dependencies ──────────────────────────────────────────────────
section "Checking Python deps for mock backends"
python3 -c "import fastapi, uvicorn" 2>/dev/null || {
    info "Installing fastapi + uvicorn for mock backends..."
    pip install -q fastapi "uvicorn[standard]" pyyaml
}

# ─── 2. Start mock backends ─────────────────────────────────────────────────
section "Starting mock backends"
for i in 0 1 2; do
    port=${BACKEND_PORTS[$i]}
    id=${BACKEND_IDS[$i]}
    python3 "$SCRIPT_DIR/mock_backend.py" --port "$port" --id "$id" &
    PIDS+=($!)
    info "  backend-${id} listening on :${port}  (PID ${PIDS[-1]})"
done

# Wait for all backends to be ready
info "Waiting for backends..."
for port in "${BACKEND_PORTS[@]}"; do
    for _ in $(seq 1 20); do
        curl -sf "http://127.0.0.1:${port}/health" > /dev/null 2>&1 && break
        sleep 0.3
    done
    curl -sf "http://127.0.0.1:${port}/health" > /dev/null 2>&1 \
        || { fail "Backend on :${port} failed to start"; exit 1; }
done
pass "All mock backends are up"

# ─── 3. Start load balancer in Docker ───────────────────────────────────────
section "Starting load balancer in Docker ($IMAGE)"

docker stop "$CONTAINER" 2>/dev/null || true
docker rm  "$CONTAINER" 2>/dev/null || true

docker run -d \
    --name "$CONTAINER" \
    --network host \
    -v "$SCRIPT_DIR:/app/test:ro" \
    "$IMAGE" \
    --host 0.0.0.0 \
    --port "$LB_PORT" \
    --config /app/test/config_test.yaml \
    --timeout 60

info "Waiting for load balancer to be ready..."
for i in $(seq 1 40); do
    curl -sf "http://127.0.0.1:${LB_PORT}/health" > /dev/null 2>&1 && break
    if [ "$i" -eq 40 ]; then
        fail "Load balancer timed out. Container logs:"
        docker logs "$CONTAINER" | tail -30
        exit 1
    fi
    sleep 0.5
done
pass "Load balancer is ready on :${LB_PORT}"

echo ""
info "Registered models:"
curl -s "http://127.0.0.1:${LB_PORT}/v1/models" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for m in d['data']:
    print(f'    {m[\"id\"]}  ({m[\"backends\"]} backend(s))')
"

# ─── Helper ──────────────────────────────────────────────────────────────────
lb_post() {
    # lb_post <model> [stream=0|1]
    local model="$1"
    local stream="${2:-0}"
    local payload="{\"model\":\"${model}\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":${stream}}"
    curl -s --max-time 10 \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "http://127.0.0.1:${LB_PORT}/v1/chat/completions"
}

# ─── 4. Round-robin test for test-model-a (2 backends) ──────────────────────
section "Round-robin test: test-model-a (2 backends: A-1 on :18001, A-2 on :18002)"

EXPECTED_A=("A-1" "A-2" "A-1" "A-2" "A-1" "A-2")
ROUND_ROBIN_OK=true

for i in $(seq 0 5); do
    resp=$(lb_post "test-model-a")
    content=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null || echo "ERROR")
    expected="${EXPECTED_A[$i]}"

    if echo "$content" | grep -q "backend-${expected}"; then
        pass "  Request $((i+1)): routed to backend-${expected} ✓  ($content)"
    else
        fail "  Request $((i+1)): expected backend-${expected}, got: $content"
        ROUND_ROBIN_OK=false
    fi
done

if $ROUND_ROBIN_OK; then
    pass "Round-robin for test-model-a works correctly"
else
    fail "Round-robin for test-model-a has errors"
fi

# ─── 5. Single-backend test for test-model-b ────────────────────────────────
section "Single-backend test: test-model-b (only B-1 on :18003 is enabled)"

SINGLE_OK=true
for i in $(seq 1 4); do
    resp=$(lb_post "test-model-b")
    content=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])" 2>/dev/null || echo "ERROR")

    if echo "$content" | grep -q "backend-B-1"; then
        pass "  Request $i: correctly routed to backend-B-1 ✓"
    else
        fail "  Request $i: unexpected backend: $content"
        SINGLE_OK=false
    fi
done

if $SINGLE_OK; then
    pass "All test-model-b requests went to the single enabled backend"
fi

# ─── 6. Streaming test ───────────────────────────────────────────────────────
section "Streaming (SSE) test: test-model-a with stream=true"

stream_output=$(lb_post "test-model-a" "true")
echo "$stream_output"

chunk_count=$(echo "$stream_output" | grep -c '^data:' || true)
has_done=$(echo "$stream_output" | grep -c 'data: \[DONE\]' || true)

if [ "$chunk_count" -gt 2 ] && [ "$has_done" -ge 1 ]; then
    pass "Streaming: received $chunk_count SSE chunks including [DONE]"
else
    fail "Streaming: unexpected output (chunks=$chunk_count done=$has_done)"
fi

# ─── 7. Unknown model → 404 ──────────────────────────────────────────────────
section "Error handling: unknown model should return 404"

status=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
    -H "Content-Type: application/json" \
    -d '{"model":"no-such-model","messages":[{"role":"user","content":"hi"}]}' \
    "http://127.0.0.1:${LB_PORT}/v1/chat/completions")

if [ "$status" = "404" ]; then
    pass "Unknown model returns HTTP 404 ✓"
else
    fail "Unknown model returned HTTP $status (expected 404)"
fi

# ─── 8. Backend request count verification ───────────────────────────────────
section "Backend request count verification"

# 6 requests to test-model-a → 3 each to A-1 and A-2
# 4 requests to test-model-b → 4 to B-1
# 1 streaming request to test-model-a → alternates (7th overall → A-1 or A-2)

for i in 0 1 2; do
    port=${BACKEND_PORTS[$i]}
    id=${BACKEND_IDS[$i]}
    stats=$(curl -s "http://127.0.0.1:${port}/stats")
    count=$(echo "$stats" | python3 -c "import sys,json; print(json.load(sys.stdin)['request_count'])")
    info "  backend-${id} (:${port}) received ${count} request(s)"
done

A1=$(curl -s "http://127.0.0.1:18001/stats" | python3 -c "import sys,json; print(json.load(sys.stdin)['request_count'])")
A2=$(curl -s "http://127.0.0.1:18002/stats" | python3 -c "import sys,json; print(json.load(sys.stdin)['request_count'])")

# A-1 and A-2 should have equal or near-equal counts (7 total → diff at most 1)
diff=$(( A1 - A2 ))
diff=${diff#-}   # abs
if [ "$diff" -le 1 ]; then
    pass "test-model-a load balanced evenly: A-1=$A1, A-2=$A2 (diff=$diff)"
else
    fail "test-model-a load imbalanced: A-1=$A1, A-2=$A2 (diff=$diff)"
fi

B1=$(curl -s "http://127.0.0.1:18003/stats" | python3 -c "import sys,json; print(json.load(sys.stdin)['request_count'])")
if [ "$B1" -eq 4 ]; then
    pass "test-model-b: all 4 requests went to B-1 ✓"
else
    fail "test-model-b: expected 4 requests at B-1, got $B1"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
section "Test Summary"
if [ "$FAILURES" -eq 0 ]; then
    echo -e "${GREEN}${BOLD}All tests passed!${RESET}"
else
    echo -e "${RED}${BOLD}$FAILURES test(s) failed.${RESET}"
    exit 1
fi
