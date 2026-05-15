# suvs 测试环境

suvs（Supa Validation Suite）是壁仞 GPU 的硬件测试工具，支持 PCIe、P2P、HBM、内存带宽、视频、功耗、算力压力/性能等共 25 种测试任务，并通过 suvs 内置 GM 插件同步采集 GPU 时钟、温度和功耗数据。

本目录包含两个脚本，分别负责**环境搭建**和**测试执行**。

---

## 文件说明

| 文件 | 用途 |
|------|------|
| `setup_suvs.sh` | 构建 Docker 测试容器，安装 sudcgm（含 suvs 二进制） |
| `run_suvs.sh` | 在容器内执行测试，生成并保存 conf 文件，记录日志和摘要 |

---

## 快速开始

```bash
# 1. 构建容器环境（只需执行一次，或容器丢失后重建）
sudo bash base_tests/suvs/setup_suvs.sh

# 2. 运行全部测试
sudo bash base_tests/suvs/run_suvs.sh

# 加 --verbose 同步在终端查看详细输出
sudo bash base_tests/suvs/run_suvs.sh --verbose

# 只运行部分任务
sudo bash base_tests/suvs/run_suvs.sh --tasks pcie,membw,hbm0

# 指定 GPU、覆盖时长
sudo bash base_tests/suvs/run_suvs.sh --tasks spcstress_fp32 --gpu-ids 0,1 --duration 60
```

---

## setup_suvs.sh

### 执行内容

1. 检查 Docker 镜像，不存在则从 `SDK_ROOT_PATH` 导入 `.tar`
2. 删除同名旧容器，重新启动新容器（不映射 IB 设备，无需 InfiniBand）
3. 在容器内运行 `sudcgm_*.run` 安装包（提供 suvs 二进制）
4. 验证 suvs 可正常启动并列出 GPU 信息

### 主要配置变量（脚本顶部）

```bash
SDK_ROOT_PATH="/data/release/2602rc2/"   # SDK 根目录
IMAGE_NAME="birensupa-sdk:26.02.rc2-br1xx"
CONTAINER_NAME="biren_suvs"
```

---

## run_suvs.sh

### 参数

```
./run_suvs.sh [--tasks TASK[,TASK...]] [--gpu-ids IDS] [--duration SECS] [--verbose]
```

| 参数 | 说明 |
|------|------|
| `--tasks` | 逗号或空格分隔的任务列表，或 `all`（默认） |
| `--gpu-ids` | 测试动作的 GPU ID（如 `0` 或 `0,1,2`），默认 `all`；GM 监控始终覆盖全部 GPU |
| `--duration` | 统一覆盖所有任务的测试时长（秒），留空则使用各任务内置默认值 |
| `--verbose` | 向 suvs 传递 `-v` 参数以显示详细输出 |

### 默认配置变量（脚本顶部）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DEFAULT_TASKS` | `all` | 默认运行全部任务 |
| `DEFAULT_GPU_IDS` | `all` | 默认测试全部 GPU |
| `DEFAULT_DURATION` | `""` | 使用各任务内置时长 |
| `DEFAULT_VERBOSE` | `false` | 关闭详细输出 |
| `LOG_ROOT_REL` | `../../logs/suvs` | 相对于脚本目录的日志根目录（即 `logs/suvs/`） |

### 支持的测试任务

| 任务名 | 说明 | 默认时长 |
|--------|------|----------|
| `pcie` | PCIe 带宽 | 5 s |
| `p2p` | P2P 带宽 | 5 s |
| `hbm0`–`hbm10` | HBM 显存测试（共 11 种子测试） | 5 s |
| `membw` | 显存带宽 | 90 s |
| `video` | 视频解码性能 | — |
| `power_pct50` | 功耗压力（50% 功耗） | 90 s |
| `power_idle` | 空闲功耗验证 | 90 s |
| `spcstress_fp32/int8/bf16/tf32/fp16` | 算力压力测试（各精度） | 90 s |
| `spcperf_fp32/int8/bf16/tf32/fp16` | 算力性能基准（各精度） | 90 s |
| `all` | 以上全部（共 25 个任务） | — |

### conf 文件机制

每个任务在运行前动态生成一份 YAML conf 文件，结构为：

```yaml
actions:
- name: gm_start       # GM 监控启动（覆盖全部 GPU）
  plugin: gm
  ...
- name: test_<task>    # 测试动作（gpu_id、duration 等参数写入 conf）
  plugin: <plugin>
  ...
- name: gm_stop        # GM 监控停止
  plugin: gm
  ...
```

conf 文件保存在本次运行的日志目录中，同时以唯一名称软链接到容器内 suvs 的 `conf/` 目录（运行结束后自动清理）。

### 日志格式

每次运行在 `logs/suvs/<时间戳>/` 下生成：

```
suvs/20260514_132124/
├── pcie.conf           # 该任务的完整 YAML conf（含 GM 包装）
├── pcie.log            # suvs 输出（含 GM 监控数据）
├── membw.conf
├── membw.log
├── ...
└── summary.log         # 汇总：各任务状态 + 结果摘要
```

`summary.log` 示例：

```
  pcie                  PASS          PCIe Bandwidth
    [Test Pass] pciebw H2D: 25.3 GB/s  D2H: 24.8 GB/s

  membw                 PASS          Memory Bandwidth
    [Test Pass] membw peak: 1.92 TB/s

  spcstress_fp32        FAIL (exit 1) SPC Stress fp32
    [Test Fail] ...
```

---

## 注意事项

- **IOMMU**：测试前建议在宿主机关闭 IOMMU，否则影响性能
- **ACS**：测试前需关闭 ACS，否则 GPU 通信失败
- **video 任务**：依赖容器内 `/tmp/video_samples/` 目录，若不存在则跳过或报错
- **hbm9**（Bit fade）：内置时长约 90 分钟，建议单独运行
- **容器重启**：容器停止后需重新执行 `setup_suvs.sh` 重建环境（sudcgm 安装在容器内层，不持久化）
