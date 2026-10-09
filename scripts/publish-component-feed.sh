#!/usr/bin/env bash
set -euo pipefail

# 先上传全部资产到草稿，最后公开；任何失败都不能发布不完整的软件源。
die() { printf '错误: %s\n' "$*" >&2; exit 1; }
[ "$#" -ge 3 ] || die "用法: $0 <release-tag> <title> <component-dir>..."
release_tag="$1"
release_title="$2"
shift 2
repository="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
[[ "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "必须设置有效的 GITHUB_REPOSITORY 或 GH_REPO"
[[ "${release_tag}" =~ ^custom-(helloworld|fullcone)-[A-Za-z0-9_.-]+$ ]] || die "组件快照 tag 无效"
[ -n "${release_title}" ] || die "Release 标题不能为空"
[ -n "${GH_TOKEN:-}" ] || die "必须设置 GH_TOKEN"
[[ "${GITHUB_SHA:-}" =~ ^[0-9a-fA-F]{40}$ ]] || die "必须设置完整的 GITHUB_SHA"
for tool in gh python3 sha256sum; do
    command -v "${tool}" >/dev/null 2>&1 || die "缺少工具: ${tool}"
done
temporary_dir="$(mktemp -d)"
trap 'rm -rf "${temporary_dir}"' EXIT
assets=()
declare -A asset_names=()
component_number=0
for component_dir in "$@"; do
    [ -d "${component_dir}" ] || die "组件目录不存在: ${component_dir}"
    component_dir="$(cd "${component_dir}" && pwd)"
    [ -s "${component_dir}/SHA256SUMS" ] && [ -s "${component_dir}/runtime-repository.url" ] || die "组件尚未准备软件源"
    # 只允许公开运行时必需的 APK、签名索引与公钥，不上传私钥及其他 SDK 文件。
    python3 - "${component_dir}" "${repository}" "${release_tag}" > "${temporary_dir}/package-map.tsv" <<'PY'
import pathlib, re, sys
root, repo, tag = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
def fail(message):
    raise SystemExit("错误: " + message)
url = (root / "runtime-repository.url").read_text().strip()
prefix = "https://github.com/" + repo + "/releases/download/" + tag + "/"
if not url.startswith(prefix):
    fail("组件软件源 URL 与目标 Release 不一致")
index = url[len(prefix):]
if not re.fullmatch(r"(?:helloworld|fullcone-runtime|fullcone-luci)-packages\.adb", index) or not (root / index).is_file():
    fail("组件缺少 URL 对应的 APK 索引")
allowed = {p.name for pattern in ("*.apk", "*-packages.adb", "*-public-key.pem") for p in root.glob(pattern)}
allowed |= {"BUILD-INFO.txt", "repository-packages.txt", "install-packages.txt", "install-constraints.txt", "kernel-dependency.txt", "runtime-repository.url"}
seen = set()
for line in (root / "SHA256SUMS").read_text().splitlines():
    match = re.fullmatch(r"[0-9a-fA-F]{64} [ *](\S+)", line)
    if not match:
        fail("SHA256SUMS 格式无效")
    name = match[1].removeprefix("./")
    if "/" in name or name not in allowed or name in seen:
        fail("SHA256SUMS 包含非法或重复路径")
    seen.add(name)
required = {p.name for pattern in ("*.apk", "*-packages.adb", "*-public-key.pem") for p in root.glob(pattern)}
required.add("repository-packages.txt")
if not required <= seen or index not in required:
    fail("SHA256SUMS 未覆盖全部发布资产")
for name in required:
    path = root / name
    if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
        fail("发布资产为空、无效或为符号链接")
    if name.endswith("-public-key.pem"):
        content = path.read_text()
        if "PRIVATE KEY" in content or not content.startswith("-----BEGIN PUBLIC KEY-----\n"):
            fail("发布公钥不是有效的公钥 PEM")
packages = {p.name for p in root.glob("*.apk")}
declared = {}
for line in (root / "repository-packages.txt").read_text().splitlines():
    match = re.fullmatch(r"([A-Za-z0-9][A-Za-z0-9_.-]*)=(\S+)", line)
    if not match or match[1] in declared:
        fail("repository-packages.txt 包含非法或重复条目，发布包名必须适合 GitHub 资产文件名")
    declared[match[1]] = match[1] + "-" + match[2] + ".apk"
if set(declared.values()) != packages:
    fail("APK 与 repository-packages.txt 不是一一对应")
for name, filename in declared.items():
    print(filename, name + ".apk", sep="\t")
PY
    (cd "${component_dir}" && sha256sum --check --strict SHA256SUMS) || die "发布前组件 SHA-256 校验失败"
    # 别名副本不修改 APK 内容和内部版本；索引的 pkgname-spec 同步使用包名.apk。
    component_number=$((component_number + 1))
    upload_dir="${temporary_dir}/component-${component_number}"
    mkdir -p "${upload_dir}"
    while IFS=$'\t' read -r source_name published_name; do
        cp "${component_dir}/${source_name}" "${upload_dir}/${published_name}"
    done < "${temporary_dir}/package-map.tsv"
    shopt -s nullglob
    component_assets=("${upload_dir}"/*.apk "${component_dir}"/*-packages.adb "${component_dir}"/*-public-key.pem)
    shopt -u nullglob
    apk_count=0
    index_count=0
    key_count=0
    for asset in "${component_assets[@]}"; do
        asset_name="${asset##*/}"
        [ -z "${asset_names[${asset_name}]+set}" ] || die "多个组件存在重名发布资产: ${asset_name}"
        asset_names["${asset_name}"]=1
        case "${asset_name}" in
            *.apk) apk_count=$((apk_count + 1)) ;;
            *-packages.adb) index_count=$((index_count + 1)) ;;
            *-public-key.pem) key_count=$((key_count + 1)) ;;
        esac
        assets+=("${asset}")
    done
    [ "${apk_count}" -gt 0 ] && [ "${index_count}" -eq 1 ] && [ "${key_count}" -eq 1 ] || die "每个组件必须有 APK、一个签名索引及一个公钥"
done

# gh 的认证、网络、权限错误不得当作不存在。只有 API 明确返回 HTTP 404 才继续。
api_must_be_absent() {
    local endpoint="$1"
    if gh api "${endpoint}" > "${temporary_dir}/api-response" 2> "${temporary_dir}/api-error"; then
        die "Release 或 Git tag 已存在，拒绝覆盖: ${release_tag}"
    fi
    if ! grep -Eq '\(HTTP 404\)([[:space:]]|$)' "${temporary_dir}/api-error"; then
        cat "${temporary_dir}/api-error" >&2
        die "无法确认 Release 或 Git tag 不存在"
    fi
}
visibility="$(gh repo view "${repository}" --json visibility --jq .visibility)" || die "无法查询目标仓库可见性"
[ "${visibility}" = PUBLIC ] || die "运行时软件源必须发布到公开仓库"
api_must_be_absent "repos/${repository}/releases/tags/${release_tag}"
api_must_be_absent "repos/${repository}/git/ref/tags/${release_tag}"
cat > "${temporary_dir}/release-notes.md" <<EOF
此 Release 保存 OpenWrt 自定义组件的 APK、签名索引和签名公钥，供已安装固件持续更新软件包。

快照标签：${release_tag}
构建提交：${GITHUB_SHA}

请长期保留此快照及全部资产；已有固件通过固定地址引用它，不应覆盖或删除。
EOF
gh release create "${release_tag}" --repo "${repository}" --title "${release_title}" \
    --notes-file "${temporary_dir}/release-notes.md" --target "${GITHUB_SHA}" --draft --latest=false || die "创建组件 Release 草稿失败"
gh release upload "${release_tag}" "${assets[@]}" --repo "${repository}" || die "资产上传失败；Release 保持草稿，未公开残缺软件源"
# 二次检查服务端资产，完整上传后才公开草稿。
gh release view "${release_tag}" --repo "${repository}" --json isDraft,assets \
    > "${temporary_dir}/release.json" || die "无法验证草稿 Release 的资产"
python3 - "${temporary_dir}/release.json" "${assets[@]}" <<'PY'
import json, pathlib, sys
release = json.loads(pathlib.Path(sys.argv[1]).read_text())
expected = {pathlib.Path(p).name: pathlib.Path(p).stat().st_size for p in sys.argv[2:]}
assets = release.get("assets", [])
actual = {p["name"]: p["size"] for p in assets}
errors = []
if not release.get("isDraft"):
    errors.append("Release 已非草稿")
if len(actual) != len(assets):
    errors.append("存在重名资产")
if expected.keys() - actual.keys():
    errors.append("缺少资产: " + ", ".join(sorted(expected.keys() - actual.keys())))
if actual.keys() - expected.keys():
    errors.append("非预期资产: " + ", ".join(sorted(actual.keys() - expected.keys())))
for name in sorted(expected.keys() & actual.keys()):
    if actual[name] != expected[name]:
        errors.append(f"资产大小不符: {name} (期望 {expected[name]}，实际 {actual[name]})")
if errors:
    for error in errors:
        print("错误: " + error, file=sys.stderr)
    raise SystemExit("错误: 草稿 Release 资产缺失、重复或大小不符，拒绝公开")
PY
gh release edit "${release_tag}" --repo "${repository}" --draft=false --latest=false || die "公开组件 Release 失败"
printf '已发布长期组件软件源: https://github.com/%s/releases/tag/%s\n' "${repository}" "${release_tag}"
