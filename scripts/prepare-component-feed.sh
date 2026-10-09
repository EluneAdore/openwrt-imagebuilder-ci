#!/usr/bin/env bash
set -euo pipefail

# 把组件构建产物转换为固件内置、严格签名的 APK v3 软件源。
die() { printf '错误: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 3 ] || die "用法: $0 <feed-kind> <component-dir> <sdk-dir>"
feed_kind="$1"
component_dir="$2"
sdk_dir="$3"
case "${feed_kind}" in
    helloworld) public_key_name=helloworld-public-key.pem ;;
    fullcone-runtime) public_key_name=fullcone-public-key.pem ;;
    fullcone-luci) public_key_name=luci-fullcone-public-key.pem ;;
    *) die "未知组件类型: ${feed_kind}" ;;
esac
for tool in python3 openssl sha256sum; do
    command -v "${tool}" >/dev/null 2>&1 || die "缺少工具: ${tool}"
done
[ -d "${component_dir}" ] || die "组件目录不存在: ${component_dir}"
[ -d "${sdk_dir}" ] || die "SDK 目录不存在: ${sdk_dir}"
component_dir="$(cd "${component_dir}" && pwd)"
sdk_dir="$(cd "${sdk_dir}" && pwd)"
apk_tool="${sdk_dir}/staging_dir/host/bin/apk"
index_name="${feed_kind}-packages.adb"
[ -x "${apk_tool}" ] || die "SDK 缺少 apk 工具"
for file in BUILD-INFO.txt repository-packages.txt install-packages.txt install-constraints.txt SHA256SUMS "${public_key_name}"; do
    [ -s "${component_dir}/${file}" ] && [ ! -L "${component_dir}/${file}" ] || die "缺少有效组件文件: ${file}"
done
for file in private-key.pem public-key.pem; do
    [ -s "${sdk_dir}/${file}" ] || die "SDK 缺少签名密钥文件"
done
shopt -s nullglob
package_files=("${component_dir}"/*.apk)
shopt -u nullglob
[ "${#package_files[@]}" -gt 0 ] || die "组件目录中没有 APK"

# 先限制原清单的路径与覆盖范围，再执行原始 SHA-256 校验。
python3 - "${component_dir}" "${public_key_name}" "${index_name}" "${OPENWRT_VERSION:-}" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
key_name, index_name, expected_version = sys.argv[2:]
def fail(message):
    raise SystemExit("错误: " + message)
fields = {}
for line in (root / "BUILD-INFO.txt").read_text().splitlines():
    if ": " in line and not line.startswith(" "):
        name, value = line.split(": ", 1)
        if name in fields:
            fail("BUILD-INFO.txt 包含重复字段: " + name)
        fields[name] = value
version = fields.get("OpenWrt version", "")
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-rc[0-9]+)?", version):
    fail("BUILD-INFO.txt 缺少有效 OpenWrt 版号")
if expected_version and version != expected_version:
    fail("BUILD-INFO.txt 与 OPENWRT_VERSION 不一致")
if fields.get("Architecture") != "x86_64":
    fail("BUILD-INFO.txt Architecture 必须是 x86_64")
allowed = {"BUILD-INFO.txt", "repository-packages.txt", "install-packages.txt",
           "install-constraints.txt", "kernel-dependency.txt",
           key_name, index_name}
packages = {p.name for p in root.glob("*.apk")}
seen = set()
for line in (root / "SHA256SUMS").read_text().splitlines():
    match = re.fullmatch(r"[0-9a-fA-F]{64} [ *](\S+)", line)
    if not match:
        fail("原 SHA256SUMS 格式无效")
    filename = match.group(1).removeprefix("./")
    if "/" in filename or filename not in allowed | packages or filename in seen:
        fail("原 SHA256SUMS 包含非法或重复路径")
    seen.add(filename)
if not packages <= seen:
    fail("原 SHA256SUMS 未覆盖全部 APK")
for name in packages:
    if (root / name).is_symlink() or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9+_.~-]*\.apk", name):
        fail("APK 文件名无效或为符号链接")
PY
(cd "${component_dir}" && sha256sum --check --strict SHA256SUMS) || die "原组件 SHA-256 校验失败"
build_version="$(sed -n 's/^OpenWrt version: //p' "${component_dir}/BUILD-INFO.txt")"
if [ -f "${sdk_dir}/include/version.mk" ]; then
    sdk_version="$(sed -n 's/^VERSION_NUMBER:=.*,[[:space:]]*\([^,)]*\))$/\1/p' "${sdk_dir}/include/version.mk")"
    [ "${sdk_version}" = "${build_version}" ] || die "SDK 与组件 OpenWrt 版号不一致"
fi

temporary_dir="$(mktemp -d "${component_dir}/.prepare-feed.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT
mkdir -p "${temporary_dir}/keys"
cp "${component_dir}/${public_key_name}" "${temporary_dir}/keys/${public_key_name}"
openssl pkey -pubin -in "${component_dir}/${public_key_name}" -outform DER \
    -out "${temporary_dir}/component-public.der" 2>/dev/null || die "组件公钥无效"
openssl pkey -pubin -in "${sdk_dir}/public-key.pem" -outform DER \
    -out "${temporary_dir}/sdk-public.der" 2>/dev/null || die "SDK 公钥无效"
openssl pkey -in "${sdk_dir}/private-key.pem" -pubout -outform DER \
    -out "${temporary_dir}/signing-public.der" 2>/dev/null || die "SDK 私钥无效"
cmp -s "${temporary_dir}/component-public.der" "${temporary_dir}/sdk-public.der" || die "组件与 SDK 公钥不一致"
cmp -s "${temporary_dir}/signing-public.der" "${temporary_dir}/sdk-public.der" || die "SDK 签名私钥与公钥不一致"

: > "${temporary_dir}/apk-metadata.tsv"
prepared_packages=()
for package_file in "${package_files[@]}"; do
    prepared_package="${temporary_dir}/${package_file##*/}"
    cp "${package_file}" "${prepared_package}"
    "${apk_tool}" adbdump "${prepared_package}" > "${temporary_dir}/package.txt" || die "无法读取 APK 元数据"
    if ! "${apk_tool}" --keys-dir "${temporary_dir}/keys" verify "${prepared_package}" > "${temporary_dir}/verify.log" 2>&1; then
        # OpenWrt 单包 compile 的 mkpkg 不签名；SDK 有密钥不代表 APK 已签名。
        # 已存在签名却不可信的 APK 必须拒绝，不能通过追加本地签名掩盖错误。
        if grep -q '^# sig ' "${temporary_dir}/package.txt"; then
            cat "${temporary_dir}/verify.log" >&2
            die "已有 APK 签名或完整性校验失败，拒绝重新签名"
        fi
        # 此选项只用于校验和首次签署本次 SDK 的未签名构建产物。
        # 索引和运行时验签不允许使用它。
        "${apk_tool}" --keys-dir "${temporary_dir}/keys" --allow-untrusted verify "${prepared_package}" || die "未签名 APK 内容完整性校验失败"
        "${apk_tool}" --keys-dir "${temporary_dir}/keys" --allow-untrusted adbsign \
            --sign-key "${sdk_dir}/private-key.pem" "${prepared_package}" || die "APK 签名失败"
    fi
    # apk-tools 3.0.5 adbsign 可能报错仍返回 0，必须独立严格验签确认。
    "${apk_tool}" --keys-dir "${temporary_dir}/keys" verify "${prepared_package}" || die "APK 签名或完整性校验失败"
    prepared_packages+=("${prepared_package}")
    python3 - "${package_file##*/}" "${temporary_dir}/package.txt" >> "${temporary_dir}/apk-metadata.tsv" <<'PY'
import pathlib, re, sys
fields = {}
for line in pathlib.Path(sys.argv[2]).read_text().splitlines():
    match = re.fullmatch(r"  (name|version|arch): (\S+)", line)
    if match:
        if match[1] in fields:
            raise SystemExit("错误: APK 元数据字段重复")
        fields[match[1]] = match[2]
name, version, arch = (fields.get(key, "") for key in ("name", "version", "arch"))
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9+_.-]*", name) or not version or arch not in {"x86_64", "all", "noarch"}:
    raise SystemExit("错误: APK 名称、版本或架构无效")
if sys.argv[1] != name + "-" + version + ".apk":
    raise SystemExit("错误: APK 文件名与 name-version.apk 不一致")
print(name, version, sep="\t")
PY
done
"${apk_tool}" --keys-dir "${temporary_dir}/keys" mkndx \
    --sign-key "${sdk_dir}/private-key.pem" \
    --description "OpenWrt ${build_version} ${feed_kind} x86_64" \
    --output "${temporary_dir}/${index_name}" "${prepared_packages[@]}" || die "生成签名 APK 索引失败"
"${apk_tool}" --keys-dir "${temporary_dir}/keys" verify "${temporary_dir}/${index_name}" || die "APK 索引签名校验失败"
"${apk_tool}" --keys-dir "${temporary_dir}/keys" adbdump "${temporary_dir}/${index_name}" > "${temporary_dir}/index.txt" || die "无法读取 APK 索引"

# APK 3 的安装身份来自索引中的 hashes 前 20 字节，不是 APK info.hashes。
python3 - "${component_dir}" "${temporary_dir}" <<'PY'
import base64, pathlib, re, sys
root, temporary = map(pathlib.Path, sys.argv[1:])
def fail(message):
    raise SystemExit("错误: " + message)
index_lines = (temporary / "index.txt").read_text().splitlines()
actual = {}
for line in (temporary / "apk-metadata.tsv").read_text().splitlines():
    name, version = line.split("\t")
    if name in actual:
        fail("同一组件包含重复包名: " + name)
    actual[name] = version
declared = {}
for line in (root / "repository-packages.txt").read_text().splitlines():
    match = re.fullmatch(r"([A-Za-z0-9][A-Za-z0-9+_.-]*)=(\S+)", line)
    if not match or match[1] in declared:
        fail("repository-packages.txt 包含非法或重复条目")
    declared[match[1]] = match[2]
if actual != declared:
    fail("APK 与 repository-packages.txt 不是一一对应")
entries, current = {}, None
for line in index_lines:
    match = re.fullmatch(r"  - name: (\S+)", line)
    if match:
        current = match[1]
        if current in entries:
            fail("APK 索引包含重复包名")
        entries[current] = {}
        continue
    match = re.fullmatch(r"    (version|hashes): (\S+)", line)
    if match and current:
        if match[1] in entries[current]:
            fail("APK 索引包含重复字段")
        entries[current][match[1]] = match[2]
if entries.keys() != actual.keys():
    fail("APK 索引没有覆盖完整组件")
identities = {}
for name, fields in entries.items():
    hashes = fields.get("hashes", "")
    if fields.get("version") != actual[name] or not re.fullmatch(r"[0-9a-fA-F]{40,}", hashes) or len(hashes) % 2:
        fail("APK 索引版本或身份摘要无效")
    identities[name] = "Q1" + base64.b64encode(bytes.fromhex(hashes[:40])).decode()
packages = (root / "install-packages.txt").read_text().splitlines()
constraints = (root / "install-constraints.txt").read_text().splitlines()
if not packages or len(packages) != len(set(packages)) or len(packages) != len(constraints):
    fail("安装清单为空、重复或与约束数目不一致")
new_constraints = []
for name, constraint in zip(packages, constraints):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9+_.-]*", name):
        fail("install-packages.txt 包名无效")
    if re.fullmatch(re.escape(name) + r"@custom(?:[=~<>].*)?", constraint):
        if name not in identities:
            fail("@custom 安装目标缺少 APK: " + name)
        new_constraints.append(name + "@custom><" + identities[name])
    elif name in {"v2ray-geodata", "v2ray-geoip", "v2ray-geosite"} and constraint == name and name not in actual:
        new_constraints.append(constraint)
    else:
        fail("安装约束必须锁定 @custom；官方 GeoData 保持无 tag")
(temporary / "install-constraints.txt").write_text("\n".join(new_constraints) + "\n")
PY
checksum_files=(BUILD-INFO.txt repository-packages.txt install-packages.txt "${public_key_name}")
[ ! -f "${component_dir}/kernel-dependency.txt" ] || checksum_files+=(kernel-dependency.txt)
(
    cd "${component_dir}"
    sha256sum "${checksum_files[@]}"
) > "${temporary_dir}/SHA256SUMS"
(
    cd "${temporary_dir}"
    sha256sum "${prepared_packages[@]##*/}" "${index_name}" install-constraints.txt
) >> "${temporary_dir}/SHA256SUMS"
for prepared_package in "${prepared_packages[@]}"; do
    mv -f "${prepared_package}" "${component_dir}/${prepared_package##*/}"
done
mv -f "${temporary_dir}/${index_name}" "${component_dir}/${index_name}"
mv -f "${temporary_dir}/install-constraints.txt" "${component_dir}/install-constraints.txt"
mv -f "${temporary_dir}/SHA256SUMS" "${component_dir}/SHA256SUMS"
(cd "${component_dir}" && sha256sum --check --strict SHA256SUMS) || die "新软件源 SHA-256 校验失败"
printf '已准备 %s 内置软件源，共 %s 个 APK，签名索引: %s\n' "${feed_kind}" "${#package_files[@]}" "${index_name}"
