#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
VALIDATOR_PATH = ROOT / "scripts" / "validate-fullcone-dag.py"
FIXTURE_PATH = ROOT / "tests" / "fixtures" / "openwrt-25.12.5-fullcone.packagedeps"

spec = importlib.util.spec_from_file_location("validate_fullcone_dag", VALIDATOR_PATH)
assert spec and spec.loader
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class FullConeDagTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = FIXTURE_PATH.read_text()

    def validate(self, text: str) -> None:
        validator.validate_dependencies(validator.parse_dependencies(text))

    def assert_invalid(self, text: str) -> None:
        with self.assertRaises(ValueError):
            self.validate(text)

    def without_dependency(self, target: str, dependency: str) -> str:
        lines = []
        for line in self.fixture.splitlines():
            if line.startswith(f"{target} +="):
                fields = line.split()
                fields.remove(dependency)
                line = " ".join(fields)
            lines.append(line)
        return "\n".join(lines) + "\n"

    def test_openwrt_25_12_5_fixture(self) -> None:
        self.validate(self.fixture)

    def test_missing_firewall4_to_nftables_path_fails(self) -> None:
        self.assert_invalid(
            self.without_dependency(validator.FIREWALL4, validator.NFTABLES)
        )

    def test_missing_firewall4_to_fullcone_path_fails(self) -> None:
        self.assert_invalid(
            self.without_dependency(validator.FIREWALL4, validator.FULLCONE)
        )

    def test_missing_nftables_to_libnftnl_path_fails(self) -> None:
        self.assert_invalid(
            self.without_dependency(validator.NFTABLES, validator.LIBNFTNL)
        )

    def test_kernel_outside_firewall4_closure_fails(self) -> None:
        text = self.without_dependency(validator.FIREWALL4, validator.LINUX)
        text = text.replace(f" {validator.LINUX}\n", "\n", 1)
        self.assert_invalid(text)

    def test_nftables_does_not_need_direct_kernel_edge(self) -> None:
        nftables_line = next(
            line for line in self.fixture.splitlines() if line.startswith(validator.NFTABLES)
        )
        self.assertNotIn(validator.LINUX, nftables_line)
        self.validate(self.fixture)

    def test_obsolete_feeds_base_linux_path_is_absent(self) -> None:
        obsolete = "$(curdir)/feeds/base/linux/compile"
        self.assertNotIn(obsolete, VALIDATOR_PATH.read_text())
        self.assertNotIn(obsolete, self.fixture)


if __name__ == "__main__":
    unittest.main()
