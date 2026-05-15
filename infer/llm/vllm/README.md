# vLLM Server — BirenTech GPU 部署指南

本目录提供两种方式在 BirenTech GPU 节点上拉起 vLLM OpenAI 兼容推理服务：

| 方式 | 入口脚本 | 适用场景 |
|------|---------|---------|
| **Docker** | `start_vllm_docker.sh` | 快速调试、单次运行 |
| **Kubernetes** | `start_vllm_k8s.sh` | 生产部署、持久运行 |

两个脚本都通过同一个容器内脚本 `start_vllm_server.sh` 拉起 vLLM 服务，参数来自共享的 `configs/*.conf` 配置文件。

---

## 架构说明

```
外部（宿主机）                          容器内
┌─────────────────────┐               ┌──────────────────────────────┐
│ start_vllm_docker.sh│  docker run   │ biren_entrypoint.sh          │
│ ┌ GPU 选择           │ ──────────►  │   └─ exec args...            │
│ └ 容器生命周期管理   │               │       bash start_vllm_server.sh│
└─────────────────────┘               │         └─ exec python3 vllm │
                                      └──────────────────────────────┘
┌─────────────────────┐               ┌──────────────────────────────┐
│ start_vllm_k8s.sh   │  kubectl      │ biren_entrypoint.sh          │
│ ┌ 节点探测           │  apply ──►   │   └─ exec args...            │
│ └ YAML 动态生成      │               │       bash start_vllm_server.sh│
└─────────────────────┘               │         └─ exec python3 vllm │
                                      └──────────────────────────────┘
```

`start_vllm_server.sh` 挂载到容器中（Docker 通过 `/home` bind-mount，k8s 通过 hostPath volume），
由 BirenTech 镜像的 ENTRYPOINT（`biren_entrypoint.sh`）设置好 `LD_LIBRARY_PATH` 后调用。

---

## 目录结构

```
infer/llm/vllm/
├── start_vllm_server.sh      # 容器内脚本：加载 conf → 查 registry → exec vllm
├── start_vllm_docker.sh      # Docker 外层：GPU 选择 + 容器启动 + 健康轮询
├── start_vllm_k8s.sh         # k8s 外层：节点探测 + 动态生成 YAML + 等待 Ready
├── model_registry.conf       # 模型库：本地路径 + HuggingFace/ModelScope ID
├── configs/
│   ├── bge-m3.conf           # bge-m3 运行参数（含 k8s_nodeport=30800）
│   └── qwen3-32b.conf        # Qwen3-32B 运行参数（含 k8s_nodeport=30801）
└── logs/                     # Docker 启动日志（自动生成）
```

---

## 前置条件

| 依赖 | 说明 |
|------|------|
| BirenTech GPU 驱动 | `/dev/biren/card_*` 设备文件存在 |
| `brsmi` | 用于查询 GPU 空闲状态（Docker 方式） |
| Docker | 需要 `sudo docker` 权限（Docker 方式） |
| `kubectl` | 需有 `~/.kube/config`（k8s 方式） |
| 模型权重 | 存放于 host 的 `/data/models/` 目录下 |

---

## 一、Docker 方式

### 1.1 启动命令

```bash
cd infer/llm/vllm
sudo bash start_vllm_docker.sh <config>
```

`<config>` 支持三种形式：

```bash
sudo bash start_vllm_docker.sh bge-m3                    # 裸模型名（自动找 configs/bge-m3.conf）
sudo bash start_vllm_docker.sh configs/qwen3-32b.conf   # 相对路径
sudo bash start_vllm_docker.sh /abs/path/to/custom.conf # 绝对路径
```

### 1.2 脚本行为

`start_vllm_docker.sh`（宿主机）按以下顺序执行：

1. 加载配置文件，查找模型权重（如缺失则询问下载）
2. 用 `brsmi` 查询空闲 GPU，选取 `tp × pp` 张
3. 启动 Docker 容器，仅映射所需的 `/dev/biren/card_N` 设备
4. 挂载 `/home:/home`（使 `start_vllm_server.sh` 在容器内可见）
5. 容器内由 ENTRYPOINT → `start_vllm_server.sh` → `exec python3 -m vllm...` 完成启动
6. 宿主机轮询 `/health` 端点，最多等待 600 秒
7. 打印 curl 测试命令

### 1.3 容器管理

容器名为 `vllm_<model_weights>`：

```bash
# 查看日志
sudo docker logs -f vllm_bge-m3

# 停止 / 删除
sudo docker stop vllm_bge-m3
sudo docker rm   vllm_bge-m3
```

日志同时写入 `logs/vllm_<model>_<timestamp>.log`。

### 1.4 curl 测试

**bge-m3（嵌入）：**
```bash
curl -s http://127.0.0.1:28800/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model": "/data/models/BAAI/bge-m3", "input": "Hello, world!"}' \
  | python3 -m json.tool
```

**qwen3-32b（对话）：**
```bash
curl -s http://127.0.0.1:28800/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "Qwen/Qwen3-32B", "messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 64}' \
  | python3 -m json.tool
```

> **注意：** Docker 方式两个模型都使用端口 28800，不能同时运行。若需同时运行，修改其中一个 conf 的 `port` 字段。

---

## 二、Kubernetes 方式

### 2.1 前置：集群环境要求

| 组件 | 版本/状态 |
|------|---------|
| k8s | v1.30+，节点处于 `biren` 模式 |
| containerd | v2.x，已注册 `biren` RuntimeClass（见下） |
| biren device plugin | DaemonSet 运行中（`biren-gpu` namespace） |
| 私有 Registry | `10.49.4.248:32000`（镜像已导入） |

**RuntimeClass 注册**（首次部署时一次性操作，已完成）：

1. 在 `/etc/containerd/config.toml` 末尾追加 biren runtime handler（`cri.v1.runtime` 节点下）
2. `systemctl restart containerd`
3. 创建 `RuntimeClass` 资源（`handler: biren`）

如在新集群部署，参考 `skills/vllm.md` 中的"RuntimeClass 注册"章节。

### 2.2 启动命令

```bash
cd infer/llm/vllm
bash start_vllm_k8s.sh <config>
```

`<config>` 格式与 Docker 方式相同。

### 2.3 脚本行为

`start_vllm_k8s.sh`（宿主机）按以下顺序执行：

1. 加载配置文件，查找模型权重（如缺失则询问下载）
2. 自动探测具有足够 `birentech.com/gpu` 资源的节点（或使用 `k8s_node_name` 指定）
3. 动态生成 Kubernetes YAML（Namespace + Deployment + Service）并 `kubectl apply`
   - Deployment 的 `args` 为：`[bash, start_vllm_server.sh, <config>]`
   - 通过 hostPath volume 将脚本目录挂载到容器内（路径与宿主机一致）
4. 等待 Pod Ready（超时时间根据 GPU 数量自动计算）
5. 打印 curl 测试命令

### 2.4 典型部署

```bash
# 启动 bge-m3（embedding，1 GPU，NodePort 30800）
bash start_vllm_k8s.sh bge-m3

# 启动 qwen3-32b（chat，2 GPU，NodePort 30801）
bash start_vllm_k8s.sh qwen3-32b

# 两个模型可同时运行（使用不同 NodePort，互不冲突）
```

### 2.5 查看状态

```bash
kubectl get pods -n vllm
kubectl get svc -n vllm

kubectl logs -n vllm -l app=vllm-bge-m3 -f
kubectl logs -n vllm -l app=vllm-qwen3-32b -f
```

### 2.6 端口说明

| 模型 | containerPort | NodePort | 访问地址 |
|------|--------------|----------|---------|
| bge-m3 | 28800 | **30800** | `http://<node-ip>:30800` |
| qwen3-32b | 28800 | **30801** | `http://<node-ip>:30801` |

### 2.7 curl 测试

> 若系统配置了 HTTP 代理（`http_proxy` 环境变量），需添加 `--noproxy "*"` 参数。

**bge-m3：**
```bash
curl -s --noproxy "*" http://10.49.4.248:30800/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model": "/data/models/BAAI/bge-m3", "input": "Hello, world!"}' \
  | python3 -m json.tool
```

**qwen3-32b：**
```bash
curl -s --noproxy "*" http://10.49.4.248:30801/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "Qwen/Qwen3-32B", "messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 64}' \
  | python3 -m json.tool
```

### 2.8 清理

```bash
kubectl delete deployment/vllm-bge-m3 service/vllm-bge-m3 -n vllm
kubectl delete deployment/vllm-qwen3-32b service/vllm-qwen3-32b -n vllm
# 或删除整个 namespace
kubectl delete namespace vllm
```

---

## 三、配置文件说明

### 3.1 模型运行配置（`configs/*.conf`）

每个模型一个配置文件，`key=value` 格式，可被 bash `source` 直接加载。
被 `start_vllm_server.sh`、`start_vllm_docker.sh`、`start_vllm_k8s.sh` 共同读取。

```bash
# ── 必填 ──────────────────────────────────────────────────────────────────────
model_weights=bge-m3          # 对应 model_registry.conf 中的 section 名称

# ── 网络 ──────────────────────────────────────────────────────────────────────
port=28800                     # 服务监听端口

# ── 推理参数 ──────────────────────────────────────────────────────────────────
served_model_name=             # OpenAI API 中的模型名（空 = 使用权重路径）
task=embed                     # 任务类型：embed（嵌入）或留空（对话）
dtype=bfloat16                 # 权重精度：auto / bfloat16 / float16
max_model_len=8192             # 最大序列长度（tokens）
max_num_seqs=64                # 最大并发请求数

# ── 并行配置（所需 GPU 数 = tensor_parallel_size × pipeline_parallel_size）──
tensor_parallel_size=1
pipeline_parallel_size=1
gpu_memory_utilization=0.8

# ── 可选 flag（true/false）────────────────────────────────────────────────────
enable_chunked_prefill=false
enforce_eager=true

# ── 可选参数（空 = 不传）──────────────────────────────────────────────────────
distributed_executor_backend=
compilation_config=            # JSON 字符串，需用单引号包裹，例如：
                               # compilation_config='{"cudagraph_mode": "FULL_DECODE_ONLY"}'

# ── Kubernetes 专属 ───────────────────────────────────────────────────────────
k8s_nodeport=30800             # NodePort 端口（必填，供 start_vllm_k8s.sh 使用）
k8s_node_name=                 # 指定 k8s 节点名（空 = 自动探测有足够 GPU 的节点）
```

### 3.2 模型库（`model_registry.conf`）

```ini
[bge-m3]
local_path=/data/models/BAAI/bge-m3
huggingface_id=BAAI/bge-m3
modelscope_id=BAAI/bge-m3

[qwen3-32b]
local_path=/data/models/Qwen/Qwen3-32B
huggingface_id=Qwen/Qwen3-32B
modelscope_id=Qwen/Qwen3-32B
```

---

## 四、新增模型

### 步骤 1：在 `model_registry.conf` 添加条目

```ini
[my-new-model]
local_path=/data/models/org/my-new-model
huggingface_id=org/my-new-model
modelscope_id=org/my-new-model
```

### 步骤 2：在 `configs/` 新建配置文件

```bash
cp configs/qwen3-32b.conf configs/my-new-model.conf
# 修改 model_weights、port、tp/pp、k8s_nodeport 等参数
```

### 步骤 3：启动服务

```bash
# Docker
sudo bash start_vllm_docker.sh my-new-model

# Kubernetes
bash start_vllm_k8s.sh my-new-model
```

不需要修改任何脚本，所有参数从配置文件中读取。

---

## 五、GPU 使用规则（Docker 方式）

`start_vllm_docker.sh` 自动从 `brsmi` 查询空闲 GPU（`memory.used == 0`），按索引从小到大选取 `tensor_parallel_size × pipeline_parallel_size` 张。

- 选中的卡以 `--device /dev/biren/card_N` 独占映射到容器
- 同时设置 `BIREN_VISIBLE_DEVICES=N,...` 环境变量
- 若空闲卡数量不足，脚本报错退出并打印当前 GPU 状态

```bash
brsmi gpu --query-gpu=index,memory.used,memory.free --format=csv,noheader
```

k8s 方式下，GPU 分配由 biren device plugin 自动处理（通过 `birentech.com/gpu` 资源请求）。
