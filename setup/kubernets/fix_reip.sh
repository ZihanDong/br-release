#!/bin/bash
# One-time script to re-configure k8s after the node IP changes.
# Usage: sudo bash fix_reip.sh <OLD_IP> <NEW_IP>
# Example: sudo bash fix_reip.sh 10.49.4.248 10.50.36.126
set -euo pipefail

OLD_IP="${1:?Usage: $0 <OLD_IP> <NEW_IP>}"
NEW_IP="${2:?Usage: $0 <OLD_IP> <NEW_IP>}"
HOSTNAME="$(hostname)"
K8S_VER="v1.30.0"

echo "[1/8] Creating kubeadm config for new IP ${NEW_IP} ..."
cat > /tmp/kubeadm-reip.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${NEW_IP}"
  bindPort: 6443
nodeRegistration:
  name: ${HOSTNAME}
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: ${K8S_VER}
controlPlaneEndpoint: "${NEW_IP}:6443"
networking:
  serviceSubnet: "10.96.0.0/12"
  podSubnet: "10.244.0.0/16"
apiServer:
  certSANs:
  - "${NEW_IP}"
  - "${HOSTNAME}"
etcd:
  local:
    dataDir: /var/lib/etcd
EOF

echo "[2/8] Backing up existing PKI ..."
BACKUP_DIR="/etc/kubernetes/pki-backup-$(date +%Y%m%d%H%M%S)"
cp -r /etc/kubernetes/pki "${BACKUP_DIR}"
echo "  → backup saved to ${BACKUP_DIR}"

echo "[3/8] Deleting old leaf certificates (CAs kept) ..."
rm -f /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
rm -f /etc/kubernetes/pki/etcd/server.crt /etc/kubernetes/pki/etcd/server.key
rm -f /etc/kubernetes/pki/etcd/peer.crt   /etc/kubernetes/pki/etcd/peer.key

echo "[4/8] Regenerating certificates with new IP ..."
kubeadm init phase certs apiserver    --config /tmp/kubeadm-reip.yaml
kubeadm init phase certs etcd-server  --config /tmp/kubeadm-reip.yaml
kubeadm init phase certs etcd-peer    --config /tmp/kubeadm-reip.yaml

echo "  Verifying SANs ..."
for cert in /etc/kubernetes/pki/apiserver.crt \
            /etc/kubernetes/pki/etcd/server.crt \
            /etc/kubernetes/pki/etcd/peer.crt; do
    echo -n "  ${cert}: "
    openssl x509 -in "${cert}" -noout -text 2>/dev/null \
        | grep -A2 "Subject Alternative" | grep "IP Address" | tr -d ' '
done

echo "[5/8] Updating etcd manifest ..."
sed -i "s/${OLD_IP}/${NEW_IP}/g" /etc/kubernetes/manifests/etcd.yaml

echo "[6/8] Updating kube-apiserver manifest ..."
sed -i "s/${OLD_IP}/${NEW_IP}/g" /etc/kubernetes/manifests/kube-apiserver.yaml

echo "[7/8] Updating kubeconfig files ..."
for conf in /etc/kubernetes/admin.conf \
            /etc/kubernetes/controller-manager.conf \
            /etc/kubernetes/scheduler.conf \
            /etc/kubernetes/kubelet.conf \
            /etc/kubernetes/super-admin.conf; do
    [ -f "${conf}" ] && sed -i "s|https://${OLD_IP}:6443|https://${NEW_IP}:6443|g" "${conf}" \
        && echo "  updated ${conf}"
done

# Update user kubeconfig if it points to the old IP
USER_KUBECONFIG="/home/zanedong/.kube/config"
if [ -f "${USER_KUBECONFIG}" ]; then
    sed -i "s|https://${OLD_IP}:6443|https://${NEW_IP}:6443|g" "${USER_KUBECONFIG}"
    echo "  updated ${USER_KUBECONFIG}"
fi

echo "[8/8] Restarting kubelet ..."
systemctl restart kubelet

echo ""
echo "Waiting 40s for control plane to come up ..."
sleep 40

echo ""
echo "=== Cluster status ==="
kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide 2>&1 || true
kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A 2>&1 || true

echo ""
echo "Done. If nodes are still NotReady, wait another 30s and re-check."
