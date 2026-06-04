#!/usr/bin/env bash
# Smoke test for the bge-m3 embedding service (vLLM OpenAI-compatible /v1/embeddings).
#
# bge-m3 is an embedding model (configs/bge-m3.conf: task=embed, port=28800,
# k8s_nodeport=30800), so it exposes /v1/embeddings — NOT /v1/chat/completions.
#
# Usage:
#   bash curl_bge_m3.sh [HOST] [PORT] [MODEL] [TEXT...]
#
#   HOST   service host        (default 172.25.198.37 = brhost-02)
#   PORT   service port        (default 30800 = bge-m3 NodePort; for a bare Pod
#                               use `kubectl -n vllm port-forward pod/<pod> 30800:28800`
#                               then HOST=127.0.0.1)
#   MODEL  model id            (default: auto-discovered from /v1/models)
#   TEXT   one or more strings to embed (default: a CN + EN sample)
#
# Exit code: 0 if the service returns embedding vectors, non-zero otherwise.

set -uo pipefail

HOST="${1:-172.25.198.37}"
PORT="${2:-30800}"
MODEL_ARG="${3:-}"
shift || true; shift || true; shift || true
if [[ "$#" -gt 0 ]]; then
    TEXTS=("$@")
else
    TEXTS=("壁仞 GPU 上的向量检索" "What is retrieval-augmented generation?")
fi

BASE="http://${HOST}:${PORT}"
CURL=(curl -s --noproxy "*" --max-time 120)

echo "→ service: ${BASE}" >&2

# ── Discover the served model id (served_model_name is empty in the conf, so the
#    id is whatever vLLM registered) unless the caller passed one explicitly. ──
MODEL="$MODEL_ARG"
if [[ -z "$MODEL" ]]; then
    MODEL=$("${CURL[@]}" "${BASE}/v1/models" 2>/dev/null \
        | python3 -c "import sys,json
try:
    d=json.load(sys.stdin); print(d['data'][0]['id'])
except Exception:
    pass" 2>/dev/null)
fi
[[ -z "$MODEL" ]] && MODEL="bge-m3"
echo "  model=${MODEL}  inputs=${#TEXTS[@]}" >&2
echo "" >&2

# ── Build the JSON request body (input = array of strings). ──
REQ=$(python3 -c "import json,sys; print(json.dumps({'model': sys.argv[1], 'input': sys.argv[2:]}))" \
    "$MODEL" "${TEXTS[@]}")

RESP=$("${CURL[@]}" "${BASE}/v1/embeddings" \
    -H 'Content-Type: application/json' \
    -d "$REQ")

if [[ -z "$RESP" ]]; then
    echo "[FAIL] no response from ${BASE}/v1/embeddings (service up? port-forward needed for a bare Pod?)" >&2
    exit 1
fi

# ── Validate + summarize (print per-input embedding dimension and a preview). ──
echo "$RESP" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print('[FAIL] non-JSON response:'); print(sys.stdin.read()[:500]); sys.exit(1)
if 'data' not in d or not d['data']:
    print('[FAIL] no embedding data in response:'); print(json.dumps(d, ensure_ascii=False)[:500]); sys.exit(1)
n = len(d['data'])
dim = len(d['data'][0].get('embedding', []))
print(f'[OK] embeddings returned: count={n}  dim={dim}  model={d.get(\"model\")}')
for i, item in enumerate(d['data']):
    emb = item.get('embedding', [])
    preview = ', '.join(f'{x:.4f}' for x in emb[:4])
    print(f'  [{i}] dim={len(emb)}  [{preview}, ...]')
if 'usage' in d:
    print(f'  usage: {d[\"usage\"]}')
sys.exit(0 if dim > 0 else 1)
"
