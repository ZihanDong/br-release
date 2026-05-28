---
name: sglang
description: Start and manage SGLang OpenAI-compatible inference servers on BirenTech GPU nodes. Covers Docker and Kubernetes deployments, model registry management, GPU selection, VL multimodal models, and troubleshooting. Read this skill before launching any SGLang server.
metadata:
  type: skill
  tags: [sglang, inference, birentech, gpu, docker, kubernetes, llm, vl, multimodal, vision-language]
  scripts:
    - infer/llm/sglang/sglang_server.sh
    - infer/llm/sglang/run_docker.sh
    - infer/llm/sglang/k8s_yaml_gen.sh
    - infer/llm/sglang/k8s_apply.sh
    - infer/llm/model_registry.conf
    - infer/llm/sglang/configs/qwen3-vl-32b.conf
---

# Skill: sglang

## Script / File Map

| 文件 | 运行位置 | 说明 |
|------|---------|------|
| `sglang_server.sh` | **容器内** | 加载 conf → 查 registry → exec SGLang；被 Docker/k8s 统一调用 |
| `run_docker.sh` | 宿主机 | GPU 选择（brsmi）+ 启动容器；默认交互式 shell，`--run` 直接拉起 server |
| `k8s_yaml_gen.sh` | 宿主机 | 生成 k8s YAML 到 `k8s_yaml_gen/<model>-<type>.yaml`，`--task pod\|deploy`，不执行 apply |
| `k8s_apply.sh` | 宿主机 | `kubectl apply <yaml>`；deploy 自动等待 Ready + API 测试；pod 进入交互式 shell |
| `../model_registry.conf` | — | 模型库：本地权重路径 + HF/MS 下载 ID（位于 `infer/llm/`，多框架共享） |
| `configs/<model>.conf` | — | 每个模型的运行参数；Docker 和 k8s 共用同一套配置 |

**架构原则：**
- 与 vLLM 目录完全对称；所有 SGLang 参数逻辑集中在 `sglang_server.sh`
- 外层脚本只负责容器编排，不重复构建 SGLang 命令
- 容器统一以 `sleep infinity` 启动，server 由 run script 或用户手动触发
- k8s 分两步：先生成 YAML（可检查/修改），再部署；pod/deploy 通过 `--task` 区分
- 新增模型只需一个 conf 文件，无需修改任何脚本

**与 vLLM 的关键参数差异（重要：勿混淆）：**

| 概念 | vLLM 参数 | SGLang 参数 |
|------|----------|------------|
| 模型路径 | `--model` | `--model-path` |
| 张量并行 | `--tensor_parallel_size` | `--tp-size` |
| 流水线并行 | `--pipeline_parallel_size` | `--pp-size` |
| 显存占比 | `--gpu_memory_utilization` | `--mem-fraction-static` |
| 最大并发 | `--max_num_seqs` | `--max-running-requests` |
| BirenTech env | `VLLM_USE_V1`, `VLLM_BR_*` | `BRTB_PLAN_ID_RENEW`, `BRTB_DISABLE_*`, `BRTB_ENABLE_*` |
| k8s namespace | `vllm` | `sglang` |
| k8s annotation | `vllm.io/config-file` | `sglang.io/config-file` |

已部署模型端口一览：

| 模型 | 类型 | Docker 端口 | k8s NodePort | GPU 数 |
|------|------|------------|-------------|--------|
| qwen3-vl-32b | VL chat | 28800 | 30900 | 4 (tp=4) |

---

## 1 — Docker 方式启动

### 1.1 启动命令

```bash
cd infer/llm/sglang
sudo bash run_docker.sh [--run] <config>
```

`<config>` 接受：裸模型名（`qwen3-vl-32b`）、相对路径、绝对路径。

### 1.2 两种模式

| 模式 | 命令 | 行为 |
|------|------|------|
| **交互式**（默认） | `sudo bash run_docker.sh qwen3-vl-32b` | 容器 idle，进入 bash shell，手动运行 `bash run_sglang_qwen3-vl-32b_server.sh` |
| **直接启动** | `sudo bash run_docker.sh --run qwen3-vl-32b` | 自动 exec server，宿主机轮询 `/health`，打印测试命令后退出 |

两种模式均会将 `run_sglang_<model>_server.sh` 写入 `logs/` 目录（通过 `/home` bind-mount 对容器可见）。

输出示例（`--run` 模式）：
```
[INFO]  Config      : qwen3-vl-32b.conf  [mode=--run]
[INFO]  Model key   : qwen3-vl-32b  |  port=28800  |  tp=4  pp=1
[ OK ]  Weights     : /data/models/Qwen/Qwen3-VL-32B-Instruct
[INFO]  GPU needed  : tp=4 × pp=1 = 4
[ OK ]  GPUs        : [0,1,2,3]  (card_0 card_1 card_2 card_3 )
[INFO]  Container   : sglang_qwen3-vl-32b
[ OK ]  Container started.
[ OK ]  Run script  : .../logs/run_sglang_qwen3-vl-32b_server.sh
[INFO]  Starting SGLang server (logs → ...)
        .....
[ OK ]  SGLang server ready — sglang_qwen3-vl-32b  :28800
```

### 1.3 查看日志

```bash
sudo docker logs -f sglang_qwen3-vl-32b
tail -f infer/llm/sglang/logs/sglang_qwen3-vl-32b_<timestamp>.log
```

SGLang 就绪标志：日志出现 `The server is fired up and ready to roll!`

### 1.4 停止 / 重启

```bash
sudo docker stop sglang_qwen3-vl-32b && sudo docker rm sglang_qwen3-vl-32b
# 重启：脚本自动删除同名旧容器
sudo bash run_docker.sh qwen3-vl-32b
```

### 1.5 验证（curl 测试）

**文本对话：**
```bash
curl -s http://127.0.0.1:28800/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "Qwen/Qwen3-VL-32B-Instruct", "messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 64}' \
  | python3 -m json.tool
```

**图文多模态（base64，容器内无公网时必须用此方式）：**
```bash
python3 -c "
import base64, json
with open('/path/to/image.png','rb') as f:
    b64 = base64.b64encode(f.read()).decode()
payload = {
    'model': 'Qwen/Qwen3-VL-32B-Instruct',
    'messages': [{'role':'user','content':[
        {'type':'image_url','image_url':{'url':f'data:image/png;base64,{b64}'}},
        {'type':'text','text':'描述这张图片的内容。'}
    ]}],
    'max_tokens': 128
}
print(json.dumps(payload))
" | curl -s http://127.0.0.1:28800/v1/chat/completions \
  -H 'Content-Type: application/json' -d @- | python3 -m json.tool
```

---

## 2 — Kubernetes 方式启动

### 2.1 前置：镜像推送（首次使用）

k8s 节点使用 containerd 从内网 registry 拉取镜像。首次使用前需推送：

```bash
sudo docker tag birensupa-smartinfer-sglang:26.04.rc2-py310-pt2.9.0-br1xx \
    172.25.198.36:32000/infer/birensupa-smartinfer-sglang:26.04.rc2-py310-pt2.9.0-br1xx
sudo docker push 172.25.198.36:32000/infer/birensupa-smartinfer-sglang:26.04.rc2-py310-pt2.9.0-br1xx
```

验证推送成功：
```bash
curl -s http://172.25.198.36:32000/v2/_catalog | python3 -m json.tool
# 应包含 "infer/birensupa-smartinfer-sglang"
```

### 2.2 前置检查

```bash
kubectl get node -o jsonpath='{.items[*].status.allocatable.birentech\.com/gpu}'
kubectl get pods -n biren-gpu
kubectl get runtimeclass biren
```

### 2.3 典型工作流

**Deployment 方式（生产）：**

```bash
cd infer/llm/sglang

# Step 1: 生成 YAML（固定到指定节点，确保 hostPath 有效）
bash k8s_yaml_gen.sh --task deploy --node brhost-01 qwen3-vl-32b
# → 输出: k8s_yaml_gen/qwen3-vl-32b-deploy-node-brhost-01-p28800-r1.yaml

# Step 2: 部署并自动测试
bash k8s_apply.sh k8s_yaml_gen/qwen3-vl-32b-deploy-node-brhost-01-p28800-r1.yaml
```

`k8s_apply.sh` 会：
1. `kubectl apply -f <yaml>`
2. 轮询 Pod readiness（readinessProbe initialDelay = 540s，约等 9 min）
3. 就绪后自动 curl smoke test（chat completion）
4. 打印管理命令

**Pod 方式（调试 / 手动控制）：**

```bash
bash k8s_yaml_gen.sh --task pod --node brhost-01 qwen3-vl-32b
# → 输出: k8s_yaml_gen/qwen3-vl-32b-pod-node-brhost-01-p28800.yaml

bash k8s_apply.sh k8s_yaml_gen/qwen3-vl-32b-pod-node-brhost-01-p28800.yaml
# → Pod Running 后写入 run script，进入交互式 shell
# 在 shell 内执行：
# bash run_sglang_qwen3-vl-32b_server.sh
```

Pod 方式 server 启动后，通过 **pod IP** 访问（无 NodePort Service）：
```bash
POD_IP=$(kubectl get pod sglang-qwen3-vl-32b -n sglang -o jsonpath='{.status.podIP}')
curl -s --noproxy "*" "http://${POD_IP}:28800/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen3-VL-32B-Instruct","messages":[{"role":"user","content":"Hello"}],"max_tokens":32}' \
  | python3 -m json.tool
```

### 2.4 监控进度

```bash
kubectl get pods -n sglang -w
kubectl logs -n sglang -l app=sglang-qwen3-vl-32b -f
kubectl get svc,endpoints -n sglang
```

### 2.5 验证（Deployment NodePort）

```bash
# brhost-01 = 172.25.198.36，NodePort 30900
curl -s --noproxy "*" http://172.25.198.36:30900/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "Qwen/Qwen3-VL-32B-Instruct", "messages": [{"role": "user", "content": "Hello!"}], "max_tokens": 64}' \
  | python3 -m json.tool
```

### 2.6 清理

```bash
# Deployment 方式
kubectl delete deployment/sglang-qwen3-vl-32b service/sglang-qwen3-vl-32b -n sglang
# Pod 方式
kubectl delete pod/sglang-qwen3-vl-32b -n sglang
# 全部清理
kubectl delete namespace sglang
```

---

## 3 — 配置文件格式

### 3.1 `configs/<model>.conf` 参数说明

| 参数 | 必填 | 示例 | 说明 |
|------|------|------|------|
| `model_weights` | ✓ | `qwen3-vl-32b` | model_registry.conf 中的 section 名 |
| `port` | ✓ | `28800` | 服务监听端口 |
| `served_model_name` | — | `Qwen/Qwen3-VL-32B-Instruct` | API 中 model 字段；空 = 用权重路径 |
| `max_model_len` | ✓ | `32768` | 最大序列长度 |
| `max_running_requests` | ✓ | `64` | 最大并发请求数 |
| `tensor_parallel_size` | ✓ | `4` | 张量并行数 |
| `pipeline_parallel_size` | ✓ | `1` | 流水线并行数（所需 GPU = tp × pp） |
| `mem_fraction_static` | ✓ | `0.85` | GPU 显存静态占比 |
| `page_size` | ✓ | `128` | KV cache 页大小（BirenTech 推荐 128） |
| `disable_radix_cache` | — | `true` | **VL 模型必须设为 `true`** |
| `trust_remote_code` | — | `true` | Qwen3-VL 等需要 |
| `extra_env` | — | `"KEY=V"` | 额外 env 变量，空格分隔的 KEY=VALUE |
| `extra_sglang_args` | — | `"--enable-mixed-chunk"` | 额外 SGLang CLI 参数 |
| `k8s_nodeport` | k8s必填 | `30900` | k8s NodePort（deploy 类型必填） |

**所需 GPU 数 = `tensor_parallel_size × pipeline_parallel_size`**

### 3.2 `infer/llm/model_registry.conf` 格式

```ini
[<model_name>]
local_path=<权重绝对路径>   # 支持 ${ROOT_PATH} 变量
download_name=<org/repo>    # HuggingFace 和 ModelScope 共用同一 ID
```

---

## 4 — 常见问题

### Docker 方式

| 现象 | 原因 | 解决 |
|------|------|------|
| `Docker image not found` | 本地无该镜像 | `docker load -i /data/release/2604rc2/images/birensupa-smartinfer-sglang-26.04.rc2-py310-pt2.9.0-br1xx.tar` |
| `Not enough free GPUs` | GPU 被占用 | `brsmi gpu --query-gpu=index,memory.used --format=csv,noheader` |
| `/health` 轮询超时 | 模型加载慢 | Qwen3-VL-32B（4 GPU）约 2–3 min；`tail -f logs/sglang_*` 查看进度 |
| 图片 URL timeout | 容器无公网 | 改用 `data:image/png;base64,...` 格式 |

### k8s 方式

| 现象 | 原因 | 解决 |
|------|------|------|
| `ImagePullBackOff` | 镜像未推到 registry | 执行 **2.1 镜像推送** 步骤 |
| `ImportError: libbesu.so.1` | `biren-driver` hostPath 缺失 | 确认 YAML 中有 `biren-driver` volume，hostPath 为 `/usr/local/birensupa/driver` |
| Pod 长时间 `0/1 Running` | readiness probe 正常等待 | Qwen3-VL-32B initialDelay=540s，属正常；`kubectl logs -n sglang -l app=... -f` 监控 |
| NodePort 返回 502 | HTTP 代理 | 加 `--noproxy "*"` |
| `sglang_server.sh: not found` | hostPath 路径在目标节点不存在 | 用 `--node` 指定脚本所在节点；或手动同步脚本目录 |
| `Failed to parse CONFIG_FILE` | YAML 注解缺失 | 确认 YAML 来自 `k8s_yaml_gen.sh`，含 `sglang.io/config-file` 注解 |
