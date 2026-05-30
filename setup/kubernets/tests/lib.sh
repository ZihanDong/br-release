#!/usr/bin/env bash
# Common helpers for HAMi + Biren SVI tests.
# kubectl must bypass the corporate proxy for the cluster API / registry.
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export NO_PROXY="10.50.36.126,10.96.0.0/12,10.244.0.0/16,localhost,127.0.0.1,.svc,.cluster.local,gpu-master"
export no_proxy="$NO_PROXY"
REGISTRY="${REGISTRY:-10.50.36.126:32000}"
NODE="${NODE:-$(hostname -s)}"
log(){ printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok(){  printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; }
k(){ kubectl "$@"; }
# wait_pod_running <name> <ns> <timeoutSec>
wait_pod_running(){
  local n="$1" ns="${2:-default}" t="${3:-120}" i
  for ((i=0;i<t;i+=5)); do
    local ph; ph=$(kubectl get pod "$n" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)
    [[ "$ph" == "Running" || "$ph" == "Succeeded" ]] && return 0
    [[ "$ph" == "Failed" ]] && return 1
    sleep 5
  done
  return 1
}
