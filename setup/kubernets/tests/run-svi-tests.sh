#!/usr/bin/env bash
# End-to-end validation: HAMi schedules Biren SVI (1/2 and 1/4) vGPU instances,
# then runs a basic sudcgm/suvs compute test inside each scheduled pod.
#
# Prereqs (see README.md):
#   - HAMi deployed with the Biren backend enabled (helm -f hami-biren-values.yaml,
#     extender image hami/hami:biren-svi, scheduler arg --enable-biren=true).
#   - Stock biren-device-plugin running; SVI enabled on some GPUs
#     (brsmi gpu set -s 1 -i <gpu> => 1/2 ; -s 2 => 1/4).
#   - SDK image present on the node as
#     ${REGISTRY}/base/birensupa-sdk:26.04.rc2-br1xx (see README "images").
#   - node-register annotations published: ./register-biren-nodes.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"

FAILS=0

run_one(){
  local label="$1" manifest="$2" pod="$3" common="$4"
  echo; log "============ TEST: $label ============"
  kubectl delete pod "$pod" -n default --ignore-not-found --force --grace-period=0 >/dev/null 2>&1
  kubectl apply -f "$manifest" >/dev/null
  log "waiting for pod $pod to run (HAMi scheduling + container start)..."
  if ! wait_pod_running "$pod" default 300; then
    err "$label: pod did not reach Running"
    kubectl describe pod "$pod" -n default | grep -A12 Events: | tail -14
    FAILS=$((FAILS+1)); return 1
  fi

  # Prove HAMi (not the default scheduler) placed the pod AND allocated an SVI
  # instance: the scheduler's Filter writes hami.io/<commonWord>-devices-allocated.
  local sched node alloc
  sched=$(kubectl get pod "$pod" -n default -o jsonpath='{.spec.schedulerName}')
  node=$(kubectl get pod "$pod" -n default -o jsonpath='{.spec.nodeName}')
  alloc=$(kubectl get pod "$pod" -n default -o jsonpath="{.metadata.annotations.hami\.io/${common}-devices-allocated}")
  local card; card=$(kubectl exec "$pod" -n default -- sh -c 'echo -n "$BR_PHY_CARDS"' 2>/dev/null)
  echo "   schedulerName = $sched"
  echo "   node          = $node"
  echo "   HAMi allocated= ${alloc:-<none>}"
  echo "   injected card = ${card:-<none>}"
  if [[ "$sched" == "hami-scheduler" && -n "$alloc" && -n "$card" ]]; then
    ok "$label: HAMi scheduled the pod onto an SVI instance"
  else
    err "$label: HAMi scheduling not confirmed"
    FAILS=$((FAILS+1)); return 1
  fi

  # Run the in-pod suvs compute test on the allocated instance.
  log "installing sudcgm + running suvs compute test inside pod (takes ~2-3 min)..."
  kubectl cp "$HERE/in-pod-suvs.sh" "default/$pod:/tmp/in-pod-suvs.sh" >/dev/null 2>&1
  kubectl exec "$pod" -n default -- bash /tmp/in-pod-suvs.sh 2>&1 | tee "/tmp/${pod}-suvs.log"
  if grep -q "SUVS_RESULT: PASS" "/tmp/${pod}-suvs.log"; then
    ok "$label: suvs compute test PASS ($(grep -oE 'membw=[0-9.]+ GB/s' "/tmp/${pod}-suvs.log" | head -1))"
  else
    err "$label: suvs compute test did not pass (see /tmp/${pod}-suvs.log)"
    FAILS=$((FAILS+1))
  fi
}

echo "### HAMi scheduler ###"
kubectl get pods -n hami-system -l app.kubernetes.io/component=hami-scheduler 2>/dev/null | tail -n +1
echo "### Node biren allocatable ###"
kubectl get node "$NODE" -o json | python3 -c "import sys,json;a=json.load(sys.stdin)['status']['allocatable'];[print('   ',k,'=',v) for k,v in sorted(a.items()) if 'birentech' in k]"

run_one "SVI 1/2 (half GPU)"    "$HERE/svi-1of2-test.yaml" biren-svi-1of2-test Biren-1of2
run_one "SVI 1/4 (quarter GPU)" "$HERE/svi-1of4-test.yaml" biren-svi-1of4-test Biren-1of4

echo
if [[ "$FAILS" -eq 0 ]]; then
  ok "ALL TESTS PASSED — HAMi manages Biren SVI 1/2 and 1/4 vGPU scheduling."
else
  err "$FAILS check(s) failed."
fi
log "pods left running for inspection; clean up with:"
echo "   kubectl delete pod -l app=biren-svi-test -n default"
exit "$FAILS"
