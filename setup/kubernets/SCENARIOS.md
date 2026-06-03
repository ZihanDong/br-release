# 典型配置场景

以下场景均在 `setup/kubernets/` 目录下执行。国内/Kylin 环境必须传入 `REGISTRY_MIRROR`（见注意事项）。

Registry 相关操作的完整说明见 [registry/README.md](registry/README.md)。

---

## 场景一：全新单节点集群（Master 兼 GPU 节点）

```bash
cd setup/kubernets

# 安装 k8s 基础环境
sudo REGISTRY_MIRROR=registry.aliyuncs.com/google_containers ./install.sh

# 初始化控制面
sudo REGISTRY_MIRROR=registry.aliyuncs.com/google_containers ./master.sh

# 将本机切换为 BirenTech GPU 算力节点
sudo ./set-node-mode.sh biren

# 部署私有 Registry（可选，按需）
sudo ./registry/setup-registry.sh
# 编辑 images.conf 后导入镜像
# vi ./registry/images.conf
sudo ./registry/update_images.sh add

# 验证
kubectl get nodes -o wide
kubectl get pods -A
curl http://$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}'):32000/v2/_catalog
```

---

## 场景二：Master + Worker 多节点集群

```bash
# === 在 Master 节点执行 ===
sudo REGISTRY_MIRROR=registry.aliyuncs.com/google_containers ./install.sh
sudo REGISTRY_MIRROR=registry.aliyuncs.com/google_containers ./master.sh   # 生成 /root/k8s-join.sh

# 将 join 文件分发到 Worker 节点
scp /root/k8s-join.sh worker01:/root/k8s-join.sh

# === 在 Worker 节点执行 ===
sudo REGISTRY_MIRROR=registry.aliyuncs.com/google_containers ./install.sh
sudo ./join.sh biren                  # 以 GPU 节点加入

# === 在 Master 节点执行（部署 Registry，推送镜像，分发信任）===
sudo ./registry/setup-registry.sh
# vi ./registry/images.conf
sudo ./registry/update_images.sh add
sudo ./registry/registry-trust.sh apply worker01,worker02
```

---

## 场景三：节点算力角色切换

```bash
# Master 节点参与 CPU 调度
sudo ./set-node-mode.sh cpu

# 切换为 BirenTech GPU 节点（原厂整卡插件，仅整卡调度）
sudo ./set-node-mode.sh biren

# 切换为 GPU 节点并启用 HAMi-Biren 统一插件（整卡 + SVI + vGPU）
# 取代原厂整卡插件；vGPU 软切分需节点加载 1.12.0 KMD
sudo ./set-node-mode.sh biren --vgpu

# 恢复隔离（仅运行系统组件）
sudo ./set-node-mode.sh none

# 批量切换多个 Worker 节点为 GPU 节点
sudo ./set-node-mode.sh biren worker01,worker02
sudo ./set-node-mode.sh biren --vgpu worker01,worker02   # 批量部署统一插件
```

---

## 场景四：完整清除并重置

```bash
# 1. 先清除 Registry（读取 registry.conf 自动识别要删除的内容）
sudo ./registry/registry_clean.sh

# 2. 再清除 k8s（打印摘要 → 确认 → 执行）
sudo ./k8s_clean.sh

# 3. 重新初始化
sudo REGISTRY_MIRROR=registry.aliyuncs.com/google_containers ./install.sh
sudo REGISTRY_MIRROR=registry.aliyuncs.com/google_containers ./master.sh
```

---

## 注意事项

- **国内/Kylin 环境**：`install.sh` 和 `master.sh` 均需传入 `REGISTRY_MIRROR=registry.aliyuncs.com/google_containers`，否则 containerd sandbox_image 和 kubeadm 镜像拉取会因 `registry.k8s.io` 不可达而失败
- `join.sh biren` 需要 admin.conf；若 master 已通过 `set-node-mode.sh biren` 首次部署，该前提已满足
- `packages/biren/` 目录需提前填充（见 `set-node-mode.sh` 说明中的 BirenTech device plugin 准备步骤）
- `set-node-mode.sh biren --vgpu` 另需 `packages/hami-biren/` 安装包（见 `packages/README.md`）；vGPU 软切分还需节点加载 1.12.0 KMD
- 清除操作（`registry_clean.sh`、`k8s_clean.sh`）均需用户二次确认，不会静默执行
