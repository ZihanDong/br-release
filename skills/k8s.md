---
name: k8s
description: Operate the Kubernetes automation tooling in setup/kubernets/. Covers cluster install, control-plane init, worker join, node mode switching (CPU / BirenTech GPU), private registry management, and full cleanup. Read this skill before running any k8s script.
metadata:
  type: skill
  tags: [kubernetes, gpu, birentech, registry, containerd, setup, cleanup]
  scripts:
    - setup/kubernets/install.sh
    - setup/kubernets/master.sh
    - setup/kubernets/join.sh
    - setup/kubernets/set-node-mode.sh
    - setup/kubernets/k8s_clean.sh
    - setup/kubernets/registry/setup-registry.sh
    - setup/kubernets/registry/update_images.sh
    - setup/kubernets/registry/registry-trust.sh
    - setup/kubernets/registry/registry_clean.sh
---

# Skill: k8s

## Script Map

| Script | Needs root | Purpose |
|--------|-----------|---------|
| `install.sh` | yes | Install containerd + kubeadm/kubelet/kubectl on a node (Ubuntu or Kylin, auto-detected) |
| `master.sh` | yes | Init control-plane (kubeadm init + CNI); outputs join command |
| `join.sh <mode>` | yes | Join a node to an existing cluster as cpu / biren / worker |
| `set-node-mode.sh <mode>` | yes | Switch an already-joined node between cpu / biren / none |
| `k8s_clean.sh` | yes | Reset system to pre-k8s state; works on Ubuntu and Kylin; prompts before executing |
| `registry/setup-registry.sh` | yes | Deploy registry:2 in k8s; writes registry-trust.conf |
| `registry/update_images.sh` | yes | Sync images between images.conf and registry (add/purge/conf_gen) |
| `registry/registry-trust.sh <sub>` | yes (apply/remove) | Inject or remove containerd trust on local or remote nodes |
| `registry/registry_clean.sh` | yes | Remove all registry resources and data; prompts before executing |

Sample end-to-end scripts live in `setup/samples/`.

### OS-specific lib files

`install.sh` reads `/etc/os-release` and sources the correct OS variant automatically:

| File | OS | Purpose |
|------|----|---------|
| `lib/preflight-ubuntu.sh` | Ubuntu | apt deps, ufw, kernel modules |
| `lib/preflight-kylin.sh` | Kylin V10/V11 | yum deps, firewalld, copies CNI bins from `/usr/libexec/cni/` → `/opt/cni/bin/` |
| `lib/container_runtime-ubuntu.sh` | Ubuntu | Install containerd via Docker CE apt repo |
| `lib/container_runtime-kylin.sh` | Kylin V10/V11 | Configure existing containerd binary; create systemd service file if missing |
| `lib/kubeadm-ubuntu.sh` | Ubuntu | Install k8s packages via apt (pkgs.k8s.io new/legacy channels) |
| `lib/kubeadm-kylin.sh` | Kylin V10/V11 | Install k8s via yum; skip if already installed |
| `lib/init_cluster.sh` | both | Shared kubeadm init/join logic |
| `lib/common.sh` | both | Logging, OS detection, version comparison helpers |

---

## 1 — Cluster Setup

### 1.1 Install base environment (every node)

Run before init or join. Script auto-detects Ubuntu vs Kylin.

```bash
sudo bash setup/kubernets/install.sh
```

Key environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `K8S_VERSION` | `1.30` | Version to install; accepts `1.28` or `1.28.5`; supports ≥ 1.19 |
| `REGISTRY_MIRROR` | — | **Required for mainland China / Kylin environments** (registry.k8s.io unreachable). Use `registry.aliyuncs.com/google_containers` |
| `CNI_PLUGIN` | `flannel` | `flannel` \| `calico` \| `none` |
| `CONTAINERD_VERSION` | latest | Pin a specific containerd version (Ubuntu only; Kylin skips install if containerd exists) |

**Side effects:**
- Ubuntu: installs containerd via Docker CE apt repo; installs kubeadm/kubelet/kubectl with `apt-mark hold`
- Kylin: configures existing containerd (patches config, creates systemd unit if missing); installs k8s via yum if not present; copies CNI plugin binaries from `/usr/libexec/cni/` to `/opt/cni/bin/`
- Both: writes `/etc/modules-load.d/k8s.conf` (overlay, br_netfilter), `/etc/sysctl.d/99-k8s.conf`, and saves containerd config backup as `config.toml.bak.<timestamp>`

### 1.2 Initialize control-plane (master only)

```bash
sudo bash setup/kubernets/master.sh
```

Key environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `API_SERVER_ADDR` | auto-detected | Required when multiple NICs; auto-detected from default route otherwise |
| `POD_CIDR` | `10.244.0.0/16` | Pod network CIDR |
| `SVC_CIDR` | `10.96.0.0/12` | Service CIDR |
| `CNI_PLUGIN` | `flannel` | Must match install.sh |
| `REGISTRY_MIRROR` | — | If set and containerd sandbox_image still points to registry.k8s.io, master.sh auto-patches it before kubeadm init |
| `TOKEN_TTL` | `24h` | join token TTL; `0` = non-expiring |
| `JOIN_FILE` | `/root/k8s-join.sh` | Where to write the worker join command |

**Post-init state:** node carries `control-plane:NoSchedule` taint — not schedulable for workloads. Use `set-node-mode.sh` to change role.

**Outputs:**
- `/etc/kubernetes/admin.conf` — cluster admin kubeconfig
- `~/.kube/config` — user kubeconfig (auto-configured)
- `JOIN_FILE` (default `/root/k8s-join.sh`) — join command for workers

### 1.3 Join worker nodes

Copy `JOIN_FILE` from master to worker, then:

```bash
# Standard CPU worker
sudo bash setup/kubernets/join.sh worker

# CPU worker (explicit label)
sudo bash setup/kubernets/join.sh cpu

# BirenTech GPU worker
sudo bash setup/kubernets/join.sh biren
```

Join parameters are resolved in priority order:
1. `JOIN_FILE` (default `/root/k8s-join.sh`)
2. Environment variables: `MASTER_IP` + `JOIN_TOKEN` + `CA_CERT_HASH`
3. Interactive prompt

Additional variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `MASTER_PORT` | `6443` | API Server port |
| `NODE_NAME` | hostname | Override node name |
| `NODE_LABELS` | — | Comma-separated extra labels, e.g. `zone=cn-east` |
| `PLUGIN_DIR` | `packages/biren/` | (biren only) Directory containing `*.tar` image and `biren-device-plugin.yaml` |

**`join.sh biren` auto-configures:**
- Creates `/usr/bin/biren-container-runtime` symlink (via `biren-containerd-configure` or manual fallback)
- Registers biren runtime in containerd config (idempotent)
- Creates k8s RuntimeClass `biren` with `handler: runc` (if admin.conf available)

---

## 2 — Node Mode Management

Use `set-node-mode.sh` for nodes **already in the cluster** (including the master itself). Use `join.sh <mode>` when adding a node for the first time.

### Modes

| Mode | Taint | Label | Device Plugin | Schedulable |
|------|-------|-------|---------------|-------------|
| `none` | `control-plane:NoSchedule` (added) | — | — | No |
| `cpu` | removed | — | — | Yes (CPU) |
| `biren` | removed | `birentech.com=gpu` | DaemonSet deployed | Yes (GPU + CPU) |

### Usage

```bash
# Local node
sudo bash setup/kubernets/set-node-mode.sh cpu
sudo bash setup/kubernets/set-node-mode.sh biren
sudo bash setup/kubernets/set-node-mode.sh none

# Specific or multiple nodes (comma-separated)
sudo bash setup/kubernets/set-node-mode.sh biren node1,node2
```

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `KUBECONFIG` | `/etc/kubernetes/admin.conf` | kubectl config |
| `PLUGIN_DIR` | `packages/biren/` | Directory containing `*.tar` image and `biren-device-plugin.yaml` |
| `PLUGIN_NAMESPACE` | `biren-gpu` | Namespace for device plugin DaemonSet |

### Preparing packages/biren/

`packages/biren/` is gitignored (large binaries). Populate it from the release package before running biren mode:

```bash
# The release .tar.gz is a wrapper; extract it to get the inner image tar
gunzip -c /data/release/<version>/images/k8s_device_plugin_*.tar.gz \
    | tar -xf - -C packages/biren/
# Result: packages/biren/ contains k8s_device_plugin_*.tar + biren-device-plugin.yaml
```

### BirenTech Device Plugin details

- Imported from tarball into containerd `k8s.io` namespace
- Deployed as DaemonSet; node selector: `birentech.com=gpu`
- Exposes resource `birentech.com/gpu` to the scheduler
- Script auto-detects the real path of `libbiren-ml.so.1` via `realpath` and patches the DaemonSet `brml` volume `hostPath` — handles broken absolute symlinks transparently

### Requesting GPU in a Pod

```yaml
resources:
  limits:
    birentech.com/gpu: "1"
```

### Verification

```bash
# Taints and labels
kubectl describe node <node> | grep -E 'Taint|Label'

# GPU allocatable across all nodes
kubectl get nodes -o json | python3 -c "
import sys, json
for n in json.load(sys.stdin)['items']:
    print(n['metadata']['name'],
          n['status']['allocatable'].get('birentech.com/gpu', '0'), 'GPU(s)')
"

# Device plugin pods
kubectl get pods -n biren-gpu -o wide
```

---

## 3 — Private Registry

### 3.1 Deploy registry

```bash
sudo bash setup/kubernets/registry/setup-registry.sh
# or specify a custom config file:
sudo bash setup/kubernets/registry/setup-registry.sh /path/to/registry.conf
```

**What it does:**
1. Pulls `registry:2` into containerd `k8s.io` namespace (skips if already present); if docker.io is unreachable, automatically tries mirrors in order: `docker.m.daocloud.io`, `hub.uuuadc.cn`, `docker.1panel.live`
2. Creates storage directory
3. Deploys k8s Deployment + NodePort Service on the control-plane node (`REGISTRY_STORAGE_DELETE_ENABLED=true` is set automatically)
4. Waits for registry HTTP endpoint to become reachable
5. Configures local containerd trust (`certs.d`) and writes `registry-trust.conf`

**Prerequisites:** cluster must be running (`master.sh` completed).

To import/push images after the registry is running, use `update_images.sh`.

### 3.2 Configuration files

**registry.conf** — registry infrastructure settings (read by `setup-registry.sh`):

```ini
REGISTRY_STORAGE=/data/registry      # image data directory on the host
REGISTRY_PORT=32000                   # NodePort
REGISTRY_HTTP=true                    # HTTP (recommended for internal networks)
REGISTRY_K8S_NAMESPACE=kube-system   # k8s namespace for registry resources
```

**images.conf** — image source definitions (read by `update_images.sh`):

```ini
# Each [namespace.<name>] section defines one namespace.
# Paths can be files (.tar, .tar.gz) or directories (scanned recursively).
# Pushed image address: <registry-addr>/<namespace>/<image-basename>:<tag>

[namespace.base]
/path/to/base-image.tar

[namespace.infer]
/path/to/infer/                      # directory: all .tar/.tar.gz files

[namespace.k8s]
/path/to/plugin.tar.gz
```

### 3.2b Image sync (update_images.sh)

```bash
# Add missing images (default mode)
sudo bash setup/kubernets/registry/update_images.sh add

# Delete registry images not in images.conf
sudo bash setup/kubernets/registry/update_images.sh purge

# Generate a snapshot config of current registry contents
sudo bash setup/kubernets/registry/update_images.sh conf_gen

# Options
sudo bash setup/kubernets/registry/update_images.sh add \
  --config /path/to/registry.conf \
  --images /path/to/images.conf \
  --registry 192.168.1.10:32000
```

Both `add` and `purge` print a diff and prompt for confirmation before making changes. `conf_gen` writes `images.conf.generated-<timestamp>` and never overwrites existing files.

### 3.3 Distribute trust to nodes

Trust config is written to `/etc/containerd/certs.d/<addr>/hosts.toml`. containerd reads it dynamically — **no restart needed**.

```bash
# Local node
sudo bash setup/kubernets/registry/registry-trust.sh apply

# Remote nodes via SSH
sudo bash setup/kubernets/registry/registry-trust.sh apply worker01,worker02

# Custom SSH credentials
sudo bash setup/kubernets/registry/registry-trust.sh apply \
  --ssh-user <user> --ssh-key ~/.ssh/id_rsa worker01

# List active trust configs
bash setup/kubernets/registry/registry-trust.sh list
bash setup/kubernets/registry/registry-trust.sh list worker01

# Remove (without --config: lists current configs and exits)
sudo bash setup/kubernets/registry/registry-trust.sh remove
sudo bash setup/kubernets/registry/registry-trust.sh remove --config registry-trust.conf
```

### 3.4 Use registry images in Pods

```yaml
image: <registry-addr>/<namespace>/<image>:<tag>
imagePullPolicy: IfNotPresent
```

No `imagePullSecret` required — trust is at the containerd level.

### 3.5 Inspect and push manually

```bash
# List repositories
curl -s http://<registry-addr>/v2/_catalog | python3 -m json.tool

# List tags
curl -s http://<registry-addr>/v2/<namespace>/<image>/tags/list

# Push an additional image
sudo ctr -n k8s.io images import /path/to/image.tar
sudo ctr -n k8s.io images tag <source-ref> <registry-addr>/<ns>/<image>:<tag>
sudo ctr -n k8s.io images push --plain-http <registry-addr>/<ns>/<image>:<tag>
```

---

## 4 — Cleanup

Both scripts print a categorized operation summary and require explicit `y` confirmation before executing anything.

**Order matters:** always clean the registry first, then k8s — after k8s is gone the API server is unavailable and kubectl-based registry teardown will be skipped automatically.

### 4.1 registry_clean.sh — remove registry

```bash
sudo bash setup/kubernets/registry/registry_clean.sh
# custom config:
sudo bash setup/kubernets/registry/registry_clean.sh /path/to/registry.conf
```

**Removes:**
1. k8s Deployment/registry + Service/registry
2. containerd trust config (`/etc/containerd/certs.d/<addr>/`)
3. Registry storage directory (configurable, can be large)
4. `registry:2` image from containerd `k8s.io` namespace
5. `registry-trust.conf` file

**Preserves:** k8s cluster, other Deployments/Services, containerd config, BirenTech runtime.

If the API server is unreachable (e.g., cluster already torn down), step 1 is skipped automatically.

### 4.2 k8s_clean.sh — full k8s reset

Works on both Ubuntu and Kylin; auto-detects OS.

```bash
sudo bash setup/kubernets/k8s_clean.sh
```

**Removes (9 steps):**
1. `kubeadm reset -f` (with explicit `--cri-socket` on hosts with multiple CRI endpoints)
2. Packages: Ubuntu — apt purge kubeadm/kubelet/kubectl/kubernetes-cni; Kylin — yum remove
3. k8s package source: Ubuntu — apt source + GPG keyring; Kylin — yum repo file
4. Directories: `/etc/kubernetes`, `/var/lib/kubelet`, `/var/lib/etcd`, `/opt/cni`, `/var/lib/cni`, `/etc/cni/net.d`
5. `~/.kube/` for all system users
6. containerd config restored from most recent `config.toml.bak.*` backup
7. `/etc/sysctl.d/99-k8s.conf` + `/etc/modules-load.d/k8s.conf`
8. CNI interfaces (`cni0`, `flannel.1`, etc.) + iptables flush
9. `systemctl restart containerd`

**Note:** `/etc/cni/net.d/` is wiped to prevent stale CNI configs (e.g. leftover Calico conflist) from blocking the next deployment.

**Preserves:** containerd service, Docker, BirenTech runtime, registry storage, all original app data.

**Note:** Each run of `install.sh` creates a new `config.toml.bak.*`; `k8s_clean.sh` consumes the most recent one. Re-run `install.sh` before a second clean cycle.

### 4.3 Full cleanup + reinstall sequence

```bash
sudo bash setup/kubernets/registry/registry_clean.sh   # confirm y
sudo bash setup/kubernets/k8s_clean.sh                 # confirm y

# Reinstall (add REGISTRY_MIRROR for China/Kylin environments)
sudo REGISTRY_MIRROR=registry.aliyuncs.com/google_containers \
    bash setup/kubernets/install.sh
sudo REGISTRY_MIRROR=registry.aliyuncs.com/google_containers \
    bash setup/kubernets/master.sh
sudo bash setup/kubernets/set-node-mode.sh biren
sudo bash setup/kubernets/registry/setup-registry.sh
```

### 4.4 Verify clean state

```bash
# Ubuntu
dpkg -l kubeadm kubelet kubectl 2>/dev/null | grep '^[ih][ih]' || echo "packages removed"

# Kylin
rpm -q kubeadm kubelet kubectl 2>/dev/null || echo "packages removed"

# Both
pgrep -x kubelet || echo "kubelet stopped"
systemctl is-active containerd        # should be active
ls /etc/kubernetes 2>/dev/null || echo "dir removed"
```

---

## 5 — Common Issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| API Server not starting after init | Static pod convergence takes ~60s | `journalctl -u kubelet -f`; wait |
| Node stuck `NotReady` | CNI pod not yet running | Wait for Flannel/Calico DaemonSet pod to become Ready |
| kubelet BackOff loop | Multiple restarts push back-off past 5 min | `sudo systemctl restart kubelet` |
| containerd v2 plugin path error | Wrong config key | Use `io.containerd.cri.v1.runtime` (v2), not `io.containerd.grpc.v1.cri` (v1) |
| GPU count 0 after `biren` mode | Device plugin registers ~30s after rollout | Wait and re-run verification |
| `libbiren-ml.so.1` not found in container | Absolute symlink not mounted | `set-node-mode.sh` patches hostPath automatically via `realpath`; if deployed externally, trace the symlink chain manually |
| **vLLM:** `ImportError: libbesu.so.1` in pod | `biren-driver` hostPath volume missing — `LD_LIBRARY_PATH` never set for SDK libs | `k8s_yaml_gen.sh` auto-adds `biren-driver` volume (hostPath `/usr/local/birensupa/driver`); check YAML contains it |
| DaemonSet pod stuck `Pending` | Missing GPU label | Re-run `set-node-mode.sh biren` |
| `ImagePullBackOff` on workers | Trust config not injected | Run `registry-trust.sh apply <node>` on master |
| `ctr push` fails unauthorized | Missing `--plain-http` for HTTP registry | Add `--plain-http` flag |
| **Kylin:** `kubernetes-cni` not found | RPM package names differ from Ubuntu | `kubeadm-kylin.sh` installs `kubernetes-cni` as `kubernetes-cni`; if missing, check yum repo or install separately |
| **Kylin:** CoreDNS stuck `ContainerCreating` — "plugin type=calico failed" | Stale Calico CNI config in `/etc/cni/net.d/` from a previous deploy | `k8s_clean.sh` now removes `/etc/cni/net.d/`; for a running cluster: `sudo mv /etc/cni/net.d/10-calico.conflist /tmp/ && kubectl delete pod -n kube-system -l k8s-app=kube-dns` |
| **Kylin:** CoreDNS stuck — "failed to find plugin bridge in /opt/cni/bin" | CNI binaries not in expected path | `preflight-kylin.sh` now copies them from `/usr/libexec/cni/`; for a running cluster: `sudo cp /usr/libexec/cni/* /opt/cni/bin/` |
| **Kylin:** kubeadm fails — "Found multiple CRI endpoints" | Both containerd and cri-dockerd sockets present | All scripts pass `--cri-socket unix:///run/containerd/containerd.sock` explicitly |
| **Kylin:** kubelet can't pull pause image | `sandbox_image` points to `registry.k8s.io` because install.sh ran without REGISTRY_MIRROR | `master.sh patch_sandbox_image()` auto-fixes when REGISTRY_MIRROR is set; manual fix: `sudo sed -i 's|sandbox_image.*|sandbox_image = "registry.aliyuncs.com/google_containers/pause:3.8"|' /etc/containerd/config.toml && sudo systemctl restart containerd` |
| **Kylin:** `registry:2` pull hangs | docker.io unreachable | `setup-registry.sh` auto-falls back to `docker.m.daocloud.io`; or pre-pull: `sudo ctr -n k8s.io images pull docker.m.daocloud.io/library/registry:2 && sudo ctr -n k8s.io images tag docker.m.daocloud.io/library/registry:2 docker.io/library/registry:2` |
