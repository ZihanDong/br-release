---
name: vllm
description: Start and manage vLLM OpenAI-compatible inference servers on BirenTech GPU nodes. Covers Docker and Kubernetes deployments, model registry management, GPU selection, and troubleshooting. Read this skill before launching any vLLM server.
metadata:
  type: skill
  tags: [vllm, inference, birentech, gpu, docker, kubernetes, llm, embedding]
  scripts:
    - infer/llm/vllm/start_vllm_server.sh
    - infer/llm/vllm/start_vllm_k8s.sh
    - infer/llm/vllm/model_registry.conf
    - infer/llm/vllm/configs/bge-m3.conf
    - infer/llm/vllm/configs/qwen3-32b.conf
---

# Skill: vllm

## Script / File Map

| 文件 | 说明 |
|------|------|
| `start_vllm_server.sh` | Docker 方式启动主脚本；强制要求传入配置文件 |
| `start_vllm_k8s.sh` | k8s 方式启动脚本；动态生成 YAML 并 apply；同样接受配置文件 |
| `model_registry.conf` | 模型库：记录本地权重路径 + HF/MS 下载 ID |
| `configs/<model>.conf` | 每个模型的 vLLM 运行参数（port、tp、pp、k8s_nodeport 等） |

两个脚本共享同一套 `configs/*.conf`，新增模型只需写一个配置文件即可同时支持 Docker 和 k8s 部署。

已部署模型端口一览：

| 模型 | 类型 | Docker 端口 | k8s NodePort |
|------|------|------------|-------------|
| bge-m3 | embedding | 28800 | 30800 |
| qwen3-32b | chat | 28800 | 30801 |

---

## 1 — Docker 方式启动

### 1.1 启动命令

```bash
cd infer/llm/vllm
sudo bash start_vllm_server.sh <config>
```

`<config>` 接受以下格式：

| 格式 | 示例 |
|------|------|
| 裸模型名 | `bge-m3` → 自动解析为 `configs/bge-m3.conf` |
| 相对路径 | `configs/qwen3-32b.conf` |
| 绝对路径 | `/path/to/custom.conf` |

### 1.2 典型启动流程

**启动 bge-m3（embedding，1 GPU，端口 28800）：**

```bash
cd infer/llm/vllm
sudo bash start_vllm_server.sh bge-m3
```

脚本输出示例：
```
[INFO]  Config      : bge-m3.conf
[INFO]  Model key   : bge-m3  |  port=28800  |  tp=1  pp=1
[ OK ]  Weights     : /data/models/BAAI/bge-m3
[INFO]  GPU needed  : tp=1 × pp=1 = 1
[ OK ]  GPUs        : [0]  (card_0 )
[INFO]  Container   : vllm_bge-m3
[ OK ]  Container started. Waiting for server on port 28800...
        ....
[ OK ]  Server is ready!
```

**启动 qwen3-32b（chat，2 GPU，端口 28800）：**

```bash
sudo bash start_vllm_server.sh qwen3-32b
```

> 两个模型默认都使用 28800 端口，不能同时用 Docker 方式运行。若需同时运行，修改其中一个 conf 的 `port` 字段（例如改为 28801）。

### 1.3 查看日志

```bash
# 实时日志（容器标准输出）
sudo docker logs -f vllm_bge-m3

# 也会同步写入文件
tail -f infer/llm/vllm/logs/vllm_bge-m3_<timestamp>.log
```

### 1.4 停止 / 重启

```bash
sudo docker stop vllm_bge-m3       # 停止
sudo docker rm   vllm_bge-m3       # 删除容器

# 重新启动只需再次运行脚本（脚本会自动删除同名旧容器）
sudo bash start_vllm_server.sh bge-m3
```

### 1.5 验证（curl 测试）

**bge-m3 embedding：**
```bash
curl -s http://127.0.0.1:28800/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model": "/data/models/BAAI/bge-m3", "input": "Hello, world!"}' \
  | python3 -m json.tool
```

期望响应：包含 `"object": "list"` 和 `"embedding": [...]` 数组。

**qwen3-32b chat：**
```bash
curl -s http://127.0.0.1:28800/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "Qwen/Qwen3-32B", "messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 64}' \
  | python3 -m json.tool
```

期望响应：包含 `"choices"` 数组和 `"content"` 字段。

---

## 2 — Kubernetes 方式启动

### 2.1 前置检查

在部署前确认：

```bash
# 集群节点处于 biren 模式（GPU 可分配）
kubectl get node -o jsonpath='{.items[0].status.allocatable.birentech\.com/gpu}'
# 期望输出: 8（或其他正整数）

# device plugin 运行中
kubectl get pods -n biren-gpu
# 期望: biren-device-plugin-daemonset-xxx Running

# RuntimeClass 已注册（首次部署集群时需要执行一次）
kubectl get runtimeclass biren
# 期望: NAME=biren HANDLER=biren
```

若 RuntimeClass 不存在，先执行 **2.2 RuntimeClass 注册**（一次性操作）。

### 2.2 RuntimeClass 注册（首次部署，需要 root）

containerd v2.x 的新 CRI 插件（`io.containerd.cri.v1.runtime`）与旧版 gRPC 插件配置独立，biren runtime 需要在两处都注册。

**Step 1：追加 containerd 配置**

```bash
sudo bash -c "cat >> /etc/containerd/config.toml << 'EOF'

        [plugins.\"io.containerd.cri.v1.runtime\".containerd.runtimes.biren]
          runtime_type = \"io.containerd.runc.v2\"
          sandboxer = \"podsandbox\"

          [plugins.\"io.containerd.cri.v1.runtime\".containerd.runtimes.biren.options]
            BinaryName = \"/usr/local/birensupa/container-toolkit/biren-container-toolkit/bin/biren-container-runtime\"
            SystemdCgroup = true
EOF"
```

**Step 2：重启 containerd**

```bash
sudo systemctl restart containerd
kubectl get nodes   # 确认节点仍 Ready
```

**Step 3：创建 RuntimeClass**

```bash
kubectl apply -f - << 'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: biren
handler: biren
EOF
```

> **原理：** 镜像的 entrypoint 是 `biren_entrypoint.sh`，它在启动时调用 `brsw_set_env.sh` 设置 `LD_LIBRARY_PATH`，使 `libsupti.so.1` 等 SDK 库可被 torch_br 加载。YAML 中只使用 `args`（不用 `command`），确保 entrypoint 正常执行。

### 2.3 部署命令

```bash
cd infer/llm/vllm

# 单独部署
bash start_vllm_k8s.sh bge-m3
bash start_vllm_k8s.sh qwen3-32b

# 两个模型可同时运行（NodePort 不同，互不冲突）
```

脚本自动完成：自动探测节点 → 生成 Namespace + Deployment + Service YAML → apply → 等待 Pod Ready → 打印 curl 命令。

### 2.4 监控启动进度

模型加载需要一定时间（bge-m3 约 2 分钟，qwen3-32b 约 5 分钟）：

```bash
# 查看 Pod 状态（等待 1/1 Running）
kubectl get pods -n vllm -w

# 查看启动日志
kubectl logs -n vllm -l app=vllm-bge-m3 -f
kubectl logs -n vllm -l app=vllm-qwen3-32b -f

# 查看服务和端点（Endpoints 有值时表示 Pod 已 Ready）
kubectl get svc,endpoints -n vllm
```

### 2.5 验证（curl 测试）

> 环境若设置了 HTTP 代理（`http_proxy`），需加 `--noproxy "*"`。

**bge-m3（NodePort 30800）：**
```bash
curl -s --noproxy "*" http://10.49.4.248:30800/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model": "/data/models/BAAI/bge-m3", "input": "Hello, world!"}' \
  | python3 -m json.tool
```

**qwen3-32b（NodePort 30801）：**
```bash
curl -s --noproxy "*" http://10.49.4.248:30801/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "Qwen/Qwen3-32B", "messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 64}' \
  | python3 -m json.tool
```

### 2.6 清理

```bash
kubectl delete deployment/vllm-bge-m3 service/vllm-bge-m3 -n vllm
kubectl delete deployment/vllm-qwen3-32b service/vllm-qwen3-32b -n vllm

# 或一次性清理整个 vllm namespace
kubectl delete namespace vllm
```

---

## 3 — 配置文件格式

### 3.1 `configs/<model>.conf` 参数说明

| 参数 | 必填 | 示例 | 说明 |
|------|------|------|------|
| `model_weights` | ✓ | `bge-m3` | model_registry.conf 中的 section 名 |
| `port` | ✓ | `28800` | 服务监听端口 |
| `served_model_name` | — | `Qwen/Qwen3-32B` | API 中 model 字段；空 = 用权重路径 |
| `task` | — | `embed` | 嵌入模型必须设为 `embed`；对话模型留空 |
| `dtype` | ✓ | `bfloat16` | `auto` / `bfloat16` / `float16` |
| `max_model_len` | ✓ | `8192` | 最大序列长度 |
| `max_num_seqs` | ✓ | `64` | 最大并发序列数 |
| `tensor_parallel_size` | ✓ | `2` | 张量并行数 |
| `pipeline_parallel_size` | ✓ | `1` | 流水线并行数 |
| `gpu_memory_utilization` | ✓ | `0.8` | GPU 显存使用比例（0~1） |
| `enable_chunked_prefill` | — | `true` | 启用 chunked prefill |
| `enforce_eager` | — | `true` | 禁用 CUDA graph（嵌入模型建议开启） |
| `distributed_executor_backend` | — | `mp` | 多进程后端：`mp` 或留空 |
| `compilation_config` | — | `'{"cudagraph_mode": "FULL_DECODE_ONLY"}'` | JSON 格式，需用单引号包裹 |
| `k8s_nodeport` | k8s必填 | `30800` | k8s NodePort 端口（供 start_vllm_k8s.sh 使用） |
| `k8s_node_name` | — | `pj-3f-server008` | 指定 k8s 节点；空 = 自动探测 |

**所需 GPU 数 = `tensor_parallel_size × pipeline_parallel_size`**

### 3.2 `model_registry.conf` 格式

```ini
[<model_name>]
local_path=<host 上的权重绝对路径>    # 留空 = 未下载，脚本会询问
huggingface_id=<org/repo>             # huggingface-cli download <id>
modelscope_id=<org/repo>              # modelscope download --model <id>
```

---

## 4 — 常见问题

### Docker 方式

| 现象 | 原因 | 解决 |
|------|------|------|
| `Docker image not found` | 本地无该镜像 | `sudo docker images` 确认镜像名称后更新脚本中 `CONTAINER_IMAGE` |
| `Not enough free GPUs` | 其他进程占用 GPU | `brsmi` 查看占用，或等待释放 |
| `Container exited unexpectedly` | 脚本自动打印最后 30 行日志 | 检查日志中的具体错误，常见为 OOM 或权重路径不存在 |
| 模型权重不存在 | `local_path` 目录不存在 | 脚本会交互式询问是否下载 |

### k8s 方式

| 现象 | 原因 | 解决 |
|------|------|------|
| `ImportError: libsupti.so.1` | YAML 中 `command` 覆盖了镜像 entrypoint | 脚本生成的 YAML 只有 `args` 字段，无 `command`；若手动修改过 YAML 请检查 |
| `Failed to infer device type` | biren runtime 未注册或 SDK 库未加载 | 检查 RuntimeClass 是否存在；重新执行 2.2 步骤 |
| Pod 长时间 `0/1 Running` | readiness probe 初始延迟期 | 正常现象，bge-m3 约 2 min，qwen3-32b 约 5 min |
| `Endpoints` 为空 | Pod 未 Ready | `kubectl describe pod -n vllm <pod>` 查看事件 |
| NodePort curl 返回 502/空 | 系统 HTTP 代理干扰 | 加 `--noproxy "*"` 参数 |
| Pod `Pending` 且有 GPU 不足提示 | 其他 Pod 已占用全部 GPU | `kubectl get pods -A` 查看占用情况 |
| `k8s_nodeport not set` | conf 文件缺少 `k8s_nodeport` 字段 | 在 `configs/<model>.conf` 中添加 `k8s_nodeport=<port>` |
