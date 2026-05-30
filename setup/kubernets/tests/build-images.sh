#!/usr/bin/env bash
# Build & publish the images needed to run HAMi + Biren SVI on this cluster.
#
# Two images are needed on the GPU node:
#   1. the HAMi scheduler/extender image  (built here from the compiled
#      HAMi-br `scheduler` binary)
#   2. the birensupa-sdk runtime image    (the vendor SDK image, loaded from a
#      docker-save tarball)
#
# Why crane + ctr (and not docker build / docker push):
#   - This host has no rootless docker and `sudo` is the only way to reach the
#     daemon, so we build images *daemonless* with `crane` (a static binary).
#   - The cluster registry (10.50.36.126:32000) is plain-HTTP and containerd
#     does NOT honour the insecure-registry override for CRI pulls, so images
#     are also imported straight into containerd's k8s.io namespace with
#     `ctr -n k8s.io images import` (this is how the cluster already runs the
#     Biren device-plugin image). We still `crane push` to the registry so it
#     has a record / for nodes that can pull.
#
# Prereqs: the HAMi scheduler binary must already be compiled (see COMPILE
# below). Run from anywhere; uses sudo for `ctr`.
#
#   COMPILE (on a host with Go >= 1.26):
#     cd $HAMI_SRC && make build          # -> bin/scheduler
#   or the full upstream image:
#     cd $HAMI_SRC && make docker IMG_NAME=hami IMG_TAG=biren-svi
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"

HAMI_SRC="${HAMI_SRC:-$HOME/hami-br/HAMi-br}"
# Compiled scheduler binary: prefer make output, fall back to repo root copy.
SCHED_BIN="${SCHED_BIN:-$([ -x "$HAMI_SRC/bin/scheduler" ] && echo "$HAMI_SRC/bin/scheduler" || echo "$HAMI_SRC/scheduler")}"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:24.04}"          # glibc base for the Go binary (needs >= 2.34)
HAMI_IMAGE="${HAMI_IMAGE:-$REGISTRY/hami/hami:biren-svi}"

SDK_TAR="${SDK_TAR:-/data/release/2604rc2/images/birensupa-sdk-26.04.rc2-br1xx.tar}"
SDK_IMAGE="${SDK_IMAGE:-$REGISTRY/base/birensupa-sdk:26.04.rc2-br1xx}"

CRANE="${CRANE:-$HERE/bin/crane}"
CRANE_VER="${CRANE_VER:-v0.20.2}"

ensure_crane(){
  command -v crane >/dev/null 2>&1 && { CRANE=crane; return; }
  [ -x "$CRANE" ] && return
  log "downloading crane $CRANE_VER"
  mkdir -p "$(dirname "$CRANE")"
  curl -sSL "https://github.com/google/go-containerregistry/releases/download/$CRANE_VER/go-containerregistry_Linux_x86_64.tar.gz" \
    | tar -xz -C "$(dirname "$CRANE")" crane
  chmod +x "$CRANE"
}

build_hami_image(){
  [ -x "$SCHED_BIN" ] || { err "scheduler binary not found at $SCHED_BIN (run 'make build' in $HAMI_SRC)"; exit 1; }
  log "building HAMi image $HAMI_IMAGE  (base $BASE_IMAGE + $SCHED_BIN)"
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/root/usr/local/bin"
  install -m0755 "$SCHED_BIN" "$tmp/root/usr/local/bin/scheduler"
  tar -C "$tmp/root" -cf "$tmp/layer.tar" usr
  # base layers + our layer are pushed to the registry (self-contained)
  "$CRANE" append -b "$BASE_IMAGE" -f "$tmp/layer.tar" -t "$HAMI_IMAGE" --insecure
  log "importing $HAMI_IMAGE into containerd (k8s.io)"
  "$CRANE" pull --insecure --format=tarball "$HAMI_IMAGE" "$tmp/hami.tar"
  sudo ctr -n k8s.io images import "$tmp/hami.tar" >/dev/null
  rm -rf "$tmp"
  ok "HAMi image ready: $HAMI_IMAGE"
}

load_sdk_image(){
  [ -f "$SDK_TAR" ] || { log "SDK tar $SDK_TAR not found; skipping SDK image"; return; }
  log "pushing SDK image $SDK_IMAGE from $SDK_TAR"
  "$CRANE" push "$SDK_TAR" "$SDK_IMAGE" --insecure || true
  log "importing SDK image into containerd (k8s.io)"
  sudo ctr -n k8s.io images import "$SDK_TAR" >/dev/null
  # docker-save tar imports under its embedded repo tag; retag to the ref pods use.
  local src; src="$(tar xOf "$SDK_TAR" manifest.json | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["RepoTags"][0])')"
  sudo ctr -n k8s.io images tag --force "docker.io/library/$src" "$SDK_IMAGE" 2>/dev/null \
    || sudo ctr -n k8s.io images tag --force "$src" "$SDK_IMAGE"
  ok "SDK image ready: $SDK_IMAGE"
}

ensure_crane
build_hami_image
load_sdk_image
log "images present in containerd:"
sudo crictl images 2>/dev/null | grep -E "hami/hami|birensupa-sdk" || true
