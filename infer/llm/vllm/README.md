# vLLM Server — BirenTech GPU 部署指南

本目录提供两种方式在 BirenTech GPU 节点上拉起 vLLM OpenAI 兼容推理服务：

| 方式 | 脚本 | 适用场景 |
|------|------|---------|
| **Docker** | `run_docker.sh` | 快速调试、单次运行 |
| **Kubernetes** | `k8s_yaml_gen.sh` + `test_k8s.sh` | 生产部署、持久运行 |

---

## 架构说明

```
宿主机                                  容器内
┌──────────────────────────┐          ┌──────────────────────────────────┐
│ run_docker.sh             │          │ biren_entrypoint.sh              │
│  └ GPU 选择（brsmi）      │ docker   │  └ exec args...                  │
│  └ 启动容器               │ ──────►  │      bash vllm_server.sh <conf>  │
│  └ 轮询 /health           │          │        └ exec python3 -m vllm... │
└──────────────────────────┘          └──────────────────────────────────┘

┌──────────────────────────┐  生成     k8s_yaml_gen/
│ k8s_yaml_gen.sh           │ ──────►  └ <model>.yaml
│  └ 节点探测               │
│  └ 生成 YAML 到文件       │  apply
└──────────────────────────┘    │
                                ▼
┌──────────────────────────┐          ┌──────────────────────────────────┐
│ test_k8s.sh               │ kubectl  │ biren_entrypoint.sh              │
│  └ kubectl apply <yaml>   │ ──────►  │  └ exec args...                  │
│  └ 等待 Pod Ready         │          │      bash vllm_server.sh <conf>  │
│  └ API 自动测试           │          │        └ exec python3 -m vllm... │
│  └ 打印 k8s 命令          │          └──────────────────────────────────┘
└──────────────────────────┘
```

`vllm_server.sh` 挂载到容器中（Docker 通过 `/home` bind-mount，k8s 通过 hostPath volume），
由 BirenTech 镜像的 ENTRYPOINT（`biren_entrypoint.sh`）设置好 `LD_LIBRARY_PATH` 后调用。

---

## 目录结构

```
infer/llm/
├── model_registry.conf   # 模型库：本地路径 + HuggingFace/ModelScope ID（多框架共享）
└── vllm/
    ├── vllm_server.sh        # 容器内脚本：加载 conf → 查 registry → exec vllm
    ├── run_docker.sh         # Docker 外层：GPU 选择 + 容器启动 + 健康轮询
    ├── k8s_yaml_gen.sh       # k8s YAML 生成器：根据 conf 输出 YAML 到 k8s_yaml_gen/
    ├── test_k8s.sh           # k8s 部署测试：apply YAML + 等待就绪 + API 测试 + 打印命令
    ├── configs/
    │   ├── bge-m3.conf         # bge-m3（embedding，端口 28800，k8s NodePort 30800）
    │   ├── qwen3-32b.conf      # Qwen3-32B（chat，端口 28800，k8s NodePort 30801）
    │   └── minimax-m2.5.conf   # MiniMax M2.5（chat MoE，INT8，端口 20027，k8s NodePort 30802）
    ├── quant/                # 权重量化工具
    │   ├── run_quant.sh        # 一键量化：FP8 → BF16 → INT8（在 BirenTech 容器内运行）
    │   ├── cast_fp8_bf16.py    # Stage 1：FP8 safetensors → BF16
    │   ├── convert-to-compressed.py  # Stage 2：BF16 → INT8 packed（torchrun 分布式）
    │   └── utils.py            # 量化辅助函数
    ├── k8s_yaml_gen/         # 生成的 k8s YAML（临时文件，可按需修改后应用）
    │   ├── bge-m3.yaml
    │   └── qwen3-32b.yaml
    └── logs/                 # 启动 / 量化日志（自动生成）
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
sudo bash run_docker.sh <config>
```

`<config>` 支持三种形式：

```bash
sudo bash run_docker.sh bge-m3                    # 裸模型名（自动找 configs/bge-m3.conf）
sudo bash run_docker.sh configs/qwen3-32b.conf   # 相对路径
sudo bash run_docker.sh /abs/path/to/custom.conf # 绝对路径
```

### 1.2 脚本行为

1. 加载配置文件，查找模型权重（如缺失则询问下载）
2. 用 `brsmi` 查询空闲 GPU，选取 `tp × pp` 张
3. 启动 Docker 容器，仅映射所需的 `/dev/biren/card_N` 设备
4. 挂载 `/home:/home`（使 `vllm_server.sh` 在容器内可见）
5. 容器内由 ENTRYPOINT → `vllm_server.sh` → `exec python3 -m vllm...` 完成启动
6. 宿主机轮询 `/health` 端点，最多等待 600 秒

### 1.3 容器管理

容器名为 `vllm_<model_weights>`，日志写入 `logs/vllm_<model>_<timestamp>.log`：

```bash
sudo docker logs -f vllm_bge-m3
sudo docker stop vllm_bge-m3
sudo docker rm   vllm_bge-m3
```

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

> Docker 方式两个模型都使用端口 28800，不能同时运行。若需同时运行，修改其中一个 conf 的 `port` 字段。

---

## 二、Kubernetes 方式

### 2.1 前置：集群环境要求

| 组件 | 版本/状态 |
|------|---------|
| k8s | v1.25+，节点处于 `biren` 模式 |
| containerd | v1.7+，已注册 `biren` RuntimeClass |
| biren device plugin | DaemonSet 运行中（`biren-gpu` namespace） |
| 私有 Registry | `172.25.198.36:32000`（镜像已导入） |

**RuntimeClass 注册**：`join.sh biren` 和 `set-node-mode.sh biren` 会自动完成，通常无需手动执行。若需手动创建：

```bash
kubectl apply -f - << 'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: biren
handler: runc
EOF
```

> **注意：** RuntimeClass 使用 `handler: runc`（标准 runc），GPU 设备访问通过 `privileged: true` + `BIREN_VISIBLE_DEVICES` 环境变量实现，SDK 库路径通过 `biren-driver` hostPath volume（`/usr/local/birensupa/driver`）挂载提供——`k8s_yaml_gen.sh` 自动将这三项写入生成的 YAML。

### 2.2 典型工作流

```bash
cd infer/llm/vllm

# Step 1：生成 YAML（可在部署前检查或修改）
bash k8s_yaml_gen.sh bge-m3
# → 保存到 k8s_yaml_gen/bge-m3.yaml

# Step 2：（可选）查看 / 修改 YAML
cat k8s_yaml_gen/bge-m3.yaml

# Step 3：部署并自动测试 API
bash test_k8s.sh k8s_yaml_gen/bge-m3.yaml
```

两个模型可同时部署（NodePort 不同，互不冲突）：

```bash
bash k8s_yaml_gen.sh bge-m3    && bash test_k8s.sh k8s_yaml_gen/bge-m3.yaml
bash k8s_yaml_gen.sh qwen3-32b && bash test_k8s.sh k8s_yaml_gen/qwen3-32b.yaml
```

### 2.3 `k8s_yaml_gen.sh` 行为

- 加载 conf，查找模型权重（如缺失则询问下载）
- 自动探测具有足够 GPU 资源的节点（或使用 `k8s_node_name` 指定）
- 生成完整的 Namespace + Deployment + Service YAML 保存到 `k8s_yaml_gen/<model>.yaml`
- **不执行 apply**，便于在部署前检查或修改 YAML

### 2.4 `test_k8s.sh` 行为

- 解析 YAML 中的元数据（namespace、app label、nodeport、config 路径等）
- `kubectl apply -f <yaml>` 应用资源
- 等待 Pod 变为 Ready（超时时间从 YAML readiness probe 初始延迟推算）
- 自动执行 API 调用验证（embedding 或 chat completion）
- 打印后续可用的 kubectl 命令

### 2.5 端口说明

| 模型 | containerPort | NodePort | 访问地址 |
|------|--------------|----------|---------|
| bge-m3 | 28800 | **30800** | `http://<node-ip>:30800` |
| qwen3-32b | 28800 | **30801** | `http://<node-ip>:30801` |

### 2.6 curl 测试

> 若系统配置了 HTTP 代理（`http_proxy`），需添加 `--noproxy "*"` 参数。

```bash
# bge-m3（brhost-02 = 172.25.198.37，NodePort 30800）
curl -s --noproxy "*" http://172.25.198.37:30800/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model": "/data/models/BAAI/bge-m3", "input": "Hello, world!"}' \
  | python3 -m json.tool

# qwen3-32b（brhost-02 = 172.25.198.37，NodePort 30801）
curl -s --noproxy "*" http://172.25.198.37:30801/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "Qwen/Qwen3-32B", "messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 64}' \
  | python3 -m json.tool
```

### 2.7 清理

```bash
kubectl delete deployment/vllm-bge-m3 service/vllm-bge-m3 -n vllm
kubectl delete deployment/vllm-qwen3-32b service/vllm-qwen3-32b -n vllm
# 或删除整个 namespace
kubectl delete namespace vllm
```

---

## 三、配置文件说明

### 3.1 模型运行配置（`configs/*.conf`）

`key=value` 格式，被 `vllm_server.sh`、`run_docker.sh`、`k8s_yaml_gen.sh` 共同读取：

```bash
# ── 必填 ──────────────────────────────────────────────────────────────────────
model_weights=bge-m3          # 对应 model_registry.conf 中的 section 名称
port=28800                     # 服务监听端口

# ── 推理参数 ──────────────────────────────────────────────────────────────────
served_model_name=             # OpenAI API 中的模型名（空 = 使用权重路径）
task=embed                     # 任务类型：embed（嵌入）或留空（对话）
dtype=bfloat16
max_model_len=8192
max_num_seqs=64

# ── 并行配置 ──────────────────────────────────────────────────────────────────
tensor_parallel_size=1
pipeline_parallel_size=1       # 所需 GPU 数 = tp × pp
gpu_memory_utilization=0.8

# ── 可选 flag ─────────────────────────────────────────────────────────────────
enable_chunked_prefill=false
enforce_eager=true
distributed_executor_backend=
compilation_config=            # 需用单引号包裹 JSON，如：
                               # compilation_config='{"cudagraph_mode": "FULL_DECODE_ONLY"}'

# ── Kubernetes 专属 ───────────────────────────────────────────────────────────
k8s_nodeport=30800             # NodePort 端口（k8s_yaml_gen.sh 必填）
k8s_node_name=                 # 指定 k8s 节点；空 = 自动探测
```

### 3.2 模型库（`infer/llm/model_registry.conf`）

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

```bash
# 1. 在 infer/llm/model_registry.conf 添加条目
# 2. 复制并修改 conf 文件
cp configs/qwen3-32b.conf configs/my-model.conf
# 修改 model_weights、port、tp/pp、k8s_nodeport

# 3. Docker 启动
sudo bash run_docker.sh my-model

# 4. k8s 启动
bash k8s_yaml_gen.sh my-model
bash test_k8s.sh k8s_yaml_gen/my-model.yaml
```

---

## 五、GPU 使用规则（Docker 方式）

`run_docker.sh` 自动从 `brsmi` 查询空闲 GPU（`memory.used == 0`），选取 `tp × pp` 张：

- 选中的卡以 `--device /dev/biren/card_N` 独占映射到容器
- 同时设置 `BIREN_VISIBLE_DEVICES=N,...` 环境变量
- 若空闲卡数量不足，脚本报错退出并打印当前 GPU 状态

```bash
brsmi gpu --query-gpu=index,memory.used,memory.free --format=csv,noheader
```

---

## 六、权重量化（FP8 → INT8）

部分模型（如 MiniMax M2.5）官方只提供 FP8 权重，需离线量化为 INT8 格式。

### 6.1 量化流程

```
FP8 权重  ──[cast_fp8_bf16.py]──►  BF16 临时权重  ──[convert-to-compressed.py]──►  INT8 权重
```

| Stage | 脚本 | 方式 | 说明 |
|-------|------|------|------|
| Stage 1 | `quant/cast_fp8_bf16.py` | 单进程 | FP8 safetensors 反量化为 BF16 |
| Stage 2 | `quant/convert-to-compressed.py` | `torchrun` 8 进程 | BF16 → channel-wise INT8 packed |

### 6.2 一键量化

编辑 `quant/run_quant.sh` 开头的路径变量后运行：

```bash
cd infer/llm/vllm
sudo bash quant/run_quant.sh
# 日志写入 logs/quant_m2.5_<timestamp>.log
```

脚本支持**断点续跑**：若 BF16 或 INT8 目标目录的 `model.safetensors.index.json` 已存在，对应 Stage 会跳过。

### 6.3 量化后验证

```bash
# Docker 启动
sudo bash run_docker.sh minimax-m2.5

# 测试 API
curl -s http://127.0.0.1:20027/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "/data/models/MiniMax/MiniMax-M2.5-INT8", "messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 64}' \
  | python3 -m json.tool
```

k8s 方式下，GPU 分配由 biren device plugin 自动处理（通过 `birentech.com/gpu` 资源请求）。
