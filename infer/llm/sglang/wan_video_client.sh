#!/usr/bin/env bash
# Wan2.2 video-generation test client for the sglang.multimodal_gen online server
# (launch_mode=video_gen). Submits POST /v1/videos, polls the job, downloads the mp4,
# and reports timing (wall / server inference_time_s / per-step) over --runs iterations.
#
# t2v, 2 runs, 1280x720, 20 steps:
#   bash wan_video_client.sh --task t2v --port 39000 --steps 20 --size 1280x720 --runs 2
#
# i2v (server must be an -I2V- model): --task i2v + a first-frame image
#   bash wan_video_client.sh --task i2v --port 39001 --steps 40 --size 1280x720 --runs 1 \
#       --image ./i2v_input.JPG --out /data/final/wan2.2-0606/i2v.mp4
#
# --task is optional: if omitted it defaults to i2v when --image is given, else t2v.
#
# Each run downloads its mp4 (via /v1/videos/<id>/content) to <out>_run<N>.mp4.
# NOTE: the current c064 build has a multi-request bug — only the FIRST request on a
# given server succeeds; run 2+ fail with "Input is not on SUPA". Restart the server
# (run_docker.sh --run …) between runs to get more than one data point.

set -euo pipefail

# Bypass any localhost HTTP proxy (this node sets http_proxy=127.0.0.1:7890, which
# turns curl to 127.0.0.1:<port> into 502s). Make localhost direct for all curls.
export no_proxy="127.0.0.1,localhost,::1${no_proxy:+,$no_proxy}"
export NO_PROXY="$no_proxy"

HOST="127.0.0.1"
PORT="39000"
PROMPT="Summer beach vacation style, a white cat wearing sunglasses sits on a surfboard."
SIZE="832x480"
STEPS=4
FRAMES=81
SEED=1024
RUNS=1
TASK=""          # t2v | i2v ; if empty, inferred from --image
IMAGE=""
NEGATIVE=""
OUT=""
POLL_TIMEOUT=3600   # seconds per run

# All human/progress messages go to STDERR so STDOUT carries only machine results
# (and the summary). Run with `> file 2>&1` to capture everything to a log.
_info() { echo -e "\033[0;36m[INFO]\033[0m  $*" >&2; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*" >&2; }
_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*" >&2; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

usage() {
    cat >&2 <<EOF
Usage: $0 [options]
  --host <h>        Server host (default 127.0.0.1)
  --port <p>        Server port (default 39000)
  --prompt <text>   Generation prompt
  --size <WxH>      Resolution, e.g. 832x480 or 1280x720 (default 832x480)
  --steps <n>       Diffusion steps (default 4)
  --frames <n>      num_frames; (frames-1) must be divisible by 4 (default 81)
  --seed <n>        Seed (default 1024)
  --runs <n>        Number of timed generations to run (default 1)
  --task <t2v|i2v>  Task type (default: i2v if --image given, else t2v).
                    i2v requires --image; the server must be an -I2V- model.
  --image <path>    First-frame image path for i2v (required for --task i2v)
  --negative <txt>  Negative prompt (optional; model has a default)
  --out <file>      Base download path; runs save to <out_without_ext>_run<N>.mp4
  --timeout <sec>   Max seconds to poll per run (default 3600)
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)     HOST="$2"; shift 2 ;;
        --port)     PORT="$2"; shift 2 ;;
        --prompt)   PROMPT="$2"; shift 2 ;;
        --size)     SIZE="$2"; shift 2 ;;
        --steps)    STEPS="$2"; shift 2 ;;
        --frames)   FRAMES="$2"; shift 2 ;;
        --seed)     SEED="$2"; shift 2 ;;
        --runs)     RUNS="$2"; shift 2 ;;
        --task)     TASK="$2"; shift 2 ;;
        --image)    IMAGE="$2"; shift 2 ;;
        --negative) NEGATIVE="$2"; shift 2 ;;
        --out)      OUT="$2"; shift 2 ;;
        --timeout)  POLL_TIMEOUT="$2"; shift 2 ;;
        -h|--help)  usage ;;
        *) _err "Unknown option: $1"; usage ;;
    esac
done

BASE="http://${HOST}:${PORT}"
command -v jq >/dev/null 2>&1 || { _err "jq is required (apt-get install jq)."; exit 1; }

# Resolve task: explicit --task wins; otherwise infer from --image presence.
if [[ -z "$TASK" ]]; then
    TASK=$([[ -n "$IMAGE" ]] && echo i2v || echo t2v)
fi
case "$TASK" in
    t2v) ;;
    i2v) [[ -n "$IMAGE" ]] || { _err "--task i2v requires --image <first-frame.jpg>"; exit 1; } ;;
    *)   _err "Invalid --task '$TASK' (expected t2v or i2v)"; exit 1 ;;
esac
[[ "$TASK" == "t2v" && -n "$IMAGE" ]] && _warn "--task t2v: ignoring --image ($IMAGE)"

# Per-run download base: <out_without_ext>; default ./wan_<task>_<size>
OUT_BASE="${OUT:-./wan_${TASK}_${SIZE}}"
OUT_BASE="${OUT_BASE%.mp4}"

# ── Health check ───────────────────────────────────────────────────────────────
curl -sf "${BASE}/health" >/dev/null 2>&1 || { _err "Server not responding at ${BASE}/health — is it up?"; exit 1; }
_ok "Server healthy: ${BASE}  | task=${TASK} size=${SIZE} steps=${STEPS} frames=${FRAMES} runs=${RUNS}"

# ── Build request JSON (same for every run; same seed → identical output) ──────
req=$(jq -n --arg prompt "$PROMPT" --arg size "$SIZE" \
    --argjson steps "$STEPS" --argjson frames "$FRAMES" --argjson seed "$SEED" \
    '{prompt:$prompt, size:$size, num_inference_steps:$steps, num_frames:$frames, seed:$seed}')
if [[ "$TASK" == "i2v" ]]; then
    [[ -f "$IMAGE" ]] || { _err "Image not found: $IMAGE"; exit 1; }
    # input_reference is read by the server directly as a local image_path INSIDE the
    # container (CWD=/workspace), so resolve to an absolute path — it must fall under a
    # bind-mounted dir (/home or /data) to be visible in the container. The server also
    # auto-detects i2v from the model's model_index.json and rejects requests without an
    # image, so an -I2V- server is required.
    IMAGE_ABS=$(realpath "$IMAGE")
    case "$IMAGE_ABS" in
        /home/*|/data/*) ;;
        *) _warn "image ${IMAGE_ABS} is not under /home or /data — the container may not see it" ;;
    esac
    req=$(echo "$req" | jq --arg img "$IMAGE_ABS" '. + {input_reference:$img}')
    _info "i2v input image: ${IMAGE_ABS}"
fi
[[ -n "$NEGATIVE" ]] && req=$(echo "$req" | jq --arg n "$NEGATIVE" '. + {negative_prompt:$n}')

# ── One generation: progress → stderr; on success prints "wall infer perstep peak" to stdout ──
run_once() {
    local idx="$1" out_file="$2"
    local t0 t1 resp vid job status infer peak wall perstep pstart now
    t0=$(date +%s.%N)
    resp=$(curl -s -X POST "${BASE}/v1/videos" -H 'Content-Type: application/json' -d "$req")
    vid=$(echo "$resp" | jq -r '.id // empty')
    [[ -n "$vid" ]] || { _err "run ${idx}: submit failed: ${resp}"; return 1; }
    _ok "run ${idx}: submitted id=${vid}"
    pstart=$(date +%s)
    while true; do
        job=$(curl -s "${BASE}/v1/videos/${vid}")
        status=$(echo "$job" | jq -r '.status // "unknown"')
        [[ "$status" == "completed" ]] && break
        [[ "$status" == "failed" ]] && { _err "run ${idx} FAILED: $(echo "$job" | jq -rc '.error.message // .error // .')"; return 1; }
        now=$(date +%s)
        (( now - pstart > POLL_TIMEOUT )) && { _err "run ${idx}: timeout after ${POLL_TIMEOUT}s (last=${status})"; return 1; }
        printf "  run %s [%4ds] status=%s\n" "$idx" "$((now - pstart))" "$status" >&2
        sleep 5
    done
    t1=$(date +%s.%N)
    infer=$(echo "$job" | jq -r '.inference_time_s // 0')
    peak=$(echo "$job"  | jq -r '.peak_memory_mb // 0')
    wall=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')
    perstep=$(awk -v i="$infer" -v s="$STEPS" 'BEGIN{printf "%.2f", (s>0? i/s : 0)}')
    if curl -sf "${BASE}/v1/videos/${vid}/content" -o "$out_file" 2>/dev/null && [[ -s "$out_file" ]]; then
        _ok "run ${idx}: downloaded → ${out_file} ($(du -h "$out_file" | cut -f1))"
    else
        _warn "run ${idx}: no HTTP download (server file: $(echo "$job" | jq -r '.file_path // "n/a"'))"
    fi
    _ok "run ${idx}: wall=${wall}s  infer=${infer}s  per-step=${perstep}s  peak=${peak}MB"
    echo "${wall} ${infer} ${perstep} ${peak}"
}

# ── Loop over runs, accumulate stats ───────────────────────────────────────────
ok=0; fail=0; sum_wall=0; sum_infer=0; sum_ps=0; peak_max=0
for ((r=1; r<=RUNS; r++)); do
    echo "" >&2
    _info "──────── run ${r}/${RUNS} ────────"
    if line=$(run_once "$r" "${OUT_BASE}_run${r}.mp4"); then
        read -r w i p pk <<< "$line"
        sum_wall=$(awk -v a="$sum_wall" -v b="$w" 'BEGIN{print a+b}')
        sum_infer=$(awk -v a="$sum_infer" -v b="$i" 'BEGIN{print a+b}')
        sum_ps=$(awk -v a="$sum_ps" -v b="$p" 'BEGIN{print a+b}')
        (( $(awk -v p="$pk" -v m="$peak_max" 'BEGIN{print (p>m)}') )) && peak_max=$pk
        ok=$((ok+1))
    else
        fail=$((fail+1))
    fi
done

# ── Summary (stdout) ───────────────────────────────────────────────────────────
echo ""
echo "════════════ SUMMARY  task=${TASK}  ${SIZE}  ${FRAMES}f  ${STEPS} steps  runs=${RUNS} ════════════"
echo "  success: ${ok}/${RUNS}   failed: ${fail}"
if (( ok > 0 )); then
    awk -v sw="$sum_wall" -v si="$sum_infer" -v sp="$sum_ps" -v n="$ok" -v st="$STEPS" -v pk="$peak_max" 'BEGIN{
        printf "  total infer time (sum of runs): %.1f s\n", si;
        printf "  total wall  time (sum of runs): %.1f s\n", sw;
        printf "  avg  wall   per run           : %.1f s\n", sw/n;
        printf "  avg  infer  per run           : %.1f s   (server inference_time_s)\n", si/n;
        printf "  avg  per-step                 : %.2f s   (= avg infer / %d steps)\n", sp/n, st;
        printf "  peak memory                   : %.0f MB\n", pk;
    }'
fi
[[ $fail -gt 0 ]] && echo "  NOTE: failures are expected for run 2+ on one server (multi-request bug; see README §5)."
echo "═══════════════════════════════════════════════════════════════════════════════"
