#!/usr/bin/env bash
# Generate a Kubernetes YAML for a vLLM server.
# Saves the result to k8s_yaml_gen/<model>-<type>.yaml (does not apply it).
#
# Usage:
#   bash k8s_yaml_gen.sh --task <pod|deploy> <config_file>
#
#   --task deploy  Deployment + NodePort Service  (server auto-starts at launch)
#   --task pod     Interactive Pod only           (server script written; user starts manually)
#
# config_file may be:
#   - a bare model name: bge-m3  (resolved to configs/bge-m3.conf)
#   - a relative path:   configs/bge-m3.conf
#   - an absolute path:  /path/to/any.conf
#
# After generating, review the YAML and apply with:
#   bash k8s_apply.sh k8s_yaml_gen/<model>-<type>.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Paths ──────────────────────────────────────────────────────────────────────
_REGISTRY_SH="${SCRIPT_DIR}/../model_registry.sh"
CONTAINER_IMAGE='172.25.198.36:32000/infer/birensupa-smartinfer-vllm:26.04.rc2-py310-pt2.8.0-br1xx'
K8S_NAMESPACE='vllm'
YAML_DIR="${SCRIPT_DIR}/k8s_yaml_gen"

# ── Helpers ────────────────────────────────────────────────────────────────────
_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

usage() {
    echo ""
    echo "Usage: $0 --task <pod|deploy> <config_file>"
    echo ""
    echo "  --task deploy  Generate a Deployment + NodePort Service YAML (server auto-starts)"
    echo "  --task pod     Generate an interactive Pod YAML (server script prepared; user starts manually)"
    echo ""
    echo "Available configs:"
    for f in "${SCRIPT_DIR}/configs/"*.conf; do
        [[ -f "$f" ]] && echo "  $(basename "$f" .conf)"
    done
    echo ""
    exit 1
}

# ── Parse arguments ────────────────────────────────────────────────────────────
K8S_TYPE=""
CONFIG_ARG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)
            [[ $# -lt 2 ]] && { _err "--task requires an argument (pod|deploy)"; usage; }
            K8S_TYPE="$2"; shift 2 ;;
        -*)
            _err "Unknown option: $1"; usage ;;
        *)
            CONFIG_ARG="$1"; shift ;;
    esac
done

[[ -z "$K8S_TYPE" ]] && { _err "--task is required."; usage; }
[[ "$K8S_TYPE" != "pod" && "$K8S_TYPE" != "deploy" ]] && {
    _err "--task must be 'pod' or 'deploy', got: '${K8S_TYPE}'"; usage; }
[[ -z "$CONFIG_ARG" ]] && { _err "A config file is required."; usage; }

# ── Resolve config ─────────────────────────────────────────────────────────────
CONFIG_FILE=""

if [[ "$CONFIG_ARG" == /* ]]; then
    CONFIG_FILE="$CONFIG_ARG"
elif [[ -f "${SCRIPT_DIR}/configs/${CONFIG_ARG}.conf" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/configs/${CONFIG_ARG}.conf"
elif [[ -f "${SCRIPT_DIR}/${CONFIG_ARG}" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_ARG}"
elif [[ -f "${CONFIG_ARG}" ]]; then
    CONFIG_FILE="${CONFIG_ARG}"
fi

[[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]] && {
    _err "Config not found: $CONFIG_ARG"; usage; }

# ── Load config ────────────────────────────────────────────────────────────────
port=8000
served_model_name=""
task=""
dtype="auto"
max_model_len=8192
max_num_seqs=64
pipeline_parallel_size=1
tensor_parallel_size=1
gpu_memory_utilization=0.8
enable_chunked_prefill=false
enforce_eager=false
distributed_executor_backend=""
compilation_config=""
model_weights=""
k8s_nodeport=""
k8s_node_name=""

# shellcheck source=/dev/null
source "$CONFIG_FILE"

[[ -z "$model_weights" ]] && { _err "model_weights not set in $(basename "$CONFIG_FILE")"; exit 1; }
[[ "$K8S_TYPE" == "deploy" && -z "$k8s_nodeport" ]] && {
    _err "k8s_nodeport not set in $(basename "$CONFIG_FILE") (required for deploy type)"; exit 1; }

_info "Config      : $(basename "$CONFIG_FILE")  [task=${K8S_TYPE}]"
_info "Model key   : $model_weights  |  port=$port  |  tp=$tensor_parallel_size  pp=$pipeline_parallel_size"

# ── Registry lookup (via model_registry.sh) ───────────────────────────────────
[[ ! -f "$_REGISTRY_SH" ]] && { _err "model_registry.sh not found: $_REGISTRY_SH"; exit 1; }
# shellcheck source=../model_registry.sh
source "$_REGISTRY_SH"
parse_model "$model_weights" || exit 1
MODEL_LOCAL_PATH="$MODEL_PATH"

_info "Registry    : path=$MODEL_LOCAL_PATH  download=$DOWNLOAD_NAME  status=$DIR_STATUS"

# ── Weight check / download (before generating YAML) ──────────────────────────
if [[ "$DIR_STATUS" == "ok" ]]; then
    _ok "Weights     : $MODEL_LOCAL_PATH"
else
    _warn "Local weights not found (${MODEL_LOCAL_PATH:-(path not configured)}, status: $DIR_STATUS)"
    read -rp "  Download now? [y/N]: " yn
    if [[ ! "$yn" =~ ^[Yy]$ ]]; then
        _err "Cannot generate YAML without model weights. Exiting."; exit 1
    fi
    echo "  Download source:"
    echo "    1) modelscope  —  modelscope download --model $DOWNLOAD_NAME --local_dir $MODEL_LOCAL_PATH"
    echo "    2) huggingface —  huggingface-cli download $DOWNLOAD_NAME --local-dir $MODEL_LOCAL_PATH"
    read -rp "  Choose [1/2]: " src
    mkdir -p "$MODEL_LOCAL_PATH"
    case "$src" in
        1) modelscope download --model "$DOWNLOAD_NAME" --local_dir "$MODEL_LOCAL_PATH" ;;
        2) huggingface-cli download "$DOWNLOAD_NAME" --local-dir "$MODEL_LOCAL_PATH" ;;
        *) _err "Invalid choice."; exit 1 ;;
    esac
    _ok "Downloaded  : $MODEL_LOCAL_PATH"
fi

# ── Resolve k8s node ──────────────────────────────────────────────────────────
gpu_needed=$((tensor_parallel_size * pipeline_parallel_size))
_info "GPU needed  : tp=$tensor_parallel_size × pp=$pipeline_parallel_size = $gpu_needed"

if [[ -n "$k8s_node_name" ]]; then
    NODE_NAME="$k8s_node_name"
    _info "Node        : $NODE_NAME (from config)"
else
    NODE_NAME=$(kubectl get nodes \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.birentech\.com/gpu}{"\n"}{end}' \
        2>/dev/null | awk -v need="$gpu_needed" '$2+0 >= need { print $1; exit }')
    [[ -z "$NODE_NAME" ]] && {
        _err "No node with >= $gpu_needed birentech.com/gpu available."
        kubectl get nodes -o wide 2>/dev/null || true
        exit 1; }
    _info "Node        : $NODE_NAME (auto-detected)"
fi

# ── Derived resource values ───────────────────────────────────────────────────
cpu_req=$((gpu_needed * 8))
cpu_lim=$((gpu_needed * 16))
mem_req_gi=$((gpu_needed * 32))
mem_lim_gi=$((gpu_needed * 80))

initial_delay_ready=$(( gpu_needed * 120 + 60 ))
initial_delay_live=$(( gpu_needed * 180 + 60 ))

# k8s names must match DNS-1035: dots not allowed — replace with dashes
k8s_name="${model_weights//./-}"
APP_LABEL="vllm-${k8s_name}"
DEPLOY_NAME="vllm-${k8s_name}"
SVC_NAME="vllm-${k8s_name}"
POD_NAME="vllm-${k8s_name}"

INNER_SCRIPT="${SCRIPT_DIR}/vllm_server.sh"
LLM_DIR="$(dirname "${SCRIPT_DIR}")"

# Build BIREN_VISIBLE_DEVICES string: e.g. "0,1" for gpu_needed=2
_biren_visible=""
for (( _i=0; _i<gpu_needed; _i++ )); do
    [[ -n "$_biren_visible" ]] && _biren_visible="${_biren_visible},"
    _biren_visible="${_biren_visible}${_i}"
done

# ── Write YAML ─────────────────────────────────────────────────────────────────
mkdir -p "$YAML_DIR"
OUT_YAML="${YAML_DIR}/${model_weights}-${K8S_TYPE}.yaml"

# Shared volume/volumeMount snippet used by both types
_vol_mounts="        volumeMounts:
        - name: dshm
          mountPath: /dev/shm
        - name: model-weights
          mountPath: /data/models
          readOnly: true
        - name: vllm-scripts
          mountPath: ${SCRIPT_DIR}
          readOnly: true
        - name: patch-parameter
          mountPath: /usr/local/lib/python3.10/dist-packages/vllm_br/model_executor/parameter.py
          readOnly: true
        - name: model-registry
          mountPath: ${LLM_DIR}/model_registry.sh
          readOnly: true
        - name: model-registry-conf
          mountPath: ${LLM_DIR}/model_registry.conf
          readOnly: true
        - name: biren-driver
          mountPath: /usr/local/birensupa/driver
          readOnly: true"

_volumes="      volumes:
      - name: dshm
        emptyDir:
          medium: Memory
          sizeLimit: 256Gi
      - name: model-weights
        hostPath:
          path: /data/models
          type: Directory
      - name: vllm-scripts
        hostPath:
          path: ${SCRIPT_DIR}
          type: Directory
      - name: patch-parameter
        hostPath:
          path: ${SCRIPT_DIR}/patches/vllm_br_parameter.py
          type: File
      - name: model-registry
        hostPath:
          path: ${LLM_DIR}/model_registry.sh
          type: File
      - name: model-registry-conf
        hostPath:
          path: ${LLM_DIR}/model_registry.conf
          type: File
      - name: biren-driver
        hostPath:
          path: /usr/local/birensupa/driver
          type: Directory"

if [[ "$K8S_TYPE" == "deploy" ]]; then

cat > "$OUT_YAML" <<YAML
# Generated by k8s_yaml_gen.sh  model=${model_weights}  config=$(basename "$CONFIG_FILE")  task=deploy
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${K8S_NAMESPACE}

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${DEPLOY_NAME}
  namespace: ${K8S_NAMESPACE}
  annotations:
    vllm.io/config-file: "${CONFIG_FILE}"
    vllm.io/server-script: "${INNER_SCRIPT}"
  labels:
    app: ${APP_LABEL}
    model: ${model_weights}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_LABEL}
  template:
    metadata:
      labels:
        app: ${APP_LABEL}
        model: ${model_weights}
    spec:
      # RuntimeClass 'biren' uses handler: runc (standard runc + manual workarounds below).
      # GPU devices: privileged + BIREN_VISIBLE_DEVICES.  SDK libs: biren-driver hostPath volume.
      runtimeClassName: biren
      nodeName: ${NODE_NAME}
      containers:
      - name: vllm-server
        image: ${CONTAINER_IMAGE}
        imagePullPolicy: IfNotPresent
        # No 'command' field — preserves the image ENTRYPOINT (biren_entrypoint.sh),
        # which sets LD_LIBRARY_PATH before exec'ing the args.
        args:
        - bash
        - "${INNER_SCRIPT}"
        - "${CONFIG_FILE}"
        env:
        - name: VLLM_USE_V1
          value: "1"
        - name: VLLM_WORKER_MULTIPROC_METHOD
          value: spawn
        - name: VLLM_BR_WEIGHT_TYPE
          value: NUMA
        - name: BIREN_VISIBLE_DEVICES
          value: "${_biren_visible}"
        ports:
        - name: http
          containerPort: ${port}
          protocol: TCP
        resources:
          requests:
            birentech.com/gpu: "${gpu_needed}"
            cpu: "${cpu_req}"
            memory: "${mem_req_gi}Gi"
          limits:
            birentech.com/gpu: "${gpu_needed}"
            cpu: "${cpu_lim}"
            memory: "${mem_lim_gi}Gi"
        securityContext:
          privileged: true
          capabilities:
            add:
            - IPC_LOCK
        readinessProbe:
          httpGet:
            path: /health
            port: ${port}
          initialDelaySeconds: ${initial_delay_ready}
          periodSeconds: 15
          failureThreshold: 8
          timeoutSeconds: 10
        livenessProbe:
          httpGet:
            path: /health
            port: ${port}
          initialDelaySeconds: ${initial_delay_live}
          periodSeconds: 30
          failureThreshold: 3
          timeoutSeconds: 10
${_vol_mounts}
${_volumes}

---
apiVersion: v1
kind: Service
metadata:
  name: ${SVC_NAME}
  namespace: ${K8S_NAMESPACE}
  labels:
    app: ${APP_LABEL}
    model: ${model_weights}
spec:
  type: NodePort
  selector:
    app: ${APP_LABEL}
  ports:
  - name: http
    port: ${port}
    targetPort: ${port}
    nodePort: ${k8s_nodeport}
    protocol: TCP
YAML

else  # pod

# Pod-level volume/volumeMount indentation is 4 spaces less than in Deployment template
_pod_vol_mounts="    volumeMounts:
    - name: dshm
      mountPath: /dev/shm
    - name: model-weights
      mountPath: /data/models
      readOnly: true
    - name: vllm-scripts
      mountPath: ${SCRIPT_DIR}
      readOnly: true
    - name: patch-parameter
      mountPath: /usr/local/lib/python3.10/dist-packages/vllm_br/model_executor/parameter.py
      readOnly: true
    - name: model-registry
      mountPath: ${LLM_DIR}/model_registry.sh
      readOnly: true
    - name: model-registry-conf
      mountPath: ${LLM_DIR}/model_registry.conf
      readOnly: true
    - name: biren-driver
      mountPath: /usr/local/birensupa/driver
      readOnly: true"

_pod_volumes="  volumes:
  - name: dshm
    emptyDir:
      medium: Memory
      sizeLimit: 256Gi
  - name: model-weights
    hostPath:
      path: /data/models
      type: Directory
  - name: vllm-scripts
    hostPath:
      path: ${SCRIPT_DIR}
      type: Directory
  - name: patch-parameter
    hostPath:
      path: ${SCRIPT_DIR}/patches/vllm_br_parameter.py
      type: File
  - name: model-registry
    hostPath:
      path: ${LLM_DIR}/model_registry.sh
      type: File
  - name: model-registry-conf
    hostPath:
      path: ${LLM_DIR}/model_registry.conf
      type: File
  - name: biren-driver
    hostPath:
      path: /usr/local/birensupa/driver
      type: Directory"

cat > "$OUT_YAML" <<YAML
# Generated by k8s_yaml_gen.sh  model=${model_weights}  config=$(basename "$CONFIG_FILE")  task=pod
---
apiVersion: v1
kind: Namespace
metadata:
  name: ${K8S_NAMESPACE}

---
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${K8S_NAMESPACE}
  annotations:
    vllm.io/config-file: "${CONFIG_FILE}"
    vllm.io/server-script: "${INNER_SCRIPT}"
  labels:
    app: ${APP_LABEL}
    model: ${model_weights}
spec:
  # RuntimeClass 'biren' uses handler: runc.
  # GPU devices: privileged + BIREN_VISIBLE_DEVICES.  SDK libs: biren-driver hostPath volume.
  runtimeClassName: biren
  nodeName: ${NODE_NAME}
  restartPolicy: Never
  containers:
  - name: vllm-server
    image: ${CONTAINER_IMAGE}
    imagePullPolicy: IfNotPresent
    # No 'command' — preserves ENTRYPOINT (biren_entrypoint.sh) for LD_LIBRARY_PATH setup.
    # Pod stays alive; user enters via 'kubectl exec -it' and runs the server script manually.
    args:
    - sleep
    - infinity
    env:
    - name: VLLM_USE_V1
      value: "1"
    - name: VLLM_WORKER_MULTIPROC_METHOD
      value: spawn
    - name: VLLM_BR_WEIGHT_TYPE
      value: NUMA
    - name: BIREN_VISIBLE_DEVICES
      value: "${_biren_visible}"
    resources:
      requests:
        birentech.com/gpu: "${gpu_needed}"
        cpu: "${cpu_req}"
        memory: "${mem_req_gi}Gi"
      limits:
        birentech.com/gpu: "${gpu_needed}"
        cpu: "${cpu_lim}"
        memory: "${mem_lim_gi}Gi"
    securityContext:
      privileged: true
      capabilities:
        add:
        - IPC_LOCK
${_pod_vol_mounts}
${_pod_volumes}
YAML

fi

_ok "YAML saved  : $OUT_YAML"
echo ""
echo "  Review the YAML, then apply with:"
echo "    bash ${SCRIPT_DIR}/k8s_apply.sh ${OUT_YAML}"
