import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMPONENT = ROOT / "components" / "helloworld-builder" / "build.sh"
WRAPPER = ROOT / "scripts" / "build-helloworld.sh"
ORCHESTRATOR = ROOT / "scripts" / "build.sh"


class HelloworldComponentInterfaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.component = COMPONENT.read_text()
        cls.wrapper = WRAPPER.read_text()
        cls.orchestrator = ORCHESTRATOR.read_text()

    def test_component_requires_stable_inputs(self):
        for variable in ("OPENWRT_VERSION", "WORK_DIR", "OUTPUT_DIR"):
            self.assertIn(f'${{{variable}:?', self.component)

    def test_component_keeps_required_outputs(self):
        for output in (
            "helloworld-public-key.pem",
            "repository-packages.txt",
            "install-packages.txt",
            "install-constraints.txt",
            "SHA256SUMS",
            "BUILD-INFO.txt",
        ):
            self.assertIn(output, self.component)

    def test_package_contract_is_unchanged(self):
        for package in (
            "luci-app-ssr-plus",
            "xray-core",
            "mihomo",
            "luci-i18n-ssr-plus-zh-cn",
            "v2ray-geoip",
            "v2ray-geosite",
        ):
            self.assertIn(package, self.component)
        self.assertIn("Excluded target: naiveproxy", self.component)

    def test_component_supports_sdk_dir_priority(self):
        self.assertIn('SDK_DIR="${SDK_DIR:-}"', self.component)
        self.assertIn('if [ -n "${SDK_DIR}" ] && [ -f "${SDK_DIR}/Makefile" ]; then', self.component)
        self.assertIn('sdk_dir="${SDK_DIR}"', self.component)

    def test_component_build_info_records_target_metadata(self):
        for field in (
            "Target: ${TARGET_PATH%/*}",
            "Subtarget: ${TARGET_PATH#*/}",
            "Architecture: ${SDK_ARCH}",
        ):
            self.assertIn(field, self.component)

    def test_helloworld_workflow_exists_and_calls_authoritative_component(self):
        workflow_file = ROOT / ".github" / "workflows" / "build-helloworld.yml"
        self.assertTrue(workflow_file.is_file())
        workflow_content = workflow_file.read_text()
        self.assertIn("./components/helloworld-builder/build.sh", workflow_content)
        self.assertIn("component-helloworld-", workflow_content)
        self.assertIn("resolve-version.sh", workflow_content)

    def test_component_cleans_wsl_path(self):
        self.assertIn('CLEAN_PATH=""', self.component)
        self.assertIn('export PATH="$CLEAN_PATH"', self.component)



if __name__ == "__main__":
    unittest.main()
