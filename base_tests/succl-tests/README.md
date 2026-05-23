# succl-tests 测试环境

succl-tests 是壁仞 GPU 通信库（suCCL）的性能测试工具，支持 AllReduce、AllGather、Alltoall 等 11 种集合通信算子，可在单节点或多节点（SSH + MPI）模式下运行。

---

## 文件说明

```
base_tests/succl-tests/
├── setup_succl-tests.sh          # 构建 Docker 测试容器（安装 succl-tests、MPI、SSH 免密）
├── run_succl_tests.sh             # 在容器内执行测试，输出日志和峰值带宽摘要
└── configs/
    ├── general.conf               # 通用测试参数（迭代次数、数据类型、校验开关等）
    ├── multi-node.conf            # 多节点参数（节点 IP、SSH 端口、MPI 网卡等）
    ├── multi-2node-all-ops.conf   # 双节点全算子运行配置（含 BR166 已知 bug 规避参数）
    └── example-run.conf           # 运行配置示例与字段说明
```

---

## 快速开始

### 1. 构建容器环境（每个节点执行一次）

**单节点：**
```bash
bash base_tests/succl-tests/setup_succl-tests.sh single
```

**多节点（每个节点都需执行）：**
```bash
bash base_tests/succl-tests/setup_succl-tests.sh multi --pass <解密密码>
```

> `--pass` 对应 `setup/ssh-settings/biren-ssh-pass.tar.gz.enc` 的解密密码，用于在所有节点容器间部署共享 SSH 密钥对，实现 MPI 免密登录。

---

### 2. 配置多节点参数

编辑 `configs/multi-node.conf`，填入实际节点 IP 和 MPI 网卡：

```ini
SSH_PORT="2222"
MPI_IFACE_INCLUDE="p21p2"        # MPI 通信网卡（需两节点共同存在的接口名）
MPI_IFACE_EXCLUDE="lo"           # INCLUDE 非空时此项忽略
SUCCL_BUFFSIZE=""                 # 4+ 节点需设为 16777216
MULTI_NODE_IPS=(
    172.25.198.36                 # 主节点（运行 mpiexec）
    172.25.198.37                 # 从节点
)
```

---

### 3. 运行测试

```bash
# 单节点全算子（8 卡）
bash base_tests/succl-tests/run_succl_tests.sh \
    --config base_tests/succl-tests/configs/example-run.conf

# 双节点全算子（每节点 8 卡）
bash base_tests/succl-tests/run_succl_tests.sh \
    --config base_tests/succl-tests/configs/multi-2node-all-ops.conf

# 加 -v 同时在终端输出测试过程
bash base_tests/succl-tests/run_succl_tests.sh -v \
    --config base_tests/succl-tests/configs/multi-2node-all-ops.conf
```

---

## setup_succl-tests.sh

### 参数

| 参数 | 说明 |
|------|------|
| `single` | 单节点模式：不映射 IB 设备，不配置 SSH |
| `multi` | 多节点模式：自动检测 IB 设备并映射，配置容器 SSH 免密 |
| `--pass <密码>` | multi 模式必填，解密共享 SSH 密钥包 |

### 执行步骤

1. 检测 `/dev/infiniband/uverbs*`，multi 模式下有则映射入容器
2. 加载 Docker 镜像（若不存在则从 `SDK_ROOT_PATH` 导入 `.tar`）
3. 删除同名旧容器，以 `--restart unless-stopped` 启动新容器
4. **[multi]** 安装 `openssh-server`（镜像内已有则跳过 apt-get），配置 sshd 端口 `SSH_PORT`（默认 2222），生成主机密钥，部署共享 RSA 密钥对
5. 解压 succl-tests 安装包到容器 `/opt/succl-tests`
6. 检查 openMPI，不存在则从源码编译安装（约 10 分钟）
7. 写入环境变量配置 `/etc/profile.d/succl-tests.sh`
8. 探测 GPU 型号（BR166M 自动启用 UMA16 内存模式），写入 `/etc/succl-hw.conf`
9. **[multi]** SSH 免密自检（重试最多 10 次等待 sshd 就绪）；**[single]** 验证 mpiexec 和二进制文件

### 配置变量（脚本顶部）

```bash
SDK_ROOT_PATH="/data/release/2604rc2/"
IMAGE_NAME="birensupa-sdk:26.04.rc2-br1xx"
CONTAINER_NAME="biren_succl_tests"
SSH_PORT=2222
```

---

## run_succl_tests.sh

### 命令行

```
run_succl_tests.sh [-v] --config <run.conf> [--config <run2.conf> ...]
                         [--general <general.conf>]
                         [--multi-config <multi-node.conf>]
```

| 参数 | 说明 |
|------|------|
| `-v` | 详细模式：测试输出同时打印终端和日志 |
| `--config <file>` | 运行配置文件（INI 格式，可重复指定多个） |
| `--general <file>` | 通用参数文件（默认 `configs/general.conf`） |
| `--multi-config <file>` | 多节点参数文件（默认 `configs/multi-node.conf`） |

### 运行配置文件格式（`configs/*.conf`）

每个 `[section]` 对应一组测试：

```ini
[section_name]
mode         = single | multi
ops          = allreduce allgather ... | all
gpus         = 8            # single: 本节点总卡数; multi: 每节点卡数
min_bytes    = 512          # 可选，覆盖 general.conf 默认值
max_bytes    = 1G           # 可选
step_bytes   = 0            # 可选，0=使用 step_factor
step_factor  = 2            # 可选
iters        = 3            # 可选，覆盖 general.conf ITERS
warmup_iters = 3            # 可选，覆盖 general.conf WARMUP_ITERS
check        = 1            # 可选，覆盖 general.conf CHECK（0=跳过校验）
```

支持的算子（`ops` 字段）：

| 名称 | 对应二进制 |
|------|-----------|
| `allreduce` | `all_reduce_perf` |
| `allgather` | `all_gather_perf` |
| `alltoall` | `alltoall_perf` |
| `alltoallv` | `alltoallv_perf` |
| `broadcast` | `broadcast_perf` |
| `gather` | `gather_perf` |
| `hypercube` | `hypercube_perf` |
| `reduce` | `reduce_perf` |
| `reducescatter` | `reduce_scatter_perf` |
| `scatter` | `scatter_perf` |
| `sendrecv` | `sendrecv_perf` |
| `all` | 以上全部 |

### 通用参数（`configs/general.conf`）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `REDUCE_OP` | `sum` | 归约操作：`sum \| prod \| min \| max \| avg \| all` |
| `DATATYPE` | `float` | 数据类型：`float \| BF16` |
| `ROOT` | `0` | 根节点（`-1` = 遍历所有 rank，仅 Broadcast/Reduce 有效） |
| `ITERS` | `3` | 计时迭代次数（1–20） |
| `WARMUP_ITERS` | `3` | 预热迭代次数（0–10） |
| `AGG_ITERS` | `1` | 每次迭代聚合的操作数 |
| `AVERAGE` | `1` | 带宽取值方式：0=Rank0 / 1=Avg / 2=Min / 3=Max |
| `CHECK` | `1` | 结果校验：`1`=校验 / `0`=跳过（更快） |
| `BR166_MODE` | `auto` | UMA16 模式：`auto`=自动检测 / `0`=关闭 / `1`=强制 |

### 多节点参数（`configs/multi-node.conf`）

| 变量 | 说明 |
|------|------|
| `SSH_PORT` | 容器 sshd 端口，需与 setup 脚本一致（默认 2222） |
| `MPI_IFACE_INCLUDE` | MPI 通信使用的网卡（优先级高于 EXCLUDE） |
| `MPI_IFACE_EXCLUDE` | 排除的网卡（INCLUDE 为空时生效，默认 `lo`） |
| `SUCCL_BUFFSIZE` | 4+ 节点某些算子需设为 `16777216` |
| `MULTI_NODE_IPS` | 参与测试的节点 IP 列表（顺序任意，主节点建议放第一行） |

### 日志

每次运行在 `logs/succl-tests/succl-tests_<时间戳>/` 下生成：

```
succl-tests_20260523_012542/
├── multi_2node_allreduce_allreduce.log   # 首行: # CMD: <完整执行命令>
├── multi_2node_allreduce_allreduce.sh    # 可直接重跑的等价脚本
├── ...
└── summary.log                           # 汇总：各算子状态 + 峰值带宽
```

`summary.log` 示例：
```
  allreduce:       OK   algbw  30.26 GB/s  busbw  56.73 GB/s  @ 64 MiB   float
  allgather:       OK   algbw  85.22 GB/s  busbw  79.89 GB/s  @ 512 MiB  float
  sendrecv:        OK   algbw  28.87 GB/s  busbw  28.87 GB/s  @ 512 MiB  float
```

---

## 注意事项

### 硬件与系统

- **BR166M**：必须使用 UMA16 内存模式（`-k 1`）；setup 脚本自动探测并写入 `/etc/succl-hw.conf`，run 脚本默认读取（`BR166_MODE=auto`）
- **IOMMU**：测试前建议在宿主机关闭 IOMMU，否则影响性能（详见用户手册 §2.3）
- **ACS**：测试前需关闭 ACS，否则 suCCL 通信失败（详见用户手册 §2.3）
- **多节点防火墙**：需关闭防火墙，禁用 IPv6

### BR166M 多节点已知问题（SDK 26.04.rc2）

libsuccl 在 **UMA16 + 多节点 + 大消息** 场景下存在两类 segfault：

| 触发条件 | 规避方法 |
|----------|---------|
| `CHECK=1` + `iters/warmup > 1` + 消息 ≥ 134 MiB | 设 `iters=1 warmup_iters=1` |
| `CHECK=0` + `iters/warmup > 1` + 消息 ≥ 134 MiB | 设 `iters=1 warmup_iters=1` |

`configs/multi-2node-all-ops.conf` 已预设 `check=0 iters=1 warmup_iters=1`，待 SDK 修复后可移除这些限制。

### 4+ 节点大数据量

SendRecv / Gather / Scatter / Hypercube / Alltoall / Alltoallv 在 4 台或以上节点时，需在 `multi-node.conf` 中设置：
```ini
SUCCL_BUFFSIZE="16777216"
```
