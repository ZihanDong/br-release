#!/usr/bin/env bash
# run_suvs_tests.sh — run SUVS GPU tests with built-in GM monitoring
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# DEFAULT SETTINGS  (all overridable via CLI args)
# ═══════════════════════════════════════════════════════════════════════════════

CONTAINER_NAME="biren_suvs"

# Tasks to run. "all" runs every task in ALL_TASKS below.
# Multiple tasks: space- or comma-separated  (e.g. "pcie,membw,hbm0")
DEFAULT_TASKS="base"

# GPU IDs for test actions. "all" = conf default.  Specific: "0" or "0,1,2"
# GM monitoring always covers all GPUs regardless of this setting.
DEFAULT_GPU_IDS="all"

# Duration override in seconds. Empty string = each task's built-in default.
DEFAULT_DURATION=""

# Verbose mode: "true" adds -v flag to suvs
DEFAULT_VERBOSE="false"

# Log root relative to this script's directory
LOG_ROOT_REL="../../logs/suvs"

# ═══════════════════════════════════════════════════════════════════════════════
# TASK REGISTRY
# ═══════════════════════════════════════════════════════════════════════════════

declare -A TASK_DESC
TASK_DESC[pcie]="PCIe Bandwidth"
TASK_DESC[p2p]="P2P Bandwidth"
TASK_DESC[hbm0]="HBM Test0 [Walking 1 bit]"
TASK_DESC[hbm1]="HBM Test1 [Own address]"
TASK_DESC[hbm2]="HBM Test2 [Moving inversions 1s&0s]"
TASK_DESC[hbm3]="HBM Test3 [Moving inversions 8bit]"
TASK_DESC[hbm4]="HBM Test4 [Moving inversions random]"
TASK_DESC[hbm5]="HBM Test5 [Block move 64]"
TASK_DESC[hbm6]="HBM Test6 [Moving inversions 32bit]"
TASK_DESC[hbm7]="HBM Test7 [Random number sequence]"
TASK_DESC[hbm8]="HBM Test8 [Modulo 20 random]"
TASK_DESC[hbm9]="HBM Test9 [Bit fade 90min]"
TASK_DESC[hbm10]="HBM Test10 [Memory stress]"
TASK_DESC[membw]="Memory Bandwidth"
TASK_DESC[video]="Video Performance"
TASK_DESC[power_pct50]="Power Stress 50%"
TASK_DESC[power_idle]="Power Stress Idle"
TASK_DESC[spcstress_fp32]="SPC Stress fp32"
TASK_DESC[spcstress_int8]="SPC Stress int8"
TASK_DESC[spcstress_bf16]="SPC Stress bf16"
TASK_DESC[spcstress_tf32]="SPC Stress tf32"
TASK_DESC[spcstress_fp16]="SPC Stress fp16"
TASK_DESC[spcperf_fp32]="SPC Perf fp32"
TASK_DESC[spcperf_int8]="SPC Perf int8"
TASK_DESC[spcperf_bf16]="SPC Perf bf16"
TASK_DESC[spcperf_tf32]="SPC Perf tf32"
TASK_DESC[spcperf_fp16]="SPC Perf fp16"

# base: core daily tests (excludes hbm2-9 and video)
BASE_TASKS=(
    pcie p2p
    hbm0 hbm1 hbm10
    membw
    power_pct50 power_idle
    spcstress_fp32 spcstress_int8 spcstress_bf16 spcstress_tf32 spcstress_fp16
    spcperf_fp32   spcperf_int8   spcperf_bf16   spcperf_tf32   spcperf_fp16
)

# all: full suite including extended HBM patterns and video
ALL_TASKS=(
    pcie p2p
    hbm0 hbm1 hbm2 hbm3 hbm4 hbm5 hbm6 hbm7 hbm8 hbm9 hbm10
    membw video
    power_pct50 power_idle
    spcstress_fp32 spcstress_int8 spcstress_bf16 spcstress_tf32 spcstress_fp16
    spcperf_fp32   spcperf_int8   spcperf_bf16   spcperf_tf32   spcperf_fp16
)

# ═══════════════════════════════════════════════════════════════════════════════
# ARGUMENT PARSING
# ═══════════════════════════════════════════════════════════════════════════════

TASKS="$DEFAULT_TASKS"
GPU_IDS="$DEFAULT_GPU_IDS"
DURATION="$DEFAULT_DURATION"
VERBOSE="$DEFAULT_VERBOSE"

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --tasks TASK[,TASK...]   Tasks to run, comma or space separated.
                           Keywords: "base" (18 core tasks), "all" (full 25-task suite)
                           Available: ${ALL_TASKS[*]}
  --gpu-ids IDS            GPU IDs for test actions (e.g. "0" or "0,1,2"),
                           or "all" (default). GM monitoring always covers all GPUs.
  --duration SECS          Override duration in all tasks (seconds)
  --verbose                Enable suvs verbose output (-v)
  -h, --help               Show this help

Examples:
  $(basename "$0") --tasks base
  $(basename "$0") --tasks pcie,membw,hbm0
  $(basename "$0") --tasks all --duration 30 --gpu-ids 0
  $(basename "$0") --tasks "spcstress_fp32 spcperf_fp32" --verbose
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tasks)    TASKS="${2//,/ }";  shift 2 ;;
        --gpu-ids)  GPU_IDS="$2";       shift 2 ;;
        --duration) DURATION="$2";      shift 2 ;;
        --verbose)  VERBOSE="true";     shift   ;;
        -h|--help)  usage; exit 0       ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

[[ "$TASKS" == "all" ]]  && TASKS="${ALL_TASKS[*]}"
[[ "$TASKS" == "base" ]] && TASKS="${BASE_TASKS[*]}"

# ═══════════════════════════════════════════════════════════════════════════════
# SETUP
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "${SCRIPT_DIR}/${LOG_ROOT_REL}"
LOG_ROOT="$(cd "${SCRIPT_DIR}/${LOG_ROOT_REL}" && pwd)"

RUN_TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RUN_LOG_DIR="${LOG_ROOT}/suvs_${RUN_TIMESTAMP}"
mkdir -p "${RUN_LOG_DIR}"

SUMMARY_LOG="${RUN_LOG_DIR}/summary.log"
VERBOSE_FLAG=""
[[ "$VERBOSE" == "true" ]] && VERBOSE_FLAG="-v"

# suvs must run from its bin directory; conf paths are relative to it
SUVS_BIN="/usr/local/birensupa/sudcgm/latest/suvs/bin"
# Unique prefix for symlinks injected into the container's suvs bin/conf for this run
CONF_PREFIX="run_${RUN_TIMESTAMP}"

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "ERROR: Container '$CONTAINER_NAME' is not running. Run setup_suvs.sh first." >&2
    exit 1
fi

cleanup_confs() {
    docker exec "$CONTAINER_NAME" bash -c \
        "rm -f '${SUVS_BIN}/conf/${CONF_PREFIX}_'*.conf 2>/dev/null || true" 2>/dev/null || true
}
trap cleanup_confs EXIT

# ─── Helpers ─────────────────────────────────────────────────────────────────

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$SUMMARY_LOG"; }
hdr() {
    printf '\n%s\n' "$(printf '═%.0s' {1..72})" | tee -a "$SUMMARY_LOG"
    echo "  $*" | tee -a "$SUMMARY_LOG"
    printf '%s\n' "$(printf '═%.0s' {1..72})" | tee -a "$SUMMARY_LOG"
}

# _clamp_dur <task> <requested_dur> <min_dur>
# Returns the effective duration: if requested < min, warns (stderr) and returns min.
_clamp_dur() {
    local task="$1" req="${2:-}" min="${3:-90}"
    if [[ -n "$req" && "$req" =~ ^[0-9]+$ ]] && (( req < min )); then
        echo "WARNING: Task '${task}' requires duration >= ${min}s (suvs will error on shorter runs)." \
             "Requested ${req}s → using ${min}s." >&2
        echo "$min"
    else
        echo "${req:-$min}"
    fi
}

# generate_conf <task> <gpu_id> <duration_override>
# Writes the complete suvs YAML conf (wrapped with GM start/stop) to stdout.
generate_conf() {
    local task="$1"
    local gpu_id="${2:-all}"
    local dur="${3:-}"

    # GM start — always monitors all GPUs
    cat <<'YAML'
actions:
- name: gm_start
  gpu_id: all
  plugin: gm
  core_clock: true
  mem_clock: true
  temperature: true
  power: true
  monitor: true
  monitor_interval: 1000
YAML

    # Test-specific action(s)
    case "$task" in
        pcie)
            local d="${dur:-5}"
            cat <<YAML
- name: test_pciebw
  gpu_id: ${gpu_id}
  plugin: pciebw
  device_to_host: true
  host_to_device: true
  pinned: true
  duration: ${d}
YAML
            ;;
        p2p)
            local d="${dur:-5}"
            cat <<YAML
- name: test_p2p
  gpu_id: ${gpu_id}
  plugin: p2p
  peers: all
  duration: ${d}
YAML
            ;;
        hbm[0-9]|hbm10)
            local test_num="${task#hbm}"
            local d="${dur:-5}"
            cat <<YAML
- name: test_hbm${test_num}
  gpu_id: ${gpu_id}
  plugin: hbm
  duration: ${d}
  block_num: 1024
  test: ${test_num}
YAML
            ;;
        membw)
            local d; d="$(_clamp_dur "$task" "$dur" 90)"
            cat <<YAML
- name: test_membw
  gpu_id: ${gpu_id}
  plugin: membw
  duration: ${d}
YAML
            ;;
        video)
            # video plugin uses file paths and times, not duration or gpu_id
            cat <<'YAML'
- name: jpeg_decode_single_channel_test
  plugin: video
  channel_num: 1
  times: 100
  compare: 1
  channel_paths: "/tmp/video_samples/dec_jpeg/vectors/ch_00007fff78022590/"
- name: jpeg_decode_multi_channels_test
  plugin: video
  channel_num: 16
  times: 100
  compare: 1
  channel_paths_root: "/tmp/video_samples/dec_jpeg/vectors/"
YAML
            ;;
        power_pct50)
            local d; d="$(_clamp_dur "$task" "$dur" 90)"
            cat <<YAML
- name: test_power_pct50
  gpu_id: ${gpu_id}
  plugin: spcpower
  duration: ${d}
  power_pct: 50
YAML
            ;;
        power_idle)
            local d; d="$(_clamp_dur "$task" "$dur" 90)"
            cat <<YAML
- name: test_power_idle
  gpu_id: ${gpu_id}
  plugin: spcpower
  duration: ${d}
  power_test_idle: true
  idle_power_max: 80
  idle_power_min: 30
YAML
            ;;
        spcstress_*)
            local stype="${task#spcstress_}"
            local d; d="$(_clamp_dur "$task" "$dur" 90)"
            cat <<YAML
- name: test_spcstress_${stype}
  gpu_id: ${gpu_id}
  plugin: spcstress
  duration: ${d}
  type: ${stype}
  replicate: true
YAML
            ;;
        spcperf_*)
            local stype="${task#spcperf_}"
            local d; d="$(_clamp_dur "$task" "$dur" 90)"
            cat <<YAML
- name: test_spcperf_${stype}
  gpu_id: ${gpu_id}
  plugin: spcperf
  duration: ${d}
  type: ${stype}
  replicate: true
YAML
            ;;
    esac

    # GM stop
    cat <<'YAML'
- name: gm_stop
  gpu_id: all
  plugin: gm
  monitor: false
  monitor_interval: 1000
YAML
}

# write_conf <task>
# Generates conf → saves to RUN_LOG_DIR/<task>.conf (authoritative copy),
# symlinks into container's suvs bin/conf for path resolution.
# Echoes the relative path suvs expects (conf/<name>.conf).
write_conf() {
    local task="$1"
    local conf_name="${CONF_PREFIX}_${task}.conf"
    local log_conf="${RUN_LOG_DIR}/${task}.conf"
    local suvs_conf="${SUVS_BIN}/conf/${conf_name}"

    generate_conf "$task" "$GPU_IDS" "$DURATION" > "$log_conf"
    docker exec "$CONTAINER_NAME" bash -c "ln -sf '${log_conf}' '${suvs_conf}'"
    echo "conf/${conf_name}"
}

# extract_summary <task_log_file>
extract_summary() {
    local log_file="$1"
    [[ -f "$log_file" ]] || { echo "(no log)"; return; }
    local block
    block="$(grep -A 50 "Test result summary" "$log_file" 2>/dev/null || true)"
    if [[ -n "$block" ]]; then echo "$block"; return; fi
    grep -iE '\[(Test Pass|Test Fail|PASS|FAIL)\]' "$log_file" 2>/dev/null | tail -10 \
        || tail -5 "$log_file"
}

# extract_gpu_stats <log_file> <gpu_ids>
# Parses [gm_start] monitoring lines; filters to active GPUs (per gpu_ids);
# prints a per-GPU averages table plus cross-GPU average row to stdout.
extract_gpu_stats() {
    local log_file="$1"
    local gpu_ids="${2:-all}"

    [[ -f "$log_file" ]] || return 0
    grep -q '\[gm_start\] gm, gpu' "$log_file" 2>/dev/null || return 0

    awk -v gpu_ids="$gpu_ids" '
BEGIN {
    use_all = (gpu_ids == "all")
    if (!use_all) {
        n = split(gpu_ids, gtmp, /[, ]+/)
        for (i = 1; i <= n; i++) allowed[gtmp[i]] = 1
    }
    ngpus = 0; nkeys = 0
}
/\[gm_start\] gm, gpu[0-9]+:/ {
    pos = index($0, "gm, gpu")
    if (!pos) next
    rest = substr($0, pos + 7)
    match(rest, /^[0-9]+/)
    if (RLENGTH <= 0) next
    gid = substr(rest, 1, RLENGTH)

    if (!use_all && !(gid in allowed)) next

    if (!(gid in gid_seen)) {
        gid_seen[gid] = 1
        gpu_arr[ngpus++] = gid
    }

    prefix = "gm, gpu" gid ": "
    mstart = index($0, prefix)
    if (!mstart) next
    mstr = substr($0, mstart + length(prefix))
    # Skip lines where metrics portion is not valid (e.g. debug output mixed in)
    if (mstr !~ /^[a-zA-Z0-9_-]+:[0-9]/) next

    nf = split(mstr, flds, /; ?/)
    for (i = 1; i <= nf; i++) {
        f = flds[i]
        gsub(/^[ \t]+/, "", f); gsub(/[ \t;]+$/, "", f)
        if (f == "") continue
        ci = index(f, ":")
        if (!ci) continue
        key = substr(f, 1, ci - 1)
        # Skip fields with non-standard key names (e.g. from interleaved debug output)
        if (key !~ /^[a-zA-Z0-9_][-a-zA-Z0-9_]*$/) continue
        vraw = substr(f, ci + 1)
        num = vraw + 0
        match(vraw, /^[0-9]+/)
        unit = (RLENGTH > 0) ? substr(vraw, RLENGTH + 1) : ""
        gsub(/[; \t]+$/, "", unit)

        idx = gid SUBSEP key
        sum_v[idx] += num
        cnt_v[idx]++
        if (!(key in key_seen)) {
            key_seen[key] = 1
            key_arr[nkeys++] = key
        }
        if (!(key in unit_map)) unit_map[key] = unit
    }
}
END {
    if (ngpus == 0) exit
    cw0 = 10; cw = 10
    printf "  GPU Stats (active GPUs, averaged over monitoring period):\n"
    hdr = sprintf("  %-*s", cw0, "GPU")
    for (ki = 0; ki < nkeys; ki++) {
        k = key_arr[ki]; d = k
        if (d == "core_clock")         d = "core_clk"
        if (d == "mem_clock")          d = "mem_clk"
        if (d == "pcie_link_speed")    d = "pcie_spd"
        if (d == "pcie_replay_count")  d = "replay"
        if (d == "gpu_temp")           d = "temp"
        if (d == "1-bit_ecc")          d = "ecc1b"
        if (d == "2-bit_ecc")          d = "ecc2b"
        hdr = hdr sprintf("  %-*s", cw, d)
    }
    totw = cw0 + nkeys * (cw + 2)
    sep = "  "; for (j = 0; j < totw; j++) sep = sep "-"
    printf "%s\n%s\n", hdr, sep
    for (gi = 0; gi < ngpus; gi++) {
        gid = gpu_arr[gi]
        row = sprintf("  %-*s", cw0, "gpu" gid)
        for (ki = 0; ki < nkeys; ki++) {
            k = key_arr[ki]
            idx = gid SUBSEP k
            if ((idx in sum_v) && cnt_v[idx] > 0) {
                avg = sum_v[idx] / cnt_v[idx]
                u = unit_map[k]
                cell = (avg == int(avg)) ? sprintf("%d%s", int(avg), u) \
                                         : sprintf("%.1f%s", avg, u)
            } else { cell = "N/A" }
            row = row sprintf("  %-*s", cw, cell)
        }
        printf "%s\n", row
    }
    if (ngpus > 1) {
        printf "%s\n", sep
        row = sprintf("  %-*s", cw0, "-- avg --")
        for (ki = 0; ki < nkeys; ki++) {
            k = key_arr[ki]; total = 0; valid = 0
            for (gi = 0; gi < ngpus; gi++) {
                idx = gpu_arr[gi] SUBSEP k
                if ((idx in sum_v) && cnt_v[idx] > 0) {
                    total += sum_v[idx] / cnt_v[idx]; valid++
                }
            }
            if (valid > 0) {
                avg = total / valid
                u = unit_map[k]
                cell = (avg == int(avg)) ? sprintf("%d%s", int(avg), u) \
                                         : sprintf("%.1f%s", avg, u)
            } else { cell = "N/A" }
            row = row sprintf("  %-*s", cw, cell)
        }
        printf "%s\n", row
    }
    printf "\n"
}
' "$log_file"
}

# ═══════════════════════════════════════════════════════════════════════════════
# RUN TASKS
# ═══════════════════════════════════════════════════════════════════════════════

hdr "SUVS Test Run — ${RUN_TIMESTAMP}"
log "Container  : ${CONTAINER_NAME}"
log "Tasks      : ${TASKS}"
log "GPU IDs    : ${GPU_IDS}"
log "Duration   : ${DURATION:-<task default>}"
log "Verbose    : ${VERBOSE}"
log "Log dir    : ${RUN_LOG_DIR}"

declare -A TASK_STATUS
declare -A TASK_SUMMARY

for task in $TASKS; do
    if [[ -z "${TASK_DESC[$task]+set}" ]]; then
        log "WARNING: Unknown task '$task', skipping."
        continue
    fi

    desc="${TASK_DESC[$task]}"
    task_log="${RUN_LOG_DIR}/${task}.log"
    rel_conf="$(write_conf "$task")"

    hdr "Task: ${task} — ${desc}"
    log "Conf       : ${RUN_LOG_DIR}/${task}.conf"
    log "Task log   : ${task_log}"

    set +e
    docker exec "$CONTAINER_NAME" bash -c "
        source /usr/local/birensupa/sudcgm/latest/scripts/brsw_set_env.sh 2>/dev/null || true
        cd '${SUVS_BIN}'
        suvs -c '${rel_conf}' ${VERBOSE_FLAG} -d 3 2>&1
    " | tee "$task_log"
    SUVS_RC=${PIPESTATUS[0]}
    set -e

    if [[ $SUVS_RC -eq 0 ]]; then
        TASK_STATUS[$task]="PASS"
    else
        TASK_STATUS[$task]="FAIL (exit $SUVS_RC)"
    fi
    TASK_SUMMARY[$task]="$(extract_summary "$task_log")"
    log "Task '${task}' finished — ${TASK_STATUS[$task]}"
done

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY REPORT
# ═══════════════════════════════════════════════════════════════════════════════

{
printf '\n%s\n' "$(printf '═%.0s' {1..72})"
printf '  SUVS Test Summary — %s\n' "$RUN_TIMESTAMP"
printf '%s\n\n' "$(printf '═%.0s' {1..72})"

for task in $TASKS; do
    [[ -z "${TASK_DESC[$task]+set}" ]] && continue
    status="${TASK_STATUS[$task]:-SKIPPED}"
    desc="${TASK_DESC[$task]}"
    printf '%-20s  %-12s  %s\n' "$task" "$status" "$desc"
    if [[ -n "${TASK_SUMMARY[$task]:-}" ]]; then
        while IFS= read -r line; do
            printf '  %s\n' "$line"
        done <<< "${TASK_SUMMARY[$task]}"
    fi
    extract_gpu_stats "${RUN_LOG_DIR}/${task}.log" "$GPU_IDS"
    printf '\n'
done

printf '%s\n' "$(printf '─%.0s' {1..72})"
printf 'Full logs: %s\n' "$RUN_LOG_DIR"
} | tee -a "$SUMMARY_LOG"

echo ""
echo "Summary written to: $SUMMARY_LOG"
