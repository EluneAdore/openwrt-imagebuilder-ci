import unittest
from pathlib import Path


BUILD_SCRIPT = Path(__file__).parents[1] / "scripts" / "build.sh"


class RootfsFullConeValidatorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script = BUILD_SCRIPT.read_text()

    def test_nft_frontend_is_not_used_as_parser_evidence(self):
        self.assertNotIn(
            'strings "${ROOTFS_DIR}/usr/sbin/nft" | grep', self.script
        )
        self.assertIn('rootfs_nft_file_type="$(file -b', self.script)
        self.assertIn("libnftables\\.so\\.[^]]+", self.script)

    def test_actual_libnftables_is_parser_evidence(self):
        self.assertIn('readlink -e "${rootfs_libnftables_link}"', self.script)
        self.assertIn(
            'strings "${rootfs_libnftables}" > "${rootfs_libnftables_strings}"',
            self.script,
        )
        self.assertIn(
            "grep -Fx 'fullcone' \"${rootfs_libnftables_strings}\"", self.script
        )

    def test_rootfs_strings_checks_do_not_pipe_to_grep(self):
        for line in self.script.splitlines():
            if "strings " in line:
                self.assertNotIn("| grep", line)


if __name__ == "__main__":
    unittest.main()
