#!/usr/bin/env python3
"""检查源码或 APK 中的兼容修复，并用隔离命令验证运行行为。"""

import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


PACKAGE_ROOT = Path(sys.argv.pop(1))
REPO_ROOT = Path(__file__).resolve().parents[3]
if (PACKAGE_ROOT / "luasrc").is_dir():
    CONTROLLER = PACKAGE_ROOT / "luasrc/controller/shadowsocksr.lua"
    MODEL = PACKAGE_ROOT / "luasrc/model/cbi/shadowsocksr/component.lua"
    RULES = PACKAGE_ROOT / "root/usr/bin/ssr-rules"
else:
    CONTROLLER = PACKAGE_ROOT / "usr/lib/lua/luci/controller/shadowsocksr.lua"
    MODEL = PACKAGE_ROOT / "usr/lib/lua/luci/model/cbi/shadowsocksr/component.lua"
    RULES = PACKAGE_ROOT / "usr/bin/ssr-rules"
SHELL_CMD = [os.environ["BUSYBOX"], "sh"] if os.environ.get("BUSYBOX") else ["sh"]


def function(text, name):
    match = re.search(r"^" + name + r"\(\) \{\n.*?^\}", text, re.M | re.S)
    if not match:
        raise AssertionError(f"缺少函数：{name}")
    return match.group()


IP_MOCK = r'''
ip() {
    case "$*" in
        'route show table 999')
            case "$POLICY_STATE" in
                missing) printf 'Error: ipv4: FIB table does not exist.\nDump terminated\n' >&2; return 2 ;;
                empty) return 0 ;;
                present) printf 'local default dev lo scope host\n' ;;
                error) printf 'RTNETLINK answers: Operation not permitted\n' >&2; return 2 ;;
            esac ;;
        'route add local 0.0.0.0/0 dev lo table 999'|'route del local 0.0.0.0/0 dev lo table 999')
            printf '%s\n' "$*" >> "$IP_ACTION_LOG"
            if [ "$FAIL_OPERATION" = 1 ]; then
                printf 'RTNETLINK answers: Operation not permitted\n' >&2
                return 2
            fi ;;
        *) printf '意外的 ip 调用：%s\n' "$*" >&2; return 2 ;;
    esac
}
'''


class RuntimeFixTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.rules = RULES.read_text()

    def test_component_form_route(self):
        controller = CONTROLLER.read_text()
        self.assertRegex(MODEL.read_text(), r"\bSimpleForm\s*\(")
        self.assertRegex(controller, r'entry\(\{"admin", "services", "shadowsocksr", "component"\},\s*form\("shadowsocksr/component"\)')
        self.assertNotIn('cbi("shadowsocksr/component")', controller)

    def test_logger_preserves_message_and_option_boundary(self):
        message = "-> 白名单 changed: '*.apk' -p user.err"
        script = 'logger() { printf "%s\\n" "$@"; }\n'
        script += function(self.rules, "loger") + '\nloger 6 "$TEST_MESSAGE"\n'
        result = subprocess.run([*SHELL_CMD, "-c", script], env={**os.environ, "TEST_MESSAGE": message}, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        args = result.stdout.splitlines()
        self.assertEqual(args[:2], ["-s", "-t"])
        self.assertRegex(args[2], r"^ssr-rules\[\d+\]$")
        self.assertEqual(args[3:], ["-p", "6", "--", message])

    @unittest.skipUnless(os.environ.get("BUSYBOX"), "未指定 BusyBox 二进制")
    def test_busybox_logger(self):
        messages = ["list changed: 'a' -> 'b'", "-> leading arrow", "-p user.err * 中文"]
        script = 'logger() { "$BUSYBOX" logger "$@"; }\n'
        script += function(self.rules, "loger") + '\nloger 6 "$TEST_MESSAGE"\n'
        for message in messages:
            with self.subTest(message=message):
                result = subprocess.run([os.environ["BUSYBOX"], "sh", "-c", script], env={**os.environ, "TEST_MESSAGE": message}, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(message, result.stderr)
                self.assertNotIn("unrecognized option", result.stderr)

    def run_route(self, block, state, fail=False):
        with tempfile.TemporaryDirectory(prefix="ssr-route-test-") as tmp:
            actions = Path(tmp) / "actions"
            env = {**os.environ, "POLICY_STATE": state, "FAIL_OPERATION": str(int(fail)), "IP_ACTION_LOG": str(actions)}
            script = IP_MOCK + function(self.rules, "policy_route_exists")
            script += "\nexercise() {\n" + block + "\n}\nexercise\n"
            result = subprocess.run([*SHELL_CMD, "-c", script], env=env, capture_output=True, text=True)
            trace = actions.read_text().splitlines() if actions.exists() else []
            return result, trace

    def test_policy_route_probe(self):
        for state, expected in [("missing", 1), ("empty", 1), ("present", 0), ("error", 2)]:
            with self.subTest(state=state):
                result, actions = self.run_route("policy_route_exists", state)
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertEqual(actions, [])
                if state == "error":
                    self.assertIn("Operation not permitted", result.stderr)
                else:
                    self.assertEqual(result.stderr, "")

    def test_policy_route_callers(self):
        # 执行四个实际调用点的路由分支，隔离防火墙及文件系统操作。
        callers = [("flush_nftables", "del"), ("flush_iptables_legacy", "del"), ("tp_rule_nft", "add"), ("tp_rule_iptables", "add")]
        self.assertEqual(self.rules.count("ip route show table 999"), 1)
        for name, operation in callers:
            body = function(self.rules, name)
            match = re.search(r"\tif policy_route_exists; then\n.*?\n\tfi", body, re.S)
            self.assertIsNotNone(match, name)
            block = match.group() + "\nreturn 0"
            for state in ["missing", "empty", "present", "error"]:
                with self.subTest(caller=name, state=state):
                    result, actions = self.run_route(block, state)
                    if state == "error":
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("Operation not permitted", result.stderr)
                        self.assertEqual(actions, [])
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stderr, "")
                        expected_action = (operation == "del" and state == "present") or (operation == "add" and state != "present")
                        self.assertEqual(actions, [f"route {operation} local 0.0.0.0/0 dev lo table 999"] if expected_action else [])
            with self.subTest(caller=name, failure=True):
                result, actions = self.run_route(block, "present" if operation == "del" else "missing", fail=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Operation not permitted", result.stderr)
                self.assertEqual(len(actions), 1)

    def test_ssh_defaults(self):
        defaults = (REPO_ROOT / "files/etc/uci-defaults/99-custom-defaults").read_text()
        start = defaults.index("if uci -q get dropbear.main")
        end = defaults.index("# 6. 系统时区", start)
        script = "\n".join(function(defaults, name) for name in ["fail", "uci_set", "uci_delete"])
        script += "\n" + defaults[start:end]
        for section in ["dropbear.main", "dropbear.@dropbear[0]"]:
            for existing_interface in [True, False]:
                with self.subTest(section=section, existing_interface=existing_interface), tempfile.TemporaryDirectory(prefix="ssh-defaults-test-") as tmp:
                    state_file = Path(tmp) / "uci.json"
                    initial = {section: "dropbear"}
                    if existing_interface:
                        initial[section + ".Interface"] = "lan"
                    state_file.write_text(json.dumps(initial))
                    mock = Path(tmp) / "uci"
                    mock.write_text('''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
state_file = Path(os.environ["UCI_TEST_STATE"])
state = json.loads(state_file.read_text())
args = sys.argv[1:]
if args[0] == "-q": args.pop(0)
command, key = args
if command == "get":
    if key not in state: sys.exit(1)
    print(state[key])
elif command == "set":
    key, value = key.split("=", 1)
    state[key] = value
elif command == "delete":
    del state[key]
else: sys.exit(2)
state_file.write_text(json.dumps(state))
''')
                    mock.chmod(0o755)
                    env = {**os.environ, "PATH": tmp + os.pathsep + os.environ["PATH"], "UCI_TEST_STATE": str(state_file)}
                    result = subprocess.run([*SHELL_CMD, "-c", script], env=env, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    state = json.loads(state_file.read_text())
                    self.assertNotIn(section + ".Interface", state)
                    self.assertEqual(state[section + ".DirectInterface"], "lan")
                    self.assertEqual(state[section + ".PasswordAuth"], "off")
                    self.assertEqual(state[section + ".RootPasswordAuth"], "off")


if __name__ == "__main__":
    unittest.main(verbosity=2)
