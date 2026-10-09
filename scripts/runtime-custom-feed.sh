#!/usr/bin/env bash
set -euo pipefail

# 为固件内置签名组件软件源，并在独立临时 root 中验证实际 APK 事务。
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
mkdir -p "${temporary_dir}/embedded"

for i in 0 1 2; do
    component_dir="${component_dirs[$i]}"
    kind="${kinds[$i]}"
    key_name="${key_names[$i]}"
    index_name="${kind}-packages.adb"
    # 拒绝旧 artifact、错误架构、错版组件和未纳入校验清单的文件。
    python3 - "${component_dir}" "${kind}" "${key_name}" "${version}" <<'PY'
import pathlib, re, sys
root, kind, key, version = pathlib.Path(sys.argv[1]), *sys.argv[2:]
def fail(message):
    raise SystemExit("错误: " + message)
required = {"BUILD-INFO.txt", "repository-packages.txt", "install-packages.txt",
            "install-constraints.txt", key, kind + "-packages.adb"}
if kind == "fullcone-runtime":
    required.add("kernel-dependency.txt")
apk_files = {p.name for p in root.glob("*.apk")}
if not apk_files:
    fail(kind + " 没有组件 APK")
required.update(apk_files)
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
declared = {}
for line in (root / "repository-packages.txt").read_text().splitlines():
    match = re.fullmatch(r"([A-Za-z0-9][A-Za-z0-9+_.-]*)=([A-Za-z0-9][A-Za-z0-9+_.~-]*)", line)
    if not match or match[1] in declared:
        fail(kind + " 的 repository-packages.txt 包含非法或重复条目")
    declared[match[1]] = match[2]
if {name + "-" + version + ".apk" for name, version in declared.items()} != apk_files:
    fail(kind + " 的 APK 与 repository-packages.txt 不是一一对应")
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
    shopt -s nullglob
    package_files=("${component_dir}"/*.apk)
    shopt -u nullglob
    "${apk_tool}" --keys-dir "${temporary_dir}/keys-${i}" verify "${package_files[@]}" || die "${kind} APK 签名或完整性无效"
    "${apk_tool}" --keys-dir "${temporary_dir}/keys-${i}" verify "${component_dir}/${index_name}" || die "${kind} 索引签名无效"
    "${apk_tool}" adbdump "${component_dir}/${index_name}" > "${temporary_dir}/index.txt"
    python3 - "${component_dir}" "${temporary_dir}/index.txt" <<'PY'
import base64, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
constraints = (root / "install-constraints.txt").read_text().splitlines()
index_lines = pathlib.Path(sys.argv[2]).read_text().splitlines()
spec = [line for line in index_lines if line.startswith("pkgname-spec:")]
if spec not in ([], ["pkgname-spec: ${name}-${version}.apk"]):
    raise SystemExit("错误: 内置 APK 索引必须使用 name-version.apk 文件名，请重新构建组件")
entries, current = {}, None
for line in index_lines:
    match = re.fullmatch(r"  - name: (\S+)", line)
    if match:
        current = match[1]
        if current in entries:
            raise SystemExit("错误: APK 索引包含重复包名")
        entries[current] = {}
    match = re.fullmatch(r"    (version|hashes|file-size): (\S+)", line)
    if match and current:
        if match[1] in entries[current]:
            raise SystemExit("错误: APK 索引包含重复字段")
        entries[current][match[1]] = match[2]
declared = dict(line.split("=", 1) for line in (root / "repository-packages.txt").read_text().splitlines())
if entries.keys() != declared.keys():
    raise SystemExit("错误: APK 索引没有覆盖完整组件")
identities = {}
for name, fields in entries.items():
    hashes = fields.get("hashes", "")
    package = root / (name + "-" + declared[name] + ".apk")
    if (fields.get("version") != declared[name] or not re.fullmatch(r"[0-9a-fA-F]{40,}", hashes)
            or len(hashes) % 2 or fields.get("file-size") != str(package.stat().st_size)):
        raise SystemExit("错误: APK 索引版本、文件大小或身份摘要无效: " + name)
    identities[name] = "Q1" + base64.b64encode(bytes.fromhex(hashes[:40])).decode()
for pin in constraints:
    if "@custom" in pin:
        name, identity = pin.split("@custom><", 1)
        if identities.get(name) != identity:
            raise SystemExit("错误: APK 安装身份与签名索引不符: " + name)
PY
    printf '@custom file:///usr/share/custom-apk/%s/%s\n' "${kind}" "${index_name}" >> "${temporary_dir}/custom-components.list"
    cat "${component_dir}/install-constraints.txt" >> "${temporary_dir}/constraints.txt"
    if [ "${mode}" = stage ]; then
        mkdir -p "${temporary_dir}/embedded/${kind}"
        install -m 0644 "${package_files[@]}" "${component_dir}/${index_name}" "${temporary_dir}/embedded/${kind}/"
    else
        python3 - "${component_dir}" "${target_dir}/usr/share/custom-apk/${kind}" "${index_name}" <<'PY'
import pathlib, sys
source, embedded = map(pathlib.Path, sys.argv[1:3])
expected = {p.name for p in source.glob("*.apk")} | {sys.argv[3]}
if embedded.is_symlink() or not embedded.is_dir() or {p.name for p in embedded.iterdir()} != expected:
    raise SystemExit("错误: 最终 rootfs 内置组件源文件缺失或不匹配: " + str(embedded))
for name in sorted(expected):
    path = embedded / name
    if path.is_symlink() or not path.is_file() or path.read_bytes() != (source / name).read_bytes():
        raise SystemExit("错误: 最终 rootfs 内置组件源文件与构建产物不一致: " + name)
PY
    fi
done

if [ "${mode}" = stage ]; then
    mkdir -p "${target_dir}/etc/apk/repositories.d" "${target_dir}/etc/apk/keys" "${target_dir}/usr/share/custom-apk"
    install -m 0644 "${temporary_dir}/custom-components.list" "${target_dir}/etc/apk/repositories.d/custom-components.list"
    for i in 0 1 2; do
        rm -rf "${target_dir}/usr/share/custom-apk/${kinds[$i]}"
        cp -a "${temporary_dir}/embedded/${kinds[$i]}" "${target_dir}/usr/share/custom-apk/"
        install -m 0644 "${component_dirs[$i]}/${key_names[$i]}" "${target_dir}/etc/apk/keys/${key_names[$i]}"
    done
    echo '✓ 已验证并内置组件 APK、签名索引与公钥，生成本地 @custom 软件源。'
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
# 宿主机 apk 的 file:// 路径不随 --root 改变。只改副本的内置源地址，
# 官方源及其他配置仍由 APK 按实际 rootfs 的默认规则读取。
python3 - "${temporary_dir}/root" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1]).resolve()
config = root / "etc/apk/repositories.d/custom-components.list"
config.write_text("".join(
    "@custom " + (root / "usr/share/custom-apk" / kind / (kind + "-packages.adb")).as_uri() + "\n"
    for kind in ("helloworld", "fullcone-runtime", "fullcone-luci")
))
PY
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
