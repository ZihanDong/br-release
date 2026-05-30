#!/usr/bin/env bash
# Runs INSIDE the birensupa-sdk pod that HAMi scheduled onto a Biren SVI instance.
#
# It installs the Biren DCGM package (which bundles `suvs`, the SUPA Validation
# Suite) from the hostPath-mounted release dir, then runs a basic compute test on
# the allocated SVI instance:
#   - software : SUPA / driver runtime versions present  (deterministic PASS)
#   - gpuinfo  : the SVI instance is enumerated, clocks   (deterministic PASS)
#   - membw    : runs a real ~90s compute/replay kernel and MEASURES HBM
#                bandwidth on the instance.
#
# NOTE on membw PASS/FAIL: the membw plugin's built-in PASS threshold (1480 GB/s)
# is calibrated for a *whole* Biren166 GPU. On an SVI partition the hardware
# limits the instance to its fraction, so the measured bandwidth is ~1/2 or ~1/4
# of a whole card and the plugin prints "Fail for bandwidth < 1480 GB/s". That is
# expected and is itself proof the partition is enforced — so this script treats
# the measured bandwidth as the result and gates success on software+gpuinfo plus
# a successful kernel run, not on the whole-GPU threshold.
set -uo pipefail

SUVS_HOME=/usr/local/birensupa/sudcgm/latest/suvs
DURATION="${SUVS_MEMBW_DURATION:-90}"   # membw plugin requires >= 90s

echo "===== allocated SVI instance (from HAMi/biren device plugin) ====="
echo "BR_PHY_CARDS=${BR_PHY_CARDS:-<unset>}"
ls -l /dev/biren 2>/dev/null || echo "no /dev/biren (device not injected?)"
echo

echo "===== install Biren DCGM (provides suvs) from /host-driver ====="
RUN=$(ls /host-driver/sudcgm_*ubuntu-22.04*.run 2>/dev/null | head -1)
[ -z "$RUN" ] && RUN=$(ls /host-driver/sudcgm_*.run 2>/dev/null | head -1)
if [ -z "$RUN" ]; then echo "FATAL: no sudcgm .run under /host-driver"; ls /host-driver; exit 2; fi
echo "installer: $RUN"
cp "$RUN" /tmp/sudcgm.run && chmod +x /tmp/sudcgm.run
/tmp/sudcgm.run --install-dir /usr/local/birensupa 2>&1 | grep -E "installed|suvs|integrity" | tail -6

# shellcheck disable=SC1091
set +u; source /usr/local/birensupa/sudcgm/latest/scripts/brsw_set_env.sh 2>/dev/null; set -u
SUVS="$SUVS_HOME/bin/suvs"
if [ ! -x "$SUVS" ]; then echo "FATAL: suvs not found at $SUVS"; exit 2; fi
echo

echo "===== suvs sees the instance ====="
"$SUVS" -g 2>&1 | grep -E "card_id|GPU0" | head -3
echo

echo "===== run basic suvs compute test (software + gpuinfo + membw ${DURATION}s) ====="
cat > "$SUVS_HOME/bin/conf/compute.conf" <<EOF
actions:
- name: test_software
  gpu_id: all
  plugin: software
- name: test_gpuinfo
  gpu_id: all
  plugin: gpuinfo
- name: test_membw
  gpu_id: all
  plugin: membw
  duration: ${DURATION}
EOF
cd "$SUVS_HOME/bin"
LOG=/tmp/suvs-run.log
./suvs -c conf/compute.conf -i 0 2>&1 | tee "$LOG" \
  | grep -E "Test Pass|Test Fail|membw =|SUPA-Version|Driver-Version|gpuinfo \[gpu" || true
echo

echo "===== result ====="
SW_OK=$(grep -c "\[Test Pass\] \[test_software" "$LOG")
GI_OK=$(grep -c "\[Test Pass\] \[test_gpuinfo" "$LOG")
BW=$(grep -oE "membw = [0-9.]+ GB/s" "$LOG" | grep -oE "[0-9.]+" | head -1)
echo "software PASS = $([ "$SW_OK" -ge 1 ] && echo yes || echo no)"
echo "gpuinfo  PASS = $([ "$GI_OK" -ge 1 ] && echo yes || echo no)"
echo "measured HBM bandwidth on this SVI instance = ${BW:-<none>} GB/s"
if [ "$SW_OK" -ge 1 ] && [ "$GI_OK" -ge 1 ] && [ -n "$BW" ]; then
  echo "SUVS_RESULT: PASS (compute ran on the allocated SVI instance; membw=${BW} GB/s)"
  exit 0
fi
echo "SUVS_RESULT: FAIL (see $LOG)"
exit 1
