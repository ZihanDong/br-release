---
name: vllm-perf-diagnosis
description: Diagnose and fix vLLM serving performance degradation (TTFT/TPOT blow-up at higher concurrency) on BirenTech GPUs, especially long-context workloads. Covers the two dominant failure modes (chunked-prefill starving decode; KV-cache preemption cliff), how to read vllm-bench results + server scheduler logs to tell them apart, the config levers, and a no-preemption sizing formula. Read before debugging "why does concurrency make latency explode".
metadata:
  type: skill
  tags: [vllm, performance, ttft, tpot, chunked-prefill, kv-cache, preemption, long-context, biren, benchmark]
  scripts:
    - infer/llm/vllm/run_docker.sh
    - infer/llm/vllm/configs/
    - infer/llm/client/vllm-bench/run_test.sh
---

# Skill: vllm-perf-diagnosis

诊断 vLLM 推理服务"并发一升高 TTFT/TPOT 就爆炸"类性能问题的排查手册（BirenTech GPU，尤其长上下文）。结论来自 2026-05 MiniMax-M2.5-INT8 的实测定位，已两机交叉验证。

## 0 — 何时用这个 skill

症状：单并发(conc=1)指标正常，但并发升高后 TTFT 涨到几十秒~几分钟、TPOT 从几十 ms 涨到 1000ms+、吞吐不升反降。常见于长输入(16k/32k/100k) + 短输出的 bench。

**先记住核心结论**：这类问题通常是**两个独立故障叠加**，不要混为一谈：
1. **主因 — chunked prefill 垄断引擎、饿死 decode**（从低并发就开始的*渐进*劣化）
2. **次因 — KV cache 容量不足触发抢占重算**（到某并发突然*悬崖*式崩溃）

还要排除一个伪故障：请求被服务端直接拒绝（0 成功、秒结束），那不是性能问题（见 §5）。

---

## 1 — 两个故障模式的"指纹"

### 故障 A：prefill 垄断引擎，饿死 decode（主因）

**机制**：`max_num_batched_tokens`（chunked prefill 每步 token 预算，默认仅 **2048**）对长上下文太小。一个 100k 输入要 ~49 个 chunk step 才 prefill 完，每步要对已缓存的最多 100k KV 做注意力（单步 ~2-3s），且 per-step 固定开销（kernel launch/调度）被放大 49 倍。正在 decode 的请求被迫挤在这些慢 step 里 → decode 吞吐塌到 ~1 tok/s。

**指纹**（看 vllm-bench 结果 + server 日志）：
- TPOT/ITL 从 **conc=2 就开始**随并发近似线性恶化（不是某个并发点突变）；聚合 decode 吞吐随并发**下降**。
- server 调度日志里 `Avg generation throughput` 长期 ~1-2 tok/s，但**每当一批 prefill 全部完成的瞬间会暴涨到 20+ tok/s** —— 这是铁证：decode 本身健康，是 prefill 占满了引擎。
- KV 使用率在没满的情况下（如 55%、82%）TPOT 就已很差。

### 故障 B：KV cache 容量不足 → 抢占 + 重算（次因 cliff）

**机制**：KV cache 只能装下 N 个 token。当 `运行中请求数 × 各自当前长度 > KV 容量`，vLLM 抢占(preempt)某些序列；若配了 `--no_enable_prefix_caching`，被抢请求要把整段 prefill **完整重算**，灾难性浪费。

**指纹**：
- 某并发点 TPOT/TTFT **突然悬崖式恶化**（不是渐进）。
- server 日志 `GPU KV cache usage` 呈**锯齿**：爬到 ~99% 然后突降（释放），反复；偶现 `Running` 数瞬间减少（`run=N → run=N-1, wait=+1`）。
- 触发阈值可预测：`单机并发 × 单请求长度 ≈ KV 容量`。

---

## 2 — 诊断流程（按顺序）

### 2.1 看 bench 结果摘要，确认是"慢"还是"失败"

```bash
# 对每个并发的结果文件
grep -E "Successful|Failed|Mean TTFT|Mean TPOT|Mean ITL|Output token throughput|Maximum request concurrency" \
  <bench_log_dir>/bench_in*_conc*.log
```
- `Successful: 0` + 秒级 duration + `Never received a valid chunk` → **伪故障**，跳到 §5。
- conc=1 正常、并发升高 TPOT 渐涨 → 故障 A；某点突变 → 叠加了故障 B。

### 2.2 看 server 调度日志，区分 A / B

```bash
# 提取并发测试时段的调度演化
grep "loggers.py" <vllm_server.log> | \
  sed -E 's/.*([0-9]{2}:[0-9]{2}:[0-9]{2}).*generation throughput: ([0-9.]+).*Running: ([0-9]+).*Waiting: ([0-9]+).*usage: ([0-9.]+)%.*/time=\1 gen=\2 run=\3 wait=\4 kv=\5/'
```
判读：
- `gen` 长期 ~1-2、偶尔暴涨 20+ → **故障 A**（prefill 饿死 decode）。
- `kv` 锯齿冲到 ~99% 再骤降 / `run` 抖动 → **故障 B**（抢占）。
- `kv` 没满（<90%）但 `gen` 仍很低 → 纯故障 A（容量没问题）。

### 2.3 量化 KV 容量（判断故障 B 的阈值）

server 启动日志里直接有：
```bash
grep -E "GPU KV cache size|Maximum concurrency|max_num_batched_tokens" <vllm_server.log>
# GPU KV cache size: 319,488 tokens
# Maximum concurrency for 101,000 tokens per request: 3.16x
# Chunked prefill is enabled with max_num_batched_tokens=2048   <-- 故障A的根源
```
KV 容量(token)只取决于 **模型 + 显存(gpu_mem) + TP + mnbt**，**与 max_model_len 无关**。
- `单请求峰值长度 = input + output`（`ignore_eos=true` 时输出定长，峰值确定）。
- 抢占阈值（单机）：`并发 × 峰值长度 > KV 容量`。注意双机 LB 时 **单机并发 ≈ LB 并发 / 2**。

---

## 3 — 修复杠杆（实测效果，MiniMax-M2.5-INT8, 100k 输入）

| 杠杆 | 治哪个 | 实测效果 | 代价/注意 |
|------|--------|---------|----------|
| `--max_num_batched_tokens` 2048→**8192** | 故障 A | conc1-3 TTFT/TPOT **改善 34-56%**；prefill 步数 49→13；单流 prefill 吞吐 ~1750→~4000 tok/s | 占激活内存使 KV 略降(364k→319k)；过大有 OOM 风险。**反直觉：调大反而改善 decode TPOT**，因 Biren 路径 per-step 开销才是大头 |
| `max_num_seqs` 调小到容量内 | 故障 B | 把超额请求变成**排队**而非抢占重算；conc4 TPOT 从 977→500ms（消除 cliff） | 高并发段会排队、TTFT 增大（但远好于抢占）|
| 两者结合（推荐） | A+B | conc4 vs 基线 **TTFT -51%、TPOT -63%** | — |
| `gpu_memory_utilization` 0.75→0.9 | 扩 KV | — | ⚠️ **实测 OOM 崩溃**（SUPA out of memory，warmup 阶段激活内存爆）。0.9 不可用，0.8 需启动时验证 |

**无抢占的 max_num_seqs 公式（彻底消除故障 B）**：
```
max_num_seqs ≤ floor( KV容量(token) / (input + output) )
```
这样运行集峰值恒 ≤ KV 容量，多余请求干净排队、永不抢占。例（KV=319k, mnbt=8192）：
- 16k+1k=17k/seq → max_num_seqs ≤ 18
- 32k+1k=33k/seq → max_num_seqs ≤ 9
- 100k+0.8k=100.8k/seq → max_num_seqs ≤ 3

**重要的物理上限**：长输入/短输出本质是 **prefill-bound**（吞吐被 prefill 算力卡死）。故障 A 只能*最小化*不能*消除*；并发只换 TTFT 排队深度、不增吞吐。低延迟长上下文场景应保持低并发。

---

## 4 — 排除"biren 镜像 vllm 代码与官方有差异"

被测**服务端**是 biren vllm（官方 vllm 不支持 Biren GPU，换不掉，无法 A/B）。但 **bench 客户端**可静态比对：

```bash
# 从镜像导出 bench 代码
docker run --rm -e VLLM_PLUGINS="" -v /tmp/b:/out --entrypoint bash <biren-image> -c \
  'P=$(python3 -c "import vllm,os;print(os.path.dirname(vllm.__file__))")/benchmarks; cp $P/serve.py $P/datasets.py /out/; cp -r $P/lib /out/'
# 取官方对应 tag (镜像启动日志里有版本，如 v0.16.0)
curl -s https://raw.githubusercontent.com/vllm-project/vllm/v0.16.0/vllm/benchmarks/serve.py -o /tmp/o_serve.py
diff /tmp/b/serve.py /tmp/o_serve.py        # 重点比 lib/endpoint_request_func.py(算TTFT/TPOT的)
```
2026-05 实测：biren v0.16.0 的 `serve.py / datasets.py / lib/*` 与官方**逐字节一致** → 测量代码无差异，数值是真实服务端行为，不是 bench 客户端问题。

---

## 5 — 伪故障：请求被直接拒绝（不是性能问题）

bench 显示 `Successful: 0`、`Failed: N`、duration 秒级、`Error: Never received a valid chunk to calculate TTFT` → 服务端直接报错/拒绝，与并发/抢占无关。最常见原因：**请求 token 数(input+output) > 服务端 `max_model_len`**（如 32k+1k=33k 发给 max_model_len=21000 的 server）。先核对 server 的 `max_model_len`：
```bash
curl -s http://<ip>:<port>/v1/models | python3 -m json.tool | grep max_model_len
```

---

## 6 — 实测案例（MiniMax-M2.5-INT8, TP=8, 双机 LB, 100k 输入/200 输出, 单机直连绕过 LB）

单机并发 ramp 的 TPOT(ms)：

| 配置 | conc1 | conc2 | conc3 | conc4 | KV |
|------|------|------|------|------|------|
| 基线 (mns=8, mnbt=2048) | 45 | 246 | 514 | **977**(抢占) | 364k |
| mnbt=8192 | 45 | 151 | 282 | 1405 | 319k |
| mns=3 | 45 | 246 | 565 | **500**(无抢占) | 364k |
| **mns=3 + mnbt=8192** | 45 | 151 | 365 | **361** | 319k |
| gpu_mem=0.9 | ❌ OOM | | | | 686k |

两台机器结果几乎一致（排除单机故障）。conc=1 单请求 100k：TTFT~25-57s、decode ~22 tok/s（健康）。

---

## 7 — 快速排查清单

1. bench 摘要：是"慢"(TPOT涨)还是"失败"(0成功)？失败→§5 查 max_model_len。
2. server 启动日志：`GPU KV cache size`、`max_num_batched_tokens`、`Maximum concurrency`。
3. 调度日志：`gen` 是否长期低、偶尔暴涨(→A)？`kv` 是否锯齿冲顶(→B)？
4. 算阈值：`单机并发 × (input+output)` vs KV 容量；双机 LB 记得 /2。
5. 修复：mnbt 调大(治A) + max_num_seqs 卡进容量(治B，用 §3 公式)；gpu_mem 别上 0.9。
6. 重启 server：`docker rm -f vllm_<model>` → 等 GPU 释放 → `bash run_docker.sh --run configs/<conf>`（约 10min 加载），启动后**核对 KV 容量是否达标**。
