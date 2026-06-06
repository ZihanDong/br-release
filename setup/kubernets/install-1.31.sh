#!/usr/bin/env bash
# install-1.31.sh — Kubernetes 1.31 + Docker 28.x + containerd 2.x installer/upgrader
# for Kylin V10 (kernel 4.19, cgroup v1), preserving the Biren GPU runtime + images.
#
# WHY static binaries for the runtime: this cluster's docker/containerd were installed
# as STATIC BINARIES in /usr/bin (rpm -q docker-ce = not installed). The docker-ce/
# containerd.io RPMs in download.docker.com resolve to `.el10` (glibc ≥2.34) which does
# NOT match Kylin V10 (glibc 2.28). So we install docker 28.x + containerd 2.x + runc
# from the upstream **static tarballs** (proven method on this box). K8s (kubelet/
# kubeadm/kubectl) uses pkgs.k8s.io v1.31 RPMs (the existing 1.25 was rpm-installed too).
#
# Upgrade is image-preserving: /var/lib/containerd and /var/lib/docker are NOT wiped;
# `kubeadm reset` removes the control-plane/etcd but leaves the image content store.
#
# Usage:
#   sudo ROLE=control-plane ./install-1.31.sh
#   sudo ROLE=worker JOIN_COMMAND="kubeadm join 1.2.3.4:6443 --token ... \
#        --discovery-token-ca-cert-hash sha256:..." ./install-1.31.sh
#   sudo ROLE=runtime-only ./install-1.31.sh        # upgrade docker/containerd/k8s pkgs only (no reset/init)
#
# Env (defaults shown):
#   ROLE=control-plane | worker | runtime-only
#   K8S_VERSION=1.31  DOCKER_VERSION=28.5.2  CONTAINERD_VERSION=2.2.4  RUNC_VERSION=1.2.6
#   PAUSE_IMAGE=registry.aliyuncs.com/google_containers/pause:3.10
#   POD_CIDR=10.244.0.0/16   API_SERVER_ADDR=<auto>   CNI=flannel
#   CACHE_DIR=/root/upgrade-cache   (prebuilt tarballs; else downloaded via $https_proxy)
#   BIREN_RUNTIME_BIN=/usr/local/birensupa/container-toolkit/biren-container-toolkit/bin/biren-container-runtime
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${ROLE:=control-plane}"
: "${K8S_VERSION:=1.31}"
: "${DOCKER_VERSION:=28.5.2}"
: "${CONTAINERD_VERSION:=2.2.4}"
: "${RUNC_VERSION:=1.2.6}"
: "${PAUSE_IMAGE:=registry.aliyuncs.com/google_containers/pause:3.10}"
: "${POD_CIDR:=10.244.0.0/16}"
: "${CNI:=flannel}"
: "${CACHE_DIR:=/root/upgrade-cache}"
: "${JOIN_COMMAND:=}"
: "${API_SERVER_ADDR:=}"
: "${BIREN_RUNTIME_BIN:=/usr/local/birensupa/container-toolkit/biren-container-toolkit/bin/biren-container-runtime}"
# Kylin V10 is glibc 2.28; ALL prebuilt containerd 2.x (upstream static, el9, el10)
# need glibc >= 2.34, so we use a CGO_ENABLED=0 source build (statically linked,
# glibc-independent). Prebuilt static binaries are expected in CONTAINERD_STATIC_DIR;
# if absent, they are built from source here (needs the Go toolchain).
: "${CONTAINERD_STATIC_DIR:=${CACHE_DIR}/containerd-static}"
: "${GO_VERSION:=go1.26.4}"
CC=/etc/containerd/config.toml

log(){ printf '\033[1;36m[install-1.31]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[install-1.31] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "run as root (sudo)"

DL(){ # url out
  [ -f "$2" ] && { log "cached: $2"; return; }
  log "downloading $1"
  curl -fsSL --retry 3 -o "$2" "$1" || die "download failed: $1"
}

build_containerd_static(){
  # Build containerd ${CONTAINERD_VERSION} with CGO_ENABLED=0 -> statically linked
  # binaries that run on glibc 2.28. Needs Go (installed here if absent).
  log "building containerd ${CONTAINERD_VERSION} from source (CGO_ENABLED=0, glibc-independent)"
  if ! /usr/local/go/bin/go version >/dev/null 2>&1; then
    DL "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz" "$CACHE_DIR/${GO_VERSION}.linux-amd64.tar.gz"
    rm -rf /usr/local/go; tar -C /usr/local -xzf "$CACHE_DIR/${GO_VERSION}.linux-amd64.tar.gz"
  fi
  DL "https://github.com/containerd/containerd/archive/refs/tags/v${CONTAINERD_VERSION}.tar.gz" "$CACHE_DIR/containerd-src-${CONTAINERD_VERSION}.tar.gz"
  local d; d="$(mktemp -d)"; tar -C "$d" -xzf "$CACHE_DIR/containerd-src-${CONTAINERD_VERSION}.tar.gz"
  ( cd "$d/containerd-${CONTAINERD_VERSION}"
    PATH=/usr/local/go/bin:$PATH GOCACHE=/tmp/gocache GOPATH=/tmp/gopath GOFLAGS=-mod=vendor GOPROXY=off CGO_ENABLED=0 \
      make VERSION="v${CONTAINERD_VERSION}" REVISION=source-cgo0 bin/containerd bin/containerd-shim-runc-v2 bin/ctr )
  mkdir -p "$CONTAINERD_STATIC_DIR"
  install -m0755 "$d/containerd-${CONTAINERD_VERSION}"/bin/{containerd,containerd-shim-runc-v2,ctr} "$CONTAINERD_STATIC_DIR/"
  rm -rf "$d"
}

fetch_binaries(){
  mkdir -p "$CACHE_DIR"
  DL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" "$CACHE_DIR/docker-${DOCKER_VERSION}.tgz"
  DL "https://github.com/opencontainers/runc/releases/download/v${RUNC_VERSION}/runc.amd64" "$CACHE_DIR/runc.amd64"
  # containerd: static CGO-free build (prebuilt in CONTAINERD_STATIC_DIR, else build now)
  [ -x "$CONTAINERD_STATIC_DIR/containerd" ] || build_containerd_static
}

stop_services(){
  log "stopping kubelet / docker / containerd (images on disk are preserved)"
  systemctl stop kubelet 2>/dev/null || true
  systemctl stop docker docker.socket 2>/dev/null || true
  systemctl stop containerd 2>/dev/null || true
}

install_binaries(){
  local t; t="$(mktemp -d)"
  # containerd 2.x (system runtime for k8s CRI): statically-linked CGO-free build
  install -m0755 "$CONTAINERD_STATIC_DIR"/containerd "$CONTAINERD_STATIC_DIR"/containerd-shim-runc-v2 "$CONTAINERD_STATIC_DIR"/ctr /usr/bin/
  # runc >= 1.2 (required by containerd 2.x)
  install -m0755 "$CACHE_DIR/runc.amd64" /usr/bin/runc
  # docker 28.x: take ONLY the docker engine bits (use the standalone containerd/runc above)
  tar -C "$t" -xzf "$CACHE_DIR/docker-${DOCKER_VERSION}.tgz"
  install -m0755 "$t"/docker/dockerd "$t"/docker/docker "$t"/docker/docker-proxy "$t"/docker/docker-init /usr/bin/
  rm -rf "$t"
  log "binaries: containerd=$(containerd --version|awk '{print $3}') runc=$(runc --version|awk 'NR==1{print $3}') docker=$(dockerd --version|awk '{print $3}'|tr -d ,)"
}

write_containerd_config(){
  # containerd 2.x uses config version 3. Migrate the existing v2 config (which carries
  # the biren runtime) when possible; otherwise generate default + re-inject biren.
  mkdir -p /etc/containerd
  local bak="${CC}.v2-$(date +%s)"
  [ -f "$CC" ] && cp -a "$CC" "$bak" && log "backed up old config -> $bak"
  if [ -f "$bak" ] && containerd config migrate < "$bak" > "${CC}.new" 2>/dev/null && grep -q 'version = 3' "${CC}.new"; then
    mv "${CC}.new" "$CC"; log "containerd config migrated v2 -> v3 (biren runtime preserved)"
  else
    log "migrate unavailable; generating default v3 config + injecting biren runtime"
    containerd config default > "$CC"
    # add biren runtime cloned from runc, set as default (CRI v1 runtime plugin, v3 schema)
    python3 - "$CC" "$BIREN_RUNTIME_BIN" <<'PY'
import re,sys
cc,binbn=sys.argv[1],sys.argv[2]
s=open(cc).read()
# duplicate the [...runtimes.runc] table as [...runtimes.biren] with BinaryName
m=re.search(r'(\[plugins\.[\'"]io\.containerd\.cri\.v1\.runtime[\'"]\.containerd\.runtimes\.runc\][\s\S]*?)(?=\n\[plugins|\Z)',s)
if m:
    blk=m.group(1).replace('runtimes.runc','runtimes.biren')
    if 'BinaryName' not in blk:
        blk=re.sub(r'(\.options\][^\[]*)',lambda x:x.group(1).rstrip()+f'\n      BinaryName = "{binbn}"\n',blk,count=1)
    s=s[:m.end()]+"\n"+blk+s[m.end():]
s=re.sub(r'default_runtime_name = "runc"','default_runtime_name = "biren"',s)
open(cc,'w').write(s)
PY
  fi
  # ensure SystemdCgroup=true (cgroup v1 + systemd), default_runtime_name=biren, pause tag.
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' "$CC"
  # bump the pause tag in place (quote-agnostic; handles v2 `sandbox_image="..."` and the
  # migrated v3 single-quoted `sandbox = '...pause:X.Y'`).
  local ptag="${PAUSE_IMAGE##*:}"
  sed -i -E "s#pause:[0-9]+\.[0-9]+#pause:${ptag}#g" "$CC"
  grep -qE "default_runtime_name = ['\"]biren['\"]" "$CC" || sed -i -E "s/default_runtime_name = .*/default_runtime_name = 'biren'/" "$CC"
  grep -q "$BIREN_RUNTIME_BIN" "$CC" || log "WARN: biren runtime BinaryName not found in config — check $CC"
}

ensure_services(){
  # containerd.service
  if [ ! -f /usr/lib/systemd/system/containerd.service ] && [ ! -f /etc/systemd/system/containerd.service ]; then
    cat > /etc/systemd/system/containerd.service <<'EOF'
[Unit]
Description=containerd container runtime
After=network.target local-fs.target
[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/bin/containerd
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999
[Install]
WantedBy=multi-user.target
EOF
  fi
  systemctl daemon-reload
  systemctl enable --now containerd
  systemctl restart docker 2>/dev/null || systemctl start docker 2>/dev/null || true
}

verify_runtime(){
  log "verifying containerd 2.x is up and images are intact..."
  systemctl is-active --quiet containerd || die "containerd not active (check: journalctl -u containerd)"
  ctr -n k8s.io images ls -q 2>/dev/null | head -1 >/dev/null || log "WARN: ctr images query returned nothing"
  log "containerd images (k8s.io ns): $(ctr -n k8s.io images ls -q 2>/dev/null | wc -l) entries preserved"
}

install_k8s_pkgs(){
  log "adding pkgs.k8s.io v${K8S_VERSION} repo + installing kubelet/kubeadm/kubectl ${K8S_VERSION}"
  cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes v${K8S_VERSION}
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
  local P="${https_proxy:+--setopt=proxy=$https_proxy}"
  dnf -y $P --disableexcludes=kubernetes install kubelet kubeadm kubectl $P || die "k8s pkg install failed"
  systemctl enable kubelet 2>/dev/null || true
  log "k8s pkgs: $(kubeadm version -o short)"
}

reset_cluster(){
  log "kubeadm reset (control-plane/etcd wiped; image store preserved)"
  kubeadm reset -f 2>/dev/null || true
  rm -rf /etc/cni/net.d/* 2>/dev/null || true
}

init_control_plane(){
  reset_cluster
  local addr="${API_SERVER_ADDR:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')}"
  log "kubeadm init ${K8S_VERSION} (apiserver=${addr}, pod-cidr=${POD_CIDR})"
  kubeadm init --kubernetes-version "v${K8S_VERSION}" \
    --apiserver-advertise-address "${addr}" --pod-network-cidr "${POD_CIDR}" \
    --image-repository registry.aliyuncs.com/google_containers --cri-socket unix:///run/containerd/containerd.sock \
    || die "kubeadm init failed (journalctl -u kubelet)"
  mkdir -p /root/.kube; cp -f /etc/kubernetes/admin.conf /root/.kube/config
  export KUBECONFIG=/etc/kubernetes/admin.conf
  if [ "$CNI" = flannel ]; then
    log "applying flannel CNI"
    kubectl apply -f "${SCRIPT_DIR}/registry/kube-flannel.yml" 2>/dev/null \
      || kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
  fi
  log "control-plane up: $(kubectl get node -o name 2>/dev/null)"
}

join_worker(){
  reset_cluster
  [ -n "$JOIN_COMMAND" ] || die "ROLE=worker requires JOIN_COMMAND"
  log "joining cluster..."
  eval "${JOIN_COMMAND} --cri-socket unix:///run/containerd/containerd.sock" || die "kubeadm join failed"
}

main(){
  log "ROLE=$ROLE  k8s=$K8S_VERSION docker=$DOCKER_VERSION containerd=$CONTAINERD_VERSION runc=$RUNC_VERSION"
  fetch_binaries
  stop_services
  install_binaries
  write_containerd_config
  ensure_services
  verify_runtime
  install_k8s_pkgs
  case "$ROLE" in
    control-plane) init_control_plane ;;
    worker)        join_worker ;;
    runtime-only)  log "runtime-only: skipping kubeadm reset/init" ;;
    *) die "unknown ROLE=$ROLE" ;;
  esac
  log "DONE. Versions:"
  log "  $(containerd --version) | runc $(runc --version|awk 'NR==1{print $3}') | $(dockerd --version) | $(kubeadm version -o short)"
}
main "$@"
