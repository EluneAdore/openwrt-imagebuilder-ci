#!/usr/bin/env bash
set -euo pipefail

# 按 fw876/helloworld 官方 release-packages.yml 的方式，使用与固件版本
# 完全一致的 OpenWrt SDK 编译 APK。编译目标跟随官方列表，但按项目要求
# 排除 naiveproxy。

OPENWRT_VERSION="${OPENWRT_VERSION:?必须指定 OPENWRT_VERSION}"
WORK_DIR="${WORK_DIR:?必须指定 WORK_DIR}"
OUTPUT_DIR="${OUTPUT_DIR:?必须指定 OUTPUT_DIR}"
ARCH="${ARCH:-x86-64}"
SDK_ARCH="${SDK_ARCH:-x86_64}"
TARGET_PATH="${TARGET_PATH:-x86/64}"
HELLOWORLD_REPOSITORY="${HELLOWORLD_REPOSITORY:-https://github.com/fw876/helloworld.git}"
HELLOWORLD_REF="${HELLOWORLD_REF:-dev}"
JOBS="${JOBS:-$(nproc)}"

readonly TARGET_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${TARGET_PATH}"
readonly SOURCE_DIR="${WORK_DIR}/helloworld-source"
readonly DOWNLOAD_DIR="${WORK_DIR}/downloads"

# 与上游 CI 的 packages 数组一致，naiveproxy 按本项目要求排除。
readonly -a BUILD_PACKAGES=(
    luci-app-ssr-plus
    xray-core
    mihomo
)

die() {
    echo "❌ $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少构建命令: $1（请先运行 scripts/setup-env.sh）"
}

for command_name in curl git make sha256sum tar; do
    require_command "${command_name}"
done

mkdir -p "${WORK_DIR}" "${DOWNLOAD_DIR}"

echo "==> 查询 OpenWrt ${OPENWRT_VERSION} x86_64 官方 SDK..."
target_index="$(curl -fsSL --retry 3 --connect-timeout 15 "${TARGET_URL}/")" || \
    die "无法读取 OpenWrt SDK 下载目录: ${TARGET_URL}/"
sdk_candidates="$(printf '%s' "${target_index}" |
    grep -oE "openwrt-sdk-${OPENWRT_VERSION//./\\.}-${ARCH}_[^\"<>[:space:]]+\\.Linux-x86_64\\.tar\\.zst" |
    sort -u || true)"
sdk_tarball="$(printf '%s\n' "${sdk_candidates}" | sed -n '1p')"
[ -n "${sdk_tarball}" ] || die "未找到 OpenWrt ${OPENWRT_VERSION} 的 x86_64 SDK"

sdk_archive="${WORK_DIR}/${sdk_tarball}"
sdk_dir="${WORK_DIR}/${sdk_tarball%.tar.zst}"
checksums_file="${WORK_DIR}/sha256sums-${OPENWRT_VERSION}-x86-64"

curl -fsSL --retry 3 --connect-timeout 15 "${TARGET_URL}/sha256sums" -o "${checksums_file}"
expected_sha256="$(awk -v filename="${sdk_tarball}" '
    $2 == filename || $2 == "*" filename { print $1; exit }
' "${checksums_file}")"
[ -n "${expected_sha256}" ] || die "官方 sha256sums 中没有 ${sdk_tarball}"

archive_is_valid() {
    printf '%s  %s\n' "${expected_sha256}" "${sdk_archive}" | sha256sum --check --status
}

if [ ! -f "${sdk_archive}" ] || ! archive_is_valid; then
    echo "==> 下载官方 SDK: ${sdk_tarball}"
    rm -f "${sdk_archive}" "${sdk_archive}.part"
    curl -fL --retry 3 --connect-timeout 15 "${TARGET_URL}/${sdk_tarball}" \
        -o "${sdk_archive}.part"
    mv -f "${sdk_archive}.part" "${sdk_archive}"
fi
archive_is_valid || die "SDK SHA-256 校验失败: ${sdk_tarball}"

if [ ! -f "${sdk_dir}/Makefile" ]; then
    echo "==> 解压 SDK: ${sdk_tarball}"
    rm -rf "${sdk_dir}"
    tar --zstd -xf "${sdk_archive}" -C "${WORK_DIR}"
fi
[ -f "${sdk_dir}/Makefile" ] || die "SDK 解压后目录结构不完整: ${sdk_dir}"

echo "==> 获取 helloworld ${HELLOWORLD_REF} 最新源码..."
if [ -d "${SOURCE_DIR}/.git" ]; then
    git -C "${SOURCE_DIR}" remote set-url origin "${HELLOWORLD_REPOSITORY}"
    git -C "${SOURCE_DIR}" fetch --depth=1 origin "${HELLOWORLD_REF}"
    git -C "${SOURCE_DIR}" checkout --detach --force FETCH_HEAD
    git -C "${SOURCE_DIR}" clean -fdx
else
    rm -rf "${SOURCE_DIR}"
    git clone --depth=1 --branch "${HELLOWORLD_REF}" \
        "${HELLOWORLD_REPOSITORY}" "${SOURCE_DIR}"
fi
helloworld_commit="$(git -C "${SOURCE_DIR}" rev-parse HEAD)"
echo "  helloworld commit: ${helloworld_commit}"

cd "${sdk_dir}"

echo "==> 初始化 SDK feeds..."
# SDK 自带的 feeds.conf.default 固定在当前 OpenWrt 发布版对应的提交，
# 可避免 dev 分支依赖到其他 OpenWrt 系列的软件包。
./scripts/feeds clean
cp -f feeds.conf.default feeds.conf
printf 'src-link helloworld %s\n' "${SOURCE_DIR}" >> feeds.conf
./scripts/feeds update -a

# 上游 CI 明确移除官方 packages feed 中的 xray-core，确保使用 helloworld 版本。
rm -rf feeds/packages/net/xray-core
./scripts/feeds update -i packages
./scripts/feeds install -a
./scripts/feeds install -a -f -p helloworld
test -e package/feeds/helloworld/xray-core || die "helloworld feed 安装不完整"

echo "==> 写入与上游 APK CI 对齐的 SDK 配置..."
cat > .config <<'EOF'
CONFIG_ALL_NONSHARED=n
CONFIG_ALL_KMODS=n
CONFIG_ALL=n
CONFIG_AUTOREMOVE=n
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_PACKAGE_luci-app-ssr-plus=m
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_NONE_V2RAY=y
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Shadowsocks_NONE_Client=y
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Shadowsocks_NONE_Server=y
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_ChinaDNS_NG=n
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_DNS2TCP=n
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_MosDNS=n
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Http_Proxy=n
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Mihomo=n
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_GeoData=n
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Shadow_TLS=n
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Kcptun=n
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_NaiveProxy=n
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Shadowsocks_Rust_Client=n
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Shadowsocks_Rust_Server=n
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Shadowsocks_Simple_Obfs=n
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Shadowsocks_V2ray_Plugin=n
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_ShadowsocksR_Libev_Client=n
CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_ShadowsocksR_Libev_Server=n
CONFIG_PACKAGE_xray-core=m
CONFIG_PACKAGE_mihomo=m
# CONFIG_PACKAGE_naiveproxy is not set
EOF

make defconfig
for package_name in "${BUILD_PACKAGES[@]}"; do
    grep -Fqx "CONFIG_PACKAGE_${package_name}=m" .config || \
        die "make defconfig 未保留 ${package_name}=m"
done
if grep -Eq '^CONFIG_PACKAGE_naiveproxy=[my]$' .config; then
    die "naiveproxy 被意外选中"
fi

# 与上游 CI 一样先清理、预下载；下载失败由后续逐包编译给出准确错误。
make clean
rm -rf "${sdk_dir}/bin/packages/${SDK_ARCH}/helloworld"
if ! make download -j"${JOBS}" DL_DIR="${DOWNLOAD_DIR}"; then
    echo "⚠️ 部分源码预下载失败，将在逐包编译时重试。" >&2
fi

echo "==> 按官方列表逐包编译 APK（排除 naiveproxy）..."
for package_name in "${BUILD_PACKAGES[@]}"; do
    package_target="package/feeds/helloworld/${package_name}"
    echo "  + 编译 ${package_name}"
    make "${package_target}/clean" DL_DIR="${DOWNLOAD_DIR}"
    if ! make "${package_target}/compile" -j"${JOBS}" DL_DIR="${DOWNLOAD_DIR}"; then
        echo "  ! ${package_name} 并行编译失败，使用 -j1 V=s 重试" >&2
        make "${package_target}/compile" -j1 V=s DL_DIR="${DOWNLOAD_DIR}"
    fi
done

package_dir="${sdk_dir}/bin/packages/${SDK_ARCH}/helloworld"
[ -d "${package_dir}" ] || die "未生成 helloworld APK 目录: ${package_dir}"

apk_tool="${sdk_dir}/staging_dir/host/bin/apk"
[ -x "${apk_tool}" ] || die "SDK 内缺少 apk 工具"

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"
shopt -s nullglob
package_files=("${package_dir}"/*.apk)
shopt -u nullglob
[ ${#package_files[@]} -gt 0 ] || die "helloworld feed 没有生成任何 APK"
cp -f "${package_files[@]}" "${OUTPUT_DIR}/"

# SDK 生成的 APK 使用本地构建密钥签名。ImageBuilder 在装包阶段需要对应公钥。
[ -f "${sdk_dir}/public-key.pem" ] || die "SDK 未生成 APK 签名公钥"
cp -f "${sdk_dir}/public-key.pem" "${OUTPUT_DIR}/helloworld-public-key.pem"

apk_field() {
    local apk_file="$1"
    local field="$2"
    "${apk_tool}" adbdump "${apk_file}" 2>/dev/null |
        sed -n "s/^  ${field}: //p" | head -n 1
}

: > "${OUTPUT_DIR}/repository-packages.txt"
for apk_file in "${OUTPUT_DIR}"/*.apk; do
    package_name="$(apk_field "${apk_file}" name)"
    package_version="$(apk_field "${apk_file}" version)"
    [ -n "${package_name}" ] && [ -n "${package_version}" ] || \
        die "无法读取 APK 元数据: $(basename "${apk_file}")"
    printf '%s=%s\n' "${package_name}" "${package_version}" \
        >> "${OUTPUT_DIR}/repository-packages.txt"
done
sort -u -o "${OUTPUT_DIR}/repository-packages.txt" \
    "${OUTPUT_DIR}/repository-packages.txt"

# 三个官方目标必须生成；中文包由 LUCI_LANG_zh_Hans 同步生成并安装。
: > "${OUTPUT_DIR}/install-packages.txt"
: > "${OUTPUT_DIR}/install-constraints.txt"
install_packages=("${BUILD_PACKAGES[@]}" luci-i18n-ssr-plus-zh-cn)
for package_name in "${install_packages[@]}"; do
    constraint="$(awk -F= -v name="${package_name}" \
        '$1 == name { print; exit }' "${OUTPUT_DIR}/repository-packages.txt")"
    [ -n "${constraint}" ] || die "未生成必需 APK: ${package_name}"
    printf '%s\n' "${package_name}" >> "${OUTPUT_DIR}/install-packages.txt"
    printf '%s@custom\n' "${package_name}" \
        >> "${OUTPUT_DIR}/install-constraints.txt"
done

if grep -Eq '^naiveproxy=' "${OUTPUT_DIR}/repository-packages.txt"; then
    die "输出仓库中意外出现 naiveproxy"
fi

(
    cd "${OUTPUT_DIR}"
    sha256sum ./*.apk > SHA256SUMS
)

cat > "${OUTPUT_DIR}/BUILD-INFO.txt" <<EOF
OpenWrt version: ${OPENWRT_VERSION}
SDK archive: ${sdk_tarball}
SDK SHA-256: ${expected_sha256}
helloworld repository: ${HELLOWORLD_REPOSITORY}
helloworld ref: ${HELLOWORLD_REF}
helloworld commit: ${helloworld_commit}
Compiled targets: ${BUILD_PACKAGES[*]}
Excluded target: naiveproxy
Repository APK count: ${#package_files[@]}
Installed target versions:
EOF
for package_name in "${install_packages[@]}"; do
    awk -F= -v name="${package_name}" \
        '$1 == name { print "  " $0; exit }' \
        "${OUTPUT_DIR}/repository-packages.txt" \
        >> "${OUTPUT_DIR}/BUILD-INFO.txt"
done

echo "✓ helloworld APK 编译完成，共 ${#package_files[@]} 个本地仓库包。"
