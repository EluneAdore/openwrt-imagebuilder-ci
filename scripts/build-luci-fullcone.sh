#!/usr/bin/env bash
set -euo pipefail

# 在官方 OpenWrt LuCI 源码上应用 ImmortalWrt openwrt-25.12 的最小
# FullCone UI 增量，并使用与固件完全同版的官方 SDK 重新编译 APK。

OPENWRT_VERSION="${OPENWRT_VERSION:?必须指定 OPENWRT_VERSION}"
WORK_DIR="${WORK_DIR:?必须指定 WORK_DIR}"
OUTPUT_DIR="${OUTPUT_DIR:?必须指定 OUTPUT_DIR}"
ARCH="${ARCH:-x86-64}"
SDK_ARCH="${SDK_ARCH:-x86_64}"
JOBS="${JOBS:-$(nproc)}"

readonly IMMORTALWRT_LUCI_BRANCH="openwrt-25.12"
readonly IMMORTALWRT_LUCI_COMMIT="d6167ea0645cbd1327708d85f94824f42d0eb872"
readonly -a REQUIRED_PACKAGES=(
    luci-base
    luci-app-firewall
    luci-i18n-firewall-zh-cn
)

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_DIR="${WORKSPACE_ROOT}/patches/luci-fullcone"
DOWNLOAD_DIR="${WORK_DIR}/downloads"

die() {
    echo "❌ $*" >&2
    exit 1
}

validate_firewall_ui() {
    local zones_file="$1"
    local source_label="$2"

    grep -Eq "if[[:space:]]*\\([[:space:]]*L\\.hasSystemFeature\\('fullcone'\\)[[:space:]]*\\)" \
        "${zones_file}" || die "${source_label} 未按 capability 控制 FullCone UI"
    grep -Eq "s\\.option\\(form\\.Flag,[[:space:]]*'fullcone',[[:space:]]*_\\('Enable FullCone NAT'\\)\\)" \
        "${zones_file}" || die "${source_label} 缺少 IPv4 FullCone 开关"
    grep -Eq "s\\.option\\(form\\.Flag,[[:space:]]*'fullcone6',[[:space:]]*_\\('Enable FullCone NAT6'\\)\\)" \
        "${zones_file}" || die "${source_label} 缺少 IPv6 FullCone 开关"
}

validate_zh_hans_po() {
    local po_file="$1"

    python3 - "${po_file}" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
translations = {
    "Enable FullCone NAT": "启用 FullCone NAT",
    "Enable FullCone NAT6": "启用 FullCone NAT6",
}
for msgid, msgstr in translations.items():
    entry = f'msgid "{msgid}"\nmsgstr "{msgstr}"'
    if text.count(entry) != 1:
        raise SystemExit(f"简体中文 PO 缺少唯一且非空的翻译: {msgid}")
PY
}

sdk_dirs=()
while IFS= read -r candidate; do
    sdk_dirs+=("${candidate}")
done < <(find "${WORK_DIR}" -maxdepth 1 -type d \
    -name "openwrt-sdk-${OPENWRT_VERSION}-${ARCH}_*.Linux-x86_64" -print)
[ ${#sdk_dirs[@]} -eq 1 ] || \
    die "同版官方 SDK 目录数量异常: ${#sdk_dirs[@]}"
sdk_dir="${sdk_dirs[0]}"

luci_source="${sdk_dir}/feeds/luci"
[ -d "${luci_source}/.git" ] || die "SDK 缺少已初始化的官方 LuCI feed"
official_luci_commit="$(git -C "${luci_source}" rev-parse HEAD)"

# 前一次中断可能留下已应用的补丁。每次都从当前官方 feed commit
# 恢复 LuCI tracked files，保证补丁必须能在官方源码上精确重放。
git -C "${luci_source}" reset --hard "${official_luci_commit}" >/dev/null
git -C "${luci_source}" clean -fd >/dev/null

echo "==> 应用 ImmortalWrt LuCI FullCone 最小补丁..."
for patch_file in \
    "${PATCH_DIR}/001-luci-base-detect-fullcone.patch" \
    "${PATCH_DIR}/002-luci-app-firewall-add-fullcone-options.patch" \
    "${PATCH_DIR}/003-luci-app-firewall-add-zh-hans-translations.patch"; do
    [ -f "${patch_file}" ] || die "缺少 LuCI FullCone 补丁: ${patch_file}"
    patch --batch --forward --fuzz=0 -d "${luci_source}" -p1 \
        < "${patch_file}" || die "LuCI FullCone 补丁无法精确应用: $(basename "${patch_file}")"
done

luci_rpc="${luci_source}/modules/luci-base/root/usr/share/rpcd/ucode/luci"
luci_zones="${luci_source}/applications/luci-app-firewall/htdocs/luci-static/resources/view/firewall/zones.js"
luci_firewall_po="${luci_source}/applications/luci-app-firewall/po/zh_Hans/firewall.po"
grep -Fq "fullcone:   access('/sys/module/xt_FULLCONENAT/refcnt') == true || access('/sys/module/nft_fullcone/refcnt') == true," \
    "${luci_rpc}" || die "patched luci-base 缺少 FullCone capability detection"
validate_firewall_ui "${luci_zones}" 'patched luci-app-firewall'
validate_zh_hans_po "${luci_firewall_po}"
grep -Fq "po2lmo \$(po)" "${luci_source}/luci.mk" || \
    die "官方 LuCI 构建规则缺少 PO → LMO 转换"

cd "${sdk_dir}"
rm -rf tmp
cat > .config <<'EOF'
CONFIG_ALL_NONSHARED=n
CONFIG_ALL_KMODS=n
CONFIG_ALL=n
CONFIG_AUTOREMOVE=n
CONFIG_LUCI_LANG_zh_Hans=y
CONFIG_PACKAGE_luci-base=y
CONFIG_PACKAGE_luci-app-firewall=y
CONFIG_PACKAGE_luci-i18n-firewall-zh-cn=y
EOF
make defconfig
for package_name in "${REQUIRED_PACKAGES[@]}"; do
    grep -Fqx "CONFIG_PACKAGE_${package_name}=y" .config || \
        die "make defconfig 未保留 ${package_name}=y"
done

echo "==> 清理并编译 FullCone LuCI APK..."
make \
    package/feeds/luci/luci-base/clean \
    package/feeds/luci/luci-app-firewall/clean \
    DL_DIR="${DOWNLOAD_DIR}"
make -j"${JOBS}" package/feeds/luci/luci-app-firewall/compile \
    DL_DIR="${DOWNLOAD_DIR}" || die "FullCone LuCI APK 编译失败"

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
        [ "$(apk_field "${apk_file}" name)" = "${required_name}" ] && \
            matches+=("${apk_file}")
    done < <(find "${sdk_dir}/bin/packages/${SDK_ARCH}/luci" \
        -maxdepth 1 -type f -name '*.apk' -print)
    [ ${#matches[@]} -eq 1 ] || die "${required_name} APK 数量异常: ${#matches[@]}"
    cp -f "${matches[0]}" "${OUTPUT_DIR}/"
    package_version="$(apk_field "${matches[0]}" version)"
    [ -n "${package_version}" ] || die "无法读取 ${required_name} APK 版本"
    printf '%s=%s\n' "${required_name}" "${package_version}" \
        >> "${OUTPUT_DIR}/repository-packages.txt"
done

[ -f "${sdk_dir}/public-key.pem" ] || die "SDK 未生成 APK 签名公钥"
cp -f "${sdk_dir}/public-key.pem" "${OUTPUT_DIR}/luci-fullcone-public-key.pem"

extract_dir="$(mktemp -d "${WORK_DIR}/luci-fullcone-apk.XXXXXX")"
trap 'rm -rf "${extract_dir}"' EXIT INT TERM
for apk_file in "${OUTPUT_DIR}"/*.apk; do
    package_name="$(apk_field "${apk_file}" name)"
    package_extract_dir="${extract_dir}/${package_name}"
    mkdir -p "${package_extract_dir}"
    "${apk_tool}" --allow-untrusted extract --destination "${package_extract_dir}" \
        "${apk_file}" >/dev/null
done
grep -Fq "fullcone:   access('/sys/module/xt_FULLCONENAT/refcnt') == true || access('/sys/module/nft_fullcone/refcnt') == true," \
    "${extract_dir}/luci-base/usr/share/rpcd/ucode/luci" || \
    die "luci-base APK 缺少 FullCone capability detection"
zones_file="${extract_dir}/luci-app-firewall/www/luci-static/resources/view/firewall/zones.js"
validate_firewall_ui "${zones_file}" 'luci-app-firewall APK'
firewall_lmo="${extract_dir}/luci-i18n-firewall-zh-cn/usr/lib/lua/luci/i18n/firewall.zh-cn.lmo"
[ -s "${firewall_lmo}" ] || \
    die "luci-i18n-firewall-zh-cn APK 缺少非空 firewall.zh-cn.lmo"

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
Official LuCI commit: ${official_luci_commit}
ImmortalWrt LuCI branch: ${IMMORTALWRT_LUCI_BRANCH}
ImmortalWrt LuCI reference commit: ${IMMORTALWRT_LUCI_COMMIT}
Backported packages: ${REQUIRED_PACKAGES[*]}
EOF

echo "✓ FullCone LuCI APK 编译完成。"
