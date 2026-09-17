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

        fc_job = jobs["fullcone"]
        self.assertEqual(fc_job.get("needs"), "resolve-version")
        self.assertEqual(fc_job.get("uses"), "./.github/workflows/build-fullcone.yml")
        self.assertEqual(fc_job.get("secrets"), "inherit")
        self.assertEqual(fc_job.get("with", {}).get("openwrt_version"), "${{ needs.resolve-version.outputs.version }}")

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

    def test_component_workflows_have_no_skip_logic_or_component_tags(self):
        # 验证两个组件工作流不存在基于旧 Release 的跳过逻辑，且不生成 component-* 标签
        for name in ("build-helloworld.yml", "build-fullcone.yml"):
            content = (WORKFLOWS_DIR / name).read_text(encoding="utf-8")
            self.assertNotIn("gh release view", content, f"{name} 不得查询旧 Release")
            self.assertNotIn("gh release download", content, f"{name} 不得下载旧 Release 进行对比")
            self.assertNotIn('should_build="false"', content, f"{name} 不得设置跳过编译")
            self.assertNotIn("tag_name=", content, f"{name} 不得管理或创建 component 标签")

    def test_component_build_steps_executed_unconditionally_and_no_component_release(self):
        # 验证核心编译与校验步骤无条件执行，且绝对不发布组件 Release
        for name in ("build-helloworld.yml", "build-fullcone.yml"):
            with open(WORKFLOWS_DIR / name, "r", encoding="utf-8") as fp:
                data = yaml.load(fp, Loader=UniqueKeyLoader)

            steps = data["jobs"]["build"]["steps"]
            step_names = [s.get("name") for s in steps]

            # 核心构建与校验步骤必须存在
            self.assertTrue(any("编译" in s for s in step_names), f"{name} 缺少编译步骤")
            self.assertTrue(any("验证" in s for s in step_names), f"{name} 缺少校验步骤")
            self.assertTrue(any("打包" in s for s in step_names), f"{name} 缺少打包步骤")
            self.assertTrue(any("上传" in s for s in step_names), f"{name} 缺少上传 Artifact 步骤")

            # 严格确保不存在组件 Release 步骤或 action-gh-release
            self.assertFalse(any("发布至 GitHub Releases" in s for s in step_names), f"{name} 严禁包含组件发布步骤")
            self.assertFalse(any(s.get("uses", "").startswith("softprops/action-gh-release") for s in steps), f"{name} 严禁使用 action-gh-release")

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

    def test_component_workflows_upload_only_final_tar_gz_artifact(self):
        # 验证 helloworld 与 fullcone Actions Artifact 仅上传最终 tar.gz，retention 为 1 天，不上传 .work 或解包目录
        component_expectations = {
            "build-helloworld.yml": "openwrt-component-helloworld-${OPENWRT_VERSION}-x86_64.tar.gz",
            "build-fullcone.yml": "openwrt-component-fullcone-${OPENWRT_VERSION}-x86_64.tar.gz",
        }

        for workflow_name, expected_archive in component_expectations.items():
            path = WORKFLOWS_DIR / workflow_name
            with open(path, "r", encoding="utf-8") as fp:
                data = yaml.load(fp, Loader=UniqueKeyLoader)

            steps = data["jobs"]["build"]["steps"]
            upload_step = next(
                s for s in steps if s.get("uses", "").startswith("actions/upload-artifact")
            )
            raw_path = upload_step.get("with", {}).get("path")
            self.assertEqual(
                raw_path,
                "${{ steps.package_step.outputs.archive_path }}",
                f"{workflow_name} actions/upload-artifact path 必须仅为 package_step archive_path",
            )
            self.assertEqual(
                upload_step.get("with", {}).get("retention-days"),
                1,
                f"{workflow_name} actions/upload-artifact retention-days 必须为 1 天",
            )

            # 验证 package_step 中 archive_path 即目标 tar.gz 文件名
            package_step = next(s for s in steps if s.get("id") == "package_step")
            package_run = package_step.get("run", "")
            self.assertIn(f'COMPONENT_ARCHIVE="{expected_archive}"', package_run)
            self.assertIn('echo "archive_path=${COMPONENT_ARCHIVE}" >> $GITHUB_OUTPUT', package_run)

            # 严格确保未包含解包目录或 .work 路径
            self.assertNotIn(".work", raw_path)
            self.assertNotIn("output_dir", raw_path)
            self.assertNotIn("runtime", raw_path)
            self.assertNotIn("luci", raw_path)
            self.assertNotIn("/*", raw_path)
            self.assertNotIn("/**", raw_path)

    def test_firmware_depends_only_on_current_run_component_tar_gz_artifact(self):
        # 验证 Firmware 装配流程严格只通过 actions/download-artifact 下载当前 run 产物并解压最终 tar.gz
        daily_path = WORKFLOWS_DIR / "daily-build.yml"
        content = daily_path.read_text(encoding="utf-8")
        fw_section = content.split("firmware:")[1]

        # 验证使用 actions/download-artifact 直接下载两个组件
        self.assertIn("uses: actions/download-artifact@v6", fw_section)
        self.assertIn("helloworld-component-${{ needs.resolve-version.outputs.version }}", fw_section)
        self.assertIn("fullcone-component-${{ needs.resolve-version.outputs.version }}", fw_section)
        self.assertIn("path: .work/artifacts/helloworld", fw_section)
        self.assertIn("path: .work/artifacts/fullcone", fw_section)

        # 验证绝对不从 GitHub Release 下载组件，严禁 gh run download 与 gh release download
        self.assertNotIn("gh run download", fw_section)
        self.assertNotIn("gh release download", fw_section)
        self.assertNotIn("GITHUB_RUN_ID", fw_section)
        self.assertNotIn('"component-helloworld-', fw_section)
        self.assertNotIn('"component-fullcone-', fw_section)

        # 验证解压并校验最终 tar.gz
        self.assertIn('tar -xzf "${HW_ARCHIVE}" -C "${HW_DIR}"', fw_section)
        self.assertIn('tar -xzf "${FC_ARCHIVE}" -C "${FC_DIR}"', fw_section)

        # 验证组件文件名
        self.assertIn("openwrt-component-helloworld-${OPENWRT_VERSION}-x86_64.tar.gz", fw_section)
        self.assertIn("openwrt-component-fullcone-${OPENWRT_VERSION}-x86_64.tar.gz", fw_section)

    def test_only_firmware_publishes_release_and_components_do_not(self):
        # 验证仅 firmware job 可以发布 GitHub Release，组件工作流绝对不发布 Release
        for name in ("build-helloworld.yml", "build-fullcone.yml"):
            with open(WORKFLOWS_DIR / name, "r", encoding="utf-8") as fp:
                data = yaml.load(fp, Loader=UniqueKeyLoader)
            steps = data["jobs"]["build"]["steps"]
            self.assertFalse(any(s.get("uses", "").startswith("softprops/action-gh-release") for s in steps))

        with open(WORKFLOWS_DIR / "daily-build.yml", "r", encoding="utf-8") as fp:
            daily_data = yaml.load(fp, Loader=UniqueKeyLoader)
        fw_steps = daily_data["jobs"]["firmware"]["steps"]
        rel_steps = [s for s in fw_steps if s.get("uses", "").startswith("softprops/action-gh-release")]
        self.assertEqual(len(rel_steps), 1, "daily-build.yml 中 firmware 必须有且仅有 1 个 Release 步骤")

    def test_requirement_14_contract_verifications(self):
        # 针对需求 14 的显式契约断言汇总
        daily_content = (WORKFLOWS_DIR / "daily-build.yml").read_text(encoding="utf-8")
        hw_content = (WORKFLOWS_DIR / "build-helloworld.yml").read_text(encoding="utf-8")
        fc_content = (WORKFLOWS_DIR / "build-fullcone.yml").read_text(encoding="utf-8")

        with open(WORKFLOWS_DIR / "daily-build.yml", "r", encoding="utf-8") as fp:
            daily_data = yaml.load(fp, Loader=UniqueKeyLoader)

        jobs = daily_data["jobs"]

        # 1. 主 workflow 中不存在 component Release 创建逻辑
        self.assertNotIn("action-gh-release", hw_content)
        self.assertNotIn("action-gh-release", fc_content)
        daily_releases = [s for s in jobs["firmware"]["steps"] if "action-gh-release" in s.get("uses", "")]
        self.assertEqual(len(daily_releases), 1)

        # 2. Firmware 不从 Release 下载组件，严禁 gh run download 与 gh release download
        fw_section = daily_content.split("firmware:")[1]
        self.assertNotIn("gh release download", fw_section)
        self.assertNotIn("gh run download", fw_section)
        self.assertNotIn("GITHUB_RUN_ID", fw_section)
        self.assertNotIn('"component-helloworld-', fw_section)
        self.assertNotIn('"component-fullcone-', fw_section)

        # 3. helloworld/fullcone 必须是 Firmware 的 needs
        fw_needs = jobs["firmware"]["needs"]
        self.assertIn("helloworld", fw_needs)
        self.assertIn("fullcone", fw_needs)

        # 4. 两个组件并行 (均仅以 resolve-version 为前置)
        self.assertEqual(jobs["helloworld"]["needs"], "resolve-version")
        self.assertEqual(jobs["fullcone"]["needs"], "resolve-version")

        # 5. Firmware 必须包含 actions/download-artifact，且两个 Artifact name 均来自同一个 resolve-version
        fw_steps = jobs["firmware"]["steps"]
        dl_steps = [s for s in fw_steps if "actions/download-artifact" in s.get("uses", "")]
        self.assertEqual(len(dl_steps), 2, "Firmware 必须包含 2 个 actions/download-artifact 步骤")
        dl_names = [s.get("with", {}).get("name") for s in dl_steps]
        self.assertIn("helloworld-component-${{ needs.resolve-version.outputs.version }}", dl_names)
        self.assertIn("fullcone-component-${{ needs.resolve-version.outputs.version }}", dl_names)
        self.assertIn('tar -xzf "${HW_ARCHIVE}" -C "${HW_DIR}"', fw_section)
        self.assertIn('tar -xzf "${FC_ARCHIVE}" -C "${FC_DIR}"', fw_section)

        # 6. upload-artifact 不包含 .work 或原始 APK / 解包目录，且 retention 为 1 天
        for c_content in (hw_content, fc_content):
            self.assertIn("uses: actions/upload-artifact@v6", c_content)
            self.assertIn("path: ${{ steps.package_step.outputs.archive_path }}", c_content)
            self.assertIn("retention-days: 1", c_content)
            self.assertNotIn(".work", c_content.split("actions/upload-artifact@v6")[1].split("retention-days")[0])

        # 7. Firmware workflow 不包含 SDK/component builder 调用
        for forbidden in (
            "setup-sdk.sh",
            "openwrt-sdk-x86_64",
            "SDK_DIR",
            "components/helloworld-builder",
            "components/fullcone-builder",
        ):
            self.assertNotIn(forbidden, fw_section)


if __name__ == "__main__":
    unittest.main()
