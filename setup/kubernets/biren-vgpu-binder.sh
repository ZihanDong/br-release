#!/usr/bin/env bash
# biren-vgpu-binder.sh — host-side per-container vGPU profile binder.
#
# WHY THIS EXISTS
#   On this cluster (Kylin V10, kernel 4.19.90, pure cgroup v1) the HAMi-Biren
#   biren-mode-manager puts a card into vGPU mode (`br_vgpu_tool enter`) and
#   advertises capacity, but it never performs the *per-container* binding
#   `br_vgpu_tool apply_reg --cgroup <id> --uuid <BR_VGPU_UUID>`. Without that
#   binding the KMD cannot match a container's tasks to their vGPU namespace, so
#   any GPU workload inside a vGPU pod dies with:
#       ERROR (SUPA) ... ErrorCode: 100, no device
#
#   The KMD's kcl_current_cgroup_id() identifies a task by the *inode number of
#   its memory-controller cgroup directory* (memory_cgrp_id). This daemon scans
#   running vGPU containers (those with BR_VGPU_UUID in their environ), computes
#   that inode, and apply_reg's the profile; it release --force's when the
#   container goes away. It is idempotent and survives container restarts (the
#   cgroup inode changes on restart -> re-bind).
#
# REQUIREMENTS: run as root on each GPU node that serves vGPU pods. Needs
#   /usr/local/bin/br_vgpu_tool, /dev/biren-m (1.12.0 KMD), and host /proc.
#
# USAGE:
#   sudo bash biren-vgpu-binder.sh [--interval SEC] [--once] [--verbose]
#
set -uo pipefail

TOOL="${BR_VGPU_TOOL:-/usr/local/bin/br_vgpu_tool}"
INTERVAL=3
ONCE=0
VERBOSE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval) INTERVAL="$2"; shift 2 ;;
        --once)     ONCE=1; shift ;;
        --verbose|-v) VERBOSE=1; shift ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

ts()   { date '+%H:%M:%S'; }
log()  { echo "[$(ts)] $*"; }
vlog() { [[ "$VERBOSE" == 1 ]] && echo "[$(ts)] $*"; return 0; }

[[ -x "$TOOL" ]] || { echo "br_vgpu_tool not found at $TOOL" >&2; exit 1; }
[[ -e /dev/biren-m ]] || { echo "/dev/biren-m missing — is the 1.12.0 vGPU KMD loaded?" >&2; exit 1; }

# bound[uuid] = "dbdf cgid spc hbm"   (what we last apply_reg'd)
declare -A bound
# orphan_strikes[uuid] = consecutive cycles a host-visible profile had no container
declare -A orphan_strikes

# Read a NUL-separated environ value for a given key from /proc/<pid>/environ.
getenv_val() {  # $1=pid  $2=KEY
    tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n "s/^$2=//p" | head -1
}

# Inode of a pid's memory-controller cgroup dir == the id the KMD matches on.
mem_cgroup_inode() {  # $1=pid
    local rel
    rel=$(sed -n 's/^[0-9]*:\([^:]*\bmemory\b[^:]*\):\(.*\)$/\2/p' "/proc/$1/cgroup" 2>/dev/null | head -1)
    [[ -z "$rel" ]] && return 1
    stat -c %i "/sys/fs/cgroup/memory${rel}" 2>/dev/null
}

_apply() {  # $1=uuid $2=dbdf $3=cgid $4=spc $5=hbm  -> 0 on success
    "$TOOL" apply_reg --dbdf "$2" --spc "$4" --hbm "$5" --cgroup "$3" --uuid "$1" >/dev/null 2>&1
}

bind_one() {  # $1=uuid $2=dbdf $3=cgid $4=spc $5=hbm
    local uuid="$1" dbdf="$2" cgid="$3" spc="$4" hbm="$5"
    if _apply "$uuid" "$dbdf" "$cgid" "$spc" "$hbm"; then
        bound["$uuid"]="$dbdf $cgid $spc $hbm"
        log "BOUND   uuid=${uuid:0:8} dbdf=$dbdf cgroup=$cgid spc=$spc hbm=${hbm}MB"
        return
    fi
    # apply_reg can fail because a STALE profile with this uuid already exists
    # (e.g. the binder restarted, or the container restarted into a new cgroup).
    # Clear it and re-apply so the profile always ends bound to the CURRENT cgroup.
    "$TOOL" release --dbdf "$dbdf" --uuid "$uuid" --force >/dev/null 2>&1
    if _apply "$uuid" "$dbdf" "$cgid" "$spc" "$hbm"; then
        bound["$uuid"]="$dbdf $cgid $spc $hbm"
        log "REBIND  uuid=${uuid:0:8} dbdf=$dbdf cgroup=$cgid spc=$spc hbm=${hbm}MB"
    else
        # genuinely no room (ENOSPC) — leave for a later cycle once others free up
        log "FAIL    apply_reg uuid=${uuid:0:8} dbdf=$dbdf cgroup=$cgid (will retry)"
    fi
}

# uuids of host-visible profiles on a card (col 1 of `list`)
profile_uuids() {  # $1=dbdf
    "$TOOL" list --dbdf "$1" 2>/dev/null | awk '$1 ~ /^[0-9a-f]{8}-/ {print $1}'
}

release_one() {  # $1=uuid $2=dbdf $3=cgid
    # Full release (no --cgroup) returns SPC/HBM to the card's pool; --force in
    # case the namespace still shows active during teardown.
    "$TOOL" release --dbdf "$2" --uuid "$1" --force >/dev/null 2>&1
    log "RELEASE uuid=${1:0:8} dbdf=$2 cgroup=$3 (container gone)"
    unset 'bound[$1]'
}

scan_once() {
    declare -A seen   # uuid -> "dbdf cgid spc hbm" found this cycle
    local pid uuid dbdf spc hbm cgid
    for pid in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
        [[ -r "/proc/$pid/environ" ]] || continue
        uuid=$(getenv_val "$pid" BR_VGPU_UUID); [[ -z "$uuid" ]] && continue
        [[ -n "${seen[$uuid]:-}" ]] && continue          # one pid per uuid is enough
        dbdf=$(getenv_val "$pid" BR_VGPU_DBDF)
        spc=$(getenv_val "$pid" BR_VGPU_SPC)
        hbm=$(getenv_val "$pid" BR_VGPU_HBM)
        cgid=$(mem_cgroup_inode "$pid") || continue
        [[ -z "$dbdf$spc$hbm$cgid" ]] && continue
        seen[$uuid]="$dbdf $cgid $spc $hbm"
    done

    # bind new / re-bind on cgroup change (container restart)
    local cur
    for uuid in "${!seen[@]}"; do
        read -r dbdf cgid spc hbm <<< "${seen[$uuid]}"
        cur="${bound[$uuid]:-}"
        if [[ "$cur" != "${seen[$uuid]}" ]]; then
            [[ -n "$cur" ]] && { read -r odbdf ocgid _ _ <<< "$cur"; release_one "$uuid" "$odbdf" "$ocgid"; }
            bind_one "$uuid" "$dbdf" "$cgid" "$spc" "$hbm"
        else
            vlog "ok      uuid=${uuid:0:8} cgroup=$cgid (already bound)"
        fi
    done

    # release vanished containers we track
    for uuid in "${!bound[@]}"; do
        if [[ -z "${seen[$uuid]:-}" ]]; then
            read -r dbdf cgid _ _ <<< "${bound[$uuid]}"
            release_one "$uuid" "$dbdf" "$cgid"
        fi
    done

    # orphan sweep: release host-visible profiles with NO running container.
    # Catches leaks the bound[] map can't (binder restart, prior --once run, a
    # crash between apply_reg and tracking). Grace of 3 cycles avoids racing a
    # just-created profile whose container we haven't scanned yet.
    local -A active_dbdf
    for uuid in "${!seen[@]}";  do read -r d _ <<< "${seen[$uuid]}";  active_dbdf[$d]=1; done
    for uuid in "${!bound[@]}"; do read -r d _ <<< "${bound[$uuid]}"; active_dbdf[$d]=1; done
    local puuid
    for dbdf in "${!active_dbdf[@]}"; do
        while read -r puuid; do
            [[ -z "$puuid" ]] && continue
            if [[ -n "${seen[$puuid]:-}" ]]; then orphan_strikes[$puuid]=0; continue; fi
            orphan_strikes[$puuid]=$(( ${orphan_strikes[$puuid]:-0} + 1 ))
            if [[ ${orphan_strikes[$puuid]} -ge 3 ]]; then
                "$TOOL" release --dbdf "$dbdf" --uuid "$puuid" --force >/dev/null 2>&1
                log "ORPHAN  released uuid=${puuid:0:8} dbdf=$dbdf (no container 3 cycles)"
                unset 'orphan_strikes[$puuid]' 'bound[$puuid]'
            fi
        done < <(profile_uuids "$dbdf")
    done
}

log "biren-vgpu-binder starting (tool=$TOOL interval=${INTERVAL}s once=$ONCE)"
if [[ "$ONCE" == 1 ]]; then
    scan_once
    exit 0
fi
trap 'log "stopping"; exit 0' INT TERM
while :; do
    scan_once
    sleep "$INTERVAL"
done
