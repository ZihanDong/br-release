# SGLang Server — BirenTech GPU 部署指南

本目录提供两种方式在 BirenTech GPU 节点上拉起 SGLang OpenAI 兼容推理服务：

| 方式 | 脚本 | 适用场景 |
|------|------|---------|
| **Docker** | `run_docker.sh` | 快速调试、单次运行 |
| **Kubernetes** | `k8s_yaml_gen.sh` + `k8s_apply.sh` | 生产部署、持久运行 |

---

## 架构说明

```
宿主机                                           容器内
┌──────────────────────────────────────┐        ┌─────────────────────────────────────┐
│ run_docker.sh [--run|default]         │        │ biren_entrypoint.sh (PID 1)         │
│  └ GPU 选择（brsmi）                 │ ─────► │  └ exec sleep infinity              │
│  └ 启动容器（sleep infinity）        │        │                                     │
│  └ 写入 run_sglang_*_server.sh        │        │ [--run]  exec run_sglang_*_server.sh│
│  [--run]  exec server + 轮询 /health  │        │   └ bash sglang_server.sh <conf>    │
│  [default] 进入交互式 shell            │        │       └ exec python3 -m sglang...   │
└──────────────────────────────────────┘        └─────────────────────────────────────┘

┌──────────────────────────────────┐  生成    k8s_yaml_gen/
│ k8s_yaml_gen.sh --task <type>    │ ──────► ├ <model>-pod.yaml
│  └ 节点探测 + 生成 YAML          │          └ <model>-deploy.yaml
└──────────────────────────────────┘
                    │ apply
                    ▼
┌──────────────────────────────────┐          ┌─────────────────────────────────────┐
│ k8s_apply.sh <yaml>              │          │ [deploy] bash sglang_server.sh <conf>│
│  [deploy] apply + 等待 Ready     │ kubectl  │   └ exec python3 -m sglang...        │
│           API 测试 + 打印命令    │ ──────►  │                                     │
│  [pod]    apply + 等待 Running   │          │ [pod]    sleep infinity              │
│           写 run script 到 pod   │          │   → 用户手动运行 run script          │
│           进入交互式 shell        │          └─────────────────────────────────────┘
└──────────────────────────────────┘
```

`sglang_server.sh` 挂载到容器中（Docker 通过 `/home` bind-mount，k8s 通过 hostPath volume），
由 BirenTech 镜像的 ENTRYPOINT（`biren_entrypoint.sh`）设置好 `LD_LIBRARY_PATH` 后调用。

---

## 目录结构

```
infer/llm/
├── model_registry.conf   # 模型库：本地路径 + HuggingFace/ModelScope ID（多框架共享）
└── sglang/
    ├── sglang_server.sh      # 容器内脚本：加载 conf → 查 registry → exec sglang
    ├── run_docker.sh         # Docker 外层：GPU 选择 + 容器启动；默认交互式，--run 直接拉起 server
    ├── k8s_yaml_gen.sh       # k8s YAML 生成器：--task pod|deploy，输出 YAML 到 k8s_yaml_gen/
    ├── k8s_apply.sh          # k8s 部署：apply YAML；deploy 自动测试，pod 进入交互式 shell
    ├── configs/
    │   └── qwen3-vl-32b.conf   # Qwen3-VL-32B（VL chat，端口 28800，k8s NodePort 30900）
    ├── k8s_yaml_gen/         # 生成的 k8s YAML（临时文件，可按需修改后应用）
    │   └── qwen3-vl-32b-deploy.yaml
    └── logs/                 # 启动日志（自动生成）
```

---

## 与 vLLM 的核心差异

| 维度 | vLLM | SGLang |
|------|------|--------|
| 启动模块 | `python3 -m vllm.entrypoints.openai.api_server` | `python3 -m sglang.launch_server` |
| 模型路径参数 | `--model` | `--model-path` |
| 张量并行 | `--tensor_parallel_size` | `--tp-size` |
| 流水线并行 | `--pipeline_parallel_size` | `--pp-size` |
| 显存占比 | `--gpu_memory_utilization` | `--mem-fraction-static` |
| 最大并发 | `--max_num_seqs` | `--max-running-requests` |
| 页大小 | 无 | `--page-size 128`（BirenTech 专用） |
| BirenTech env | `VLLM_USE_V1`, `VLLM_BR_*` | `BRTB_*` |
| k8s namespace | `vllm` | `sglang` |
| VL 模型额外参数 | 无 | `--disable-radix-cache`, `--trust-remote-code` |

---

## 前置条件

| 依赖 | 说明 |
|------|------|
| BirenTech GPU 驱动 | `/dev/biren/card_*` 设备文件存在 |
| `brsmi` | 用于查询 GPU 空闲状态（Docker 方式） |
| Docker | 需要 `sudo docker` 权限（Docker 方式） |
| `kubectl` | 需有 `~/.kube/config`（k8s 方式） |
| 模型权重 | 存放于 host 的 `/data/models/` 目录下 |
| SGLang 镜像 | `birensupa-smartinfer-sglang:26.04.rc2-py310-pt2.9.0-br1xx` |

**首次使用 k8s 方式前**，需将镜像推送到内网 registry：
```bash
sudo docker tag birensupa-smartinfer-sglang:26.04.rc2-py310-pt2.9.0-br1xx \
    172.25.198.36:32000/infer/birensupa-smartinfer-sglang:26.04.rc2-py310-pt2.9.0-br1xx
sudo docker push 172.25.198.36:32000/infer/birensupa-smartinfer-sglang:26.04.rc2-py310-pt2.9.0-br1xx
```

---

## 一、Docker 方式

### 1.1 启动命令

```bash
cd infer/llm/sglang
sudo bash run_docker.sh [--run] <config>
```

`<config>` 支持三种形式：

```bash
sudo bash run_docker.sh qwen3-vl-32b                    # 裸模型名
sudo bash run_docker.sh configs/qwen3-vl-32b.conf       # 相对路径
sudo bash run_docker.sh /abs/path/to/custom.conf         # 绝对路径
```

### 1.2 两种运行模式

| 模式 | 命令 | 行为 |
|------|------|------|
| **交互式**（默认） | `sudo bash run_docker.sh qwen3-vl-32b` | 启动容器后进入容器交互式 shell，用户手动运行 server 脚本 |
| **直接启动** | `sudo bash run_docker.sh --run qwen3-vl-32b` | 自动 exec server，宿主机轮询 `/health`，打印测试命令后退出 |

### 1.3 验证（curl 测试）

**文本对话：**
```bash
curl -s http://127.0.0.1:28800/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "Qwen/Qwen3-VL-32B-Instruct", "messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 64}' \
  | python3 -m json.tool
```

**图文多模态（base64 图片）：**
```python
import base64, json, subprocess

with open('/path/to/image.png', 'rb') as f:
    b64 = base64.b64encode(f.read()).decode()

payload = json.dumps({
    "model": "Qwen/Qwen3-VL-32B-Instruct",
    "messages": [{"role": "user", "content": [
        {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}},
        {"type": "text", "text": "描述这张图片的内容。"}
    ]}],
    "max_tokens": 128
})
```

### 1.4 容器管理

```bash
sudo docker logs -f sglang_qwen3-vl-32b
tail -f infer/llm/sglang/logs/sglang_qwen3-vl-32b_<timestamp>.log
sudo docker stop sglang_qwen3-vl-32b
sudo docker rm   sglang_qwen3-vl-32b
```

---

## 二、Kubernetes 方式

### 2.1 前置检查

```bash
kubectl get node -o jsonpath='{.items[0].status.allocatable.birentech\.com/gpu}'
kubectl get pods -n biren-gpu
kubectl get runtimeclass biren
```

### 2.2 两种任务类型

| 类型 | 命令 | YAML 文件 | 行为 |
|------|------|----------|------|
| **deploy** | `--task deploy` | `<model>-deploy.yaml` | Deployment + NodePort Service；自动启动 server，支持就绪探针 |
| **pod** | `--task pod` | `<model>-pod.yaml` | 单 Pod；容器 idle（sleep infinity），进入交互式 shell 手动启动 |

### 2.3 典型工作流

**Deployment 方式（生产推荐）：**

```bash
cd infer/llm/sglang

# Step 1：生成 YAML
bash k8s_yaml_gen.sh --task deploy --node brhost-01 qwen3-vl-32b
# → 保存到 k8s_yaml_gen/qwen3-vl-32b-deploy-node-brhost-01-p28800-r1.yaml

# Step 2：（可选）查看 YAML
cat k8s_yaml_gen/qwen3-vl-32b-deploy-node-brhost-01-p28800-r1.yaml

# Step 3：部署并自动测试 API
bash k8s_apply.sh k8s_yaml_gen/qwen3-vl-32b-deploy-node-brhost-01-p28800-r1.yaml
```

**Pod 方式（调试 / 手动控制）：**

```bash
bash k8s_yaml_gen.sh --task pod --node brhost-01 qwen3-vl-32b
bash k8s_apply.sh k8s_yaml_gen/qwen3-vl-32b-pod-node-brhost-01-p28800.yaml
# → Pod Running 后进入交互式 shell，手动运行：
# bash run_sglang_qwen3-vl-32b_server.sh
```

### 2.4 `k8s_yaml_gen.sh` 选项

```
bash k8s_yaml_gen.sh --task <pod|deploy> [选项] <config>

调度选项（互斥）：
  --node <nodename>      固定到指定节点（nodeName）
  --label <key=value>    节点标签选择器（nodeSelector）

资源选项：
  --cpu <n>              每副本 CPU 核数（默认 32，limit=2n）
  --mem-per-gpu <n>      每 GPU 内存 Gi（默认 128）

副本选项（仅 deploy）：
  --replicas <n>         副本数（默认 1）
```

输出文件命名规则：
```
k8s_yaml_gen/<model>-<type>[-node-<n>|-label-<v>]-p<port>[-r<replicas>].yaml
```

### 2.5 端口说明

| 模型 | containerPort | NodePort | 访问地址 |
|------|--------------|----------|---------|
| qwen3-vl-32b | 28800 | **30900** | `http://<node-ip>:30900` |

### 2.6 监控

```bash
kubectl get pods -n sglang -w
kubectl logs -n sglang -l app=sglang-qwen3-vl-32b -f
kubectl get svc,endpoints -n sglang
```

### 2.7 验证（NodePort）

```bash
# 若系统配置了 HTTP 代理，需加 --noproxy "*"
curl -s --noproxy "*" http://172.25.198.36:30900/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "Qwen/Qwen3-VL-32B-Instruct", "messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 64}' \
  | python3 -m json.tool
```

### 2.8 清理

```bash
# Deployment 方式
kubectl delete deployment/sglang-qwen3-vl-32b service/sglang-qwen3-vl-32b -n sglang
# Pod 方式
kubectl delete pod/sglang-qwen3-vl-32b -n sglang
# 全部清理
kubectl delete namespace sglang
```

---

## 三、配置文件说明

### 3.1 模型运行配置（`configs/*.conf`）

| 参数 | 必填 | 示例 | 说明 |
|------|------|------|------|
| `model_weights` | ✓ | `qwen3-vl-32b` | model_registry.conf 中的 section 名 |
| `port` | ✓ | `28800` | 服务监听端口 |
| `served_model_name` | — | `Qwen/Qwen3-VL-32B-Instruct` | API 中 model 字段；空 = 用权重路径 |
| `max_model_len` | ✓ | `32768` | 最大序列长度（context length） |
| `max_running_requests` | ✓ | `64` | 最大并发请求数 |
| `tensor_parallel_size` | ✓ | `4` | 张量并行数 |
| `pipeline_parallel_size` | ✓ | `1` | 流水线并行数（所需 GPU = tp × pp） |
| `mem_fraction_static` | ✓ | `0.85` | GPU 显存静态占比（模型权重 + KV cache）|
| `page_size` | ✓ | `128` | KV cache 分页大小（BirenTech 推荐 128）|
| `disable_radix_cache` | — | `true` | VL 多模态模型必须设为 `true` |
| `trust_remote_code` | — | `true` | Qwen3-VL 等模型需要 |
| `extra_env` | — | `"KEY=V1 KEY2=V2"` | 额外 env 变量，空格分隔的 KEY=VALUE 对 |
| `extra_sglang_args` | — | `"--enable-mixed-chunk"` | 额外 SGLang CLI 参数 |
| `k8s_nodeport` | k8s必填 | `30900` | k8s NodePort |

### 3.2 模型库（`infer/llm/model_registry.conf`，多框架共享）

```ini
[qwen3-vl-32b]
local_path=${ROOT_PATH}/Qwen/Qwen3-VL-32B-Instruct
download_name=Qwen/Qwen3-VL-32B-Instruct
```

---

## 四、新增模型

```bash
# 1. 在 infer/llm/model_registry.conf 添加条目
# 2. 复制并修改 conf 文件
cp configs/qwen3-vl-32b.conf configs/my-model.conf
# 修改 model_weights、port、tp/pp、k8s_nodeport 等

# 3. Docker 启动
sudo bash run_docker.sh --run my-model

# 4. k8s Deployment 部署
bash k8s_yaml_gen.sh --task deploy my-model
bash k8s_apply.sh k8s_yaml_gen/my-model-deploy-p<port>-r1.yaml

# 5. k8s Pod 交互式调试
bash k8s_yaml_gen.sh --task pod my-model
bash k8s_apply.sh k8s_yaml_gen/my-model-pod-p<port>.yaml
```

---

## 五、常见问题

### Docker 方式

| 现象 | 原因 | 解决 |
|------|------|------|
| `Docker image not found` | 本地无该镜像 | `sudo docker images` 确认镜像名，加载：`docker load -i /data/release/2604rc2/images/birensupa-smartinfer-sglang-*.tar` |
| `Not enough free GPUs` | GPU 被占用 | `brsmi gpu --query-gpu=index,memory.used --format=csv,noheader` 查看占用情况 |
| server 启动后 `/health` 无响应 | 模型仍在加载 | Qwen3-VL-32B（4 GPU）约需 2–3 分钟；检查日志直到出现 `The server is fired up and ready to roll!` |

### k8s 方式

| 现象 | 原因 | 解决 |
|------|------|------|
| `ImagePullBackOff` | 镜像未推送到内网 registry | 参考「前置条件」中的 `docker tag` + `docker push` 命令 |
| `ImportError: libbesu.so.1` | `biren-driver` hostPath volume 缺失 | 确认 YAML 中有 `biren-driver` volumeMount，hostPath 为 `/usr/local/birensupa/driver` |
| Pod 长时间 `0/1 Running` | readiness probe 初始延迟 | 正常，Qwen3-VL-32B（4 GPU）readiness initialDelaySeconds = 540s（约 9 min）|
| NodePort curl 返回 502 | HTTP 代理干扰 | 加 `--noproxy "*"` |
| `sglang_server.sh: not found` | hostPath 挂载路径不一致 | 确认 `--node` 指定的节点上存在 `SCRIPT_DIR` 路径 |
| VL 图片请求 timeout | 容器内无公网访问 | 改用 base64 编码的图片（`data:image/png;base64,...`） |
