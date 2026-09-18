import os
import sys
import tempfile
import unittest
from pathlib import Path
import subprocess
import yaml

ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = ROOT / "scripts" / "diff_manifest.py"
BUILD_FIRMWARE_PATH = ROOT / "scripts" / "build-firmware.sh"
DAILY_WORKFLOW_PATH = ROOT / ".github" / "workflows" / "daily-build.yml"

# 将 scripts 路径加入 sys.path 以便直接导入测试函数
sys.path.insert(0, str(ROOT / "scripts"))
from diff_manifest import (
    parse_manifest,
    generate_diff,
    build_markdown_report,
    build_text_diff,
)


class DiffManifestLogicTests(unittest.TestCase):
    def test_parse_manifest_formats(self):
        content = """
# 注释行应当忽略
base-files - 1711~f5dae5ece4
curl - 8.21.0-r1
dnsmasq-full 2.93-r1
coreutils\t9.9-r2
        """
        with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as tf:
            tf.write(content)
            tf_path = tf.name

        try:
            pkgs = parse_manifest(tf_path)
            self.assertEqual(pkgs["base-files"], "1711~f5dae5ece4")
            self.assertEqual(pkgs["curl"], "8.21.0-r1")
            self.assertEqual(pkgs["dnsmasq-full"], "2.93-r1")
            self.assertEqual(pkgs["coreutils"], "9.9-r2")
        finally:
            if os.path.exists(tf_path):
                os.remove(tf_path)

    def test_parse_manifest_nonexistent_and_empty_file(self):
        self.assertEqual(parse_manifest(None), {})
        self.assertEqual(parse_manifest("/nonexistent/file/path"), {})

        with tempfile.NamedTemporaryFile("w", delete=False, encoding="utf-8") as tf:
            tf.write("")
            tf_path = tf.name
        try:
            self.assertEqual(parse_manifest(tf_path), {})
        finally:
            if os.path.exists(tf_path):
                os.remove(tf_path)

    def test_generate_diff_categories(self):
        prev = {
            "pkg-unchanged": "1.0",
            "pkg-upgraded": "1.0",
            "pkg-removed": "1.0",
        }
        curr = {
            "pkg-unchanged": "1.0",
            "pkg-upgraded": "2.0",
            "pkg-added": "1.0",
        }

        added, removed, changed, unchanged = generate_diff(prev, curr)

        self.assertEqual(added, [("pkg-added", "1.0")])
        self.assertEqual(removed, [("pkg-removed", "1.0")])
        self.assertEqual(changed, [("pkg-upgraded", "1.0", "2.0")])
        self.assertEqual(unchanged, [("pkg-unchanged", "1.0")])

    def test_markdown_report_first_run(self):
        md = build_markdown_report([], [], [], [], 306, is_first_run=True)
        self.assertIn("首次记录构建基准", md)
        self.assertIn("306", md)

    def test_markdown_report_identical(self):
        md = build_markdown_report([], [], [], [("curl", "8.0")], 1, is_first_run=False)
        self.assertIn("所有软件包与上次构建完全一致", md)

    def test_markdown_report_with_changes(self):
        added = [("pkg-add", "1.0")]
        removed = [("pkg-del", "1.0")]
        changed = [("pkg-up", "1.0", "2.0")]
        unchanged = [("pkg-same", "1.0")]

        md = build_markdown_report(added, removed, changed, unchanged, 3, is_first_run=False)
        self.assertIn("版本变更", md)
        self.assertIn("新增组件", md)
        self.assertIn("移除组件", md)
        self.assertIn("pkg-up", md)
        self.assertIn("pkg-add", md)
        self.assertIn("pkg-del", md)
        self.assertIn("点击展开未变动组件清单", md)


class DiffManifestCliTests(unittest.TestCase):
    def setUp(self):
        self.tmp_dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.tmp_dir.cleanup()

    def test_cli_execution_with_diff(self):
        prev_file = Path(self.tmp_dir.name) / "prev.manifest"
        curr_file = Path(self.tmp_dir.name) / "curr.manifest"
        diff_out = Path(self.tmp_dir.name) / "out.diff"
        md_out = Path(self.tmp_dir.name) / "out.md"
        summary_out = Path(self.tmp_dir.name) / "summary.md"

        prev_file.write_text("base-files - 100\ncurl - 8.0\n", encoding="utf-8")
        curr_file.write_text("base-files - 101\ncurl - 8.0\nnew-pkg - 1.0\n", encoding="utf-8")

        env = os.environ.copy()
        env["GITHUB_STEP_SUMMARY"] = str(summary_out)

        cmd = [
            sys.executable,
            str(SCRIPT_PATH),
            str(prev_file),
            str(curr_file),
            "--output-diff",
            str(diff_out),
            "--output-md",
            str(md_out),
            "--summary",
        ]

        res = subprocess.run(cmd, capture_output=True, text=True, env=env)
        self.assertEqual(res.returncode, 0, f"diff_manifest.py failed: {res.stderr}")

        self.assertTrue(diff_out.is_file())
        self.assertTrue(md_out.is_file())
        self.assertTrue(summary_out.is_file())

        md_content = md_out.read_text(encoding="utf-8")
        self.assertIn("base-files", md_content)
        self.assertIn("new-pkg", md_content)

        summary_content = summary_out.read_text(encoding="utf-8")
        self.assertEqual(summary_content.strip(), md_content.strip())

    def test_cli_execution_empty_previous_manifest_triggers_baseline(self):
        # 验证历史文件如果为 0 字节，正确识别为首次基准模式，而非错误识别为全量新增
        prev_file = Path(self.tmp_dir.name) / "empty_prev.manifest"
        curr_file = Path(self.tmp_dir.name) / "curr.manifest"
        md_out = Path(self.tmp_dir.name) / "out.md"

        prev_file.write_text("", encoding="utf-8")
        curr_file.write_text("base-files - 101\ncurl - 8.0\n", encoding="utf-8")

        cmd = [
            sys.executable,
            str(SCRIPT_PATH),
            str(prev_file),
            str(curr_file),
            "--output-md",
            str(md_out),
        ]
        res = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(res.returncode, 0)
        md_content = md_out.read_text(encoding="utf-8")
        self.assertIn("首次记录构建基准", md_content)
        self.assertNotIn("新增组件", md_content)


class ManifestWorkflowContractTests(unittest.TestCase):
    def test_daily_build_manifest_cache_contracts(self):
        content = DAILY_WORKFLOW_PATH.read_text(encoding="utf-8")
        data = yaml.safe_load(content)

        # 1. 缓存路径必须为工作区相对路径 .manifest-cache，严禁使用 /tmp/manifest_cache
        self.assertNotIn("/tmp/manifest_cache", content)

        steps = data["jobs"]["firmware"]["steps"]
        restore_step = next(s for s in steps if s.get("name") == "恢复历史 Manifest 清单缓存")
        self.assertEqual(restore_step["with"]["path"], ".manifest-cache")
        self.assertEqual(restore_step["with"]["key"], "manifest-cache-x86_64-${{ github.run_id }}")
        self.assertEqual(restore_step["with"]["restore-keys"].strip(), "manifest-cache-x86_64-")

        save_step = next(s for s in steps if s.get("name") == "保存本次 Manifest 清单缓存")
        self.assertEqual(save_step["with"]["path"], ".manifest-cache")
        self.assertEqual(save_step["with"]["key"], "manifest-cache-x86_64-${{ github.run_id }}")
        # 必须仅在构建成功时保存缓存
        self.assertEqual(save_step.get("if"), "success()")

        # 2. 验证基于 .manifest-cache/last.manifest 的恢复逻辑存在
        self.assertIn("cp -f .manifest-cache/last.manifest .work/last-manifest.txt", content)
        self.assertIn(".manifest-cache/last.manifest", content)

    def test_build_firmware_manifest_search_is_strict(self):
        content = BUILD_FIRMWARE_PATH.read_text(encoding="utf-8")
        # 验证严禁使用宽松的 *manifest*，必须使用 *.manifest
        self.assertIn('find "${BIN_DIR}" -type f -name "*.manifest"', content)
        self.assertNotIn('find "${BIN_DIR}" -type f -name "*manifest*"', content)


if __name__ == "__main__":
    unittest.main()
