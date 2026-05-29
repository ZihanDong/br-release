#!/bin/bash
# Start the vLLM load balancer inside a Docker container.
#
# Usage:
#   ./start_lb.sh --port 8080 --config /path/to/config.yaml [OPTIONS]
#
# Options:
#   --host     Bind host inside container (default: 0.0.0.0)
#   --port     Bind port (required)
#   --config   Absolute path to backends config YAML (required)
#   --timeout  Per-request timeout in seconds (default: 3600)
#   --name     Docker container name (default: vllm-lb)
#   --image    Docker image to use (default: python:3.11-slim)
#   --detach   Run container in background (default: foreground with logs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

HOST="0.0.0.0"
PORT=""
CONFIG=""
TIMEOUT=3600
CONTAINER_NAME="vllm-lb"
IMAGE="vllm-lb:latest"
DETACH=false

usage() {
    sed -n '2,14p' "$0" | sed 's/^# //'
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --host)    HOST="$2";           shift 2 ;;
        --port)    PORT="$2";           shift 2 ;;
        --config)  CONFIG="$2";         shift 2 ;;
        --timeout) TIMEOUT="$2";        shift 2 ;;
        --name)    CONTAINER_NAME="$2"; shift 2 ;;
        --image)   IMAGE="$2";          shift 2 ;;
        --detach)  DETACH=true;         shift   ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

[[ -z "$PORT"   ]] && { echo "ERROR: --port is required";   usage; }
[[ -z "$CONFIG" ]] && { echo "ERROR: --config is required"; usage; }

CONFIG="$(realpath "$CONFIG")"
CONFIG_DIR="$(dirname "$CONFIG")"
CONFIG_FILE="$(basename "$CONFIG")"

# Remove stale container
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Removing existing container: $CONTAINER_NAME"
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm  "$CONTAINER_NAME" 2>/dev/null || true
fi

DOCKER_FLAGS=(-d)
[[ "$DETACH" == false ]] && DOCKER_FLAGS=()   # run in foreground; logs stream to terminal

echo "Starting container: $CONTAINER_NAME"
echo "  Image   : $IMAGE"
echo "  Listen  : $HOST:$PORT"
echo "  Config  : $CONFIG"
echo "  Timeout : ${TIMEOUT}s"
echo ""

docker run "${DOCKER_FLAGS[@]}" \
    --name "$CONTAINER_NAME" \
    --network host \
    -v "$CONFIG_DIR:/app/config:ro" \
    "$IMAGE" \
    --host "$HOST" \
    --port "$PORT" \
    --config "/app/config/$CONFIG_FILE" \
    --timeout "$TIMEOUT"

if [[ "$DETACH" == true ]]; then
    echo "Container started in background. Waiting for server..."
    for i in $(seq 1 30); do
        if curl -sf "http://localhost:${PORT}/health" > /dev/null 2>&1; then
            echo "Load balancer is ready at http://localhost:${PORT}"
            echo ""
            echo "Available models:"
            curl -s "http://localhost:${PORT}/v1/models" \
                | python3 -c "
import sys, json
d = json.load(sys.stdin)
for m in d['data']:
    print(f\"  {m['id']}  ({m['backends']} backend(s))\")
"
            echo ""
            echo "Logs : docker logs -f $CONTAINER_NAME"
            echo "Stop : docker stop $CONTAINER_NAME"
            exit 0
        fi
        sleep 1
    done
    echo "ERROR: Timed out waiting for server. Check: docker logs $CONTAINER_NAME"
    exit 1
fi
