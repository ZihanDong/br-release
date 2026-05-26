# 私有 Registry 工具集

在 k8s 集群中部署、管理和维护私有镜像仓库（`registry:2`）的工具集。

**前提依赖：** k8s 集群已就绪（`master.sh` 执行完成，`kubectl get nodes` 显示 Ready）

---

## 脚本说明

### setup-registry.sh — 部署私有 Registry

在 k8s 集群中部署 `registry:2` 镜像仓库（NodePort 方式），配置本机信任并生成信任配置文件。

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
1. 拉取 `registry:2` 镜像（已存在则跳过；docker.io 不可达时自动尝试 `docker.m.daocloud.io` 等备用镜像源）
2. 准备存储目录
3. 在 k8s 中部署 Deployment + NodePort Service（自动启用 `REGISTRY_STORAGE_DELETE_ENABLED=true`）
4. 等待 Registry 就绪
5. 配置本机 containerd 信任该 Registry，生成 `registry-trust.conf`

镜像导入和推送请使用 `update_images.sh`。

---

### update_images.sh — 镜像同步管理

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

### registry-trust.sh — Registry 信任管理

向本机或远程节点注入/移除 containerd Registry 信任配置（写入 `certs.d`，**无需重启 containerd**）。

**用法：**

```bash
sudo ./registry/registry-trust.sh apply   [--config FILE] [节点,...]
sudo ./registry/registry-trust.sh remove  [--config FILE] [节点,...]
      ./registry/registry-trust.sh list   [节点,...]
```

**选项：**

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `--config FILE` | `registry-trust.conf` | 信任配置文件（由 `setup-registry.sh` 生成） |
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

# 移除指定 Registry 的信任
sudo ./registry/registry-trust.sh remove --config registry-trust.conf
```

---

### registry_clean.sh — 清除 Registry

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

## 典型使用流程

### 首次部署（集群就绪后）

```bash
cd setup/kubernets

# 1. 部署 Registry（读取 registry/registry.conf）
sudo ./registry/setup-registry.sh

# 2. 编辑 images.conf，配置需要导入的镜像路径
vi ./registry/images.conf

# 3. 导入并推送镜像到 Registry
sudo ./registry/update_images.sh add

# 4. 向 Worker 节点下发信任配置（多节点集群）
sudo ./registry/registry-trust.sh apply worker01,worker02
```

### 后续镜像维护

```bash
# 查看 Registry 当前内容
curl http://<master-ip>:32000/v2/_catalog

# 追加新镜像（只推送 images.conf 中新增的部分）
sudo ./registry/update_images.sh add

# 清理 images.conf 已移除但 Registry 中仍存在的镜像
sudo ./registry/update_images.sh purge
```

### 完整清除

```bash
# 清除 Registry 全部资源和数据（会请求确认）
sudo ./registry/registry_clean.sh
```

---

## 注意事项

- Registry 信任配置写入 `certs.d` 后 containerd 动态读取，**无需重启 containerd**
- `docker.io` 在国内环境不可达时，`setup-registry.sh` 会自动依次尝试 `docker.m.daocloud.io`、`hub.uuuadc.cn`、`docker.1panel.live` 等镜像源
- `update_images.sh add/purge` 均需用户二次确认，不会静默修改 Registry 内容
- `registry_clean.sh` 会删除 `REGISTRY_STORAGE` 目录下的全部数据，执行前请确认备份
- Worker 节点拉取 Registry 中的镜像前必须先执行 `registry-trust.sh apply`，否则 containerd 会因不信任 HTTP 而拒绝拉取
