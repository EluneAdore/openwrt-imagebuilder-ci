"""固件内置 custom APK 源回归；只在临时目录使用真实签名 APK。

运行：python3 -m unittest discover -s tests -v
可通过 CUSTOM_FEED_APK 指定 OpenWrt SDK/ImageBuilder 的 apk-tools 3 路径。
"""

import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PREPARE = ROOT / "scripts/prepare-component-feed.sh"
RUNTIME = ROOT / "scripts/runtime-custom-feed.sh"
CONFIGURE = ROOT / "scripts/configure-imagebuilder-apk.py"
KEY_NAMES = {
    "helloworld": "helloworld-public-key.pem",
    "fullcone-runtime": "fullcone-public-key.pem",
    "fullcone-luci": "luci-fullcone-public-key.pem",
}
EMBEDDED_BASE = Path("usr/share/custom-apk")


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
        result = run("bash", PREPARE, kind, directory, self.sdk, env=self.env)
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

                repositories = self.work / f"{kind}-install-repositories"
                repositories.write_text("@custom " + index.as_uri() + "\n")
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
                self.assertNotIn("pkgname-spec: ${name}.apk", checked(self.apk, "adbdump", index))
                self.assertFalse((directory / "runtime-repository.url").exists())
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

    def test_package_name_with_plus_is_supported_by_local_repository(self):
        directory = self.make_component(name="local+package")
        self.prepare(directory)
        checked(self.apk, "--keys-dir", self.trusted_keys, "verify",
                directory / "local+package-1.0-r1.apk", directory / "helloworld-packages.adb")

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

    def test_rejects_wrong_openwrt_version(self):
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



APK_LOGGER = r'''#!/usr/bin/env python3
import json, os, subprocess, sys
from pathlib import Path
with Path(os.environ["APK_TEST_LOG"]).open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\n")
sys.exit(subprocess.call([os.environ["REAL_CUSTOM_FEED_APK"], "--no-network"] + sys.argv[1:]))
'''


class RuntimeCustomFeedTests(SignedFixture):
    def setUp(self):
        super().setUp()
        self.components = []
        self.names = []
        self.versions = []
        for kind in KEY_NAMES:
            name = "luci-i18n-firewall-zh-cn" if kind == "fullcone-luci" else kind + "-smoke"
            version = "26.280.64158~a450f0d-r1" if kind == "fullcone-luci" else "1.0-r1"
            component = self.make_component(kind, name, version=version)
            self.prepare(component, kind)
            self.components.append(component)
            self.names.append(name)
            self.versions.append(version)
        wrapper = self.sdk / "staging_dir/host/bin/apk"
        wrapper.write_text(APK_LOGGER)
        wrapper.chmod(0o755)
        self.apk_log = self.work / "apk-calls.jsonl"
        self.external_log = self.work / "external-tools.log"
        blocked_bin = self.work / "blocked-bin"
        blocked_bin.mkdir()
        for name in ("curl", "gh"):
            tool = blocked_bin / name
            tool.write_text("#!/bin/sh\nprintf '%s\\n' \"$0\" >> \"$EXTERNAL_TOOLS_LOG\"\nexit 99\n")
            tool.chmod(0o755)
        self.env.update({"PATH": str(blocked_bin) + os.pathsep + os.environ["PATH"],
                         "APK_TEST_LOG": str(self.apk_log),
                         "EXTERNAL_TOOLS_LOG": str(self.external_log),
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
        shutil.copytree(self.overlay, rootfs)
        official = self.work / "official"
        self.make_package(official, name="coremark")
        for name, version in zip(self.names, self.versions):
            self.make_package(official, name=name, contents="official replacement\n", version=version)
        official_index = self.signed_index(official)
        self.setup_repos = self.work / "install-repositories"
        self.setup_repos.write_text(official_index.as_uri() + "\n" + "".join(
            "@custom " + (rootfs / EMBEDDED_BASE / kind / f"{kind}-packages.adb").as_uri() + "\n"
            for kind in KEY_NAMES
        ))
        constraints = [line for component in self.components
                       for line in (component / "install-constraints.txt").read_text().splitlines()]
        checked(self.apk, "--root", rootfs, "--arch", "x86_64", "--keys-dir", self.trusted_keys,
                "--repositories-file", self.setup_repos, "--no-network", "add", "--usermode", "--initdb", *constraints)
        (rootfs / "etc/apk/repositories").write_text(official_index.as_uri() + "\n")
        return rootfs

    def test_stage_and_verify_real_world_without_mutating_rootfs_or_network_dependencies(self):
        self.runtime("stage", self.overlay)
        config = self.overlay / "etc/apk/repositories.d/custom-components.list"
        expected = [f"@custom file:///usr/share/custom-apk/{kind}/{kind}-packages.adb" for kind in KEY_NAMES]
        self.assertEqual(config.read_text().splitlines(), expected)
        self.assertNotIn(str(self.work), config.read_text())
        for component, kind in zip(self.components, KEY_NAMES):
            self.assertEqual((self.overlay / "etc/apk/keys" / KEY_NAMES[kind]).read_bytes(),
                             (component / KEY_NAMES[kind]).read_bytes())
            embedded = self.overlay / EMBEDDED_BASE / kind
            expected_assets = {path.name for path in component.glob("*.apk")} | {f"{kind}-packages.adb"}
            self.assertEqual({path.name for path in embedded.iterdir()}, expected_assets)
            for name in expected_assets:
                self.assertEqual((embedded / name).read_bytes(), (component / name).read_bytes())
        rootfs = self.install_rootfs()
        before = {str(p.relative_to(rootfs)): p.read_bytes() for p in rootfs.rglob("*") if p.is_file()}
        self.runtime("verify", rootfs)
        after = {str(p.relative_to(rootfs)): p.read_bytes() for p in rootfs.rglob("*") if p.is_file()}
        self.assertEqual(after, before)
        calls = [json.loads(line) for line in self.apk_log.read_text().splitlines()]
        self.assertTrue(any("update" in call for call in calls), calls)
        self.assertTrue(any("add" in call and "--simulate" in call and "coremark" in call for call in calls), calls)
        self.assertFalse(any("--allow-untrusted" in call for call in calls), calls)
        self.assertFalse(self.external_log.exists(), "内置源不应调用网络或托管工具")

    def test_embedded_tilde_version_installs_and_official_transactions_preserve_custom_identity(self):
        self.runtime("stage", self.overlay)
        rootfs = self.install_rootfs()
        component = self.components[2]
        name, version = self.names[2], self.versions[2]
        canonical = f"{name}-{version}.apk"
        self.assertIn("~", canonical)
        self.assertEqual((rootfs / EMBEDDED_BASE / "fullcone-luci" / canonical).read_bytes(),
                         (component / canonical).read_bytes())
        installed_before = (rootfs / "lib/apk/db/installed").read_text()
        self.assertRegex(installed_before, r"(?m)^V:" + re.escape(version) + r"$")
        custom_pins = [line for line in (rootfs / "etc/apk/world").read_text().splitlines() if "@custom" in line]
        # 删除构建输入；固件内置组件必须独立提供后续安装事务所需的源和包。
        for component in self.components:
            shutil.rmtree(component)
        args = (self.apk, "--root", rootfs, "--arch", "x86_64", "--keys-dir", self.trusted_keys,
                "--repositories-file", self.setup_repos, "--no-network")
        checked(*args, "update")
        checked(*args, "add", "--usermode", "coremark")
        checked(*args, "upgrade", "--no-scripts")
        after_pins = [line for line in (rootfs / "etc/apk/world").read_text().splitlines() if "@custom" in line]
        self.assertEqual(after_pins, custom_pins)
        for name in self.names:
            self.assertEqual((rootfs / "usr/share" / name).read_text(), "custom\n")
        self.assertFalse(self.external_log.exists())

    def test_stage_rejects_missing_metadata_checksum_coverage(self):
        component = self.components[0]
        checksums = component / "SHA256SUMS"
        checksums.write_text("\n".join(line for line in checksums.read_text().splitlines()
                                      if not line.endswith("helloworld-packages.adb")) + "\n")
        result = self.runtime("stage", self.overlay, success=False)
        self.assertIn("SHA256SUMS 未覆盖", result.stdout)

    def test_stage_rejects_missing_component_apk(self):
        next(self.components[0].glob("*.apk")).unlink()
        self.runtime("stage", self.overlay, success=False)

    def test_stage_rejects_corrupt_component_apk(self):
        package = next(self.components[0].glob("*.apk"))
        package.write_bytes(package.read_bytes() + b"corrupt")
        self.runtime("stage", self.overlay, success=False)

    def test_stage_rejects_corrupt_payload_even_with_updated_checksums(self):
        component, name = self.components[0], self.names[0]
        package = self.make_package(component, name=name, contents="UNIQUE_STAGE_PAYLOAD\n",
                                    compression="none")
        write_checksums(component)
        self.prepare(component)
        original = package.read_bytes()
        self.assertEqual(original.count(b"UNIQUE_STAGE_PAYLOAD"), 1)
        package.write_bytes(original.replace(b"UNIQUE_STAGE_PAYLOAD", b"BROKEN_STAGE_PAYLOAD"))
        write_checksums(component)
        result = self.runtime("stage", self.overlay, success=False)
        self.assertIn("file integrity error", result.stdout)

    def test_stage_rejects_corrupt_component_index(self):
        index = self.components[0] / "helloworld-packages.adb"
        index.write_bytes(index.read_bytes() + b"corrupt")
        self.runtime("stage", self.overlay, success=False)

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

    def test_verify_rejects_missing_embedded_index(self):
        self.runtime("stage", self.overlay)
        rootfs = self.install_rootfs()
        (rootfs / EMBEDDED_BASE / "helloworld/helloworld-packages.adb").unlink()
        self.runtime("verify", rootfs, success=False)

    def test_verify_rejects_missing_embedded_apk(self):
        self.runtime("stage", self.overlay)
        rootfs = self.install_rootfs()
        next((rootfs / EMBEDDED_BASE / "helloworld").glob("*.apk")).unlink()
        self.runtime("verify", rootfs, success=False)

    def test_verify_rejects_corrupt_embedded_assets(self):
        self.runtime("stage", self.overlay)
        rootfs = self.install_rootfs()
        directory = rootfs / EMBEDDED_BASE / "helloworld"
        for asset in directory.iterdir():
            with self.subTest(asset=asset.name):
                original = asset.read_bytes()
                asset.write_bytes(original + b"corrupt")
                self.runtime("verify", rootfs, success=False)
                asset.write_bytes(original)


if __name__ == "__main__":
    unittest.main()
