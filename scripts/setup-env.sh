#!/usr/bin/env bash
# ==============================================================================
# OpenWrt ImageBuilder 本地构建环境依赖检测与自动安装脚本 (setup-env.sh)
# ==============================================================================
# 用途:
# 1. 检查 Ubuntu / Debian / WSL2 宿主机是否已安装构建 OpenWrt 所需的核心工具链与库。
# 2. 自动识别缺失的依赖项，并尝试通过 apt-get (支持 sudo 或 root 模式) 进行静默补全安装。
# ==============================================================================
set -euo pipefail

echo "=================================================="
echo "  正在检查 OpenWrt ImageBuilder 所需编译依赖..."
echo "=================================================="

# 必备构建依赖列表及其用途:
# - build-essential, clang, flex, bison, bzip2: SDK 源码编译与解包工具
# - gcc-multilib, g++-multilib: helloworld 官方 CI 使用的多架构宿主工具链
# - libncurses-dev: 终端控制台图形库
# - zlib1g-dev, libssl-dev: 压缩与加解密支持库
# - gawk, gettext, git, rsync, file: 源码获取、文本处理与同步工具
# - wget, curl: 软件包与镜像下载工具
# - tar, zstd, unzip: SDK 源码包与官方构建工具解包
# - python3: 软件包清单比对脚本 (diff_manifest.py) 运行环境
DEPS=(
    build-essential
    clang
    flex
    bison
    bzip2
    g++
    gcc-multilib
    g++-multilib
    libncurses-dev
    zlib1g-dev
    gawk
    git
    gettext
    libssl-dev
    rsync
    wget
    curl
    file
    tar
    zstd
    unzip
    python3
)

MISSING_DEPS=()
for dep in "${DEPS[@]}"; do
    if ! dpkg -s "$dep" >/dev/null 2>&1; then
        MISSING_DEPS+=("$dep")
    fi
done

if [ ${#MISSING_DEPS[@]} -eq 0 ]; then
    echo "✓ 检查通过：所有必备构建依赖均已就绪。"
else
    echo "⚠️ 发现缺失以下构建依赖: ${MISSING_DEPS[*]}"
    echo "==> 正在尝试自动安装缺失依赖..."
    if command -v sudo >/dev/null 2>&1; then
        if ! sudo apt-get update || \
           ! sudo apt-get install -y "${MISSING_DEPS[@]}"; then
            echo "❌ 错误: 自动安装依赖失败！请手动在宿主机执行:"
            echo "   sudo apt-get update && sudo apt-get install -y ${MISSING_DEPS[*]}"
            exit 1
        fi
    else
        if ! apt-get update || ! apt-get install -y "${MISSING_DEPS[@]}"; then
            echo "❌ 错误: 自动安装依赖失败！请以 root 权限执行:"
            echo "   apt-get update && apt-get install -y ${MISSING_DEPS[*]}"
            exit 1
        fi
    fi
    echo "✓ 所有依赖已成功安装完成！"
fi
