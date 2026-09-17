import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
COMPONENT_DIR = ROOT / "components" / "fullcone-builder"
RUNTIME_COMPONENT = COMPONENT_DIR / "build.sh"
LUCI_COMPONENT = COMPONENT_DIR / "build-luci.sh"
ASSEMBLY_SCRIPT = ROOT / "scripts" / "build-firmware.sh"


class FullConeComponentInterfaceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime = RUNTIME_COMPONENT.read_text()
        cls.luci = LUCI_COMPONENT.read_text()
        cls.assembly_script = ASSEMBLY_SCRIPT.read_text()

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

    def test_assembly_script_consumes_fullcone_components(self):
        self.assertIn("${FULLCONE_RUNTIME_DIR:?", self.assembly_script)
        self.assertIn("${FULLCONE_LUCI_DIR:?", self.assembly_script)
        self.assertIn("fullcone-runtime-build-info.txt", self.assembly_script)
        self.assertIn("fullcone-luci-build-info.txt", self.assembly_script)

    def test_luci_dynamic_stable_branch_resolution_and_fail_fast(self):
        self.assertIn(
            'VERSION_SERIES="$(echo "${OPENWRT_VERSION}" | cut -d. -f1-2)"',
            self.luci,
        )
        self.assertIn(
            'LUCI_BRANCH="${LUCI_BRANCH:-openwrt-${VERSION_SERIES}}"',
            self.luci,
        )
        self.assertIn('git ls-remote --heads "${LUCI_REPOSITORY}"', self.luci)
        self.assertIn(
            'die "无法在官方 LuCI 仓库中找到 OpenWrt ${OPENWRT_VERSION} 对应的 stable branch: ${LUCI_BRANCH}（严禁使用 master 或猜测分支）"',
            self.luci,
        )
        self.assertNotIn('LUCI_BRANCH="master"', self.luci)
        self.assertNotIn('checkout master', self.luci)

    def test_luci_compiles_both_base_and_app_firewall(self):
        self.assertIn('package/feeds/luci/luci-base/compile', self.luci)
        self.assertIn('package/feeds/luci/luci-app-firewall/compile', self.luci)

    def test_luci_build_info_contains_metadata_tracking(self):
        for field in (
            "Target: ${target}",
            "Subtarget: ${subtarget}",
            "Architecture: ${SDK_ARCH}",
            "LuCI repository: ${LUCI_REPOSITORY}",
            "LuCI ref: ${luci_ref}",
            "LuCI commit SHA: ${luci_commit}",
            "ImmortalWrt donor commit: ${immortalwrt_donor_commit}",
            "nft-fullcone source commit: ${fullcone_source_commit}",
        ):
            self.assertIn(field, self.luci)

    def test_runtime_build_info_contains_target_subtarget_and_donor(self):
        for field in (
            "Target: ${target}",
            "Subtarget: ${subtarget}",
            "Architecture: ${SDK_ARCH}",
            "ImmortalWrt donor commit: ${immortalwrt_head_commit}",
            "nft-fullcone source commit: ${fullcone_upstream_commit}",
        ):
            self.assertIn(field, self.runtime)

    def test_assembly_script_validates_luci_manifest_versions_match_component(self):
        self.assertIn(
            'done < "${FULLCONE_LUCI_DIR}/repository-packages.txt"',
            self.assembly_script,
        )
        self.assertIn(
            'manifest_version="$(awk -v pkg="${pkg_name}" \'$1 == pkg { print $3; exit }\' "${MANIFEST_FILE}")"',
            self.assembly_script,
        )
        self.assertIn(
            '与预编译组件版本 (${expected_version}) 不一致',
            self.assembly_script,
        )

    def test_components_support_sdk_dir_priority(self):
        for source in (self.runtime, self.luci):
            self.assertIn('SDK_DIR="${SDK_DIR:-}"', source)
            self.assertIn('if [ -n "${SDK_DIR}" ] && [ -f "${SDK_DIR}/Makefile" ]; then', source)
            self.assertIn('sdk_dir="${SDK_DIR}"', source)

    def test_fullcone_workflow_exists_and_calls_authoritative_components(self):
        workflow_file = ROOT / ".github" / "workflows" / "build-fullcone.yml"
        self.assertTrue(workflow_file.is_file())
        workflow_content = workflow_file.read_text()
        self.assertIn("./components/fullcone-builder/build.sh", workflow_content)
        self.assertIn("./components/fullcone-builder/build-luci.sh", workflow_content)
        self.assertIn("openwrt-component-fullcone-", workflow_content)
        self.assertIn("fullcone-component-", workflow_content)
        self.assertNotIn("tag_name=", workflow_content)
        self.assertIn("resolve-version.sh", workflow_content)
        self.assertIn("setup-sdk.sh", workflow_content)
        self.assertIn('SDK_DIR="${SDK_DIR}"', workflow_content)
        self.assertIn("CUSTOM_SIGNING_KEY", workflow_content)
        self.assertIn("sha256sum --check --strict SHA256SUMS", workflow_content)
        self.assertIn("kernel-dependency.txt", workflow_content)
        self.assertIn("fullcone-public-key.pem", workflow_content)
        self.assertIn("luci-fullcone-public-key.pem", workflow_content)
        self.assertIn("runtime", workflow_content)
        self.assertIn("luci", workflow_content)
        for pkg in (
            "kmod-nft-fullcone",
            "libnftnl11",
            "nftables-json",
            "firewall4",
            "luci-base",
            "luci-app-firewall",
            "luci-i18n-firewall-zh-cn",
        ):
            self.assertIn(pkg, workflow_content)


if __name__ == "__main__":
    unittest.main()
