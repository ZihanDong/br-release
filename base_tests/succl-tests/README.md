# succl-tests 测试环境

succl-tests 是壁仞 GPU 通信库（suCCL）的性能与正确性测试工具，支持 AllReduce、AllGather、Alltoall 等 11 种集合通信算子。

本目录包含两个脚本，分别负责**环境搭建**和**测试执行**。

---

## 文件说明

| 文件 | 用途 |
|------|------|
| `setup_succl-tests.sh` | 构建 Docker 测试容器，安装 succl-tests 和 openMPI，配置 SSH 免密（多节点） |
| `run_succl_tests.sh` | 在容器内执行测试，自动记录日志和峰值带宽摘要 |
| `壁仞_succl-tests_用户指南_V1.10.0.x_202602.pdf` | 官方用户手册，含参数说明和测试规格 |

---

## 快速开始

### 单节点测试

```bash
# 1. 构建容器环境（只需执行一次）
sudo bash base_tests/succl-tests/setup_succl-tests.sh single

# 2. 运行全部算子，8 卡
sudo bash base_tests/succl-tests/run_succl_tests.sh single all 8

# 加 -v 同步在终端查看输出
sudo bash base_tests/succl-tests/run_succl_tests.sh -v single all 8

# 只测单个算子
sudo bash base_tests/succl-tests/run_succl_tests.sh single allreduce 8
```

### 多节点测试

```bash
# 1. 在每个节点上构建容器（需要提供加密密钥的解密密码）
sudo bash base_tests/succl-tests/setup_succl-tests.sh multi --pass <解密密码>

# 2. 编辑 run_succl_tests.sh 顶部的多节点配置变量：
#      MPI_HOSTS="10.9.1.10:8,10.9.1.11:8"   # 各节点 IP 和 GPU 数
#      MPI_IFACE="ens110f0"                    # MPI TCP 通信网卡

# 3. 在主节点上执行（mpiexec 会 SSH 到其他节点）
sudo bash base_tests/succl-tests/run_succl_tests.sh multi allreduce 8
```

---

## setup_succl-tests.sh

### 参数

| 参数 | 说明 |
|------|------|
| `single` | 单节点模式：不映射 IB 设备，不配置 SSH |
| `multi` | 多节点模式：自动检测并映射 IB 设备，配置容器间 SSH 免密登录 |
| `--pass <密码>` | multi 模式必填，解密 `setup/ssh-settings/biren-ssh-pass.tar.gz.enc` |

### 执行内容

1. 检测 `/dev/infiniband/uverbs*`，multi 模式下有则映射入容器
2. 加载 Docker 镜像（若不存在则从 `SDK_ROOT_PATH` 导入 `.tar`）
3. 删除同名旧容器，重新启动新容器
4. **[multi]** 安装 `openssh-server`，配置 sshd 端口 `SSH_PORT`（默认 2222），部署共享 RSA 密钥
5. 解压 succl-tests 安装包到容器 `/opt/succl-tests`
6. 检查 openMPI，不存在则从源码编译安装（约 10 分钟）
7. 写入环境变量配置 `/etc/profile.d/succl-tests.sh`
8. 探测 GPU 型号（BR166M 自动启用 UMA16 内存模式），结果写入 `/etc/succl-hw.conf`
9. 验证：[multi] SSH 自检；[single] mpiexec 和二进制文件检查

### 主要配置变量（脚本顶部）

```bash
SDK_ROOT_PATH="/data/release/2602rc2/"   # SDK 根目录
IMAGE_NAME="birensupa-sdk:26.02.rc2-br1xx"
CONTAINER_NAME="biren_succl_tests"
SSH_PORT=2222
```

---

## run_succl_tests.sh

### 参数

```
./run_succl_tests.sh [-v] <mode> <op> <gpus>
```

| 参数 | 取值 | 说明 |
|------|------|------|
| `-v` | — | 详细模式，输出同时显示在终端 |
| `mode` | `single` \| `multi` | 单节点 / 多节点 |
| `op` | 见下表 | 算子名称，`all` 表示全部 |
| `gpus` | 正整数 | GPU 卡数（single: 总卡数；multi: 每节点卡数） |

支持的算子：

| 参数值 | 对应二进制 |
|--------|-----------|
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

### 测试参数配置变量（脚本顶部）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `LOG_PATH` | `<repo>/logs/succl-tests`（相对脚本位置） | 日志根目录（可通过环境变量覆盖） |
| `MIN_BYTES` | `512` | 起始数据量（需 512 对齐） |
| `MAX_BYTES` | `1G` | 最大数据量 |
| `STEP_FACTOR` | `2` | 数据量倍增因子（`STEP_BYTES=0` 时生效） |
| `STEP_BYTES` | `0` | 固定步进字节数，大于 0 时优先于 `STEP_FACTOR` |
| `DATATYPE` | `float` | 数据精度：`float` \| `BF16` |
| `REDUCE_OP` | `sum` | 归约操作：`sum` \| `prod` \| `min` \| `max` \| `avg` \| `all` |
| `ITERS` | `3` | 计时迭代次数（范围 1–20，过大会 OOM） |
| `WARMUP_ITERS` | `3` | 预热迭代次数（范围 0–10） |
| `CHECK` | `1` | 结果校验：`0`=跳过（快）\| `1`=校验 |
| `BR166_MODE` | `auto` | BR166 UMA16 模式：`auto`=自动检测 \| `0`=关闭 \| `1`=强制开启 |
| `MPI_HOSTS` | 空 | **多节点必填**，格式：`ip1:slots,ip2:slots` |
| `MPI_IFACE` | 空 | MPI TCP 网卡，留空则排除 lo |
| `SSH_PORT` | `2222` | 与 setup 脚本配置一致 |
| `SUCCL_BUFFSIZE` | 空 | 4+ 节点某些算子需设为 `16777216`（16 MiB） |

### 日志格式

每次运行在 `LOG_PATH/succl-tests_<时间戳>/` 下生成：

```
succl-tests_20260514_132124/
├── allreduce.log       # 首行: # CMD: <完整执行命令>，其后为全量测试输出
├── allgather.log
├── ...
└── summary.log         # 汇总：各算子状态 + 峰值 AlgBW / BusBW / 数据量 / 精度
```

`summary.log` 示例：
```
  allreduce:       OK   algbw  50.37 GB/s  busbw  88.15 GB/s  @ 1 GiB    float
  allgather:       OK   algbw 123.77 GB/s  busbw 108.30 GB/s  @ 1 GiB    float
  sendrecv:        OK   algbw  32.31 GB/s  busbw  32.31 GB/s  @ 64 MiB   float
```

---

## 注意事项

- **BR166M 硬件**：必须使用 `-k 1`（UMA16 内存模式），`setup_succl-tests.sh` 会自动探测并写入配置，`run_succl_tests.sh` 默认读取该配置（`BR166_MODE=auto`）
- **IOMMU**：测试前建议在宿主机关闭 IOMMU，否则影响性能（详见用户手册第 2.3 节）
- **ACS**：测试前需关闭 ACS，否则 suCCL 通信失败（详见用户手册第 2.3 节）
- **多节点防火墙**：需关闭防火墙，禁用 IPv6
- **4+ 节点大数据量**：SendRecv / Gather / Scatter / Hypercube / Alltoall / Alltoallv 需设置 `SUCCL_BUFFSIZE=16777216`
