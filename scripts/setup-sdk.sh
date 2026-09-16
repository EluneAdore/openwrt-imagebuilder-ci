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
# OpenWrt 官方 SDK 下载与环境初始化脚本 (setup-sdk.sh)
# 用法: SDK_DIR="$(./scripts/setup-sdk.sh [OPENWRT_VERSION] [WORK_DIR])"
# ==============================================================================

OPENWRT_VERSION="${1:-${OPENWRT_VERSION:-}}"
WORK_DIR="${2:-${WORK_DIR:-.work}}"
ARCH="${ARCH:-x86-64}"
TARGET_PATH="${TARGET_PATH:-x86/64}"

[ -n "${OPENWRT_VERSION}" ] || {
    echo "❌ 错误: 必须指定 OPENWRT_VERSION。" >&2
    exit 1
}

mkdir -p "${WORK_DIR}"
WORK_DIR="$(cd "${WORK_DIR}" && pwd)"

# 检查当前目录是否已存在匹配的已解压 SDK
sdk_dirs=()
while IFS= read -r candidate; do
    [ -f "${candidate}/Makefile" ] && sdk_dirs+=("${candidate}")
done < <(find "${WORK_DIR}" -maxdepth 1 -type d \
    -name "openwrt-sdk-${OPENWRT_VERSION}-${ARCH}_*.Linux-x86_64" -print 2>/dev/null)

if [ ${#sdk_dirs[@]} -eq 1 ]; then
    sdk_dir="${sdk_dirs[0]}"
    echo "==> 检测到已就绪的本地 SDK: ${sdk_dir}" >&2
else
    TARGET_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${TARGET_PATH}"
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

    curl -fsSL --retry 3 --connect-timeout 15 "${TARGET_URL}/sha256sums" -o "${checksums_file}"
    expected_sha256="$(awk -v filename="${sdk_tarball}" '
        $2 == filename || $2 == "*" filename { print $1; exit }
    ' "${checksums_file}")"
    [ -n "${expected_sha256}" ] || {
        echo "❌ 错误: 官方 sha256sums 中没有 ${sdk_tarball}。" >&2
        exit 1
    }

    archive_is_valid() {
        printf '%s  %s\n' "${expected_sha256}" "${sdk_archive}" |
            sha256sum --check --status
    }

    if [ ! -f "${sdk_archive}" ] || ! archive_is_valid; then
        echo "==> 正在下载官方 SDK: ${sdk_tarball}..." >&2
        rm -f "${sdk_archive}" "${sdk_archive}.part"
        curl -fL --retry 3 --connect-timeout 15 "${TARGET_URL}/${sdk_tarball}" \
            -o "${sdk_archive}.part"
        mv -f "${sdk_archive}.part" "${sdk_archive}"
    fi
    archive_is_valid || {
        echo "❌ 错误: SDK SHA-256 校验失败: ${sdk_tarball}。" >&2
        exit 1
    }

    if [ ! -f "${sdk_dir}/Makefile" ]; then
        echo "==> 正在解压 SDK: ${sdk_tarball}..." >&2
        rm -rf "${sdk_dir}"
        tar --zstd -xf "${sdk_archive}" -C "${WORK_DIR}"
    fi
    [ -f "${sdk_dir}/Makefile" ] || {
        echo "❌ 错误: SDK 解压后目录结构不完整: ${sdk_dir}。" >&2
        exit 1
    }
fi

# 可选注入外部指定的自定义签名私钥 (若配置了 GitHub Secret CUSTOM_SIGNING_KEY)
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

# 将最终确认的 SDK 绝对路径输出至 stdout
printf '%s\n' "${sdk_dir}"
