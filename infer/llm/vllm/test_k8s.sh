#!/usr/bin/env bash
# Apply a vLLM Kubernetes YAML, wait for the server to become ready,
# run an API smoke test, and print management commands.
#
# Usage:
#   bash test_k8s.sh <yaml_file>
#
# Typical workflow:
#   bash k8s_yaml_gen.sh bge-m3            # generate YAML
#   bash test_k8s.sh k8s_yaml_gen/bge-m3.yaml  # apply + test

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_REGISTRY="${SCRIPT_DIR}/../model_registry.conf"

_info() { echo -e "\033[0;36m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*" >&2; }

usage() {
    echo ""
    echo "Usage: $0 <yaml_file>"
    echo ""
    echo "Example:"
    echo "  $0 k8s_yaml_gen/bge-m3.yaml"
    echo ""
    exit 1
}

[[ $# -lt 1 ]] && { _err "A YAML file is required."; usage; }

YAML_FILE="$1"
# Resolve relative to CWD
[[ "$YAML_FILE" != /* ]] && YAML_FILE="$(pwd)/${YAML_FILE}"
[[ ! -f "$YAML_FILE" ]] && { _err "YAML file not found: $YAML_FILE"; exit 1; }

# ── Parse metadata from generated YAML ────────────────────────────────────────
# All patterns match the structure produced by k8s_yaml_gen.sh.

NAMESPACE=$(awk '/^kind: Namespace/{f=1} f && /^  name:/{print $2; exit}' "$YAML_FILE")
DEPLOY_NAME=$(awk '/^kind: Deployment/{f=1} f && /^  name:/{print $2; exit}' "$YAML_FILE")
SVC_NAME=$(awk '/^kind: Service/{f=1} f && /^  name:/{print $2; exit}' "$YAML_FILE")
APP_LABEL=$(awk '/matchLabels:/{f=1} f && /app:/{print $2; exit}' "$YAML_FILE")
NODEPORT=$(awk '/nodePort:/{print $2; exit}' "$YAML_FILE")
NODE_NAME=$(awk '/nodeName:/{print $2; exit}' "$YAML_FILE")
CONTAINER_PORT=$(awk '/containerPort:/{print $2; exit}' "$YAML_FILE")
# Readiness initialDelaySeconds (first occurrence = readiness probe)
INITIAL_DELAY=$(awk '/initialDelaySeconds:/{print $2; exit}' "$YAML_FILE")
# Config file is the third arg: bash  vllm_server.sh  <config.conf>
CONFIG_FILE=$(awk '/^        args:/{f=1; next} f && /\.conf"/{gsub(/[" ]/,""); sub(/^-/,""); print; exit}' "$YAML_FILE")

for var in NAMESPACE DEPLOY_NAME SVC_NAME APP_LABEL NODEPORT NODE_NAME CONTAINER_PORT INITIAL_DELAY CONFIG_FILE; do
    [[ -z "${!var}" ]] && { _err "Failed to parse ${var} from YAML: ${YAML_FILE}"; exit 1; }
done
[[ ! -f "$CONFIG_FILE" ]] && { _err "Config file not found: $CONFIG_FILE"; exit 1; }

# ── Load config (for API test details) ────────────────────────────────────────
task=""
served_model_name=""
model_weights=""
port="${CONTAINER_PORT}"

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ── Registry lookup (for model API path) ──────────────────────────────────────
registry_get() {
    awk -v sec="[$1]" -v fld="$2" '
        /^\[/ { cur = $0 }
        cur == sec && match($0, "^" fld "=") { print substr($0, length(fld)+2); exit }
    ' "$MODEL_REGISTRY"
}
MODEL_LOCAL_PATH=$(registry_get "$model_weights" "local_path")
MODEL_API="${served_model_name:-${MODEL_LOCAL_PATH}}"

# ── Resolve node IP ───────────────────────────────────────────────────────────
NODE_IP=$(kubectl get node "$NODE_NAME" \
    -o jsonpath='{range .status.addresses[*]}{.type}{"\t"}{.address}{"\n"}{end}' \
    | awk '$1=="InternalIP"{print $2; exit}')
[[ -z "$NODE_IP" ]] && NODE_IP="$NODE_NAME"

_info "YAML        : $YAML_FILE"
_info "Namespace   : $NAMESPACE"
_info "Deployment  : $DEPLOY_NAME  →  Service: $SVC_NAME"
_info "Node        : $NODE_NAME  ($NODE_IP)"
_info "NodePort    : $NODEPORT"
_info "Config      : $CONFIG_FILE"
echo ""

# ── Apply YAML ─────────────────────────────────────────────────────────────────
kubectl apply -f "$YAML_FILE"
_ok "Resources applied."
echo ""

# ── Wait for Pod readiness ────────────────────────────────────────────────────
TIMEOUT=$(( INITIAL_DELAY + 300 ))
_info "Waiting for Pod to become Ready (~$((INITIAL_DELAY / 60)) min estimated)..."
_info "Monitor: kubectl logs -n ${NAMESPACE} -l app=${APP_LABEL} -f"
echo ""

ELAPSED=0
INTERVAL=15
READY=false

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    STATUS=$(kubectl get pods -n "$NAMESPACE" -l "app=${APP_LABEL}" \
        --no-headers -o custom-columns='R:.status.containerStatuses[0].ready' \
        2>/dev/null | head -1 || echo "unknown")
    [[ "$STATUS" == "true" ]] && { READY=true; break; }
    printf "."
    sleep $INTERVAL
    ELAPSED=$((ELAPSED + INTERVAL))
done
echo ""

# ── API smoke test ────────────────────────────────────────────────────────────
if $READY; then
    _ok "══════════════════════════════════════════════════════"
    _ok " vLLM server ready — ${DEPLOY_NAME}  NodePort :${NODEPORT}"
    _ok "══════════════════════════════════════════════════════"
    echo ""
    _info "Running API smoke test..."
    echo ""

    if [[ "$task" == "embed" ]]; then
        RESULT=$(curl -sf --noproxy "*" \
            "http://${NODE_IP}:${NODEPORT}/v1/embeddings" \
            -H 'Content-Type: application/json' \
            -d "{\"model\": \"${MODEL_API}\", \"input\": \"Hello, world!\"}" \
            2>/dev/null || true)
        if [[ -n "$RESULT" ]] && echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('object')=='list'" 2>/dev/null; then
            _ok "Embedding API smoke test passed"
            echo "$RESULT" | python3 -m json.tool 2>/dev/null | head -12 || true
        else
            _warn "API test returned unexpected response:"
            echo "${RESULT:-<empty>}"
        fi
    else
        RESULT=$(curl -sf --noproxy "*" \
            "http://${NODE_IP}:${NODEPORT}/v1/chat/completions" \
            -H 'Content-Type: application/json' \
            -d "{\"model\": \"${MODEL_API}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}], \"max_tokens\": 16}" \
            2>/dev/null || true)
        if [[ -n "$RESULT" ]] && echo "$RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'choices' in d" 2>/dev/null; then
            _ok "Chat completion API smoke test passed"
            echo "$RESULT" | python3 -m json.tool 2>/dev/null | head -16 || true
        else
            _warn "API test returned unexpected response:"
            echo "${RESULT:-<empty>}"
        fi
    fi
else
    _warn "Pod not Ready after ${TIMEOUT}s — may still be loading or failed."
    _warn "Check: kubectl logs -n ${NAMESPACE} -l app=${APP_LABEL} -f"
fi

# ── Print curl reference commands ─────────────────────────────────────────────
echo ""
if [[ "$task" == "embed" ]]; then
    echo "── Embedding test ──────────────────────────────────────────"
    echo "curl -s --noproxy \"*\" http://${NODE_IP}:${NODEPORT}/v1/embeddings \\"
    echo "  -H 'Content-Type: application/json' \\"
    echo "  -d '{\"model\": \"${MODEL_API}\", \"input\": \"Hello, world!\"}' \\"
    echo "  | python3 -m json.tool"
else
    echo "── Chat completion test ────────────────────────────────────"
    echo "curl -s --noproxy \"*\" http://${NODE_IP}:${NODEPORT}/v1/chat/completions \\"
    echo "  -H 'Content-Type: application/json' \\"
    echo "  -d '{\"model\": \"${MODEL_API}\", \"messages\": [{\"role\": \"user\", \"content\": \"Hello!\"}], \"max_tokens\": 64}' \\"
    echo "  | python3 -m json.tool"
fi

echo ""
echo "── K8s management ──────────────────────────────────────────"
echo "  kubectl get pods -n ${NAMESPACE}"
echo "  kubectl logs -n ${NAMESPACE} -l app=${APP_LABEL} -f"
echo "  kubectl describe pod -n ${NAMESPACE} -l app=${APP_LABEL}"
echo "  kubectl delete deployment/${DEPLOY_NAME} service/${SVC_NAME} -n ${NAMESPACE}"
