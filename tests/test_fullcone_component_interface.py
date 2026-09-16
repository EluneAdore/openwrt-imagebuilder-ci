import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMPONENT_DIR = ROOT / "components" / "fullcone-builder"
RUNTIME_COMPONENT = COMPONENT_DIR / "build.sh"
LUCI_COMPONENT = COMPONENT_DIR / "build-luci.sh"
RUNTIME_WRAPPER = ROOT / "scripts" / "build-fullcone.sh"
LUCI_WRAPPER = ROOT / "scripts" / "build-luci-fullcone.sh"
ORCHESTRATOR = ROOT / "scripts" / "build.sh"


class FullConeComponentInterfaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime = RUNTIME_COMPONENT.read_text()
        cls.luci = LUCI_COMPONENT.read_text()
        cls.runtime_wrapper = RUNTIME_WRAPPER.read_text()
        cls.luci_wrapper = LUCI_WRAPPER.read_text()
        cls.orchestrator = ORCHESTRATOR.read_text()

    def test_entries_require_stable_inputs(self):
        for source in (self.runtime, self.luci):
            for variable in ("OPENWRT_VERSION", "WORK_DIR", "OUTPUT_DIR"):
                self.assertIn(f'${{{variable}:?', source)
            self.assertIn("COMPONENT_INTERFACE_VERSION=1", source)

    def test_runtime_keeps_fullcone_hard_validation(self):
        for evidence in (
            "validate-fullcone-dag.py",
            "find-nftables-build-roots.py",
            "PKG_FIXUP:=autoreconf",
            "package/feeds/base/firewall4/compile",
            "nft_fullcone.ko",
            "libnftables.so",
            "nft_try_fullcone",
            "zone-fullcone.uc",
            "kernel-dependency.txt",
        ):
            self.assertIn(evidence, self.runtime)

    def test_luci_keeps_fullcone_ui_and_translation_validation(self):
        for evidence in (
            "001-luci-base-detect-fullcone.patch",
            "003-luci-app-firewall-add-zh-hans-translations.patch",
            "luci-i18n-firewall-zh-cn",
            "Enable FullCone NAT",
            "firewall.zh-cn.lmo",
        ):
            self.assertIn(evidence, self.luci)

    def test_orchestrator_and_compatibility_wrappers_use_components(self):
        self.assertIn(
            'FULLCONE_COMPONENT="${WORKSPACE_ROOT}/components/fullcone-builder/build.sh"',
            self.orchestrator,
        )
        self.assertIn(
            'FULLCONE_LUCI_COMPONENT="${WORKSPACE_ROOT}/components/fullcone-builder/build-luci.sh"',
            self.orchestrator,
        )
        self.assertIn('components/fullcone-builder', self.runtime_wrapper)
        self.assertIn('exec "${COMPONENT_BUILD}" "$@"', self.runtime_wrapper)
        self.assertIn('components/fullcone-builder', self.luci_wrapper)
        self.assertIn('exec "${COMPONENT_BUILD}" "$@"', self.luci_wrapper)


if __name__ == "__main__":
    unittest.main()
