#!/usr/bin/env bash
# Deploy a vLLM OpenAI-compatible server as a Kubernetes Deployment.
#
# Usage:
#   ./start_vllm_k8s.sh <config_file>
#
# config_file may be:
#   - a bare model name: bge-m3  (resolved to configs/bge-m3.conf)
#   - a relative path:   configs/bge-m3.conf
#   - an absolute path:  /path/to/any.conf

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Paths ──────────────────────────────────────────────────────────────────────
MODEL_REGISTRY="${SCRIPT_DIR}/model_registry.conf"
CONTAINER_IMAGE='10.49.4.248:32000/infer/birensupa-smartinfer-vllm:26.04.beta1-py310-pt2.8.0-br1xx'
K8S_NAMESPACE='vllm'

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

# ── Require config argument ────────────────────────────────────────────────────
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

# ── Load config (defaults cover all optional fields) ───────────────────────────
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

# ── Lookup model in registry ───────────────────────────────────────────────────
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

# ── Check / download model weights ────────────────────────────────────────────
WEIGHTS_PATH=""
if [[ -n "$MODEL_LOCAL_PATH" && -d "$MODEL_LOCAL_PATH" ]]; then
    WEIGHTS_PATH="$MODEL_LOCAL_PATH"
    _ok "Weights     : $WEIGHTS_PATH"
else
    _warn "Local weights not found (${MODEL_LOCAL_PATH:-(path not configured)})"
    read -rp "  Download now? [y/N]: " yn
    if [[ ! "$yn" =~ ^[Yy]$ ]]; then
        _err "Cannot start without model weights. Exiting."; exit 1
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
    WEIGHTS_PATH="$DEST"
    _ok "Downloaded  : $WEIGHTS_PATH"
fi

# ── Resolve GPU count and k8s node ────────────────────────────────────────────
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

NODE_IP=$(kubectl get node "$NODE_NAME" \
    -o jsonpath='{range .status.addresses[*]}{.type}{"\t"}{.address}{"\n"}{end}' \
    | awk '$1=="InternalIP"{print $2; exit}')
[[ -z "$NODE_IP" ]] && NODE_IP="$NODE_NAME"

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

# ── Build YAML args list ──────────────────────────────────────────────────────
# Each argument becomes an indented "- value" entry.
# Values starting with '{' are wrapped in YAML single-quotes to avoid flow-mapping parse.
args_yaml=""
_arg() {
    local val="$1"
    if [[ "$val" == "{"* ]]; then
        args_yaml+="        - '${val}'\n"
    else
        args_yaml+="        - \"${val}\"\n"
    fi
}

_arg "python3"
_arg "-m"
_arg "vllm.entrypoints.openai.api_server"
_arg "--host";                  _arg "0.0.0.0"
_arg "--port";                  _arg "${port}"
_arg "--model";                 _arg "${WEIGHTS_PATH}"
[[ -n "$served_model_name" ]] && { _arg "--served_model_name"; _arg "${served_model_name}"; }
[[ -n "$task" ]]              && { _arg "--task";               _arg "${task}"; }
_arg "--trust_remote_code"
_arg "--dtype";                 _arg "${dtype}"
_arg "--kv_cache_dtype";        _arg "auto"
_arg "--max_model_len";         _arg "${max_model_len}"
_arg "--max_num_seqs";          _arg "${max_num_seqs}"
_arg "--tensor_parallel_size";  _arg "${tensor_parallel_size}"
_arg "--pipeline_parallel_size"; _arg "${pipeline_parallel_size}"
_arg "--data_parallel_size";    _arg "1"
_arg "--gpu_memory_utilization"; _arg "${gpu_memory_utilization}"
[[ "$enforce_eager" == "true" ]]          && _arg "--enforce_eager"
[[ "$enable_chunked_prefill" == "true" ]] && _arg "--enable_chunked_prefill"
[[ -n "$distributed_executor_backend" ]] && {
    _arg "--distributed_executor_backend"; _arg "${distributed_executor_backend}"; }
if [[ -n "$compilation_config" ]]; then
    # Strip surrounding single-quotes added in conf file for bash safety
    cc="${compilation_config#\'}"
    cc="${cc%\'}"
    _arg "--compilation_config"; _arg "${cc}"
fi

# ── Generate and apply Kubernetes YAML ───────────────────────────────────────
_info "Deploying   : $DEPLOY_NAME  ns/$K8S_NAMESPACE  node/$NODE_NAME  NodePort/$k8s_nodeport"
echo ""

kubectl apply -f - <<YAML
# Generated by start_vllm_k8s.sh  model=${model_weights}
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
      # biren-container-runtime injects BIREN_VISIBLE_DEVICES and SDK library paths
      runtimeClassName: biren
      nodeName: ${NODE_NAME}
      containers:
      - name: vllm-server
        image: ${CONTAINER_IMAGE}
        imagePullPolicy: IfNotPresent
        # No 'command' field — preserves the image ENTRYPOINT (biren_entrypoint.sh),
        # which sets LD_LIBRARY_PATH for the BirenTech SDK before exec'ing args.
        args:
$(printf '%b' "${args_yaml}")
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
      volumes:
      - name: dshm
        emptyDir:
          medium: Memory
          sizeLimit: 256Gi
      - name: model-weights
        hostPath:
          path: /data/models
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

_ok "Resources applied."
echo ""

# ── Wait for Pod readiness ────────────────────────────────────────────────────
_info "Waiting for Pod to become Ready (~$((initial_delay_ready / 60)) min estimated)..."
_info "Monitor: kubectl logs -n ${K8S_NAMESPACE} -l app=${APP_LABEL} -f"
echo ""

TIMEOUT=$((initial_delay_ready + 300))
ELAPSED=0
INTERVAL=15
READY=false

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    STATUS=$(kubectl get pods -n "$K8S_NAMESPACE" -l "app=${APP_LABEL}" \
        --no-headers -o custom-columns='R:.status.containerStatuses[0].ready' \
        2>/dev/null | head -1 || echo "unknown")
    [[ "$STATUS" == "true" ]] && { READY=true; break; }
    printf "."
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done
echo ""

MODEL_API="${served_model_name:-${WEIGHTS_PATH}}"

if $READY; then
    _ok "══════════════════════════════════════════════════════"
    _ok " vLLM server ready — ${DEPLOY_NAME}  NodePort :${k8s_nodeport}"
    _ok "══════════════════════════════════════════════════════"
else
    _warn "Pod not Ready after ${TIMEOUT}s — may still be loading."
    _warn "Check: kubectl logs -n ${K8S_NAMESPACE} -l app=${APP_LABEL} -f"
fi

# ── Print test commands ────────────────────────────────────────────────────────
echo ""
if [[ "$task" == "embed" ]]; then
    echo "── Embedding test ──────────────────────────────────────────"
    echo "curl -s --noproxy \"*\" http://${NODE_IP}:${k8s_nodeport}/v1/embeddings \\"
    echo "  -H 'Content-Type: application/json' \\"
    echo "  -d '{\"model\": \"${MODEL_API}\", \"input\": \"Hello, world!\"}' \\"
    echo "  | python3 -m json.tool"
else
    echo "── Chat completion test ────────────────────────────────────"
    echo "curl -s --noproxy \"*\" http://${NODE_IP}:${k8s_nodeport}/v1/chat/completions \\"
    echo "  -H 'Content-Type: application/json' \\"
    echo "  -d '{\"model\": \"${MODEL_API}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}], \"max_tokens\": 64}' \\"
    echo "  | python3 -m json.tool"
fi

echo ""
echo "── K8s management ──────────────────────────────────────────"
echo "  kubectl get pods -n ${K8S_NAMESPACE}"
echo "  kubectl logs -n ${K8S_NAMESPACE} -l app=${APP_LABEL} -f"
echo "  kubectl delete deployment/${DEPLOY_NAME} service/${SVC_NAME} -n ${K8S_NAMESPACE}"
