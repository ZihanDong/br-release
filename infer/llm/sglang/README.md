# SGLang Server — BirenTech GPU 部署指南

> 统一布局总览见 [`../README.md`](../README.md)。模型配置集中在 `../configs/sglang_*.conf`
> （首行 `framework=sglang`），由 `../utils/parse_config.sh` 统一解析校验；k8s YAML 生成/应用用
> 跨框架的 `../utils/k8s_yaml_gen.sh` 和 `../utils/k8s_apply.sh`，产物落到 `../configs/{pod,deploy}/`。
> 本文档只讲 SGLang 专属内容。

本目录提供两种方式在 BirenTech GPU 节点上拉起 SGLang OpenAI 兼容推理服务：

| 方式 | 脚本 | 适用场景 |
|------|------|---------|
| **Docker** | `run_docker.sh` | 快速调试、单次运行 |
| **Kubernetes** | `../utils/k8s_yaml_gen.sh` + `../utils/k8s_apply.sh` | 生产部署、持久运行 |

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
├── configs/              # 统一模型配置（多框架共享）+ 生成的 k8s YAML
│   ├── sglang_qwen3-vl-32b.conf  # Qwen3-VL-32B（VL chat，端口 28800，k8s NodePort 30900）
│   ├── sglang_qwen-image.conf    # Qwen-Image-2512（多模态图像生成，端口 38000，NodePort 30901）
│   ├── pod/  deploy/             # k8s_yaml_gen.sh 产物
├── utils/                # 跨框架工具：parse_config.sh / k8s_yaml_gen.sh / k8s_apply.sh / conf_gen.sh
└── sglang/
    ├── sglang_server.sh        # 容器内启动器：parse_config → 查 registry → 经 sglang_launch.sh 拉起
    ├── sglang_launch.sh        # 启动逻辑单一来源：按 launch_mode 分支 env + 命令（docker/k8s 共用）
    ├── run_docker.sh           # Docker 外层：GPU 选择 + 端口检查 + 容器启动；默认交互式，--run 直接拉起 server
    ├── launch_multimodal_gen.py # multimodal_gen 通用入口（图像 + Wan 视频共用），spawn 安全；类比 LLM 的 python3 -m sglang.launch_server
    ├── wan_video_client.sh     # Wan2.2 视频测试客户端（POST /v1/videos → 轮询 → 下载）
    └── logs/                   # 启动日志（自动生成）
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
sudo bash run_docker.sh [--run] [--env <name>] [--env-list <file>] <config>
```

`<config>` 支持三种形式：

```bash
sudo bash run_docker.sh qwen3-vl-32b                    # 裸模型名
sudo bash run_docker.sh configs/qwen3-vl-32b.conf       # 相对路径
sudo bash run_docker.sh /abs/path/to/custom.conf         # 绝对路径
```

`--env <name>`（可选）从镜像清单 `sglang_images.list` 选一个基础镜像并执行其 `setup`
（容器启动后自动 `docker exec`），用于装齐镜像缺失的依赖；不带则用配置里的 `docker_image`、不做额外操作。
详见下文「§3.3 镜像清单」。Qwen-Image 必须带 `--env`（装 `cache_dit`）：

```bash
sudo bash run_docker.sh --run --env 2604-rc2 qwen-image   # 装 cache_dit 后拉起图像生成服务
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

> 统一生成器需要一个 GPU 资源模式（`--gpu` / `--svi` / `--vgpu-core+--vgpu-mem`，见 `../README.md`）。
> 配置用 `sglang_<model>`（裸名也行，生成器经 parser 自动定位 `../configs/sglang_<model>.conf`）。

**Deployment 方式（生产推荐）：**

```bash
cd infer/llm

# Step 1：生成 YAML（整卡模式；可选 --node 固定节点）
bash utils/k8s_yaml_gen.sh --task deploy --gpu --node brhost-01 sglang_qwen3-vl-32b
# → 保存到 configs/deploy/sglang_qwen3-vl-32b-deploy-node-brhost-01-p28800-r1.yaml

# Step 2：（可选）查看 YAML
cat configs/deploy/sglang_qwen3-vl-32b-deploy-node-brhost-01-p28800-r1.yaml

# Step 3：部署并自动测试 API
bash utils/k8s_apply.sh configs/deploy/sglang_qwen3-vl-32b-deploy-node-brhost-01-p28800-r1.yaml
```

**Pod 方式（调试 / 手动控制）：**

```bash
bash utils/k8s_yaml_gen.sh --task pod --gpu --node brhost-01 sglang_qwen3-vl-32b
bash utils/k8s_apply.sh configs/pod/sglang_qwen3-vl-32b-pod-node-brhost-01-p28800.yaml
# → Pod Running 后进入交互式 shell，手动运行：
# bash run_sglang_qwen3-vl-32b_server.sh
```

**带 `--env`（缺失依赖场景，如 Qwen-Image）：** `setup` 会被拼到容器自动运行命令最前面
（deploy：`<setup> && exec bash sglang_server.sh <conf>`；pod：`<setup>; exec sleep infinity`）。

```bash
bash utils/k8s_yaml_gen.sh --task deploy --gpu --node brhost-01 --env 2604-rc2 sglang_qwen-image
# k8s 用清单镜像名时需先让集群可达（push registry / ctr import 进节点 containerd），否则 ImagePullBackOff
bash utils/k8s_apply.sh configs/deploy/sglang_qwen-image-deploy-node-brhost-01-p38000-r1.yaml
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

基础镜像（可选；缺省用配置里的 k8s_image）：
  --env <name>           从 sglang_images.list 选基础镜像 + 注入其 setup 步骤
  --env-list <file>      指定清单文件（默认 sglang/sglang_images.list）
```

输出文件命名规则：
```
configs/{pod,deploy}/sglang_<model>-<type>[-svi-…|-vgpu-…][-node-<n>|-label-<v>]-p<port>[-r<replicas>].yaml
```

### 2.5 端口说明

| 模型 | containerPort | NodePort | 访问地址 |
|------|--------------|----------|---------|
| qwen3-vl-32b | 28800 | **30900** | `http://<node-ip>:30900` |
| qwen-image | 38000 | **30901** | `http://<node-ip>:30901` |
| wan2.2-t2v-a14b | 39000 | **30902** | `http://<node-ip>:30902` |
| wan2.2-i2v-a14b | 39001 | **30903** | `http://<node-ip>:30903` |

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

### 3.3 镜像清单（`sglang_images.list`，配合 `--env`）

把「镜像缺失依赖的安装步骤」从脚本里挪到声明式清单（`utils/parse_image_list.sh` 解析），
`run_docker.sh` / `k8s_yaml_gen.sh` 用 `--env <name>` 选用。每段：

```ini
[2604-rc2]                                                                # --env 检索名
image = birensupa-smartinfer-sglang:26.06.02-c059s001t004b24295-...        # 镜像名
desc  = 26.06 RC2 multimodal_gen build; Qwen-Image needs cache_dit          # 描述
setup = python3 -m pip install --no-input cache-dit==1.3.4                   # 容器内步骤；可多行(重复 setup=，按 && 串联)，留空不执行
```

执行时机：Docker 容器启动后 `docker exec`；k8s 拼到容器自动运行命令最前。`#` 开头为注释；
`setup` 命令里勿用双引号（k8s 会把它放进双引号 YAML 参数）。**Qwen-Image** 的 cache_dit 即由此提供，
所以不再需要在 `sglang_server.sh` 里写依赖安装逻辑。

> k8s 用清单里的裸镜像名时，containerd 会按 `docker.io/library/<image>` 解析；务必先 push 到内网
> registry 或 `sudo ctr -n k8s.io images import` 进目标节点，否则 `ImagePullBackOff`。

---

## 四、新增模型

```bash
# 1. 在 infer/llm/model_registry.conf 添加条目
# 2. 复制并修改 conf 文件
cp ../configs/sglang_qwen3-vl-32b.conf ../configs/sglang_my-model.conf
# 修改 framework(=sglang 保持)、model_weights、port、tp/pp、k8s_nodeport 等

# 3. Docker 启动
sudo bash run_docker.sh --run my-model

# 4. k8s Deployment 部署（从 infer/llm 目录）
cd ..
bash utils/k8s_yaml_gen.sh --task deploy --gpu sglang_my-model
bash utils/k8s_apply.sh configs/deploy/sglang_my-model-deploy-p<port>-r1.yaml

# 5. k8s Pod 交互式调试
bash utils/k8s_yaml_gen.sh --task pod --gpu sglang_my-model
bash utils/k8s_apply.sh configs/pod/sglang_my-model-pod-p<port>.yaml
```

---

## 五、Wan2.2 视频生成（video_gen 模式）

Wan2.2（T2V / I2V）走 `launch_mode=video_gen`：在线服务用的是和离线
`testcase_wan.py` **完全相同**的 `sglang.multimodal_gen` 运行时
——离线 `DiffGenerator` 调 `launch_server(..., launch_http_server=False)`，
在线只是 `launch_http_server=True`，多出 OpenAI 兼容的 `/v1/videos` 端点，
**无需修改框架**。容器内入口为 `server_sglang_video.sh`（Python，与图像入口
`launch_multimodal_gen.py` 同类），由 `sglang_launch.sh` 的 video_gen 分支构建命令、
经 `sglang_server.sh` 拉起。

### 5.1 前置：权重格式 + 依赖

- **权重必须是 diffusers 格式**（目录含 `model_index.json`）：
  `Wan-AI/Wan2.2-T2V-A14B-Diffusers` / `Wan-AI/Wan2.2-I2V-A14B-Diffusers`。
  ModelScope 版（`high_noise_model/low_noise_model/*.pth`，无 `model_index.json`）
  **离线、在线都无法直接加载**。`model_registry.conf` 已登记 `-Diffusers` 路径。
- **cache_dit 必须是 1.3.4**（镜像未预装；最新 1.3.10 缺 `cache_dit.parallelism`）：
  `pip install --no-deps cache_dit==1.3.4`。video_gen 启动时（`sglang_launch.sh` 的 LAUNCH_PRE）已自动安装。
- **专用镜像必须用 c064（Wan 自己的构建）**：
  `birensupa-smartinfer-sglang:26.06.02-c064s001t001b24295-py310-pt2.9.0-br1xx`
  （`docker load -i /data/release/siming-0602/birensupa-smartinfer-sglang-26.06.02-c064*.tar`）。
  **不要用 c059**（qwen-image 的构建）——它跑不了 Wan 的 UMT5 文本编码器（`RMSNormInfer` /
  `Colmajor 2D` 报错）。

下面这些 Wan 专属坑已在脚本里**自动处理**（无需手动操作），列出以备排障：

- **`br_generator` / PYTHONPATH**：VAE decode 时 SUDNN 要 JIT 编译卷积核，需 import
  `br_generator`（在 SDK 的 `.../sulib/lib`，由镜像 ENTRYPOINT 写进 PID1 的 PYTHONPATH）。
  但 `docker exec` 不继承 ENTRYPOINT 环境，缺它会 `No module named 'br_generator'` → SUDNN
  `build graph failed`。`run_docker.sh` 的 run script 现在把 **PID1 整套环境**（PYTHONPATH/
  LD_LIBRARY_PATH/PATH…）透传进来，不再只传 LD_LIBRARY_PATH。**离线 / 在线同此坑**。
- **VAE 用 bf16 + 关并行 decode**：`sglang_launch.sh` 给 video_gen 加 `--vae-precision bf16`；
  `launch_multimodal_gen.py` 对 Wan 管线把 `vae_config.use_parallel_{encode,decode}=False`
  （否则分别 `SliceNcdhwDAxis` 无后端 / `split_for_parallel_decode` 未定义）。与离线
  `testcase_wan.py` 的 `vae_config` 一致。
- **文本编码器在 GPU**（`text_encoder_cpu_offload=False`，c064 上 RMSNorm 正常）；本地 7890
  代理会把 `127.0.0.1:39000` 变 502，`wan_video_client.sh` 已自动 `no_proxy` 绕过。

> 验证：4 步 t2v 在线全链路已跑通（c064，4 卡 cfg2，832×480 → mp4；首次 ~207s，含 VAE 核 JIT 编译）。
> 8 卡 cfg2 t2v / i2v 也各自跑通**首个请求**（1280×720，10 步：t2v infer≈385s / i2v≈791s，峰值≈63GB）。

> ⚠️ **已知限制 — 多请求**：当前 c064 构建里，**同一 server 的第 2 个请求会失败**
> （`PtOpIRBuilder: Input is not on SUPA and not host scalar!`，发生在 TextEncodingStage 的
> embedding）。根因是第 1 个请求里 dit/vae 的 CPU offload 把 SUPA 设备态搞乱，第 2 个请求
> 取 `input_ids` 时落在 host 上。离线 `testcase_wan.py` 每次新进程跑一个生成，从不复用，所以
> 碰不到——这是**有状态在线服务路径**才暴露的 vendor runtime bug。`text_encoder_cpu_offload=True`
> 反而让第 1 个请求也挂；offload 又因 28B 模型在 65GB 卡上放不下而无法关闭。**单请求可用；多请求
> 待 BirenTech / sglang-br 修**（每请求重置 SUPA 设备上下文 / 修复 offload 后的设备态）。性能压测
> 脚本 `wan_video_perf.sh` 因此只能拿到 warm-up（首请求，含 JIT 编译）的数。

### 5.2 并行度（config 字段）

`tensor_parallel_size` = **要分配的总卡数**，必须等于
`ulysses_degree × ring_degree × (enable_cfg_parallel ? 2 : 1)`；模型内部 TP 固定为 1。
8 卡两种布局：

| 布局 | ulysses_degree | ring_degree | enable_cfg_parallel | 总卡 |
|------|----------------|-------------|---------------------|------|
| **cfg2（默认）** | 4 | 1 | true  | 8 |
| ring2 | 4 | 2 | false | 8 |

t2v / i2v 由权重的 `model_index.json` 自动判别，无需任务参数；i2v 请求必须带输入图。
扩散步数、prompt、分辨率、首帧图都是**逐请求**参数（`POST /v1/videos`），不是启动参数。

### 5.3 启动 + 4 步快速验证

```bash
cd infer/llm/sglang

# 直接拉起 t2v 服务（宿主机轮询 /health，就绪后打印测试命令）
sudo bash run_docker.sh --run wan2.2-t2v-a14b

# 4 步冒烟（t2v）
bash wan_video_client.sh --port 39000 --steps 4 \
  --prompt "a white cat wearing sunglasses on a surfboard" --size 832x480

# i2v：换 wan2.2-i2v-a14b（端口 39001），请求带首帧图
sudo bash run_docker.sh --run wan2.2-i2v-a14b
bash wan_video_client.sh --port 39001 --steps 4 --image /path/to/first.jpg \
  --prompt "the cat turns its head and smiles"
```

`wan_video_client.sh` 提交任务 → 轮询 `GET /v1/videos/<id>` → 完成后从
`/v1/videos/<id>/content` 下载 mp4（服务端也会存到 `output_path`）。

### 5.4 直接 curl

```bash
# 提交（t2v，4 步）
curl -s -X POST http://127.0.0.1:39000/v1/videos -H 'Content-Type: application/json' \
  -d '{"prompt":"a white cat on a surfboard","size":"832x480","num_inference_steps":4,"num_frames":81,"seed":1024}'
# → {"id":"<vid>","status":"queued",...}

# 轮询 / 下载
curl -s http://127.0.0.1:39000/v1/videos/<vid> | python3 -m json.tool
curl -s http://127.0.0.1:39000/v1/videos/<vid>/content -o out.mp4
```

> i2v 请求加 `"reference_url":"/abs/path/first.jpg"`（或 `input_reference`）；
> 缺图会被服务端拒绝（400）。`num_frames-1` 须能被 4 整除（81、61、21…）。

---

## 六、常见问题

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
