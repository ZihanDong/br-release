#!/usr/bin/env bash
# switch-gpu-driver.sh — 在本节点的 Biren GPU 内核驱动（KMD）之间切换：
#   default  系统自带 / 出厂驱动（性能更好，支持整卡 + SVI，**不**支持 vGPU 软切分）
#   vgpu     vGPU 专用驱动 1.12.0（实现 vGPU ioctl，但会影响上层应用性能）
#
# 背景：vGPU 软切分需要 1.12.0 KMD，而它会拖累普通应用性能；整卡 / SVI 用默认驱动即可。
# 因此仅在确实要跑 vGPU 应用时切到 vgpu 驱动，其余时间切回 default 驱动。
#
# 驱动就是内核模块 `biren`（biren.ko）。切换 = rmmod 当前模块 + insmod 目标构建。
# **目标构建的 vermagic 必须与当前内核 `$(uname -r)` 完全一致**，否则 insmod 失败。
#
# 两个构建以解压后的 .ko 形式缓存在 KMD store（默认 /usr/local/birensupa/kmd-store/），
# 与“当前开机加载的是哪个”解耦；首次运行 vgpu/default 会自动从本机现有文件播种 store
# （default ← updates/biren.ko.xz.bak-*；vgpu ← 版本为 1.12.0 的 .ko/.ko.xz）。
#
# 用法：
#   sudo bash switch-gpu-driver.sh status
#   sudo bash switch-gpu-driver.sh vgpu     [--persist] [--force] [--yes]
#   sudo bash switch-gpu-driver.sh default  [--persist] [--force] [--yes]
#   sudo bash switch-gpu-driver.sh seed     [--default-ko <文件>] [--vgpu-ko <文件>]
#   sudo bash switch-gpu-driver.sh persist  <vgpu|default>
#
# - 运行期切换（vgpu/default）立即生效、重启后失效；
# - --persist（或 persist 子命令）会把所选构建写入开机加载路径，使重启保持该选择。
#
# 注意：切换会卸载并重载 GPU 驱动，**会中断本节点上所有 GPU 负载**。切换前请先停止
# GPU 消费者（docker GPU 容器、k8s GPU Pod、占用 /dev/biren* 的进程，以及会持有设备的
# biren 设备插件 / mode-manager DaemonSet）；本脚本会检测并列出占用者，未清空时拒绝卸载。

set -euo pipefail

# ── 路径与常量 ────────────────────────────────────────────────────────────────
MODULE="biren"
KREL="$(uname -r)"
UPDATES_DIR="/lib/modules/${KREL}/updates"
BOOT_KO_XZ="${UPDATES_DIR}/biren.ko.xz"            # 开机经 PCI modalias 自加载的文件
STORE_DIR="${BIREN_KMD_STORE:-/usr/local/birensupa/kmd-store}"
DEFAULT_KO="${STORE_DIR}/biren-default.ko"          # 缓存：默认/出厂构建（解压后）
VGPU_KO="${STORE_DIR}/biren-vgpu.ko"                # 缓存：vGPU 1.12.0 构建（解压后）
VGPU_VERSION="1.12.0"                               # vGPU KMD 版本（用于识别构建）
VGPU_TOOL="/usr/local/bin/br_vgpu_tool"

# ── 日志 ──────────────────────────────────────────────────────────────────────
_c() { printf '\033[%sm' "$1"; }; _r() { printf '\033[0m'; }
log_info() { echo -e "$(_c '0;36')[INFO]$(_r)  $*"; }
log_ok()   { echo -e "$(_c '1;32')[ OK ]$(_r)  $*"; }
log_warn() { echo -e "$(_c '0;33')[WARN]$(_r)  $*"; }
log_err()  { echo -e "$(_c '0;31')[ERR ]$(_r)  $*" >&2; }
die()      { log_err "$*"; exit 1; }

# ── 通用 ──────────────────────────────────────────────────────────────────────
need_root() {
    if [[ ${EUID} -ne 0 ]]; then
        die "需要 root。请用： sudo bash $0 ${CMD} ${ARGS_ECHO}"
    fi
}

# 一个文件是否为 xz 压缩（按内容判断，兼容 .ko.xz、.ko.xz.bak-* 等任意后缀）
_is_xz() { xz -t "$1" >/dev/null 2>&1; }

# modinfo 字段（兼容裸 .ko 与 xz 压缩的 .ko）
_ko_field() {  # <file> <field>
    local f="$1" field="$2" tmp rc
    if _is_xz "$f"; then
        tmp="$(mktemp --suffix=.ko)"
        xz -dc "$f" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
        modinfo -F "$field" "$tmp" 2>/dev/null; rc=$?
        rm -f "$tmp"; return $rc
    fi
    modinfo -F "$field" "$f" 2>/dev/null
}
_ko_version()  { _ko_field "$1" version  | head -1; }
_ko_vermagic() { _ko_field "$1" vermagic | head -1; }

# 校验一个 .ko 对本内核可加载（vermagic 必须匹配）
_verify_ko_loadable() {  # <file> <label>
    local f="$1" label="$2" vm
    [[ -f "$f" ]] || die "${label} KMD 文件不存在：${f}"
    vm="$(_ko_vermagic "$f" || true)"
    [[ -n "$vm" ]] || die "${label}：无法读取 ${f} 的 vermagic（文件损坏？）"
    # vermagic 以 'KREL ...' 开头
    if [[ "${vm%% *}" != "${KREL}" ]]; then
        die "${label} 的 vermagic 与当前内核不匹配：
    文件 vermagic = '${vm}'
    当前内核      = '${KREL}'
  请提供为该内核构建的 biren.ko（用 --default-ko / --vgpu-ko 指定，或重建 KMD）。"
    fi
}

loaded_version() { cat "/sys/module/${MODULE}/version" 2>/dev/null || true; }
is_loaded()      { [[ -d "/sys/module/${MODULE}" ]]; }
module_refcnt()  { cat "/sys/module/${MODULE}/refcnt" 2>/dev/null || echo 0; }

# 把已加载版本映射到模式名
loaded_mode() {
    local v; v="$(loaded_version)"
    [[ -z "$v" ]] && { echo "none"; return; }
    [[ "$v" == "${VGPU_VERSION}" ]] && echo "vgpu" || echo "default"
}

# 列出持有 GPU 设备的进程（阻止 rmmod 的根因）
list_device_holders() {
    local holders=""
    if command -v fuser >/dev/null 2>&1; then
        holders="$(fuser /dev/biren-m /dev/biren/* /dev/biren/card_* 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -u || true)"
    elif command -v lsof >/dev/null 2>&1; then
        holders="$(lsof -t /dev/biren-m /dev/biren/* 2>/dev/null | sort -u || true)"
    fi
    echo "$holders"
}

# ── store 播种 ────────────────────────────────────────────────────────────────
# 把一个源 .ko/.ko.xz 解压/拷贝为 store 里的目标 .ko（解压后，便于 insmod）
_install_to_store() {  # <src> <dest.ko> <label>
    local src="$1" dest="$2" label="$3"
    install -d -m0755 "${STORE_DIR}"
    if _is_xz "$src"; then
        xz -dc "$src" > "${dest}.tmp" || die "${label}：解压 ${src} 失败"
        mv -f "${dest}.tmp" "$dest"
    else
        install -m0644 "$src" "$dest"
    fi
    log_ok "${label} → ${dest}  (version=$(_ko_version "$dest"), vermagic 匹配)"
}

# 自动探测某模式的源文件（vermagic 必须匹配本内核）
_detect_source() {  # <mode>  -> echo path | empty
    local mode="$1" f vm ver
    local -a cands=()
    if [[ "$mode" == "vgpu" ]]; then
        cands=( "${BOOT_KO_XZ}" "${UPDATES_DIR}"/biren.ko.xz.bak-1.12.0* )
    else
        cands=( "${UPDATES_DIR}"/biren.ko.xz.bak-* "${BOOT_KO_XZ}" )
    fi
    for f in "${cands[@]}"; do
        [[ -e "$f" ]] || continue
        vm="$(_ko_vermagic "$f" 2>/dev/null || true)"; [[ "${vm%% *}" == "${KREL}" ]] || continue
        ver="$(_ko_version "$f" 2>/dev/null || true)"
        if [[ "$mode" == "vgpu" ]]; then
            [[ "$ver" == "${VGPU_VERSION}" ]] && { echo "$f"; return 0; }
        else
            [[ -n "$ver" && "$ver" != "${VGPU_VERSION}" ]] && { echo "$f"; return 0; }
        fi
    done
    return 1
}

# 确保 store 里某模式的 .ko 就位（缺则自动播种）；返回该 .ko 路径
ensure_store() {  # <mode> [override_src]
    local mode="$1" override="${2:-}" dest src
    [[ "$mode" == "vgpu" ]] && dest="${VGPU_KO}" || dest="${DEFAULT_KO}"
    if [[ -n "$override" ]]; then
        [[ -e "$override" ]] || die "指定的 --${mode}-ko 不存在：${override}"
        _verify_ko_loadable "$override" "${mode}(指定)"
        _install_to_store "$override" "$dest" "${mode}"
    elif [[ ! -f "$dest" ]]; then
        src="$(_detect_source "$mode" || true)"
        [[ -n "$src" ]] || die "未能自动找到 ${mode} 驱动源（vermagic=${KREL}）。
  请用： sudo bash $0 seed --${mode}-ko <为本内核构建的 biren.ko 或 .ko.xz>"
        log_info "自动播种 ${mode} 源：${src}"
        _verify_ko_loadable "$src" "${mode}(自动)"
        _install_to_store "$src" "$dest" "${mode}"
    fi
    _verify_ko_loadable "$dest" "${mode}(store)"
    echo "$dest"
}

# ── 加载/卸载 ─────────────────────────────────────────────────────────────────
unload_module() {  # <force>
    local force="$1" rc holders
    is_loaded || { log_info "模块 ${MODULE} 当前未加载。"; return 0; }
    rc="$(module_refcnt)"
    holders="$(list_device_holders)"
    if [[ "${rc}" != "0" || -n "$holders" ]]; then
        log_warn "模块 ${MODULE} 仍被占用（refcnt=${rc}）。占用 /dev/biren* 的进程："
        if [[ -n "$holders" ]]; then
            ps -o pid,comm,args -p $(echo "$holders" | tr '\n' ',' | sed 's/,$//') 2>/dev/null | sed 's/^/    /' || echo "    (pid: $holders)"
        else
            echo "    (refcnt>0，但未能定位具体进程；可能是内核内部引用)"
        fi
        echo ""
        log_warn "请先停止这些 GPU 负载，例如："
        echo "    • docker：sudo docker ps -q --filter ancestor=... | xargs -r sudo docker stop"
        echo "    • k8s 设备插件（会持有设备）：kubectl -n biren-gpu delete pod -l ... 或暂停其 DaemonSet"
        echo "    • 任何使用 brsmi/SUPA 的进程"
        if [[ "$force" != "true" ]]; then
            die "为安全起见已中止。确认无误后可加 --force（rmmod 仍会在真正占用时失败）。"
        fi
        log_warn "--force：仍尝试卸载……"
    fi
    log_info "卸载模块 ${MODULE}（当前版本 $(loaded_version)）..."
    if ! rmmod "${MODULE}" 2>/tmp/.rmmod.err; then
        log_err "$(cat /tmp/.rmmod.err 2>/dev/null)"; rm -f /tmp/.rmmod.err
        die "rmmod ${MODULE} 失败（仍被占用）。请停止上述进程后重试。"
    fi
    rm -f /tmp/.rmmod.err
    is_loaded && die "rmmod 后模块仍在？异常，已中止。"
    log_ok "已卸载 ${MODULE}。"
}

load_ko() {  # <ko> <expect_version>
    local ko="$1" expect="$2"
    log_info "加载 ${ko} ..."
    if ! insmod "${ko}" 2>/tmp/.insmod.err; then
        log_err "$(cat /tmp/.insmod.err 2>/dev/null)"; rm -f /tmp/.insmod.err
        return 1
    fi
    rm -f /tmp/.insmod.err
    is_loaded || return 1
    local v; v="$(loaded_version)"
    [[ -n "$expect" && "$v" != "$expect" ]] && log_warn "加载后版本=${v}（预期 ${expect}）"
    return 0
}

wait_devices() {  # 等驱动重建设备节点
    local i
    for i in $(seq 1 20); do
        [[ -e /dev/biren-m ]] && ls /dev/biren/card_* >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# ── 子命令 ────────────────────────────────────────────────────────────────────
cmd_status() {
    echo "── Biren GPU 驱动状态（$(hostname -s)，内核 ${KREL}）──"
    if is_loaded; then
        printf "  已加载模块 : %s  version=%s  mode=%s  refcnt=%s\n" \
            "${MODULE}" "$(loaded_version)" "$(loaded_mode)" "$(module_refcnt)"
    else
        echo "  已加载模块 : (未加载)"
    fi
    local bv="(无)"; [[ -e "${BOOT_KO_XZ}" ]] && bv="$(_ko_version "${BOOT_KO_XZ}" 2>/dev/null)  vermagic=$(_ko_vermagic "${BOOT_KO_XZ}" 2>/dev/null)"
    printf "  开机加载文件: %s\n               version=%s\n" "${BOOT_KO_XZ}" "${bv}"
    echo "  KMD store  : ${STORE_DIR}"
    local m dest
    for m in default vgpu; do
        [[ "$m" == vgpu ]] && dest="${VGPU_KO}" || dest="${DEFAULT_KO}"
        if [[ -f "$dest" ]]; then
            printf "    %-8s : %s  (version=%s)\n" "$m" "$dest" "$(_ko_version "$dest" 2>/dev/null)"
        else
            local src; src="$(_detect_source "$m" 2>/dev/null || true)"
            printf "    %-8s : (未播种；可自动取自: %s)\n" "$m" "${src:-未找到，需 seed --${m}-ko}"
        fi
    done
    local holders; holders="$(list_device_holders)"
    if [[ -n "$holders" ]]; then
        echo "  设备占用者 : $(echo "$holders" | tr '\n' ' ')（切换前需先停止）"
    else
        echo "  设备占用者 : 无（可安全切换）"
    fi
    [[ -x "${VGPU_TOOL}" ]] && echo "  br_vgpu_tool: ${VGPU_TOOL}（vGPU 模式下用它管理 profile）"
}

persist_mode() {  # <mode>
    local mode="$1" ko ts curver
    ko="$(ensure_store "$mode")"
    install -d -m0755 "${UPDATES_DIR}"
    if [[ -e "${BOOT_KO_XZ}" ]]; then
        curver="$(_ko_version "${BOOT_KO_XZ}" 2>/dev/null || echo unknown)"
        ts="$(date +%Y%m%d-%H%M%S)"
        cp -a "${BOOT_KO_XZ}" "${BOOT_KO_XZ}.bak-${curver}-${ts}"
        log_info "已备份当前开机文件 → ${BOOT_KO_XZ}.bak-${curver}-${ts}"
    fi
    xz -c "$ko" > "${BOOT_KO_XZ}.tmp" || die "压缩到开机文件失败"
    mv -f "${BOOT_KO_XZ}.tmp" "${BOOT_KO_XZ}"
    depmod -a || log_warn "depmod -a 返回非零"
    log_ok "已持久化：重启后开机加载 ${mode} 驱动（${BOOT_KO_XZ} = version $(_ko_version "${BOOT_KO_XZ}" 2>/dev/null)）。"
}

switch_to() {  # <mode> <persist> <force> <yes> <override_src>
    local mode="$1" persist="$2" force="$3" yes="$4" override="${5:-}"
    local target_ver other ko_target ko_other cur
    if [[ "$mode" == "vgpu" ]]; then target_ver="${VGPU_VERSION}"; other="default"
    else target_ver=""; other="vgpu"; fi

    ko_target="$(ensure_store "$mode" "$override")"

    cur="$(loaded_mode)"
    if [[ "$cur" == "$mode" ]]; then
        log_ok "当前已是 ${mode} 驱动（version=$(loaded_version)），无需切换。"
        [[ "$persist" == "true" ]] && persist_mode "$mode"
        return 0
    fi

    echo ""
    log_warn "即将把 GPU 驱动从 [${cur}] 切到 [${mode}]，这会卸载并重载 biren 模块，"
    log_warn "中断本节点上所有 GPU 负载。目标：${ko_target}（vermagic 已校验匹配 ${KREL}）。"
    if [[ "$yes" != "true" ]]; then
        read -rp "  确认继续？输入 yes： " ans
        [[ "$ans" == "yes" ]] || die "已取消。"
    fi

    unload_module "$force"

    if ! load_ko "$ko_target" "$target_ver"; then
        log_err "加载 ${mode} 驱动失败！尝试回滚到 ${cur} ..."
        local ko_back; [[ "$other" == vgpu ]] && ko_back="${VGPU_KO}" || ko_back="${DEFAULT_KO}"
        if [[ -f "$ko_back" ]] && load_ko "$ko_back" ""; then
            log_warn "已回滚到 ${cur} 驱动（version=$(loaded_version)）。请检查 ${mode} 构建。"
        else
            die "回滚也失败：本节点当前无 GPU 驱动！请手动 insmod 一个匹配 ${KREL} 的 biren.ko。"
        fi
        exit 1
    fi

    if wait_devices; then
        log_ok "驱动已加载：${MODULE} version=$(loaded_version)，设备节点已重建。"
    else
        log_warn "驱动已加载（version=$(loaded_version)），但未在 20s 内见到 /dev/biren/card_*。请检查 dmesg。"
    fi
    command -v brsmi >/dev/null 2>&1 && { brsmi gpu --query-gpu=index,memory.used --format=csv,noheader 2>/dev/null | head -1 >/dev/null && log_ok "brsmi 可访问 GPU。" || log_warn "brsmi 暂不可访问，可能需重启 SUPA 用户态进程。"; }

    if [[ "$mode" == "vgpu" ]]; then
        [[ -x "${VGPU_TOOL}" ]] && log_info "vGPU 就绪。用 ${VGPU_TOOL} status --dbdf 0 验证（应为 INACTIVE/非 EINVAL）。" \
            || log_warn "未找到 ${VGPU_TOOL}；如需 vGPU profile 管理请先安装（见 packages/hami-biren/kmd/）。"
    fi
    [[ "$persist" == "true" ]] && persist_mode "$mode"

    echo ""
    log_ok "切换完成：现为 [${mode}] 驱动。"
    log_warn "请重启之前停掉的 GPU 负载（biren 设备插件 DaemonSet / GPU 容器 / Pod）。"
    [[ "$persist" != "true" ]] && log_info "本次为运行期切换，重启后会回到开机文件的版本（当前开机=$( [[ -e ${BOOT_KO_XZ} ]] && _ko_version "${BOOT_KO_XZ}" 2>/dev/null || echo 无)）。如需重启保持，请加 --persist。"
}

# ── 参数解析 ──────────────────────────────────────────────────────────────────
usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

[[ $# -lt 1 ]] && usage 1
CMD="$1"; shift
ARGS_ECHO="$*"
PERSIST=false; FORCE=false; YES=false; OVR_DEFAULT=""; OVR_VGPU=""; POSARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --persist)    PERSIST=true; shift ;;
        --force)      FORCE=true; shift ;;
        --yes|-y)     YES=true; shift ;;
        --default-ko) OVR_DEFAULT="${2:?--default-ko 需要文件参数}"; shift 2 ;;
        --vgpu-ko)    OVR_VGPU="${2:?--vgpu-ko 需要文件参数}"; shift 2 ;;
        -h|--help)    usage 0 ;;
        --*)          die "未知参数：$1（用 -h 看用法）" ;;
        *)            [[ -z "$POSARG" ]] || die "多余参数：$1"; POSARG="$1"; shift ;;
    esac
done

case "${CMD}" in
    status)
        cmd_status ;;
    vgpu)
        need_root "$@"; switch_to vgpu    "$PERSIST" "$FORCE" "$YES" "$OVR_VGPU" ;;
    default|perf)
        need_root "$@"; switch_to default "$PERSIST" "$FORCE" "$YES" "$OVR_DEFAULT" ;;
    seed)
        need_root "$@"
        ensure_store default "$OVR_DEFAULT" >/dev/null
        ensure_store vgpu    "$OVR_VGPU"    >/dev/null
        log_ok "store 已就绪：${STORE_DIR}"; cmd_status ;;
    persist)
        need_root
        [[ "$POSARG" == "vgpu" || "$POSARG" == "default" ]] || die "persist 需要 vgpu|default（如：persist default）"
        persist_mode "$POSARG" ;;
    -h|--help)
        usage 0 ;;
    *)
        die "未知命令：${CMD}（status|vgpu|default|seed|persist；-h 看用法）" ;;
esac
