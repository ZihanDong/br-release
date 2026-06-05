#!/usr/bin/env bash
# 持续高并发压测 bge-m3 embedding 服务（/v1/embeddings）。
# 启动 N 个并发 worker，每个 worker 死循环发送 embedding 请求，把服务压到高负载。
# 设计为「启动后一直运行」——后续 vGPU 隔离/利用率测试期间保持它运行，不要停止。
#
# 用法:
#   bash load_bge_embed.sh [HOST] [PORT] [CONCURRENCY] [MODEL]
#     HOST         服务地址（默认 127.0.0.1，建议用 bge pod IP 或节点 NodePort 所在 IP）
#     PORT         端口（默认 28800；deploy 经 NodePort 时用 30800）
#     CONCURRENCY  并发 worker 数（默认 64）
#     MODEL        模型 id（默认从 /v1/models 自动发现，回退 bge-m3）
#
# 每 5s 打印一次累计统计：总请求 / 成功 / 失败 / 近 5s QPS / 平均延迟(ms)。
# Ctrl-C 或 kill 退出时清理所有 worker。日志：stdout。

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-28800}"
CONC="${3:-64}"
MODEL_ARG="${4:-}"
BASE="http://${HOST}:${PORT}"

# 待 embed 的文本（固定一批，足够产生稳定负载）
read -r -d '' INPUTS_JSON <<'JSON' || true
["壁仞 GPU 上的向量检索与召回","retrieval augmented generation on Biren vGPU","同一物理卡上多 vGPU 的隔离性测试","high concurrency embedding load test"]
JSON

# 自动发现模型 id
MODEL="$MODEL_ARG"
if [[ -z "$MODEL" ]]; then
    MODEL=$(curl -s --noproxy '*' --max-time 5 "${BASE}/v1/models" 2>/dev/null \
        | python3 -c "import sys,json;print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)
fi
[[ -z "$MODEL" ]] && MODEL="bge-m3"

REQ_BODY="{\"model\":\"${MODEL}\",\"input\":${INPUTS_JSON}}"
STATS_DIR="$(mktemp -d /tmp/load_bge.XXXXXX)"
echo "target=${BASE}/v1/embeddings  model=${MODEL}  concurrency=${CONC}  stats=${STATS_DIR}"

cleanup() { echo; echo "stopping workers..."; kill 0 2>/dev/null; rm -rf "$STATS_DIR" 2>/dev/null; }
trap cleanup EXIT INT TERM

# 单个 worker：死循环发请求，把 ok/fail/累计延迟(us) 写入自己的统计文件
worker() {
    # NOTE: assign on separate lines — `local a=$1 b=$a` expands ${a} before the
    # assignment lands, which trips `set -u` ("a: unbound variable").
    local id="$1"
    local f="${STATS_DIR}/w${id}"
    local ok=0 fail=0 us=0 t0 t1 code
    : > "$f"
    while :; do
        t0=$(date +%s%6N)
        code=$(curl -s --noproxy '*' --max-time 30 -o /dev/null -w '%{http_code}' \
            "${BASE}/v1/embeddings" -H 'Content-Type: application/json' -d "$REQ_BODY" 2>/dev/null)
        t1=$(date +%s%6N)
        if [[ "$code" == "200" ]]; then ok=$((ok+1)); us=$((us + (t1-t0))); else fail=$((fail+1)); fi
        # 周期性落盘（每 20 次请求写一次，降低 IO）
        if (( (ok+fail) % 20 == 0 )); then printf '%s %s %s\n' "$ok" "$fail" "$us" > "$f"; fi
    done
}

for ((i=0; i<CONC; i++)); do worker "$i" & done

# 主循环：周期性汇总打印
prev_total=0
while :; do
    sleep 5
    sum_ok=0 sum_fail=0 sum_us=0
    for f in "${STATS_DIR}"/w*; do
        [[ -s "$f" ]] || continue
        read -r o fa u < "$f"
        sum_ok=$((sum_ok + ${o:-0})); sum_fail=$((sum_fail + ${fa:-0})); sum_us=$((sum_us + ${u:-0}))
    done
    total=$((sum_ok + sum_fail))
    qps=$(( (total - prev_total) / 5 )); prev_total=$total
    avg_ms=0; [[ "$sum_ok" -gt 0 ]] && avg_ms=$(( sum_us / sum_ok / 1000 ))
    printf '[%s] total=%d ok=%d fail=%d  ~qps=%d  avg=%dms\n' \
        "$(date +%H:%M:%S)" "$total" "$sum_ok" "$sum_fail" "$qps" "$avg_ms"
done
