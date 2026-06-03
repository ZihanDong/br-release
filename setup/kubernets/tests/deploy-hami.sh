#!/usr/bin/env bash
# Deploy HAMi with the Biren SVI backend enabled, then publish the SVI devices
# to the scheduler. Idempotent (helm upgrade --install).
#
# Prereqs:
#   - images built/loaded:   ./build-images.sh
#   - stock Biren device-plugin running (ns biren-gpu) advertising birentech.com/*
#
# After this, run ./run-svi-tests.sh to validate 1/2 and 1/4 scheduling.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"

HAMI_SRC="${HAMI_SRC:-$HOME/hami-br/HAMi-br}"
CHART="${CHART:-$HAMI_SRC/charts/hami}"
NS="${NS:-hami-system}"
RELEASE="${RELEASE:-hami}"
VALUES="${VALUES:-$HERE/hami-biren-values.yaml}"

[ -d "$CHART" ] || { err "chart not found at $CHART"; exit 1; }

log "helm upgrade --install $RELEASE -> ns $NS  (values: $VALUES)"
helm upgrade --install "$RELEASE" "$CHART" -n "$NS" --create-namespace -f "$VALUES"

log "waiting for hami-scheduler to become ready..."
kubectl -n "$NS" rollout status deploy/hami-scheduler --timeout=180s

log "publishing Biren SVI node-register annotations"
"$HERE/register-biren-nodes.sh"

echo
log "HAMi scheduler:"
kubectl get pods -n "$NS" -l app.kubernetes.io/component=hami-scheduler -o wide
ok "HAMi deployed with Biren SVI backend. Next: ./run-svi-tests.sh"
