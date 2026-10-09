#!/usr/bin/env bash
set -euo pipefail

# 为固件配置固定的软件源快照，并在独立临时 root 中验证实际 APK 事务。
die() { printf '错误: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 7 ] || die "用法: $0 <stage|verify> <imagebuilder-dir> <overlay|rootfs-dir> <version> <helloworld-dir> <runtime-dir> <luci-dir>"
mode="$1"
ib_dir="$(cd "$2" && pwd)"
target_dir="$3"
version="$4"
component_dirs=("$5" "$6" "$7")
kinds=(helloworld fullcone-runtime fullcone-luci)
key_names=(helloworld-public-key.pem fullcone-public-key.pem luci-fullcone-public-key.pem)
case "${mode}" in stage|verify) ;; *) die "未知操作: ${mode}" ;; esac
apk_tool="${ib_dir}/staging_dir/host/bin/apk"
[ -x "${apk_tool}" ] || die "ImageBuilder 缺少 apk 工具"
mkdir -p "${ib_dir}/tmp"
temporary_dir="$(mktemp -d "${ib_dir}/tmp/custom-feed.XXXXXX")"
trap 'rm -rf "${temporary_dir}"' EXIT
: > "${temporary_dir}/custom-components.list"
: > "${temporary_dir}/constraints.txt"

for i in 0 1 2; do
    component_dir="${component_dirs[$i]}"
    kind="${kinds[$i]}"
    key_name="${key_names[$i]}"
    index_name="${kind}-packages.adb"
    # 拒绝旧 artifact、错误架构、错版快照和未纳入校验清单的运行时配置。
    python3 - "${component_dir}" "${kind}" "${key_name}" "${version}" <<'PY'
import pathlib, re, sys
root, kind, key, version = pathlib.Path(sys.argv[1]), *sys.argv[2:]
def fail(message):
    raise SystemExit("错误: " + message)
required = {"BUILD-INFO.txt", "repository-packages.txt", "install-packages.txt",
            "install-constraints.txt", "runtime-repository.url", key, kind + "-packages.adb"}
if kind == "fullcone-runtime":
    required.add("kernel-dependency.txt")
required.update(p.name for p in root.glob("*.apk"))
allowed = required
covered = set()
for line in (root / "SHA256SUMS").read_text().splitlines():
    match = re.fullmatch(r"[0-9a-fA-F]{64} [ *](\S+)", line)
    name = match[1].removeprefix("./") if match else ""
    if name not in allowed or name in covered:
        fail(kind + " 的 SHA256SUMS 包含非法或重复路径")
    covered.add(name)
if covered != required:
    fail(kind + " 的 SHA256SUMS 未覆盖全部软件源文件，请重新构建组件")
for name in required:
    path = root / name
    if not path.is_file() or path.is_symlink() or path.stat().st_size == 0:
        fail(kind + " 缺少有效文件: " + name)
info = (root / "BUILD-INFO.txt").read_text().splitlines()
if info.count("OpenWrt version: " + version) != 1 or info.count("Architecture: x86_64") != 1:
    fail(kind + " 的版本或架构不匹配")
url = (root / "runtime-repository.url").read_text().strip()
release_kind = "helloworld" if kind == "helloworld" else "fullcone"
pattern = (r"https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/download/custom-"
           + release_kind + "-" + re.escape(version) + r"-x86_64-[1-9][0-9]*-[1-9][0-9]*/"
           + re.escape(kind + "-packages.adb"))
if not re.fullmatch(pattern, url):
    fail(kind + " 的软件源 URL 必须是同版本、同架构的固定 GitHub Release 快照")
packages = (root / "install-packages.txt").read_text().splitlines()
constraints = (root / "install-constraints.txt").read_text().splitlines()
if not packages or len(packages) != len(set(packages)) or len(packages) != len(constraints):
    fail(kind + " 的安装清单与约束不一致")
for name, pin in zip(packages, constraints):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9+_.-]*", name):
        fail("安装包名无效")
    if pin == name and name in {"v2ray-geodata", "v2ray-geoip", "v2ray-geosite"}:
        continue
    if not re.fullmatch(re.escape(name) + r"@custom><Q1[A-Za-z0-9+/]{27}=", pin):
        fail(kind + " 的定制包必须使用 APK 身份约束: " + name)
PY
    (cd "${component_dir}" && sha256sum --check --strict SHA256SUMS) || die "${kind} 软件源文件校验失败"
    mkdir -p "${temporary_dir}/keys-${i}"
    cp "${component_dir}/${key_name}" "${temporary_dir}/keys-${i}/${key_name}"
    "${apk_tool}" --keys-dir "${temporary_dir}/keys-${i}" verify "${component_dir}/${index_name}" || die "${kind} 索引签名无效"
    "${apk_tool}" adbdump "${component_dir}/${index_name}" > "${temporary_dir}/index.txt"
    python3 - "${component_dir}/install-constraints.txt" "${temporary_dir}/index.txt" <<'PY'
import base64, pathlib, re, sys
constraints = pathlib.Path(sys.argv[1]).read_text().splitlines()
entries, current = {}, None
for line in pathlib.Path(sys.argv[2]).read_text().splitlines():
    match = re.fullmatch(r"  - name: (\S+)", line)
    if match:
        current = match[1]
    match = re.fullmatch(r"    hashes: ([0-9a-fA-F]{40,})", line)
    if match and current:
        entries[current] = "Q1" + base64.b64encode(bytes.fromhex(match[1][:40])).decode()
for pin in constraints:
    if "@custom" in pin:
        name, identity = pin.split("@custom><", 1)
        if entries.get(name) != identity:
            raise SystemExit("错误: APK 安装身份与签名索引不符: " + name)
PY
    url="$(cat "${component_dir}/runtime-repository.url")"
    printf '@custom %s\n' "${url}" >> "${temporary_dir}/custom-components.list"
    cat "${component_dir}/install-constraints.txt" >> "${temporary_dir}/constraints.txt"
    if [ "${mode}" = stage ]; then
        curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 15 --max-time 180 \
            "${url}" -o "${temporary_dir}/remote-${index_name}" || die "已发布的 ${kind} 索引不可访问"
        cmp -s "${component_dir}/${index_name}" "${temporary_dir}/remote-${index_name}" || die "已发布的 ${kind} 索引与当前组件不一致"
        "${apk_tool}" --keys-dir "${temporary_dir}/keys-${i}" verify "${temporary_dir}/remote-${index_name}" || die "远程 ${kind} 索引签名无效"
    fi
done

runtime_base="$(sed 's|/[^/]*$||' "${component_dirs[1]}/runtime-repository.url")"
luci_base="$(sed 's|/[^/]*$||' "${component_dirs[2]}/runtime-repository.url")"
[ "${runtime_base}" = "${luci_base}" ] || die "FullCone runtime 与 LuCI 必须来自同一发布快照"

if [ "${mode}" = stage ]; then
    mkdir -p "${target_dir}/etc/apk/repositories.d" "${target_dir}/etc/apk/keys"
    install -m 0644 "${temporary_dir}/custom-components.list" "${target_dir}/etc/apk/repositories.d/custom-components.list"
    for i in 0 1 2; do
        install -m 0644 "${component_dirs[$i]}/${key_names[$i]}" "${target_dir}/etc/apk/keys/${key_names[$i]}"
    done
    echo '✓ 已验证公网签名索引，并生成固件运行时 @custom 源和公钥。'
    exit 0
fi

cmp -s "${temporary_dir}/custom-components.list" "${target_dir}/etc/apk/repositories.d/custom-components.list" || die "最终 rootfs 的 @custom 软件源配置不匹配"
for i in 0 1 2; do
    cmp -s "${component_dirs[$i]}/${key_names[$i]}" "${target_dir}/etc/apk/keys/${key_names[$i]}" || die "最终 rootfs 缺少正确的 ${key_names[$i]}"
done
python3 - "${temporary_dir}/constraints.txt" "${target_dir}/etc/apk/world" <<'PY'
import pathlib, sys
expected = {p for p in pathlib.Path(sys.argv[1]).read_text().splitlines() if "@custom" in p}
actual = {p for p in pathlib.Path(sys.argv[2]).read_text().splitlines() if "@custom" in p}
if actual != expected:
    raise SystemExit("错误: 最终 rootfs 的 @custom APK 身份约束缺失或不匹配")
PY

# 使用副本与独立缓存验证普通装包；禁止运行固件维护脚本或改变待交付 rootfs。
mkdir -p "${temporary_dir}/root" "${temporary_dir}/cache"
cp -a "${target_dir}/." "${temporary_dir}/root/"
apk_args=(--root "${temporary_dir}/root" --arch x86_64
    --keys-dir "${temporary_dir}/root/etc/apk/keys"
    --cache-dir "${temporary_dir}/cache" --no-logfile)
"${apk_tool}" "${apk_args[@]}" update 2>&1 | tee "${ib_dir}/tmp/custom-feed-update.log" || die "固件运行时软件源 apk update 失败"
"${apk_tool}" "${apk_args[@]}" add --no-scripts --simulate coremark 2>&1 | tee "${ib_dir}/tmp/custom-feed-coremark.log" || die "固件运行时 apk add --simulate coremark 失败"
python3 - "${temporary_dir}/constraints.txt" "${ib_dir}/tmp/custom-feed-coremark.log" <<'PY'
import pathlib, re, sys
packages = [p.split("@", 1)[0] for p in pathlib.Path(sys.argv[1]).read_text().splitlines() if "@custom" in p]
log = pathlib.Path(sys.argv[2]).read_text()
for name in packages:
    if re.search(r"(?:Reinstalling|Upgrading|Downgrading|Purging)\s+" + re.escape(name) + r"(?:\s|$)", log, re.I):
        raise SystemExit("错误: 安装 coremark 会替换定制包: " + name)
PY
echo '✓ 运行时 APK 更新与 coremark 模拟安装通过，定制组件保持原身份。'
