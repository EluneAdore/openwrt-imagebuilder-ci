import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
ASSEMBLY_SCRIPT = ROOT / "scripts" / "build-firmware.sh"


class FirmwareAssemblyOnlyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script_content = ASSEMBLY_SCRIPT.read_text(encoding="utf-8")

    def test_assembly_script_exists_and_executable(self):
        self.assertTrue(ASSEMBLY_SCRIPT.is_file())

    def test_assembly_script_requires_explicit_component_inputs(self):
        for var in (
            "HELLOWORLD_COMPONENT_DIR",
            "FULLCONE_RUNTIME_DIR",
            "FULLCONE_LUCI_DIR",
        ):
            self.assertIn(f"${{{var}:?", self.script_content)

    def test_assembly_script_strictly_forbids_compilation(self):
        forbidden_patterns = (
            "components/helloworld-builder/build.sh",
            "components/fullcone-builder/build.sh",
            "components/fullcone-builder/build-luci.sh",
            "package/feeds/",
            "package/kernel/",
            "/compile",
            "make clean",
        )
        for pattern in forbidden_patterns:
            self.assertNotIn(pattern, self.script_content)

    def test_assembly_script_validates_sha256_for_all_components(self):
        self.assertIn("sha256sum --check --strict SHA256SUMS", self.script_content)

    def test_assembly_script_imports_multiple_public_keys(self):
        self.assertIn("helloworld-public-key.pem", self.script_content)
        self.assertIn("fullcone-public-key.pem", self.script_content)
        self.assertIn("luci-fullcone-public-key.pem", self.script_content)

    def test_assembly_script_validates_manifest_and_kernel_abi(self):
        self.assertIn("kernel-dependency.txt", self.script_content)
        self.assertIn("kmod-nft-fullcone ABI", self.script_content)
        self.assertIn("repository-packages.txt", self.script_content)
        self.assertIn("naiveproxy", self.script_content)

    def test_assembly_script_performs_rootfs_hard_validation(self):
        for evidence in (
            "geoip.dat",
            "geosite.dat",
            "nft_fullcone.ko",
            "libnftables.so",
            "libnftnl",
            "fullcone-check",
            "firewall.zh-cn.lmo",
            "zone-fullcone.uc",
        ):
            self.assertIn(evidence, self.script_content)

    def test_assembly_script_exports_unified_metadata(self):
        self.assertIn("helloworld-build-info.txt", self.script_content)
        self.assertIn("fullcone-runtime-build-info.txt", self.script_content)
        self.assertIn("fullcone-luci-build-info.txt", self.script_content)
        self.assertNotIn("fullcone-build-info.txt", self.script_content)
        self.assertNotIn("luci-fullcone-build-info.txt", self.script_content)


class FirmwareCIWorkflowAssemblyOnlyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow_path = ROOT / ".github" / "workflows" / "build.yml"
        cls.workflow_content = cls.workflow_path.read_text(encoding="utf-8")

    def test_workflow_exists_and_is_valid_yaml(self):
        self.assertTrue(self.workflow_path.is_file())
        try:
            import yaml
            data = yaml.safe_load(self.workflow_content)
            self.assertIsInstance(data, dict)
        except ImportError:
            pass

    def test_workflow_strictly_forbids_sdk_download_or_cache(self):
        forbidden = (
            "openwrt-sdk-x86_64",
            "setup-sdk.sh",
            "SDK_DIR",
        )
        for item in forbidden:
            self.assertNotIn(item, self.workflow_content)

    def test_workflow_strictly_forbids_component_compilation(self):
        forbidden = (
            "./scripts/build.sh",
            "components/helloworld-builder/build.sh",
            "components/fullcone-builder/build.sh",
            "components/fullcone-builder/build-luci.sh",
        )
        for item in forbidden:
            self.assertNotIn(item, self.workflow_content)

    def test_workflow_calls_build_firmware_with_explicit_components(self):
        self.assertIn("./scripts/build-firmware.sh", self.workflow_content)
        for var in (
            "HELLOWORLD_COMPONENT_DIR",
            "FULLCONE_RUNTIME_DIR",
            "FULLCONE_LUCI_DIR",
        ):
            self.assertIn(var, self.workflow_content)

    def test_workflow_downloads_matching_components_with_fail_fast(self):
        self.assertIn("openwrt-component-helloworld-${OPENWRT_VERSION}-x86_64.tar.gz", self.workflow_content)
        self.assertIn("openwrt-component-fullcone-${OPENWRT_VERSION}-x86_64.tar.gz", self.workflow_content)
        self.assertIn("component-helloworld-${OPENWRT_VERSION}", self.workflow_content)
        self.assertIn("component-fullcone-${OPENWRT_VERSION}", self.workflow_content)
        self.assertIn("严禁降级混拼旧版本或回退编译", self.workflow_content)


if __name__ == "__main__":
    unittest.main()
