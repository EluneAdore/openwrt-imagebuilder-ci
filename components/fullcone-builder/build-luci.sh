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

# FullCone builder component interface v1. It applies the smallest ImmortalWrt
# UI delta to the latest official LuCI stable feed revision matching the OpenWrt
# release series and rebuilds it in the SDK matching the final firmware.

OPENWRT_VERSION="${OPENWRT_VERSION:?必须指定 OPENWRT_VERSION}"
WORK_DIR="${WORK_DIR:?必须指定 WORK_DIR}"
OUTPUT_DIR="${OUTPUT_DIR:?必须指定 OUTPUT_DIR}"
ARCH="${ARCH:-x86-64}"
SDK_ARCH="${SDK_ARCH:-x86_64}"
TARGET_PATH="${TARGET_PATH:-x86/64}"
JOBS="${JOBS:-$(nproc)}"

mkdir -p "${WORK_DIR}" "${OUTPUT_DIR}"
WORK_DIR="$(cd "${WORK_DIR}" && pwd)"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"

readonly TARGET_URL="https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/${TARGET_PATH}"
readonly IMMORTALWRT_LUCI_COMMIT="d6167ea0645cbd1327708d85f94824f42d0eb872"
readonly COMPONENT_INTERFACE_VERSION=1
readonly -a REQUIRED_PACKAGES=(
    luci-base
    luci-app-firewall
    luci-i18n-firewall-zh-cn
)

COMPONENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="${COMPONENT_DIR}/patches/luci-fullcone"
DOWNLOAD_DIR="${WORK_DIR}/downloads"

die() {
    echo "❌ $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少构建命令: $1（请先运行 scripts/setup-env.sh）"
}

for command_name in awk cmp curl file git make patch python3 readelf sha256sum strings tar; do
    require_command "${command_name}"
done

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

mkdir -p "${WORK_DIR}" "${DOWNLOAD_DIR}"

# 1. 确保同版官方 SDK 就绪（支持独立组件构建）
SDK_DIR="${SDK_DIR:-}"

if [ -n "${SDK_DIR}" ] && [ -f "${SDK_DIR}/Makefile" ]; then
    sdk_dir="${SDK_DIR}"
    sdk_dir="$(cd "${sdk_dir}" && pwd)"
    sdk_tarball="external-sdk"
    expected_sha256="external-sdk"
    echo "==> 使用显式指定的 SDK 目录: ${sdk_dir}"
else
    sdk_dirs=()
    while IFS= read -r candidate; do
        [ -f "${candidate}/Makefile" ] && sdk_dirs+=("${candidate}")
    done < <(find "${WORK_DIR}" -maxdepth 1 -type d \
        -name "openwrt-sdk-${OPENWRT_VERSION}-${ARCH}_*.Linux-x86_64" -print 2>/dev/null)

    if [ ${#sdk_dirs[@]} -eq 1 ]; then
        sdk_dir="${sdk_dirs[0]}"
    else
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
    fi
fi

# 2. 自动解析当前 OpenWrt 稳定系列对应的官方 LuCI stable branch
VERSION_SERIES="$(echo "${OPENWRT_VERSION}" | cut -d. -f1-2)"
[ -n "${VERSION_SERIES}" ] || die "未能解析 OpenWrt 版本系列"

luci_feed_line="$(grep -E '^src-git(-full)?[[:space:]]+luci[[:space:]]+' "${sdk_dir}/feeds.conf.default" 2>/dev/null || true)"
[ -n "${luci_feed_line}" ] || die "SDK feeds.conf.default 中未找到 luci feed 定义"
luci_feed_entry="$(echo "${luci_feed_line}" | awk '{print $3}')"
default_luci_repo="${luci_feed_entry%%[\^;]*}"
[ -n "${default_luci_repo}" ] || die "未能从 feeds.conf.default 中解析 LuCI 仓库地址"

LUCI_REPOSITORY="${LUCI_REPOSITORY:-${default_luci_repo}}"
LUCI_BRANCH="${LUCI_BRANCH:-openwrt-${VERSION_SERIES}}"
luci_ref="refs/heads/${LUCI_BRANCH}"

echo "==> 检查官方 LuCI 仓库 (${LUCI_REPOSITORY}) 中是否存在 stable branch: ${LUCI_BRANCH}..."
remote_heads=""
if ! remote_heads="$(git ls-remote --heads "${LUCI_REPOSITORY}" "${luci_ref}" 2>/dev/null)"; then
    remote_heads=""
fi
if [ -z "${remote_heads}" ] && [[ "${LUCI_REPOSITORY}" == *"git.openwrt.org"* ]]; then
    # 官方 git.openwrt.org 网络超时或不可达时，备选尝试官方 GitHub 镜像
    github_mirror="https://github.com/openwrt/luci.git"
    echo "==> 官方 git.openwrt.org 查询无响应，尝试官方 GitHub 镜像 (${github_mirror})..."
    if ! remote_heads="$(git ls-remote --heads "${github_mirror}" "${luci_ref}" 2>/dev/null)"; then
        remote_heads=""
    fi
    if [ -n "${remote_heads}" ]; then
        LUCI_REPOSITORY="${github_mirror}"
    fi
fi

[ -n "${remote_heads}" ] || \
    die "无法在官方 LuCI 仓库中找到 OpenWrt ${OPENWRT_VERSION} 对应的 stable branch: ${LUCI_BRANCH}（严禁使用 master 或猜测分支）"

luci_commit="$(awk '{print $1}' <<< "${remote_heads}")"
[[ "${luci_commit}" =~ ^[0-9a-f]{40}$ ]] || \
    die "未能从远程仓库解析有效的 LuCI commit SHA: ${luci_commit}"
echo "==> 成功锁定官方 LuCI stable branch: ${LUCI_BRANCH} (${luci_ref})"
echo "==> 最新 stable revision commit SHA: ${luci_commit}"

# 3. 更新 SDK 中的 feeds/luci 至最新 stable revision
luci_source="${sdk_dir}/feeds/luci"
mkdir -p "$(dirname "${luci_source}")"

if [ -d "${luci_source}/.git" ]; then
    git -C "${luci_source}" remote set-url origin "${LUCI_REPOSITORY}" 2>/dev/null || true
    fetch_ok=false
    for fetch_try in 1 2 3; do
        if git -C "${luci_source}" fetch --depth=1 origin "${luci_ref}"; then
            fetch_ok=true
            break
        fi
        sleep 2
    done
    if [ "${fetch_ok}" != "true" ] && [[ "${LUCI_REPOSITORY}" == *"git.openwrt.org"* ]]; then
        echo "⚠️ 从 origin 拉取失败，尝试官方 GitHub 镜像..."
        git -C "${luci_source}" fetch --depth=1 "https://github.com/openwrt/luci.git" "${luci_ref}" || \
            die "无法获取官方 LuCI ${luci_ref} 源码"
    elif [ "${fetch_ok}" != "true" ]; then
        die "无法获取官方 LuCI ${luci_ref} 源码"
    fi
    git -C "${luci_source}" checkout --detach --force FETCH_HEAD
    git -C "${luci_source}" clean -fdx
else
    echo "==> 克隆官方 LuCI ${LUCI_BRANCH} 最新 revision..."
    rm -rf "${luci_source}"
    git clone --depth=1 --branch "${LUCI_BRANCH}" "${LUCI_REPOSITORY}" "${luci_source}"
fi

actual_luci_commit="$(git -C "${luci_source}" rev-parse HEAD)"
[ "${actual_luci_commit}" = "${luci_commit}" ] || \
    die "feeds/luci 当前 commit (${actual_luci_commit}) 与期望的最新 stable commit (${luci_commit}) 不一致"

# 4. 更新 feeds 配置并同步安装 LuCI 目标包定义
sed -i '\|^src-git\(-full\)\?[[:space:]]\+luci[[:space:]]|d' "${sdk_dir}/feeds.conf" 2>/dev/null || true
printf 'src-git luci %s;%s\n' "${LUCI_REPOSITORY}" "${LUCI_BRANCH}" >> "${sdk_dir}/feeds.conf"
(
    cd "${sdk_dir}"
    ./scripts/feeds update -i luci
    ./scripts/feeds install -p luci -f "${REQUIRED_PACKAGES[@]}"
)

# 5. 在最新 stable LuCI 源码上精确重放 FullCone 补丁（严禁 fuzz、跳过或静默退回）
echo "==> 应用 ImmortalWrt LuCI FullCone 最小补丁..."
for patch_file in \
    "${PATCH_DIR}/001-luci-base-detect-fullcone.patch" \
    "${PATCH_DIR}/002-luci-app-firewall-add-fullcone-options.patch" \
    "${PATCH_DIR}/003-luci-app-firewall-add-zh-hans-translations.patch"; do
    [ -f "${patch_file}" ] || die "缺少 LuCI FullCone 补丁: ${patch_file}"
    patch --batch --forward --fuzz=0 -d "${luci_source}" -p1 \
        < "${patch_file}" || die "LuCI FullCone 补丁无法精确应用: $(basename "${patch_file}")（上游结构变动，严禁模糊跳过或静默退回）"
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

# 6. 显式全量编译 luci-base 与 luci-app-firewall（含 zh-cn 翻译包）
echo "==> 清理并编译 FullCone LuCI APK..."
for package_name in "${REQUIRED_PACKAGES[@]}"; do
    rm -f "${sdk_dir}/bin/packages/${SDK_ARCH}/luci/${package_name}"-*.apk 2>/dev/null || true
done
make \
    package/feeds/luci/luci-base/clean \
    package/feeds/luci/luci-app-firewall/clean \
    DL_DIR="${DOWNLOAD_DIR}"
make -j"${JOBS}" \
    package/feeds/luci/luci-base/compile \
    package/feeds/luci/luci-app-firewall/compile \
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

immortalwrt_donor_commit="${IMMORTALWRT_LUCI_COMMIT}"
fullcone_source_commit="unknown"
fullcone_build_info="${WORK_DIR}/fullcone-packages-${OPENWRT_VERSION}/BUILD-INFO.txt"
if [ -f "${fullcone_build_info}" ]; then
    donor_from_info="$(awk -F': ' '$1 ~ /ImmortalWrt (donor|source) commit/ { print $2; exit }' "${fullcone_build_info}" 2>/dev/null || true)"
    [ -n "${donor_from_info}" ] && immortalwrt_donor_commit="${donor_from_info}"
    upstream_from_info="$(awk -F': ' '$1 ~ /nft-fullcone (source|upstream) commit/ { print $2; exit }' "${fullcone_build_info}" 2>/dev/null || true)"
    [ -n "${upstream_from_info}" ] && fullcone_source_commit="${upstream_from_info}"
elif [ -d "${WORK_DIR}/immortalwrt-source/.git" ]; then
    donor_from_git="$(git -C "${WORK_DIR}/immortalwrt-source" rev-parse HEAD 2>/dev/null || true)"
    [ -n "${donor_from_git}" ] && immortalwrt_donor_commit="${donor_from_git}"
fi

target="${TARGET_PATH%/*}"
subtarget="${TARGET_PATH#*/}"

cat > "${OUTPUT_DIR}/BUILD-INFO.txt" <<EOF
OpenWrt version: ${OPENWRT_VERSION}
Component interface: ${COMPONENT_INTERFACE_VERSION}
Target: ${target}
Subtarget: ${subtarget}
Architecture: ${SDK_ARCH}
LuCI repository: ${LUCI_REPOSITORY}
LuCI ref: ${luci_ref}
LuCI commit SHA: ${luci_commit}
ImmortalWrt donor commit: ${immortalwrt_donor_commit}
nft-fullcone source commit: ${fullcone_source_commit}
Backported packages: ${REQUIRED_PACKAGES[*]}
Installed package versions:
EOF
for package_name in "${REQUIRED_PACKAGES[@]}"; do
    awk -F= -v name="${package_name}" \
        '$1 == name { print "  " $0; exit }' \
        "${OUTPUT_DIR}/repository-packages.txt" \
        >> "${OUTPUT_DIR}/BUILD-INFO.txt"
done

echo "✓ FullCone LuCI APK 编译完成。"
