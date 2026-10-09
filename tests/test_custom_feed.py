"""长期 custom APK 源回归；只在临时目录运行，GitHub 发布使用本地 gh 替身。

运行：python3 -m unittest discover -s tests -v
可通过 CUSTOM_FEED_APK 指定 OpenWrt SDK/ImageBuilder 的 apk-tools 3 路径。
"""

import base64
import contextlib
import functools
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
PREPARE = ROOT / "scripts/prepare-component-feed.sh"
PUBLISH = ROOT / "scripts/publish-component-feed.sh"
RUNTIME = ROOT / "scripts/runtime-custom-feed.sh"
CONFIGURE = ROOT / "scripts/configure-imagebuilder-apk.py"
KEY_NAMES = {
    "helloworld": "helloworld-public-key.pem",
    "fullcone-runtime": "fullcone-public-key.pem",
    "fullcone-luci": "luci-fullcone-public-key.pem",
}
RELEASE_TAG = "custom-helloworld-25.12.5-x86_64-12345-1"
FULLCONE_TAG = "custom-fullcone-25.12.5-x86_64-12345-1"
RELEASE_URL = "https://github.com/example/router/releases/download/" + RELEASE_TAG


def release_url(kind):
    tag = RELEASE_TAG if kind == "helloworld" else FULLCONE_TAG
    return "https://github.com/example/router/releases/download/" + tag


def run(*args, cwd=None, env=None):
    return subprocess.run(
        [str(arg) for arg in args], cwd=cwd, env=env,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        timeout=60,
    )


def checked(*args, **kwargs):
    result = run(*args, **kwargs)
    if result.returncode:
        raise AssertionError(f"命令失败 ({result.returncode}): {args}\n{result.stdout}")
    return result.stdout


def find_apk():
    requested = os.environ.get("CUSTOM_FEED_APK")
    if requested:
        candidate = Path(requested).expanduser().resolve()
        if not candidate.is_file():
            raise unittest.SkipTest(f"CUSTOM_FEED_APK 不存在: {candidate}")
        candidates = [candidate]
    else:
        candidates = sorted((ROOT / ".work").glob("**/staging_dir/host/bin/apk"),
                            key=lambda path: ("openwrt-imagebuilder-" not in str(path), str(path)))
        if shutil.which("apk"):
            candidates.append(Path(shutil.which("apk")))
    for candidate in candidates:
        result = run(candidate, "--version")
        if result.returncode == 0 and re.search(r"apk-tools 3\.", result.stdout):
            return candidate.resolve()
    raise unittest.SkipTest("缺少 apk-tools 3；请先准备 OpenWrt SDK/ImageBuilder 或设置 CUSTOM_FEED_APK")


def write_checksums(directory):
    files = sorted(p for p in directory.iterdir() if p.is_file() and p.name != "SHA256SUMS")
    (directory / "SHA256SUMS").write_text("".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in files
    ))


def index_identity(apk, index, name):
    """APK 的身份来自索引条目；包文件本体 SHA-256 与 info.hashes 不能替代它。"""
    dump = checked(apk, "adbdump", index)
    entries = re.split(r"(?m)^  - name: ", dump)[1:]
    for entry in entries:
        if entry.splitlines()[0] == name:
            hashes = re.search(r"(?m)^    hashes: ([0-9a-f]+)$", entry)
            if hashes:
                return "Q1" + base64.b64encode(bytes.fromhex(hashes[1])[:20]).decode()
    raise AssertionError(f"签名索引中找不到 {name} 的 APK identity")


@contextlib.contextmanager
def serve_release_assets(directory):
    """真实下载仅开放模拟 Release 资产，记录 APK 实际请求的文件名。"""
    requests = []

    class Handler(http.server.SimpleHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            super().do_GET()

        def log_message(self, format, *args):
            pass

    server = http.server.ThreadingHTTPServer(
        ("127.0.0.1", 0), functools.partial(Handler, directory=str(directory))
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


class SignedFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.apk = find_apk()
        if not shutil.which("openssl"):
            raise unittest.SkipTest("缺少 openssl，无法生成真实签名 APK fixture")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="custom-feed-regression-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.sdk = self.work / "sdk"
        (self.sdk / "staging_dir/host/bin").mkdir(parents=True)
        # ImageBuilder 的 apk 是依赖自身路径寻找 lib 的启动脚本，不能直接搬移符号链接。
        sdk_apk = self.sdk / "staging_dir/host/bin/apk"
        sdk_apk.write_text("#!/bin/sh\nexec " + shlex.quote(str(self.apk)) + ' "$@"\n')
        sdk_apk.chmod(0o755)
        self.make_key(self.sdk)
        self.trusted_keys = self.work / "trusted-keys"
        self.trusted_keys.mkdir()
        shutil.copyfile(self.sdk / "public-key.pem", self.trusted_keys / "fixture.pem")
        self.env = os.environ.copy()
        self.env["OPENWRT_VERSION"] = "25.12.5"

    def make_key(self, directory):
        directory.mkdir(parents=True, exist_ok=True)
        checked("openssl", "genpkey", "-algorithm", "EC", "-pkeyopt",
                "ec_paramgen_curve:prime256v1", "-out", directory / "private-key.pem")
        checked("openssl", "pkey", "-in", directory / "private-key.pem", "-pubout",
                "-out", directory / "public-key.pem")

    def make_package(self, directory, name="custom-feed-smoke", contents="custom\n", key=None,
                     signed=True, compression=None, version="1.0-r1"):
        directory.mkdir(parents=True, exist_ok=True)
        payload = self.work / f"payload-{len(list(self.work.glob('payload-*')))}"
        (payload / "usr/share").mkdir(parents=True)
        (payload / "usr/share" / name).write_text(contents)
        package = directory / f"{name}-{version}.apk"
        args = [self.apk, "mkpkg"]
        if signed:
            args.extend(("--sign-key", key or self.sdk / "private-key.pem"))
        if compression:
            args.extend(("--compression", compression))
        checked(*args, "--info", f"name:{name}", "--info", f"version:{version}",
                "--info", "arch:x86_64", "--files", payload, "--output", package)
        return package

    def make_component(self, kind="helloworld", name="custom-feed-smoke", geodata=False,
                       signed=True, version="1.0-r1"):
        directory = self.work / kind
        self.make_package(directory, name=name, signed=signed, version=version)
        shutil.copyfile(self.sdk / "public-key.pem", directory / KEY_NAMES[kind])
        (directory / "BUILD-INFO.txt").write_text(
            "OpenWrt version: 25.12.5\nArchitecture: x86_64\nComponent interface: 2\n"
        )
        (directory / "repository-packages.txt").write_text(f"{name}={version}\n")
        (directory / "install-packages.txt").write_text(name + "\n" + ("v2ray-geodata\n" if geodata else ""))
        (directory / "install-constraints.txt").write_text(name + "@custom\n" + ("v2ray-geodata\n" if geodata else ""))
        if kind == "fullcone-runtime":
            (directory / "kernel-dependency.txt").write_text("kernel=6.12.85~abcdef123456-r1\n")
        write_checksums(directory)
        return directory

    def prepare(self, directory, kind="helloworld", success=True):
        self.assertTrue(PREPARE.is_file(), f"缺少脚本: {PREPARE}")
        result = run("bash", PREPARE, kind, directory, self.sdk, release_url(kind), env=self.env)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, "无效组件被接受\n" + result.stdout)
            self.assertFalse((directory / f"{kind}-packages.adb").exists())
        return result

    def signed_index(self, directory, name="packages.adb"):
        index = directory / name
        checked(self.apk, "--keys-dir", self.trusted_keys, "mkndx", "--sign-key", self.sdk / "private-key.pem",
                "--output", index, *sorted(directory.glob("*.apk")))
        return index

    def release_assets(self, directory):
        """ImageBuilder 保留原 APK 文件名，公网副本必须与索引 name-only 模板一致。"""
        published = Path(tempfile.mkdtemp(prefix="published-", dir=self.work))
        for line in (directory / "repository-packages.txt").read_text().splitlines():
            name, version = line.split("=", 1)
            shutil.copyfile(directory / f"{name}-{version}.apk", published / f"{name}.apk")
        for pattern in ("*-packages.adb", "*-public-key.pem"):
            for path in directory.glob(pattern):
                shutil.copyfile(path, published / path.name)
        return published


class PrepareComponentFeedTests(SignedFixture):
    def test_unsigned_sdk_packages_are_signed_before_indexing_for_each_component(self):
        for kind in KEY_NAMES:
            with self.subTest(kind=kind):
                name = kind + "-unsigned-smoke"
                directory = self.make_component(kind, name, signed=False)
                package = directory / f"{name}-1.0-r1.apk"
                original_bytes = package.read_bytes()
                original_checksums = self.work / f"{kind}-original-SHA256SUMS"
                original_checksums.write_bytes((directory / "SHA256SUMS").read_bytes())
                unsigned_verification = run(self.apk, "--keys-dir", self.trusted_keys,
                                            "verify", package)
                self.assertNotEqual(unsigned_verification.returncode, 0)
                self.assertIn("UNTRUSTED signature", unsigned_verification.stdout)
                # SDK 的无签名产物仍必须通过 payload 完整性校验。
                checked(self.apk, "--allow-untrusted", "verify", package)
                unsigned_index = self.work / f"{kind}-unsigned-index.adb"
                checked(self.apk, "--allow-untrusted", "mkndx", "--sign-key",
                        self.sdk / "private-key.pem", "--output", unsigned_index, package)
                original_identity = index_identity(self.apk, unsigned_index, name)

                self.prepare(directory, kind)

                checked(self.apk, "--keys-dir", self.trusted_keys, "verify", package)
                index = directory / f"{kind}-packages.adb"
                checked(self.apk, "--keys-dir", self.trusted_keys, "verify", index)
                self.assertNotEqual(package.read_bytes(), original_bytes)
                self.assertNotEqual(hashlib.sha256(package.read_bytes()).digest(),
                                    hashlib.sha256(original_bytes).digest())
                # 加签改变 APK 文件和 file-size，但保留 ADB 内容的安装身份。
                identity = index_identity(self.apk, index, name)
                self.assertEqual(identity, original_identity)
                pin = f"{name}@custom><{identity}"
                self.assertEqual((directory / "install-constraints.txt").read_text().strip(), pin)
                stale = run("sha256sum", "--check", "--strict", original_checksums,
                            cwd=directory)
                self.assertNotEqual(stale.returncode, 0)
                self.assertIn(f"{name}-1.0-r1.apk: FAILED", stale.stdout)
                checked("sha256sum", "--check", "--strict", "SHA256SUMS", cwd=directory)

                published = self.release_assets(directory)
                repositories = self.work / f"{kind}-install-repositories"
                repositories.write_text("@custom " + (published / index.name).as_uri() + "\n")
                install_root = self.work / f"{kind}-install-root"
                install_root.mkdir()
                checked(self.apk, "--root", install_root, "--arch", "x86_64",
                        "--keys-dir", self.trusted_keys, "--repositories-file", repositories,
                        "--no-network", "add", "--usermode", "--initdb", pin)
                self.assertEqual((install_root / "usr/share" / name).read_text(), "custom\n")
                self.assertEqual((install_root / "etc/apk/world").read_text().strip(), pin)

    def test_preparing_previously_unsigned_package_again_preserves_signed_apk_and_identity(self):
        directory = self.make_component(signed=False)
        self.prepare(directory)
        package = directory / "custom-feed-smoke-1.0-r1.apk"
        signed_bytes = package.read_bytes()
        first_constraints = (directory / "install-constraints.txt").read_bytes()
        self.prepare(directory)
        self.assertEqual(package.read_bytes(), signed_bytes)
        self.assertEqual((directory / "install-constraints.txt").read_bytes(), first_constraints)
        checked(self.apk, "--keys-dir", self.trusted_keys, "verify", package)
        checked("sha256sum", "--check", "--strict", "SHA256SUMS", cwd=directory)

    def test_rejects_adbsign_success_without_signature_atomically(self):
        directory = self.make_component(signed=False)
        package = directory / "custom-feed-smoke-1.0-r1.apk"
        original_package = package.read_bytes()
        original_checksums = (directory / "SHA256SUMS").read_bytes()
        # apk-tools 3.0.5 adbsign 在报错时仍可能返回 0；验证不能只看退出码。
        wrapper = self.sdk / "staging_dir/host/bin/apk"
        wrapper.write_text(
            "#!/usr/bin/env python3\nimport subprocess, sys\n"
            "if 'adbsign' in sys.argv[1:]:\n"
            "    print('fixture adbsign failed but returned success', file=sys.stderr)\n"
            "    sys.exit(0)\n"
            "sys.exit(subprocess.call([" + repr(str(self.apk)) + "] + sys.argv[1:]))\n"
        )
        result = self.prepare(directory, success=False)
        self.assertIn("APK 签名或完整性校验失败", result.stdout)
        self.assertEqual(package.read_bytes(), original_package)
        self.assertEqual((directory / "SHA256SUMS").read_bytes(), original_checksums)
        self.assertFalse((directory / "helloworld-packages.adb").exists())
        self.assertFalse((directory / "runtime-repository.url").exists())

    def test_rejects_corrupt_unsigned_payload_even_with_matching_original_checksum(self):
        directory = self.make_component(signed=False)
        package = self.make_package(directory, contents="UNIQUE_UNSIGNED_PAYLOAD\n",
                                    signed=False, compression="none")
        original = package.read_bytes()
        self.assertEqual(original.count(b"UNIQUE_UNSIGNED_PAYLOAD"), 1)
        corrupted = original.replace(b"UNIQUE_UNSIGNED_PAYLOAD", b"BROKEN_UNSIGNED_PAYLOAD")
        package.write_bytes(corrupted)
        write_checksums(directory)
        verification = run(self.apk, "--allow-untrusted", "verify", package)
        self.assertNotEqual(verification.returncode, 0)
        self.assertIn("file integrity error", verification.stdout)
        self.prepare(directory, success=False)
        self.assertEqual(package.read_bytes(), corrupted)

    def test_each_component_produces_signed_index_and_complete_checksums(self):
        for kind in KEY_NAMES:
            with self.subTest(kind=kind):
                name = "luci-i18n-firewall-zh-cn" if kind == "fullcone-luci" else kind + "-smoke"
                directory = self.make_component(kind, name, geodata=kind == "helloworld")
                package = directory / f"{name}-1.0-r1.apk"
                original_signed_bytes = package.read_bytes()
                self.prepare(directory, kind)
                self.assertEqual(package.read_bytes(), original_signed_bytes)
                index = directory / f"{kind}-packages.adb"
                keys = self.work / f"keys-{kind}"
                keys.mkdir()
                shutil.copyfile(self.sdk / "public-key.pem", keys / "fixture.pem")
                checked(self.apk, "--keys-dir", keys, "verify", index)
                self.assertIn("pkgname-spec: ${name}.apk", checked(self.apk, "adbdump", index))
                self.assertEqual((directory / "runtime-repository.url").read_text().strip(),
                                 f"{release_url(kind)}/{kind}-packages.adb")
                constraints = (directory / "install-constraints.txt").read_text().splitlines()
                identity = index_identity(self.apk, index, name)
                self.assertIn(f"{name}@custom><{identity}", constraints)
                self.assertNotEqual(identity, "Q1" + base64.b64encode(
                    hashlib.sha256((directory / f"{name}-1.0-r1.apk").read_bytes()).digest()[:20]
                ).decode())
                if kind == "helloworld":
                    self.assertIn("v2ray-geodata", constraints)
                covered = {line.split(maxsplit=1)[1].lstrip("*").removeprefix("./")
                           for line in (directory / "SHA256SUMS").read_text().splitlines()}
                self.assertEqual(covered, {p.name for p in directory.iterdir()
                                           if p.is_file() and p.name != "SHA256SUMS"})
                checked("sha256sum", "--check", "--strict", "SHA256SUMS", cwd=directory)

    def test_rejects_tampered_original_checksum(self):
        directory = self.make_component()
        with (directory / "custom-feed-smoke-1.0-r1.apk").open("ab") as output:
            output.write(b"tampered")
        self.prepare(directory, success=False)

    def test_rejects_component_public_key_mismatch(self):
        directory = self.make_component()
        other = self.work / "other-key"
        self.make_key(other)
        shutil.copyfile(other / "public-key.pem", directory / KEY_NAMES["helloworld"])
        write_checksums(directory)
        self.prepare(directory, success=False)

    def test_rejects_sdk_private_key_mismatch(self):
        directory = self.make_component()
        other = self.work / "other-key"
        self.make_key(other)
        shutil.copyfile(other / "private-key.pem", self.sdk / "private-key.pem")
        self.prepare(directory, success=False)

    def test_rejects_apk_signed_by_another_key(self):
        directory = self.make_component()
        other = self.work / "other-key"
        self.make_key(other)
        package = self.make_package(directory, key=other / "private-key.pem")
        foreign_signed_bytes = package.read_bytes()
        write_checksums(directory)
        self.prepare(directory, success=False)
        self.assertEqual(package.read_bytes(), foreign_signed_bytes)

    def test_rejects_filename_not_matching_package_metadata(self):
        directory = self.make_component()
        (directory / "custom-feed-smoke-1.0-r1.apk").rename(directory / "wrong-1.0-r1.apk")
        write_checksums(directory)
        self.prepare(directory, success=False)

    def test_rejects_package_name_github_would_rename(self):
        directory = self.make_component(name="unsafe+release-name")
        self.prepare(directory, success=False)

    def test_rejects_undeclared_apk(self):
        directory = self.make_component()
        self.make_package(directory, name="undeclared")
        write_checksums(directory)
        self.prepare(directory, success=False)

    def test_rejects_missing_declared_apk(self):
        directory = self.make_component()
        with (directory / "repository-packages.txt").open("a") as output:
            output.write("missing=1.0-r1\n")
        write_checksums(directory)
        self.prepare(directory, success=False)

    def test_rejects_wrong_architecture(self):
        directory = self.make_component()
        (directory / "BUILD-INFO.txt").write_text("OpenWrt version: 25.12.5\nArchitecture: aarch64\n")
        write_checksums(directory)
        self.prepare(directory, success=False)

    def test_rejects_wrong_release_version(self):
        directory = self.make_component()
        self.env["OPENWRT_VERSION"] = "25.12.4"
        self.prepare(directory, success=False)


class ApkWorldRegressionTests(SignedFixture):
    def setUp(self):
        super().setUp()
        self.custom = self.work / "custom"
        self.official = self.work / "official"
        self.make_package(self.custom, contents="custom build\n")
        self.make_package(self.official, contents="official build\n")
        self.make_package(self.official, name="coremark", contents="coremark\n")
        self.custom_index = self.signed_index(self.custom)
        self.official_index = self.signed_index(self.official)
        self.keys = self.work / "keys"
        self.keys.mkdir()
        shutil.copyfile(self.sdk / "public-key.pem", self.keys / "fixture.pem")
        self.repositories = self.work / "repositories"
        self.repositories.write_text(
            self.official_index.as_uri() + "\n@custom " + self.custom_index.as_uri() + "\n"
        )
        self.install_root = self.work / "install-root"
        self.install_root.mkdir()
        self.pin = "custom-feed-smoke@custom><" + index_identity(self.apk, self.custom_index, "custom-feed-smoke")
        result = self.apk_command("add", "--initdb", self.pin)
        self.assertEqual(result.returncode, 0, result.stdout)

    def apk_command(self, *args):
        if args and args[0] == "add":
            args = (args[0], "--usermode", *args[1:])
        return run(self.apk, "--root", self.install_root, "--arch", "x86_64",
                   "--keys-dir", self.keys, "--repositories-file", self.repositories,
                   "--no-network", *args)

    def test_later_official_add_and_upgrade_preserve_custom_identity(self):
        before = (self.install_root / "lib/apk/db/installed").read_bytes()
        world = (self.install_root / "etc/apk/world").read_text()
        self.assertEqual(world.strip(), self.pin)
        self.assertEqual((self.install_root / "usr/share/custom-feed-smoke").read_text(), "custom build\n")
        for command in (("add", "--simulate", "coremark"), ("upgrade", "--simulate")):
            with self.subTest(command=command):
                result = self.apk_command(*command)
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertNotRegex(result.stdout, r"(?i)(reinstalling|upgrading|downgrading|purging).*custom-feed-smoke")
        self.assertEqual((self.install_root / "lib/apk/db/installed").read_bytes(), before)
        installed = self.apk_command("add", "coremark")
        self.assertEqual(installed.returncode, 0, installed.stdout)
        upgraded = self.apk_command("upgrade")
        self.assertEqual(upgraded.returncode, 0, upgraded.stdout)
        self.assertEqual((self.install_root / "usr/share/custom-feed-smoke").read_text(), "custom build\n")
        self.assertEqual((self.install_root / "etc/apk/world").read_text().splitlines(),
                         ["coremark", self.pin])

    def test_missing_custom_tag_reproduces_original_world_failure(self):
        self.repositories.write_text(self.official_index.as_uri() + "\n")
        for command in (("add", "--simulate", "coremark"), ("upgrade", "--simulate")):
            with self.subTest(command=command):
                result = self.apk_command(*command)
                self.assertEqual(result.returncode, 99, result.stdout)
                self.assertIn("missing repository tag", result.stdout.lower())


class ImageBuilderConstraintTests(unittest.TestCase):
    def test_real_formatpackages_preserves_identity_and_official_constraints(self):
        if not shutil.which("make"):
            self.skipTest("缺少 GNU make，无法执行 ImageBuilder APK 约束兼容回归")
        candidates = sorted((ROOT / ".work").glob("**/openwrt-imagebuilder-*/Makefile"))
        source = next((p for p in candidates if "define FormatPackages\n" in p.read_text()), None)
        if source is None:
            self.skipTest("缺少已解压的 OpenWrt ImageBuilder Makefile")
        content = source.read_text()
        function = re.search(r"(?ms)^define FormatPackages\n.*?^endef$", content)
        self.assertIsNotNone(function)
        pin = "luci-base@custom><Q1AHP9WZ/llaH9pzjRb40Aa86OhaM="
        with tempfile.TemporaryDirectory(prefix="custom-feed-make-") as temporary:
            directory = Path(temporary)
            makefile = directory / "Makefile"
            makefile.write_text(
                "define GetABISuffix\n$(if $(filter ordinary,$(1)),-abi,)\nendef\n"
                + function[0] + "\n"
                + "PACKAGES := ordinary=2.0-r1 geodata " + pin + "\n"
                + "all:\n\t@" + sys.executable
                + " -c 'import json,sys; print(json.dumps(sys.argv[1:]))'"
                + " $(call FormatPackages,$(PACKAGES))\n"
            )
            checked(sys.executable, CONFIGURE, directory)
            output = checked("make", "--no-print-directory", "-f", makefile, cwd=directory)
            self.assertEqual(json.loads(output), ["ordinary-abi=2.0-r1", "geodata", pin])
            first = makefile.read_bytes()
            checked(sys.executable, CONFIGURE, directory)
            self.assertEqual(makefile.read_bytes(), first)

    def test_unknown_imagebuilder_format_fails_closed(self):
        with tempfile.TemporaryDirectory(prefix="custom-feed-make-") as temporary:
            directory = Path(temporary)
            makefile = directory / "Makefile"
            makefile.write_text("all:\n\t@true\n")
            result = run(sys.executable, CONFIGURE, directory)
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertEqual(makefile.read_text(), "all:\n\t@true\n")


CURL_MOCK = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["CURL_MOCK_LOG"]).open("a") as log:
    log.write(json.dumps(args) + "\\n")
mapping = json.loads(Path(os.environ["FEED_TRANSPORT_MAP"]).read_text())
url = next((arg for arg in args if arg.startswith("https://")), "")
if url not in mapping:
    print("fixture URL unavailable", file=sys.stderr)
    sys.exit(22)
data = Path(mapping[url]).read_bytes()
if os.environ.get("CURL_MOCK_CORRUPT_INDEX") == "1":
    data += b"incorrect release asset"
output = next((args[i + 1] for i, arg in enumerate(args[:-1]) if arg in ("-o", "--output")), None)
if output:
    Path(output).write_bytes(data)
else:
    sys.stdout.buffer.write(data)
'''


APK_TRANSPORT = '''#!/usr/bin/env python3
import json, os, subprocess, sys, tempfile
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["APK_TRANSPORT_LOG"]).open("a") as log:
    log.write(json.dumps(args) + "\\n")
mapping = json.loads(Path(os.environ["FEED_TRANSPORT_MAP"]).read_text())
def localize(content):
    for url, path in mapping.items():
        content = content.replace(url, Path(path).as_uri())
    return content
with tempfile.TemporaryDirectory(prefix="custom-feed-apk-transport-") as temporary:
    if "--repositories-file" in args:
        i = args.index("--repositories-file") + 1
        config = Path(args[i])
        mapped = Path(temporary) / "repositories"
        mapped.write_text(localize(config.read_text()))
        args[i] = str(mapped)
    elif "--root" in args:
        root = Path(args[args.index("--root") + 1])
        files = [root / "etc/apk/repositories"] + sorted((root / "etc/apk/repositories.d").glob("*.list"))
        for config in files:
            if config.is_file():
                content = config.read_text()
                mapped = localize(content)
                if mapped != content:
                    config.write_text(mapped)
    args = [localize(arg) for arg in args]
    sys.exit(subprocess.call([os.environ["REAL_CUSTOM_FEED_APK"], "--no-network"] + args))
'''


class RuntimeCustomFeedTests(SignedFixture):
    def setUp(self):
        super().setUp()
        self.components = []
        self.names = []
        self.mapping = {}
        for kind in KEY_NAMES:
            name = "luci-i18n-firewall-zh-cn" if kind == "fullcone-luci" else kind + "-smoke"
            component = self.make_component(kind, name)
            self.prepare(component, kind)
            self.components.append(component)
            self.names.append(name)
            published = self.release_assets(component)
            self.mapping[(component / "runtime-repository.url").read_text().strip()] = str(published / f"{kind}-packages.adb")
        self.transport_map = self.work / "transport-map.json"
        self.transport_map.write_text(json.dumps(self.mapping))
        mock_bin = self.work / "transport-bin"
        mock_bin.mkdir()
        curl = mock_bin / "curl"
        curl.write_text(CURL_MOCK)
        curl.chmod(0o755)
        wrapper = self.sdk / "staging_dir/host/bin/apk"
        wrapper.unlink()
        wrapper.write_text(APK_TRANSPORT)
        wrapper.chmod(0o755)
        self.apk_log = self.work / "apk-transport.jsonl"
        self.curl_log = self.work / "curl-calls.jsonl"
        self.env.update({"PATH": str(mock_bin) + os.pathsep + os.environ["PATH"],
                         "FEED_TRANSPORT_MAP": str(self.transport_map),
                         "CURL_MOCK_LOG": str(self.curl_log),
                         "APK_TRANSPORT_LOG": str(self.apk_log),
                         "REAL_CUSTOM_FEED_APK": str(self.apk)})
        self.overlay = self.work / "overlay"
        self.overlay.mkdir()

    def runtime(self, mode, directory, success=True):
        result = run("bash", RUNTIME, mode, self.sdk, directory, "25.12.5",
                     *self.components, env=self.env)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def install_rootfs(self):
        rootfs = self.work / "rootfs"
        rootfs.mkdir()
        official = self.work / "official"
        self.make_package(official, name="coremark")
        for name in self.names:
            self.make_package(official, name=name, contents="official replacement\n")
        official_index = self.signed_index(official)
        setup_repos = self.work / "install-repositories"
        setup_repos.write_text(official_index.as_uri() + "\n" + "".join(
            "@custom " + Path(index).as_uri() + "\n" for index in self.mapping.values()
        ))
        constraints = [line for component in self.components
                       for line in (component / "install-constraints.txt").read_text().splitlines()]
        checked(self.apk, "--root", rootfs, "--arch", "x86_64", "--keys-dir", self.trusted_keys,
                "--repositories-file", setup_repos, "--no-network", "add", "--usermode", "--initdb", *constraints)
        shutil.copytree(self.overlay, rootfs, dirs_exist_ok=True)
        (rootfs / "etc/apk/repositories").write_text(official_index.as_uri() + "\n")
        return rootfs

    def test_stage_and_verify_real_world_without_mutating_rootfs(self):
        self.runtime("stage", self.overlay)
        config = self.overlay / "etc/apk/repositories.d/custom-components.list"
        self.assertEqual(config.read_text().splitlines(), ["@custom " + url for url in self.mapping])
        for component, kind in zip(self.components, KEY_NAMES):
            self.assertEqual((self.overlay / "etc/apk/keys" / KEY_NAMES[kind]).read_bytes(),
                             (component / KEY_NAMES[kind]).read_bytes())
        rootfs = self.install_rootfs()
        before = {str(p.relative_to(rootfs)): p.read_bytes() for p in rootfs.rglob("*") if p.is_file()}
        self.runtime("verify", rootfs)
        after = {str(p.relative_to(rootfs)): p.read_bytes() for p in rootfs.rglob("*") if p.is_file()}
        self.assertEqual(after, before)
        calls = [json.loads(line) for line in self.apk_log.read_text().splitlines()]
        self.assertTrue(any("update" in call for call in calls), calls)
        self.assertTrue(any("add" in call and "--simulate" in call and "coremark" in call for call in calls), calls)
        self.assertFalse(any("--allow-untrusted" in call for call in calls), calls)

    def test_stage_rejects_remote_index_different_from_component(self):
        self.env["CURL_MOCK_CORRUPT_INDEX"] = "1"
        result = self.runtime("stage", self.overlay, success=False)
        self.assertIn("索引与当前组件不一致", result.stdout)

    def test_stage_rejects_snapshot_of_another_release(self):
        component = self.components[0]
        url = (component / "runtime-repository.url").read_text()
        other_url = url.replace("25.12.5", "25.12.4")
        (component / "runtime-repository.url").write_text(other_url)
        self.mapping[other_url.strip()] = self.mapping[url.strip()]
        self.transport_map.write_text(json.dumps(self.mapping))
        write_checksums(component)
        result = self.runtime("stage", self.overlay, success=False)
        self.assertIn("同版本、同架构", result.stdout)

    def test_stage_rejects_missing_metadata_checksum_coverage(self):
        component = self.components[0]
        checksums = component / "SHA256SUMS"
        checksums.write_text("\n".join(line for line in checksums.read_text().splitlines()
                                      if not line.endswith("runtime-repository.url")) + "\n")
        result = self.runtime("stage", self.overlay, success=False)
        self.assertIn("SHA256SUMS 未覆盖", result.stdout)

    def test_verify_rejects_rootfs_without_custom_repository(self):
        self.runtime("stage", self.overlay)
        rootfs = self.install_rootfs()
        (rootfs / "etc/apk/repositories.d/custom-components.list").unlink()
        self.runtime("verify", rootfs, success=False)

    def test_verify_rejects_rootfs_public_key_mismatch(self):
        self.runtime("stage", self.overlay)
        rootfs = self.install_rootfs()
        other = self.work / "wrong-rootfs-key"
        self.make_key(other)
        shutil.copyfile(other / "public-key.pem", rootfs / "etc/apk/keys" / KEY_NAMES["helloworld"])
        result = self.runtime("verify", rootfs, success=False)
        self.assertIn("缺少正确的 helloworld-public-key.pem", result.stdout)

    def test_verify_rejects_world_with_incorrect_identity(self):
        self.runtime("stage", self.overlay)
        rootfs = self.install_rootfs()
        world = rootfs / "etc/apk/world"
        lines = world.read_text().splitlines()
        lines[0] = lines[0].split("><", 1)[0] + "><Q1AAAAAAAAAAAAAAAAAAAAAAAAAAA="
        world.write_text("\n".join(lines) + "\n")
        self.runtime("verify", rootfs, success=False)


GH_MOCK = '''#!/usr/bin/env python3
import json, os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
with Path(os.environ["GH_MOCK_LOG"]).open("a") as log:
    log.write(json.dumps(args) + "\\n")
if args[:2] == ["repo", "view"]:
    print("PRIVATE" if os.environ.get("GH_MOCK_PRIVATE_REPO") == "1" else "PUBLIC")
    sys.exit(0)
if args and args[0] == "api":
    if os.environ.get("GH_MOCK_API_FAILURE") == "1":
        print("gh: Bad credentials (HTTP 401)", file=sys.stderr)
        sys.exit(1)
    endpoint = next((a for a in args[1:] if a.startswith("repos/")), "")
    if "/git/ref" in endpoint or "/git/matching-refs" in endpoint:
        if os.environ.get("GH_MOCK_EXISTING_TAG") == "1":
            print(json.dumps({"ref": "refs/tags/component-fixture"}))
            sys.exit(0)
        print("gh: Not Found (HTTP 404)", file=sys.stderr)
        sys.exit(1)
    if "/releases/tags/" in endpoint:
        if os.environ.get("GH_MOCK_EXISTING_RELEASE") == "1":
            print(json.dumps({"id": 7, "draft": False}))
            sys.exit(0)
        print("gh: Not Found (HTTP 404)", file=sys.stderr)
        sys.exit(1)
    print(json.dumps({"private": False, "visibility": "public"}))
    sys.exit(0)
if args[:2] == ["release", "view"]:
    published = Path(os.environ["GH_MOCK_ASSET_DIR"])
    assets = [{"name": path.name, "size": path.stat().st_size}
              for path in sorted(published.iterdir()) if path.is_file()]
    if os.environ.get("GH_MOCK_MISSING_ASSET") == "1":
        assets = assets[:-1]
    if os.environ.get("GH_MOCK_WRONG_ASSET_SIZE") == "1":
        assets[0]["size"] += 1
    print(json.dumps({"isDraft": True, "assets": assets}))
    sys.exit(0)
if args[:2] == ["release", "upload"]:
    if os.environ.get("GH_MOCK_FAIL_UPLOAD") == "1":
        print("fixture upload failed", file=sys.stderr)
        sys.exit(1)
    published = Path(os.environ["GH_MOCK_ASSET_DIR"])
    for arg in args[3:]:
        path = Path(arg)
        if path.is_file():
            # GitHub Release 上传 API 会改名；~ 版本是此次真实 CI 的触发条件。
            name = path.name.replace("~", ".")
            if os.environ.get("GH_MOCK_RENAME_ASSET") == "1" and path.suffix == ".apk":
                name = "renamed-" + name
            target = published / name
            if target.exists():
                print("gh: already_exists (HTTP 422)", file=sys.stderr)
                sys.exit(1)
            shutil.copyfile(path, target)
if args[:2] == ["release", "create"]:
    print("https://github.com/example/router/releases/tag/component-fixture")
sys.exit(0)
'''


class PublishComponentFeedTests(SignedFixture):
    def setUp(self):
        super().setUp()
        self.component = self.make_component()
        self.prepare(self.component)
        mock_bin = self.work / "mock-bin"
        mock_bin.mkdir()
        gh = mock_bin / "gh"
        gh.write_text(GH_MOCK)
        gh.chmod(0o755)
        self.log = self.work / "gh-calls.jsonl"
        self.published = self.work / "release-assets"
        self.published.mkdir()
        self.publish_tag = RELEASE_TAG
        self.env.update({"PATH": str(mock_bin) + os.pathsep + os.environ["PATH"],
                         "GH_MOCK_LOG": str(self.log), "GH_MOCK_ASSET_DIR": str(self.published),
                         "GH_TOKEN": "fixture-token",
                         "GITHUB_REPOSITORY": "example/router", "GH_REPO": "example/router",
                         "GITHUB_SHA": "0123456789abcdef0123456789abcdef01234567"})

    def publish(self, *directories):
        self.assertTrue(PUBLISH.is_file(), f"缺少脚本: {PUBLISH}")
        return run("bash", PUBLISH, self.publish_tag, "回归 fixture", *(directories or (self.component,)), env=self.env)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_draft_upload_all_assets_then_publish_without_latest(self):
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout)
        calls = self.calls()
        creates = [i for i, call in enumerate(calls) if call[:2] == ["release", "create"]]
        uploads = [i for i, call in enumerate(calls) if call[:2] == ["release", "upload"]]
        edits = [i for i, call in enumerate(calls) if call[:2] == ["release", "edit"]]
        self.assertEqual(len(creates), 1, calls)
        self.assertTrue(uploads, calls)
        self.assertEqual(len(edits), 1, calls)
        self.assertLess(creates[0], min(uploads))
        self.assertLess(max(uploads), edits[0])
        self.assertIn("--draft", calls[creates[0]])
        self.assertIn("--draft=false", calls[edits[0]])
        self.assertIn("--latest=false", calls[edits[0]])
        assets = [Path(arg).name for i in uploads for arg in calls[i]
                  if arg.endswith((".apk", "-packages.adb", "-public-key.pem"))]
        expected = {"custom-feed-smoke.apk", "helloworld-packages.adb", "helloworld-public-key.pem"}
        self.assertEqual(set(assets), expected)
        self.assertEqual(len(assets), len(expected))
        self.assertNotIn("--clobber", [arg for call in calls for arg in call])
        self.assertFalse(any("private-key" in arg for call in calls for arg in call))

    def test_tilde_version_release_downloads_name_only_apk_without_changing_identity(self):
        # 与真实 LuCI/FullCone 日期版本一致，GitHub API 会改名 canonical 文件中的 ~。
        version = "2026.10.09~abcdef123-r1"
        name = "custom-feed-smoke"
        shutil.rmtree(self.component)
        self.component = self.make_component(version=version)
        canonical = self.component / f"{name}-{version}.apk"
        original_package = canonical.read_bytes()
        original_index = self.work / "original-index.adb"
        checked(self.apk, "--keys-dir", self.trusted_keys, "mkndx", "--sign-key",
                self.sdk / "private-key.pem", "--output", original_index, canonical)
        original_identity = index_identity(self.apk, original_index, name)

        prepared = self.prepare(self.component)
        self.assertNotIn("not matching package name specification", prepared.stdout)
        result = self.publish()
        self.assertEqual(result.returncode, 0, result.stdout)
        uploaded = self.published / f"{name}.apk"
        self.assertEqual(uploaded.read_bytes(), original_package)
        self.assertEqual(canonical.read_bytes(), original_package)
        self.assertFalse((self.component / f"{name}.apk").exists())
        self.assertFalse((self.published / canonical.name).exists())
        self.assertFalse((self.published / canonical.name.replace("~", ".")).exists())
        self.assertEqual(index_identity(self.apk, self.published / "helloworld-packages.adb", name),
                         original_identity)
        dump = checked(self.apk, "adbdump", self.published / "helloworld-packages.adb")
        self.assertIn(f"    version: {version}\n", dump)
        self.assertIn("pkgname-spec: ${name}.apk\n", dump)
        checked(self.apk, "--keys-dir", self.trusted_keys, "verify", uploaded,
                self.published / "helloworld-packages.adb")
        checked("sha256sum", "--check", "--strict", "SHA256SUMS", cwd=self.component)

        install_root = self.work / "http-install-root"
        install_root.mkdir()
        repositories = self.work / "http-repositories"
        pin = f"{name}@custom><{original_identity}"
        with serve_release_assets(self.published) as (base_url, requests):
            repositories.write_text(f"@custom {base_url}/helloworld-packages.adb\n")
            checked(self.apk, "--root", install_root, "--arch", "x86_64", "--keys-dir",
                    self.trusted_keys, "--repositories-file", repositories, "--no-cache",
                    "add", "--usermode", "--initdb", pin)
        self.assertIn("/helloworld-packages.adb", requests)
        self.assertIn(f"/{name}.apk", requests)
        self.assertFalse(any("~" in path or version in path for path in requests), requests)
        self.assertEqual((install_root / "usr/share" / name).read_text(), "custom\n")
        self.assertEqual((install_root / "etc/apk/world").read_text().strip(), pin)
        self.assertRegex((install_root / "lib/apk/db/installed").read_text(),
                         r"(?m)^V:" + re.escape(version) + r"$")

    def test_mock_reproduces_github_tilde_filename_renaming(self):
        asset = self.work / "legacy-1.0~abcdef.apk"
        asset.write_bytes(b"fixture release asset")
        checked("gh", "release", "upload", RELEASE_TAG, asset, "--repo", "example/router",
                env=self.env)
        view = json.loads(checked("gh", "release", "view", RELEASE_TAG, "--json", "assets",
                                  env=self.env))
        self.assertEqual(view["assets"], [{"name": "legacy-1.0.abcdef.apk", "size": asset.stat().st_size}])

    def test_server_side_asset_rename_keeps_release_unpublished(self):
        self.env["GH_MOCK_RENAME_ASSET"] = "1"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(any(call[:2] == ["release", "upload"] for call in self.calls()))
        self.assertFalse(any(call[:2] == ["release", "edit"] for call in self.calls()))
        self.assertIn("custom-feed-smoke.apk", result.stdout)
        self.assertIn("renamed-custom-feed-smoke.apk", result.stdout)

    def test_existing_tag_is_rejected_before_release_creation(self):
        self.env["GH_MOCK_EXISTING_TAG"] = "1"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any(call[:2] == ["release", "create"] for call in self.calls()))

    def test_fullcone_runtime_and_luci_publish_in_one_complete_release(self):
        self.publish_tag = FULLCONE_TAG
        components = []
        expected = set()
        for kind in ("fullcone-runtime", "fullcone-luci"):
            component = self.make_component(kind, name=kind + "-smoke")
            self.prepare(component, kind)
            components.append(component)
            expected.update({kind + "-smoke.apk", kind + "-packages.adb", KEY_NAMES[kind]})
        result = self.publish(*components)
        self.assertEqual(result.returncode, 0, result.stdout)
        calls = self.calls()
        self.assertEqual(sum(call[:2] == ["release", "create"] for call in calls), 1)
        self.assertEqual(sum(call[:2] == ["release", "edit"] for call in calls), 1)
        assets = {Path(arg).name for call in calls if call[:2] == ["release", "upload"]
                  for arg in call if arg.endswith((".apk", "-packages.adb", "-public-key.pem"))}
        self.assertEqual(assets, expected)

    def test_existing_release_is_rejected_before_release_creation(self):
        self.env["GH_MOCK_EXISTING_RELEASE"] = "1"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any(call[:2] == ["release", "create"] for call in self.calls()))

    def test_upload_failure_leaves_release_unpublished(self):
        self.env["GH_MOCK_FAIL_UPLOAD"] = "1"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(any(call[:2] == ["release", "create"] for call in self.calls()))
        self.assertTrue(any(call[:2] == ["release", "upload"] for call in self.calls()))
        self.assertFalse(any(call[:2] == ["release", "edit"] for call in self.calls()))

    def test_duplicate_asset_names_are_rejected_before_create(self):
        duplicate = self.work / "duplicate"
        shutil.copytree(self.component, duplicate)
        result = self.publish(self.component, duplicate)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any(call[:2] == ["release", "create"] for call in self.calls()))

    def test_same_package_name_with_different_component_versions_is_rejected_before_create(self):
        self.publish_tag = FULLCONE_TAG
        components = []
        for kind, version in (("fullcone-runtime", "1.0-r1"), ("fullcone-luci", "2.0-r1")):
            component = self.make_component(kind, name="shared-package", version=version)
            self.prepare(component, kind)
            components.append(component)
        result = self.publish(*components)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("shared-package.apk", result.stdout)
        self.assertFalse(any(call[:2] == ["release", "create"] for call in self.calls()))

    def test_private_key_in_component_is_rejected_before_create(self):
        shutil.copyfile(self.sdk / "private-key.pem", self.component / "private-key.pem")
        write_checksums(self.component)
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any(call[:2] == ["release", "create"] for call in self.calls()))

    def test_private_key_disguised_as_public_key_is_rejected(self):
        shutil.copyfile(self.sdk / "private-key.pem", self.component / KEY_NAMES["helloworld"])
        write_checksums(self.component)
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any(call[:2] == ["release", "create"] for call in self.calls()))

    def test_missing_uploaded_asset_keeps_release_unpublished(self):
        self.env["GH_MOCK_MISSING_ASSET"] = "1"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(any(call[:2] == ["release", "upload"] for call in self.calls()))
        self.assertFalse(any(call[:2] == ["release", "edit"] for call in self.calls()))

    def test_uploaded_asset_size_mismatch_keeps_release_unpublished(self):
        self.env["GH_MOCK_WRONG_ASSET_SIZE"] = "1"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(any(call[:2] == ["release", "upload"] for call in self.calls()))
        self.assertFalse(any(call[:2] == ["release", "edit"] for call in self.calls()))

    def test_authentication_failure_is_not_treated_as_absent_tag(self):
        self.env["GH_MOCK_API_FAILURE"] = "1"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any(call[:2] == ["release", "create"] for call in self.calls()))

    def test_private_repository_is_rejected(self):
        self.env["GH_MOCK_PRIVATE_REPO"] = "1"
        result = self.publish()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertFalse(any(call[:2] == ["release", "create"] for call in self.calls()))


if __name__ == "__main__":
    unittest.main()
