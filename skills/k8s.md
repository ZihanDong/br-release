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
| `install.sh` | yes | Install containerd + kubeadm/kubelet/kubectl on a node |
| `master.sh` | yes | Init control-plane (kubeadm init + CNI); outputs join command |
| `join.sh <mode>` | yes | Join a node to an existing cluster as cpu / biren / worker |
| `set-node-mode.sh <mode>` | yes | Switch an already-joined node between cpu / biren / none |
| `k8s_clean.sh` | yes | Reset system to pre-k8s state; prompts before executing |
| `registry/setup-registry.sh` | yes | Deploy registry:2 in k8s; writes registry-trust.conf |
| `registry/update_images.sh` | yes | Sync images between images.conf and registry (add/purge/conf_gen) |
| `registry/registry-trust.sh <sub>` | yes (apply/remove) | Inject or remove containerd trust on local or remote nodes |
| `registry/registry_clean.sh` | yes | Remove all registry resources and data; prompts before executing |

Sample end-to-end scripts live in `setup/samples/`.

---

## 1 — Cluster Setup

### 1.1 Install base environment (every node)

Run before init or join:

```bash
sudo bash setup/kubernets/install.sh
```

Key environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `K8S_VERSION` | `1.30` | Version to install; accepts `1.28` or `1.28.5`; supports ≥ 1.19 |
| `REGISTRY_MIRROR` | — | Image mirror (e.g. `registry.aliyuncs.com/google_containers`) for air-gapped environments |
| `CNI_PLUGIN` | `flannel` | `flannel` \| `calico` \| `none` |
| `CONTAINERD_VERSION` | latest | Pin a specific containerd version |

**Side effects:**
- Installs containerd; if already present, patches config in-place and saves backup as `config.toml.bak.<timestamp>`
- Installs kubeadm / kubelet / kubectl with `apt-mark hold`
- Writes `/etc/modules-load.d/k8s.conf` (overlay, br_netfilter) and `/etc/sysctl.d/99-k8s.conf`

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
1. Pulls `registry:2` into containerd `k8s.io` namespace (skips if already present)
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

```bash
sudo bash setup/kubernets/k8s_clean.sh
```

**Removes (9 steps):**
1. `kubeadm reset -f`
2. Packages: kubeadm, kubelet, kubectl, kubernetes-cni (including `hi` hold-state packages)
3. k8s apt source + GPG keyring
4. Directories: `/etc/kubernetes`, `/var/lib/kubelet`, `/var/lib/etcd`, `/opt/cni`, `/var/lib/cni`
5. `~/.kube/` for all system users
6. containerd config restored from most recent `config.toml.bak.*` backup
7. `/etc/sysctl.d/99-k8s.conf` + `/etc/modules-load.d/k8s.conf`
8. CNI interfaces (`cni0`, `flannel.1`, etc.) + iptables flush
9. `systemctl restart containerd`

**Preserves:** containerd service, Docker, BirenTech runtime, registry storage, all original app data.

**Note:** Each run of `install.sh` creates a new `config.toml.bak.*`; `k8s_clean.sh` consumes the most recent one. Re-run `install.sh` before a second clean cycle.

### 4.3 Full cleanup + reinstall sequence

```bash
sudo bash setup/kubernets/registry/registry_clean.sh   # confirm y
sudo bash setup/kubernets/k8s_clean.sh                 # confirm y

# Reinstall
sudo bash setup/kubernets/install.sh
sudo bash setup/kubernets/master.sh
sudo bash setup/kubernets/set-node-mode.sh biren
sudo bash setup/kubernets/registry/setup-registry.sh
```

### 4.4 Verify clean state

```bash
dpkg -l kubeadm kubelet kubectl 2>/dev/null | grep '^[ih][ih]' || echo "packages removed"
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
| DaemonSet pod stuck `Pending` | Missing GPU label | Re-run `set-node-mode.sh biren` |
| `ImagePullBackOff` on workers | Trust config not injected | Run `registry-trust.sh apply <node>` on master |
| `ctr push` fails unauthorized | Missing `--plain-http` for HTTP registry | Add `--plain-http` flag |
| `kubernetes-cni` purge blocked by held packages | `apt purge` respects dependency order | `apt-mark unhold` all k8s packages first, then purge together |
