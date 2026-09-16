#!/usr/bin/env bash
set -euo pipefail

# 清理 WSL2 环境下从 Windows 继承的含空格或特殊字符 PATH
CLEAN_PATH=""
IFS=':' read -ra ADDR <<< "$PATH"
for p in "${ADDR[@]}"; do
    case "$p" in
        /mnt/*|*" "*|*"("*|*")"*) continue ;;
        *) CLEAN_PATH="${CLEAN_PATH:+${CLEAN_PATH}:}$p" ;;
    esac
done
export PATH="$CLEAN_PATH"

# ==============================================================================
# OpenWrt 官方 SDK 下载、SHA-256 校验与环境初始化脚本 (setup-sdk.sh)
# 用法: SDK_DIR="$(./scripts/setup-sdk.sh [OPENWRT_VERSION|latest] [WORK_DIR])"
# 注意: stdout 严格仅输出 SDK_DIR 路径，所有日志一律输出到 stderr
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPENWRT_VERSION="${1:-${OPENWRT_VERSION:-latest}}"
WORK_DIR="${2:-${WORK_DIR:-.work}}"
ARCH="${ARCH:-x86-64}"
TARGET_PATH="${TARGET_PATH:-x86/64}"

# 1. 统一解析版本 (支持 latest 或具体稳定版号如 25.12.5)
if [ -z "${OPENWRT_VERSION}" ] || [ "${OPENWRT_VERSION}" = "latest" ]; then
    OPENWRT_VERSION="$("${SCRIPT_DIR}/resolve-version.sh" "latest")"
fi

mkdir -p "${WORK_DIR}"
WORK_DIR="$(cd "${WORK_DIR}" && pwd)"

TARGET_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${TARGET_PATH}"

# 2. 查询 OpenWrt 官方发布目录并锁定确切 SDK 压缩包文件名
echo "==> 查询 OpenWrt ${OPENWRT_VERSION} ${TARGET_PATH} 官方 SDK 下载目录..." >&2
target_index="$(curl -fsSL --retry 3 --connect-timeout 15 "${TARGET_URL}/")" || {
    echo "❌ 错误: 无法读取 OpenWrt SDK 下载目录: ${TARGET_URL}/" >&2
    exit 1
}

sdk_matches=""
if sdk_matches="$(printf '%s' "${target_index}" |
    grep -oE "openwrt-sdk-${OPENWRT_VERSION//./\\.}-${ARCH}_[^\"<>[:space:]]+\\.Linux-x86_64\\.tar\\.zst")"; then
    sdk_candidates="$(printf '%s\n' "${sdk_matches}" | sort -u)"
else
    sdk_candidates=""
fi
sdk_tarball="$(printf '%s\n' "${sdk_candidates}" | sed -n '1p')"
[ -n "${sdk_tarball}" ] || {
    echo "❌ 错误: 未找到 OpenWrt ${OPENWRT_VERSION} 的 ${TARGET_PATH} SDK。" >&2
    exit 1
}
[ "$(printf '%s\n' "${sdk_candidates}" | sed '/^$/d' | wc -l)" -eq 1 ] || {
    echo "❌ 错误: SDK 下载目录存在多个候选文件，无法安全选择。" >&2
    exit 1
}

sdk_archive="${WORK_DIR}/${sdk_tarball}"
sdk_dir="${WORK_DIR}/${sdk_tarball%.tar.zst}"
checksums_file="${WORK_DIR}/sha256sums-${OPENWRT_VERSION}-${ARCH}-sdk"

# 3. 获取官方 sha256sums 并提取预期校验和
curl -fsSL --retry 3 --connect-timeout 15 "${TARGET_URL}/sha256sums" -o "${checksums_file}"
expected_sha256="$(awk -v filename="${sdk_tarball}" '
    $2 == filename || $2 == "*" filename { print $1; exit }
' "${checksums_file}")"
[ -n "${expected_sha256}" ] || {
    echo "❌ 错误: 官方 sha256sums 中没有 ${sdk_tarball}。" >&2
    exit 1
}

archive_is_valid() {
    [ -f "${sdk_archive}" ] && printf '%s  %s\n' "${expected_sha256}" "${sdk_archive}" |
        sha256sum --check --status
}

# 4. 无论是否已存在/缓存命中，一律严格校验 SHA256；若不符则重新下载
if ! archive_is_valid; then
    echo "==> 正在下载官方 SDK: ${sdk_tarball}..." >&2
    rm -f "${sdk_archive}" "${sdk_archive}.part"
    curl -fL --retry 3 --connect-timeout 15 "${TARGET_URL}/${sdk_tarball}" \
        -o "${sdk_archive}.part"
    mv -f "${sdk_archive}.part" "${sdk_archive}"
else
    echo "==> 本地/缓存 SDK 压缩包 SHA-256 校验通过: ${sdk_tarball}" >&2
fi
archive_is_valid || {
    echo "❌ 错误: SDK SHA-256 校验失败: ${sdk_tarball}。" >&2
    exit 1
}

# 5. 解包 SDK
if [ ! -f "${sdk_dir}/Makefile" ]; then
    echo "==> 正在解压 SDK: ${sdk_tarball}..." >&2
    rm -rf "${sdk_dir}"
    tar --zstd -xf "${sdk_archive}" -C "${WORK_DIR}"
else
    echo "==> 检测到已就绪的本地 SDK 目录: ${sdk_dir}" >&2
fi
[ -f "${sdk_dir}/Makefile" ] || {
    echo "❌ 错误: SDK 解压后目录结构不完整: ${sdk_dir}。" >&2
    exit 1
}

# 6. 可选注入外部指定的自定义签名私钥 (若配置了 GitHub Secret CUSTOM_SIGNING_KEY)
CUSTOM_SIGNING_KEY="${CUSTOM_SIGNING_KEY:-${SIGNING_KEY_PEM:-}}"
if [ -n "${CUSTOM_SIGNING_KEY}" ]; then
    echo "==> 注入统一自定义 APK 签名私钥..." >&2
    printf '%s\n' "${CUSTOM_SIGNING_KEY}" > "${sdk_dir}/private-key.pem"
    chmod 600 "${sdk_dir}/private-key.pem"
    if command -v openssl >/dev/null 2>&1; then
        openssl ec -in "${sdk_dir}/private-key.pem" -pubout > "${sdk_dir}/public-key.pem" 2>/dev/null || true
        [ -s "${sdk_dir}/public-key.pem" ] && chmod 644 "${sdk_dir}/public-key.pem"
    fi
fi

# 7. 将最终确认的 SDK 绝对路径严格仅输出至 stdout
printf '%s\n' "${sdk_dir}"
