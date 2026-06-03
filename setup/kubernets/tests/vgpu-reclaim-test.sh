#!/usr/bin/env bash
# End-to-end test: a vGPU task occupies an SVI instance, and releasing it makes
# the biren-svi-manager auto-recover the whole physical GPU.
#
# Why the careful setup: the manager continuously reclaims idle partitioned GPUs,
# so a GPU you partition by hand is reverted before a pod can land on it. This
# script therefore stops the manager, establishes the occupied state, then
# restarts the manager — mirroring steady-state operation where a task is
# already running on a partitioned GPU.
#
# Usage:
#   sudo ./vgpu-reclaim-test.sh [--gpu <index>] [--flavor half|quarter]
#   (sudo is needed for `brsmi gpu set`)
#
# Env: HAMI_PLUGIN_DIR (default ../../../packages/hami-br), NODE (default hostname)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

HAMI_PLUGIN_DIR="${HAMI_PLUGIN_DIR:-$HERE/../../../packages/hami-br}"
HAMI_NS="${HAMI_NS:-hami-system}"
DP_NS="${DP_NS:-biren-gpu}"
TEST_POD_YAML="${TEST_POD_YAML:-$HERE/../templates/vgpu-test-pod.yaml}"
BRSMI="${BRSMI:-brsmi}"
POD=vgpu-test-pod

GPU=""; FLAVOR=half
while [[ $# -gt 0 ]]; do
  case "$1" in
    --gpu)    GPU="$2"; shift 2 ;;
    --flavor) FLAVOR="$2"; shift 2 ;;
    *) err "unknown arg: $1"; exit 1 ;;
  esac
done
case "$FLAVOR" in
  half)    SVI_MODE=1; RES=birentech.com/1-2-gpu; WANT=2 ;;
  quarter) SVI_MODE=2; RES=birentech.com/1-4-gpu; WANT=4 ;;
  *) err "--flavor must be half|quarter"; exit 1 ;;
esac

# ── helpers / predicates ──────────────────────────────────────────────────────
gpu_mode(){ $BRSMI gpu --query-gpu=index,svi.mode.current --format=csv,noheader -i "$1" 2>/dev/null | awk -F, '{gsub(/ /,"",$2);print $2}'; }
res_alloc(){ kubectl get node "$NODE" -o json 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['status']['allocatable'].get('$1','0'))"; }
restart_dp(){ kubectl delete pod -n "$DP_NS" -l name=biren-device-plugin --field-selector "spec.nodeName=$NODE" --force --grace-period=0 >/dev/null 2>&1; }
restart_sched(){ kubectl delete pod -n "$HAMI_NS" -l app.kubernetes.io/component=hami-scheduler --force --grace-period=0 >/dev/null 2>&1; }
wait_for(){ local f="$1" t="${2:-120}" i; for ((i=0;i<t;i+=6)); do "$f" && return 0; sleep 6; done; return 1; }
have_res(){     [[ "$(res_alloc "$RES")" -ge "$WANT" ]]; }
# the vendor device plugin oscillates after a mode change; wait until the count
# is stable at >=WANT for two consecutive reads before trusting it.
stable_res(){ local a b; a=$(res_alloc "$RES"); sleep 6; b=$(res_alloc "$RES"); [[ "$a" -ge "$WANT" && "$b" -ge "$WANT" ]]; }
sched_ready(){  [[ "$(kubectl get pod -n "$HAMI_NS" -l app.kubernetes.io/component=hami-scheduler --no-headers 2>/dev/null | grep -c '2/2.*Running')" -ge 1 ]]; }
mgr_ready(){    [[ "$(kubectl get pod -n "$HAMI_NS" -l app=biren-svi-manager --field-selector "spec.nodeName=$NODE" --no-headers 2>/dev/null | grep -c '1/1.*Running')" -ge 1 ]]; }
pod_running(){  [[ "$(kubectl get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)" == "Running" ]]; }
reverted(){     [[ "$(gpu_mode "$GPU")" == "Disabled" ]]; }

command -v "$BRSMI" >/dev/null || { err "brsmi not found"; exit 1; }
[[ -f "$HAMI_PLUGIN_DIR/hami-scheduler.yaml" ]] || { err "package not found: $HAMI_PLUGIN_DIR (run package-hami-svi.sh + stage)"; exit 1; }

# pick an idle whole GPU if none specified
if [[ -z "$GPU" ]]; then
  GPU=$($BRSMI gpu --query-gpu=index,svi.mode.current --format=csv,noheader,nounits 2>/dev/null \
        | awk -F, '/[Dd]isabled/{gsub(/ /,"",$1);print $1; exit}')
fi
[[ -n "$GPU" ]] || { err "no idle whole GPU available to partition"; exit 1; }
log "test: flavor=$FLAVOR (SVI mode $SVI_MODE, $RES) on GPU $GPU, node $NODE"

FAIL=0

log "1/6 stop biren-svi-manager (so setup isn't auto-reclaimed)"
kubectl delete ds biren-svi-manager -n "$HAMI_NS" --ignore-not-found >/dev/null 2>&1
kubectl delete pod "$POD" --ignore-not-found --force --grace-period=0 >/dev/null 2>&1

log "2/6 partition GPU $GPU (svi mode $SVI_MODE) + refresh device plugin"
sudo "$BRSMI" gpu set -s "$SVI_MODE" -i "$GPU" 2>&1 | tail -1
restart_dp
wait_for stable_res 150 || true
[[ "$(res_alloc "$RES")" -ge "$WANT" ]] || { err "device plugin did not advertise $RES (got $(res_alloc "$RES"))"; FAIL=1; }
log "   $RES allocatable = $(res_alloc "$RES")"

log "3/6 register SVI devices + refresh scheduler"
bash "$HAMI_PLUGIN_DIR/register-svi-devices.sh" "$NODE" >/dev/null 2>&1 || true
restart_sched
wait_for sched_ready 120 || true
sleep 20   # let the scheduler's register loop ingest the real instances

log "4/6 deploy vGPU task and wait until Running (retry on transient Allocate failure)"
ran=0
for attempt in 1 2 3; do
  kubectl delete pod "$POD" --ignore-not-found --force --grace-period=0 >/dev/null 2>&1
  kubectl apply -f "$TEST_POD_YAML" >/dev/null
  if wait_for pod_running 90; then ran=1; break; fi
  log "   attempt $attempt: pod=$(kubectl get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null) — refreshing device-plugin + scheduler and retrying"
  restart_dp; restart_sched; wait_for stable_res 120 || true; wait_for sched_ready 90 || true; sleep 15
done
if [[ "$ran" == "1" ]]; then
  ok "task Running on card $(kubectl exec "$POD" -- sh -c 'echo $BR_PHY_CARDS' 2>/dev/null), GPU $GPU=$(gpu_mode "$GPU")"
else
  err "task did not reach Running (phase=$(kubectl get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null))"; FAIL=1
fi

log "5/6 restart manager; while the task runs the GPU must STAY partitioned"
kubectl apply -f "$HAMI_PLUGIN_DIR/hami-scheduler.yaml" >/dev/null 2>&1
wait_for mgr_ready 60 || true
sleep 45
if [[ "$(gpu_mode "$GPU")" == "Enabled" ]]; then
  ok "GPU $GPU still Enabled while task runs (occupancy prevents reclaim)"
else
  err "GPU $GPU was reclaimed while the task was still running"; FAIL=1
fi

log "6/6 RELEASE the task -> expect auto-recover to a whole card"
kubectl delete pod "$POD" --force --grace-period=0 >/dev/null 2>&1
if wait_for reverted 150; then
  ok "GPU $GPU AUTO-RECOVERED to a whole card after task release"
else
  err "GPU $GPU did not revert to whole within timeout (mode=$(gpu_mode "$GPU"))"; FAIL=1
fi

echo
[[ "$FAIL" -eq 0 ]] && ok "RECLAIM TEST PASSED" || err "RECLAIM TEST FAILED"
exit "$FAIL"
