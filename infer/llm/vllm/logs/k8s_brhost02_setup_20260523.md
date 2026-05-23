# brhost-02 (172.25.198.37) — K8s GPU Worker Node Setup Log
**Date:** 2026-05-23  
**Objective:** Add brhost-02 (Kylin V10, 8×Biren166M GPUs) as a k8s worker node to the existing cluster (master: brhost-01 / 172.25.198.36), deploy bge-m3 embedding and Qwen3-32B chat services, and test both.

---

## 1. Environment

| Item | Value |
|---|---|
| Master | brhost-01 / 172.25.198.36 (k8s control-plane) |
| Worker | brhost-02 / 172.25.198.37 (new GPU node) |
| OS | Kylin Linux Advanced Server V10 (Lance) |
| Kernel | 4.19.90-52.22.v2207.ky10.x86_64 |
| k8s | v1.25.3 |
| Container runtime | containerd 1.7.15 |
| GPU | 8 × Biren166M (65024MiB each) |
| GPU Driver | BirenTech SDK 1.11.0 |
| CNI | Flannel |
| Local registry | 172.25.198.36:32000 (HTTP, no TLS) |

---

## 2. File Transfer Method

**scp fails silently** (reports exit 0 but files don't appear). rsync fails with "protocol version mismatch" because `.bashrc` on the remote prints to stdout during non-interactive SSH sessions, corrupting the rsync protocol.

**Fix:** Use SSH pipe for all file transfers:
```bash
# Transfer a single file
cat localfile | ssh br166@172.25.198.37 "cat > /remote/path/file"

# Transfer a directory (4.3GB example)
tar -C /data/models/BAAI/bge-m3 -cf - . | ssh br166@172.25.198.37 \
    "mkdir -p /data/models/BAAI/bge-m3 && tar -C /data/models/BAAI/bge-m3 -xf -"
```

---

## 3. K8s Worker Node Setup

### 3.1 Reset Old Cluster State on brhost-02
```bash
sudo kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock
sudo rm -rf /etc/cni/net.d/ /var/lib/cni/ /var/lib/kubelet/ /etc/kubernetes/
```

### 3.2 containerd Configuration

**Problem:** `sandbox_image` pointed to `registry.k8s.io/pause:3.8` (unreachable from remote).  
**Fix:** Changed to `registry.aliyuncs.com/google_containers/pause:3.8` and pre-loaded the image.

Transfer pause image from master:
```bash
docker save registry.aliyuncs.com/google_containers/pause:3.8 | \
    ssh br166@172.25.198.37 "sudo ctr -n k8s.io images import -"
# Also tag for registry.k8s.io compatibility:
ssh br166@172.25.198.37 "sudo ctr -n k8s.io images tag \
    registry.aliyuncs.com/google_containers/pause:3.8 registry.k8s.io/pause:3.8"
```

**Problem:** Local registry at 172.25.198.36:32000 uses HTTP; containerd rejects by default.  
**Fix:** Set `config_path = "/etc/containerd/certs.d"` in `/etc/containerd/config.toml` (line 172) and create:

`/etc/containerd/certs.d/172.25.198.36:32000/hosts.toml`:
```toml
server = "http://172.25.198.36:32000"
[host."http://172.25.198.36:32000"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
```

### 3.3 Biren Runtime Setup

**Install biren-containerd-configure:**
```bash
# Transfer biren device plugin package from master
cat /home/br166/br-release/packages/biren/k8s_device_plugin_v0.7.6-188-899ca76.tar | \
    ssh br166@172.25.198.37 "cat > /tmp/biren_plugin.tar"

# On remote: extract and configure
tar -xf /tmp/biren_plugin.tar
sudo bash biren-containerd-configure configure  # adds biren runtime to containerd config
```

**Problem:** `biren-containerd-configure` requires `/usr/bin/biren-container-runtime` to exist.  
**Fix:**
```bash
sudo ln -sf /usr/local/birensupa/container-toolkit/biren-container-toolkit/bin/biren-container-runtime \
    /usr/bin/biren-container-runtime
```

**Create RuntimeClass in k8s** (from master):
```yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: biren
handler: runc
```
```bash
kubectl apply -f runtime_class_biren.yaml
```

### 3.4 Dependencies

**Problem:** `kubeadm join` fails: `conntrack not found`.  
**Problem:** `dnf`/`yum` broken because `/usr/bin/python3` symlink points to user-compiled Python 3.10.12 instead of system Python 3.7 needed by dnf.  
**Fix:**
```bash
sudo /usr/bin/python3.7 /usr/bin/dnf install -y conntrack-tools socat
```

### 3.5 Cluster Join

```bash
# On master — generate join command
kubeadm token create --print-join-command

# On brhost-02
sudo kubeadm join 172.25.198.36:6443 --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH> \
    --cri-socket unix:///run/containerd/containerd.sock
```

**Problem:** "Found multiple CRI endpoints" (both containerd and cri-dockerd).  
**Fix:** Specify `--cri-socket unix:///run/containerd/containerd.sock` explicitly.

### 3.6 CNI Restoration

**Problem:** Old Calico CNI configs in `/etc/cni/net.d/` from previous cluster prevented Flannel from working.  
**Fix:**
```bash
sudo rm -rf /etc/cni/net.d/
kubectl delete pod kube-flannel-ds-<pod-id> -n kube-flannel  # force re-init
# Then restart both:
sudo systemctl restart containerd
sudo systemctl restart kubelet
```

### 3.7 GPU Device Plugin

```bash
# On master — load device plugin image into brhost-02
docker save k8s_device_plugin:v0.7.6-188-899ca76 | \
    ssh br166@172.25.198.37 "sudo ctr -n k8s.io images import -"

# Apply DaemonSet on master
kubectl apply -f /home/br166/br-release/packages/biren/biren-device-plugin.yaml
```

Verify: `kubectl describe node brhost-02 | grep birentech` → `birentech.com/gpu: 8`

---

## 4. vLLM Container: GPU Library Access Fix

**Problem:** The vLLM container image (`birensupa-smartinfer-vllm:26.04.rc2-...`) does not include the BirenTech driver library directory (`/usr/local/birensupa/driver/`). When the container starts:

1. `brsw_set_env.sh` inside the container tries to source `/usr/local/birensupa/driver/scripts/brsw_set_env.sh`
2. Without this file, `LD_LIBRARY_PATH` is never set to include `/usr/local/birensupa/driver/brumd/lib/`
3. Python `import torch_br._C` fails with: `ImportError: libbesu.so.1: cannot open shared object file`

**Fix:** Mount the host's `/usr/local/birensupa/driver` directory into the container at the same path. This makes the driver scripts available, causing `brsw_set_env.sh` to set `LD_LIBRARY_PATH` correctly on startup.

Added to `k8s_yaml_gen.sh` template:
```yaml
volumeMounts:
- name: biren-driver
  mountPath: /usr/local/birensupa/driver
  readOnly: true
volumes:
- name: biren-driver
  hostPath:
    path: /usr/local/birensupa/driver
    type: Directory
```

Also required: `privileged: true` and explicit `BIREN_VISIBLE_DEVICES` env var:
```yaml
securityContext:
  privileged: true
  capabilities:
    add:
    - IPC_LOCK
env:
- name: BIREN_VISIBLE_DEVICES
  value: "0,1"   # one index per GPU requested
```

---

## 5. Model Weight Transfer

**bge-m3** (4.3GB) — transferred from master via SSH pipe tar:
```bash
tar -C /data/models/BAAI/bge-m3 -cf - . | ssh br166@172.25.198.37 \
    "tar -C /data/models/BAAI/bge-m3 -xf -"
```

**Qwen3-32B** — already present on brhost-02's `/data/models/Qwen/Qwen3-32B` (no transfer needed).

---

## 6. Service Deployment

### Generate and apply YAML

```bash
# On master
bash infer/llm/vllm/k8s_yaml_gen.sh qwen3-32b
bash infer/llm/vllm/k8s_yaml_gen.sh bge-m3
kubectl apply -f infer/llm/vllm/k8s_yaml_gen/qwen3-32b.yaml
kubectl apply -f infer/llm/vllm/k8s_yaml_gen/bge-m3.yaml
```

### Config overrides (configs/*.conf)

| Model | Key settings |
|---|---|
| qwen3-32b | tp=2, pp=1, port=28800, nodeport=30801, k8s_node_name=brhost-02 |
| bge-m3 | tp=1, pp=1, port=28800, nodeport=30800, k8s_node_name=brhost-02, task=embed, enforce_eager=true |

---

## 7. Startup Sequence (Qwen3-32B — 2 GPUs)

| Step | Duration |
|---|---|
| Platform init + torch_br load | ~5s |
| Parallel state init (tp=2 via Gloo) | ~3s |
| Safetensors shard loading (17 shards) | ~28s |
| KV cache memory profiling | ~2s |
| SUPA graph capture (11 sizes) | ~5s |
| Total init engine | ~15s |
| **API server ready** | **~60s total** |

KV cache: **145,408 tokens** (50.80GiB usable, 32.67GiB model weights, 17.89GiB for KV cache, per GPU with 0.8 utilization)

---

## 8. Verification

```bash
# Health checks (bypass http_proxy)
NO_PROXY='*' http_proxy='' curl http://172.25.198.37:30801/health  # qwen3-32b
NO_PROXY='*' http_proxy='' curl http://172.25.198.37:30800/health  # bge-m3

# Or via pod IP from master (no proxy needed):
curl http://10.244.1.10:28800/health   # qwen3-32b pod
curl http://10.244.1.11:28800/health   # bge-m3 pod

# Chat completion (Qwen3-32B)
NO_PROXY='*' http_proxy='' curl http://172.25.198.37:30801/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"Qwen/Qwen3-32B","messages":[{"role":"user","content":"你好"}],"max_tokens":100}'

# Embedding (bge-m3)
curl http://10.244.1.11:28800/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"model":"/data/models/BAAI/bge-m3","input":["Hello world"]}'
# Returns: dim=1024 vectors ✓
```

**Note on proxy:** The local env has `http_proxy=http://127.0.0.1:7890`. Use `NO_PROXY='*' http_proxy=''` prefix or use `nc` / pod-IP-direct to bypass.

---

## 9. Final State

```
kubectl -n vllm get pods
NAME                             READY   STATUS    RESTARTS   AGE
vllm-bge-m3-86b9df567c-h4dq4     1/1     Running   0          ~3m
vllm-qwen3-32b-7c69f79dd-4xpbd   1/1     Running   0          ~13m

kubectl get nodes
NAME        STATUS   ROLES           AGE
brhost-01   Ready    control-plane   19h
brhost-02   Ready    <none>          ~1h  ← 8×Biren166M, birentech.com/gpu=8
```

GPU allocation on brhost-02: 3/8 GPUs used (2 for qwen3-32b, 1 for bge-m3).

---

## 10. Script Changes

### `infer/llm/vllm/k8s_yaml_gen.sh`
- Added `LLM_DIR="$(dirname "${SCRIPT_DIR}")"` for absolute path to parent directory
- Added `BIREN_VISIBLE_DEVICES` env var computation and injection into YAML
- Added `privileged: true` to securityContext
- Added `IPC_LOCK` capability
- Added volume mounts for `model_registry.sh`, `model_registry.conf`
- **Added `biren-driver` hostPath volume mount** (fixes libbesu.so.1 not found)

### `infer/llm/vllm/configs/qwen3-32b.conf`
- Added `k8s_node_name=brhost-02`

### `infer/llm/vllm/configs/bge-m3.conf`
- Added `k8s_node_name=brhost-02`

---

## 11. New Driver/Runtime Test — Does New biren-container-runtime Eliminate Workarounds?

**Date:** 2026-05-23 (after brhost-02 rejoined cluster with updated GPU driver and container-toolkit)

**New containerd config on brhost-02 (post-driver update):**
```toml
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.biren]
  privileged_without_host_devices = false
  runtime_type = "io.containerd.runc.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.biren.options]
    BinaryName = "/usr/local/birensupa/container-toolkit/biren-container-toolkit/bin/biren-container-runtime"
    SystemdCgroup = true
```

**Test:** Deployed qwen3-32b WITHOUT:
- `biren-driver` hostPath volume mount
- `privileged: true`
- `BIREN_VISIBLE_DEVICES` env var

**Result: FAIL** — same `ImportError: libbesu.so.1: cannot open shared object file` error.

**Conclusion:** The new biren-container-runtime:
- ✅ Handles GPU device node injection (device files in `/dev/biren/`)
- ❌ Does **not** inject SDK shared libraries into container (`libbesu.so.1` etc.)
- ❌ Does **not** set `LD_LIBRARY_PATH` to include the driver's lib directory
- ❌ Does **not** set `BIREN_VISIBLE_DEVICES` automatically (at least not before lib load)

The `biren-driver` volume mount at `/usr/local/birensupa/driver` remains **mandatory** because:
- `brsw_set_env.sh` (called by container entrypoint) sources `/usr/local/birensupa/driver/scripts/brsw_set_env.sh`
- That script adds `/usr/local/birensupa/driver/brumd/lib` to `LD_LIBRARY_PATH`
- Without it, `import torch_br._C` fails with `libbesu.so.1: cannot open shared object file`

`privileged: true` and `BIREN_VISIBLE_DEVICES` are also still required for GPU access.
Working configuration restored: `k8s_yaml_gen/qwen3-32b.yaml` with all three workarounds.
