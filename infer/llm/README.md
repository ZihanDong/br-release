# infer/llm — 统一推理服务框架（vLLM / SGLang）

在 BirenTech GPU 上以 **Docker** 或 **Kubernetes** 拉起 OpenAI 兼容推理服务。
vLLM 与 SGLang 共用一套配置目录、一个配置解析器、一套 k8s 生成/应用脚本，靠配置文件里的
`framework=` 字段区分框架。

## 目录结构

```
infer/llm/
├── model_registry.{sh,conf}     # 模型库：本地权重路径 + HF/ModelScope 下载名（多框架共享）
├── configs/                     # ★ 统一模型配置 + 生成的 k8s YAML
│   ├── vllm_<model>.conf          # framework=vllm
│   ├── sglang_<model>.conf        # framework=sglang
│   ├── pod/                       # k8s_yaml_gen --task pod 产物
│   └── deploy/                    # k8s_yaml_gen --task deploy 产物
├── utils/                       # ★ 跨框架工具
│   ├── parse_config.sh            # 解析/校验/补默认 + CLI（--list/--check/--check-all/--show）
│   ├── k8s_yaml_gen.sh            # 统一 k8s YAML 生成器（按 framework 分支）
│   ├── k8s_apply.sh              # 统一 k8s 应用器（deploy 自测 / pod 交互）
│   ├── conf_gen.sh               # 配置编辑器（按改动派生新文件名）
│   └── tests/test_k8s_yaml_gen.sh # 生成器单测（两框架）
├── vllm/
│   ├── vllm_server.sh            # 容器内：parse_config → 查 registry → exec vllm
│   ├── run_docker.sh             # Docker 外层：GPU 选择 + 端口检查 + 启动容器
│   ├── vllm_server_pd.sh proxy_server.sh proxy_conf/ configs/   # PD 分离部署（独立，未纳入统一体系）
│   └── quant/                    # 权重量化（FP8→BF16→INT8）
└── sglang/
    ├── sglang_server.sh          # 容器内：parse_config → 查 registry → exec sglang
    ├── run_docker.sh             # Docker 外层
    └── run_qwen-image.sh         # 多模态图像生成入口（launch_mode=multimodal_gen）
```

> PD（Prefill/Decode 分离）相关文件仍位于 `vllm/`（`*.p.conf`/`*.d.conf`、`proxy_conf/`、
> `vllm_server_pd.sh`、`proxy_server.sh`），是专门的双机方案，**未纳入**本统一配置/解析体系。

## 配置文件（`configs/<framework>_<model>.conf`）

`key=value` 文本，首个有效字段必须是 `framework=`：

```bash
framework=vllm                 # vllm | sglang | suinferllm（首个有效字段，必填）
model_weights=qwen3-vl-32b     # 对应 model_registry.conf 的 section 名
port=28802
...
k8s_image=...                  # 可选：k8s 镜像（缺省回落框架默认）
k8s_nodeport=30803             # k8s deploy 必填
```

- **必填项**（无默认，缺失即报错）：vLLM = `model_weights port tensor_parallel_size
  max_model_len max_num_seqs`；SGLang = 上述 + `max_running_requests`（`launch_mode=multimodal_gen`
  时放宽 `max_model_len/max_running_requests/pipeline_parallel_size`）。
- **可选项**：可留空或省略字段，由 `utils/parse_config.sh` 顶部的默认值表自动填入。

校验所有配置：
```bash
bash utils/parse_config.sh --check-all
bash utils/parse_config.sh --show vllm_qwen3-vl-32b   # 查看补全后的最终值
```

## 三种部署方式

```bash
cd infer/llm

# 1) Docker（快速调试）
sudo bash vllm/run_docker.sh   --run qwen3-vl-32b        # 解析 configs/vllm_qwen3-vl-32b.conf
sudo bash sglang/run_docker.sh --run qwen3-vl-32b        # 解析 configs/sglang_qwen3-vl-32b.conf

# 2) k8s Pod（交互式调试；容器 sleep，手动起 server）
bash utils/k8s_yaml_gen.sh --task pod    --gpu vllm_qwen3-vl-32b
bash utils/k8s_apply.sh    configs/pod/vllm_qwen3-vl-32b-pod-p28802.yaml

# 3) k8s Deployment（生产；自动起 server + 就绪探针 + NodePort）
bash utils/k8s_yaml_gen.sh --task deploy --gpu sglang_qwen3-vl-32b
bash utils/k8s_apply.sh    configs/deploy/sglang_qwen3-vl-32b-deploy-p28800-r1.yaml
```

`run_docker.sh` 用裸模型名时会自动补框架前缀（`vllm/run_docker.sh qwen3-vl-32b` →
`configs/vllm_qwen3-vl-32b.conf`），并校验 `framework=vllm` 匹配。三种方式核心都通过同源的
`vllm_server.sh` / `sglang_server.sh` 拉起，保证 Docker 与 k8s 行为一致。

### k8s GPU 资源模式（`k8s_yaml_gen.sh`，两框架通用，均经 hami-scheduler 调度）

| 模式 | 选项 | 资源 | 约束 |
|------|------|------|------|
| 整卡 | `--gpu` | `birentech.com/gpu = tp×pp` | — |
| SVI 硬切分 | `--svi 1in2` / `--svi 1in4` | `birentech.com/1-2-gpu`/`1-4-gpu = 1` | 需单卡配置(tp×pp=1) |
| vGPU 软切分 | `--vgpu-core <1-32> --vgpu-mem <1-64>` | `birentech.com/vgpu=1` + cores + memory(MB) | 需单卡配置(tp×pp=1) |

调度：`--node <name>` 固定节点 / `--label k=v` 标签选择 / 默认 `nodeSelector birentech.com=gpu`。
资源：`--cpu`（默认 32，limit=2×）、`--mem-per-gpu`（默认 128Gi/卡）；`--replicas`（仅 deploy）。

各框架的 Docker/k8s 细节、curl 验证、量化等见 `vllm/README.md` 与 `sglang/README.md`。
