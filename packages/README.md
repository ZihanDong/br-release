# download_release.sh

解析 Confluence Release 页面 HTML，按分类在本地重建目录结构并下载所有 SDK 文件。

## 依赖

- Python 3.6+（标准库，无需额外安装）
- `wget`（实际下载时需要）

## 用法

```bash
# Dry-run（默认）：仅创建目录和空占位文件，不下载
./download_release.sh <html_file> <output_dir>

# 实际下载
DRY_RUN=0 ./download_release.sh <html_file> <output_dir>
```

**示例：**

```bash
# 预览目录结构
./download_release.sh "01 - Rel_2604 Package Info - rc2 ....html" /data/release/2604rc2

# 执行下载
DRY_RUN=0 ./download_release.sh "01 - Rel_2604 Package Info - rc2 ....html" /data/release/2604rc2
```

## 输出目录结构

```
<output_dir>/
├── packages/
│   ├── ubuntu-22.04/       # 按 OS 分类的软件栈安装包
│   ├── kylin-V10/
│   ├── general/            # 不区分 OS 的包
│   ├── whl/                # Python wheel 包（始终归入此目录）
│   └── Windows/
├── images/                 # 基础容器镜像（.tar）
├── llm_codes/
│   └── <ModelName>/
│       ├── pretrain/       # 预训练
│       ├── fullparam/      # 全参微调
│       ├── lora/           # LoRA 微调
│       └── continue_pretrain/  # 继续预训练
├── model_codes/
│   └── <ModelName>/        # 小模型训练源码包
├── infer_codes/
│   └── <ModelName>/        # 模型推理源码包
└── fw_tools/               # FW 固件及 Brflash 工具
```

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `DRY_RUN` | `1` | 设为 `0` 执行实际下载；其他值均为 dry-run |

脚本启动时会自动 unset `http_proxy` / `https_proxy` 等代理变量，确保 wget 能直接访问内网 Artifactory，不影响系统全局代理设置。

## 失败处理

- 下载失败的文件会被立即删除（避免留下不完整文件）
- 所有下载完成后，若有失败则在 stderr 打印汇总：

```
============================================================
DOWNLOAD FAILURES: 4 / 326 files
============================================================
  PATH: /data/release/2512rc2/fw_tools/br104_BOOTMPUFW_xxx.tgz
  URL:  http://...
```

- 有任何失败时退出码为 `1`，全部成功退出码为 `0`
- 支持断点续传（`wget -c`）：重新运行同一命令可跳过已完整下载的文件

## HTML 格式兼容性

脚本兼容不同 release 版本的页面差异：

| 格式 | 版本示例 | packages 表列数 |
|------|----------|----------------|
| 5 列（含行号列） | 2602+   | `行号\|包名\|OS\|链接\|MD5` |
| 4 列            | 2512 及更早 | `包名\|OS\|链接\|MD5` |

文件链接的识别同时支持 `<a href>` 和单元格内纯文本 URL（Confluence `nolink` 格式）。

## 注意事项

- HTML 文件须为 Confluence 页面的完整导出（包含 `id="main-content"` 节点）
- 路径去重：同一相对路径只保留第一次出现的 URL
- 模型名称中的特殊字符会被自动过滤（仅保留 `[a-zA-Z0-9_\-.]`）

---

# GPU 设备插件安装包

`packages/` 下还存放 K8s GPU 设备插件的离线安装包，供
`setup/kubernets/set-node-mode.sh` 使用。整个 `packages/` 目录已被根 `.gitignore`
排除（含大体积镜像 / KMD），需从发布包手动填充。

## `packages/biren/` —— 原厂整卡插件（plain `biren`）

`set-node-mode.sh biren` 使用，仅整卡调度。需包含：

```
packages/biren/
├── k8s_device_plugin_*.tar      # 设备插件镜像（发布包内层 tar）
└── biren-device-plugin.yaml     # DaemonSet 配置
```

填充方式见 `setup/kubernets/README.md` 的 “BirenTech device plugin 准备”。

## `packages/hami-biren/` —— HAMi-Biren 统一插件（`biren --vgpu`）

`set-node-mode.sh biren --vgpu` 使用，同一套插件同时调度整卡 + SVI(1/2、1/4) +
vGPU 软切分。由 `hami_br_deploy` 安装包整体复制而来（`HAMI_BUNDLE_DIR` 默认指向此处）：

```
packages/hami-biren/
├── images/      hami-biren-vgpu.tar（HAMi 调度器 + biren-mode-manager）、
│                biren-hami-deviceplugin-vgpu.tar（设备插件）、load-images.sh
├── chart/       hami/（Helm chart）、values-biren-vgpu.yaml（Biren 后端 values）
├── deploy/      biren-hami-deviceplugin.yaml（设备插件 DaemonSet）
├── kmd/         biren.ko（1.12.0，vGPU 用）、br_vgpu_tool、br_container_id、补丁
├── examples/    whole_gpu / svi_half / svi_quarter / vgpu 示例 Pod
└── test/        run-tests.sh + README（整卡 / SVI / vGPU 校验）
```

填充方式：
```bash
cp -a /path/to/hami_br_deploy/. packages/hami-biren/
```

要点：
- 镜像 tag 形如 `10.50.36.126:32000/...`，`imagePullPolicy: IfNotPresent`，仅作名称用；
  `set-node-mode.sh` 会在每个目标节点 `ctr -n k8s.io images import` 导入，不走 registry 拉取。
- 整卡 / SVI 用现有壁仞驱动即可；**vGPU 软切分**额外需要节点加载与内核匹配的
  **1.12.0 KMD**（`kmd/biren.ko`，由管理员手动 `insmod`；预编译版本 vermagic 为
  `6.8.0-117-generic`，其他内核需按 `kmd/README.md` 从源码重编）。
- HAMi 调度器内置的 kube-scheduler sidecar 镜像须与集群 k8s 小版本一致，`set-node-mode.sh`
  默认探测 API server 版本并复用集群已缓存的
  `registry.aliyuncs.com/google_containers/kube-scheduler:v<版本>`。
