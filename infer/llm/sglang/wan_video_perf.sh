#!/usr/bin/env bash
# Wan2.2 video-generation ONLINE perf test (curl-based).
#
# Sequentially benchmarks the 8-card cfg2 servers for t2v and i2v at a fixed
# resolution (default 1280x720). For each task it: launches the server via
# run_docker.sh --run, does a warm-up generation (discarded — first request
# JIT-compiles SUDNN/VAE kernels), then N timed runs, polling POST/GET /v1/videos
# and recording latency. Stops the server before moving to the next task.
#
# Timing sources per run:
#   - wall   : client-side wall clock around submit→completed
#   - infer  : server's `inference_time_s` from the completed VideoResponse
#   - peakMB : server's `peak_memory_mb`
#
# Token accounting: the OpenAI-style video response carries NO token field
# (only inference_time_s / peak_memory_mb). Video diffusion has no LLM "tokens",
# so we report the closest analog — the DiT latent sequence length (#tokens per
# forward pass) derived from the resolution, and the total token-passes over the
# whole diffusion (× steps × cfg). Formula (Wan2.2 A14B): VAE 8x spatial / 4x
# temporal, DiT patch_size (1,2,2):
#     T_lat = (frames-1)/4 + 1 ;  H_lat = H/16 ;  W_lat = W/16
#     tokens_per_pass   = T_lat * H_lat * W_lat
#     total_token_pass  = tokens_per_pass * steps * cfg_factor(=2 for cfg2)
#
# Usage:
#   bash wan_video_perf.sh [--size 1280x720] [--frames 81] [--steps 40]
#        [--runs 3] [--tasks t2v,i2v] [--image ./i2v_input.JPG] [--keep]

set -euo pipefail
export no_proxy="127.0.0.1,localhost,::1${no_proxy:+,$no_proxy}"
export NO_PROXY="$no_proxy"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Defaults ────────────────────────────────────────────────────────────────
SIZE="1280x720"
FRAMES=81
STEPS=40
RUNS=3
TASKS="t2v,i2v"
IMAGE="${SCRIPT_DIR}/i2v_input.JPG"
KEEP=false
SEED=1024
HEALTH_TIMEOUT=900     # s to wait for server /health
GEN_TIMEOUT=3600       # s to wait for one generation

_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

usage() { grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --size)   SIZE="$2"; shift 2 ;;
        --frames) FRAMES="$2"; shift 2 ;;
        --steps)  STEPS="$2"; shift 2 ;;
        --runs)   RUNS="$2"; shift 2 ;;
        --tasks)  TASKS="$2"; shift 2 ;;
        --image)  IMAGE="$2"; shift 2 ;;
        --keep)   KEEP=true; shift ;;
        -h|--help) usage ;;
        *) _err "Unknown option: $1"; usage ;;
    esac
done

command -v jq >/dev/null 2>&1 || { _err "jq required"; exit 1; }
W="${SIZE%x*}"; H="${SIZE#*x}"

# ── Token-equivalent calc (Wan2.2 A14B latent geometry) ──────────────────────
# prints: tokens_per_pass total_token_passes  (cfg_factor=2)
calc_tokens() {
    awk -v W="$1" -v H="$2" -v F="$3" -v S="$4" 'BEGIN{
        tlat=int((F-1)/4)+1; hlat=int(H/16); wlat=int(W/16);
        tok=tlat*hlat*wlat;
        printf "%d %d %d %d %d", tlat, hlat, wlat, tok, tok*S*2
    }'
}

# ── One task: launch server, warm up, time RUNS generations ──────────────────
# args: task(t2v|i2v) model(wan2.2-…) port
run_task() {
    local task="$1" model="$2" port="$3"
    local base="http://127.0.0.1:${port}"
    local container="sglang_${model}"

    echo ""
    _info "════════ ${task^^}  (${model}, :${port}, ${SIZE}, steps=${STEPS}) ════════"

    # Build the per-request JSON (i2v adds a local input image via input_reference,
    # which the server reads directly as image_path — no reference_url upload path).
    local req
    req=$(jq -n --arg p "perf benchmark: a white cat wearing sunglasses on a surfboard at the beach, gentle waves" \
                --arg sz "$SIZE" --argjson st "$STEPS" --argjson fr "$FRAMES" --argjson sd "$SEED" \
                '{prompt:$p, size:$sz, num_inference_steps:$st, num_frames:$fr, seed:$sd}')
    if [[ "$task" == "i2v" ]]; then
        [[ -f "$IMAGE" ]] || { _err "i2v needs --image; not found: $IMAGE"; return 1; }
        req=$(echo "$req" | jq --arg img "$IMAGE" '. + {input_reference:$img}')
        _info "i2v input image: ${IMAGE}"
    fi

    # ── launch server (8-card cfg2 from the committed config) ──
    _info "Launching server ${container} ..."
    sudo docker rm -f "$container" >/dev/null 2>&1 || true
    sudo bash "${SCRIPT_DIR}/run_docker.sh" --run "$model" > "/tmp/perf_${model}.log" 2>&1 &
    local up=false _t=0
    while (( _t < HEALTH_TIMEOUT )); do
        if curl -sf --noproxy '*' --max-time 4 "${base}/health" >/dev/null 2>&1; then up=true; break; fi
        sleep 10; _t=$((_t+10))
    done
    if ! $up; then _err "${task}: server not ready in ${HEALTH_TIMEOUT}s"; tail -15 "/tmp/perf_${model}.log"; return 1; fi
    _ok "Server ready after ~${_t}s"

    # one timed generation; echoes "wall infer peakmb" or "FAIL"
    _gen_once() {
        local t0 t1 vid job status infer peak
        t0=$(date +%s.%N)
        vid=$(curl -s --noproxy '*' --max-time 30 -X POST "${base}/v1/videos" \
                -H 'Content-Type: application/json' -d "$req" | jq -r '.id // empty')
        [[ -n "$vid" ]] || { echo "FAIL submit"; return 1; }
        local _g=0
        while (( _g < GEN_TIMEOUT )); do
            job=$(curl -s --noproxy '*' --max-time 10 "${base}/v1/videos/${vid}")
            status=$(echo "$job" | jq -r '.status // "unknown"')
            [[ "$status" == "completed" ]] && break
            [[ "$status" == "failed" ]] && { echo "FAIL $(echo "$job" | jq -rc '.error')"; return 1; }
            sleep 3; _g=$((_g+3))
        done
        t1=$(date +%s.%N)
        infer=$(echo "$job" | jq -r '.inference_time_s // 0')
        peak=$(echo "$job"  | jq -r '.peak_memory_mb // 0')
        awk -v a="$t0" -v b="$t1" -v i="$infer" -v p="$peak" 'BEGIN{printf "%.1f %.1f %.0f", b-a, i, p}'
    }

    _info "Warm-up / first request (includes one-time kernel JIT compile) ..."
    local warm; warm=$(_gen_once) || { _err "${task} warm-up failed: $warm"; $KEEP || sudo docker rm -f "$container" >/dev/null 2>&1; return 1; }
    _ok "First request: ${warm} (wall infer peakMB)"
    # Record the first request too: with the current build's multi-request bug
    # (2nd request fails: "Input is not on SUPA"), this may be the only data point.
    { read -r _w _i _p <<< "$warm"
      read -r _ _ _ tok total <<< "$(calc_tokens "$W" "$H" "$FRAMES" "$STEPS")"
      awk -v t="${task}-1st" -v w="$_w" -v i="$_i" -v p="$_p" -v steps="$STEPS" -v tok="$tok" -v total="$total" \
        'BEGIN{printf "RESULT|%s|%.1f|%.1f|%.2f|%.0f|%d|%d|%.0f|incl-JIT\n", t,w,i,(i/steps),p,tok,total,(total/i)}'
    } >> /tmp/wan_perf_results.txt

    local sum_wall=0 sum_infer=0 peak=0 n=0
    for ((r=1; r<=RUNS; r++)); do
        local res; res=$(_gen_once) || { _warn "run $r failed: $res"; continue; }
        local w i p; read -r w i p <<< "$res"
        printf "  run %d/%d: wall=%ss  infer=%ss  peak=%sMB\n" "$r" "$RUNS" "$w" "$i" "$p"
        sum_wall=$(awk -v a="$sum_wall" -v b="$w" 'BEGIN{print a+b}')
        sum_infer=$(awk -v a="$sum_infer" -v b="$i" 'BEGIN{print a+b}')
        (( $(awk -v p="$p" -v m="$peak" 'BEGIN{print (p>m)}') )) && peak=$p
        n=$((n+1))
    done
    $KEEP || { _info "Stopping ${container}"; sudo docker rm -f "$container" >/dev/null 2>&1 || true; }
    [[ $n -gt 0 ]] || { _err "${task}: all timed runs failed"; return 1; }

    # averages + token math
    read -r tlat hlat wlat tok total <<< "$(calc_tokens "$W" "$H" "$FRAMES" "$STEPS")"
    awk -v task="$task" -v n="$n" -v sw="$sum_wall" -v si="$sum_infer" -v peak="$peak" \
        -v steps="$STEPS" -v tok="$tok" -v total="$total" \
        -v tl="$tlat" -v hl="$hlat" -v wl="$wlat" 'BEGIN{
        aw=sw/n; ai=si/n; perstep=ai/steps; thr=(total/ai);
        printf "RESULT|%s|%.1f|%.1f|%.2f|%.0f|%d|%d|%.0f|%d:%d:%d\n",
               task, aw, ai, perstep, peak, tok, total, thr, tl, hl, wl
    }' >> /tmp/wan_perf_results.txt
    _ok "${task^^} avg: wall=$(awk -v s="$sum_wall" -v n="$n" 'BEGIN{printf "%.1f",s/n}')s  infer=$(awk -v s="$sum_infer" -v n="$n" 'BEGIN{printf "%.1f",s/n}')s  per-step=$(awk -v s="$sum_infer" -v n="$n" -v st="$STEPS" 'BEGIN{printf "%.2f",s/n/st}')s  tokens/pass=${tok}"
}

# ── Main ─────────────────────────────────────────────────────────────────────
: > /tmp/wan_perf_results.txt
_info "Wan2.2 online perf — size=${SIZE} frames=${FRAMES} steps=${STEPS} runs=${RUNS} tasks=${TASKS}"

IFS=',' read -ra _tasks <<< "$TASKS"
for t in "${_tasks[@]}"; do
    case "$t" in
        t2v) run_task t2v wan2.2-t2v-a14b 39000 || _warn "t2v task failed" ;;
        i2v) run_task i2v wan2.2-i2v-a14b 39001 || _warn "i2v task failed" ;;
        *)   _warn "unknown task: $t" ;;
    esac
done

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════ SUMMARY (${SIZE}, ${FRAMES}f, ${STEPS} steps, cfg2/8-card) ══════════════════════════"
printf "%-5s | %8s | %9s | %9s | %8s | %12s | %14s | %12s\n" \
    "task" "wall(s)" "infer(s)" "s/step" "peakMB" "tok/pass" "tot tok-pass" "tok/s(agg)"
echo "------+----------+-----------+-----------+----------+--------------+----------------+-------------"
while IFS='|' read -r tag task aw ai ps peak tok total thr geom; do
    [[ "$tag" == "RESULT" ]] || continue
    printf "%-5s | %8s | %9s | %9s | %8s | %12s | %14s | %12s\n" \
        "$task" "$aw" "$ai" "$ps" "$peak" "$tok" "$total" "$thr"
done < /tmp/wan_perf_results.txt
echo ""
echo "Notes:"
echo "  • Video response has no token field; 'tok/pass' = DiT latent seq length"
echo "    = T_lat×H_lat×W_lat (Wan2.2: VAE 8x/4x, patch (1,2,2) → H/16, W/16, (F-1)/4+1)."
echo "  • 'tot tok-pass' = tok/pass × steps × 2 (cfg cond+uncond). 'tok/s' = tot/infer."
echo "  • infer = server inference_time_s (warm-up excluded). wall includes HTTP/polling."
