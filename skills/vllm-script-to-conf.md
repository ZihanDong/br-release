---
name: vllm-script-to-conf
description: Convert a raw vLLM launch script (start_<model>.sh) into a structured conf file under infer/llm/vllm/configs/ and update infer/llm/model_registry.conf if needed. Read this skill before performing any such conversion.
metadata:
  type: skill
  tags: [vllm, config, migration, inference, birentech]
  related_files:
    - infer/llm/vllm/configs/bge-m3.conf
    - infer/llm/vllm/configs/qwen3-32b.conf
    - infer/llm/model_registry.conf
    - infer/llm/vllm/vllm_server.sh
---

# Skill: vllm-script-to-conf

将形如 `start_<model>.sh` 的原始 vLLM 启动脚本转换为 `infer/llm/vllm/configs/<model>.conf` 格式，以便 `run_docker.sh` 和 `k8s_yaml_gen.sh` 统一调用。

---

## 1 — 参数映射表

| 脚本中的内容 | conf 字段 | 说明 |
|------------|---------|------|
| `--port <n>` | `port=<n>` | 服务监听端口 |
| `--model <path>` | `model_weights=<key>` | 用路径在 `infer/llm/model_registry.conf` 中查找 section 名；见第 2 节 |
| `--served_model_name <name>` | `served_model_name=<name>` | 缺失则留空 |
| `--task <type>` | `task=<type>` | embed 模型必须设为 `embed`；对话模型留空 |
| `--dtype <type>` | `dtype=<type>` | |
| `--max_model_len <n>` | `max_model_len=<n>` | |
| `--max_num_seqs <n>` | `max_num_seqs=<n>` | |
| `--tensor_parallel_size <n>` | `tensor_parallel_size=<n>` | |
| `--pipeline_parallel_size <n>` | `pipeline_parallel_size=<n>` | |
| `--gpu_memory_utilization <f>` | `gpu_memory_utilization=<f>` | |
| `--enable_chunked_prefill`（flag，无值）| `enable_chunked_prefill=true` | 缺失则写 `false` |
| `--enforce_eager`（flag，无值）| `enforce_eager=true` | 缺失则写 `false` |
| `--distributed_executor_backend <name>` | `distributed_executor_backend=<name>` | 缺失则留空 |
| `--compilation_config '<json>'` | `compilation_config='<json>'` | 保留单引号包裹 |

**模型特有扩展字段**（如有以下情况需额外添加）：

| 脚本中的内容 | conf 字段 | 说明 |
|------------|---------|------|
| 脚本开头 `export KEY=VALUE` 且非 `VLLM_USE_V1/VLLM_WORKER_MULTIPROC_METHOD/VLLM_BR_WEIGHT_TYPE` | `extra_env="KEY1=V1 KEY2=V2"` | 空格分隔，整体加双引号 |
| `--enable_expert_parallel` / `--no_enable_prefix_caching` 等非标准 flag | `extra_vllm_args="--flag1 --flag2"` | 整体加双引号 |

**忽略**（`vllm_server.sh` 已内置或不需要）：
- `--host` — 脚本固定使用 `0.0.0.0`
- `--trust_remote_code` — 脚本默认传递
- `--data_parallel_size` — 当前架构不使用
- `--kv_cache_dtype` — 当前架构不使用
- `VLLM_USE_V1=1 VLLM_WORKER_MULTIPROC_METHOD=spawn VLLM_BR_WEIGHT_TYPE=NUMA` — `vllm_server.sh` 已 export

**手动填写**（脚本中不存在）：
- `k8s_nodeport=` — k8s NodePort 端口，需手动指定（参考已有模型：bge-m3=30800, qwen3-32b=30801，新模型递增）
- `k8s_node_name=` — 留空即自动探测

---

## 2 — 确定 model_weights 键名

`model_weights` 是 `infer/llm/model_registry.conf` 中的 section 名称（`[...]`），不是路径。

**步骤：**
1. 从 `--model <path>` 取出路径，例如 `/data/models/BAAI/bge-m3`
2. 读取 `infer/llm/model_registry.conf`，在 `local_path` 字段中匹配该路径
3. 找到对应的 section 名作为 `model_weights` 的值

**若路径未在 registry 中登记**，需先追加一个新 section：

```ini
[<model-key>]
local_path=<权重绝对路径>
huggingface_id=<org/repo>    # 可从 HuggingFace 页面获取，不知道留空
modelscope_id=<org/repo>     # 可从 ModelScope 页面获取，不知道留空
```

`<model-key>` 建议使用小写短横线格式，如 `llama3-8b`、`qwen2-7b`。

---

## 3 — conf 文件模板

```bash
# vLLM server config — <HF org/model name> (<model type>)
# Used by: run_docker.sh  k8s_yaml_gen.sh

model_weights=<registry section name>

port=28800
served_model_name=          # OpenAI API 中的模型名；空 = 使用权重路径
task=                       # embed（嵌入模型）或留空（对话模型）
dtype=auto

max_model_len=8192
max_num_seqs=64

tensor_parallel_size=1
pipeline_parallel_size=1    # 所需 GPU 数 = tp × pp
gpu_memory_utilization=0.8

enable_chunked_prefill=false
enforce_eager=false
distributed_executor_backend=
compilation_config=         # 如有 JSON，用单引号包裹：'{"key": "val"}'

# Kubernetes 专属（Docker 方式忽略）
k8s_nodeport=               # 必填，新模型在已有端口基础上 +1
k8s_node_name=              # 留空 = 自动探测
```

---

## 4 — 完整转换示例

### 原始脚本 `start_bge-m3.sh`

```bash
VLLM_USE_V1=1 VLLM_WORKER_MULTIPROC_METHOD=spawn VLLM_BR_WEIGHT_TYPE=NUMA \
python3 -m vllm.entrypoints.openai.api_server --host 127.0.0.1 --port 28800 \
    --model /data/models/BAAI/bge-m3 \
    --task embed \
    --trust_remote_code \
    --dtype bfloat16 \
    --max_model_len 8192 \
    --enforce_eager \
    --pipeline_parallel_size 1 \
    --tensor_parallel_size 1 \
    --data_parallel_size 1 \
    --gpu_memory_utilization 0.8 \
    --kv_cache_dtype auto \
    --max_num_seqs 64
```

### 转换后 `configs/bge-m3.conf`

```bash
# vLLM server config — BAAI/bge-m3 (embedding model)
# Used by: run_docker.sh  k8s_yaml_gen.sh

model_weights=bge-m3        # /data/models/BAAI/bge-m3 → registry section [bge-m3]

port=28800
served_model_name=
task=embed
dtype=bfloat16

max_model_len=8192
max_num_seqs=64

tensor_parallel_size=1
pipeline_parallel_size=1
gpu_memory_utilization=0.8

enable_chunked_prefill=false
enforce_eager=true
distributed_executor_backend=
compilation_config=

k8s_nodeport=30800
k8s_node_name=
```

**被忽略的参数：** `--host 127.0.0.1`、`--trust_remote_code`、`--data_parallel_size 1`、`--kv_cache_dtype auto`、环境变量前缀。

---

### 原始脚本 `start_qwen3-32b.sh`

```bash
VLLM_USE_V1=1 VLLM_WORKER_MULTIPROC_METHOD=spawn VLLM_BR_WEIGHT_TYPE=NUMA \
python3 -m vllm.entrypoints.openai.api_server --host 127.0.0.1 --port 28800 \
    --served_model_name Qwen/Qwen3-32B \
    --model /data/models/Qwen/Qwen3-32B/ \
    --trust_remote_code \
    --dtype auto \
    --kv_cache_dtype auto \
    --distributed_executor_backend mp \
    --tensor_parallel_size 2 \
    --pipeline_parallel_size 1 \
    --data_parallel_size 1 \
    --max_model_len 32768 \
    --gpu_memory_utilization 0.8 \
    --max_num_seqs 64 \
    --enable_chunked_prefill \
    --compilation_config '{"cudagraph_mode": "FULL_DECODE_ONLY"}'
```

### 转换后 `configs/qwen3-32b.conf`

```bash
# vLLM server config — Qwen/Qwen3-32B (chat model)
# Used by: run_docker.sh  k8s_yaml_gen.sh

model_weights=qwen3-32b     # /data/models/Qwen/Qwen3-32B → registry section [qwen3-32b]

port=28800
served_model_name=Qwen/Qwen3-32B
task=
dtype=auto

max_model_len=32768
max_num_seqs=64

tensor_parallel_size=2
pipeline_parallel_size=1
gpu_memory_utilization=0.8

enable_chunked_prefill=true
enforce_eager=false
distributed_executor_backend=mp
compilation_config='{"cudagraph_mode": "FULL_DECODE_ONLY"}'

k8s_nodeport=30801
k8s_node_name=
```

---

## 5 — 转换后验证

生成 conf 后，用 Docker 方式快速验证参数是否正确被读取：

```bash
cd infer/llm/vllm
sudo bash run_docker.sh <model-key>
```

若仅想检查配置是否能被解析（无需真正启动）：

```bash
source infer/llm/vllm/configs/<model>.conf
echo "model=$model_weights port=$port tp=$tensor_parallel_size pp=$pipeline_parallel_size"
```
