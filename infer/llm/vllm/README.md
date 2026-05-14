# vLLM Server — BirenTech GPU 部署指南

本目录提供两种方式在 BirenTech GPU 节点上拉起 vLLM OpenAI 兼容推理服务：

| 方式 | 入口 | 适用场景 |
|------|------|---------|
| **Docker** | `start_vllm_server.sh` | 快速调试、单次运行 |
| **Kubernetes** | `k8s/*.yaml` | 生产部署、持久运行 |

---

## 目录结构

```
infer/llm/vllm/
├── start_vllm_server.sh      # Docker 启动主脚本
├── model_registry.conf       # 模型库：本地路径 + HuggingFace/ModelScope ID
├── configs/
│   ├── bge-m3.conf           # bge-m3 运行参数
│   └── qwen3-32b.conf        # Qwen3-32B 运行参数
├── k8s/
│   ├── bge-m3.yaml           # bge-m3 Deployment + Service
│   └── qwen3-32b.yaml        # Qwen3-32B Deployment + Service
└── logs/                     # Docker 启动日志（自动生成）
```

---

## 前置条件

| 依赖 | 说明 |
|------|------|
| BirenTech GPU 驱动 | `/dev/biren/card_*` 设备文件存在 |
| `brsmi` | 用于查询 GPU 空闲状态 |
| Docker | 需要 `sudo docker` 权限 |
| `kubectl` | 仅 k8s 方式需要，需有 `~/.kube/config` |
| 模型权重 | 存放于 host 的 `/data/models/` 目录下 |

---

## 一、Docker 方式

### 1.1 启动命令

```bash
cd infer/llm/vllm
sudo bash start_vllm_server.sh <config>
```

`<config>` 支持三种形式：

```bash
sudo bash start_vllm_server.sh bge-m3                    # 裸模型名（自动找 configs/bge-m3.conf）
sudo bash start_vllm_server.sh configs/qwen3-32b.conf   # 相对路径
sudo bash start_vllm_server.sh /abs/path/to/custom.conf # 绝对路径
```

### 1.2 脚本行为

脚本按以下顺序执行：

1. **加载配置文件** — 读取 `configs/<model>.conf` 中的所有参数
2. **查找模型权重** — 在 `model_registry.conf` 中匹配 `model_weights` 字段
3. **权重缺失时询问下载** — 支持通过 modelscope 或 huggingface 下载
4. **选择空闲 GPU** — 用 `brsmi` 查询 `memory.used == 0` 的卡，选取 `tp × pp` 张
5. **启动 Docker 容器** — 只映射所需的 `/dev/biren/card_N` 设备
6. **等待服务就绪** — 轮询 `/health` 端点，最多等待 600 秒
7. **打印 curl 测试命令**

### 1.3 容器管理

脚本启动后容器在后台运行，容器名为 `vllm_<model_weights>`：

```bash
# 查看日志
sudo docker logs -f vllm_bge-m3
sudo docker logs -f vllm_qwen3-32b

# 停止
sudo docker stop vllm_bge-m3

# 删除
sudo docker rm vllm_bge-m3
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

containerd v2.x 的 `cri.v1.runtime` 插件需要单独注册 biren runtime handler，否则镜像 entrypoint 中的 SDK 路径初始化不会执行。已完成的配置步骤：

1. 在 `/etc/containerd/config.toml` 末尾追加 biren runtime handler（`cri.v1.runtime` 节点下）
2. `systemctl restart containerd`
3. 创建 `RuntimeClass` 资源（`handler: biren`）

如在新集群部署，参考 `skills/vllm.md` 中的"RuntimeClass 注册"章节。

### 2.2 部署

```bash
cd infer/llm/vllm/k8s

# 部署单个模型
kubectl apply -f bge-m3.yaml
kubectl apply -f qwen3-32b.yaml

# 两个同时部署（互不冲突，使用不同 NodePort）
kubectl apply -f bge-m3.yaml -f qwen3-32b.yaml
```

### 2.3 查看状态

```bash
kubectl get pods -n vllm
kubectl get svc -n vllm

# 查看日志（模型加载需要数分钟）
kubectl logs -n vllm -l app=vllm-bge-m3 -f
kubectl logs -n vllm -l app=vllm-qwen3-32b -f
```

### 2.4 端口说明

| 模型 | containerPort | NodePort | 访问地址 |
|------|--------------|----------|---------|
| bge-m3 | 28800 | **30800** | `http://<node-ip>:30800` |
| qwen3-32b | 28800 | **30801** | `http://<node-ip>:30801` |

### 2.5 curl 测试

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

### 2.6 清理

```bash
kubectl delete -f bge-m3.yaml
kubectl delete -f qwen3-32b.yaml
# 或删除整个 namespace
kubectl delete namespace vllm
```

---

## 三、配置文件说明

### 3.1 模型运行配置（`configs/*.conf`）

每个模型一个配置文件，使用 `key=value` 格式（可被 bash `source` 直接加载）：

```bash
# 必填
model_weights=bge-m3          # 对应 model_registry.conf 中的 section 名称

# 网络
port=28800                     # 服务监听端口

# 推理参数
served_model_name=             # OpenAI API 中的模型名（空 = 使用权重路径）
task=embed                     # 任务类型：embed（嵌入）或留空（对话）
dtype=bfloat16                 # 权重精度：auto / bfloat16 / float16
max_model_len=8192             # 最大序列长度（tokens）
max_num_seqs=64                # 最大并发请求数

# 并行配置（所需 GPU 数 = tensor_parallel_size × pipeline_parallel_size）
tensor_parallel_size=1
pipeline_parallel_size=1
gpu_memory_utilization=0.8

# 可选 flag（true/false）
enable_chunked_prefill=false
enforce_eager=true

# 可选参数（空 = 不传）
distributed_executor_backend=
compilation_config=            # JSON 字符串，需用单引号包裹，例如：
                               # compilation_config='{"cudagraph_mode": "FULL_DECODE_ONLY"}'
```

### 3.2 模型库（`model_registry.conf`）

记录所有模型的本地路径和下载 ID，INI 格式：

```ini
[bge-m3]
local_path=/data/models/BAAI/bge-m3     # 本地权重目录（为空则视为未下载）
huggingface_id=BAAI/bge-m3              # huggingface-cli download <id>
modelscope_id=BAAI/bge-m3              # modelscope download --model <id>

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
# 修改 model_weights、port、tp/pp 等参数
```

### 步骤 3：（k8s）复制并修改 YAML

```bash
cp k8s/qwen3-32b.yaml k8s/my-new-model.yaml
# 修改：metadata.name、app label、model 路径、GPU 数量、NodePort
```

---

## 五、GPU 使用规则（Docker 方式）

`start_vllm_server.sh` 自动从 `brsmi` 查询空闲 GPU（`memory.used == 0`），按索引从小到大选取 `tensor_parallel_size × pipeline_parallel_size` 张。

- 选中的卡以 `--device /dev/biren/card_N` 独占映射到容器
- 同时设置 `BIREN_VISIBLE_DEVICES=N,...` 环境变量
- 若空闲卡数量不足，脚本报错退出并打印当前 GPU 状态

**查看当前 GPU 状态：**
```bash
brsmi gpu --query-gpu=index,memory.used,memory.free --format=csv,noheader
```
