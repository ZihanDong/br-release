#!/usr/bin/env bash
# Generate a Kubernetes YAML for an SGLang server.
# Saves the result to k8s_yaml_gen/<model>-<type>[...].yaml (does not apply it).
#
# Usage:
#   bash k8s_yaml_gen.sh --task <pod|deploy> [options] <config_file>
#
# Required:
#   --task <pod|deploy>    Workload type.
#
# Scheduling (mutually exclusive; default: k8s scheduler decides):
#   --node <nodename>      Hard-pin to a specific node (nodeName).
#   --label <key=value>    Node label selector (nodeSelector).
#
# Resources (per-instance; defaults: cpu=32, mem=128Gi/GPU):
#   --cpu <n>              CPU cores (request=n, limit=2n). Default: 32.
#   --mem-per-gpu <n>      Memory per GPU in Gi (request=limit=n×gpus). Default: 128.
#
# Scale (deploy only):
#   --replicas <n>         Number of Deployment replicas. Default: 1.
#
# config_file may be:
#   - a bare model name: qwen3-vl-32b  (resolved to configs/qwen3-vl-32b.conf)
#   - a relative path:   configs/qwen3-vl-32b.conf
#   - an absolute path:  /path/to/any.conf
#
# Output filename:
#   k8s_yaml_gen/<model>-<type>[-node-<n>|-label-<v>]-p<port>[-r<replicas>].yaml
#
# After generating, review the YAML and apply with:
#   bash k8s_apply.sh k8s_yaml_gen/<model>-<type>[...].yaml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Paths ──────────────────────────────────────────────────────────────────────
_REGISTRY_SH="${SCRIPT_DIR}/../model_registry.sh"
CONTAINER_IMAGE='172.25.198.36:32000/infer/birensupa-smartinfer-sglang:26.04.rc2-py310-pt2.9.0-br1xx'
K8S_NAMESPACE='sglang'
YAML_DIR="${SCRIPT_DIR}/k8s_yaml_gen"

# ── Helpers ────────────────────────────────────────────────────────────────────
_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

usage() {
    echo ""
    echo "Usage: $0 --task <pod|deploy> [options] <config_file>"
    echo ""
    echo "  --task <pod|deploy>    Required. Workload type."
    echo ""
    echo "  Scheduling (mutually exclusive; default: no constraint):"
    echo "  --node <nodename>      Pin to a specific node (nodeName)."
    echo "  --label <key=value>    Node label selector (nodeSelector)."
    echo ""
    echo "  Resources:"
    echo "  --cpu <n>              CPU cores per replica (default: 32; limit=2n)."
    echo "  --mem-per-gpu <n>      Memory in Gi per GPU (default: 128; request=limit=n×gpus)."
    echo ""
    echo "  Scale (deploy only):"
    echo "  --replicas <n>         Deployment replicas (default: 1)."
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
OPT_NODE=""
OPT_LABEL=""
OPT_CPU=32
OPT_MEM_PER_GPU=128
OPT_REPLICAS=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --task)
            [[ $# -lt 2 ]] && { _err "--task requires an argument (pod|deploy)"; usage; }
            K8S_TYPE="$2"; shift 2 ;;
        --node)
            [[ $# -lt 2 ]] && { _err "--node requires a nodename argument"; usage; }
            OPT_NODE="$2"; shift 2 ;;
        --label)
            [[ $# -lt 2 ]] && { _err "--label requires a key=value argument"; usage; }
            OPT_LABEL="$2"; shift 2 ;;
        --cpu)
            [[ $# -lt 2 ]] && { _err "--cpu requires a numeric argument"; usage; }
            OPT_CPU="$2"; shift 2 ;;
        --mem-per-gpu)
            [[ $# -lt 2 ]] && { _err "--mem-per-gpu requires a numeric argument"; usage; }
            OPT_MEM_PER_GPU="$2"; shift 2 ;;
        --replicas)
            [[ $# -lt 2 ]] && { _err "--replicas requires a numeric argument"; usage; }
            OPT_REPLICAS="$2"; shift 2 ;;
        -*)
            _err "Unknown option: $1"; usage ;;
        *)
            CONFIG_ARG="$1"; shift ;;
    esac
done

# ── Validate arguments ─────────────────────────────────────────────────────────
[[ -z "$K8S_TYPE" ]] && { _err "--task is required."; usage; }
[[ "$K8S_TYPE" != "pod" && "$K8S_TYPE" != "deploy" ]] && {
    _err "--task must be 'pod' or 'deploy', got: '${K8S_TYPE}'"; usage; }
[[ -z "$CONFIG_ARG" ]] && { _err "A config file is required."; usage; }
[[ -n "$OPT_NODE" && -n "$OPT_LABEL" ]] && {
    _err "--node and --label are mutually exclusive."; usage; }
[[ -n "$OPT_LABEL" && "$OPT_LABEL" != *=* ]] && {
    _err "--label must be in key=value format, got: '${OPT_LABEL}'"; exit 1; }
[[ ! "$OPT_CPU" =~ ^[0-9]+$ || "$OPT_CPU" -lt 1 ]] && {
    _err "--cpu must be a positive integer"; exit 1; }
[[ ! "$OPT_MEM_PER_GPU" =~ ^[0-9]+$ || "$OPT_MEM_PER_GPU" -lt 1 ]] && {
    _err "--mem-per-gpu must be a positive integer"; exit 1; }
[[ ! "$OPT_REPLICAS" =~ ^[0-9]+$ || "$OPT_REPLICAS" -lt 1 ]] && {
    _err "--replicas must be a positive integer"; exit 1; }

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
# Required params have NO defaults and MUST be set in the config file:
#   model_weights, port, tensor_parallel_size, pipeline_parallel_size,
#   max_model_len, max_running_requests
served_model_name=""
mem_fraction_static=0.85
page_size=128
disable_radix_cache=false
trust_remote_code=false
extra_env=""
extra_sglang_args=""
k8s_nodeport=""

# shellcheck source=/dev/null
source "$CONFIG_FILE"

_missing=()
[[ -z "${model_weights:-}" ]]         && _missing+=(model_weights)
[[ -z "${port:-}" ]]                   && _missing+=(port)
[[ -z "${tensor_parallel_size:-}" ]]   && _missing+=(tensor_parallel_size)
[[ -z "${pipeline_parallel_size:-}" ]] && _missing+=(pipeline_parallel_size)
[[ -z "${max_model_len:-}" ]]          && _missing+=(max_model_len)
[[ -z "${max_running_requests:-}" ]]   && _missing+=(max_running_requests)
[[ ${#_missing[@]} -gt 0 ]] && {
    _err "Required params not set in $(basename "$CONFIG_FILE"): ${_missing[*]}"; exit 1; }
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

# ── GPU count and resource sizing ─────────────────────────────────────────────
gpu_needed=$((tensor_parallel_size * pipeline_parallel_size))
cpu_lim=$((OPT_CPU * 2))
mem_gi=$((gpu_needed * OPT_MEM_PER_GPU))

_info "GPU needed  : tp=$tensor_parallel_size × pp=$pipeline_parallel_size = $gpu_needed"
_info "Resources   : cpu req=${OPT_CPU} lim=${cpu_lim}  mem=${mem_gi}Gi (${OPT_MEM_PER_GPU}Gi/GPU)"
[[ "$K8S_TYPE" == "deploy" ]] && _info "Replicas    : ${OPT_REPLICAS}"

# ── Resolve node scheduling ───────────────────────────────────────────────────
if [[ -n "$OPT_NODE" ]]; then
    SCHED_TYPE="node"
    _info "Scheduling  : nodeName=${OPT_NODE}"
elif [[ -n "$OPT_LABEL" ]]; then
    SCHED_TYPE="label"
    LABEL_KEY="${OPT_LABEL%%=*}"
    LABEL_VAL="${OPT_LABEL#*=}"
    _info "Scheduling  : nodeSelector ${LABEL_KEY}=${LABEL_VAL}"
else
    SCHED_TYPE="none"
    _avail=$(kubectl get nodes \
        -o jsonpath='{range .items[*]}{.status.allocatable.birentech\.com/gpu}{"\n"}{end}' \
        2>/dev/null | awk -v need="$gpu_needed" 'BEGIN{ok=0} $1+0>=need{ok=1} END{print ok}' || echo 0)
    if [[ "$_avail" != "1" ]]; then
        _warn "No single node with >= $gpu_needed birentech.com/gpu found; k8s scheduler will decide."
    fi
    _info "Scheduling  : (none — k8s scheduler decides)"
fi

# ── Scheduling YAML snippets ──────────────────────────────────────────────────
if [[ "$SCHED_TYPE" == "node" ]]; then
    _sched_deploy="      nodeName: ${OPT_NODE}"
    _sched_pod="  nodeName: ${OPT_NODE}"
elif [[ "$SCHED_TYPE" == "label" ]]; then
    _sched_deploy="      nodeSelector:
        ${LABEL_KEY}: ${LABEL_VAL}"
    _sched_pod="  nodeSelector:
    ${LABEL_KEY}: ${LABEL_VAL}"
else
    _sched_deploy=""
    _sched_pod=""
fi

# ── Build output filename ─────────────────────────────────────────────────────
_sched_suffix=""
if [[ "$SCHED_TYPE" == "node" ]]; then
    _sched_suffix="-node-${OPT_NODE//./-}"
elif [[ "$SCHED_TYPE" == "label" ]]; then
    _safe_val="${LABEL_VAL//[^a-zA-Z0-9_-]/-}"
    _sched_suffix="-label-${_safe_val}"
fi

if [[ "$K8S_TYPE" == "deploy" ]]; then
    OUT_YAML="${YAML_DIR}/${model_weights}-deploy${_sched_suffix}-p${port}-r${OPT_REPLICAS}.yaml"
else
    OUT_YAML="${YAML_DIR}/${model_weights}-pod${_sched_suffix}-p${port}.yaml"
fi

# ── k8s names (DNS-1035: dots not allowed — replace with dashes) ──────────────
k8s_name="${model_weights//./-}"
APP_LABEL="sglang-${k8s_name}"
DEPLOY_NAME="sglang-${k8s_name}"
SVC_NAME="sglang-${k8s_name}"
POD_NAME="sglang-${k8s_name}"

INNER_SCRIPT="${SCRIPT_DIR}/sglang_server.sh"
LLM_DIR="$(dirname "${SCRIPT_DIR}")"

initial_delay_ready=$(( gpu_needed * 120 + 60 ))
initial_delay_live=$(( gpu_needed * 180 + 60 ))

# ── Write YAML ─────────────────────────────────────────────────────────────────
mkdir -p "$YAML_DIR"

_vol_mounts="        volumeMounts:
        - name: dshm
          mountPath: /dev/shm
        - name: model-weights
          mountPath: /data/models
          readOnly: true
        - name: sglang-scripts
          mountPath: ${SCRIPT_DIR}
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
      - name: sglang-scripts
        hostPath:
          path: ${SCRIPT_DIR}
          type: Directory
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
# Generated by k8s_yaml_gen.sh  model=${model_weights}  config=$(basename "$CONFIG_FILE")  task=deploy  replicas=${OPT_REPLICAS}
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
    sglang.io/config-file: "${CONFIG_FILE}"
    sglang.io/server-script: "${INNER_SCRIPT}"
  labels:
    app: ${APP_LABEL}
    model: ${model_weights}
spec:
  replicas: ${OPT_REPLICAS}
  selector:
    matchLabels:
      app: ${APP_LABEL}
  template:
    metadata:
      labels:
        app: ${APP_LABEL}
        model: ${model_weights}
    spec:
      # RuntimeClass 'biren' (handler: biren) uses biren-container-runtime (BirenTech Container
      # Toolkit), which injects /dev/biren-m and the allocated /dev/biren/card_N devices.
      # birentech.com/gpu device plugin selects which cards are allocated per pod.
      # No privileged mode or hardcoded BIREN_VISIBLE_DEVICES needed.
      runtimeClassName: biren
${_sched_deploy}
      containers:
      - name: sglang-server
        image: ${CONTAINER_IMAGE}
        imagePullPolicy: IfNotPresent
        args:
        - bash
        - "${INNER_SCRIPT}"
        - "${CONFIG_FILE}"
        env:
        - name: BRTB_PLAN_ID_RENEW
          value: "1"
        - name: BRTB_DISABLE_ZERO_REORDER
          value: "1"
        - name: BRTB_DISABLE_ZERO_OUTPUT_NUMA
          value: "1"
        - name: BRTB_DISABLE_ZERO_OUTPUT_UMA
          value: "1"
        - name: BRTB_DISABLE_ZERO_WS
          value: "1"
        - name: BRTB_DISABLE_L2_FLUSH
          value: "1"
        - name: BRTB_ENABLE_SUPA_FILL
          value: "1"
        ports:
        - name: http
          containerPort: ${port}
          protocol: TCP
        resources:
          requests:
            birentech.com/gpu: "${gpu_needed}"
            cpu: "${OPT_CPU}"
            memory: "${mem_gi}Gi"
          limits:
            birentech.com/gpu: "${gpu_needed}"
            cpu: "${cpu_lim}"
            memory: "${mem_gi}Gi"
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

_pod_vol_mounts="    volumeMounts:
    - name: dshm
      mountPath: /dev/shm
    - name: model-weights
      mountPath: /data/models
      readOnly: true
    - name: sglang-scripts
      mountPath: ${SCRIPT_DIR}
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
  - name: sglang-scripts
    hostPath:
      path: ${SCRIPT_DIR}
      type: Directory
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
    sglang.io/config-file: "${CONFIG_FILE}"
    sglang.io/server-script: "${INNER_SCRIPT}"
  labels:
    app: ${APP_LABEL}
    model: ${model_weights}
spec:
  # RuntimeClass 'biren' (handler: biren) uses biren-container-runtime (BirenTech Container
  # Toolkit), which injects /dev/biren-m and the allocated /dev/biren/card_N devices.
  # birentech.com/gpu device plugin selects which cards are allocated per pod.
  # No privileged mode or hardcoded BIREN_VISIBLE_DEVICES needed.
  runtimeClassName: biren
${_sched_pod}
  restartPolicy: Never
  containers:
  - name: sglang-server
    image: ${CONTAINER_IMAGE}
    imagePullPolicy: IfNotPresent
    args:
    - sleep
    - infinity
    env:
    - name: BRTB_PLAN_ID_RENEW
      value: "1"
    - name: BRTB_DISABLE_ZERO_REORDER
      value: "1"
    - name: BRTB_DISABLE_ZERO_OUTPUT_NUMA
      value: "1"
    - name: BRTB_DISABLE_ZERO_OUTPUT_UMA
      value: "1"
    - name: BRTB_DISABLE_ZERO_WS
      value: "1"
    - name: BRTB_DISABLE_L2_FLUSH
      value: "1"
    - name: BRTB_ENABLE_SUPA_FILL
      value: "1"
    resources:
      requests:
        birentech.com/gpu: "${gpu_needed}"
        cpu: "${OPT_CPU}"
        memory: "${mem_gi}Gi"
      limits:
        birentech.com/gpu: "${gpu_needed}"
        cpu: "${cpu_lim}"
        memory: "${mem_gi}Gi"
    securityContext:
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
