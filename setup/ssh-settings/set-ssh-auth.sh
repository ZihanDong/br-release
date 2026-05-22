#!/usr/bin/env bash
# set-ssh-auth.sh — 解密 RSA 密钥包并部署到容器 /root/.ssh/
#
# 用法（容器内执行）：
#   SSH_KEY_PASS=<密码> ./set-ssh-auth.sh <node_id> <enc_file>
#
# 参数：
#   node_id   节点标识（当前未使用，占位符）
#   enc_file  AES-256-CBC 加密的 tar.gz 密钥包路径
set -euo pipefail

ENC_FILE="${2:-}"
if [[ -z "$ENC_FILE" || ! -f "$ENC_FILE" ]]; then
    echo "ERROR: encrypted key file not found: $ENC_FILE" >&2
    exit 1
fi
if [[ -z "${SSH_KEY_PASS:-}" ]]; then
    echo "ERROR: SSH_KEY_PASS environment variable is not set." >&2
    exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:"$SSH_KEY_PASS" \
    -in "$ENC_FILE" | tar -xz -C "$TMPDIR"

KEY_DIR=$(find "$TMPDIR" -name "id_rsa" -printf '%h\n' | head -1)
if [[ -z "$KEY_DIR" ]]; then
    echo "ERROR: id_rsa not found in archive." >&2
    exit 1
fi

mkdir -p /root/.ssh
chmod 700 /root/.ssh
cp "${KEY_DIR}/id_rsa"     /root/.ssh/id_rsa
cp "${KEY_DIR}/id_rsa.pub" /root/.ssh/id_rsa.pub
cat "${KEY_DIR}/id_rsa.pub" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/id_rsa /root/.ssh/authorized_keys
chmod 644 /root/.ssh/id_rsa.pub

echo "[SSH] Keys deployed to /root/.ssh/"
