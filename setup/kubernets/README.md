# Kubernetes 自动化部署工具集

面向 Ubuntu 20.04/22.04/24.04 及 Kylin V10/V11 的 Kubernetes 一键部署、节点管理和清理工具。支持 k8s ≥ v1.19，已在以下环境验证：

| 平台 | k8s 版本 | 容器运行时 |
|------|----------|-----------|
| Ubuntu 22.04 | v1.30 | containerd v2 |
| Kylin Linux Advanced Server V10 | v1.25.3 | containerd v1.7 |

---

## 目录结构

```
setup/kubernets/
├── install.sh              # 节点基础环境安装（containerd + k8s 包）
├── master.sh               # 控制面初始化（kubeadm init + CNI）
├── join.sh                 # 工作节点加入集群（支持 CPU / BirenTech GPU 模式）
├── set-node-mode.sh        # 已加入节点的算力角色切换
├── k8s_clean.sh            # 清除 k8s 全部组件，恢复安装前状态（Ubuntu + Kylin）
├── k8s_clean-ubuntu.sh     # k8s_clean.sh 的前身，仅适用于 Ubuntu（归档保留）
├── fix_reip.sh             # 【IP变更恢复】Master 节点 IP 变更后一键修复（证书+配置）
├── fix_worker_reip.sh      # 【IP变更恢复】Worker 节点上执行：更新 kubelet.conf + registry 信任
├── fix_worker_master_side.sh  # 【IP变更恢复】Master 上执行：更新 flannel 注解 + 等待 Worker 就绪
├── on_restart.sh           # 开机后自动健康检查：检测 IP 变化并调用修复脚本
├── lib/                    # 公共函数库（脚本内部使用）
│   ├── common.sh               # 通用工具函数（OS 检测、日志、版本比较等）
│   ├── preflight-ubuntu.sh     # Ubuntu 预检（apt 依赖、ufw、内核模块等）
│   ├── preflight-kylin.sh      # Kylin 预检（yum 依赖、firewalld、CNI bin 路径修复）
│   ├── container_runtime-ubuntu.sh  # Ubuntu containerd 安装（apt/Docker CE repo）
│   ├── container_runtime-kylin.sh   # Kylin containerd 配置（service 文件、config patch）
│   ├── kubeadm-ubuntu.sh       # Ubuntu k8s 包安装（apt，新旧 pkgs.k8s.io 双通道）
│   ├── kubeadm-kylin.sh        # Kylin k8s 包安装（yum，已安装则跳过）
│   └── init_cluster.sh         # kubeadm init/join 公共逻辑（两个平台共用）
├── registry/               # 私有 Registry 管理（见 registry/README.md）
│   ├── README.md           # Registry 工具集完整文档
│   ├── setup-registry.sh   # 在 k8s 中部署私有 Registry
│   ├── update_images.sh    # 镜像同步：比对 images.conf 与 Registry，支持 add/purge/conf_gen
│   ├── registry-trust.sh   # 节点注入/移除 Registry 信任配置
│   ├── registry_clean.sh   # 清除 Registry 全部资源和数据
│   ├── registry.conf       # Registry 部署配置（存储路径、端口等）
│   └── images.conf         # 镜像路径配置（命名空间定义，供 update_images.sh 使用）
└── SCENARIOS.md            # 典型配置场景（单节点、多节点、清除重置等）
```

**`install.sh` 会根据 `/etc/os-release` 自动检测 OS，并 source 对应的 `-ubuntu` 或 `-kylin` lib 文件。**

---

## 快速开始

```bash
cd setup/kubernets

# 1. 安装 k8s 基础环境（国内/Kylin 环境必须传入 REGISTRY_MIRROR）
sudo REGISTRY_MIRROR=registry.aliyuncs.com/google_containers ./install.sh

# 2. 初始化控制面
sudo REGISTRY_MIRROR=registry.aliyuncs.com/google_containers ./master.sh

# 3. 切换节点算力角色（可选）
sudo ./set-node-mode.sh biren        # BirenTech GPU 节点
# 或
sudo ./set-node-mode.sh cpu          # 纯 CPU 节点

# 4. 部署私有 Registry（可选，见 registry/README.md）
sudo ./registry/setup-registry.sh
```

完整的多节点、清除重置等场景见 [SCENARIOS.md](SCENARIOS.md)。

---

## 脚本说明

### install.sh — 节点基础环境安装

在节点上安装 containerd、kubeadm、kubelet、kubectl，配置内核模块和 sysctl。不初始化集群，只做环境准备。

**支持操作系统：** Ubuntu 20.04 / 22.04 / 24.04，Kylin V10 / V11

**环境变量（均可选）：**

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `K8S_VERSION` | `1.30` | 安装的 k8s 版本，支持 `1.28`、`1.28.5` 等格式 |
| `REGISTRY_MIRROR` | 空 | 镜像加速地址，如 `registry.aliyuncs.com/google_containers`<br>**Kylin/国内环境必填**（registry.k8s.io 不可达） |
| `CONTAINERD_VERSION` | 最新 | 固定 containerd 版本（Ubuntu 专用；Kylin 若已有 containerd 则跳过安装） |
| `CNI_PLUGIN` | `flannel` | CNI 插件：`flannel` / `calico` / `none` |

**用法示例：**

```bash
# 默认安装 k8s 1.30（Ubuntu，网络可达时）
sudo ./install.sh

# 指定版本，使用国内镜像加速（Ubuntu 或 Kylin）
sudo K8S_VERSION=1.28 REGISTRY_MIRROR=registry.aliyuncs.com/google_containers ./install.sh
```

**影响范围：**
- 安装 containerd（Ubuntu：通过 Docker CE apt 源；Kylin：若已安装则仅修补配置）
- 安装 kubeadm / kubelet / kubectl（Ubuntu：apt + hold；Kylin：yum，已安装则跳过）
- 写入 `/etc/modules-load.d/k8s.conf`（overlay、br_netfilter）
- 写入 `/etc/sysctl.d/99-k8s.conf`（bridge-nf、ip_forward）
- Kylin：将 `/usr/libexec/cni/` 下 CNI 插件二进制复制到 `/opt/cni/bin/`
- 备份原 containerd 配置为 `/etc/containerd/config.toml.bak.<timestamp>`

---

### master.sh — 控制面初始化

在已执行 `install.sh` 的节点上执行 `kubeadm init`，安装 CNI 插件，生成 worker 节点 join 命令文件。

**初始化后节点状态：** 带 `control-plane:NoSchedule` 污点，不参与业务调度。使用 `set-node-mode.sh` 修改角色。

**环境变量（均可选）：**

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `K8S_VERSION` | `1.30` | 需与 install.sh 保持一致 |
| `API_SERVER_ADDR` | 自动检测 | 多网卡时必填，指定对外暴露的 IP |
| `POD_CIDR` | `10.244.0.0/16` | Pod 网络段 |
| `SVC_CIDR` | `10.96.0.0/12` | Service 网络段 |
| `CNI_PLUGIN` | `flannel` | `flannel` / `calico` / `none` |
| `REGISTRY_MIRROR` | 空 | 镜像加速地址。若设置且 containerd 配置中 sandbox_image 仍指向 registry.k8s.io，脚本会自动修正 |
| `TOKEN_TTL` | `24h` | join token 有效期，`0` 表示永不过期 |
| `JOIN_FILE` | `/root/k8s-join.sh` | join 命令保存路径 |

**用法示例：**

```bash
# 最简用法（自动检测本机 IP）
sudo ./master.sh

# 国内/Kylin 环境（必须传入 REGISTRY_MIRROR）
sudo REGISTRY_MIRROR=registry.aliyuncs.com/google_containers ./master.sh

# 指定 API Server 地址（多网卡环境）
sudo API_SERVER_ADDR=192.168.1.10 REGISTRY_MIRROR=registry.aliyuncs.com/google_containers ./master.sh
```

**执行后产物：**
- `/etc/kubernetes/admin.conf` — 管理员 kubeconfig
- `~/.kube/config` — 当前用户 kubeconfig（自动配置）
- `/root/k8s-join.sh` — worker 节点 join 命令（`TOKEN_TTL` 有效期内）

---

### join.sh — 工作节点加入集群

在 worker 节点上执行 `kubeadm join`，支持三种算力角色。

**用法：**

```bash
sudo ./join.sh <mode> [选项]
# mode: worker | cpu | biren
```

**三种模式：**

| 模式 | 效果 |
|------|------|
| `worker` | 标准工作节点，参与 CPU 调度（默认） |
| `cpu` | 同 worker，明确标注 CPU 角色 |
| `biren` | GPU 节点：导入 device plugin 镜像、打 GPU 标签、部署 DaemonSet |

**Join 参数来源（优先级从高到低）：**
1. `JOIN_FILE` 文件（默认 `/root/k8s-join.sh`，由 master.sh 生成）
2. 环境变量：`MASTER_IP` + `JOIN_TOKEN` + `CA_CERT_HASH`
3. 交互式输入

**环境变量（均可选）：**

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `JOIN_FILE` | `/root/k8s-join.sh` | join 命令文件 |
| `MASTER_IP` | 空 | Master IP |
| `MASTER_PORT` | `6443` | API Server 端口 |
| `JOIN_TOKEN` | 空 | kubeadm token |
| `CA_CERT_HASH` | 空 | CA 哈希（`sha256:...`） |
| `NODE_NAME` | 本机 hostname | 覆盖节点名 |
| `NODE_LABELS` | 空 | 附加标签，逗号分隔，如 `zone=cn-east` |
| `NODE_TAINTS` | 空 | 附加 taint，逗号分隔 |
| `PLUGIN_DIR` | `packages/biren/` | biren 模式：device plugin 文件目录（需含 `*.tar` 镜像和 `biren-device-plugin.yaml`） |

**用法示例：**

```bash
# 标准 CPU worker（读取 /root/k8s-join.sh）
sudo ./join.sh worker

# BirenTech GPU worker
sudo ./join.sh biren
```

---

### set-node-mode.sh — 节点算力角色切换

切换**已加入集群**的节点的算力角色，支持批量操作多个节点。

**用法：**

```bash
sudo ./set-node-mode.sh <mode> [节点名1,节点名2,...]
```

**三种模式：**

| 模式 | 效果 |
|------|------|
| `cpu` | 去除 control-plane 污点，节点以纯 CPU 算力参与调度 |
| `biren` | 去除污点 + 打 `birentech.com=gpu` 标签 + 部署 device plugin DaemonSet |
| `none` | 恢复 `control-plane:NoSchedule` 污点，退出调度池 |

**用法示例：**

```bash
sudo ./set-node-mode.sh biren               # 本机切换为 GPU 节点
sudo ./set-node-mode.sh cpu                 # 本机切换为 CPU 节点
sudo ./set-node-mode.sh none                # 恢复隔离
sudo ./set-node-mode.sh biren node1,node2   # 批量设置
```

**BirenTech device plugin 准备：**

`packages/biren/` 目录需包含：
- `*.tar` — 设备插件镜像（从发布包中的 `k8s_device_plugin_*.tar.gz` 解压获取内层 tar）
- `biren-device-plugin.yaml` — DaemonSet 配置

该目录已被 `.gitignore` 排除（含大文件），使用前需从发布包手动填充：
```bash
gunzip -c /data/release/<version>/images/k8s_device_plugin_*.tar.gz \
    | tar -xf - -C packages/biren/
# 或直接解压 .tar.gz（外层为 wrapper，内含同名 .tar）
```

**与 join.sh biren 的区别：**
- `join.sh biren` — 用于**首次**加入集群时设置为 GPU 节点
- `set-node-mode.sh biren` — 用于**已加入**集群的节点切换角色（包括 master 节点）

---

### k8s_clean.sh — 清除 k8s 环境

将系统重置到 k8s 安装之前的状态。自动检测 OS（Ubuntu/Kylin），执行前打印完整操作摘要，**需用户确认后再执行**。

**用法：**

```bash
sudo ./k8s_clean.sh
```

**清除内容：**

1. `kubeadm reset -f` — 清理控制面/节点状态（Kylin 自动指定 `--cri-socket`）
2. 卸载 k8s 包（Ubuntu：`apt purge kubeadm kubelet kubectl kubernetes-cni`；Kylin：`yum remove kubeadm kubelet kubectl`）
3. 移除 k8s 包管理器源和 GPG 密钥
4. 删除目录：`/etc/kubernetes`、`/var/lib/kubelet`、`/var/lib/etcd`、`/opt/cni`、`/var/lib/cni`、`/etc/cni/net.d`
5. 删除用户 `~/.kube` 配置
6. 从备份恢复 containerd 配置（最新 `config.toml.bak.*`）
7. 删除 k8s 写入的 `/etc/sysctl.d/99-k8s.conf` 和 `/etc/modules-load.d/k8s.conf`
8. 清理残留 CNI 接口和 iptables 规则
9. 重启 containerd

> `/etc/cni/net.d/` 会被一并清除，避免旧版 Calico/Flannel 配置残留干扰下次部署。

**不影响：** containerd 服务本身、Docker、BirenTech runtime、`/data/registry` 存储、原有应用数据

---

## Registry 集成

k8s 集群本身**不依赖**私有 Registry 即可正常运行。Registry 是可选组件，用于在内网分发推理镜像。

集群与 Registry 之间的关联点：

| 时机 | 操作 | 说明 |
|------|------|------|
| 集群就绪后 | 部署 Registry | `registry/setup-registry.sh` 将 Registry 以 NodePort 形式运行在集群中 |
| Worker 节点加入后 | 下发信任配置 | `registry/registry-trust.sh apply` 让 containerd 信任 HTTP Registry |
| 清除集群前 | 先清除 Registry | 若 Registry 运行在集群中，需先执行 `registry/registry_clean.sh` 再执行 `k8s_clean.sh` |

Registry 工具集的完整说明见 [registry/README.md](registry/README.md)。

---

## 节点 IP 变更恢复

当 Master 节点的 IP 地址发生变化后（如 DHCP 重新分配、网卡更换），k8s 各组件因 TLS 证书和 kubeconfig 中硬编码了旧 IP 而无法启动。此工具集提供两个脚本处理此场景。

### fix_reip.sh — 一次性 IP 变更修复

```bash
sudo bash setup/kubernets/fix_reip.sh <OLD_IP> <NEW_IP>
# 示例：
sudo bash setup/kubernets/fix_reip.sh 10.49.4.248 10.50.36.126
```

执行内容：
1. 生成包含新 IP 的 kubeadm 配置
2. 备份旧证书到 `/etc/kubernetes/pki-backup-<timestamp>/`
3. 删除旧 leaf 证书（保留 CA），使用 `kubeadm init phase certs` 重新生成含新 IP SAN 的证书
4. 用 `sed` 替换 `etcd.yaml`、`kube-apiserver.yaml` manifest 中的旧 IP
5. 更新所有 kubeconfig 文件（admin、controller-manager、scheduler、kubelet、super-admin、`~/.kube/config`）
6. 重启 kubelet

> **注意：** 运行后还需手动重启 `kube-controller-manager` 和 `kube-scheduler` 的容器（它们在启动时缓存了旧 IP，仅删除 Pod 对象不够）：
> ```bash
> sudo mv /etc/kubernetes/manifests/kube-controller-manager.yaml /tmp/kcm.yaml && sleep 5 && sudo mv /tmp/kcm.yaml /etc/kubernetes/manifests/
> sudo mv /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/ks.yaml && sleep 5 && sudo mv /tmp/ks.yaml /etc/kubernetes/manifests/
> ```
> 同时更新 kube-proxy ConfigMap 中的 server 地址：
> ```bash
> kubectl get cm kube-proxy -n kube-system -o json | \
>   python3 -c "import json,sys; d=json.load(sys.stdin); d['data']['kubeconfig.conf']=d['data']['kubeconfig.conf'].replace('https://<OLD_IP>:6443','https://<NEW_IP>:6443'); print(json.dumps(d))" | \
>   kubectl apply -f -
> kubectl rollout restart ds/kube-proxy -n kube-system
> ```

### on_restart.sh — 开机后自动健康检查与恢复

```bash
sudo bash setup/kubernets/on_restart.sh
```

该脚本会：
1. 检测当前节点 IP 与 k8s 配置的 IP 是否一致
2. 若不一致，自动调用 `fix_reip.sh`
3. 等待 API Server 就绪
4. 重启使用了旧 IP 的 static pod 容器（controller-manager、scheduler）
5. 更新 kube-proxy ConfigMap（若需要）
6. 验证 Registry 是否可访问

**一键注册为 systemd 服务（开机自动运行）：**

```bash
sudo tee /etc/systemd/system/k8s-on-restart.service > /dev/null << 'EOF'
[Unit]
Description=K8s post-boot recovery and health check
After=network-online.target kubelet.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 30
ExecStart=/bin/bash /home/zanedong/br-release/setup/kubernets/on_restart.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable k8s-on-restart.service
```

### Worker 节点 IP 变更修复

Worker 节点 IP 变更（或 Master IP 变更导致 Worker 无法连接）时，需分两步操作。

**第一步：在 worker 节点上执行**

```bash
# 拷贝脚本到 worker 节点后执行，或直接 SSH 进去运行
sudo bash fix_worker_reip.sh <OLD_MASTER_IP> <NEW_MASTER_IP>

# 示例（master IP 从 10.49.4.248 变为 10.50.36.126）：
sudo bash fix_worker_reip.sh 10.49.4.248 10.50.36.126
```

执行内容：
1. 备份并更新 `/etc/kubernetes/kubelet.conf`（master 的 API server 地址）
2. 更新 containerd 的 registry 信任配置（`/etc/containerd/certs.d/`）
3. 更新 `/etc/docker/daemon.json` 的 `insecure-registries`（如有 docker）
4. 重启 kubelet
5. 打印 master 侧需要执行的命令

> 若 worker 自身的 IP 也变化，kubelet 重启后会自动向 API server 上报新 IP，无需额外配置。

**第二步：在 master 节点上执行（等 worker 重连后）**

```bash
# WORKER_HOSTNAME：worker 节点的 hostname（kubectl get nodes 中的名称）
# NEW_WORKER_IP：worker 节点的新 IP
bash fix_worker_master_side.sh <WORKER_HOSTNAME> <NEW_WORKER_IP>

# 示例：
bash fix_worker_master_side.sh pj-3f-server002 10.50.36.200
```

执行内容：
1. 等待 worker 节点 `Ready`（最多 120s）
2. 更新 flannel 的 `public-ip` 注解（影响跨节点 Pod 网络的 VXLAN 隧道）
3. 重启 worker 上的 flannel pod（使其重新建立 VXLAN peer）
4. 打印节点和 Pod 状态汇总

**完整流程示意：**

```
Worker 节点（SSH）                         Master 节点
─────────────────────────────────          ──────────────────────────────────
sudo bash fix_worker_reip.sh \
    10.49.4.248 10.50.36.126
                                    →      bash fix_worker_master_side.sh \
                                               pj-3f-server002 10.50.36.200
```

---

## 注意事项

- 所有 `sudo` 脚本需要 root 权限
- **国内/Kylin 环境**：`install.sh` 和 `master.sh` 均需传入 `REGISTRY_MIRROR=registry.aliyuncs.com/google_containers`，否则 containerd sandbox_image 和 kubeadm 镜像拉取会因 `registry.k8s.io` 不可达而失败
- `join.sh` 和 `set-node-mode.sh` 使用 `kubelet.conf` 操作本机节点标签，不依赖 admin.conf
- BirenTech device plugin 的 `brml` volume 会自动修正 `libbiren-ml.so.1` 的绝对软链接路径
- Kylin 上 containerd v2 的插件路径为 `io.containerd.cri.v1.runtime`（不同于 v1 的 `io.containerd.grpc.v1.cri`）
- **Kylin 特有**：如果主机同时安装了 `cri-dockerd`，kubeadm 命令会遇到"多 CRI 端点"报错；相关脚本已内置 `--cri-socket unix:///run/containerd/containerd.sock` 参数规避
- `k8s_clean.sh` 执行后 containerd 备份文件（`config.toml.bak.*`）会被消耗，再次清除前需重新执行 `install.sh` 生成新备份
