# Kubernetes 自动化部署工具集

面向 Ubuntu 20.04/22.04/24.04 及 Kylin V10/V11 的 Kubernetes 一键部署、节点管理、私有 Registry 和清理工具。支持 k8s ≥ v1.19，当前已在 k8s v1.30 + containerd v2 环境验证。

---

## 目录结构

```
setup/kubernets/
├── install.sh          # 节点基础环境安装（containerd + k8s 包）
├── master.sh           # 控制面初始化（kubeadm init + CNI）
├── join.sh             # 工作节点加入集群（支持 CPU / BirenTech GPU 模式）
├── set-node-mode.sh    # 已加入节点的算力角色切换
├── k8s_clean.sh        # 清除 k8s 全部组件，恢复安装前状态
├── lib/                # 公共函数库（脚本内部使用）
│   ├── common.sh
│   ├── preflight.sh
│   ├── container_runtime.sh
│   ├── kubeadm.sh
│   └── init_cluster.sh
└── registry/           # 私有 Registry 管理
    ├── setup-registry.sh   # 在 k8s 中部署私有 Registry
    ├── update_images.sh    # 镜像同步：比对 images.conf 与 Registry，支持 add/purge/conf_gen
    ├── registry-trust.sh   # 节点注入/移除 Registry 信任配置
    ├── registry_clean.sh   # 清除 Registry 全部资源和数据
    ├── registry.conf       # Registry 部署配置（存储路径、端口等）
    └── images.conf         # 镜像路径配置（命名空间定义，供 update_images.sh 使用）
```

---

## 快速开始

### 典型流程：单节点 Master + BirenTech GPU

```bash
# 1. 安装 k8s 基础环境
sudo ./install.sh

# 2. 初始化控制面（初始为隔离状态）
sudo ./master.sh

# 3. 将本机同时作为 BirenTech GPU 算力节点
sudo ./set-node-mode.sh biren

# 4. 部署私有 Registry
sudo ./registry/setup-registry.sh

# 5. 导入并推送镜像（编辑 registry/images.conf 后执行）
sudo ./registry/update_images.sh add

# 6. 向其他节点下发 Registry 信任配置
sudo ./registry/registry-trust.sh apply worker01,worker02
```

---

## 脚本说明

### install.sh — 节点基础环境安装

在节点上安装 containerd、kubeadm、kubelet、kubectl，配置内核模块和 sysctl。不初始化集群，只做环境准备。

**支持操作系统：** Ubuntu 20.04 / 22.04 / 24.04，Kylin V10 / V11

**环境变量（均可选）：**

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `K8S_VERSION` | `1.30` | 安装的 k8s 版本，支持 `1.28`、`1.28.5` 等格式 |
| `REGISTRY_MIRROR` | 空 | 镜像加速地址，如 `registry.aliyuncs.com/google_containers` |
| `CONTAINERD_VERSION` | 最新 | 固定 containerd 版本 |
| `CNI_PLUGIN` | `flannel` | CNI 插件：`flannel` / `calico` / `none` |

**用法示例：**

```bash
# 默认安装 k8s 1.30
sudo ./install.sh

# 指定版本，使用国内镜像加速
sudo K8S_VERSION=1.28 REGISTRY_MIRROR=registry.aliyuncs.com/google_containers ./install.sh
```

**影响范围：**
- 安装 containerd（若已存在则仅修补配置）
- 安装 kubeadm / kubelet / kubectl（包版本锁定）
- 写入 `/etc/modules-load.d/k8s.conf`（overlay、br_netfilter）
- 写入 `/etc/sysctl.d/99-k8s.conf`（bridge-nf、ip_forward）
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
| `TOKEN_TTL` | `24h` | join token 有效期，`0` 表示永不过期 |
| `JOIN_FILE` | `/root/k8s-join.sh` | join 命令保存路径 |

**用法示例：**

```bash
# 最简用法（自动检测本机 IP）
sudo ./master.sh

# 指定 API Server 地址（多网卡环境）
sudo API_SERVER_ADDR=192.168.1.10 ./master.sh

# 国内环境 + Calico CNI
sudo REGISTRY_MIRROR=registry.aliyuncs.com/google_containers \
     CNI_PLUGIN=calico ./master.sh
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

# 通过环境变量传入 join 参数
sudo MASTER_IP=192.168.1.10 JOIN_TOKEN=abc.xyz \
     CA_CERT_HASH=sha256:xxx ./join.sh cpu

# BirenTech GPU worker
sudo ./join.sh biren

# 指定 device plugin 目录（非默认位置）
sudo PLUGIN_DIR=/path/to/plugin-dir ./join.sh biren
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
# 本机切换为 CPU 节点
sudo ./set-node-mode.sh cpu

# 本机切换为 BirenTech GPU 节点
sudo ./set-node-mode.sh biren

# 恢复隔离（退出调度）
sudo ./set-node-mode.sh none

# 批量设置多节点
sudo ./set-node-mode.sh biren node1,node2,node3

# 指定 device plugin 目录（非默认位置）
sudo PLUGIN_DIR=/path/to/plugin-dir ./set-node-mode.sh biren
```

**与 join.sh biren 的区别：**
- `join.sh biren` — 用于**首次**加入集群时设置为 GPU 节点
- `set-node-mode.sh biren` — 用于**已加入**集群的节点切换角色（包括 master 节点）

---

### k8s_clean.sh — 清除 k8s 环境

将系统重置到 k8s 安装之前的状态。执行前打印完整操作摘要，**需用户确认后再执行**。

**用法：**

```bash
sudo ./k8s_clean.sh
```

**清除内容：**

1. `kubeadm reset -f` — 清理控制面/节点状态
2. 卸载 `kubeadm / kubelet / kubectl / kubernetes-cni` 包（包括 hold 状态）
3. 移除 k8s apt 源（`/etc/apt/sources.list.d/kubernetes.list`）和 GPG 密钥
4. 删除目录：`/etc/kubernetes`、`/var/lib/kubelet`、`/var/lib/etcd`、`/opt/cni`、`/var/lib/cni`
5. 删除用户 `~/.kube` 配置
6. 从备份恢复 containerd 配置（最新 `config.toml.bak.*`）
7. 删除 k8s 写入的 `/etc/sysctl.d/99-k8s.conf` 和 `/etc/modules-load.d/k8s.conf`
8. 清理残留 CNI 接口（`cni0`、`flannel.1` 等）和 iptables 规则
9. 重启 containerd

**不影响：** containerd 服务本身、Docker、BirenTech runtime、`/data/registry` 存储、原有应用数据

---

## Registry 子工具

### registry/setup-registry.sh — 部署私有 Registry

在 k8s 集群中部署 `registry:2` 镜像仓库（NodePort 方式），配置本机信任并生成信任配置文件。

**前提：** 集群已就绪（`master.sh` 执行完成）

**用法：**

```bash
sudo ./registry/setup-registry.sh [配置文件路径]
# 配置文件默认为同目录下的 registry.conf
```

**配置文件（registry.conf）格式：**

```ini
REGISTRY_STORAGE=/data/registry     # 镜像存储目录
REGISTRY_PORT=32000                  # NodePort 端口
REGISTRY_HTTP=true                   # HTTP 模式（内网推荐）
REGISTRY_K8S_NAMESPACE=kube-system   # 部署命名空间
```

**执行流程：**
1. 拉取 `registry:2` 镜像（已存在则跳过）
2. 准备存储目录
3. 在 k8s 中部署 Deployment + NodePort Service（自动启用 `REGISTRY_STORAGE_DELETE_ENABLED=true`）
4. 等待 Registry 就绪
5. 配置本机 containerd 信任该 Registry，生成 `registry-trust.conf`

镜像导入和推送请使用 `update_images.sh`（见下节）。

---

### registry/update_images.sh — 镜像同步管理

比对 `images.conf` 中定义的镜像与 Registry 现有镜像，支持三种同步模式。添加/删除操作均需用户确认。

**用法：**

```bash
sudo ./registry/update_images.sh [add|purge|conf_gen] [选项]
```

**三种模式：**

| 模式 | 说明 |
|------|------|
| `add`（默认） | 找出 images.conf 中有但 Registry 中缺失的镜像，确认后导入并推送 |
| `purge` | 找出 Registry 中有但 images.conf 未定义的多余镜像，确认后删除并运行 GC |
| `conf_gen` | 根据 Registry 当前镜像生成快照配置文件（不覆盖原有文件） |

**选项：**

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `--config FILE` | `./registry.conf` | Registry 部署配置文件 |
| `--images FILE` | `./images.conf` | 镜像路径配置文件 |
| `--registry ADDR` | 自动检测 | 手动指定 Registry 地址（如 `192.168.1.10:32000`） |

**镜像配置文件（images.conf）格式：**

```ini
# 每个 [namespace.<name>] 节定义一个命名空间，节内每行为路径（文件或目录）
[namespace.base]
/data/release/images/base-image.tar

[namespace.infer]
/data/release/images/             # 目录：递归扫描所有 .tar/.tar.gz

[namespace.k8s]
/data/release/k8s/plugin.tar.gz
```

**用法示例：**

```bash
# 添加缺失镜像（会打印 diff 并请求确认）
sudo ./registry/update_images.sh add

# 删除多余镜像并运行 GC（会打印 diff 并请求确认）
sudo ./registry/update_images.sh purge

# 生成当前 Registry 镜像快照（不修改任何文件）
sudo ./registry/update_images.sh conf_gen

# 手动指定 Registry 地址
sudo ./registry/update_images.sh add --registry 192.168.1.10:32000
```

**Registry 地址解析优先级：**
1. `--registry` 命令行参数
2. `registry-trust.conf`（由 `setup-registry.sh` 生成）
3. 集群 API Server 自动检测

**镜像访问格式：**`<registry-addr>/<namespace>/<image>:<tag>`

```bash
# 查看所有仓库
curl http://<master-ip>:32000/v2/_catalog

# 查看某仓库的 tag
curl http://<master-ip>:32000/v2/<namespace>/<image>/tags/list

# 在 Pod 中使用
image: <master-ip>:32000/infer/birensupa-smartinfer-vllm:26.04.beta1-py310-pt2.8.0-br1xx
```

---

### registry/registry-trust.sh — Registry 信任管理

向本机或远程节点注入/移除 containerd Registry 信任配置（写入 `certs.d`，**无需重启 containerd**）。

**用法：**

```bash
# 子命令
sudo ./registry/registry-trust.sh apply   [--config FILE] [节点,...]
sudo ./registry/registry-trust.sh remove  [--config FILE] [节点,...]
      ./registry/registry-trust.sh list   [节点,...]
```

**选项：**

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `--config FILE` | `registry-trust.conf` | 信任配置文件 |
| `--ssh-user USER` | `root` | SSH 登录用户（远程节点） |
| `--ssh-key FILE` | 系统默认 | SSH 私钥（远程节点） |

**用法示例：**

```bash
# 注入信任到本机
sudo ./registry/registry-trust.sh apply

# 批量注入到远程节点
sudo ./registry/registry-trust.sh apply worker01,worker02

# 指定 SSH 用户和密钥
sudo ./registry/registry-trust.sh apply --ssh-user admin --ssh-key ~/.ssh/id_rsa worker01

# 查看本机生效的所有信任配置
./registry/registry-trust.sh list

# 列出当前生效配置（不执行删除）
./registry/registry-trust.sh remove

# 移除指定 Registry 的信任
sudo ./registry/registry-trust.sh remove --config registry-trust.conf
```

---

### registry/registry_clean.sh — 清除 Registry

完全清除私有 Registry 的所有配置和数据。执行前打印操作摘要，**需用户确认后再执行**。

**用法：**

```bash
sudo ./registry/registry_clean.sh [配置文件路径]
```

**清除内容：**

1. 删除 k8s Deployment/registry 和 Service/registry
2. 移除本机 containerd 信任配置（`/etc/containerd/certs.d/<addr>/`）
3. 删除 Registry 存储目录（`REGISTRY_STORAGE` 指定的路径）
4. 从 containerd 删除 `registry:2` 镜像
5. 删除生成的 `registry-trust.conf` 文件

**不影响：** k8s 集群本身、其他 Deployment/Service、containerd 主配置、BirenTech runtime

---

## 典型场景

### 场景一：全新单节点集群（Master 兼 GPU 节点）

```bash
cd setup/kubernets

# 安装
sudo ./install.sh

# 初始化控制面
sudo ./master.sh

# 切换为 BirenTech GPU 算力节点
sudo ./set-node-mode.sh biren

# 部署私有 Registry
sudo ./registry/setup-registry.sh

# 编辑 images.conf 后导入镜像
# vi ./registry/images.conf
sudo ./registry/update_images.sh add

# 验证
kubectl get nodes -o wide
kubectl get pods -A
curl http://$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}'):32000/v2/_catalog
```

### 场景二：Master + Worker 多节点集群

```bash
# === 在 Master 节点执行 ===
sudo ./install.sh
sudo ./master.sh                      # 生成 /root/k8s-join.sh

# 将 join 文件分发到 Worker 节点
scp /root/k8s-join.sh worker01:/root/k8s-join.sh

# === 在 Worker 节点执行 ===
sudo ./install.sh
sudo ./join.sh biren                  # 以 GPU 节点加入

# === 在 Master 节点执行（部署 Registry，推送镜像，分发信任）===
sudo ./registry/setup-registry.sh
# vi ./registry/images.conf
sudo ./registry/update_images.sh add
sudo ./registry/registry-trust.sh apply worker01,worker02
```

### 场景三：节点角色切换

```bash
# Master 节点参与 CPU 调度
sudo ./set-node-mode.sh cpu

# 切换为 GPU 节点
sudo ./set-node-mode.sh biren

# 恢复隔离（仅运行系统组件）
sudo ./set-node-mode.sh none

# 批量切换多个 worker 节点为 GPU 节点
sudo ./set-node-mode.sh biren worker01,worker02
```

### 场景四：完整清除并重置

```bash
# 先清除 Registry（读取 registry.conf 自动识别要删除的内容）
sudo ./registry/registry_clean.sh

# 再清除 k8s（打印摘要 → 确认 → 执行）
sudo ./k8s_clean.sh

# 重新初始化
sudo ./install.sh && sudo ./master.sh
```

---

## 注意事项

- 所有 `sudo` 脚本需要 root 权限
- `join.sh` 和 `set-node-mode.sh` 使用 `kubelet.conf` 操作本机节点标签，不依赖 admin.conf
- `join.sh biren` 的 DaemonSet 部署需要 admin.conf，若不存在则跳过（假设 master 已通过 `set-node-mode.sh biren` 首次部署）
- BirenTech device plugin 的 `brml` volume 会自动修正 `libbiren-ml.so.1` 的绝对软链接路径
- containerd v2 的插件路径为 `io.containerd.cri.v1.runtime`（不同于 v1 的 `io.containerd.grpc.v1.cri`）
- Registry 信任配置写入 `certs.d` 后 containerd 动态读取，**无需重启**
- `k8s_clean.sh` 执行后 containerd 备份文件（`config.toml.bak.*`）会被消耗，再次清除前需重新执行 `install.sh` 生成新备份
