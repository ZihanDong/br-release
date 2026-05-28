#!/usr/bin/env bash
# Quick smoke test: send a vision chat completion request to a VLM service.
#
# Usage:
#   bash curl_vlm.sh [HOST] [PORT] [MODEL] [IMAGE_FILE] [PROMPT]
#
# Defaults target qwen3-vl-32b on brhost-02 (vLLM NodePort).
# IMAGE_FILE must be a local path; it is base64-encoded and sent as a data URL.

# ── configurable defaults ────────────────────────────────────────────────────
HOST="${1:-172.25.198.37}"
PORT="${2:-30803}"
MODEL="${3:-Qwen/Qwen3-VL-32B-Instruct}"
IMAGE_FILE="${4:-$(dirname "$0")/test_image.png}"
PROMPT="${5:-请描述这张图片的内容。}"
MAX_TOKENS="${MAX_TOKENS:-256}"
# ─────────────────────────────────────────────────────────────────────────────

if [[ ! -f "$IMAGE_FILE" ]]; then
    echo "Error: image file not found: $IMAGE_FILE" >&2
    exit 1
fi

# Detect MIME type from extension
case "${IMAGE_FILE##*.}" in
    jpg|jpeg) MIME="image/jpeg" ;;
    gif)      MIME="image/gif"  ;;
    webp)     MIME="image/webp" ;;
    *)        MIME="image/png"  ;;
esac

B64=$(base64 -w 0 "$IMAGE_FILE")
DATA_URL="data:${MIME};base64,${B64}"

URL="http://${HOST}:${PORT}/v1/chat/completions"

echo "→ POST ${URL}"
echo "  model=${MODEL}  max_tokens=${MAX_TOKENS}"
echo "  image=${IMAGE_FILE}  ($(wc -c < "$IMAGE_FILE") bytes)"
echo "  prompt: ${PROMPT}"
echo ""

curl -s --noproxy "*" --max-time 180 "${URL}" \
  -H 'Content-Type: application/json' \
  -d "$(python3 -c "
import json, sys
payload = {
    'model': '${MODEL}',
    'messages': [{
        'role': 'user',
        'content': [
            {'type': 'image_url', 'image_url': {'url': '''${DATA_URL}'''}},
            {'type': 'text', 'text': '''${PROMPT}'''}
        ]
    }],
    'max_tokens': ${MAX_TOKENS}
}
print(json.dumps(payload))
")" | python3 -m json.tool
