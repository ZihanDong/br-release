---
name: vllm
description: Start and manage vLLM OpenAI-compatible inference servers on BirenTech GPU nodes. Covers Docker and Kubernetes deployments, model registry management, GPU selection, and troubleshooting. Read this skill before launching any vLLM server.
metadata:
  type: skill
  tags: [vllm, inference, birentech, gpu, docker, kubernetes, llm, embedding]
  scripts:
    - infer/llm/vllm/vllm_server.sh
    - infer/llm/vllm/run_docker.sh
    - infer/llm/vllm/k8s_yaml_gen.sh
    - infer/llm/vllm/test_k8s.sh
    - infer/llm/vllm/model_registry.conf
    - infer/llm/vllm/configs/bge-m3.conf
    - infer/llm/vllm/configs/qwen3-32b.conf
---

# Skill: vllm

## Script / File Map

| 文件 | 运行位置 | 说明 |
|------|---------|------|
| `vllm_server.sh` | **容器内** | 加载 conf → 查 registry → exec vLLM；被 Docker/k8s 统一调用 |
| `run_docker.sh` | 宿主机 | GPU 选择（brsmi）+ `docker run` + 健康轮询 |
| `k8s_yaml_gen.sh` | 宿主机 | 生成 k8s YAML 到 `k8s_yaml_gen/<model>.yaml`，不执行 apply |
| `test_k8s.sh` | 宿主机 | `kubectl apply <yaml>` + 等待 Ready + API 测试 + 打印命令 |
| `model_registry.conf` | — | 模型库：本地权重路径 + HF/MS 下载 ID |
| `configs/<model>.conf` | — | 每个模型的运行参数；Docker 和 k8s 共用同一套配置 |

**架构原则：**
- 所有 vLLM 参数逻辑集中在 `vllm_server.sh`（容器内脚本）
- 外层脚本只负责容器编排，不重复构建 vLLM 命令
- k8s 分两步：先生成 YAML（可检查/修改），再部署测试
- 新增模型只需一个 conf 文件，无需修改任何脚本

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
sudo bash run_docker.sh <config>
```

`<config>` 接受：裸模型名（`bge-m3`）、相对路径、绝对路径。

### 1.2 典型流程

```bash
sudo bash run_docker.sh bge-m3
```

输出示例：
```
[INFO]  Config      : bge-m3.conf
[INFO]  Model key   : bge-m3  |  port=28800  |  tp=1  pp=1
[ OK ]  Weights     : /data/models/BAAI/bge-m3
[INFO]  GPU needed  : tp=1 × pp=1 = 1
[ OK ]  GPUs        : [0]  (card_0 )
[INFO]  Container   : vllm_bge-m3
[ OK ]  Container started. Waiting for server on port 28800...
        ....
[ OK ]  vLLM server ready — vllm_bge-m3  :28800
```

> 两个模型默认都使用 28800 端口，不能同时用 Docker 运行。若需同时运行，修改其中一个 conf 的 `port`。

### 1.3 查看日志

```bash
sudo docker logs -f vllm_bge-m3
tail -f infer/llm/vllm/logs/vllm_bge-m3_<timestamp>.log
```

### 1.4 停止 / 重启

```bash
sudo docker stop vllm_bge-m3 && sudo docker rm vllm_bge-m3
# 重启：脚本自动删除同名旧容器
sudo bash run_docker.sh bge-m3
```

### 1.5 验证（curl 测试）

**bge-m3 embedding：**
```bash
curl -s http://127.0.0.1:28800/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model": "/data/models/BAAI/bge-m3", "input": "Hello, world!"}' \
  | python3 -m json.tool
```

**qwen3-32b chat：**
```bash
curl -s http://127.0.0.1:28800/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "Qwen/Qwen3-32B", "messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 64}' \
  | python3 -m json.tool
```

---

## 2 — Kubernetes 方式启动

### 2.1 前置检查

```bash
# 集群 GPU 可分配
kubectl get node -o jsonpath='{.items[0].status.allocatable.birentech\.com/gpu}'
# device plugin 运行中
kubectl get pods -n biren-gpu
# RuntimeClass 已注册
kubectl get runtimeclass biren
```

若 RuntimeClass 不存在，先执行 **2.2 RuntimeClass 注册**（一次性操作）。

### 2.2 RuntimeClass 注册（首次部署，需要 root）

```bash
# Step 1: 追加 containerd 配置（cri.v1.runtime 节点）
sudo bash -c "cat >> /etc/containerd/config.toml << 'EOF'

        [plugins.\"io.containerd.cri.v1.runtime\".containerd.runtimes.biren]
          runtime_type = \"io.containerd.runc.v2\"
          sandboxer = \"podsandbox\"

          [plugins.\"io.containerd.cri.v1.runtime\".containerd.runtimes.biren.options]
            BinaryName = \"/usr/local/birensupa/container-toolkit/biren-container-toolkit/bin/biren-container-toolkit\"
            SystemdCgroup = true
EOF"

# Step 2: 重启 containerd
sudo systemctl restart containerd && kubectl get nodes

# Step 3: 创建 RuntimeClass
kubectl apply -f - << 'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: biren
handler: biren
EOF
```

> **原理：** 镜像 ENTRYPOINT（`biren_entrypoint.sh`）设置 LD_LIBRARY_PATH 后 `exec "$@"`。k8s YAML 只使用 `args`（不用 `command`），确保 ENTRYPOINT 正常执行，再由 `vllm_server.sh` 启动 vLLM。

### 2.3 典型工作流

```bash
cd infer/llm/vllm

# Step 1: 生成 YAML（可检查/修改后再部署）
bash k8s_yaml_gen.sh bge-m3
# → 输出: k8s_yaml_gen/bge-m3.yaml

# Step 2: 部署并自动测试
bash test_k8s.sh k8s_yaml_gen/bge-m3.yaml
```

两个模型同时运行：

```bash
bash k8s_yaml_gen.sh bge-m3    && bash test_k8s.sh k8s_yaml_gen/bge-m3.yaml
bash k8s_yaml_gen.sh qwen3-32b && bash test_k8s.sh k8s_yaml_gen/qwen3-32b.yaml
```

### 2.4 监控进度

```bash
kubectl get pods -n vllm -w
kubectl logs -n vllm -l app=vllm-bge-m3 -f
kubectl logs -n vllm -l app=vllm-qwen3-32b -f
kubectl get svc,endpoints -n vllm
```

### 2.5 验证

> 若系统配置了 HTTP 代理，需加 `--noproxy "*"`。

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
kubectl delete namespace vllm   # 全部清理
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
| `gpu_memory_utilization` | ✓ | `0.8` | GPU 显存使用比例 |
| `enable_chunked_prefill` | — | `true` | 启用 chunked prefill |
| `enforce_eager` | — | `true` | 禁用 CUDA graph |
| `distributed_executor_backend` | — | `mp` | 多进程后端 |
| `compilation_config` | — | `'{"cudagraph_mode": "FULL_DECODE_ONLY"}'` | JSON，需单引号包裹 |
| `k8s_nodeport` | k8s必填 | `30800` | k8s NodePort |
| `k8s_node_name` | — | `pj-3f-server008` | 指定 k8s 节点；空 = 自动探测 |

**所需 GPU 数 = `tensor_parallel_size × pipeline_parallel_size`**

### 3.2 `model_registry.conf` 格式

```ini
[<model_name>]
local_path=<权重绝对路径>   # 留空 = 未下载，脚本会询问
huggingface_id=<org/repo>
modelscope_id=<org/repo>
```

---

## 4 — 常见问题

### Docker 方式

| 现象 | 原因 | 解决 |
|------|------|------|
| `Docker image not found` | 本地无该镜像 | `sudo docker images` 确认后更新 `run_docker.sh` 中 `CONTAINER_IMAGE` |
| `Not enough free GPUs` | GPU 被占用 | `brsmi` 查看占用 |
| `Container exited unexpectedly` | 脚本打印最后 30 行日志 | 检查 OOM 或权重路径 |

### k8s 方式

| 现象 | 原因 | 解决 |
|------|------|------|
| `ImportError: libsupti.so.1` | ENTRYPOINT 被跳过 | 确认 YAML 只有 `args` 无 `command` |
| `Failed to infer device type` | biren runtime 未注册 | 重新执行 2.2 步骤 |
| Pod 长时间 `0/1 Running` | readiness probe 初始延迟 | 正常，bge-m3 约 2 min，qwen3-32b 约 5 min |
| NodePort curl 返回 502 | 系统 HTTP 代理干扰 | 加 `--noproxy "*"` |
| `Failed to parse XXX from YAML` | YAML 不是 k8s_yaml_gen.sh 生成的格式 | 确认 YAML 来自 `k8s_yaml_gen.sh` |
| `vllm_server.sh: not found` | hostPath 挂载路径不一致 | 确认 SCRIPT_DIR 路径在目标 nodeName 上存在 |
