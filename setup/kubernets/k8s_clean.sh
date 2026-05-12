#!/usr/bin/env bash
# 重置系统到 k8s 安装之前的状态
#
# 执行内容：
#   1. kubeadm reset（清理 k8s 控制面/节点状态）
#   2. 卸载 kubeadm / kubelet / kubectl / kubernetes-cni 包
#   3. 移除 k8s apt 源及 GPG 密钥
#   4. 清理 /etc/kubernetes、/var/lib/kubelet、/var/lib/etcd、/opt/cni 等目录
#   5. 清理 ~/.kube 用户配置
#   6. 恢复 containerd 配置备份（最新 .bak.* 文件）
#   7. 移除 k8s 写入的 sysctl / modules-load 配置
#   8. 清理残留 CNI 网络接口（cni0、flannel.1 等）
#   9. 重启 containerd
#
# 不影响：containerd 本身、Docker、BirenTech runtime、原有应用数据
#
# 用法：
#   sudo ./k8s_clean.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"
source "${LIB_DIR}/common.sh"

require_root

# ── 收集当前状态 ───────────────────────────────────────────────────────────────
_K8S_PKGS=()
for pkg in kubeadm kubelet kubectl kubernetes-cni; do
    # match both 'ii' (installed) and 'hi' (installed+hold)
    dpkg -l "${pkg}" 2>/dev/null | grep -qE '^[ih][ih]' && _K8S_PKGS+=("${pkg}") || true
done

_KUBEADM_INSTALLED=false
command -v kubeadm &>/dev/null && _KUBEADM_INSTALLED=true

_APT_SOURCES=()
[[ -f /etc/apt/sources.list.d/kubernetes.list ]] && _APT_SOURCES+=("/etc/apt/sources.list.d/kubernetes.list")

_APT_KEYRINGS=()
[[ -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]] && _APT_KEYRINGS+=("/etc/apt/keyrings/kubernetes-apt-keyring.gpg")

_DIRS=()
for d in /etc/kubernetes /var/lib/kubelet /var/lib/etcd /opt/cni /var/lib/cni /run/flannel; do
    [[ -e "${d}" ]] && _DIRS+=("${d}")
done

_KUBE_USER_DIRS=()
for u in $(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $6}') /root; do
    [[ -d "${u}/.kube" ]] && _KUBE_USER_DIRS+=("${u}/.kube")
done

# containerd 备份
_CTD_BAK=""
_CTD_BAK=$(ls -t /etc/containerd/config.toml.bak.* 2>/dev/null | head -1 || true)

_SYSCTL_FILES=()
[[ -f /etc/sysctl.d/99-k8s.conf ]] && _SYSCTL_FILES+=("/etc/sysctl.d/99-k8s.conf")

_MODULES_FILES=()
[[ -f /etc/modules-load.d/k8s.conf ]] && _MODULES_FILES+=("/etc/modules-load.d/k8s.conf")

# CNI 网络接口
_CNI_IFACES=()
for iface in cni0 flannel.1 tunl0 vxlan.calico; do
    ip link show "${iface}" &>/dev/null && _CNI_IFACES+=("${iface}") || true
done

# ── 打印 Summary ───────────────────────────────────────────────────────────────
echo
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              k8s 清理 —— 待执行操作摘要                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo

echo "【1】kubeadm reset"
if ${_KUBEADM_INSTALLED}; then
    echo "    执行: kubeadm reset -f"
else
    echo "    kubeadm 未安装，跳过。"
fi
echo

echo "【2】卸载 k8s 软件包"
if [[ ${#_K8S_PKGS[@]} -gt 0 ]]; then
    for p in "${_K8S_PKGS[@]}"; do echo "    - ${p}"; done
else
    echo "    未检测到已安装的 k8s 软件包。"
fi
echo

echo "【3】移除 apt 源 / GPG 密钥"
if [[ ${#_APT_SOURCES[@]} -gt 0 || ${#_APT_KEYRINGS[@]} -gt 0 ]]; then
    for f in "${_APT_SOURCES[@]}" "${_APT_KEYRINGS[@]}"; do echo "    - ${f}"; done
else
    echo "    未检测到 k8s apt 源文件。"
fi
echo

echo "【4】删除 k8s 目录"
if [[ ${#_DIRS[@]} -gt 0 ]]; then
    for d in "${_DIRS[@]}"; do echo "    - ${d}"; done
else
    echo "    无需清理的目录。"
fi
echo

echo "【5】清理用户 ~/.kube 配置"
if [[ ${#_KUBE_USER_DIRS[@]} -gt 0 ]]; then
    for d in "${_KUBE_USER_DIRS[@]}"; do echo "    - ${d}"; done
else
    echo "    无 ~/.kube 目录。"
fi
echo

echo "【6】恢复 containerd 配置"
if [[ -n "${_CTD_BAK}" ]]; then
    echo "    备份文件: ${_CTD_BAK}"
    echo "    恢复到 : /etc/containerd/config.toml"
else
    echo "    未找到 containerd 配置备份（/etc/containerd/config.toml.bak.*），跳过。"
fi
echo

echo "【7】移除 k8s sysctl / modules-load 配置"
if [[ ${#_SYSCTL_FILES[@]} -gt 0 || ${#_MODULES_FILES[@]} -gt 0 ]]; then
    for f in "${_SYSCTL_FILES[@]}" "${_MODULES_FILES[@]}"; do echo "    - ${f}"; done
else
    echo "    无 k8s 专属 sysctl/modules 配置。"
fi
echo

echo "【8】清理残留 CNI 网络接口"
if [[ ${#_CNI_IFACES[@]} -gt 0 ]]; then
    for i in "${_CNI_IFACES[@]}"; do echo "    - ${i}"; done
else
    echo "    无残留 CNI 接口。"
fi
echo

echo "【9】重启 containerd"
echo "    systemctl restart containerd"
echo

echo "──────────────────────────────────────────────────────────────"
echo "  不影响：containerd 服务本身、Docker、BirenTech runtime、"
echo "           /data/registry 存储、原有应用数据"
echo "──────────────────────────────────────────────────────────────"
echo

# ── 用户确认 ───────────────────────────────────────────────────────────────────
read -rp "确认执行以上所有清理操作？[y/N] " _CONFIRM
case "${_CONFIRM}" in
    y|Y|yes|YES) ;;
    *) echo "已取消。"; exit 0 ;;
esac

echo

# ── 执行清理 ───────────────────────────────────────────────────────────────────

# 1. kubeadm reset
if ${_KUBEADM_INSTALLED}; then
    log_info "Step 1/9: kubeadm reset..."
    kubeadm reset -f 2>&1 | sed 's/^/    /' || true
else
    log_info "Step 1/9: kubeadm 未安装，跳过。"
fi

# 2. 卸载软件包
log_info "Step 2/9: 卸载 k8s 软件包..."
if [[ ${#_K8S_PKGS[@]} -gt 0 ]]; then
    apt-mark unhold "${_K8S_PKGS[@]}" 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get purge -y "${_K8S_PKGS[@]}" 2>&1 | tail -5 || true
    apt-get autoremove -y 2>&1 | tail -3 || true
    log_info "  软件包已卸载。"
else
    log_info "  无需卸载。"
fi

# 3. 移除 apt 源 / 密钥
log_info "Step 3/9: 移除 apt 源 / GPG 密钥..."
for f in "${_APT_SOURCES[@]}" "${_APT_KEYRINGS[@]}"; do
    rm -f "${f}" && log_info "  已删除: ${f}"
done
apt-get update -qq 2>/dev/null || true

# 4. 删除 k8s 目录
log_info "Step 4/9: 删除 k8s 目录..."
for d in "${_DIRS[@]}"; do
    rm -rf "${d}" && log_info "  已删除: ${d}"
done

# 5. 清理用户 ~/.kube
log_info "Step 5/9: 清理用户 ~/.kube 配置..."
for d in "${_KUBE_USER_DIRS[@]}"; do
    rm -rf "${d}" && log_info "  已删除: ${d}"
done

# 6. 恢复 containerd 配置
log_info "Step 6/9: 恢复 containerd 配置..."
if [[ -n "${_CTD_BAK}" ]]; then
    cp "${_CTD_BAK}" /etc/containerd/config.toml
    log_info "  已恢复: ${_CTD_BAK} → /etc/containerd/config.toml"
else
    log_warn "  无备份文件，保持当前配置不变。"
fi

# 7. 移除 k8s sysctl / modules 配置
log_info "Step 7/9: 移除 k8s sysctl / modules 配置..."
for f in "${_SYSCTL_FILES[@]}" "${_MODULES_FILES[@]}"; do
    rm -f "${f}" && log_info "  已删除: ${f}"
done
if [[ ${#_SYSCTL_FILES[@]} -gt 0 ]]; then
    sysctl --system &>/dev/null || true
fi

# 8. 清理 CNI 网络接口
log_info "Step 8/9: 清理 CNI 网络接口..."
for iface in "${_CNI_IFACES[@]}"; do
    ip link set "${iface}" down 2>/dev/null || true
    ip link delete "${iface}" 2>/dev/null && log_info "  已删除接口: ${iface}" || true
done

# iptables 规则清理（FORWARD/KUBE-*/CNI 链）
if command -v iptables &>/dev/null; then
    iptables -F 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    log_info "  iptables 规则已清空。"
fi

# 9. 重启 containerd
log_info "Step 9/9: 重启 containerd..."
systemctl restart containerd
log_info "  containerd 已重启。"

echo
log_info "════════════════════════════════════════════════════════"
log_info "  k8s 清理完成！系统已恢复到 k8s 安装之前的状态。"
log_info "  如需重新初始化，运行: sudo ./install.sh && sudo ./master.sh"
log_info "════════════════════════════════════════════════════════"
