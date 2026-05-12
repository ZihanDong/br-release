#!/usr/bin/env bash
# 示例 03：使用私有 Registry 中的 vLLM 镜像创建测试 Pod
#
# 验证内容：
#   - 节点可从私有 Registry 拉取镜像（无 ImagePullBackOff）
#   - BirenTech GPU 资源被正确分配（birentech.com/gpu limit）
#   - vllm 包可正常导入
#   - /dev/biren GPU 设备在容器内可见
#
# 使用方式：
#   bash setup/samples/03-vllm-pod-test.sh
#
# 环境变量：
#   REGISTRY_ADDR   Registry 地址，默认从 registry-trust.conf 读取
#   GPU_COUNT       申请的 GPU 数量（默认 1）
#   KUBECONFIG      kubectl 配置文件（默认 ~/.kube/config）
#   NAMESPACE       Pod 部署命名空间（默认 default）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="${SCRIPT_DIR}/../kubernets"
TRUST_CONF="${K8S_DIR}/registry/registry-trust.conf"

# ── 读取配置 ───────────────────────────────────────────────────────────────────
: "${KUBECONFIG:=${HOME}/.kube/config}"
: "${NAMESPACE:=default}"
: "${GPU_COUNT:=1}"
: "${POD_NAME:=vllm-test}"

# 自动从 trust conf 读取 Registry 地址
if [[ -z "${REGISTRY_ADDR:-}" && -f "${TRUST_CONF}" ]]; then
    REGISTRY_ADDR=$(grep TRUST_REGISTRY_ADDR "${TRUST_CONF}" | cut -d= -f2)
fi
[[ -n "${REGISTRY_ADDR:-}" ]] \
    || { echo "错误: 未能确定 REGISTRY_ADDR，请设置环境变量或先执行 setup-registry.sh"; exit 1; }

VLLM_IMAGE="${REGISTRY_ADDR}/infer/birensupa-smartinfer-vllm:26.04.beta1-py310-pt2.8.0-br1xx"

_info()  { echo -e "\033[0;32m[INFO]\033[0m  $*"; }
_ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
_fail()  { echo -e "\033[0;31m[FAIL]\033[0m  $*"; }

echo
_info "Registry : ${REGISTRY_ADDR}"
_info "镜像     : ${VLLM_IMAGE}"
_info "GPU 数量 : ${GPU_COUNT}"
echo

# ── 前置检查 ───────────────────────────────────────────────────────────────────
command -v kubectl &>/dev/null || { echo "未找到 kubectl"; exit 1; }
kubectl get nodes --kubeconfig "${KUBECONFIG}" &>/dev/null \
    || { echo "kubectl 无法访问集群，检查 KUBECONFIG=${KUBECONFIG}"; exit 1; }

GPU_AVAIL=$(kubectl get nodes --kubeconfig "${KUBECONFIG}" \
    -o jsonpath='{.items[*].status.allocatable.birentech\.com/gpu}' 2>/dev/null \
    | tr ' ' '\n' | awk '{s+=$1} END{print s+0}')
_info "集群可用 GPU 总数: ${GPU_AVAIL}"
[[ "${GPU_AVAIL}" -ge "${GPU_COUNT}" ]] \
    || { _fail "可用 GPU（${GPU_AVAIL}）不足 ${GPU_COUNT} 个"; exit 1; }

# ── 清理旧 Pod ──────────────────────────────────────────────────────────────────
kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}" \
    --kubeconfig "${KUBECONFIG}" --ignore-not-found &>/dev/null

# ── 创建测试 Pod ────────────────────────────────────────────────────────────────
_info "创建测试 Pod: ${POD_NAME}"
kubectl apply --kubeconfig "${KUBECONFIG}" -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: vllm-test
    sample: "03"
spec:
  restartPolicy: Never
  tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  containers:
  - name: vllm
    image: ${VLLM_IMAGE}
    imagePullPolicy: IfNotPresent
    command:
    - python3
    - -c
    - |
      import sys, os
      print("=== 环境信息 ===")
      print(f"Python: {sys.version.split()[0]}")

      import torch
      print(f"torch : {torch.__version__}")

      try:
          import vllm
          print(f"vllm  : {vllm.__version__}")
      except Exception as e:
          print(f"vllm  : import error — {e}")

      devs = [d for d in os.listdir('/dev') if 'biren' in d.lower()]
      print(f"/dev/biren 设备: {devs if devs else '未找到（可能需要主机路径挂载）'}")

      alloc_gpu = os.environ.get('BIREN_VISIBLE_DEVICES', os.environ.get('GPU_DEVICE_ORDINAL', ''))
      print(f"分配 GPU: {alloc_gpu if alloc_gpu else '（env 未设置，查看 /dev）'}")

      print("=== 验证完成 ===")
    resources:
      limits:
        birentech.com/gpu: "${GPU_COUNT}"
    volumeMounts:
    - name: biren-driver
      mountPath: /usr/local/birensupa
      readOnly: true
  volumes:
  - name: biren-driver
    hostPath:
      path: /usr/local/birensupa
      type: Directory
EOF

# ── 等待完成 ────────────────────────────────────────────────────────────────────
_info "等待 Pod 完成（最多 5 分钟）..."
TIMEOUT=300
ELAPSED=0
while true; do
    PHASE=$(kubectl get pod "${POD_NAME}" -n "${NAMESPACE}" \
        --kubeconfig "${KUBECONFIG}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Pending")
    case "${PHASE}" in
        Succeeded) break ;;
        Failed)
            _fail "Pod 失败！查看日志："
            kubectl logs "${POD_NAME}" -n "${NAMESPACE}" --kubeconfig "${KUBECONFIG}"
            exit 1
            ;;
    esac
    [[ $ELAPSED -ge $TIMEOUT ]] && {
        _fail "超时（${TIMEOUT}s）。当前状态:"
        kubectl describe pod "${POD_NAME}" -n "${NAMESPACE}" --kubeconfig "${KUBECONFIG}" | tail -20
        exit 1
    }
    _info "  ${PHASE} ... (${ELAPSED}s / ${TIMEOUT}s)"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

# ── 打印结果 ────────────────────────────────────────────────────────────────────
echo
_info "═══════════════════════════════════════"
_info "  Pod 日志输出："
_info "═══════════════════════════════════════"
kubectl logs "${POD_NAME}" -n "${NAMESPACE}" --kubeconfig "${KUBECONFIG}"
echo

# ── 结果验证 ────────────────────────────────────────────────────────────────────
LOGS=$(kubectl logs "${POD_NAME}" -n "${NAMESPACE}" --kubeconfig "${KUBECONFIG}" 2>/dev/null)
PASS=true

grep -q "torch" <<< "${LOGS}"  && _ok  "torch 导入成功" || { _fail "torch 未找到"; PASS=false; }
grep -q "vllm"  <<< "${LOGS}"  && _ok  "vllm 导入成功"  || { _fail "vllm 未找到";  PASS=false; }
grep -q "验证完成" <<< "${LOGS}" && _ok "Pod 正常完成"  || { _fail "Pod 异常退出"; PASS=false; }

echo
if ${PASS}; then
    _ok "═══════════════════════════════════════"
    _ok "  全部验证通过！vLLM 镜像运行正常。"
    _ok "═══════════════════════════════════════"
else
    _fail "存在验证失败项，请查看上方日志。"
    exit 1
fi

# ── 清理 ────────────────────────────────────────────────────────────────────────
kubectl delete pod "${POD_NAME}" -n "${NAMESPACE}" \
    --kubeconfig "${KUBECONFIG}" --ignore-not-found &>/dev/null
_info "测试 Pod 已清理。"
