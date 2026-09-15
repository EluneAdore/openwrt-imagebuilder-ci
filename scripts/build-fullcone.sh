#!/usr/bin/env bash
set -euo pipefail

# 使用与固件完全相同的 OpenWrt SDK 编译 LEDE nftables FullCone 调用链。
# ImageBuilder 只负责安装这里产生的 APK，不编译或替换内核。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OPENWRT_VERSION="${OPENWRT_VERSION:?必须指定 OPENWRT_VERSION}"
WORK_DIR="${WORK_DIR:?必须指定 WORK_DIR}"
OUTPUT_DIR="${OUTPUT_DIR:?必须指定 OUTPUT_DIR}"
ARCH="${ARCH:-x86-64}"
SDK_ARCH="${SDK_ARCH:-x86_64}"
TARGET_PATH="${TARGET_PATH:-x86/64}"
JOBS="${JOBS:-$(nproc)}"

readonly TARGET_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${TARGET_PATH}"
readonly LEDE_REPO="https://github.com/coolsnowwolf/lede.git"
readonly LEDE_DIR="${WORK_DIR}/lede-source"
readonly DOWNLOAD_DIR="${WORK_DIR}/downloads"

readonly -a REQUIRED_PACKAGES=(
    kmod-nft-fullcone
    libnftnl11
    nftables-json
    firewall4
)

die() {
    echo "❌ $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少构建命令: $1（请先运行 scripts/setup-env.sh）"
}

for command_name in curl git make patch python3 sha256sum strings tar; do
    require_command "${command_name}"
done

mkdir -p "${WORK_DIR}" "${DOWNLOAD_DIR}"

echo "==> 克隆 coolsnowwolf/lede 最新 HEAD..."
rm -rf "${LEDE_DIR}"
git clone --depth=1 "${LEDE_REPO}" "${LEDE_DIR}"

lede_head_commit="$(git -C "${LEDE_DIR}" rev-parse HEAD 2>/dev/null || true)"
[ -n "${lede_head_commit}" ] || die "无法获取 coolsnowwolf/lede HEAD commit"
echo "==> coolsnowwolf/lede HEAD commit: ${lede_head_commit}"

lede_fullcone_pkg="${LEDE_DIR}/package/network/services/fullconenat-nft"
[ -d "${lede_fullcone_pkg}" ] || die "LEDE HEAD 缺少 fullconenat-nft package: package/network/services/fullconenat-nft"
[ -f "${lede_fullcone_pkg}/Makefile" ] || die "LEDE HEAD fullconenat-nft package 缺少 Makefile"

fullcone_upstream_commit="$(sed -n 's/^PKG_SOURCE_VERSION:=[[:space:]]*//p' "${lede_fullcone_pkg}/Makefile" | head -n 1)"
[ -n "${fullcone_upstream_commit}" ] || die "未能从 LEDE fullconenat-nft/Makefile 中解析 PKG_SOURCE_VERSION"
echo "==> nft-fullcone 上游源码 commit: ${fullcone_upstream_commit}"

lede_libnftnl_patch="${LEDE_DIR}/package/libs/libnftnl/patches/001-libnftnl-add-fullcone-expression-support.patch"
lede_nftables_patch="${LEDE_DIR}/package/network/utils/nftables/patches/100-nftables-add-fullcone-expression-support.patch"
lede_fw4_patch="${LEDE_DIR}/package/network/config/firewall4/patches/001-firewall4-add-support-for-fullcone-nat.patch"
lede_nftables_makefile="${LEDE_DIR}/package/network/utils/nftables/Makefile"

for patch_file in "${lede_libnftnl_patch}" "${lede_nftables_patch}" "${lede_fw4_patch}"; do
    [ -f "${patch_file}" ] || die "LEDE HEAD 缺少补丁文件: ${patch_file#${LEDE_DIR}/}"
done

grep -Fq 'kmod-nft-fullcone' "${lede_nftables_makefile}" || \
    die "LEDE HEAD nftables Makefile 未声明 kmod-nft-fullcone 依赖关系"

echo "==> 查询 OpenWrt ${OPENWRT_VERSION} ${TARGET_PATH} 官方 SDK..."
target_index="$(curl -fsSL --retry 3 --connect-timeout 15 "${TARGET_URL}/")" || \
    die "无法读取 OpenWrt SDK 下载目录: ${TARGET_URL}/"
sdk_candidates="$(printf '%s' "${target_index}" |
    grep -oE "openwrt-sdk-${OPENWRT_VERSION//./\\.}-${ARCH}_[^\"<>[:space:]]+\\.Linux-x86_64\\.tar\\.zst" |
    sort -u || true)"
sdk_tarball="$(printf '%s\n' "${sdk_candidates}" | sed -n '1p')"
[ -n "${sdk_tarball}" ] || die "未找到 OpenWrt ${OPENWRT_VERSION} 的 ${TARGET_PATH} SDK"
[ "$(printf '%s\n' "${sdk_candidates}" | sed '/^$/d' | wc -l)" -eq 1 ] || \
    die "SDK 下载目录存在多个候选文件，无法安全选择"

sdk_archive="${WORK_DIR}/${sdk_tarball}"
sdk_dir="${WORK_DIR}/${sdk_tarball%.tar.zst}"
checksums_file="${WORK_DIR}/sha256sums-${OPENWRT_VERSION}-x86-64"

curl -fsSL --retry 3 --connect-timeout 15 "${TARGET_URL}/sha256sums" -o "${checksums_file}"
expected_sha256="$(awk -v filename="${sdk_tarball}" '
    $2 == filename || $2 == "*" filename { print $1; exit }
' "${checksums_file}")"
[ -n "${expected_sha256}" ] || die "官方 sha256sums 中没有 ${sdk_tarball}"

archive_is_valid() {
    printf '%s  %s\n' "${expected_sha256}" "${sdk_archive}" |
        sha256sum --check --status
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

cd "${sdk_dir}"

sdk_version="$(sed -n 's/^VERSION_NUMBER:=.*,[[:space:]]*\([^,)]*\))$/\1/p' include/version.mk | head -n 1)"
[ "${sdk_version}" = "${OPENWRT_VERSION}" ] || \
    die "SDK 版本不匹配: 期望 ${OPENWRT_VERSION}，实际 ${sdk_version:-未知}"

expected_base_commit="$(sed -n \
    's#^src-git --root=package base .*\^\([0-9a-f][0-9a-f]*\)$#\1#p' \
    feeds.conf.default)"
actual_base_commit="$(git -C feeds/base_root rev-parse HEAD 2>/dev/null || true)"
if [ -n "${expected_base_commit}" ] && \
   [ "${actual_base_commit}" = "${expected_base_commit}" ] && \
   [ -e package/feeds/base/libnftnl ] && \
   [ -e package/feeds/base/nftables ] && \
   [ -e package/feeds/base/firewall4 ]; then
    echo "==> 复用已锁定到 ${actual_base_commit} 的 OpenWrt base feed。"
else
    echo "==> 恢复 ${OPENWRT_VERSION} SDK 固定的官方 feeds..."
    ./scripts/feeds clean
    cp -f feeds.conf.default feeds.conf
    ./scripts/feeds update -a
    ./scripts/feeds install -a
fi

base_source="${sdk_dir}/feeds/base"
[ -d "${base_source}/libs/libnftnl" ] || die "SDK 缺少官方 libnftnl 源码"
[ -d "${base_source}/network/utils/nftables" ] || die "SDK 缺少官方 nftables 源码"
[ -d "${base_source}/network/config/firewall4" ] || die "SDK 缺少官方 firewall4 源码"

echo "==> 注入从 LEDE HEAD 提取的 FullCone 补丁..."
install -d \
    "${base_source}/libs/libnftnl/patches" \
    "${base_source}/network/utils/nftables/patches" \
    "${base_source}/network/config/firewall4/patches"
cp -f "${lede_libnftnl_patch}" \
    "${base_source}/libs/libnftnl/patches/"
cp -f "${lede_nftables_patch}" \
    "${base_source}/network/utils/nftables/patches/"
cp -f "${lede_fw4_patch}" \
    "${base_source}/network/config/firewall4/patches/"

# LEDE 让 nftables 显式依赖内核 expression。严格匹配官方行，未来上游改动时
# 立即失败并要求重新审核，避免补丁悄悄失效。
nftables_makefile="${base_source}/network/utils/nftables/Makefile"
if ! grep -Fq '+kmod-nft-fullcone' "${nftables_makefile}"; then
    python3 - "${nftables_makefile}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = "  DEPENDS:=+kmod-nft-core +libnftnl\n"
new = "  DEPENDS:=+kmod-nft-core +libnftnl +kmod-nft-fullcone\n"
if text.count(old) != 1:
    raise SystemExit("nftables Makefile 依赖行与预期不符")
path.write_text(text.replace(old, new))
PY
fi

fullcone_package_dir="${sdk_dir}/package/fullcone/fullconenat-nft"
rm -rf "${fullcone_package_dir}"
install -d "$(dirname "${fullcone_package_dir}")"
cp -a "${lede_fullcone_pkg}" "${fullcone_package_dir}"

echo "==> 配置 FullCone SDK 编译目标..."
cat > .config <<'EOF'
CONFIG_ALL_NONSHARED=n
CONFIG_ALL_KMODS=n
CONFIG_ALL=n
CONFIG_AUTOREMOVE=n
CONFIG_PACKAGE_kmod-nft-fullcone=m
CONFIG_PACKAGE_libnftnl=m
CONFIG_PACKAGE_nftables-json=m
CONFIG_PACKAGE_firewall4=m
EOF
make defconfig

for symbol in \
    CONFIG_PACKAGE_kmod-nft-fullcone=m \
    CONFIG_PACKAGE_libnftnl=m \
    CONFIG_PACKAGE_nftables-json=m \
    CONFIG_PACKAGE_firewall4=m; do
    grep -Fqx "${symbol}" .config || die "make defconfig 未保留 ${symbol}"
done

compile_package() {
    local package_target="$1"
    echo "  + 编译 ${package_target}"
    make "${package_target}/clean" DL_DIR="${DOWNLOAD_DIR}"
    if ! make "${package_target}/compile" -j"${JOBS}" DL_DIR="${DOWNLOAD_DIR}"; then
        echo "  ! ${package_target} 并行编译失败，使用 -j1 V=s 重试" >&2
        make "${package_target}/compile" -j1 V=s DL_DIR="${DOWNLOAD_DIR}"
    fi
}

echo "==> 编译 patched libnftnl、nftables、nft_fullcone 与 firewall4..."
compile_package package/feeds/base/libnftnl
compile_package package/fullcone/fullconenat-nft
compile_package package/feeds/base/nftables
compile_package package/feeds/base/firewall4

apk_tool="${sdk_dir}/staging_dir/host/bin/apk"
[ -x "${apk_tool}" ] || die "SDK 内缺少 apk 工具"

apk_field() {
    local apk_file="$1"
    local field="$2"
    "${apk_tool}" adbdump "${apk_file}" 2>/dev/null |
        sed -n "s/^  ${field}: //p" | head -n 1
}

rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"
: > "${OUTPUT_DIR}/repository-packages.txt"

for required_name in "${REQUIRED_PACKAGES[@]}"; do
    matches=()
    while IFS= read -r apk_file; do
        [ "$(apk_field "${apk_file}" name)" = "${required_name}" ] && matches+=("${apk_file}")
    done < <(find "${sdk_dir}/bin" -type f -name '*.apk' -print)
    [ ${#matches[@]} -eq 1 ] || \
        die "${required_name} APK 数量异常: ${#matches[@]}"
    cp -f "${matches[0]}" "${OUTPUT_DIR}/"
    package_version="$(apk_field "${matches[0]}" version)"
    [ -n "${package_version}" ] || die "无法读取 ${required_name} APK 版本"
    printf '%s=%s\n' "${required_name}" "${package_version}" \
        >> "${OUTPUT_DIR}/repository-packages.txt"
done

[ -f "${sdk_dir}/public-key.pem" ] || die "SDK 未生成 APK 签名公钥"
cp -f "${sdk_dir}/public-key.pem" "${OUTPUT_DIR}/fullcone-public-key.pem"

module_apk="$(find "${OUTPUT_DIR}" -maxdepth 1 -type f -name 'kmod-nft-fullcone-*.apk' -print -quit)"
[ -n "${module_apk}" ] || die "输出目录缺少 kmod-nft-fullcone APK"
kernel_dependency="$("${apk_tool}" adbdump "${module_apk}" 2>/dev/null |
    sed -n 's/^    - \(kernel=.*\)$/\1/p' | head -n 1)"
[ -n "${kernel_dependency}" ] || die "kmod-nft-fullcone 没有精确 kernel ABI 依赖"
printf '%s\n' "${kernel_dependency}" > "${OUTPUT_DIR}/kernel-dependency.txt"

extract_dir="$(mktemp -d "${WORK_DIR}/fullcone-apk.XXXXXX")"
# --allow-untrusted 仅用于离线解包检查文件内容；固件安装阶段仍必须使用上面
# 导出的 SDK 公钥验签并满足完整依赖，绝不绕过 ImageBuilder 的信任校验。
"${apk_tool}" --allow-untrusted extract --destination "${extract_dir}" \
    "${module_apk}" >/dev/null
find "${extract_dir}" -type f -name 'nft_fullcone.ko' -print -quit | grep -q . || \
    die "kmod-nft-fullcone APK 中没有 nft_fullcone.ko"

nftables_apk="$(find "${OUTPUT_DIR}" -maxdepth 1 -type f -name 'nftables-json-*.apk' -print -quit)"
firewall4_apk="$(find "${OUTPUT_DIR}" -maxdepth 1 -type f -name 'firewall4-*.apk' -print -quit)"
libnftnl_apk="$(find "${OUTPUT_DIR}" -maxdepth 1 -type f -name 'libnftnl11-*.apk' -print -quit)"
"${apk_tool}" --allow-untrusted extract --destination "${extract_dir}" \
    "${nftables_apk}" >/dev/null
"${apk_tool}" --allow-untrusted extract --destination "${extract_dir}" \
    "${firewall4_apk}" >/dev/null
"${apk_tool}" --allow-untrusted extract --destination "${extract_dir}" \
    "${libnftnl_apk}" >/dev/null
strings "${extract_dir}/usr/sbin/nft" | grep -Fxq fullcone || \
    die "nftables-json APK 不包含 fullcone parser"
libnftnl_file="$(find "${extract_dir}/usr/lib" -type f -name 'libnftnl.so.*' -print -quit)"
[ -n "${libnftnl_file}" ] || die "libnftnl11 APK 缺少共享库"
strings "${libnftnl_file}" | grep -Fxq fullcone || \
    die "libnftnl11 APK 不包含 fullcone expression"
grep -Fq 'nft_try_fullcone' "${extract_dir}/usr/share/ucode/fw4.uc" || \
    die "firewall4 APK 不包含 FullCone 运行时探测"
[ -f "${extract_dir}/usr/share/firewall4/templates/zone-fullcone.uc" ] || \
    die "firewall4 APK 缺少 zone-fullcone 模板"

: > "${OUTPUT_DIR}/install-packages.txt"
: > "${OUTPUT_DIR}/install-constraints.txt"
for package_name in "${REQUIRED_PACKAGES[@]}"; do
    printf '%s\n' "${package_name}" >> "${OUTPUT_DIR}/install-packages.txt"
    printf '%s@custom\n' "${package_name}" >> "${OUTPUT_DIR}/install-constraints.txt"
done

(
    cd "${OUTPUT_DIR}"
    sha256sum ./*.apk > SHA256SUMS
)

cat > "${OUTPUT_DIR}/BUILD-INFO.txt" <<EOF
OpenWrt version: ${OPENWRT_VERSION}
Target: ${TARGET_PATH}
Architecture: ${SDK_ARCH}
SDK archive: ${sdk_tarball}
SDK SHA-256: ${expected_sha256}
LEDE source commit: ${lede_head_commit}
nft-fullcone upstream commit: ${fullcone_upstream_commit}
Kernel dependency: ${kernel_dependency}
Patched packages:
EOF
sed 's/^/  /' "${OUTPUT_DIR}/repository-packages.txt" >> "${OUTPUT_DIR}/BUILD-INFO.txt"

echo "✓ FullCone APK 调用链编译完成，内核依赖: ${kernel_dependency}"
