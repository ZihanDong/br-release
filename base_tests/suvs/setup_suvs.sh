#!/usr/bin/env bash
# setup_suvs.sh — build and initialize the SUVS Docker test container
set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────
SDK_ROOT_PATH="/data/release/2602rc2/"
SUDCGM_PACKAGE="packages/ubuntu-22.04/sudcgm_*.run"
BASE_IMAGE="images/birensupa-sdk-*.tar"

CONTAINER_NAME="biren_suvs"
IMAGE_NAME="birensupa-sdk:26.02.rc2-br1xx"
# ───────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load Docker image if not already present
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    IMAGE_TAR=$(ls ${SDK_ROOT_PATH}${BASE_IMAGE} 2>/dev/null | head -1)
    if [[ -z "$IMAGE_TAR" ]]; then
        echo "ERROR: Base image not found at ${SDK_ROOT_PATH}${BASE_IMAGE}" >&2
        exit 1
    fi
    echo "Loading Docker image from: $IMAGE_TAR"
    docker load -i "$IMAGE_TAR"
fi

# Remove existing container if present
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Removing existing container: $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME"
fi

# Start container — no InfiniBand device required for SUVS
echo "Starting SUVS container: $CONTAINER_NAME"
docker run -d --name "$CONTAINER_NAME" \
    --cap-add=IPC_LOCK \
    --shm-size='256g' \
    --ulimit memlock=-1 \
    --ulimit nofile=1048576 \
    -v /home:/home \
    -v /data:/data \
    --net host \
    --device /dev/biren \
    "$IMAGE_NAME" /bin/bash -c "tail -f /dev/null"

echo "Container started. Installing sudcgm (provides suvs)..."

SUDCGM_PKG=$(ls ${SDK_ROOT_PATH}${SUDCGM_PACKAGE} 2>/dev/null | head -1)
if [[ -z "$SUDCGM_PKG" ]]; then
    echo "ERROR: sudcgm package not found at ${SDK_ROOT_PATH}${SUDCGM_PACKAGE}" >&2
    exit 1
fi

docker exec "$CONTAINER_NAME" bash -c "
    set -e
    chmod +x '${SUDCGM_PKG}'
    '${SUDCGM_PKG}'
    source /usr/local/birensupa/sudcgm/latest/scripts/brsw_set_env.sh 2>/dev/null || true
    # Fix missing libglog if suvs cannot start (best-effort)
    if ! suvs --version &>/dev/null; then
        apt-get install -y libgoogle-glog-dev 2>/dev/null || true
    fi
"

echo "Verifying suvs installation..."
docker exec "$CONTAINER_NAME" bash -c "
    source /usr/local/birensupa/sudcgm/latest/scripts/brsw_set_env.sh 2>/dev/null || true
    suvs -g
" 2>&1 | head -30

echo ""
echo "Done. Container '$CONTAINER_NAME' is ready for SUVS tests."
echo "  Enter interactively : docker exec -it $CONTAINER_NAME bash"
echo "  Run tests           : ${SCRIPT_DIR}/run_suvs.sh"
