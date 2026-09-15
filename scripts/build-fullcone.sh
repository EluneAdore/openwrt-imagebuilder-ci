#!/usr/bin/env bash
set -euo pipefail

# 使用与固件完全相同的 OpenWrt SDK 编译 ImmortalWrt nftables FullCone 调用链。
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
readonly IMMORTALWRT_REPO="https://github.com/immortalwrt/immortalwrt.git"
readonly IMMORTALWRT_DIR="${WORK_DIR}/immortalwrt-source"
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

echo "==> 克隆 ImmortalWrt 最新 HEAD..."
rm -rf "${IMMORTALWRT_DIR}"
git clone --depth=1 "${IMMORTALWRT_REPO}" "${IMMORTALWRT_DIR}"

if ! immortalwrt_head_commit="$(git -C "${IMMORTALWRT_DIR}" rev-parse HEAD 2>/dev/null)"; then
    die "无法获取 ImmortalWrt HEAD commit"
fi
[[ "${immortalwrt_head_commit}" =~ ^[0-9a-f]{40}$ ]] || \
    die "无法获取 ImmortalWrt HEAD commit"
echo "==> ImmortalWrt HEAD commit: ${immortalwrt_head_commit}"

readonly IMMORTALWRT_FULLCONE_PATH="package/network/utils/fullconenat-nft"
immortalwrt_fullcone_pkg="${IMMORTALWRT_DIR}/${IMMORTALWRT_FULLCONE_PATH}"
[ -d "${immortalwrt_fullcone_pkg}" ] || \
    die "ImmortalWrt HEAD 缺少 FullCone package: ${IMMORTALWRT_FULLCONE_PATH}"
[ -f "${immortalwrt_fullcone_pkg}/Makefile" ] || \
    die "ImmortalWrt HEAD FullCone package 缺少 Makefile"

fullcone_upstream_commit="$(sed -n 's/^PKG_SOURCE_VERSION:=[[:space:]]*//p' "${immortalwrt_fullcone_pkg}/Makefile" | head -n 1)"
[[ "${fullcone_upstream_commit}" =~ ^[0-9a-f]{40}$ ]] || \
    die "未能从 ImmortalWrt FullCone Makefile 中解析完整 PKG_SOURCE_VERSION"
fullcone_mirror_hash="$(sed -n 's/^PKG_MIRROR_HASH:=[[:space:]]*//p' "${immortalwrt_fullcone_pkg}/Makefile" | head -n 1)"
[[ "${fullcone_mirror_hash}" =~ ^[0-9a-f]{64}$ ]] || \
    die "未能从 ImmortalWrt FullCone Makefile 中解析有效 PKG_MIRROR_HASH"
echo "==> nft-fullcone 上游源码 commit: ${fullcone_upstream_commit}"
echo "==> nft-fullcone 源码归档 hash: ${fullcone_mirror_hash}"

immortalwrt_libnftnl_patch="${IMMORTALWRT_DIR}/package/libs/libnftnl/patches/001-libnftnl-add-fullcone-expression-support.patch"
immortalwrt_libnftnl_makefile="${IMMORTALWRT_DIR}/package/libs/libnftnl/Makefile"
immortalwrt_nftables_patch="${IMMORTALWRT_DIR}/package/network/utils/nftables/patches/002-nftables-add-fullcone-expression-support.patch"
immortalwrt_fw4_patch="${IMMORTALWRT_DIR}/package/network/config/firewall4/patches/001-firewall4-add-support-for-fullcone-nat.patch"
immortalwrt_fw4_makefile="${IMMORTALWRT_DIR}/package/network/config/firewall4/Makefile"

for patch_file in "${immortalwrt_libnftnl_patch}" "${immortalwrt_nftables_patch}" "${immortalwrt_fw4_patch}"; do
    [ -f "${patch_file}" ] || \
        die "ImmortalWrt HEAD 缺少补丁文件: ${patch_file#${IMMORTALWRT_DIR}/}"
done

[ -f "${immortalwrt_libnftnl_makefile}" ] || \
    die "ImmortalWrt HEAD 缺少 libnftnl Makefile"
grep -Fxq 'PKG_FIXUP:=autoreconf' "${immortalwrt_libnftnl_makefile}" || \
    die "ImmortalWrt HEAD libnftnl Makefile 未声明 PKG_FIXUP:=autoreconf"

grep -Fq '+kmod-nft-fullcone' "${immortalwrt_fw4_makefile}" || \
    die "ImmortalWrt HEAD firewall4 Makefile 未声明 kmod-nft-fullcone 依赖关系"

grep -Fq 'PKG_SOURCE ?= $(PKG_SOURCE_SUBDIR).tar.zst' \
    "${IMMORTALWRT_DIR}/include/download.mk" || \
    die "ImmortalWrt HEAD 已不再使用与官方 OpenWrt 25.12 兼容的 tar.zst 源码归档"
grep -Fq '$(subst -,.,$(PKG_SOURCE_DATE)),0)~$(call version_abbrev,$(PKG_SOURCE_VERSION))' \
    "${IMMORTALWRT_DIR}/include/download.mk" || \
    die "ImmortalWrt HEAD 已不再使用预期的日期~commit 源码版本格式"

echo "==> 查询 OpenWrt ${OPENWRT_VERSION} ${TARGET_PATH} 官方 SDK..."
target_index="$(curl -fsSL --retry 3 --connect-timeout 15 "${TARGET_URL}/")" || \
    die "无法读取 OpenWrt SDK 下载目录: ${TARGET_URL}/"
sdk_matches=""
if sdk_matches="$(printf '%s' "${target_index}" |
    grep -oE "openwrt-sdk-${OPENWRT_VERSION//./\\.}-${ARCH}_[^\"<>[:space:]]+\\.Linux-x86_64\\.tar\\.zst")"; then
    sdk_candidates="$(printf '%s\n' "${sdk_matches}" | sort -u)"
else
    sdk_candidates=""
fi
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

grep -Fq 'PKG_SOURCE ?= $(PKG_SOURCE_SUBDIR).tar.zst' include/download.mk || \
    die "官方 SDK 已不再使用预期的 tar.zst 源码归档格式"
grep -Fq '$(subst -,.,$(PKG_SOURCE_DATE)),0)~$(call version_abbrev,$(PKG_SOURCE_VERSION))' \
    include/download.mk || \
    die "官方 SDK 已不再使用预期的日期~commit 源码版本格式"

sdk_version="$(sed -n 's/^VERSION_NUMBER:=.*,[[:space:]]*\([^,)]*\))$/\1/p' include/version.mk | head -n 1)"
[ "${sdk_version}" = "${OPENWRT_VERSION}" ] || \
    die "SDK 版本不匹配: 期望 ${OPENWRT_VERSION}，实际 ${sdk_version:-未知}"

expected_base_commit="$(sed -n \
    's#^src-git --root=package base .*\^\([0-9a-f][0-9a-f]*\)$#\1#p' \
    feeds.conf.default)"
actual_base_commit=""
if [ -d feeds/base_root ]; then
    if ! actual_base_commit="$(git -C feeds/base_root rev-parse HEAD 2>/dev/null)"; then
        actual_base_commit=""
    fi
fi
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

# ImmortalWrt 的 FullCone libnftnl 补丁会修改 autotools 输入文件，因此官方
# SDK 必须重新生成构建系统。若官方包已声明 autoreconf，则保持原样；否则只
# 接受当前唯一且明确的许可证/安装字段锚点，结构变化时立即失败。
libnftnl_makefile="${base_source}/libs/libnftnl/Makefile"
[ -f "${libnftnl_makefile}" ] || die "SDK 缺少官方 libnftnl Makefile"
if grep -Fxq 'PKG_FIXUP:=autoreconf' "${libnftnl_makefile}"; then
    [ "$(grep -Fxc 'PKG_FIXUP:=autoreconf' "${libnftnl_makefile}")" -eq 1 ] || \
        die "官方 libnftnl Makefile 中 PKG_FIXUP:=autoreconf 出现多次"
else
    python3 - "${libnftnl_makefile}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
anchor = "PKG_LICENSE_FILES:=COPYING\n\nPKG_INSTALL:=1\n"
replacement = "PKG_LICENSE_FILES:=COPYING\n\nPKG_FIXUP:=autoreconf\nPKG_INSTALL:=1\n"
if text.count(anchor) != 1:
    raise SystemExit("官方 libnftnl Makefile autoreconf 注入锚点与预期不符")
path.write_text(text.replace(anchor, replacement))
PY
fi
grep -Fxq 'PKG_FIXUP:=autoreconf' "${libnftnl_makefile}" || \
    die "官方 libnftnl Makefile 未成功启用 autoreconf"

echo "==> 注入从 ImmortalWrt HEAD 提取的 FullCone 补丁..."
install -d \
    "${base_source}/libs/libnftnl/patches" \
    "${base_source}/network/utils/nftables/patches" \
    "${base_source}/network/config/firewall4/patches"
cp -f "${immortalwrt_libnftnl_patch}" \
    "${base_source}/libs/libnftnl/patches/"
cp -f "${immortalwrt_nftables_patch}" \
    "${base_source}/network/utils/nftables/patches/"

# ImmortalWrt 的补丁同时修改发行版默认 firewall 配置。这里只提取 FullCone
# 调用链，默认开关继续由本项目的 99-custom-defaults 管理。
fw4_patch_target="${base_source}/network/config/firewall4/patches/001-firewall4-add-support-for-fullcone-nat.patch"
python3 - "${immortalwrt_fw4_patch}" "${fw4_patch_target}" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1])
target = Path(sys.argv[2])
text = source.read_text()
start = "--- a/root/etc/config/firewall\n"
end = "--- a/root/usr/share/firewall4/templates/ruleset.uc\n"
if text.count(start) != 1 or text.count(end) != 1:
    raise SystemExit("ImmortalWrt firewall4 补丁结构与预期不符")
_, rest = text.split(start, 1)
_, suffix = rest.split(end, 1)
target.write_text(end + suffix)
PY

# 跟随 ImmortalWrt 的依赖方向：firewall4 -> kmod-nft-fullcone。仅修改官方
# firewall4 的依赖行，不替换其 Makefile 或源码版本。
firewall4_makefile="${base_source}/network/config/firewall4/Makefile"
if ! grep -Fq '+kmod-nft-fullcone' "${firewall4_makefile}"; then
    python3 - "${firewall4_makefile}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = "\t+kmod-nft-nat \\\n"
new = "\t+kmod-nft-nat +kmod-nft-fullcone \\\n"
if text.count(old) != 1:
    raise SystemExit("官方 firewall4 Makefile 依赖行与预期不符")
path.write_text(text.replace(old, new))
PY
fi

fullcone_package_dir="${sdk_dir}/package/fullcone/fullconenat-nft"
rm -rf "${fullcone_package_dir}"
install -d "$(dirname "${fullcone_package_dir}")"
cp -a "${immortalwrt_fullcone_pkg}" "${fullcone_package_dir}"

echo "==> 配置 FullCone SDK 编译目标..."
rm -rf tmp
cat > .config <<'EOF'
CONFIG_ALL_NONSHARED=n
CONFIG_ALL_KMODS=n
CONFIG_ALL=n
CONFIG_AUTOREMOVE=n
CONFIG_PACKAGE_kmod-nft-fullcone=y
CONFIG_PACKAGE_libnftnl=y
CONFIG_PACKAGE_nftables-json=y
CONFIG_PACKAGE_firewall4=y
EOF
make defconfig

for symbol in \
    CONFIG_PACKAGE_kmod-nft-fullcone \
    CONFIG_PACKAGE_libnftnl \
    CONFIG_PACKAGE_nftables-json \
    CONFIG_PACKAGE_firewall4; do
    grep -Eq "^${symbol}=[ym]$" .config || die "make defconfig 未保留 ${symbol}"
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
ImmortalWrt source commit: ${immortalwrt_head_commit}
ImmortalWrt donor path: ${IMMORTALWRT_FULLCONE_PATH}
nft-fullcone upstream commit: ${fullcone_upstream_commit}
nft-fullcone mirror hash: ${fullcone_mirror_hash}
Kernel dependency: ${kernel_dependency}
Patched packages:
EOF
sed 's/^/  /' "${OUTPUT_DIR}/repository-packages.txt" >> "${OUTPUT_DIR}/BUILD-INFO.txt"

echo "✓ FullCone APK 调用链编译完成，内核依赖: ${kernel_dependency}"
