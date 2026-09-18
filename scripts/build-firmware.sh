#!/usr/bin/env bash
set -euo pipefail

# 清理 WSL2 环境下从 Windows 继承的含空格或特殊字符 PATH (防止构建及 shell 解析报错)
CLEAN_PATH=""
IFS=':' read -ra ADDR <<< "$PATH"
for p in "${ADDR[@]}"; do
    case "$p" in
        /mnt/*|*" "*|*"("*|*")"*) continue ;;
        *) CLEAN_PATH="${CLEAN_PATH:+${CLEAN_PATH}:}$p" ;;
    esac
done
export PATH="$CLEAN_PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

die() {
    echo "❌ $*" >&2
    exit 1
}

# ==============================================================================
# OpenWrt 固件纯装配流水线 (Assembly-Only Firmware Build)
# 职责唯一：从已有预编译组件目录与官方 ImageBuilder 装配最终固件
# 严禁任何组件编译、SDK 编译或 Go 源码编译！
# ==============================================================================

# 输入参数与组件目录
OPENWRT_VERSION="${OPENWRT_VERSION:-latest}"
if [ "$OPENWRT_VERSION" = "latest" ] || [ -z "$OPENWRT_VERSION" ]; then
    OPENWRT_VERSION="$("${SCRIPT_DIR}/resolve-version.sh" "latest")"
fi
if ! [[ "${OPENWRT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]]; then
    die "无效的 OpenWrt 版本号: ${OPENWRT_VERSION}"
fi

HELLOWORLD_COMPONENT_DIR="${HELLOWORLD_COMPONENT_DIR:?必须指定 HELLOWORLD_COMPONENT_DIR}"
FULLCONE_RUNTIME_DIR="${FULLCONE_RUNTIME_DIR:?必须指定 FULLCONE_RUNTIME_DIR}"
FULLCONE_LUCI_DIR="${FULLCONE_LUCI_DIR:?必须指定 FULLCONE_LUCI_DIR}"

WORK_DIR="${WORK_DIR:-${WORKSPACE_ROOT}/.work}"
BIN_DIR="${BIN_DIR:-${WORKSPACE_ROOT}/bin}"
CONFIG_DIR="${CONFIG_DIR:-${WORKSPACE_ROOT}/config}"
FILES_DIR="${FILES_DIR:-${WORKSPACE_ROOT}/files}"

VERSION_SERIES="$(echo "${OPENWRT_VERSION}" | cut -d. -f1-2)"
ARCH="${ARCH:-x86-64}"
PROFILE="${PROFILE:-generic}"
ROOTFS_PARTSIZE="${ROOTFS_PARTSIZE:-2048}"
GRUB_TIMEOUT="${GRUB_TIMEOUT:-0}"
TARGET_FILESYSTEMS="${TARGET_FILESYSTEMS:-squashfs}"
IMAGES="${IMAGES:-combined-efi.img.gz}"
BUILD_DATE="${BUILD_DATE:-$(date +"%Y%m%d-%H%M")}"

mkdir -p "${WORK_DIR}" "${BIN_DIR}"
WORK_DIR="$(cd "${WORK_DIR}" && pwd)"
BIN_DIR="$(cd "${BIN_DIR}" && pwd)"
HELLOWORLD_COMPONENT_DIR="$(cd "${HELLOWORLD_COMPONENT_DIR}" && pwd)"
FULLCONE_RUNTIME_DIR="$(cd "${FULLCONE_RUNTIME_DIR}" && pwd)"
FULLCONE_LUCI_DIR="$(cd "${FULLCONE_LUCI_DIR}" && pwd)"

echo "=================================================="
echo "  OpenWrt ImageBuilder 纯装配固件流水线 (Assembly-Only)"
echo "  版本:         ${OPENWRT_VERSION} (系列: ${VERSION_SERIES})"
echo "  架构:         ${ARCH} (${PROFILE})"
echo "  helloworld:   ${HELLOWORLD_COMPONENT_DIR}"
echo "  FullCone RT:  ${FULLCONE_RUNTIME_DIR}"
echo "  FullCone LuCI:${FULLCONE_LUCI_DIR}"
echo "  交付目录:     ${BIN_DIR}"
echo "=================================================="

# ==============================================================================
# 1. 预编译组件目录权威前置校验 (Fail-Fast)
# ==============================================================================
echo "==> 正在校验预编译组件完整性..."

# A. 校验 helloworld 预编译组件
[ -d "${HELLOWORLD_COMPONENT_DIR}" ] || die "helloworld 组件目录不存在: ${HELLOWORLD_COMPONENT_DIR}"
for req_file in BUILD-INFO.txt repository-packages.txt install-packages.txt install-constraints.txt helloworld-public-key.pem SHA256SUMS; do
    [ -s "${HELLOWORLD_COMPONENT_DIR}/${req_file}" ] || die "helloworld 缺少元数据文件: ${req_file}"
done
(cd "${HELLOWORLD_COMPONENT_DIR}" && sha256sum --check --strict SHA256SUMS) || die "helloworld 组件 SHA256 校验失败"

hw_version="$(awk -F': ' '$1 == "OpenWrt version" { print $2; exit }' "${HELLOWORLD_COMPONENT_DIR}/BUILD-INFO.txt")"
[ "${hw_version}" = "${OPENWRT_VERSION}" ] || die "helloworld 组件版本 (${hw_version:-未知}) 与目标版本 (${OPENWRT_VERSION}) 不一致"

while IFS='=' read -r pkg_name pkg_ver; do
    [ -n "${pkg_name}" ] || continue
    ls "${HELLOWORLD_COMPONENT_DIR}/${pkg_name}"-*.apk >/dev/null 2>&1 || \
        die "helloworld 缺失 repository-packages.txt 中声明的 APK: ${pkg_name}"
done < "${HELLOWORLD_COMPONENT_DIR}/repository-packages.txt"

# B. 校验 FullCone runtime 预编译组件
[ -d "${FULLCONE_RUNTIME_DIR}" ] || die "FullCone runtime 组件目录不存在: ${FULLCONE_RUNTIME_DIR}"
for req_file in BUILD-INFO.txt repository-packages.txt install-packages.txt install-constraints.txt kernel-dependency.txt fullcone-public-key.pem SHA256SUMS; do
    [ -s "${FULLCONE_RUNTIME_DIR}/${req_file}" ] || die "FullCone runtime 缺少元数据文件: ${req_file}"
done
(cd "${FULLCONE_RUNTIME_DIR}" && sha256sum --check --strict SHA256SUMS) || die "FullCone runtime 组件 SHA256 校验失败"

fc_version="$(awk -F': ' '$1 == "OpenWrt version" { print $2; exit }' "${FULLCONE_RUNTIME_DIR}/BUILD-INFO.txt")"
[ "${fc_version}" = "${OPENWRT_VERSION}" ] || die "FullCone runtime 组件版本 (${fc_version:-未知}) 与目标版本 (${OPENWRT_VERSION}) 不一致"

grep -Eq '^kernel=[0-9]+\.[0-9]+\.[0-9]+~[0-9a-f]+-r[0-9]+$' "${FULLCONE_RUNTIME_DIR}/kernel-dependency.txt" || \
    die "FullCone kernel-dependency.txt 格式无效: $(cat "${FULLCONE_RUNTIME_DIR}/kernel-dependency.txt")"

for fc_core in kmod-nft-fullcone libnftnl11 nftables-json firewall4; do
    ls "${FULLCONE_RUNTIME_DIR}/${fc_core}"-*.apk >/dev/null 2>&1 || die "FullCone runtime 缺少核心 APK: ${fc_core}"
done

# C. 校验 FullCone LuCI 预编译组件
[ -d "${FULLCONE_LUCI_DIR}" ] || die "FullCone LuCI 组件目录不存在: ${FULLCONE_LUCI_DIR}"
for req_file in BUILD-INFO.txt repository-packages.txt install-packages.txt install-constraints.txt luci-fullcone-public-key.pem SHA256SUMS; do
    [ -s "${FULLCONE_LUCI_DIR}/${req_file}" ] || die "FullCone LuCI 缺少元数据文件: ${req_file}"
done
(cd "${FULLCONE_LUCI_DIR}" && sha256sum --check --strict SHA256SUMS) || die "FullCone LuCI 组件 SHA256 校验失败"

luci_version="$(awk -F': ' '$1 == "OpenWrt version" { print $2; exit }' "${FULLCONE_LUCI_DIR}/BUILD-INFO.txt")"
[ "${luci_version}" = "${OPENWRT_VERSION}" ] || die "FullCone LuCI 组件版本 (${luci_version:-未知}) 与目标版本 (${OPENWRT_VERSION}) 不一致"

grep -Fxq 'luci-i18n-firewall-zh-cn@custom' "${FULLCONE_LUCI_DIR}/install-constraints.txt" || \
    die "FullCone LuCI 翻译未锁定到 @custom"

for luci_core in luci-base luci-app-firewall luci-i18n-firewall-zh-cn; do
    ls "${FULLCONE_LUCI_DIR}/${luci_core}"-*.apk >/dev/null 2>&1 || die "FullCone LuCI 缺少核心 APK: ${luci_core}"
done

echo "✓ 三个预编译组件目录前置校验全部通过。"

# ==============================================================================
# 2. 准备官方 ImageBuilder
# ==============================================================================
IB_TARBALL="openwrt-imagebuilder-${OPENWRT_VERSION}-${ARCH}.Linux-x86_64.tar.zst"
IB_DIR_NAME="openwrt-imagebuilder-${OPENWRT_VERSION}-${ARCH}.Linux-x86_64"
IB_DIR="${WORK_DIR}/${IB_DIR_NAME}"
DOWNLOAD_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/x86/64/${IB_TARBALL}"
CHECKSUMS_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/x86/64/sha256sums"

if [ ! -d "${IB_DIR}" ] || [ ! -f "${IB_DIR}/Makefile" ]; then
    IB_ARCHIVE="${WORK_DIR}/${IB_TARBALL}"
    IB_CHECKSUMS="${WORK_DIR}/sha256sums-${OPENWRT_VERSION}-imagebuilder"
    curl -fsSL --retry 3 --connect-timeout 15 "${CHECKSUMS_URL}" -o "${IB_CHECKSUMS}"
    IB_EXPECTED_SHA256="$(awk -v filename="${IB_TARBALL}" '
        $2 == filename || $2 == "*" filename { print $1; exit }
    ' "${IB_CHECKSUMS}")"
    [ -n "${IB_EXPECTED_SHA256}" ] || die "官方 sha256sums 中没有 ${IB_TARBALL}"

    if [ ! -f "${IB_ARCHIVE}" ] || \
       ! printf '%s  %s\n' "${IB_EXPECTED_SHA256}" "${IB_ARCHIVE}" | sha256sum --check --status; then
        echo "==> 正在下载官方 ImageBuilder (${IB_TARBALL})..."
        rm -f "${IB_ARCHIVE}" "${IB_ARCHIVE}.part"
        curl -fL --retry 3 --connect-timeout 15 "${DOWNLOAD_URL}" -o "${IB_ARCHIVE}.part"
        mv -f "${IB_ARCHIVE}.part" "${IB_ARCHIVE}"
    fi
    printf '%s  %s\n' "${IB_EXPECTED_SHA256}" "${IB_ARCHIVE}" | sha256sum --check --status || \
        die "ImageBuilder SHA-256 校验失败"
    echo "==> 正在解压 ImageBuilder..."
    tar --zstd -xf "${IB_ARCHIVE}" -C "${WORK_DIR}"
fi
[ -f "${IB_DIR}/Makefile" ] || die "ImageBuilder 解压后目录结构不完整: ${IB_DIR}"
echo "==> 检测到已就绪的 ImageBuilder 目录: ${IB_DIR}"

# 以当前项目配置为准重建官方仓库列表，避免带入历史第三方源
OFFICIAL_REPOSITORIES="${IB_DIR}/repositories.official.tmp"
awk '/^https:\/\/downloads\.openwrt\.org\/releases\// { print }' \
    "${IB_DIR}/repositories" > "${OFFICIAL_REPOSITORIES}"
[ -s "${OFFICIAL_REPOSITORIES}" ] || die "ImageBuilder 中没有可用的 OpenWrt 官方软件源"
mv -f "${OFFICIAL_REPOSITORIES}" "${IB_DIR}/repositories"

# ==============================================================================
# 3. 导入组件签名公钥
# ==============================================================================
echo "==> 正在导入预编译组件签名公钥..."
mkdir -p "${IB_DIR}/keys"
find "${IB_DIR}/keys" -maxdepth 1 -type f -name '*.pub' -delete
rm -f \
    "${IB_DIR}/keys/helloworld-public-key.pem" \
    "${IB_DIR}/keys/fullcone-public-key.pem" \
    "${IB_DIR}/keys/luci-fullcone-public-key.pem" \
    "${IB_DIR}/keys/custom-sdk-public-key.pem"

# 导入 helloworld 公钥
cp -f "${HELLOWORLD_COMPONENT_DIR}/helloworld-public-key.pem" \
    "${IB_DIR}/keys/helloworld-public-key.pem"
# 导入 FullCone runtime 公钥
cp -f "${FULLCONE_RUNTIME_DIR}/fullcone-public-key.pem" \
    "${IB_DIR}/keys/fullcone-public-key.pem"
# 导入 FullCone LuCI 公钥（若存在且不相同时写入）
if [ -f "${FULLCONE_LUCI_DIR}/luci-fullcone-public-key.pem" ]; then
    cp -f "${FULLCONE_LUCI_DIR}/luci-fullcone-public-key.pem" \
        "${IB_DIR}/keys/luci-fullcone-public-key.pem"
fi
# 兼容旧逻辑
cp -f "${HELLOWORLD_COMPONENT_DIR}/helloworld-public-key.pem" \
    "${IB_DIR}/keys/custom-sdk-public-key.pem"

if [ -d "${CONFIG_DIR}/keys" ]; then
    cp -f "${CONFIG_DIR}/keys"/* "${IB_DIR}/keys/" 2>/dev/null || true
fi

# ==============================================================================
# 4. 导入预编译 APK 到 ImageBuilder 本地仓库
# ==============================================================================
echo "==> 导入预编译 APK 到本地仓库..."
mkdir -p "${IB_DIR}/packages"
rm -f "${IB_DIR}/packages"/*.apk
LOCAL_PACKAGE_MANIFEST="${IB_DIR}/packages/.custom-local-packages"
: > "${LOCAL_PACKAGE_MANIFEST}"

shopt -s nullglob
HELLOWORLD_APKS=("${HELLOWORLD_COMPONENT_DIR}"/*.apk)
FULLCONE_APKS=("${FULLCONE_RUNTIME_DIR}"/*.apk)
LUCI_FULLCONE_APKS=("${FULLCONE_LUCI_DIR}"/*.apk)
shopt -u nullglob

[ ${#HELLOWORLD_APKS[@]} -gt 0 ] || die "helloworld 构建目录中没有 APK"
[ ${#FULLCONE_APKS[@]} -gt 0 ] || die "FullCone runtime 构建目录中没有 APK"
[ ${#LUCI_FULLCONE_APKS[@]} -gt 0 ] || die "FullCone LuCI 构建目录中没有 APK"

for package_file in \
    "${HELLOWORLD_APKS[@]}" \
    "${FULLCONE_APKS[@]}" \
    "${LUCI_FULLCONE_APKS[@]}"; do
    package_name="$(basename "${package_file}")"
    if [ -e "${IB_DIR}/packages/${package_name}" ]; then
        die "本地 APK 文件名冲突: ${package_name}"
    fi
    cp -f "${package_file}" "${IB_DIR}/packages/${package_name}"
    printf '%s\n' "${package_name}" >> "${LOCAL_PACKAGE_MANIFEST}"
done

LOCAL_REPOSITORY="@custom file://${IB_DIR}/packages/packages.adb"
sed -i '\|^@helloworld file://|d; \|^@custom file://|d' "${IB_DIR}/repositories"
printf '%s\n' "${LOCAL_REPOSITORY}" >> "${IB_DIR}/repositories"
rm -f "${IB_DIR}/packages/packages.adb"

echo "  已导入 $(( ${#HELLOWORLD_APKS[@]} + ${#FULLCONE_APKS[@]} + ${#LUCI_FULLCONE_APKS[@]} )) 个本地预编译 APK。"

# ==============================================================================
# 5. 配置自定义第三方软件源与安装包清单
# ==============================================================================
echo "==> 正在配置自定义软件源 (分支代号: ${VERSION_SERIES})..."
if [ -f "${CONFIG_DIR}/custom-feeds.conf" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        resolved_line="${line//\$\{VERSION_SERIES\}/${VERSION_SERIES}}"
        if ! grep -qF "$resolved_line" "${IB_DIR}/repositories"; then
            echo "$resolved_line" >> "${IB_DIR}/repositories"
            echo "  + 追加软件源: $resolved_line"
        fi
    done < "${CONFIG_DIR}/custom-feeds.conf"
fi

echo "==> 正在解析 extra-packages 软件包清单并应用约束..."
PACKAGE_LIST=()
EXTRA_PKG_FILE="${CONFIG_DIR}/extra-packages.txt"
[ -f "${EXTRA_PKG_FILE}" ] || EXTRA_PKG_FILE="${WORKSPACE_ROOT}/extra-packages.txt"

if [ -f "${EXTRA_PKG_FILE}" ]; then
    while IFS= read -r package_name; do
        [ -n "${package_name}" ] && PACKAGE_LIST+=("${package_name}")
    done < <(sed -E 's/([[:space:]]+#.*)$//' "${EXTRA_PKG_FILE}" |
        sed -E '/^[[:space:]]*(#|$)/d; s/^[[:space:]]+//; s/[[:space:]]+$//')
fi

# 应用三个组件的安装约束 (锁定到 @custom)
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
    "${HELLOWORLD_COMPONENT_DIR}/install-constraints.txt" \
    "${FULLCONE_RUNTIME_DIR}/install-constraints.txt" \
    "${FULLCONE_LUCI_DIR}/install-constraints.txt")

PACKAGES="${PACKAGE_LIST[*]}"
echo "  包含增量包: ${PACKAGES}"

# ==============================================================================
# 6. 配置 ImageBuilder 并执行固件生成
# ==============================================================================
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

echo "==> 设置 GRUB 启动等待时间为 ${GRUB_TIMEOUT}s..."
sed -i -E "s/CONFIG_GRUB_TIMEOUT=\"[0-9]+\"/CONFIG_GRUB_TIMEOUT=\"${GRUB_TIMEOUT}\"/" "${IB_DIR}/.config"

echo "==> 清理历史构建产物..."
rm -rf "${IB_DIR}/bin/targets/x86/64"/*
rm -rf "${BIN_DIR:?}"/*

echo "==> 开始执行 make image 组装固件 (Assembly-Only)..."
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

# ==============================================================================
# 7. 规整产物与全面 Hard Validation
# ==============================================================================
echo "==> 正在收集构建产物至 ${BIN_DIR}..."
OUTPUT_SOURCE_DIR="${IB_DIR}/bin/targets/x86/64"
[ -d "${OUTPUT_SOURCE_DIR}" ] || die "未在 ${OUTPUT_SOURCE_DIR} 中找到构建产物！"

find "${OUTPUT_SOURCE_DIR}" -type f ! -name "*combined-efi*" ! -name "*manifest*" -delete 2>/dev/null || true

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
find "${OUTPUT_SOURCE_DIR}" -type f -name "*.manifest" -exec cp -f {} "${BIN_DIR}/" \;

cd "${BIN_DIR}"
echo "==> 正在生成 SHA256 校验和文件..."
sha256sum ./*combined-efi*.img.gz > sha256sums 2>/dev/null || true
cp -f sha256sums "${OUTPUT_SOURCE_DIR}/sha256sums" 2>/dev/null || true

MANIFEST_FILE=$(find "${BIN_DIR}" -type f -name "*.manifest" | head -n 1)
[ -n "${MANIFEST_FILE}" ] || die "未生成固件 Manifest"

echo "==> 执行最终 Manifest 严格比对..."
# 1. helloworld 清单校验
while IFS= read -r required_package; do
    if ! awk '{print $1}' "${MANIFEST_FILE}" | grep -Fxq "${required_package}"; then
        die "固件 Manifest 缺少 helloworld 安装包: ${required_package}"
    fi
done < "${HELLOWORLD_COMPONENT_DIR}/install-packages.txt"

if awk '{print $1}' "${MANIFEST_FILE}" | grep -Fxq naiveproxy; then
    die "固件中意外包含 naiveproxy"
fi

# 2. FullCone LuCI 清单与精确版本比对
while IFS= read -r required_package; do
    if ! awk '{print $1}' "${MANIFEST_FILE}" | grep -Fxq "${required_package}"; then
        die "固件 Manifest 缺少 FullCone LuCI 组件 ${required_package}"
    fi
done < "${FULLCONE_LUCI_DIR}/install-packages.txt"

while IFS='=' read -r pkg_name expected_version; do
    [ -n "${pkg_name}" ] && [ -n "${expected_version}" ] || continue
    manifest_version="$(awk -v pkg="${pkg_name}" '$1 == pkg { print $3; exit }' "${MANIFEST_FILE}")"
    if [ "${manifest_version}" != "${expected_version}" ]; then
        die "固件 Manifest 中的 ${pkg_name} 版本 (${manifest_version:-未知}) 与预编译组件版本 (${expected_version}) 不一致"
    fi
done < "${FULLCONE_LUCI_DIR}/repository-packages.txt"

# 3. FullCone runtime 清单与 Kernel ABI 比对
while IFS= read -r required_package; do
    if ! awk '{print $1}' "${MANIFEST_FILE}" | grep -Fxq "${required_package}"; then
        die "固件 Manifest 缺少 FullCone runtime 组件: ${required_package}"
    fi
done < "${FULLCONE_RUNTIME_DIR}/install-packages.txt"

fullcone_kernel_dependency="$(cat "${FULLCONE_RUNTIME_DIR}/kernel-dependency.txt")"
firmware_kernel_version="$(awk '$1 == "kernel" { print $3; exit }' "${MANIFEST_FILE}")"
[ "kernel=${firmware_kernel_version}" = "${fullcone_kernel_dependency}" ] || {
    die "kmod-nft-fullcone ABI (${fullcone_kernel_dependency}) 与固件 kernel (kernel=${firmware_kernel_version:-未知}) 不一致"
}

# ==============================================================================
# 8. 最终 Rootfs 深度硬校验
# ==============================================================================
echo "==> 执行最终 Rootfs 深度硬校验..."
ROOTFS_DIR="$(find "${IB_DIR}/build_dir" -maxdepth 3 -type d -name 'root-x86' -print -quit)"
[ -n "${ROOTFS_DIR}" ] || die "无法定位 ImageBuilder 最终根文件系统"

for geodata_file in \
    usr/share/v2ray/geoip.dat \
    usr/share/v2ray/geosite.dat \
    usr/share/xray/geoip.dat \
    usr/share/xray/geosite.dat; do
    [ -s "${ROOTFS_DIR}/${geodata_file}" ] || die "最终根文件系统缺少 GeoData 文件 ${geodata_file}"
done

luci_feature_rpc="${ROOTFS_DIR}/usr/share/rpcd/ucode/luci"
grep -Fq "fullcone:   access('/sys/module/xt_FULLCONENAT/refcnt') == true || access('/sys/module/nft_fullcone/refcnt') == true," \
    "${luci_feature_rpc}" || die "最终 luci-base 缺少 FullCone capability detection"

grep -Fq 'ubus call luci getFeatures' "${ROOTFS_DIR}/usr/sbin/fullcone-check" || \
    die "最终 fullcone-check 缺少 LuCI capability 运行时验收"

luci_firewall_zones="${ROOTFS_DIR}/www/luci-static/resources/view/firewall/zones.js"
grep -Eq "if[[:space:]]*\\([[:space:]]*L\\.hasSystemFeature\\('fullcone'\\)[[:space:]]*\\)" \
    "${luci_firewall_zones}" || die "最终 luci-app-firewall 未按 capability 控制 FullCone UI"
grep -Eq "s\\.option\\(form\\.Flag,[[:space:]]*'fullcone',[[:space:]]*_\\('Enable FullCone NAT'\\)\\)" \
    "${luci_firewall_zones}" || die "最终 luci-app-firewall 缺少 IPv4 FullCone 开关"
grep -Eq "s\\.option\\(form\\.Flag,[[:space:]]*'fullcone6',[[:space:]]*_\\('Enable FullCone NAT6'\\)\\)" \
    "${luci_firewall_zones}" || die "最终 luci-app-firewall 缺少 IPv6 FullCone 开关"

[ -s "${ROOTFS_DIR}/usr/lib/lua/luci/i18n/firewall.zh-cn.lmo" ] || \
    die "最终 rootfs 缺少简体中文 firewall 翻译"

find "${ROOTFS_DIR}/lib/modules" -type f -name 'nft_fullcone.ko' -print -quit |
    grep -q . || die "最终根文件系统缺少 nft_fullcone.ko"

rootfs_nft="${ROOTFS_DIR}/usr/sbin/nft"
[ -f "${rootfs_nft}" ] || die "最终根文件系统缺少 usr/sbin/nft"
rootfs_nft_file_type="$(file -b "${rootfs_nft}")"
case "${rootfs_nft_file_type}" in
    *ELF*) ;;
    *) die "最终 usr/sbin/nft 不是 ELF: ${rootfs_nft_file_type}" ;;
esac

rootfs_nft_dynamic_info="${WORK_DIR}/rootfs-nft.readelf-dynamic.txt"
readelf -d "${rootfs_nft}" > "${rootfs_nft_dynamic_info}"
rootfs_libnftables_soname=""
while IFS= read -r dynamic_line; do
    if [[ "${dynamic_line}" =~ Shared[[:space:]]library:[[:space:]]\[(libnftables\.so\.[^]]+)\] ]]; then
        [ -z "${rootfs_libnftables_soname}" ] || die "最终 usr/sbin/nft 包含多个 libnftables.so NEEDED 项"
        rootfs_libnftables_soname="${BASH_REMATCH[1]}"
    fi
done < "${rootfs_nft_dynamic_info}"
[ -n "${rootfs_libnftables_soname}" ] || die "最终 usr/sbin/nft 的 NEEDED 不包含 libnftables.so.*"

rootfs_libnftables_link="${ROOTFS_DIR}/usr/lib/${rootfs_libnftables_soname}"
[ -e "${rootfs_libnftables_link}" ] || die "最终根文件系统缺少 nft NEEDED 对应的 ${rootfs_libnftables_soname}"
if ! rootfs_libnftables="$(readlink -e "${rootfs_libnftables_link}")" || [ -z "${rootfs_libnftables}" ]; then
    die "最终 ${rootfs_libnftables_soname} 无法解析到实际共享库"
fi
case "${rootfs_libnftables}" in
    "${ROOTFS_DIR}/usr/lib/"*) ;;
    *) die "最终 ${rootfs_libnftables_soname} 解析到 rootfs 之外" ;;
esac
[ -f "${rootfs_libnftables}" ] || die "最终 ${rootfs_libnftables_soname} 没有对应的实际共享库文件"

rootfs_libnftables_strings="${WORK_DIR}/rootfs-libnftables.strings.txt"
strings "${rootfs_libnftables}" > "${rootfs_libnftables_strings}"
grep -Fx 'fullcone' "${rootfs_libnftables_strings}" >/dev/null || \
    die "最终 libnftables.so 不包含 exact fullcone parser 证据"

rootfs_libnftnl="$(find "${ROOTFS_DIR}/usr/lib" -type f -name 'libnftnl.so.*' -print -quit)"
[ -n "${rootfs_libnftnl}" ] || die "最终根文件系统缺少 libnftnl 共享库"
rootfs_libnftnl_strings="${WORK_DIR}/rootfs-libnftnl.strings.txt"
strings "${rootfs_libnftnl}" > "${rootfs_libnftnl_strings}"
grep -Fx 'fullcone' "${rootfs_libnftnl_strings}" >/dev/null || \
    die "最终 libnftnl 不支持 fullcone expression"

grep -Fq 'nft_try_fullcone' "${ROOTFS_DIR}/usr/share/ucode/fw4.uc" || \
    die "最终 firewall4 不包含 FullCone 运行时探测"
[ -f "${ROOTFS_DIR}/usr/share/firewall4/templates/zone-fullcone.uc" ] || \
    die "最终 firewall4 缺少 FullCone 规则模板"
[ -x "${ROOTFS_DIR}/usr/sbin/fullcone-check" ] || \
    die "最终根文件系统缺少 FullCone 运行时验收工具"
grep -Fq 'fullcone=1' "${ROOTFS_DIR}/etc/uci-defaults/99-custom-defaults" || \
    die "最终首次启动配置没有启用 IPv4 FullCone"

# 导出构建元数据
cp -f "${HELLOWORLD_COMPONENT_DIR}/BUILD-INFO.txt" "${BIN_DIR}/helloworld-build-info.txt"
cp -f "${FULLCONE_RUNTIME_DIR}/BUILD-INFO.txt" "${BIN_DIR}/fullcone-runtime-build-info.txt"
cp -f "${FULLCONE_LUCI_DIR}/BUILD-INFO.txt" "${BIN_DIR}/fullcone-luci-build-info.txt"

if [ -n "${MANIFEST_FILE}" ] && [ -f "${SCRIPT_DIR}/diff_manifest.py" ]; then
    python3 "${SCRIPT_DIR}/diff_manifest.py" \
        "${WORK_DIR}/last-manifest.txt" \
        "${MANIFEST_FILE}" \
        --output-diff "${BIN_DIR}/manifest.diff" \
        --output-md "${BIN_DIR}/manifest.md" \
        --summary || true
    cp -f "${MANIFEST_FILE}" "${WORK_DIR}/last-manifest.txt" 2>/dev/null || true
fi

echo ""
echo "=================================================="
echo "  🎉 固件纯装配成功完成！(Assembly-Only SUCCESS)"
echo "=================================================="
echo "产物目录: ${BIN_DIR}"
ls -lh "${BIN_DIR}"

