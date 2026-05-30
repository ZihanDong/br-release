# HAMi + Biren SVI — Kubernetes validation

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

## Cleanup

```bash
kubectl delete pod -l app=biren-svi-test -n default
# to remove HAMi entirely:
helm -n hami-system uninstall hami
```
