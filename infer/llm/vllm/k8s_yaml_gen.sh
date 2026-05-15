#!/usr/bin/env bash
# Generate a Kubernetes YAML for a vLLM server deployment.
# Saves the result to k8s_yaml_gen/<model_weights>.yaml (does not apply it).
#
# Usage:
#   bash k8s_yaml_gen.sh <config_file>
#
# config_file may be:
#   - a bare model name: bge-m3  (resolved to configs/bge-m3.conf)
#   - a relative path:   configs/bge-m3.conf
#   - an absolute path:  /path/to/any.conf
#
# After generating, review the YAML and deploy with:
#   bash test_k8s.sh k8s_yaml_gen/<model>.yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Paths ──────────────────────────────────────────────────────────────────────
MODEL_REGISTRY="${SCRIPT_DIR}/model_registry.conf"
CONTAINER_IMAGE='10.49.4.248:32000/infer/birensupa-smartinfer-vllm:26.04.beta1-py310-pt2.8.0-br1xx'
K8S_NAMESPACE='vllm'
YAML_DIR="${SCRIPT_DIR}/k8s_yaml_gen"

# ── Helpers ────────────────────────────────────────────────────────────────────
_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

usage() {
    echo ""
    echo "Usage: $0 <config_file>"
    echo ""
    echo "Available configs:"
    for f in "${SCRIPT_DIR}/configs/"*.conf; do
        [[ -f "$f" ]] && echo "  $(basename "$f" .conf)"
    done
    echo ""
    exit 1
}

# ── Resolve config ─────────────────────────────────────────────────────────────
[[ $# -lt 1 ]] && { _err "A config file is required."; usage; }

CONFIG_ARG="$1"
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
[[ -z "$k8s_nodeport"  ]] && { _err "k8s_nodeport not set in $(basename "$CONFIG_FILE")"; exit 1; }

_info "Config      : $(basename "$CONFIG_FILE")"
_info "Model key   : $model_weights  |  port=$port  |  nodeport=$k8s_nodeport  |  tp=$tensor_parallel_size  pp=$pipeline_parallel_size"

# ── Registry lookup ────────────────────────────────────────────────────────────
[[ ! -f "$MODEL_REGISTRY" ]] && { _err "Registry not found: $MODEL_REGISTRY"; exit 1; }

registry_get() {
    awk -v sec="[$1]" -v fld="$2" '
        /^\[/ { cur = $0 }
        cur == sec && match($0, "^" fld "=") { print substr($0, length(fld)+2); exit }
    ' "$MODEL_REGISTRY"
}

MODEL_LOCAL_PATH=$(registry_get "$model_weights" "local_path")
MODEL_HF_ID=$(registry_get "$model_weights" "huggingface_id")
MODEL_MS_ID=$(registry_get "$model_weights" "modelscope_id")

[[ -z "$MODEL_HF_ID$MODEL_MS_ID" ]] && {
    _err "Model '$model_weights' not found in $MODEL_REGISTRY"; exit 1; }

_info "Registry    : local=${MODEL_LOCAL_PATH:-(not set)}  hf=$MODEL_HF_ID  ms=$MODEL_MS_ID"

# ── Weight check / download (before generating YAML) ──────────────────────────
if [[ -n "$MODEL_LOCAL_PATH" && -d "$MODEL_LOCAL_PATH" ]]; then
    _ok "Weights     : $MODEL_LOCAL_PATH"
else
    _warn "Local weights not found (${MODEL_LOCAL_PATH:-(path not configured)})"
    read -rp "  Download now? [y/N]: " yn
    if [[ ! "$yn" =~ ^[Yy]$ ]]; then
        _err "Cannot generate YAML without model weights. Exiting."; exit 1
    fi
    echo "  Download source:"
    echo "    1) modelscope  —  modelscope download --model $MODEL_MS_ID"
    echo "    2) huggingface —  huggingface-cli download $MODEL_HF_ID"
    read -rp "  Choose [1/2]: " src
    DEST="${MODEL_LOCAL_PATH:-/data/models/${MODEL_HF_ID}}"
    mkdir -p "$(dirname "$DEST")"
    case "$src" in
        1) modelscope download --model "$MODEL_MS_ID" --local_dir "$DEST" ;;
        2) huggingface-cli download "$MODEL_HF_ID" --local-dir "$DEST" ;;
        *) _err "Invalid choice."; exit 1 ;;
    esac
    MODEL_LOCAL_PATH="$DEST"
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

APP_LABEL="vllm-${model_weights}"
DEPLOY_NAME="vllm-${model_weights}"
SVC_NAME="vllm-${model_weights}"

INNER_SCRIPT="${SCRIPT_DIR}/vllm_server.sh"

# ── Write YAML ─────────────────────────────────────────────────────────────────
mkdir -p "$YAML_DIR"
OUT_YAML="${YAML_DIR}/${model_weights}.yaml"

cat > "$OUT_YAML" <<YAML
# Generated by k8s_yaml_gen.sh  model=${model_weights}  config=$(basename "$CONFIG_FILE")
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
      # biren-container-runtime sets BIREN_VISIBLE_DEVICES and SDK library paths
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
        volumeMounts:
        - name: dshm
          mountPath: /dev/shm
        - name: model-weights
          mountPath: /data/models
          readOnly: true
        - name: vllm-scripts
          mountPath: ${SCRIPT_DIR}
          readOnly: true
      volumes:
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

_ok "YAML saved  : $OUT_YAML"
echo ""
echo "  Review the YAML, then deploy and test with:"
echo "    bash ${SCRIPT_DIR}/test_k8s.sh ${OUT_YAML}"
