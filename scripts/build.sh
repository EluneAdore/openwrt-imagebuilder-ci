#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# 清理 WSL2 环境下从 Windows 继承的含空格 PATH (防止 find -execdir 因相对路径或空格报错)
CLEAN_PATH=""
IFS=':' read -ra ADDR <<< "$PATH"
for p in "${ADDR[@]}"; do
    case "$p" in
        /mnt/*|*" "*) continue ;;
        *) CLEAN_PATH="${CLEAN_PATH:+${CLEAN_PATH}:}$p" ;;
    esac
done
export PATH="$CLEAN_PATH"

# ============================
# 构建参数配置 (支持环境变量重载)
# ============================
# 自动探测 OpenWrt 官方最新稳定版本 (通过官方元数据接口)
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

OPENWRT_VERSION="${OPENWRT_VERSION:-latest}"
if [ "$OPENWRT_VERSION" = "latest" ] || [ -z "$OPENWRT_VERSION" ]; then
    echo "==> 检测到未指定固定版本号，正在查询 OpenWrt 官方最新稳定版..."
    if ! OPENWRT_VERSION="$(get_latest_stable_version)"; then
        echo "❌ 错误: 无法确认 OpenWrt 官方最新稳定版，已停止构建以免回退到旧版本。" >&2
        exit 1
    fi
    echo "==> 成功锁定最新稳定版本: ${OPENWRT_VERSION}"
fi
if ! [[ "${OPENWRT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]]; then
    echo "❌ 错误: 无效的 OpenWrt 版本号: ${OPENWRT_VERSION}" >&2
    exit 1
fi

VERSION_SERIES="$(echo "${OPENWRT_VERSION}" | cut -d. -f1-2)"
ARCH="${ARCH:-x86-64}"
PROFILE="${PROFILE:-generic}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-2048}"
GRUB_TIMEOUT="${GRUB_TIMEOUT:-0}"
TARGET_FILESYSTEMS="${TARGET_FILESYSTEMS:-squashfs}"
IMAGES="${IMAGES:-combined-efi.img.gz}"
BUILD_DATE="${BUILD_DATE:-$(date +"%Y%m%d-%H%M")}"

WORK_DIR="${WORKSPACE_ROOT}/.work"
BIN_DIR="${WORKSPACE_ROOT}/bin"
CONFIG_DIR="${WORKSPACE_ROOT}/config"
FILES_DIR="${WORKSPACE_ROOT}/files"
HELLOWORLD_OUTPUT_DIR="${WORK_DIR}/helloworld-packages-${OPENWRT_VERSION}"
FULLCONE_OUTPUT_DIR="${WORK_DIR}/fullcone-packages-${OPENWRT_VERSION}"
LUCI_FULLCONE_OUTPUT_DIR="${WORK_DIR}/luci-fullcone-packages-${OPENWRT_VERSION}"

IB_TARBALL="openwrt-imagebuilder-${OPENWRT_VERSION}-${ARCH}.Linux-x86_64.tar.zst"
IB_DIR_NAME="openwrt-imagebuilder-${OPENWRT_VERSION}-${ARCH}.Linux-x86_64"
IB_DIR="${WORK_DIR}/${IB_DIR_NAME}"
DOWNLOAD_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/x86/64/${IB_TARBALL}"
CHECKSUMS_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/x86/64/sha256sums"

echo "=================================================="
echo "  OpenWrt ImageBuilder 固件自动化构建流水线"
echo "  版本:     ${OPENWRT_VERSION} (系列: ${VERSION_SERIES})"
echo "  架构:     ${ARCH} (${PROFILE})"
echo "  分区大小: ${ROOTFS_PARTSIZE} MB (2GB)"
echo "  引导等待: ${GRUB_TIMEOUT}s (0s 即刻引导)"
echo "  镜像类型: ${IMAGES}"
echo "  构建时间: ${BUILD_DATE}"
echo "=================================================="

mkdir -p "${WORK_DIR}"
mkdir -p "${BIN_DIR}"

# 1. 检查或准备 ImageBuilder
if [ ! -d "${IB_DIR}" ]; then
    IB_ARCHIVE="${WORK_DIR}/${IB_TARBALL}"
    IB_CHECKSUMS="${WORK_DIR}/sha256sums-${OPENWRT_VERSION}-imagebuilder"
    curl -fsSL --retry 3 --connect-timeout 15 "${CHECKSUMS_URL}" -o "${IB_CHECKSUMS}"
    IB_EXPECTED_SHA256="$(awk -v filename="${IB_TARBALL}" '
        $2 == filename || $2 == "*" filename { print $1; exit }
    ' "${IB_CHECKSUMS}")"
    if [ -z "${IB_EXPECTED_SHA256}" ]; then
        echo "❌ 错误: 官方 sha256sums 中没有 ${IB_TARBALL}。" >&2
        exit 1
    fi

    if [ ! -f "${IB_ARCHIVE}" ] || \
       ! printf '%s  %s\n' "${IB_EXPECTED_SHA256}" "${IB_ARCHIVE}" |
           sha256sum --check --status; then
        echo "==> 正在下载官方 ImageBuilder (${IB_TARBALL})..."
        rm -f "${IB_ARCHIVE}" "${IB_ARCHIVE}.part"
        curl -fL --retry 3 --connect-timeout 15 "${DOWNLOAD_URL}" \
            -o "${IB_ARCHIVE}.part"
        mv -f "${IB_ARCHIVE}.part" "${IB_ARCHIVE}"
    fi
    printf '%s  %s\n' "${IB_EXPECTED_SHA256}" "${IB_ARCHIVE}" |
        sha256sum --check --status || {
            echo "❌ 错误: ImageBuilder SHA-256 校验失败。" >&2
            exit 1
        }
    echo "==> 正在解压 ImageBuilder..."
    tar --zstd -xf "${IB_ARCHIVE}" -C "${WORK_DIR}"
else
    echo "==> 已检测到就绪的 ImageBuilder 目录: ${IB_DIR}"
fi

# 以当前项目配置为准重建仓库列表，避免复用 .work 时带入历史第三方源。
OFFICIAL_REPOSITORIES="${IB_DIR}/repositories.official.tmp"
awk '/^https:\/\/downloads\.openwrt\.org\/releases\// { print }' \
    "${IB_DIR}/repositories" > "${OFFICIAL_REPOSITORIES}"
if [ ! -s "${OFFICIAL_REPOSITORIES}" ]; then
    echo "❌ 错误: ImageBuilder 中没有可用的 OpenWrt 官方软件源。" >&2
    exit 1
fi
mv -f "${OFFICIAL_REPOSITORIES}" "${IB_DIR}/repositories"

# 2. 导入项目配置的第三方签名公钥
echo "==> 正在导入第三方签名公钥..."
mkdir -p "${IB_DIR}/keys"
# 清理未由当前项目配置管理的旧式第三方公钥。
find "${IB_DIR}/keys" -maxdepth 1 -type f -name '*.pub' -delete
rm -f \
    "${IB_DIR}/keys/helloworld-public-key.pem" \
    "${IB_DIR}/keys/fullcone-public-key.pem" \
    "${IB_DIR}/keys/custom-sdk-public-key.pem"
if [ -d "${CONFIG_DIR}/keys" ]; then
    cp -f "${CONFIG_DIR}/keys"/* "${IB_DIR}/keys/" 2>/dev/null || true
fi

# 3. 按 fw876/helloworld 官方 CI 流程编译 SSR Plus APK
echo "==> 开始源码编译 SSR Plus 官方 APK 列表..."
OPENWRT_VERSION="${OPENWRT_VERSION}" \
WORK_DIR="${WORK_DIR}" \
OUTPUT_DIR="${HELLOWORLD_OUTPUT_DIR}" \
ARCH="${ARCH}" \
GO_FEED_BRANCH="${GO_FEED_BRANCH:-master}" \
"${SCRIPT_DIR}/build-helloworld.sh"

# 4. 使用同一个官方 SDK 编译 ImmortalWrt nftables FullCone 调用链
echo "==> 开始源码编译 FullCone APK 调用链..."
OPENWRT_VERSION="${OPENWRT_VERSION}" \
WORK_DIR="${WORK_DIR}" \
OUTPUT_DIR="${FULLCONE_OUTPUT_DIR}" \
ARCH="${ARCH}" \
"${SCRIPT_DIR}/build-fullcone.sh"

# 5. 在官方 LuCI 上编译 FullCone capability detection 与防火墙开关
echo "==> 开始编译 FullCone LuCI APK..."
OPENWRT_VERSION="${OPENWRT_VERSION}" \
WORK_DIR="${WORK_DIR}" \
OUTPUT_DIR="${LUCI_FULLCONE_OUTPUT_DIR}" \
ARCH="${ARCH}" \
"${SCRIPT_DIR}/build-luci-fullcone.sh"

# 6. 将所有同版 SDK 产物导入 ImageBuilder 本地 APK 仓库
echo "==> 导入自编译本地 APK 仓库..."
(cd "${HELLOWORLD_OUTPUT_DIR}" && sha256sum --check --strict SHA256SUMS)
(cd "${FULLCONE_OUTPUT_DIR}" && sha256sum --check --strict SHA256SUMS)
(cd "${LUCI_FULLCONE_OUTPUT_DIR}" && sha256sum --check --strict SHA256SUMS)
cmp -s "${HELLOWORLD_OUTPUT_DIR}/helloworld-public-key.pem" \
    "${FULLCONE_OUTPUT_DIR}/fullcone-public-key.pem" || {
        echo "❌ 错误: 两个 SDK 编译阶段的 APK 签名密钥不一致。" >&2
        exit 1
    }
cmp -s "${FULLCONE_OUTPUT_DIR}/fullcone-public-key.pem" \
    "${LUCI_FULLCONE_OUTPUT_DIR}/luci-fullcone-public-key.pem" || {
        echo "❌ 错误: FullCone runtime 与 LuCI APK 签名密钥不一致。" >&2
        exit 1
    }
mkdir -p "${IB_DIR}/packages" "${IB_DIR}/keys"

# 兼容并清理此前静态预编译包方案留下的记录。
for local_manifest in \
    "${IB_DIR}/packages/.custom-local-packages" \
    "${IB_DIR}/packages/.helloworld-local-packages" \
    "${IB_DIR}/packages/.fullcone-local-packages" \
    "${IB_DIR}/packages/.luci-fullcone-local-packages"; do
    if [ -f "${local_manifest}" ]; then
        while IFS= read -r package_name; do
            case "${package_name}" in
                *.apk) rm -f "${IB_DIR}/packages/${package_name}" ;;
            esac
        done < "${local_manifest}"
    fi
done

LOCAL_PACKAGE_MANIFEST="${IB_DIR}/packages/.custom-local-packages"
: > "${LOCAL_PACKAGE_MANIFEST}"
shopt -s nullglob
HELLOWORLD_APKS=("${HELLOWORLD_OUTPUT_DIR}"/*.apk)
FULLCONE_APKS=("${FULLCONE_OUTPUT_DIR}"/*.apk)
LUCI_FULLCONE_APKS=("${LUCI_FULLCONE_OUTPUT_DIR}"/*.apk)
shopt -u nullglob
[ ${#HELLOWORLD_APKS[@]} -gt 0 ] || {
    echo "❌ 错误: helloworld 构建目录中没有 APK。" >&2
    exit 1
}
[ ${#FULLCONE_APKS[@]} -gt 0 ] || {
    echo "❌ 错误: FullCone 构建目录中没有 APK。" >&2
    exit 1
}
[ ${#LUCI_FULLCONE_APKS[@]} -gt 0 ] || {
    echo "❌ 错误: FullCone LuCI 构建目录中没有 APK。" >&2
    exit 1
}
for package_file in \
    "${HELLOWORLD_APKS[@]}" \
    "${FULLCONE_APKS[@]}" \
    "${LUCI_FULLCONE_APKS[@]}"; do
    package_name="$(basename "${package_file}")"
    if [ -e "${IB_DIR}/packages/${package_name}" ]; then
        echo "❌ 错误: 本地 APK 文件名冲突: ${package_name}" >&2
        exit 1
    fi
    cp -f "${package_file}" "${IB_DIR}/packages/${package_name}"
    printf '%s\n' "${package_name}" >> "${LOCAL_PACKAGE_MANIFEST}"
done
cp -f "${HELLOWORLD_OUTPUT_DIR}/helloworld-public-key.pem" \
    "${IB_DIR}/keys/custom-sdk-public-key.pem"

# 给本地仓库加标签，确保 SSR Plus 和 FullCone 目标包来自本次同版 SDK。
LOCAL_REPOSITORY="@custom file://${IB_DIR}/packages/packages.adb"
sed -i '\|^@helloworld file://|d; \|^@custom file://|d' "${IB_DIR}/repositories"
printf '%s\n' "${LOCAL_REPOSITORY}" >> "${IB_DIR}/repositories"

# APK 或签名密钥变化后强制 ImageBuilder 重建并签名本地仓库索引。
rm -f "${IB_DIR}/packages/packages.adb"
echo "  已导入 $(( ${#HELLOWORLD_APKS[@]} + ${#FULLCONE_APKS[@]} + ${#LUCI_FULLCONE_APKS[@]} )) 个 APK。"

# 7. 配置自定义第三方软件源 (自动替换 ${VERSION_SERIES} 动态系列)
echo "==> 正在配置自定义软件源 (分支代号: ${VERSION_SERIES})..."
if [ -f "${CONFIG_DIR}/custom-feeds.conf" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        # 忽略空行和注释
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # 动态替换版本系列变量 ${VERSION_SERIES}
        resolved_line="${line//\$\{VERSION_SERIES\}/${VERSION_SERIES}}"
        if ! grep -qF "$resolved_line" "${IB_DIR}/repositories"; then
            echo "$resolved_line" >> "${IB_DIR}/repositories"
            echo "  + 追加软件源: $resolved_line"
        fi
    done < "${CONFIG_DIR}/custom-feeds.conf"
fi

# 7. 解析软件包清单，并将目标包锁定到本次源码构建的仓库
echo "==> 正在解析 extra-packages 软件包清单..."
PACKAGE_LIST=()
EXTRA_PKG_FILE="${CONFIG_DIR}/extra-packages.txt"
if [ ! -f "${EXTRA_PKG_FILE}" ]; then
    EXTRA_PKG_FILE="${WORKSPACE_ROOT}/extra-packages.txt"
fi

if [ -f "${EXTRA_PKG_FILE}" ]; then
    while IFS= read -r package_name; do
        [ -n "${package_name}" ] && PACKAGE_LIST+=("${package_name}")
    done < <(sed -E 's/([[:space:]]+#.*)$//' "${EXTRA_PKG_FILE}" |
        sed -E '/^[[:space:]]*(#|$)/d; s/^[[:space:]]+//; s/[[:space:]]+$//')
fi

while IFS= read -r constraint; do
    [ -n "${constraint}" ] || continue
    constraint_name="${constraint%%@*}"
    filtered_packages=()
    for package_name in "${PACKAGE_LIST[@]}"; do
        [ "${package_name#-}" = "${constraint_name}" ] || \
            filtered_packages+=("${package_name}")
    done
    PACKAGE_LIST=("${filtered_packages[@]}" "${constraint}")
done < <(cat \
    "${HELLOWORLD_OUTPUT_DIR}/install-constraints.txt" \
    "${FULLCONE_OUTPUT_DIR}/install-constraints.txt" \
    "${LUCI_FULLCONE_OUTPUT_DIR}/install-constraints.txt")

PACKAGES="${PACKAGE_LIST[*]}"
echo "  包含增量包: ${PACKAGES}"

# 8. 调整 ImageBuilder .config 以匹配目标文件系统与镜像类型
if [ "${TARGET_FILESYSTEMS}" = "squashfs" ]; then
    echo "==> 设置仅编译 squashfs 文件系统 (禁用 ext4 与 targz)..."
    sed -i -E 's/CONFIG_TARGET_ROOTFS_EXT4FS=y/# CONFIG_TARGET_ROOTFS_EXT4FS is not set/' "${IB_DIR}/.config"
    sed -i -E 's/CONFIG_TARGET_ROOTFS_TARGZ=y/# CONFIG_TARGET_ROOTFS_TARGZ is not set/' "${IB_DIR}/.config"
    sed -i -E 's/# CONFIG_TARGET_ROOTFS_SQUASHFS is not set/CONFIG_TARGET_ROOTFS_SQUASHFS=y/' "${IB_DIR}/.config"
fi

if [ "${IMAGES}" = "combined-efi.img.gz" ]; then
    echo "==> 仅生成 UEFI 引导镜像 (禁用传统 BIOS combined 镜像)..."
    sed -i -E 's/CONFIG_GRUB_IMAGES=y/# CONFIG_GRUB_IMAGES is not set/' "${IB_DIR}/.config"
fi

# 调整 GRUB 启动等待时间 (默认 0s 开机即刻引导，不等待)
echo "==> 设置 GRUB 启动等待时间为 ${GRUB_TIMEOUT}s..."
sed -i -E "s/CONFIG_GRUB_TIMEOUT=\"[0-9]+\"/CONFIG_GRUB_TIMEOUT=\"${GRUB_TIMEOUT}\"/" "${IB_DIR}/.config"

# 清理历史产物目录，避免旧固件混入
echo "==> 清理历史构建产物..."
rm -rf "${IB_DIR}/bin/targets/x86/64"/*
rm -rf "${BIN_DIR:?}"/*

# 9. 执行固件构建
echo "==> 开始执行 make image 构建固件..."
BUILD_ARGS=(
    -C "${IB_DIR}"
    image
    PROFILE="${PROFILE}"
    PACKAGES="${PACKAGES}"
    ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE}"
    CONFIG_GRUB_TIMEOUT="${GRUB_TIMEOUT}"
    TARGET_FILESYSTEMS="${TARGET_FILESYSTEMS}"
    IMAGES="${IMAGES}"
    CONFIG_TARGET_IMAGES_GZIP=y
    CONFIG_TARGET_ROOTFS_TARGZ=
)

if [ -d "${FILES_DIR}" ]; then
    BUILD_ARGS+=(FILES="${FILES_DIR}")
fi

make "${BUILD_ARGS[@]}"

# 10. 收集并规整构建产物
echo "==> 正在收集构建产物至 ${BIN_DIR}..."
OUTPUT_SOURCE_DIR="${IB_DIR}/bin/targets/x86/64"

if [ -d "${OUTPUT_SOURCE_DIR}" ]; then
    # 清理 ImageBuilder 内部生成的冗余裸分区及元数据文件 (rootfs.img, kernel.bin, bom 等)
    find "${OUTPUT_SOURCE_DIR}" -type f ! -name "*combined-efi*" ! -name "*manifest*" -delete 2>/dev/null || true

    # 收集至交付目录 bin/ 并追加年月日-时间戳字段 (例如: ...-combined-efi-20260914-1652.img.gz)
    for f in "${OUTPUT_SOURCE_DIR}"/*"${IMAGES}"*; do
        if [ -f "$f" ]; then
            base_name="$(basename "$f")"
            if [[ ! "$base_name" =~ -[0-9]{8}-[0-9]{4}\.img\.gz$ ]]; then
                target_name="$(echo "$base_name" | sed -E "s/\.img\.gz$/-${BUILD_DATE}.img.gz/")"
            else
                target_name="$base_name"
            fi
            cp -f "$f" "${BIN_DIR}/${target_name}"
            mv -f "$f" "${OUTPUT_SOURCE_DIR}/${target_name}"
        fi
    done
    find "${OUTPUT_SOURCE_DIR}" -type f -name "*manifest*" -exec cp -f {} "${BIN_DIR}/" \;
    
    cd "${BIN_DIR}"
    echo "==> 正在生成 SHA256 校验和文件..."
    sha256sum ./*combined-efi*.img.gz > sha256sums 2>/dev/null || true
    # 同步更新 ImageBuilder 内部目录的 sha256sums 保持一致
    cp -f sha256sums "${OUTPUT_SOURCE_DIR}/sha256sums" 2>/dev/null || true

    # 固件成功生成后硬校验 SSR Plus 官方列表与 naiveproxy 排除策略。
    MANIFEST_FILE=$(find "${BIN_DIR}" -type f -name "*manifest*" | head -n 1)
    [ -n "${MANIFEST_FILE}" ] || {
        echo "❌ 错误: 未生成固件 Manifest，无法验证 SSR Plus 集成结果。" >&2
        exit 1
    }
    while IFS= read -r required_package; do
        if ! awk '{print $1}' "${MANIFEST_FILE}" | grep -Fxq "${required_package}"; then
            echo "❌ 错误: 固件 Manifest 缺少 ${required_package}。" >&2
            exit 1
        fi
    done < "${HELLOWORLD_OUTPUT_DIR}/install-packages.txt"
    if awk '{print $1}' "${MANIFEST_FILE}" | grep -Fxq naiveproxy; then
        echo "❌ 错误: 固件中意外包含 naiveproxy。" >&2
        exit 1
    fi
    while IFS= read -r required_package; do
        if ! awk '{print $1}' "${MANIFEST_FILE}" | grep -Fxq "${required_package}"; then
            echo "❌ 错误: 固件 Manifest 缺少 FullCone LuCI 组件 ${required_package}。" >&2
            exit 1
        fi
    done < "${LUCI_FULLCONE_OUTPUT_DIR}/install-packages.txt"

    # FullCone 四层调用链和精确 kernel ABI 都必须出现在最终固件中。
    while IFS= read -r required_package; do
        if ! awk '{print $1}' "${MANIFEST_FILE}" | grep -Fxq "${required_package}"; then
            echo "❌ 错误: 固件 Manifest 缺少 FullCone 组件 ${required_package}。" >&2
            exit 1
        fi
    done < "${FULLCONE_OUTPUT_DIR}/install-packages.txt"
    fullcone_kernel_dependency="$(cat "${FULLCONE_OUTPUT_DIR}/kernel-dependency.txt")"
    firmware_kernel_version="$(awk '$1 == "kernel" { print $3; exit }' "${MANIFEST_FILE}")"
    [ "kernel=${firmware_kernel_version}" = "${fullcone_kernel_dependency}" ] || {
        echo "❌ 错误: kmod-nft-fullcone ABI 与固件 kernel 不一致。" >&2
        echo "  模块要求: ${fullcone_kernel_dependency}" >&2
        echo "  固件内核: kernel=${firmware_kernel_version:-未知}" >&2
        exit 1
    }

    ROOTFS_DIR="$(find "${IB_DIR}/build_dir" -maxdepth 3 -type d -name 'root-x86' -print -quit)"
    [ -n "${ROOTFS_DIR}" ] || {
        echo "❌ 错误: 无法定位 ImageBuilder 最终根文件系统。" >&2
        exit 1
    }
    for geodata_file in \
        usr/share/v2ray/geoip.dat \
        usr/share/v2ray/geosite.dat \
        usr/share/xray/geoip.dat \
        usr/share/xray/geosite.dat; do
        [ -s "${ROOTFS_DIR}/${geodata_file}" ] || {
            echo "❌ 错误: 最终根文件系统缺少 GeoData 文件 ${geodata_file}。" >&2
            exit 1
        }
    done
    luci_feature_rpc="${ROOTFS_DIR}/usr/share/rpcd/ucode/luci"
    grep -Fq "fullcone:   access('/sys/module/xt_FULLCONENAT/refcnt') == true || access('/sys/module/nft_fullcone/refcnt') == true," \
        "${luci_feature_rpc}" || {
            echo "❌ 错误: 最终 luci-base 缺少 FullCone capability detection。" >&2
            exit 1
        }
    grep -Fq 'ubus call luci getFeatures' "${ROOTFS_DIR}/usr/sbin/fullcone-check" || {
        echo "❌ 错误: 最终 fullcone-check 缺少 LuCI capability 运行时验收。" >&2
        exit 1
    }
    luci_firewall_zones="${ROOTFS_DIR}/www/luci-static/resources/view/firewall/zones.js"
    grep -Eq "if[[:space:]]*\\([[:space:]]*L\\.hasSystemFeature\\('fullcone'\\)[[:space:]]*\\)" \
        "${luci_firewall_zones}" || {
        echo "❌ 错误: 最终 luci-app-firewall 未按 capability 控制 FullCone UI。" >&2
        exit 1
    }
    grep -Eq "s\\.option\\(form\\.Flag,[[:space:]]*'fullcone',[[:space:]]*_\\('Enable FullCone NAT'\\)\\)" \
        "${luci_firewall_zones}" || {
            echo "❌ 错误: 最终 luci-app-firewall 缺少 IPv4 FullCone 开关。" >&2
            exit 1
        }
    grep -Eq "s\\.option\\(form\\.Flag,[[:space:]]*'fullcone6',[[:space:]]*_\\('Enable FullCone NAT6'\\)\\)" \
        "${luci_firewall_zones}" || {
            echo "❌ 错误: 最终 luci-app-firewall 缺少 IPv6 FullCone 开关。" >&2
            exit 1
        }
    find "${ROOTFS_DIR}/lib/modules" -type f -name 'nft_fullcone.ko' -print -quit |
        grep -q . || {
            echo "❌ 错误: 最终根文件系统缺少 nft_fullcone.ko。" >&2
            exit 1
        }
    rootfs_nft="${ROOTFS_DIR}/usr/sbin/nft"
    [ -f "${rootfs_nft}" ] || {
        echo "❌ 错误: 最终根文件系统缺少 usr/sbin/nft。" >&2
        exit 1
    }
    rootfs_nft_file_type="$(file -b "${rootfs_nft}")"
    case "${rootfs_nft_file_type}" in
        *ELF*) ;;
        *)
            echo "❌ 错误: 最终 usr/sbin/nft 不是 ELF: ${rootfs_nft_file_type}" >&2
            exit 1
            ;;
    esac

    rootfs_nft_dynamic_info="${WORK_DIR}/rootfs-nft.readelf-dynamic.txt"
    readelf -d "${rootfs_nft}" > "${rootfs_nft_dynamic_info}"
    rootfs_libnftables_soname=""
    while IFS= read -r dynamic_line; do
        if [[ "${dynamic_line}" =~ Shared[[:space:]]library:[[:space:]]\[(libnftables\.so\.[^]]+)\] ]]; then
            [ -z "${rootfs_libnftables_soname}" ] || {
                echo "❌ 错误: 最终 usr/sbin/nft 包含多个 libnftables.so NEEDED 项。" >&2
                exit 1
            }
            rootfs_libnftables_soname="${BASH_REMATCH[1]}"
        fi
    done < "${rootfs_nft_dynamic_info}"
    [ -n "${rootfs_libnftables_soname}" ] || {
        echo "❌ 错误: 最终 usr/sbin/nft 的 NEEDED 不包含 libnftables.so.*。" >&2
        exit 1
    }

    rootfs_libnftables_link="${ROOTFS_DIR}/usr/lib/${rootfs_libnftables_soname}"
    [ -e "${rootfs_libnftables_link}" ] || {
        echo "❌ 错误: 最终根文件系统缺少 nft NEEDED 对应的 ${rootfs_libnftables_soname}。" >&2
        exit 1
    }
    if ! rootfs_libnftables="$(readlink -e "${rootfs_libnftables_link}")" || \
       [ -z "${rootfs_libnftables}" ]; then
        echo "❌ 错误: 最终 ${rootfs_libnftables_soname} 无法解析到实际共享库。" >&2
        exit 1
    fi
    case "${rootfs_libnftables}" in
        "${ROOTFS_DIR}/usr/lib/"*) ;;
        *)
            echo "❌ 错误: 最终 ${rootfs_libnftables_soname} 解析到 rootfs 之外。" >&2
            exit 1
            ;;
    esac
    [ -f "${rootfs_libnftables}" ] || {
        echo "❌ 错误: 最终 ${rootfs_libnftables_soname} 没有对应的实际共享库文件。" >&2
        exit 1
    }

    rootfs_nft_strings="${WORK_DIR}/rootfs-nft.strings.txt"
    strings "${rootfs_nft}" > "${rootfs_nft_strings}"
    if grep -Fi 'fullcone' "${rootfs_nft_strings}" >/dev/null; then
        echo "==> 最终 usr/sbin/nft FullCone 字符串诊断:"
        grep -Fi -C2 'fullcone' "${rootfs_nft_strings}" >&2
    else
        echo "==> 最终 usr/sbin/nft FullCone 字符串诊断: 无（parser 位于 libnftables.so）"
    fi

    rootfs_libnftables_strings="${WORK_DIR}/rootfs-libnftables.strings.txt"
    strings "${rootfs_libnftables}" > "${rootfs_libnftables_strings}"
    grep -Fx 'fullcone' "${rootfs_libnftables_strings}" >/dev/null || {
        echo "❌ 错误: 最终 libnftables.so 不包含 exact fullcone parser 证据。" >&2
        exit 1
    }
    rootfs_libnftnl="$(find "${ROOTFS_DIR}/usr/lib" -type f -name 'libnftnl.so.*' -print -quit)"
    [ -n "${rootfs_libnftnl}" ] || {
        echo "❌ 错误: 最终根文件系统缺少 libnftnl 共享库。" >&2
        exit 1
    }
    rootfs_libnftnl_strings="${WORK_DIR}/rootfs-libnftnl.strings.txt"
    strings "${rootfs_libnftnl}" > "${rootfs_libnftnl_strings}"
    grep -Fx 'fullcone' "${rootfs_libnftnl_strings}" >/dev/null || {
        echo "❌ 错误: 最终 libnftnl 不支持 fullcone expression。" >&2
        exit 1
    }
    grep -Fq 'nft_try_fullcone' "${ROOTFS_DIR}/usr/share/ucode/fw4.uc" || {
        echo "❌ 错误: 最终 firewall4 不包含 FullCone 运行时探测。" >&2
        exit 1
    }
    [ -f "${ROOTFS_DIR}/usr/share/firewall4/templates/zone-fullcone.uc" ] || {
        echo "❌ 错误: 最终 firewall4 缺少 FullCone 规则模板。" >&2
        exit 1
    }
    [ -x "${ROOTFS_DIR}/usr/sbin/fullcone-check" ] || {
        echo "❌ 错误: 最终根文件系统缺少 FullCone 运行时验收工具。" >&2
        exit 1
    }
    grep -Fq 'fullcone=1' "${ROOTFS_DIR}/etc/uci-defaults/99-custom-defaults" || {
        echo "❌ 错误: 最终首次启动配置没有启用 IPv4 FullCone。" >&2
        exit 1
    }
    cp -f "${HELLOWORLD_OUTPUT_DIR}/BUILD-INFO.txt" \
        "${BIN_DIR}/helloworld-build-info.txt"
    cp -f "${FULLCONE_OUTPUT_DIR}/BUILD-INFO.txt" \
        "${BIN_DIR}/fullcone-build-info.txt"
    cp -f "${LUCI_FULLCONE_OUTPUT_DIR}/BUILD-INFO.txt" \
        "${BIN_DIR}/luci-fullcone-build-info.txt"

    # 11. 软件包清单差异比对 (Manifest Diff)
    if [ -n "${MANIFEST_FILE}" ] && [ -f "${SCRIPT_DIR}/diff_manifest.py" ]; then
        python3 "${SCRIPT_DIR}/diff_manifest.py" \
            "${WORK_DIR}/last-manifest.txt" \
            "${MANIFEST_FILE}" \
            --output-diff "${BIN_DIR}/manifest.diff" \
            --output-md "${BIN_DIR}/manifest.md" \
            --summary || true
        # 更新比对基准缓存
        cp -f "${MANIFEST_FILE}" "${WORK_DIR}/last-manifest.txt" 2>/dev/null || true
    fi

    echo ""
    echo "=================================================="
    echo "  🎉 固件构建成功完成！"
    echo "=================================================="
    echo "产物目录: ${BIN_DIR}"
    ls -lh "${BIN_DIR}"
else
    echo "❌ 错误: 未在 ${OUTPUT_SOURCE_DIR} 中找到构建产物！" >&2
    exit 1
fi
