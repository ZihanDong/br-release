#!/usr/bin/env bash
# Quick smoke test: send a single chat completion request to a vLLM service.
#
# Usage:
#   bash tests/curl_single_test.sh [HOST] [PORT] [MODEL] [PROMPT]
#
# Defaults target qwen3-32b on brhost-02. Override via positional args or
# by editing the variables below.

# ── configurable defaults ────────────────────────────────────────────────────
HOST="${1:-172.25.198.37}"
PORT="${2:-30801}"
MODEL="${3:-Qwen/Qwen3-32B}"
PROMPT="${4:-你是谁？}"
MAX_TOKENS="${MAX_TOKENS:-128}"
# ─────────────────────────────────────────────────────────────────────────────

URL="http://${HOST}:${PORT}/v1/chat/completions"

echo "→ POST ${URL}"
echo "  model=${MODEL}  max_tokens=${MAX_TOKENS}"
echo "  prompt: ${PROMPT}"
echo ""

curl -s --noproxy "*" --max-time 120 "${URL}" \
  -H 'Content-Type: application/json' \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"${PROMPT}\"}],
    \"max_tokens\": ${MAX_TOKENS}
  }" | python3 -m json.tool
