import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "find-nftables-build-roots.py"
SPEC = importlib.util.spec_from_file_location("find_nftables_build_roots", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class NftablesBuildRootTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.build_dir = Path(self.temporary_directory.name) / "build_dir"
        self.build_dir.mkdir()

    def tearDown(self):
        self.temporary_directory.cleanup()

    def make_root(self, target: str, version: str) -> Path:
        root = self.build_dir / target / "nftables-json" / f"nftables-{version}"
        for marker in MODULE.SOURCE_MARKERS:
            path = root / marker
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        return root

    def roots(self):
        return MODULE.find_nftables_build_roots(self.build_dir)

    def test_finds_unique_immediate_source_root(self):
        root = self.make_root("target-x86_64_musl", "1.1.6")
        self.assertEqual(self.roots(), [root])

    def test_ignores_all_descendants_of_source_root(self):
        root = self.make_root("target-x86_64_musl", "1.1.6")
        nested = root / "tests" / "nftables-descendant"
        for marker in MODULE.SOURCE_MARKERS:
            path = nested / marker
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()

        self.assertEqual(self.roots(), [root])

    def test_rejects_directory_without_source_markers(self):
        candidate = (
            self.build_dir
            / "target-x86_64_musl"
            / "nftables-json"
            / "nftables-1.1.6"
        )
        candidate.mkdir(parents=True)
        self.assertEqual(self.roots(), [])

    def test_reports_multiple_independent_roots(self):
        first = self.make_root("target-x86_64_musl", "1.1.6")
        second = self.make_root("target-aarch64_cortex-a53_musl", "1.1.6")
        self.assertEqual(self.roots(), sorted([first, second]))


if __name__ == "__main__":
    unittest.main()
