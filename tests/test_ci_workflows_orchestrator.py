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
        ]
        for name in workflow_files:
            path = WORKFLOWS_DIR / name
            self.assertTrue(path.is_file(), f"Workflow file missing: {name}")
            with open(path, "r", encoding="utf-8") as fp:
                data = yaml.load(fp, Loader=UniqueKeyLoader)
            self.assertIsInstance(data, dict)

    def test_build_yml_is_completely_removed(self):
        # 确认旧 build.yml 已彻底删除，全仓库统一使用 daily-build.yml
        build_yml = WORKFLOWS_DIR / "build.yml"
        self.assertFalse(build_yml.exists(), "build.yml 必须已被彻底删除")

    def test_schedule_ownership_exclusive_to_daily_build(self):
        # 仅 daily-build.yml 拥有 schedule 定时器
        daily_path = WORKFLOWS_DIR / "daily-build.yml"
        with open(daily_path, "r", encoding="utf-8") as fp:
            daily_data = yaml.load(fp, Loader=UniqueKeyLoader)

        triggers = daily_data.get("on") or daily_data.get(True)
        self.assertIn("schedule", triggers)
        cron_expr = triggers["schedule"][0]["cron"]
        self.assertEqual(cron_expr, "23 23 * * *")

        # 两个组件工作流绝对不得包含 schedule 触发器
        for name in ("build-helloworld.yml", "build-fullcone.yml"):
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

    def test_daily_build_dag_and_concurrency(self):
        daily_path = WORKFLOWS_DIR / "daily-build.yml"
        with open(daily_path, "r", encoding="utf-8") as fp:
            data = yaml.load(fp, Loader=UniqueKeyLoader)

        # Concurrency: 绝不中断正在进行的构建
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
        self.assertTrue(hw_job.get("with", {}).get("force_rebuild"))

        fc_job = jobs["fullcone"]
        self.assertEqual(fc_job.get("needs"), "resolve-version")
        self.assertEqual(fc_job.get("uses"), "./.github/workflows/build-fullcone.yml")
        self.assertEqual(fc_job.get("secrets"), "inherit")
        self.assertEqual(fc_job.get("with", {}).get("openwrt_version"), "${{ needs.resolve-version.outputs.version }}")
        self.assertTrue(fc_job.get("with", {}).get("force_rebuild"))

        # 固件纯装配 firmware 必须等待 resolve-version, helloworld, fullcone
        fw_job = jobs["firmware"]
        fw_needs = fw_job.get("needs")
        self.assertIsInstance(fw_needs, list)
        self.assertIn("resolve-version", fw_needs)
        self.assertIn("helloworld", fw_needs)
        self.assertIn("fullcone", fw_needs)
        # firmware 是直接在 daily-build.yml 执行的 job，不再使用外部 build.yml
        self.assertNotIn("uses", fw_job)
        self.assertEqual(fw_job.get("runs-on"), "ubuntu-latest")

    def test_child_workflows_have_no_conflicting_concurrency(self):
        # 确保两个子工作流没有定义可能取消正在运行任务的 concurrency
        for name in ("build-helloworld.yml", "build-fullcone.yml"):
            path = WORKFLOWS_DIR / name
            with open(path, "r", encoding="utf-8") as fp:
                data = yaml.load(fp, Loader=UniqueKeyLoader)
            self.assertNotIn("concurrency", data, f"{name} should not define standalone concurrency")

    def test_force_rebuild_bypasses_all_skip_logic(self):
        # 验证两个组件工作流中的 skip 逻辑受 force_rebuild 严格限制
        hw_content = (WORKFLOWS_DIR / "build-helloworld.yml").read_text(encoding="utf-8")
        fc_content = (WORKFLOWS_DIR / "build-fullcone.yml").read_text(encoding="utf-8")

        for content, name in ((hw_content, "build-helloworld.yml"), (fc_content, "build-fullcone.yml")):
            # 1. 明确的跳过绕过日志
            self.assertIn(
                'echo "==> Daily/forced rebuild requested: bypassing existing component cache/release skip logic"',
                content,
                f"{name} 缺少 force_rebuild 日志提示",
            )
            # 2. 只有在 else 分支下才允许 should_build="false"
            self.assertIn('if [ "${FORCE_REBUILD}" = "true" ]; then', content)
            self.assertIn('should_build="false"', content)

    def test_build_steps_and_release_executed_on_force_rebuild(self):
        # 验证在 should_build=true 时，所有构建、校验和 Release 步骤均会执行，且支持覆写
        for name in ("build-helloworld.yml", "build-fullcone.yml"):
            with open(WORKFLOWS_DIR / name, "r", encoding="utf-8") as fp:
                data = yaml.load(fp, Loader=UniqueKeyLoader)

            steps = data["jobs"]["build"]["steps"]
            step_names = [s.get("name") for s in steps]

            # 核心构建步骤必须存在
            self.assertTrue(any("编译" in s for s in step_names), f"{name} 缺少编译步骤")
            self.assertTrue(any("验证" in s for s in step_names), f"{name} 缺少校验步骤")
            self.assertTrue(any("发布至 GitHub Releases" in s for s in step_names), f"{name} 缺少发布步骤")

            # 检查 Release 步骤必须配置 overwrite_files: true
            rel_step = next(s for s in steps if s.get("name") == "发布至 GitHub Releases")
            self.assertEqual(rel_step.get("if"), "steps.meta.outputs.should_build == 'true'")
            self.assertTrue(rel_step.get("with", {}).get("overwrite_files"))

    def test_firmware_job_assembly_only_and_single_version_resolution(self):
        content = (WORKFLOWS_DIR / "daily-build.yml").read_text(encoding="utf-8")

        # 1. 版本单次锁定断言：firmware job 直接继承 resolve-version 输出，不二次网络解析
        self.assertIn('OPENWRT_VERSION: ${{ needs.resolve-version.outputs.version }}', content)

        # 2. 严禁 SDK 下载或编译
        for forbidden in ("openwrt-sdk-x86_64", "setup-sdk.sh", "SDK_DIR"):
            # 在 firmware job 范围检查
            fw_section = content.split("firmware:")[1]
            self.assertNotIn(forbidden, fw_section)

        # 3. 严禁组件编译
        for forbidden in (
            "./scripts/build.sh",
            "components/helloworld-builder/build.sh",
            "components/fullcone-builder/build.sh",
            "components/fullcone-builder/build-luci.sh",
        ):
            self.assertNotIn(forbidden, fw_section)

        # 4. 纯装配调用与产物消费
        self.assertIn("./scripts/build-firmware.sh", fw_section)
        self.assertIn("HELLOWORLD_COMPONENT_DIR", fw_section)
        self.assertIn("FULLCONE_RUNTIME_DIR", fw_section)
        self.assertIn("FULLCONE_LUCI_DIR", fw_section)
        self.assertIn("openwrt-component-helloworld-${OPENWRT_VERSION}-x86_64.tar.gz", fw_section)
        self.assertIn("openwrt-component-fullcone-${OPENWRT_VERSION}-x86_64.tar.gz", fw_section)

    def test_publish_release_defaults_to_false(self):
        daily_path = WORKFLOWS_DIR / "daily-build.yml"
        with open(daily_path, "r", encoding="utf-8") as fp:
            data = yaml.load(fp, Loader=UniqueKeyLoader)

        triggers = data.get("on") or data.get(True)
        dispatch_inputs = triggers["workflow_dispatch"]["inputs"]
        self.assertIn("publish_release", dispatch_inputs)
        self.assertFalse(dispatch_inputs["publish_release"]["default"])

        # Release 步骤仅在显式传入 publish_release 为 true 时执行
        steps = data["jobs"]["firmware"]["steps"]
        rel_step = next(s for s in steps if s.get("name") == "自动发布 GitHub Release")
        self.assertEqual(
            rel_step.get("if"),
            "${{ github.event.inputs.publish_release == 'true' || github.event.inputs.publish_release == true }}",
        )


if __name__ == "__main__":
    unittest.main()
