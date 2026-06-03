# HAMi + Biren SVI — Kubernetes validation

> **两套部署模型，两套校验。**
>
> - **统一插件（推荐，当前 `set-node-mode.sh biren --vgpu` 部署的）**：单一
>   `biren-hami-deviceplugin` + HAMi 调度器 + `biren-mode-manager`，同时调度
>   **整卡 + SVI(1/2、1/4) + vGPU 软切分**。两个校验入口：
>   ```bash
>   # 自包含测例（版本受控），直接复用 ../templates 下的 Pod 模板：
>   sudo NODE=<gpu-node> [TEST_IMAGE=<已存在镜像>] bash test-unified-plugin.sh all   # whole|svi|vgpu
>   # 安装包内置的深度测试（含多卡 NUMA 拓扑、vGPU 共享等），需 packages/hami-biren 已填充：
>   sudo NODE=<gpu-node> bash run-hami-bundle-tests.sh all
>   ```
>   模板位于 `../templates/`：`biren-whole-gpu.yaml`、`biren-svi-half.yaml`、
>   `biren-svi-quarter.yaml`、`biren-vgpu.yaml`（均设 `schedulerName: hami-scheduler`，
>   可直接 `kubectl apply`）。`TEST_IMAGE` 须已存在于 GPU 节点（IfNotPresent）。
>
> - **旧版 overlay 模型（本目录其余脚本）**：在原厂整卡插件之上叠加 HAMi-br
>   仅做 SVI 放置（`deploy-hami.sh`、`register-biren-nodes.sh`、`run-svi-tests.sh`、
>   `vgpu-reclaim-test.sh`，依赖已废弃的 `packages/hami-br`）。`set-node-mode.sh --vgpu`
>   **已不再部署该模型**——这些脚本仅作历史参考/驱动级 `suvs` 算力验证保留。

下文描述的是**旧版 overlay 模型**。

Validates that **HAMi-br** can schedule and manage **Biren SVI** (Scalable
Virtualization Interface) hardware-partitioned vGPUs in Kubernetes, at **1/2**
and **1/4** granularity, and that a basic `suvs` compute test runs on each
HAMi-allocated SVI instance.

## How the pieces fit

SVI splits a whole Biren GPU into hardware-isolated instances, configured
out-of-band by the admin (`brsmi gpu set -s 0|1|2 -i <gpu>`: 1 / 2 / 4
instances). Each instance is a whole, exclusive device — no memory/core
oversubscription — so HAMi schedules them like whole cards (Count=1).

```
 pod (schedulerName: hami-scheduler, runtimeClassName: biren,
      requests birentech.com/1-2-gpu | 1-4-gpu | gpu)
        │
        ▼
 hami-scheduler  ── reads hami.io/node-<flavor>-register on the node
   (kube-scheduler + HAMi extender, --enable-biren)   → Filter/Bind: picks a free
        │                                                instance, writes
        │                                                hami.io/<flavor>-devices-allocated
        ▼
 kubelet → Biren device-plugin (ns biren-gpu, stock) Allocate
        → injects /dev/biren/card_N + BR_PHY_CARDS via CDI (runtimeClass "biren")
```

HAMi does **placement/accounting**; the stock Biren device-plugin does the
actual device **allocation + injection**. The `node-*-register` annotations are
the bridge that tells HAMi what SVI instances exist on the node.

## Quick start

```bash
cd /home/zanedong/br-release/setup/kubernets/tests
./build-images.sh        # build/import the HAMi + SDK images (needs the compiled scheduler binary)
./deploy-hami.sh         # helm install HAMi (Biren backend) + register SVI devices
./run-svi-tests.sh       # schedule 1/2 + 1/4 pods and run the suvs compute test
```

All scripts read `lib.sh` for `REGISTRY` / `NODE` and override-able via env vars
(`REGISTRY`, `NODE`, `HAMI_SRC`, `SDK_TAR`, `HAMI_IMAGE`, `SDK_IMAGE`, …).

## Files

| file | purpose |
|------|---------|
| `build-images.sh` | Build the HAMi scheduler image (crane) and load it + the SDK image into containerd. |
| `deploy-hami.sh` | `helm upgrade --install` HAMi with the Biren backend, then register SVI devices. |
| `hami-biren-values.yaml` | Helm values to deploy HAMi with the Biren backend (webhook + nvidia device-plugin disabled). |
| `register-biren-nodes.sh` | Publish `hami.io/node-<flavor>-register` annotations (derived from node allocatable). |
| `svi-1of2-test.yaml` / `svi-1of4-test.yaml` | Test pods requesting a 1/2 / 1/4 SVI instance. |
| `in-pod-suvs.sh` | Runs inside a pod: installs Biren DCGM (`suvs`) and runs the compute test. |
| `run-svi-tests.sh` | End-to-end driver for both granularities. |
| `vgpu-reclaim-test.sh` | Dynamic-SVI test: task release auto-recovers the whole GPU (needs biren-svi-manager). |
| `lib.sh` | shared helpers (registry, node, proxy bypass). |

## 1. Compile the scheduler

The HAMi image just wraps the compiled `scheduler` binary. On a host with
Go ≥ 1.26:

```bash
cd /home/zanedong/hami-br/HAMi-br
make build            # -> bin/scheduler   (build-images.sh picks this up)
# or the full upstream image in one step:
make docker IMG_NAME=hami IMG_TAG=biren-svi
```

> This host has no Go toolchain available, so a prebuilt `scheduler` binary
> already sits at the repo root (`HAMi-br/scheduler`); `build-images.sh` uses
> `bin/scheduler` if present, else that copy.

## 2. Build & load images — `./build-images.sh`

Builds the HAMi scheduler image **daemonless with `crane`** (base
`ubuntu:24.04` + `/usr/local/bin/scheduler`) and loads both the HAMi and the
`birensupa-sdk` images into containerd's `k8s.io` namespace with `ctr import`.

Why not `docker push`: there is no rootless docker here, and the cluster's
plain-HTTP registry (`10.50.36.126:32000`) is not honoured by containerd for
CRI pulls — so images are imported directly (the same way the cluster already
runs the Biren device-plugin image). Equivalent manual commands:

```bash
crane append -b ubuntu:24.04 -f scheduler-layer.tar \
    -t 10.50.36.126:32000/hami/hami:biren-svi --insecure
crane pull --insecure --format=tarball \
    10.50.36.126:32000/hami/hami:biren-svi /tmp/hami-biren-svi.tar
sudo ctr -n k8s.io images import /tmp/hami-biren-svi.tar
sudo ctr -n k8s.io images import /data/release/2604rc2/images/birensupa-sdk-26.04.rc2-br1xx.tar
sudo ctr -n k8s.io images tag --force \
    docker.io/library/birensupa-sdk:26.04.rc2-br1xx \
    10.50.36.126:32000/base/birensupa-sdk:26.04.rc2-br1xx
```

Also required: the **stock Biren device-plugin** running (ns `biren-gpu`) with
SVI configured on some GPUs (`brsmi gpu set -s 1|2 -i <id>`), so the node
advertises `birentech.com/1-2-gpu`, `…/1-4-gpu`, etc.

## 3. Deploy HAMi (Biren backend) — `./deploy-hami.sh`

```bash
./deploy-hami.sh
# equivalent to:
helm -n hami-system upgrade --install hami /home/zanedong/hami-br/HAMi-br/charts/hami \
  --create-namespace -f hami-biren-values.yaml
kubectl -n hami-system rollout status deploy/hami-scheduler
./register-biren-nodes.sh
```

Key choices in `hami-biren-values.yaml`:
- `devices.biren.enabled=true` → adds `--enable-biren=true`, registers the
  `BirenGPU` / `Biren-1of2` / `Biren-1of4` flavors, and adds the
  `birentech.com/*` resources to the kube-scheduler extender's `managedResources`.
- `scheduler.admissionWebhook.enabled=false` → no cluster-wide MutatingWebhook
  (safe on a shared master). Test pods set `schedulerName: hami-scheduler` and
  `runtimeClassName: biren` explicitly.
- `devicePlugin.enabled=false` → HAMi's NVIDIA device-plugin is not deployed;
  Biren's own plugin handles allocation.
- `scheduler.kubeScheduler.image` → reuse the cluster's cached
  `registry.k8s.io/kube-scheduler:v1.30.0`.

## 4. Run the validation — `./run-svi-tests.sh`

```bash
./run-svi-tests.sh               # schedules 1/2 + 1/4 pods, runs suvs on each
```

(`register-biren-nodes.sh` is run by `deploy-hami.sh`; re-run it on its own
after changing SVI modes with `brsmi gpu set -s`.)

## Expected result

```
TEST: SVI 1/2 (half GPU)     schedulerName=hami-scheduler  HAMi allocated=Biren-1of2-…  injected card=card_0
   SUVS_RESULT: PASS … membw=~820 GB/s
TEST: SVI 1/4 (quarter GPU)  schedulerName=hami-scheduler  HAMi allocated=Biren-1of4-…  injected card=card_9
   SUVS_RESULT: PASS … membw=~395 GB/s
ALL TESTS PASSED — HAMi manages Biren SVI 1/2 and 1/4 vGPU scheduling.
```

`software` and `gpuinfo` PASS deterministically. `membw` runs a real ~90s
compute/replay kernel and **measures HBM bandwidth that scales with the SVI
fraction** (~1/2 ≈ 820 GB/s, ~1/4 ≈ 395 GB/s of a whole Biren166). membw prints
`Fail for bandwidth < 1480 GB/s` because that threshold is for a *whole* GPU —
seeing roughly half/quarter is the proof the partition is enforced, so the
script reports the measured value rather than gating on the whole-GPU bar.

## 5. Dynamic SVI auto-reclaim — `./vgpu-reclaim-test.sh`

Requires the `biren-svi-manager` deployed (package built with `dynamicSVI`,
i.e. `set-node-mode biren --vgpu`). Tests that **releasing a vGPU task
auto-recovers the whole physical GPU**:

```bash
sudo ./vgpu-reclaim-test.sh [--flavor half|quarter] [--gpu <index>]
```

Steps it performs (and why): the manager continuously reclaims idle partitioned
GPUs, so the test (1) **stops the manager** during setup, (2) partitions an idle
whole GPU + refreshes the device plugin, (3) registers the SVI devices + the
scheduler, (4) runs `templates/vgpu-test-pod.yaml` on the new instance,
(5) **restarts the manager** and confirms the GPU stays partitioned while the
task runs (occupancy prevents reclaim), then (6) **deletes the task** and asserts
the GPU reverts to a whole card. Expected tail:

```
[OK] GPU 0 still Enabled while task runs (occupancy prevents reclaim)
[OK] GPU 0 AUTO-RECOVERED to a whole card after task release
[OK] RECLAIM TEST PASSED
```

Manual check: with a task running on a partitioned GPU, `kubectl delete pod
vgpu-test-pod` and watch
`brsmi gpu --query-gpu=index,svi.mode.current --format=csv,noheader` flip the
GPU from `Enabled` to `Disabled` within ~1 min. (The vendor device plugin's
advertise oscillates briefly after a mode change, so the script waits for a
stable count and retries the pod — a bare manual run may need a retry.)

## Cleanup

```bash
kubectl delete pod -l app=biren-svi-test -n default
# to remove HAMi entirely:
helm -n hami-system uninstall hami
```
