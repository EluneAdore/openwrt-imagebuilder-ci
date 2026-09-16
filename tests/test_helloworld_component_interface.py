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

    def test_orchestrator_and_compatibility_wrapper_use_component(self):
        self.assertIn('HELLOWORLD_COMPONENT="${WORKSPACE_ROOT}/components/helloworld-builder/build.sh"', self.orchestrator)
        self.assertIn('"${HELLOWORLD_COMPONENT}"', self.orchestrator)
        self.assertIn('components/helloworld-builder', self.wrapper)
        self.assertIn('exec "${COMPONENT_BUILD}" "$@"', self.wrapper)


if __name__ == "__main__":
    unittest.main()
