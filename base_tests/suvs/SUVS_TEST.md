# 壁仞™ suVS 操作指南


## 1. 安装

Host中安装基础驱动后（biren容器中不需要），需在测试环境下安装sudcgm安装包  
安装成功后，启动suVS（出现下图说明安装并启动成功）
```bash
suvs -g 2>&1 | tee suvs_start.log
```

## 2. 配置文件

配置文件通过命令行参数 `-c` 或 `--config` 来使用

### 常用配置键

| 选项 | 说明 |
|------|------|
| -a/--appendLog | 增补日志 |
| -c/--config | 指定配置文件 |
| -d/--debugLevel | 调试级别(0-5) |
| -g/--listGpus | 列出可用GPU |
| -i/--indexes | 指定GPU id列表 |
| -l/--debugLogFile | 指定日志文件 |
| -t/--listTests | 列出可用插件 |
| -v/--verbose | 详细报告 |
| --version | 显示版本信息 |
| -h/--help | 显示帮助信息 |


### BRsmi 使用

监控gpu板卡信息，比如功耗、温度、时钟等
```bash
brsmi gpu dmon -d 1 -s pucmet -o DT 2>&1 | tee brsmi_dmon.log
```

## 3. 测试项

### 3.1. GPU INFO

获取当前平台上的GPU设备信息
```bash
suvs -c gpuinfo.conf 2>&1 | tee gpuinfo.log
```

### 3.2. SOFTWARE

检查各种运行时库的安装情况及版本信息
```bash
suvs -c software.conf 2>&1 | tee software.log
```

### 3.3. PCIE BANDWIDTH

测试CPU和GPU之间的传输带宽
```bash
suvs -c pcie_1.conf 2>&1 | tee pcie_1.log
```

### 3.4. P2P BANDWIDTH

测试GPU之间的带宽
```bash
suvs -c p2p_1.conf 2>&1 | tee p2p_1.log
```

### 3.5. HBM MEMORY TEST

检测GPU内存的稳定度

Test 0 [Walking 1 bit]
```bash
suvs -c hbm.conf -test 0 2>&1 | tee hbm_test0.log
```

Test 1 [Own address test]
```bash
suvs -c hbm.conf -test 1 2>&1 | tee hbm_test1.log
```

Test 2 [Moving inversions, ones&zeros]
```bash
suvs -c hbm.conf -test 2 2>&1 | tee hbm_test2.log
```

Test 3 [Moving inversions, 8 bit pat]
```bash
suvs -c hbm.conf -test 3 2>&1 | tee hbm_test3.log
```

Test 4 [Moving inversions, random pattern]
```bash
suvs -c hbm.conf -test 4 2>&1 | tee hbm_test4.log
```

Test 5 [Block move, 64 moves]
```bash
suvs -c hbm.conf -test 5 2>&1 | tee hbm_test5.log
```

Test 6 [Moving inversions, 32 bit pat]
```bash
suvs -c hbm.conf -test 6 2>&1 | tee hbm_test6.log
```

Test 7 [Random number sequence]
```bash
suvs -c hbm.conf -test 7 2>&1 | tee hbm_test7.log
```

Test 8 [Modulo 20, random pattern]
```bash
suvs -c hbm.conf -test 8 2>&1 | tee hbm_test8.log
```

Test 9 [Bit fade test, 90 min, 2 patterns]
```bash
suvs -c hbm.conf -test 9 2>&1 | tee hbm_test9.log
```

Test 10 [memory stress test]
```bash
suvs -c hbm.conf -test 10 2>&1 | tee hbm_test10.log
```

### 3.6. MEMORY BANDWIDTH

测试GPU内存带宽
```bash
suvs -c membw.conf 2>&1 | tee membw.log
```

### 3.7. VIDEO PERFORMANCE

测试视频及图片的编解码能力
```bash
suvs -c video.conf 2>&1 | tee video.log
```

BR110平台
```bash
suvs -c video_br110.conf 2>&1 | tee video_br110.log
```

root下运行需先执行
```bash
source /etc/profile.d/biren.sh
```

### 3.8. POWER STRESS

测试GPU处于特定功耗下的稳定运行能力

功耗等级测试
```bash
suvs -c spcpower.conf -power_pct 50 2>&1 | tee spcpower_pct50.log
```

idle power测试
```bash
suvs -c spcpower.conf -power_test_idle -idle_power_max 80 -idle_power_min 30 2>&1 | tee spcpower_idle.log
```

### 3.9. SPC STRESS

SPC算力压力测试，包含数据从CPU拷贝到GPU的过程

fp32
```bash
suvs -c spcstress.conf -type fp32 -replicate 2>&1 | tee spcstress_fp32.log
```

int8
```bash
suvs -c spcstress.conf -type int8 -replicate 2>&1 | tee spcstress_int8.log
```

bf16
```bash
suvs -c spcstress.conf -type bf16 -replicate 2>&1 | tee spcstress_bf16.log
```

tf32+
```bash
suvs -c spcstress.conf -type tf32 -replicate 2>&1 | tee spcstress_tf32.log
```

fp16
```bash
suvs -c spcstress.conf -type fp16 -replicate 2>&1 | tee spcstress_fp16.log
```

### 3.10. SPC PERFORMANCE

SPC算力压力测试，不包含数据从CPU拷贝到GPU的过程

fp32
```bash
suvs -c spcperf.conf -type fp32 -replicate 2>&1 | tee spcperf_fp32.log
```

int8
```bash
suvs -c spcperf.conf -type int8 -replicate 2>&1 | tee spcperf_int8.log
```

bf16
```bash
suvs -c spcperf.conf -type bf16 -replicate 2>&1 | tee spcperf_bf16.log
```

tf32+
```bash
suvs -c spcperf.conf -type tf32 -replicate 2>&1 | tee spcperf_tf32.log
```

fp16
```bash
suvs -c spcperf.conf -type fp16 -replicate 2>&1 | tee spcperf_fp16.log
```

### 3.11. GPU MONITOR

配合其他测试，监测测试过程中的功耗、温度、时钟等信息
```bash
suvs -c spcpower_gm.conf -max_temp 98 -d 3 2>&1 | tee spcpower_gm_maxtemp98.log
```

## 4. 注意事项

如果遇到 libglog.so.0 缺失错误
```bash
sudo apt install libgoogle-glog-dev
```

