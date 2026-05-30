#!/usr/bin/env bash
# Publish Biren SVI devices to the HAMi scheduler by writing the
# hami.io/node-<commonWord>-register node annotations it reads
# (pkg/device/biren GetNodeDevices -> device.UnMarshalNodeDevices, a JSON array
# of device.DeviceInfo). Run once after (re)configuring SVI modes
# (`brsmi gpu set -s 0|1|2 -i <gpu>`) or after a HAMi (re)install.
#
# The Biren SVI instances are whole, hardware-isolated, exclusive devices, so
# each registered entry is Count=1 / Devcore=100. We derive the per-flavor
# instance COUNT directly from the node's kubelet allocatable, which the stock
# Biren device plugin already advertises (birentech.com/gpu, /1-2-gpu, /1-4-gpu).
# This keeps HAMi's view exactly consistent with what the device plugin will
# actually hand out, and needs no on-host BRML/cgo build.
#
# (Production alternative: build the BRML-based discovery binary in
#  ../../../biren-hami-deviceplugin [`-mode discover`] and apply the annotations
#  it prints — that path additionally reports real per-instance UUIDs/memory.)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"

log "deriving Biren SVI device counts from node '$NODE' allocatable"
python3 - "$NODE" <<'PY'
import json, subprocess, sys
node = sys.argv[1]
alloc = json.loads(subprocess.check_output(
    ["kubectl", "get", "node", node, "-o", "jsonpath={.status.allocatable}"]))
# kubelet resource -> (HAMi commonWord, per-instance memory MiB)
flavors = {
    "birentech.com/gpu":     ("BirenGPU",   65536),
    "birentech.com/1-2-gpu": ("Biren-1of2", 32768),
    "birentech.com/1-4-gpu": ("Biren-1of4", 16384),
}
for res, (cw, mem) in flavors.items():
    n = int(alloc.get(res, "0"))
    if n <= 0:
        continue
    devs = [{
        "id": f"{cw}-{node}-{i}", "index": i, "count": 1,
        "devmem": mem, "devcore": 100, "type": cw,
        "numa": 0, "mode": "biren-svi", "health": True,
    } for i in range(n)]
    anno = json.dumps(devs, separators=(",", ":"))
    key = f"hami.io/node-{cw}-register"
    subprocess.check_call(
        ["kubectl", "annotate", "node", node, f"{key}={anno}", "--overwrite"],
        stdout=subprocess.DEVNULL)
    print(f"  applied {key}  ({n} instances, {mem} MiB each)")
PY

log "current biren allocatable on $NODE:"
kubectl get node "$NODE" -o json | python3 -c "import sys,json;a=json.load(sys.stdin)['status']['allocatable'];[print('   ',k,'=',v) for k,v in sorted(a.items()) if 'birentech' in k]"
ok "node-register annotations published"
