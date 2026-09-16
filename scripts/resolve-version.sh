#!/usr/bin/env bash
set -euo pipefail

# 统一解析 OpenWrt 官方最新稳定版或验证指定版本号
# 用法: ./scripts/resolve-version.sh [version_or_latest]

REQUESTED_VERSION="${1:-${OPENWRT_VERSION:-latest}}"

get_latest_stable_version() {
    local latest_ver=""
    # 1. 优先尝试从 OpenWrt 官方权威版本元数据接口获取
    latest_ver="$(curl -fsSL --retry 3 --connect-timeout 15 \
        https://downloads.openwrt.org/.versions.json 2>/dev/null |
        python3 -c 'import json,sys; print(json.load(sys.stdin)["stable_version"])' \
        2>/dev/null || true)"
    if [ -z "$latest_ver" ]; then
        # 2. 备选方案：从 releases 页面提取最新数字版本号目录
        latest_ver="$(curl -fsSL --retry 3 --connect-timeout 15 \
            https://downloads.openwrt.org/releases/ 2>/dev/null |
            sed -nE 's/.*href="([0-9]+\.[0-9]+\.[0-9]+)\/".*/\1/p' |
            sort -V | tail -n 1 || true)"
    fi
    [ -n "$latest_ver" ] || return 1
    printf '%s\n' "$latest_ver"
}

version="${REQUESTED_VERSION}"
if [ -z "$version" ] || [ "$version" = "latest" ]; then
    if ! version="$(get_latest_stable_version)"; then
        echo "❌ 错误: 无法确认 OpenWrt 官方最新稳定版。" >&2
        exit 1
    fi
fi

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]]; then
    echo "❌ 错误: 无效的 OpenWrt 版本号: ${version}" >&2
    exit 1
fi

printf '%s\n' "${version}"

