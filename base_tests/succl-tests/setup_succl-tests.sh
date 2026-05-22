#!/usr/bin/env bash
# setup_succl-tests.sh — 构建 succl-tests Docker 测试容器环境
#
# 用法:
#   ./setup_succl-tests.sh single
#   ./setup_succl-tests.sh multi --pass <解密密码>
#
# 参数说明:
#   single          单节点模式: 不映射 InfiniBand 设备，不配置 SSH 免密登录
#   multi           多节点模式: 自动检测并映射 IB 设备（有则映射，无则跳过），
#                   并通过共享 RSA 密钥对配置容器间 SSH 免密登录
#   --pass <pass>   multi 模式必填，用于解密 setup/ssh-settings/biren-ssh-pass.tar.gz.enc
#
# 执行步骤:
#   1. 检测 InfiniBand 设备 (/dev/infiniband/uverbs*)
#   2. 加载 Docker 镜像（如镜像不存在则从 SDK_ROOT_PATH 导入）
#   3. 删除同名旧容器（如存在）
#   4. 启动容器（--net host，挂载 /home /data，映射 /dev/biren）
#   5. [multi] 安装 openssh-server，配置 sshd 端口 SSH_PORT，部署共享密钥
#   6. 安装 succl-tests（从 SDK_ROOT_PATH 解压到容器 /opt/succl-tests）
#   7. 检查 openMPI，不存在则从源码编译安装
#   8. 写入环境变量配置 /etc/profile.d/succl-tests.sh
#   9. 探测 GPU 型号，结果写入容器 /etc/succl-hw.conf（供 run_succl_tests.sh 读取）
#  10. 验证: [multi] SSH 免密登录自检；[single] mpiexec + 二进制文件检查
#
# 依赖文件:
#   ../../setup/ssh-settings/biren-ssh-pass.tar.gz.enc  — 加密的 RSA 密钥包
#   ../../setup/ssh-settings/set-ssh-auth.sh            — 密钥部署脚本
#
# 配置变量（脚本顶部可修改）:
#   SDK_ROOT_PATH          SDK 根目录，含镜像包和 succl-tests 安装包
#   IMAGE_NAME             Docker 镜像名称
#   CONTAINER_NAME         容器名称
#   SSH_PORT               多节点 sshd 端口（默认 2222，避免与宿主机 22 冲突）
set -euo pipefail

# ─── Configuration ─────────────────────────────────────────────────────────────
SDK_ROOT_PATH="/data/release/2604rc2/"
SUCCL_TEST_PACKAGE="packages/ubuntu-22.04/succl-tests_*.tar.gz"
BASE_IMAGE="images/birensupa-sdk-*.tar"

CONTAINER_NAME="biren_succl_tests"
IMAGE_NAME="birensupa-sdk:26.04.rc2-br1xx"
SSH_PORT=2222          # container sshd port (avoids conflict with host :22 on --net=host)
INSTALL_DIR="/opt/succl-tests"
# ───────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_SETTINGS_DIR="${SCRIPT_DIR}/../../setup/ssh-settings"
ENC_FILE="${SSH_SETTINGS_DIR}/biren-ssh-pass.tar.gz.enc"
SSH_SETUP_SCRIPT="${SSH_SETTINGS_DIR}/set-ssh-auth.sh"

# ─── Argument parsing ──────────────────────────────────────────────────────────
usage() {
    echo "Usage:"
    echo "  $0 single"
    echo "  $0 multi --pass <decrypt-password>"
    exit 1
}

MODE="${1:-}"
case "$MODE" in
    single|multi) ;;
    *) echo "ERROR: first argument must be 'single' or 'multi'." >&2; usage ;;
esac

SSH_KEY_PASS=""
shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pass) SSH_KEY_PASS="${2:-}"; shift 2 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage ;;
    esac
done

if [[ "$MODE" == "multi" && -z "$SSH_KEY_PASS" ]]; then
    echo "ERROR: --pass <password> is required in multi-node mode." >&2
    usage
fi

# ── multi 模式预检：依赖文件必须存在 ──────────────────────────────────────────
if [[ "$MODE" == "multi" ]]; then
    PREFLIGHT_OK=1
    if [[ ! -f "$ENC_FILE" ]]; then
        echo "ERROR: SSH key archive not found: $ENC_FILE" >&2
        PREFLIGHT_OK=0
    fi
    if [[ ! -f "$SSH_SETUP_SCRIPT" ]]; then
        echo "ERROR: SSH setup script not found: $SSH_SETUP_SCRIPT" >&2
        PREFLIGHT_OK=0
    fi
    if [[ "$PREFLIGHT_OK" -eq 0 ]]; then
        echo "  请将加密密钥包和部署脚本放入 ${SSH_SETTINGS_DIR}/ 后重试。" >&2
        exit 1
    fi
fi

echo "=== succl-tests setup: ${MODE}-node mode ==="

# ── 1. InfiniBand device detection ────────────────────────────────────────────
IB_ARGS=()
if [[ "$MODE" == "single" ]]; then
    echo "[IB] Skipped (single-node mode)."
elif [[ -d /dev/infiniband ]] && ls /dev/infiniband/uverbs* &>/dev/null; then
    echo "[IB] Devices detected — mapping /dev/infiniband into container."
    IB_ARGS+=("--device" "/dev/infiniband")
else
    echo "[IB] No InfiniBand devices found — skipping IB device mapping."
fi

# ── 2. Load Docker image if not already present ────────────────────────────────
if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    IMAGE_TAR=$(ls ${SDK_ROOT_PATH}${BASE_IMAGE} 2>/dev/null | head -1) || true
    if [[ -z "$IMAGE_TAR" ]]; then
        echo "ERROR: Base image not found at ${SDK_ROOT_PATH}${BASE_IMAGE}" >&2
        exit 1
    fi
    echo "[Image] Loading from: $IMAGE_TAR"
    docker load -i "$IMAGE_TAR"
fi
echo "[Image] Ready: $IMAGE_NAME"

# ── 3. Remove existing container ───────────────────────────────────────────────
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "[Container] Removing existing: $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME"
fi

# ── 4. Start container ─────────────────────────────────────────────────────────
echo "[Container] Starting: $CONTAINER_NAME"
docker run -d --name "$CONTAINER_NAME" \
    --restart unless-stopped \
    --cap-add=IPC_LOCK \
    --shm-size='256g' \
    --ulimit memlock=-1 \
    --ulimit nofile=655360 \
    -v /home:/home \
    -v /data:/data \
    --net host \
    --device /dev/biren \
    "${IB_ARGS[@]}" \
    "$IMAGE_NAME" /bin/bash -c "
        mkdir -p /run/sshd
        if [[ '${MODE}' == 'multi' ]] && command -v sshd &>/dev/null; then
            /usr/sbin/sshd 2>/dev/null || true
        fi
        tail -f /dev/null
    "

# ── 5. SSH setup (multi-node only) ────────────────────────────────────────────
if [[ "$MODE" == "multi" ]]; then
    echo "[SSH] Installing openssh-server..."
    docker exec "$CONTAINER_NAME" bash -c "
        set -e
        if ! dpkg -l openssh-server 2>/dev/null | grep -q '^ii'; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y --no-install-recommends openssh-server openssh-client
        else
            echo 'openssh-server already installed, skipping apt-get.'
        fi
        mkdir -p /run/sshd /root/.ssh
        chmod 700 /root/.ssh

        # Generate host keys if missing (needed in fresh containers)
        ssh-keygen -A 2>/dev/null || true

        sed -i 's/^#*Port .*/Port ${SSH_PORT}/'                          /etc/ssh/sshd_config
        sed -i 's/^#*PermitRootLogin .*/PermitRootLogin yes/'            /etc/ssh/sshd_config
        sed -i 's/^#*PubkeyAuthentication .*/PubkeyAuthentication yes/'  /etc/ssh/sshd_config
        sed -i 's/^#*AuthorizedKeysFile .*/AuthorizedKeysFile .ssh\/authorized_keys/' /etc/ssh/sshd_config
        grep -q '^Port ' /etc/ssh/sshd_config || echo 'Port ${SSH_PORT}' >> /etc/ssh/sshd_config
        grep -q '^PubkeyAuthentication ' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
        grep -q '^PermitRootLogin '      /etc/ssh/sshd_config || echo 'PermitRootLogin yes'      >> /etc/ssh/sshd_config
    "

    echo "[SSH] Deploying shared key pair..."
    docker exec "$CONTAINER_NAME" mkdir -p /tmp/ssh-setup
    docker cp "$ENC_FILE"         "${CONTAINER_NAME}:/tmp/ssh-setup/biren-ssh-pass.tar.gz.enc"
    docker cp "$SSH_SETUP_SCRIPT" "${CONTAINER_NAME}:/tmp/ssh-setup/set-ssh-auth.sh"
    docker exec "$CONTAINER_NAME" chmod +x /tmp/ssh-setup/set-ssh-auth.sh
    docker exec "$CONTAINER_NAME" bash -c "
        SSH_KEY_PASS='${SSH_KEY_PASS}' \
        /tmp/ssh-setup/set-ssh-auth.sh '' /tmp/ssh-setup/biren-ssh-pass.tar.gz.enc
        rm -rf /tmp/ssh-setup
    "

    echo "[SSH] Starting sshd on port ${SSH_PORT}..."
    docker exec "$CONTAINER_NAME" bash -c "/usr/sbin/sshd || service ssh start"
fi

# ── 6. Install succl-tests ────────────────────────────────────────────────────
echo "[succl-tests] Installing..."
SUCCL_PKG=$(ls ${SDK_ROOT_PATH}${SUCCL_TEST_PACKAGE} 2>/dev/null | head -1) || true
if [[ -z "$SUCCL_PKG" ]]; then
    echo "ERROR: succl-tests package not found at ${SDK_ROOT_PATH}${SUCCL_TEST_PACKAGE}" >&2
    exit 1
fi
docker exec "$CONTAINER_NAME" bash -c "
    set -e
    mkdir -p ${INSTALL_DIR}
    tar -zxf '${SUCCL_PKG}' -C ${INSTALL_DIR} --strip-components=1
    echo 'Extracted to ${INSTALL_DIR}:'
    ls ${INSTALL_DIR}/bin/ | head -5
"

# ── 7. Install openMPI if not present ─────────────────────────────────────────
echo "[openMPI] Checking..."
docker exec "$CONTAINER_NAME" bash -c "
    set -e
    if mpiexec --version &>/dev/null 2>&1; then
        echo 'Already installed:' \$(mpiexec --version 2>&1 | head -1)
        exit 0
    fi
    echo 'Not found — building from source (this takes ~10 min)...'
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y --no-install-recommends wget build-essential gfortran
    cd /tmp
    wget -q https://download.open-mpi.org/release/open-mpi/v4.1/openmpi-4.1.5.tar.gz
    tar -xf openmpi-4.1.5.tar.gz && cd openmpi-4.1.5
    ./configure --without-ucx --without-hcol --quiet
    make -j\$(nproc) --quiet && make install --quiet && ldconfig
    rm -rf /tmp/openmpi-4.1.5 /tmp/openmpi-4.1.5.tar.gz
    echo 'Installed:' \$(mpiexec --version 2>&1 | head -1)
"

# ── 8. Write environment profile ──────────────────────────────────────────────
docker exec "$CONTAINER_NAME" bash -c "
    SUCCL_LIB=\$(ls -d /usr/local/birensupa/sdk/latest/succl/lib/x86_64-linux-gnu/ 2>/dev/null || true)
    SUPA_LIB=\$(ls  -d /usr/local/birensupa/sdk/latest/supa/lib/  2>/dev/null || true)
    BRUMD_LIB=\$(ls -d /usr/local/birensupa/sdk/latest/brumd/lib/ 2>/dev/null || true)
    {
        echo 'export BR_UMD_DEBUG_P2P_ACCESS_CHECK=0'
        echo 'export PATH=${INSTALL_DIR}/bin:/usr/local/bin:\$PATH'
        if [[ -n \"\$SUCCL_LIB\" ]]; then
            echo \"export LD_LIBRARY_PATH=\${SUCCL_LIB}:\${SUPA_LIB}:\${BRUMD_LIB}:/usr/local/lib/:\\\$LD_LIBRARY_PATH\"
        fi
    } > /etc/profile.d/succl-tests.sh
    chmod +x /etc/profile.d/succl-tests.sh
"

# ── 9. Detect GPU model and write hardware config ─────────────────────────────
echo "[HW] Probing GPU model..."
PROBE_OUT=$(docker exec "$CONTAINER_NAME" bash -lc "
    mpiexec --allow-run-as-root -n 1 \
        -x BR_UMD_DEBUG_P2P_ACCESS_CHECK=0 \
        ${INSTALL_DIR}/bin/all_reduce_perf -b 512 -e 512 -n 1 -w 0 -c 0 2>&1 \
    | grep -oP 'Biren\w+' | head -1
" 2>/dev/null || true)
GPU_MODEL="${PROBE_OUT:-Unknown}"
BR166_FLAG=0
if echo "$GPU_MODEL" | grep -qi "166"; then BR166_FLAG=1; fi
docker exec "$CONTAINER_NAME" bash -c "
    echo 'GPU_MODEL=${GPU_MODEL}' > /etc/succl-hw.conf
    echo 'BR166_MODE=${BR166_FLAG}' >> /etc/succl-hw.conf
"
echo "[HW] GPU_MODEL=${GPU_MODEL}  BR166_MODE=${BR166_FLAG}  → /etc/succl-hw.conf"

# ── 10. Verify (mode-specific) ────────────────────────────────────────────────
echo ""
if [[ "$MODE" == "multi" ]]; then
    echo "[Verify] Passwordless SSH (container → localhost:${SSH_PORT})..."
    docker exec "$CONTAINER_NAME" bash -c "
        # Wait up to 10 s for sshd to accept connections
        for i in \$(seq 1 10); do
            if ssh -o StrictHostKeyChecking=no -o BatchMode=yes \
                   -o ConnectTimeout=2 -p ${SSH_PORT} root@127.0.0.1 'echo SSH_OK' 2>/dev/null; then
                exit 0
            fi
            sleep 1
        done
        echo 'SSH still not ready after 10 s — last attempt:' >&2
        ssh -v -o StrictHostKeyChecking=no -o BatchMode=yes -p ${SSH_PORT} root@127.0.0.1 'echo SSH_OK'
    " && echo "[Verify] Passwordless SSH: OK" \
      || echo "[Verify] WARNING: SSH check failed — inspect sshd status."
else
    echo "[Verify] Single-node: checking mpiexec + succl-tests binary..."
    docker exec "$CONTAINER_NAME" bash -c "
        source /etc/profile.d/succl-tests.sh
        mpiexec --version 2>&1 | head -1
        ls ${INSTALL_DIR}/bin/all_reduce_perf
        echo 'Binaries OK'
    "
fi

# ── 10. Usage summary ─────────────────────────────────────────────────────────
echo ""
echo "=== Done: ${CONTAINER_NAME} (${MODE}-node) ==="
echo "  Enter interactively : docker exec -it ${CONTAINER_NAME} bash"
echo "  succl-tests binaries : ${INSTALL_DIR}/bin/"
if [[ "$MODE" == "multi" ]]; then
    echo "  sshd port in container: ${SSH_PORT}"
    echo ""
    echo "Multi-node test example (2 nodes × 8 GPUs):"
    echo "  mpiexec --allow-run-as-root --mca pml ^ucx \\"
    echo "    --mca btl_tcp_if_include <iface> --mca plm_rsh_args \"-p ${SSH_PORT}\" \\"
    echo "    --host <node1_ip>:8,<node2_ip>:8 \\"
    echo "    -x BR_UMD_DEBUG_P2P_ACCESS_CHECK=0 \\"
    echo "    ${INSTALL_DIR}/bin/all_reduce_perf -t 1 -G 1 -e 1G -b 512 -d float -n 2"
else
    echo ""
    echo "Single-node test example (8 GPUs):"
    echo "  docker exec ${CONTAINER_NAME} bash -lc \\"
    echo "    'mpiexec --allow-run-as-root -n 8 -x BR_UMD_DEBUG_P2P_ACCESS_CHECK=0 \\"
    echo "    ${INSTALL_DIR}/bin/all_reduce_perf -t 1 -G 1 -e 1G -b 512 -d float -n 2'"
fi
