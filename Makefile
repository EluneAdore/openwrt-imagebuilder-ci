# ==============================================================================
# OpenWrt ImageBuilder CI / 本地 WSL2 自动化构建 Makefile
# ==============================================================================
# 提供常用的构建、依赖安装及清理命令快捷入口。
# ==============================================================================

.PHONY: all help build image env clean distclean

# 默认目标：输出帮助说明
all: help

# 帮助信息与可用指令汇总
help:
	@echo "=================================================================="
	@echo "  OpenWrt ImageBuilder CI / 本地 WSL2 自动化构建指令集"
	@echo "=================================================================="
	@echo ""
	@echo "常用命令:"
	@echo "  make env         - 检查并一键安装 Ubuntu/WSL2 构建所需系统依赖"
	@echo "  make build       - 启动固件编译与打包 (等同于 make image，产物在 bin/)"
	@echo "  make clean       - 清理 bin/ 目录下的历史构建产物"
	@echo "  make distclean   - 彻底清理工作区 (删除 .work 下载缓存与 bin/ 产物)"
	@echo ""
	@echo "环境变量自定义示例:"
	@echo "  ROOTFS_PARTSIZE=2048 make build        # 设置根分区大小 (默认 2048 即 2GB)"
	@echo "  GRUB_TIMEOUT=0 make build              # 设置 GRUB 启动等待时间 (默认 0 即开机不等待直接引导)"
	@echo "  OPENWRT_VERSION=latest make build      # 默认自动检测官方最新稳定版，亦可指定如 25.12.5"
	@echo "  BUILD_DATE=20260914-1600 make build    # 自定义版本时间戳标识"
	@echo "=================================================================="

# 依赖环境初始化
env:
	@bash scripts/setup-env.sh

# 固件构建目标
build:
	@bash scripts/build.sh

image: build

# 清理构建产物
clean:
	@echo "==> 正在清理构建交付目录 (bin/)..."
	@rm -rf bin/*

# 彻底清理工作区与下载缓存
distclean: clean
	@echo "==> 正在彻底清理下载缓存与构建工作区 (.work/)..."
	@rm -rf .work
