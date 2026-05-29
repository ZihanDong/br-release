# vLLM Load Balancer

OpenAI API 兼容的 Round-Robin 负载均衡服务，将对某个模型的请求均匀分发到多个 vLLM 后端。

## 目录结构

```
load_balance/
├── Dockerfile                  # 基于 python:3.11-slim，内置所有 Python 依赖
├── lb_server.py                # 负载均衡服务主体（FastAPI + aiohttp）
├── requirements.txt            # Python 依赖（fastapi / uvicorn / aiohttp / pyyaml）
├── start_lb.sh                 # 启动脚本（Docker 容器方式运行）
├── configs/
│   ├── example.yaml            # 通用配置示例
│   ├── minimax.yaml            # MiniMax-M2.5 示例配置
│   └── minimax-m2.5-lb.yaml    # MiniMax-M2.5-INT8 生产配置（.36 + .37）
└── test/
    ├── config_test.yaml        # Mock 后端测试配置
    ├── mock_backend.py         # 模拟 vLLM 后端（支持流式/非流式）
    ├── run_test.sh             # 端到端测试（含 Mock 后端 + Docker LB）
    └── test_real_backends.sh   # 真实后端功能测试（LB 须已启动）
```

## 配置文件格式

```yaml
backends:
  - model: "模型ID"        # 必须与 vLLM 服务器返回的 model id 完全一致
    ip: "10.0.0.1"
    port: 8000
    enabled: true           # false 则跳过该后端
    description: "备注"     # 可选
```

> **注意**：`model` 字段须与 vLLM 的 `/v1/models` 返回值精确匹配（通常是权重目录的绝对路径，如 `/data/models/MiniMax/MiniMax-M2.5-INT8`）。

## 启动

```bash
cd infer/llm/load_balance

# 后台启动（--detach），成功后打印可用模型列表
bash start_lb.sh --port 20080 --config configs/minimax-m2.5-lb.yaml --detach

# 前台启动（直接看日志）
bash start_lb.sh --port 20080 --config configs/minimax-m2.5-lb.yaml

# 全部参数
bash start_lb.sh \
    --port    <端口>       # 必填
    --config  <yaml路径>   # 必填，支持相对/绝对路径
    --host    0.0.0.0      # 可选，默认 0.0.0.0
    --timeout 3600         # 可选，单请求超时（秒），默认 3600
    --name    vllm-lb      # 可选，Docker 容器名，默认 vllm-lb
    --detach               # 可选，后台运行
```

## 使用示例

```bash
# 非流式请求
curl http://127.0.0.1:20080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "/data/models/MiniMax/MiniMax-M2.5-INT8",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 64
  }' | python3 -m json.tool

# 流式请求
curl http://127.0.0.1:20080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "/data/models/MiniMax/MiniMax-M2.5-INT8",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 64,
    "stream": true
  }'

# 查询已注册模型
curl http://127.0.0.1:20080/v1/models | python3 -m json.tool

# 健康检查
curl http://127.0.0.1:20080/health
```

响应头 `X-LB-Backend` 标识实际路由到的后端地址（调试用）。

## API 端点

| 方法 | 路径 | 说明 |
|------|------|------|
| `POST` | `/v1/chat/completions` | 聊天补全（支持 `stream: true`）|
| `POST` | `/v1/completions` | 文本补全 |
| `POST` | `/v1/embeddings` | Embedding |
| `GET` | `/v1/models` | 已注册模型列表 |
| `GET` | `/health` | 健康检查 |

## 路由规则

- 从请求 body 的 `model` 字段匹配后端池
- 同一模型的所有启用后端按 **Round-Robin** 顺序轮询
- 未注册或全部禁用的模型返回 **HTTP 404**
- 流式请求（`"stream": true`）直接透传 SSE，不缓冲

## 容器管理

```bash
# 查看日志
docker logs -f vllm-lb

# 停止
docker stop vllm-lb

# 重启（使用同一配置）
docker restart vllm-lb
```

## 测试

```bash
# 1. 端到端测试（自动起 Mock 后端 + Docker LB，无需预先启动任何服务）
bash test/run_test.sh

# 2. 真实后端测试（需先通过 start_lb.sh 启动 LB）
bash test/test_real_backends.sh
bash test/test_real_backends.sh --lb-url http://127.0.0.1:20080 --requests 10
```

## 构建镜像

首次使用或 `lb_server.py` / `requirements.txt` 有改动时重新构建：

```bash
cd infer/llm/load_balance
docker build -t vllm-lb:latest .
```

镜像基于 `python:3.11-slim`（从 `docker.m.daocloud.io` 拉取）。
