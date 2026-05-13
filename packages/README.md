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
