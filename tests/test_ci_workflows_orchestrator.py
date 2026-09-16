import unittest
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS_DIR = ROOT / ".github" / "workflows"


class UniqueKeyLoader(yaml.SafeLoader):
    pass


def construct_mapping(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise ValueError(f"Duplicate key found: {key} at line {node.start_mark.line + 1}")
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, construct_mapping)


class CIWorkflowsOrchestratorTests(unittest.TestCase):
    def test_all_workflows_exist_and_have_no_duplicate_keys(self):
        workflow_files = [
            "daily-build.yml",
            "build-helloworld.yml",
            "build-fullcone.yml",
            "build.yml",
        ]
        for name in workflow_files:
            path = WORKFLOWS_DIR / name
            self.assertTrue(path.is_file(), f"Workflow file missing: {name}")
            with open(path, "r", encoding="utf-8") as fp:
                data = yaml.load(fp, Loader=UniqueKeyLoader)
            self.assertIsInstance(data, dict)

    def test_schedule_ownership_exclusive_to_daily_build(self):
        # 仅 daily-build.yml 拥有 schedule 定时器
        daily_path = WORKFLOWS_DIR / "daily-build.yml"
        with open(daily_path, "r", encoding="utf-8") as fp:
            daily_data = yaml.load(fp, Loader=UniqueKeyLoader)

        triggers = daily_data.get("on") or daily_data.get(True)
        self.assertIn("schedule", triggers)
        cron_expr = triggers["schedule"][0]["cron"]
        self.assertEqual(cron_expr, "0 2 * * *")

        # 其他三个工作流绝对不得包含 schedule 触发器
        for name in ("build-helloworld.yml", "build-fullcone.yml", "build.yml"):
            path = WORKFLOWS_DIR / name
            with open(path, "r", encoding="utf-8") as fp:
                data = yaml.load(fp, Loader=UniqueKeyLoader)
            triggers = data.get("on") or data.get(True)
            self.assertNotIn("schedule", triggers, f"{name} should not have schedule trigger")

    def test_reusable_workflows_have_workflow_call(self):
        # build-helloworld.yml
        with open(WORKFLOWS_DIR / "build-helloworld.yml", "r", encoding="utf-8") as fp:
            hw_data = yaml.load(fp, Loader=UniqueKeyLoader)
        hw_triggers = hw_data.get("on") or hw_data.get(True)
        self.assertIn("workflow_call", hw_triggers)
        self.assertIn("openwrt_version", hw_triggers["workflow_call"]["inputs"])
        self.assertTrue(hw_triggers["workflow_call"]["inputs"]["openwrt_version"]["required"])
        self.assertIn("force_rebuild", hw_triggers["workflow_call"]["inputs"])

        # build-fullcone.yml
        with open(WORKFLOWS_DIR / "build-fullcone.yml", "r", encoding="utf-8") as fp:
            fc_data = yaml.load(fp, Loader=UniqueKeyLoader)
        fc_triggers = fc_data.get("on") or fc_data.get(True)
        self.assertIn("workflow_call", fc_triggers)
        self.assertIn("openwrt_version", fc_triggers["workflow_call"]["inputs"])
        self.assertTrue(fc_triggers["workflow_call"]["inputs"]["openwrt_version"]["required"])
        self.assertIn("force_rebuild", fc_triggers["workflow_call"]["inputs"])

        # build.yml
        with open(WORKFLOWS_DIR / "build.yml", "r", encoding="utf-8") as fp:
            fw_data = yaml.load(fp, Loader=UniqueKeyLoader)
        fw_triggers = fw_data.get("on") or fw_data.get(True)
        self.assertIn("workflow_call", fw_triggers)
        self.assertIn("openwrt_version", fw_triggers["workflow_call"]["inputs"])
        self.assertTrue(fw_triggers["workflow_call"]["inputs"]["openwrt_version"]["required"])
        self.assertIn("publish_release", fw_triggers["workflow_call"]["inputs"])

    def test_daily_build_dag_and_concurrency(self):
        daily_path = WORKFLOWS_DIR / "daily-build.yml"
        with open(daily_path, "r", encoding="utf-8") as fp:
            data = yaml.load(fp, Loader=UniqueKeyLoader)

        # Concurrency
        concurrency = data.get("concurrency")
        self.assertEqual(concurrency.get("group"), "daily-openwrt-build")
        self.assertFalse(concurrency.get("cancel-in-progress"))

        # Permissions
        perms = data.get("permissions")
        self.assertEqual(perms.get("contents"), "write")
        self.assertEqual(perms.get("actions"), "read")

        jobs = data.get("jobs", {})
        self.assertIn("resolve-version", jobs)
        self.assertIn("helloworld", jobs)
        self.assertIn("fullcone", jobs)
        self.assertIn("firmware", jobs)

        # helloworld 与 fullcone 必须并行依赖 resolve-version
        hw_job = jobs["helloworld"]
        self.assertEqual(hw_job.get("needs"), "resolve-version")
        self.assertEqual(hw_job.get("uses"), "./.github/workflows/build-helloworld.yml")
        self.assertEqual(hw_job.get("secrets"), "inherit")
        self.assertEqual(hw_job.get("with", {}).get("openwrt_version"), "${{ needs.resolve-version.outputs.version }}")

        fc_job = jobs["fullcone"]
        self.assertEqual(fc_job.get("needs"), "resolve-version")
        self.assertEqual(fc_job.get("uses"), "./.github/workflows/build-fullcone.yml")
        self.assertEqual(fc_job.get("secrets"), "inherit")
        self.assertEqual(fc_job.get("with", {}).get("openwrt_version"), "${{ needs.resolve-version.outputs.version }}")

        # 固件装配 firmware 必须等待 resolve-version, helloworld, fullcone
        fw_job = jobs["firmware"]
        fw_needs = fw_job.get("needs")
        self.assertIsInstance(fw_needs, list)
        self.assertIn("resolve-version", fw_needs)
        self.assertIn("helloworld", fw_needs)
        self.assertIn("fullcone", fw_needs)
        self.assertEqual(fw_job.get("uses"), "./.github/workflows/build.yml")
        self.assertEqual(fw_job.get("secrets"), "inherit")
        self.assertEqual(fw_job.get("with", {}).get("openwrt_version"), "${{ needs.resolve-version.outputs.version }}")
        self.assertTrue(fw_job.get("with", {}).get("publish_release"))

    def test_firmware_workflow_avoids_reresolving_concrete_version(self):
        content = (WORKFLOWS_DIR / "build.yml").read_text(encoding="utf-8")
        # 确保包含正则判断，避免再次网络解析版本
        self.assertIn('if [[ "${REQUESTED_OPENWRT_VERSION}" =~ ^[0-9]+\\.[0-9]+\\.[0-9]+(-rc[0-9]+)?$ ]]; then', content)
        self.assertIn('version="${REQUESTED_OPENWRT_VERSION}"', content)


if __name__ == "__main__":
    unittest.main()
