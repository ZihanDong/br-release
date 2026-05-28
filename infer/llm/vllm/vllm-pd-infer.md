# Minimax 模型分离式 PD 推理部署指南

本文档介绍如何在 Biren GPU 上使用 **HeteroSucclConnector** 进行 Prefill-Decode 分离（PD 分离）推理部署，适用于 Minimax M2.5 INT8 模型的高性能服务场景。

---

## 目录

- [节点规划](#节点规划)
- [架构概述](#架构概述)
- [组件说明](#组件说明)
- [完整运行步骤](#完整运行步骤)
- [配置参数说明](#配置参数说明)
- [关键环境变量](#关键环境变量)
- [KV Cache 传输流程](#kv-cache-传输流程)
- [常见问题与排查](#常见问题与排查)

---

## 节点规划

| 角色 | IP 地址 | 端口 | 说明 |
|------|---------|------|------|
| Proxy Server（代理服务器） | `10.90.24.135` | HTTP: `35111`，ZMQ: `34367` | 请求路由与服务发现，与 P 节点同机部署 |
| Prefill 节点（P 节点） | `10.90.24.135` | `20003` | `kv_producer`，负责输入处理与 KV Cache 填充 |
| Decode 节点（D 节点） | `10.90.24.139` | `20005` | `kv_consumer`，负责 Token 生成与流式输出 |

---

## 架构概述

PD 分离架构将传统推理流程中的 **Prefill（预填充）** 阶段与 **Decode（解码）** 阶段拆分到不同节点，分别独立扩展，从而提升整体吞吐量与硬件利用率。

```
  Client
    │
    ▼
┌────────────────────────────────────────┐
│     Proxy Server  10.90.24.135:35111    │
│  - HTTP 请求路由 (Quart)               │
│  - 服务发现与注册 (ZMQ :34367)         │
│  - 轮询负载均衡                        │
└────────────┬──────────────┬────────────┘
             │              │
    ① 转发请求│              │④ 返回生成结果
             ▼              ▼
┌─────────────────┐  ┌──────────────────────┐
│  Prefill 节点   │  │    Decode 节点        │
│  10.90.24.135    │  │   10.90.24.139        │
│  :20003         │  │   :20005              │
│  (kv_producer)  │③ │   (kv_consumer)       │
│                 │─▶│                       │
│ 处理输入 Token  │  │  接收 KV Cache        │
│ 填充 KV Cache   │  │  生成输出 Token       │
│ SUCCL 传输 KV   │  │  流式返回响应         │
└─────────────────┘  └──────────────────────┘
        ↑                      ↑
  ② ZMQ 注册                ② ZMQ 注册
  → 10.90.24.135:34367       → 10.90.24.135:34367
```

**请求处理流程：**

1. 客户端向代理服务器（`10.90.24.135:35111`）发送推理请求
2. Prefill 节点和 Decode 节点启动后均通过 ZMQ 向代理服务器（`:34367`）注册自身信息
3. 代理服务器将请求（含 Decode 节点握手地址）转发至 Prefill 节点，Prefill 节点执行输入处理并填充 KV Cache
4. Prefill 节点通过 **SUCCL** 将 KV Cache 直传至 Decode 节点，并返回 Engine ID
5. 代理服务器将请求（含 KV Cache / Engine ID）转发至 Decode 节点，Decode 节点生成 Token 并流式返回

---

## 组件说明

### 1. 代理服务器（Proxy Server）

**脚本**：`examples/online_serving/minimax_pd/hetero_proxy_server.py`

- 基于 Quart 异步框架，监听 `/v1/completions` 和 `/v1/chat/completions`
- 通过 ZMQ ROUTER Socket 监听 Prefill/Decode 节点注册（`request_address`、`handshake_address`、`engine_id` 等）
- 对 Prefill/Decode 实例分别维护轮询计数器，均匀分发请求
- 支持通过 `--host`、`--port`、`--zmq-port` CLI 参数配置监听地址

### 2. Prefill 节点（pnode）

**脚本**：`examples/online_serving/minimax_pd/minimax_pnode.sh`

- 以 `kv_producer` 角色运行 vLLM，执行输入 Token 的预填充
- 填充 KV Cache 后通过 **SUCCL** 传输至 Decode 节点
- 启动后自动向代理服务器 ZMQ 端口注册

**关键配置：**
- 分布式后端：`mp`，KV 角色：`kv_producer`
- TP=4，PP=2，max-model-len=20000，max-num-batched-tokens=8192，max-num-seqs=64

### 3. Decode 节点（dnode）

**脚本**：`examples/online_serving/minimax_pd/minimax_dnode.sh`

- 以 `kv_consumer` 角色运行 vLLM，接收 KV Cache 后执行自回归 Token 生成
- 将生成结果流式返回给代理服务器

**关键配置：**
- 分布式后端：`mp`，KV 角色：`kv_consumer`
- TP=4，PP=2，max-model-len=20000，max-num-batched-tokens=4096，max-num-seqs=64

---

## 完整运行步骤

> **前置条件**：
> - 已安装 vllm_br 及相关 Biren GPU 驱动和 SUCCL 库
> - 节点（`10.90.24.135` / `10.90.24.139`）之间网络互通
> - 模型文件已挂载至 `/mnt/file/default-cephfs-user/E01297/workspace/minimax/Minimax-M2.5-INT8`
> - 在 vllm_br 仓库根目录（`/root/workspace/src/vllm`）下执行以下命令

---

### 步骤一：在 `10.90.24.135` 启动代理服务器

```bash
cd /root/workspace/src/vllm/examples/online_serving/minimax_pd

python3 hetero_proxy_server.py \
  --host 10.90.24.135 \
  --port 35111 \
  --zmq-port 34367
```

代理服务器启动后：
- HTTP 路由监听在 `10.90.24.135:35111`
- ZMQ 服务发现监听在 `10.90.24.135:34367`

> **提示**：建议在 `screen` 或 `tmux` 中后台运行，便于查看日志。

---

### 步骤二：在 `10.90.24.135` 启动 Prefill 节点

```bash
cd /root/workspace/src/vllm/examples/online_serving/minimax_pd

bash minimax_pnode.sh \
  --model /mnt/file/default-cephfs-user/E01297/workspace/minimax/Minimax-M2.5-INT8 \
  --http-port 20003 \
  --http-ip 10.90.24.135 \
  --dp-size 1 \
  --proxy-ip 10.90.24.135 \
  --proxy-port 34367
```

Prefill 节点启动并完成模型加载后，会自动向 `10.90.24.135:34367` 发起 ZMQ 注册。代理服务器日志中出现如下内容表示注册成功：

```
###!!!Received registration from prefill instance: ...
```

---

### 步骤三：在 `10.90.24.139` 启动 Decode 节点

```bash
cd /root/workspace/src/vllm/examples/online_serving/minimax_pd

bash minimax_dnode.sh \
  --model /mnt/file/default-cephfs-user/E01297/workspace/minimax/Minimax-M2.5-INT8 \
  --http-port 20005 \
  --http-ip 10.90.24.139 \
  --dp-size 1 \
  --proxy-ip 10.90.24.135 \
  --proxy-port 34367
```

Decode 节点启动并向代理服务器注册成功后，代理服务器日志中出现：

```
###!!!Received registration from decode instance: ...
```

此时两个节点均已就绪，系统可以接受推理请求。

---

### 步骤四：发送推理请求

向代理服务器发送请求（Chat Completions）：

```bash
curl http://10.90.24.135:35111/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Minimax-M2.5-INT8",
    "messages": [{"role": "user", "content": "What is the capital of the United States?"}],
    "stream": true,
    "max_tokens": 512
  }'
```

---

## 配置参数说明

以下参数适用于 `minimax_pnode.sh` 和 `minimax_dnode.sh`：

| 参数 | 说明 | 默认值（pnode） | 默认值（dnode） |
|------|------|----------------|----------------|
| `--model` | 模型文件路径 | Minimax-M2.5-INT8 路径 | Minimax-M2.5-INT8 路径 |
| `--http-port` | vLLM HTTP 服务监听端口 | `20003` | `20005` |
| `--http-ip` | vLLM HTTP 服务监听地址 | `127.0.0.1` | `127.0.0.1` |
| `--dp-size` | 数据并行度（Data Parallelism） | `1` | `1` |
| `--proxy-ip` | 代理服务器 IP 地址 | 必须指定 | 必须指定 |
| `--proxy-port` | 代理服务器 ZMQ 注册端口 | `36367` | `36367` |
| `--timeout-seconds` | 等待服务启动超时时间（秒） | `1000` | `1000` |

`hetero_proxy_server.py` 参数：

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `--host` | HTTP 监听地址 | `0.0.0.0` |
| `--port` | HTTP 监听端口 | `35111` |
| `--zmq-port` | ZMQ 服务发现端口 | `34367` |

**Minimax M2.5 INT8 模型配置（已写入脚本）：**

| 参数 | Prefill 节点 | Decode 节点 |
|------|-------------|------------|
| `--tensor-parallel-size` | 4 | 4 |
| `--pipeline-parallel-size` | 2 | 2 |
| `--max-model-len` | 20000 | 20000 |
| `--max-num-seqs` | 64 | 64 |
| `--max-num-batched-tokens` | 8192 | 4096 |
| `--gpu-memory-utilization` | 0.9 | 0.9 |
| `--enable-expert-parallel` | ✅ | ✅ |
| `--no-enable-prefix-caching` | ✅ | ✅ |
| `--compilation-config` | `FULL_DECODE_ONLY` | `FULL_DECODE_ONLY` |
| `--served-model-name` | `Minimax-M2.5-INT8` | `Minimax-M2.5-INT8` |

---

## 关键环境变量

以下环境变量在 pnode/dnode 脚本中会自动设置：

### Biren GPU 运行时

| 环境变量 | 值 | 说明 |
|---------|-----|------|
| `BRTB_LOG_LEVEL` | `Warning` | Biren 运行时日志级别 |
| `BRTB_LOG_DIR` | `/root/vllm_logs` | Biren 运行时日志输出目录 |
| `BRTB_ENABLE_NUMA_SPLIT` | `1` | 启用 NUMA 分离，提升内存访问效率 |
| `BRTB_CHUNK_PREFILL_ATTN_HIGH_PERFORMANCE` | `1` | 高性能分块 Prefill 注意力计算 |
| `BRTB_ENABLE_MMA_BF16_ACC` | `1` | 启用 BF16 累加精度 |

### vLLM Biren 扩展

| 环境变量 | 值 | 说明 |
|---------|-----|------|
| `VLLM_BR_EMBEDDING_S0B` | `1` | Minimax 专用嵌入层优化（需为 1） |
| `VLLM_BR_WEIGHT_TYPE` | `NUMA` | 权重内存布局类型 |
| `VLLM_BR_LMHEAD_NUMA` | `1` | LM Head NUMA 优化 |
| `VLLM_BR_ENABLE_GRAPH_MODE` | `0` | 关闭图模式（PD 分离场景） |
| `VLLM_WORKER_MULTIPROC_METHOD` | `spawn` | 多进程启动方式 |
| `VLLM_USE_V1` | `1` | 使用 vLLM V1 引擎 |

### SUCCL 集合通信

| 环境变量 | 值 | 说明 |
|---------|-----|------|
| `SUCCL_BUFFSIZE` | `16777216` | SUCCL 通信缓冲区大小（16MB） |

---

## KV Cache 传输流程

```
Prefill 节点 (10.90.24.135:20003)          Decode 节点 (10.90.24.139:20005)
─────────────────────────────────────────────────────────────────────────
1. 接收请求（含 do_remote_decode=True
   及 Decode 节点 handshake_address）

2. 执行 Prefill，填充 KV Cache

3. 通过 HeteroSucclConnector 建立
   与 Decode 节点的 SUCCL 通道

4. 经 SUCCL 高速传输 KV Cache ──────────▶ 5. 接收 KV Cache 并存入 KV 池

                                            6. 接收请求（含 do_remote_prefill=True
                                               及 KV Cache ID / Engine ID）

                                            7. 基于 KV Cache 执行 Decode
                                               自回归生成 Token

5. 返回 KV Cache ID 给代理服务器           8. 流式输出生成结果给代理服务器
```

**关键机制：**
- **握手（Handshake）**：Prefill 节点在传输前与 Decode 节点协商传输参数（块大小、数据类型、目标地址）
- **SUCCL 传输**：KV Cache 通过 SUCCL 进行 GPU-to-GPU 直传，绕过 CPU，降低传输延迟
- **Engine ID**：每个 vLLM 实例拥有唯一 Engine ID，用于确保 Prefill 与 Decode 的请求配对正确

---

## 常见问题与排查

### 1. Prefill/Decode 节点未向代理服务器注册

**现象**：代理服务器日志无注册记录，或节点超时退出。

**排查步骤**：
- 确认 `--proxy-ip 10.90.24.135` 和 `--proxy-port 34367` 参数正确
- 检查防火墙：`telnet 10.90.24.135 34367` 验证 ZMQ 端口可达
- 模型加载较慢时增大 `--timeout-seconds`（默认 1000s）

---

### 2. KV Cache 传输失败或 SUCCL 报错

**现象**：Prefill 完成后卡住，Decode 节点报 KV Cache 接收错误。

**排查步骤**：
- 在脚本中添加 `export SUCCL_DEBUG=TRACE` 和 `export SUCCL_DEBUG_SUBSYS=ALL` 获取详细日志
- 确认 `10.90.24.135` 与 `10.90.24.139` 之间的网络连通性

---

### 3. 模型加载 OOM

**现象**：节点启动时报显存不足错误。

**排查步骤**：
- 确认没有其他进程占用 GPU 显存：`brsmi`
- 适当降低 `--max-num-seqs`（当前 64）或 `--gpu-memory-utilization`（当前 0.9）

---

### 4. 请求响应超时或返回 "Internal Server Error"

**现象**：客户端长时间等待（60s 超时）或收到 503/500，错误信息为 `Cannot connect to host 10.90.24.135:20003`。

**排查步骤**：
- 确认 P/D 节点的 vLLM 进程仍在运行：`ps aux | grep "VLLM::Worker" | grep -v grep | wc -l`（PP=2,TP=4 时应为 8）
- 确认代理服务器日志中 prefill 和 decode 实例均已注册（出现 `###!!!Received registration`）
- 检查 P/D 节点的 vLLM HTTP 服务是否可响应：`curl http://10.90.24.135:20003/v1/models`、`curl http://10.90.24.139:20005/v1/models`
- 若 P 节点进程已崩溃，将脚本输出重定向到文件后重启：`bash minimax_pnode.sh ... 2>&1 | tee /tmp/pnode.log`，然后 `grep -E "ValueError|Traceback|Error" /tmp/pnode.log`
- 详细调试分析见 [DEBUG.md](./debug/DEBUG.md)

---

### 5. SUCCL PP1 阶段连接未建立（P 节点在首次推理时崩溃）

**现象**：P 节点启动并通过 `/v1/models` 检查后，首次推理请求触发 P 节点崩溃，netstat 显示只有 PP0（kv_port+0 至 kv_port+3）建立过连接，PP1（kv_port+4 至 kv_port+7）从未连接。

**排查步骤**：
1. 在启动脚本中增加 SUCCL 调试日志：
   ```bash
   export SUCCL_DEBUG=TRACE
   export SUCCL_DEBUG_SUBSYS=ALL
   ```
2. 确认 P 节点启动时打印的 `dp_group_rank_infos` 包含 **8 条记录**（PP0+PP1 各 4 个 TP rank）：
   ```bash
   grep "_collect_dp_group_rank_infos" /tmp/pnode.log
   ```
3. 若仅有 4 条（PP0），说明 `all_gather_object` 阶段 PP1 worker 未参与，可能是 PP1 worker 启动慢或 nccl/sccl group 初始化超时。
4. 实时监控 PP1 SUCCL 连接：
   ```bash
   watch -n 0.5 "netstat -tn 2>/dev/null | grep '10.90.24.139:407'"
   ```

---

## 脚本路径

| 文件 | 路径 |
|------|------|
| 代理服务器 | `examples/online_serving/minimax_pd/hetero_proxy_server.py` |
| Prefill 节点启动脚本 | `examples/online_serving/minimax_pd/minimax_pnode.sh` |
| Decode 节点启动脚本 | `examples/online_serving/minimax_pd/minimax_dnode.sh` |

