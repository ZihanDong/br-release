#!/usr/bin/env bash
# run_succl_tests.sh — 在 biren_succl_tests 容器内执行 succl-tests 通信性能测试
#
# 用法:
#   ./run_succl_tests.sh [-v] --config <run.conf> [--config <run2.conf> ...]
#                        [--general <general.conf>] [--multi-config <multi-node.conf>]
#
# 参数说明:
#   -v                    可选。详细模式：测试输出同时打印到终端和日志文件
#   --config <file>       必填，可重复。运行配置文件（INI 格式，每个 [section] 为一组测试）
#   --general <file>      可选。通用配置文件（默认: <script_dir>/configs/general.conf）
#   --multi-config <file> 可选。多节点配置文件（默认: <script_dir>/configs/multi-node.conf）
#
# 运行配置文件格式（每个 [section] 定义一组测试）:
#   [section_name]
#   mode        = single | multi
#   ops         = allreduce [allgather ...] | all
#   gpus        = <int>        # single: 本节点总卡数; multi: 每节点卡数
#   min_bytes   = 512          # 可选，覆盖默认值
#   max_bytes   = 1G           # 可选，覆盖默认值
#   step_bytes  = 0            # 可选，0=使用 step_factor
#   step_factor = 2            # 可选
#
# 日志:
#   每次运行在 LOG_PATH 下创建 succl-tests_<时间戳>/ 目录，包含:
#     <section>_<op>.log  — 首行为完整执行命令，其后为测试全量输出
#     <section>_<op>.sh   — 可直接执行的等价 shell 脚本（在本机运行即可）
#     summary.log         — 汇总各组各算子结果及峰值带宽
#
# 前提条件:
#   已通过 setup_succl-tests.sh 完成容器初始化（/etc/succl-hw.conf 需存在）
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# Fixed settings — do not expose to config files
# ═══════════════════════════════════════════════════════════════════════════════

CONTAINER_NAME="biren_succl_tests"
SUCCL_BIN_DIR="/opt/succl-tests/bin"

# §3.3.1: nthreads(-t) 和 ngpus(-G) 仅支持1，写死在此处不透传到配置文件
readonly FIXED_NTHREADS=1
readonly FIXED_NGPUS=1

# ─── Logging ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_PATH="${LOG_PATH:-${SCRIPT_DIR}/../../logs/succl-tests}"

# ═══════════════════════════════════════════════════════════════════════════════
# General config defaults (overridden by general.conf)
# ═══════════════════════════════════════════════════════════════════════════════

# §3.3.3 suCCL 操作参数
REDUCE_OP="sum"
DATATYPE="float"
ROOT="0"
# §3.3.4 性能相关参数
ITERS="3"
WARMUP_ITERS="3"
AGG_ITERS="1"
AVERAGE="1"
# §3.3.5 测试选项
PARALLEL_INIT="0"
CHECK="1"
BLOCKING="0"
SUPAGRAPH="0"
# 硬件相关
BR_P2P_CHECK="0"
BR166_MODE="auto"

# ═══════════════════════════════════════════════════════════════════════════════
# Multi-node config defaults (overridden by multi-node.conf)
# ═══════════════════════════════════════════════════════════════════════════════

SSH_PORT="2222"
MPI_IFACE_INCLUDE=""
MPI_IFACE_EXCLUDE="lo"
SUCCL_BUFFSIZE=""
MULTI_NODE_IPS=()

# ═══════════════════════════════════════════════════════════════════════════════
# Argument parsing
# ═══════════════════════════════════════════════════════════════════════════════

usage() {
    grep '^# ' "$0" | head -22 | sed 's/^# \?//'
    exit 1
}

VERBOSE=0
GENERAL_CONF="${SCRIPT_DIR}/configs/general.conf"
MULTI_CONF="${SCRIPT_DIR}/configs/multi-node.conf"
RUN_CONFIGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v)               VERBOSE=1; shift ;;
        --config)         [[ $# -lt 2 ]] && { echo "ERROR: --config requires a file argument"; exit 1; }
                          RUN_CONFIGS+=("$2"); shift 2 ;;
        --general)        [[ $# -lt 2 ]] && { echo "ERROR: --general requires a file argument"; exit 1; }
                          GENERAL_CONF="$2"; shift 2 ;;
        --multi-config)   [[ $# -lt 2 ]] && { echo "ERROR: --multi-config requires a file argument"; exit 1; }
                          MULTI_CONF="$2"; shift 2 ;;
        -h|--help)        usage ;;
        *)                echo "ERROR: unknown argument: $1" >&2; usage ;;
    esac
done

[[ ${#RUN_CONFIGS[@]} -eq 0 ]] && {
    echo "ERROR: at least one --config <file> is required." >&2
    usage
}

# ─── Load general config ──────────────────────────────────────────────────────
[[ -f "$GENERAL_CONF" ]] || {
    echo "ERROR: general config not found: $GENERAL_CONF" >&2
    exit 1
}
# shellcheck source=/dev/null
source "$GENERAL_CONF"

# ─── Load multi-node config (optional at startup; required when mode=multi) ───
MULTI_CONF_LOADED=0
if [[ -f "$MULTI_CONF" ]]; then
    # shellcheck source=/dev/null
    source "$MULTI_CONF"
    MULTI_CONF_LOADED=1
fi

# ─── Validate run config files exist ─────────────────────────────────────────
for conf in "${RUN_CONFIGS[@]}"; do
    [[ -f "$conf" ]] || { echo "ERROR: run config not found: $conf" >&2; exit 1; }
done

# ═══════════════════════════════════════════════════════════════════════════════
# Operator → binary mapping
# ═══════════════════════════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════════════════════════
# INI config parsing helpers
# ═══════════════════════════════════════════════════════════════════════════════

# List all [section] names in an INI file, one per line
ini_sections() {
    grep -E '^\[[^]]+\]' "$1" | sed 's/^\[//;s/\]//'
}

# Get the value of key within a named section; print $default if not found
ini_get() {
    local file="$1" section="$2" key="$3" default="${4:-}"
    local val
    val=$(awk -v sec="[$section]" -v k="$key" '
        $0 == sec       { in_s=1; next }
        in_s && /^\[/   { in_s=0 }
        in_s {
            sub(/#.*/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            if (!length($0)) next
            eq = index($0, "=")
            if (eq > 0) {
                lhs = substr($0, 1, eq-1)
                gsub(/[[:space:]]/, "", lhs)
                if (lhs == k) {
                    val = substr($0, eq+1)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
                    print val; exit
                }
            }
        }
    ' "$file")
    echo "${val:-$default}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Logging helpers
# ═══════════════════════════════════════════════════════════════════════════════

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_DIR="${LOG_PATH}/succl-tests_${TIMESTAMP}"
mkdir -p "$LOG_DIR"

log_run() {
    local log_file="$1"; shift
    if [[ "$VERBOSE" -eq 1 ]]; then
        "$@" 2>&1 | tee -a "$log_file"
    else
        "$@" >>"$log_file" 2>&1
    fi
}

# Parse peak out-of-place AlgBW from a succl-tests log file
parse_peak_bw() {
    local log_file="$1"
    awk '
    BEGIN { algbw_col=0; busbw_col=0; max_algbw=-1 }
    /^#.*Algbw/ && algbw_col==0 {
        for (i=1; i<=NF; i++) {
            if ($i=="Algbw" && algbw_col==0) algbw_col=i
            if ($i=="Busbw" && busbw_col==0) busbw_col=i
        }
    }
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
        if      (max_bytes >= 1073741824) size = sprintf("%.0f GiB", max_bytes/1073741824)
        else if (max_bytes >= 1048576)    size = sprintf("%.0f MiB", max_bytes/1048576)
        else if (max_bytes >= 1024)       size = sprintf("%.0f KiB", max_bytes/1024)
        else                              size = sprintf("%d B",      max_bytes)
        printf "algbw %6.2f GB/s  busbw %6.2f GB/s  @ %-8s %s\n", \
               max_algbw, max_busbw, size, max_type
    }
    ' "$log_file"
}

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
# Core: run one (section, op) test
# ═══════════════════════════════════════════════════════════════════════════════
#
# Globals consumed (set by process_section before calling):
#   CURR_INNER_CMD   — full mpiexec command string for bash -lc
#   CURR_MODE        — single | multi
#   CURR_GPUS        — GPU count

run_section_op() {
    local section="$1" op="$2"
    local binary="${OP_BINARY[$op]}"
    local log_file="${LOG_DIR}/${section}_${op}.log"
    local sh_file="${LOG_DIR}/${section}_${op}.sh"

    # ── Write executable shell script BEFORE running ──────────────────────────
    # Single-quote the inner command; our commands never contain single quotes.
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Generated: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '# section=%s  op=%s  mode=%s  gpus=%s\n' \
            "$section" "$op" "$CURR_MODE" "$CURR_GPUS"
        printf '\n'
        printf "docker exec %s bash -lc '%s'\n" "$CONTAINER_NAME" "$CURR_INNER_CMD"
    } > "$sh_file"
    chmod +x "$sh_file"

    # ── Write log header (CMD on first line per existing convention) ───────────
    {
        echo "# CMD: docker exec ${CONTAINER_NAME} bash -lc '${CURR_INNER_CMD}'"
        echo "# ================================================================"
        echo "# section  : ${section}"
        echo "# operator : ${op}  binary: ${binary}"
        echo "# mode     : ${CURR_MODE}  gpus: ${CURR_GPUS}"
        echo "# started  : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# ================================================================"
        echo ""
    } > "$log_file"

    # ── Terminal output ───────────────────────────────────────────────────────
    if [[ "$VERBOSE" -eq 1 ]]; then
        echo ""
        echo "━━━ [${section}] ${op} ━━━"
        echo "CMD: docker exec ${CONTAINER_NAME} bash -lc '${CURR_INNER_CMD}'"
        echo ""
    else
        printf "  %-16s → %s  " "$op" "$(basename "$log_file")"
    fi

    # ── Execute ───────────────────────────────────────────────────────────────
    local rc=0
    log_run "$log_file" \
        docker exec "$CONTAINER_NAME" bash -lc "$CURR_INNER_CMD" || rc=$?

    {
        echo ""
        echo "# finished : $(date '+%Y-%m-%d %H:%M:%S')  exit_code: ${rc}"
    } >> "$log_file"

    if [[ "$VERBOSE" -eq 0 ]]; then
        [[ $rc -eq 0 ]] && echo "OK" || echo "FAILED (exit ${rc})"
    fi

    return $rc
}

# ═══════════════════════════════════════════════════════════════════════════════
# Core: process one [section] from a run config file
# ═══════════════════════════════════════════════════════════════════════════════

process_section() {
    local conf_file="$1" section="$2"

    # ── Validate section name (used in filenames) ─────────────────────────────
    if [[ ! "$section" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "ERROR: [${section}] — section name must match [A-Za-z0-9_-]" >&2
        return 1
    fi

    # ── Read required fields ──────────────────────────────────────────────────
    local s_mode s_ops s_gpus
    s_mode=$(ini_get "$conf_file" "$section" "mode" "")
    s_ops=$(ini_get  "$conf_file" "$section" "ops"  "")
    s_gpus=$(ini_get "$conf_file" "$section" "gpus" "")

    [[ -z "$s_mode" ]] && { echo "ERROR: [${section}] missing required field 'mode'" >&2; return 1; }
    [[ -z "$s_ops"  ]] && { echo "ERROR: [${section}] missing required field 'ops'"  >&2; return 1; }
    [[ -z "$s_gpus" ]] && { echo "ERROR: [${section}] missing required field 'gpus'" >&2; return 1; }

    [[ "$s_mode" != "single" && "$s_mode" != "multi" ]] && {
        echo "ERROR: [${section}] mode must be 'single' or 'multi', got: '${s_mode}'" >&2
        return 1
    }
    [[ ! "$s_gpus" =~ ^[0-9]+$ || "$s_gpus" -lt 1 ]] && {
        echo "ERROR: [${section}] gpus must be a positive integer, got: '${s_gpus}'" >&2
        return 1
    }

    # ── Read §3.3.2 data range (optional, with defaults) ──────────────────────
    local s_min_bytes s_max_bytes s_step_bytes s_step_factor
    s_min_bytes=$(  ini_get "$conf_file" "$section" "min_bytes"   "512")
    s_max_bytes=$(  ini_get "$conf_file" "$section" "max_bytes"   "1G")
    s_step_bytes=$( ini_get "$conf_file" "$section" "step_bytes"  "0")
    s_step_factor=$(ini_get "$conf_file" "$section" "step_factor" "2")

    # ── Per-section iter/warmup overrides (optional; fall back to general.conf) ──
    local s_iters s_warmup_iters
    s_iters=$(       ini_get "$conf_file" "$section" "iters"        "$ITERS")
    s_warmup_iters=$(ini_get "$conf_file" "$section" "warmup_iters" "$WARMUP_ITERS")

    # ── Resolve ops list ──────────────────────────────────────────────────────
    local -a run_ops=()
    if [[ "$s_ops" == "all" ]]; then
        run_ops=("${ALL_OPS[@]}")
    else
        for op in $s_ops; do
            if [[ ! -v OP_BINARY["$op"] ]]; then
                echo "ERROR: [${section}] unknown operator '${op}'. Valid: all ${ALL_OPS[*]}" >&2
                return 1
            fi
            run_ops+=("$op")
        done
    fi

    # ── Build succl-tests binary argument list ────────────────────────────────
    # §3.3.1: -t (nthreads) and -G (ngpus) are hardcoded to 1 ("仅支持1")
    local -a succl_args=(
        -t "$FIXED_NTHREADS"
        -G "$FIXED_NGPUS"
        -b "$s_min_bytes"
        -e "$s_max_bytes"
        -o "$REDUCE_OP"
        -d "$DATATYPE"
        -r "$ROOT"
        -n "$s_iters"
        -w "$s_warmup_iters"
        -m "$AGG_ITERS"
        -a "$AVERAGE"
        -p "$PARALLEL_INIT"
        -c "$CHECK"
        -z "$BLOCKING"
    )
    # §3.3.2: step mode (stepbytes takes precedence when > 0)
    [[ "$s_step_bytes" -gt 0 ]] && succl_args+=(-i "$s_step_bytes") \
                                 || succl_args+=(-f "$s_step_factor")
    # BR166 UMA16 mode
    [[ "$BR166_MODE" == "1" ]] && succl_args+=(-k 1)
    # SUPA Graph capture
    [[ "$SUPAGRAPH" != "0" ]] && succl_args+=(--supagraph "$SUPAGRAPH")

    # ── Build MPI environment args ────────────────────────────────────────────
    local -a mpi_env_args=(-x "BR_UMD_DEBUG_P2P_ACCESS_CHECK=${BR_P2P_CHECK}")
    [[ -n "$SUCCL_BUFFSIZE" ]] && mpi_env_args+=(-x "SUCCL_BUFFSIZE=${SUCCL_BUFFSIZE}")

    # ── Multi-node: validate config and build host string ─────────────────────
    local mpi_iface_arg="" mpi_hosts_str=""
    if [[ "$s_mode" == "multi" ]]; then
        if [[ "$MULTI_CONF_LOADED" -eq 0 ]]; then
            echo "ERROR: [${section}] mode=multi but multi-node config not found: ${MULTI_CONF}" >&2
            echo "  Please create ${MULTI_CONF} or specify --multi-config <file>" >&2
            return 1
        fi
        if [[ ${#MULTI_NODE_IPS[@]} -lt 1 ]]; then
            echo "ERROR: [${section}] MULTI_NODE_IPS is empty in ${MULTI_CONF}" >&2
            return 1
        fi

        # Build --host string: IP1:gpus,IP2:gpus,...
        local hosts_str=""
        for ip in "${MULTI_NODE_IPS[@]}"; do
            [[ -n "$hosts_str" ]] && hosts_str+=","
            hosts_str+="${ip}:${s_gpus}"
        done
        mpi_hosts_str="$hosts_str"

        # Network interface arg (INCLUDE takes precedence over EXCLUDE)
        if [[ -n "$MPI_IFACE_INCLUDE" ]]; then
            mpi_iface_arg="--mca btl_tcp_if_include ${MPI_IFACE_INCLUDE}"
        elif [[ -n "$MPI_IFACE_EXCLUDE" ]]; then
            mpi_iface_arg="--mca btl_tcp_if_exclude ${MPI_IFACE_EXCLUDE}"
        fi
    fi

    # ── Multi-node: wait for sshd on all remote nodes before running ─────────────
    if [[ "$s_mode" == "multi" ]]; then
        local _ip
        for _ip in "${MULTI_NODE_IPS[@]}"; do
            local _tries=0
            while ! docker exec "$CONTAINER_NAME" bash -c \
                    "ssh -o StrictHostKeyChecking=no -o BatchMode=yes \
                     -o ConnectTimeout=3 -p ${SSH_PORT} root@${_ip} 'true'" &>/dev/null; do
                (( _tries++ ))
                if [[ $_tries -ge 10 ]]; then
                    echo "[SSH] WARNING: ${_ip}:${SSH_PORT} not ready after 10 retries, skipping wait." >&2
                    break
                fi
                echo "[SSH] Waiting for sshd on ${_ip}:${SSH_PORT} (attempt ${_tries}/10)..."
                sleep 2
            done
        done
    fi

    # ── Section header ────────────────────────────────────────────────────────
    echo ""
    echo "──── [${section}]  mode=${s_mode}  ops=${s_ops}  gpus=${s_gpus} ────"
    printf "\n[%s]  mode=%s  gpus=%s\n" "$section" "$s_mode" "$s_gpus" >> "$SUMMARY_FILE"

    # ── Run each op ───────────────────────────────────────────────────────────
    local failed_ops=()
    for op in "${run_ops[@]}"; do
        local bin_path="${SUCCL_BIN_DIR}/${OP_BINARY[$op]}"

        # Set CURR_* globals consumed by run_section_op
        CURR_MODE="$s_mode"
        CURR_GPUS="$s_gpus"

        if [[ "$s_mode" == "single" ]]; then
            CURR_INNER_CMD="mpiexec --allow-run-as-root \
-n ${s_gpus} \
${mpi_env_args[*]} \
${bin_path} ${succl_args[*]}"
        else
            CURR_INNER_CMD="mpiexec --allow-run-as-root \
--mca pml ^ucx \
${mpi_iface_arg} \
--mca plm_rsh_args \"-p ${SSH_PORT} -o StrictHostKeyChecking=no\" \
--host ${mpi_hosts_str} \
${mpi_env_args[*]} \
-x LD_LIBRARY_PATH \
${bin_path} ${succl_args[*]}"
        fi

        run_section_op "$section" "$op" || failed_ops+=("$op")

        local op_status
        op_status=$([[ " ${failed_ops[*]:-} " == *" ${op} "* ]] && echo "FAILED" || echo "OK")
        local peak=""
        [[ "$op_status" == "OK" ]] && peak=$(parse_peak_bw "${LOG_DIR}/${section}_${op}.log")
        printf "  %-16s %s   %s\n" "${op}:" "$op_status" "${peak:-—}" >> "$SUMMARY_FILE"
    done

    # Return non-zero if any op failed
    [[ ${#failed_ops[@]} -eq 0 ]]
}

# ═══════════════════════════════════════════════════════════════════════════════
# Summary file header
# ═══════════════════════════════════════════════════════════════════════════════

SUMMARY_FILE="${LOG_DIR}/summary.log"
{
    echo "succl-tests run summary"
    echo "started   : $(date '+%Y-%m-%d %H:%M:%S')"
    printf "configs   : %s\n" "${RUN_CONFIGS[*]}"
    echo "general   : ${GENERAL_CONF}"
    echo "log_dir   : ${LOG_DIR}"
    echo ""
} > "$SUMMARY_FILE"

echo "Logs → ${LOG_DIR}"
echo "=== succl-tests: configs=${RUN_CONFIGS[*]} ==="
[[ "$VERBOSE" -eq 0 ]] && echo "  (run with -v to also show output on terminal)"

# ═══════════════════════════════════════════════════════════════════════════════
# Process all run config files and their sections
# ═══════════════════════════════════════════════════════════════════════════════

# Track globally failed sections across all config files
FAILED_SECTIONS=()

# Detect duplicate section names across all config files
declare -A SEEN_SECTIONS=()

for conf_file in "${RUN_CONFIGS[@]}"; do
    echo ""
    echo "════ Config: ${conf_file} ════"

    sections=$(ini_sections "$conf_file")
    if [[ -z "$sections" ]]; then
        echo "WARNING: no [sections] found in ${conf_file}, skipping." >&2
        continue
    fi

    while IFS= read -r section; do
        [[ -z "$section" ]] && continue

        # Duplicate section check
        if [[ -v SEEN_SECTIONS["$section"] ]]; then
            echo "ERROR: duplicate section name '${section}' (first seen in ${SEEN_SECTIONS[$section]}), skipping." >&2
            continue
        fi
        SEEN_SECTIONS["$section"]="$conf_file"

        process_section "$conf_file" "$section" || FAILED_SECTIONS+=("$section")
    done <<< "$sections"
done

# ═══════════════════════════════════════════════════════════════════════════════
# Final summary
# ═══════════════════════════════════════════════════════════════════════════════

echo ""
{
    echo ""
    echo "finished  : $(date '+%Y-%m-%d %H:%M:%S')"
    if [[ ${#FAILED_SECTIONS[@]} -eq 0 ]]; then
        echo "result    : ALL PASSED"
    else
        echo "result    : FAILED sections: ${FAILED_SECTIONS[*]}"
    fi
} | tee -a "$SUMMARY_FILE"

echo "Logs saved to: ${LOG_DIR}"

[[ ${#FAILED_SECTIONS[@]} -eq 0 ]]
