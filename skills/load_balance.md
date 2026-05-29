---
name: load_balance
description: Start and manage the OpenAI-compatible round-robin load balancer for vLLM backends. Covers config authoring, Docker-based startup, endpoint usage, and testing. Read this skill before setting up or modifying the load balancer.
metadata:
  type: skill
  tags: [load-balance, vllm, openai, round-robin, streaming, docker, inference]
  scripts:
    - infer/llm/load_balance/start_lb.sh
    - infer/llm/load_balance/lb_server.py
    - infer/llm/load_balance/Dockerfile
    - infer/llm/load_balance/configs/minimax-m2.5-lb.yaml
    - infer/llm/load_balance/test/test_real_backends.sh
    - infer/llm/load_balance/test/run_test.sh
---

# Skill: load_balance

## Script / File Map

| 文件 | 运行位置 | 说明 |
|------|---------|------|
| `start_lb.sh` | 宿主机 | 拉起 Docker 容器（`vllm-lb:latest`）运行 LB；支持后台/前台模式 |
| `lb_server.py` | 容器内 | FastAPI + aiohttp 实现的 LB 服务；Round-Robin 轮询，SSE 流式透传 |
| `Dockerfile` | — | 基于 `python:3.11-slim`，预装所有依赖；用 `docker build` 构建 |
| `configs/*.yaml` | — | 后端配置文件；每个条目含 model/ip/port/enabled 字段 |
| `test/test_real_backends.sh` | 宿主机 | 功能测试（仅发请求）；LB 须已通过 start_lb.sh 启动 |
| `test/run_test.sh` | 宿主机 | 端到端测试；自动起 Mock 后端 + Docker LB，无需真实 vLLM 服务 |

**架构原则：**
- LB 以 Docker 容器方式运行，`--network host` 直接访问宿主机及局域网后端
- 路由依据：请求 body 中的 `model` 字段，与配置文件中的 `model` **精确匹配**
- 同一 model 的多个后端按 Round-Robin 轮询（asyncio 异步锁保证安全）
- 响应头 `X-LB-Backend` 标识实际路由的后端（调试用）
- 流式请求（`"stream": true`）直接 chunked 透传，不缓冲

---

## 1 — 配置文件

### 1.1 格式

```yaml
backends:
  - model: "/data/models/MiniMax/MiniMax-M2.5-INT8"  # 与 vLLM /v1/models 返回值精确一致
    ip: "172.25.198.36"
    port: 20027
    enabled: true
    description: "node-36"

  - model: "/data/models/MiniMax/MiniMax-M2.5-INT8"
    ip: "172.25.198.37"
    port: 20027
    enabled: true
    description: "node-37"
```

### 1.2 查询 vLLM 的真实 model id

```bash
curl -s http://<vllm-ip>:<port>/v1/models | python3 -m json.tool
# 找 "id" 字段，如："/data/models/MiniMax/MiniMax-M2.5-INT8"
```

### 1.3 已有配置

| 配置文件 | 模型 | 后端 |
|---------|------|------|
| `configs/minimax-m2.5-lb.yaml` | `/data/models/MiniMax/MiniMax-M2.5-INT8` | 172.25.198.36:20027, 172.25.198.37:20027 |
| `configs/example.yaml` | qwen3-32b / minimax-m2.5 示例 | — |

---

## 2 — 构建镜像（首次或依赖变更后执行一次）

```bash
cd infer/llm/load_balance
docker build -t vllm-lb:latest .
```

基础镜像 `python:3.11-slim` 从 `docker.m.daocloud.io` 拉取（Docker Hub 不可达时使用）：

```bash
docker pull docker.m.daocloud.io/library/python:3.11-slim
docker tag  docker.m.daocloud.io/library/python:3.11-slim python:3.11-slim
```

---

## 3 — 启动 LB

```bash
cd infer/llm/load_balance

# 后台启动（推荐）
bash start_lb.sh --port 20080 --config configs/minimax-m2.5-lb.yaml --detach

# 前台启动（看实时日志）
bash start_lb.sh --port 20080 --config configs/minimax-m2.5-lb.yaml
```

### 参数说明

| 参数 | 必填 | 默认 | 说明 |
|------|------|------|------|
| `--port` | ✓ | — | LB 监听端口 |
| `--config` | ✓ | — | YAML 配置文件路径（相对/绝对均可）|
| `--host` | — | `0.0.0.0` | 绑定地址 |
| `--timeout` | — | `3600` | 单请求超时（秒）|
| `--name` | — | `vllm-lb` | Docker 容器名 |
| `--detach` | — | false | 后台运行 |

### 启动成功输出示例

```
Load balancer is ready at http://localhost:20080
Available models:
  /data/models/MiniMax/MiniMax-M2.5-INT8  (2 backend(s))
Logs : docker logs -f vllm-lb
Stop : docker stop vllm-lb
```

---

## 4 — 使用

### 4.1 非流式请求

```bash
curl http://127.0.0.1:20080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "/data/models/MiniMax/MiniMax-M2.5-INT8",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 64
  }' | python3 -m json.tool
```

### 4.2 流式请求

```bash
curl http://127.0.0.1:20080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "/data/models/MiniMax/MiniMax-M2.5-INT8",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 64,
    "stream": true
  }'
```

### 4.3 查询已注册模型

```bash
curl http://127.0.0.1:20080/v1/models | python3 -m json.tool
```

### 4.4 健康检查

```bash
curl http://127.0.0.1:20080/health
# {"status":"ok","models":{"/data/models/MiniMax/MiniMax-M2.5-INT8":2}}
```

### 4.5 确认路由

响应头 `X-LB-Backend` 显示本次路由到的后端：

```bash
curl -D - http://127.0.0.1:20080/v1/chat/completions ... 2>&1 | grep -i x-lb-backend
# X-LB-Backend: http://172.25.198.36:20027
```

---

## 5 — 测试

```bash
# 功能测试（LB 须已运行）
bash test/test_real_backends.sh
bash test/test_real_backends.sh --lb-url http://127.0.0.1:20080 --requests 10

# 端到端测试（Mock 后端，无需真实 vLLM）
bash test/run_test.sh
```

测试覆盖：Round-Robin 严格交替、均匀分发、SSE 流式、未知模型 404。

---

## 6 — 容器管理

```bash
docker logs -f vllm-lb       # 查看日志
docker stop  vllm-lb         # 停止
docker start vllm-lb         # 重新启动（保留配置）
docker restart vllm-lb       # 重启
docker rm    vllm-lb         # 删除容器
```

---

## 7 — 常见问题

| 现象 | 可能原因 | 排查 |
|------|---------|------|
| 启动后 `/health` 无响应 | 端口被占用 / pip 安装失败 | `docker logs vllm-lb` |
| 请求返回 404 | `model` 字段与配置不匹配 | `curl .../v1/models` 确认真实 id |
| 请求返回 502/503 | 后端 vLLM 服务宕机 | 直接访问后端 ip:port 确认 |
| 流式输出中断 | timeout 太短 | `--timeout` 调大（如 7200）|
| 只有一个后端收到请求 | 另一后端 `enabled: false` | 检查配置文件 |
