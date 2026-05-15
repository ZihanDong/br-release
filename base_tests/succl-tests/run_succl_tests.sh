#!/usr/bin/env bash
# run_succl_tests.sh — 在 biren_succl_tests 容器内执行 succl-tests 通信性能测试
#
# 用法:
#   ./run_succl_tests.sh [-v] <mode> <op> <gpus>
#
# 参数说明:
#   -v      可选。详细模式：测试输出同时打印到终端和日志文件
#   mode    single | multi
#             single: 单节点，所有 GPU 在同一容器内
#             multi : 多节点，通过 mpiexec + SSH 免密跨容器调度
#   op      算子名称，支持:
#             allreduce | allgather | alltoall | alltoallv | broadcast |
#             gather | hypercube | reduce | reducescatter | scatter | sendrecv
#             all  — 依次执行以上全部算子
#   gpus    GPU 数量（single: 本节点总卡数；multi: 每节点卡数）
#
# 示例:
#   ./run_succl_tests.sh single allreduce 8       # 单节点 allreduce，8 卡
#   ./run_succl_tests.sh -v single all 8          # 单节点全算子，终端实时输出
#   ./run_succl_tests.sh multi allreduce 8        # 多节点 allreduce，每节点 8 卡
#
# 日志:
#   每次运行在 LOG_PATH 下创建 succl-tests_<时间戳>/ 目录，包含:
#     <op>.log      — 首行为完整执行命令，其后为测试全量输出
#     summary.log   — 汇总各算子结果及峰值带宽（AlgBW / BusBW / 数据量 / 精度）
#
# 前提条件:
#   已通过 setup_succl-tests.sh 完成容器初始化（/etc/succl-hw.conf 需存在）
#
# 多节点附加配置（脚本顶部变量）:
#   MPI_HOSTS   必填，格式: "<ip1>:<slots>,<ip2>:<slots>"，如 "10.9.1.10:8,10.9.1.11:8"
#   MPI_IFACE   MPI TCP 网卡，留空则排除 lo，或填具体网卡名如 "ens110f0"
#   SSH_PORT    与 setup_succl-tests.sh 中配置一致（默认 2222）
#   ./run_succl_tests.sh multi allreduce 8
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# Default variables — edit these to match your environment
# ═══════════════════════════════════════════════════════════════════════════════

CONTAINER_NAME="biren_succl_tests"
SUCCL_BIN_DIR="/opt/succl-tests/bin"

# ── Logging ───────────────────────────────────────────────────────────────────
# Override via: LOG_PATH=/your/path ./run_succl_tests.sh ...
LOG_PATH="${LOG_PATH:-/home/zanedong/br-release/logs/suvs}"

# ── Data range ────────────────────────────────────────────────────────────────
MIN_BYTES="512"         # minimum message size in bytes; must be 512-aligned
MAX_BYTES="1G"          # maximum message size; e.g. 512, 1M, 4G
STEP_FACTOR="2"         # size multiplier between steps (used when STEP_BYTES=0)
STEP_BYTES="0"          # fixed byte increment between steps; 0 = use STEP_FACTOR

# ── suCCL operation parameters ────────────────────────────────────────────────
REDUCE_OP="sum"         # reduce op for AllReduce/Reduce/ReduceScatter: sum|prod|min|max|avg|all
DATATYPE="float"        # data type: float | BF16

# ── Performance parameters ────────────────────────────────────────────────────
ITERS="3"               # timed iteration count; keep small to avoid OOM (range: 1–20)
WARMUP_ITERS="3"        # warmup iterations, not timed (range: 0–10)
AGG_ITERS="1"           # operations aggregated per iteration (range: 1–N)
AVERAGE="1"             # bandwidth reporting: 0=Rank0 1=Avg 2=Min 3=Max

# ── Correctness check ─────────────────────────────────────────────────────────
CHECK="1"               # verify results: 0=skip (faster) | 1=check (may be slow with many GPUs)

# ── Misc test options ─────────────────────────────────────────────────────────
BLOCKING="0"            # blocking mode: 0=async | 1=blocking
BR_P2P_CHECK="0"        # BR_UMD_DEBUG_P2P_ACCESS_CHECK: 0=disabled (required for 壁砺106B/C)

# ── BR166-specific ────────────────────────────────────────────────────────────
# "auto" reads GPU_MODEL from /etc/succl-hw.conf written by setup_succl-tests.sh;
# override with 0 or 1 to force-disable or force-enable BR166 UMA16 mode (-k 1)
BR166_MODE="auto"

# ── Multi-node settings (ignored in single mode) ──────────────────────────────
SSH_PORT="2222"                         # sshd port configured in each container
MPI_IFACE=""                            # network interface for MPI TCP transport;
                                        #   leave empty to auto-exclude lo only
                                        #   example: "ens110f0"
# Host list: comma-separated <ip>:<slots> pairs; slots = GPUs per node
# Example: "10.9.1.10:8,10.9.1.11:8"
MPI_HOSTS=""

# SUCCL_BUFFSIZE: required for 4+ nodes with SendRecv/Gather/Scatter/Hypercube/
#   Alltoall/Alltoallv to reach max data size; set to 16777216 (16 MB) if needed
SUCCL_BUFFSIZE=""       # e.g. "16777216"; leave empty to use library default

# ═══════════════════════════════════════════════════════════════════════════════
# Argument parsing
# ═══════════════════════════════════════════════════════════════════════════════

usage() {
    grep '^# ' "$0" | head -14 | sed 's/^# \?//'
    exit 1
}

VERBOSE=0
if [[ "${1:-}" == "-v" ]]; then
    VERBOSE=1
    shift
fi

[[ $# -ne 3 ]] && { echo "ERROR: expected exactly 3 arguments (after optional -v)."; usage; }

MODE="$1"
OP="$2"
GPUS="$3"

case "$MODE" in
    single|multi) ;;
    *) echo "ERROR: mode must be 'single' or 'multi', got: $MODE"; usage ;;
esac

if ! [[ "$GPUS" =~ ^[0-9]+$ ]] || [[ "$GPUS" -lt 1 ]]; then
    echo "ERROR: gpus must be a positive integer, got: $GPUS"; exit 1
fi

# Map operator name → binary
declare -A OP_BINARY=(
    [allreduce]="all_reduce_perf"
    [allgather]="all_gather_perf"
    [alltoall]="alltoall_perf"
    [alltoallv]="alltoallv_perf"
    [broadcast]="broadcast_perf"
    [gather]="gather_perf"
    [hypercube]="hypercube_perf"
    [reduce]="reduce_perf"
    [reducescatter]="reduce_scatter_perf"
    [scatter]="scatter_perf"
    [sendrecv]="sendrecv_perf"
)

ALL_OPS=(allreduce allgather alltoall alltoallv broadcast gather hypercube reduce reducescatter scatter sendrecv)

if [[ "$OP" == "all" ]]; then
    RUN_OPS=("${ALL_OPS[@]}")
elif [[ -v OP_BINARY["$OP"] ]]; then
    RUN_OPS=("$OP")
else
    echo "ERROR: unknown operator '$OP'. Valid: all ${ALL_OPS[*]}"
    exit 1
fi

if [[ "$MODE" == "multi" && -z "$MPI_HOSTS" ]]; then
    echo "ERROR: MPI_HOSTS must be set for multi-node mode." >&2
    echo "  Edit the MPI_HOSTS variable at the top of this script." >&2
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Logging setup
# ═══════════════════════════════════════════════════════════════════════════════

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="${LOG_PATH}/succl-tests_${TIMESTAMP}"
mkdir -p "$LOG_DIR"

# Helper: append command output to file, optionally also to terminal
log_run() {
    local log_file="$1"
    shift
    if [[ "$VERBOSE" -eq 1 ]]; then
        "$@" 2>&1 | tee -a "$log_file"
    else
        "$@" >>"$log_file" 2>&1
    fi
}

# Parse the peak out-of-place AlgBW row from a succl-tests log file.
# Outputs: "<size_human> <type> <algbw> GB/s  busbw <busbw> GB/s"
parse_peak_bw() {
    local log_file="$1"
    awk '
    BEGIN { algbw_col=0; busbw_col=0; max_algbw=-1 }
    # Detect column positions from the header line that contains "Algbw"
    /^#.*Algbw/ && algbw_col==0 {
        for (i=1; i<=NF; i++) {
            if ($i=="Algbw" && algbw_col==0) algbw_col=i
            if ($i=="Busbw" && busbw_col==0) busbw_col=i
        }
    }
    # Data lines — same column numbering as header (both have a leading symbol)
    /^\*/ && algbw_col>0 {
        val = $algbw_col+0
        if (val > max_algbw) {
            max_algbw = val
            max_busbw = $busbw_col+0
            max_bytes = $2+0
            max_type  = $4
        }
    }
    END {
        if (max_algbw < 0) { print "N/A"; exit }
        # human-readable size
        if      (max_bytes >= 1073741824) size = sprintf("%.0f GiB", max_bytes/1073741824)
        else if (max_bytes >= 1048576)    size = sprintf("%.0f MiB", max_bytes/1048576)
        else if (max_bytes >= 1024)       size = sprintf("%.0f KiB", max_bytes/1024)
        else                              size = sprintf("%d B",      max_bytes)
        printf "algbw %6.2f GB/s  busbw %6.2f GB/s  @ %-8s %s\n", \
               max_algbw, max_busbw, size, max_type
    }
    ' "$log_file"
}

echo "Logs → ${LOG_DIR}"

# ═══════════════════════════════════════════════════════════════════════════════
# Resolve BR166_MODE
# ═══════════════════════════════════════════════════════════════════════════════

if [[ "$BR166_MODE" == "auto" ]]; then
    HW_CONF=$(docker exec "$CONTAINER_NAME" cat /etc/succl-hw.conf 2>/dev/null || true)
    if echo "$HW_CONF" | grep -q "BR166_MODE=1"; then
        BR166_MODE="1"
        GPU_MODEL=$(echo "$HW_CONF" | grep "^GPU_MODEL=" | cut -d= -f2)
        echo "[HW] Auto-detected ${GPU_MODEL} → BR166 mode enabled (-k 1)"
    else
        BR166_MODE="0"
        echo "[HW] Auto-detected non-BR166 GPU → standard mode"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Build common succl-tests flags
# ═══════════════════════════════════════════════════════════════════════════════

SUCCL_ARGS=(
    -b "$MIN_BYTES"
    -e "$MAX_BYTES"
    -d "$DATATYPE"
    -o "$REDUCE_OP"
    -n "$ITERS"
    -w "$WARMUP_ITERS"
    -m "$AGG_ITERS"
    -a "$AVERAGE"
    -c "$CHECK"
    -z "$BLOCKING"
)
[[ "$STEP_BYTES" -gt 0 ]] && SUCCL_ARGS+=(-i "$STEP_BYTES") \
                           || SUCCL_ARGS+=(-f "$STEP_FACTOR")
[[ "$BR166_MODE" == "1" ]] && SUCCL_ARGS+=(-k 1)

MPI_ENV_ARGS=(-x "BR_UMD_DEBUG_P2P_ACCESS_CHECK=${BR_P2P_CHECK}")
[[ -n "$SUCCL_BUFFSIZE" ]] && MPI_ENV_ARGS+=(-x "SUCCL_BUFFSIZE=${SUCCL_BUFFSIZE}")

# ═══════════════════════════════════════════════════════════════════════════════
# Run tests
# ═══════════════════════════════════════════════════════════════════════════════

run_op() {
    local op="$1"
    local binary="${OP_BINARY[$op]}"
    local bin_path="${SUCCL_BIN_DIR}/${binary}"
    local log_file="${LOG_DIR}/${op}.log"

    # Build the full mpiexec command string for logging
    local cmd
    if [[ "$MODE" == "single" ]]; then
        cmd="docker exec ${CONTAINER_NAME} bash -lc \
\"mpiexec --allow-run-as-root -n ${GPUS} ${MPI_ENV_ARGS[*]} ${bin_path} ${SUCCL_ARGS[*]}\""
    else
        local iface_arg
        if [[ -n "$MPI_IFACE" ]]; then
            iface_arg="--mca btl_tcp_if_include ${MPI_IFACE}"
        else
            iface_arg="--mca btl_tcp_if_exclude lo"
        fi
        cmd="docker exec ${CONTAINER_NAME} bash -lc \
\"mpiexec --allow-run-as-root --mca pml ^ucx ${iface_arg} \
--mca plm_rsh_args \\\"-p ${SSH_PORT}\\\" --host ${MPI_HOSTS} \
${MPI_ENV_ARGS[*]} -x LD_LIBRARY_PATH ${bin_path} ${SUCCL_ARGS[*]}\""
    fi

    # Write log header — command on line 1, then metadata
    {
        echo "# CMD: ${cmd}"
        echo "# ================================================================"
        echo "# operator : ${op}"
        echo "# binary   : ${binary}"
        echo "# mode     : ${MODE}   gpus: ${GPUS}"
        echo "# started  : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# ================================================================"
        echo ""
    } > "$log_file"

    local status_msg
    if [[ "$VERBOSE" -eq 1 ]]; then
        echo ""
        echo "━━━ ${op} ━━━"
        echo "CMD: ${cmd}"
        echo ""
    else
        printf "  %-16s → %s  " "$op" "$log_file"
    fi

    local rc=0
    if [[ "$MODE" == "single" ]]; then
        log_run "$log_file" \
            docker exec "$CONTAINER_NAME" bash -lc \
            "mpiexec --allow-run-as-root \
             -n ${GPUS} \
             ${MPI_ENV_ARGS[*]} \
             ${bin_path} ${SUCCL_ARGS[*]}" || rc=$?
    else
        local iface_arg
        if [[ -n "$MPI_IFACE" ]]; then
            iface_arg="--mca btl_tcp_if_include ${MPI_IFACE}"
        else
            iface_arg="--mca btl_tcp_if_exclude lo"
        fi
        log_run "$log_file" \
            docker exec "$CONTAINER_NAME" bash -lc \
            "mpiexec --allow-run-as-root \
             --mca pml ^ucx \
             ${iface_arg} \
             --mca plm_rsh_args \"-p ${SSH_PORT}\" \
             --host ${MPI_HOSTS} \
             ${MPI_ENV_ARGS[*]} \
             -x LD_LIBRARY_PATH \
             ${bin_path} ${SUCCL_ARGS[*]}" || rc=$?
    fi

    # Append finish timestamp and status to log
    {
        echo ""
        echo "# finished : $(date '+%Y-%m-%d %H:%M:%S')   exit_code: ${rc}"
    } >> "$log_file"

    if [[ "$VERBOSE" -eq 0 ]]; then
        [[ $rc -eq 0 ]] && echo "OK" || echo "FAILED (exit ${rc})"
    fi

    return $rc
}

# ─── Header summary ───────────────────────────────────────────────────────────
SUMMARY_FILE="${LOG_DIR}/summary.log"
{
    echo "succl-tests run summary"
    echo "started  : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "mode     : ${MODE}   op: ${OP}   gpus: ${GPUS}"
    echo "log_dir  : ${LOG_DIR}"
    echo ""
} > "$SUMMARY_FILE"

echo "=== succl-tests: mode=${MODE}  op=${OP}  gpus=${GPUS} ==="
[[ "$VERBOSE" -eq 0 ]] && echo "  (run with -v to also show output on terminal)"

FAILED_OPS=()
for op in "${RUN_OPS[@]}"; do
    run_op "$op" || FAILED_OPS+=("$op")
    local_status=$( [[ " ${FAILED_OPS[*]} " == *" ${op} "* ]] && echo "FAILED" || echo "OK" )
    peak=$( [[ "$local_status" == "OK" ]] && parse_peak_bw "${LOG_DIR}/${op}.log" || echo "—" )
    printf "  %-16s %s   %s\n" "${op}:" "$local_status" "$peak" >> "$SUMMARY_FILE"
done

# ─── Final summary ────────────────────────────────────────────────────────────
echo ""
{
    echo ""
    echo "finished : $(date '+%Y-%m-%d %H:%M:%S')"
    if [[ ${#FAILED_OPS[@]} -eq 0 ]]; then
        echo "result   : ALL PASSED"
    else
        echo "result   : FAILED ops: ${FAILED_OPS[*]}"
    fi
} | tee -a "$SUMMARY_FILE"

echo "Logs saved to: ${LOG_DIR}"

[[ ${#FAILED_OPS[@]} -eq 0 ]]
