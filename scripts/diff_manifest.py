#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
OpenWrt Manifest 比对与变动分析工具 (diff_manifest.py)
用途:
1. 比对上一次与本次固件生成的 *.manifest 软件包清单
2. 输出新增、移除、升级/降级的软件包列表
3. 生成 manifest.diff (纯文本)、manifest.md (Markdown)
4. 支持自动注入 GitHub Actions $GITHUB_STEP_SUMMARY 与 Release Notes
"""

import sys
import os
import glob
import argparse


def parse_manifest(filepath):
    """解析 manifest 文件，返回字典 {pkg_name: version}"""
    packages = {}
    if not filepath or not os.path.isfile(filepath):
        return packages

    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if " - " in line:
                parts = line.split(" - ", 1)
                packages[parts[0].strip()] = parts[1].strip()
            elif " " in line:
                parts = line.split(None, 1)
                packages[parts[0].strip()] = parts[1].strip()
    return packages


def find_file(path_pattern):
    """根据路径模式查找文件，支持通配符"""
    if not path_pattern:
        return None
    matches = glob.glob(path_pattern)
    if matches:
        return sorted(matches)[0]
    return None


def generate_diff(prev_pkgs, curr_pkgs):
    """比对新旧版本字典，分类返回差异"""
    all_names = sorted(set(prev_pkgs.keys()) | set(curr_pkgs.keys()))

    added = []       # [(pkg, curr_ver)]
    removed = []     # [(pkg, prev_ver)]
    changed = []     # [(pkg, prev_ver, curr_ver)]
    unchanged = []   # [(pkg, curr_ver)]

    for name in all_names:
        in_prev = name in prev_pkgs
        in_curr = name in curr_pkgs

        if in_curr and not in_prev:
            added.append((name, curr_pkgs[name]))
        elif in_prev and not in_curr:
            removed.append((name, prev_pkgs[name]))
        else:
            p_ver = prev_pkgs[name]
            c_ver = curr_pkgs[name]
            if p_ver != c_ver:
                changed.append((name, p_ver, c_ver))
            else:
                unchanged.append((name, c_ver))

    return added, removed, changed, unchanged


def build_markdown_report(added, removed, changed, unchanged, curr_count, is_first_run=False):
    """构建用于 GitHub Step Summary 与 Release 说明的 Markdown 报告"""
    lines = []
    lines.append("### 📦 固件软件包变动报告 (Manifest Diff)")
    lines.append("")

    if is_first_run:
        lines.append("> [!NOTE]")
        lines.append(f"> 首次记录构建基准，本次固件共集成 **{curr_count}** 个软件包。已保存为后续比对基准。")
        lines.append("")
        return "\n".join(lines)

    total_changes = len(added) + len(removed) + len(changed)
    if total_changes == 0:
        lines.append("> [!NOTE]")
        lines.append(f"> ✨ **所有软件包与上次构建完全一致**（共 **{curr_count}** 个组件，无任何版本变动）。")
        lines.append("")
        return "\n".join(lines)

    # 统计概览
    lines.append(
        f"- **总包数**: `{curr_count}` | **变动总数**: `{total_changes}` "
        f"(🔼 升级/变更: `{len(changed)}` | ➕ 新增: `{len(added)}` | ➖ 移除: `{len(removed)}` | ⏸ 保持: `{len(unchanged)}`)"
    )
    lines.append("")
    lines.append("| 变动类型 | 软件包名称 | 上次版本 | 本次版本 |")
    lines.append("| :--- | :--- | :--- | :--- |")

    for name, p_ver, c_ver in changed:
        lines.append(f"| 🔼 **版本变更** | `{name}` | `{p_ver}` | `{c_ver}` |")

    for name, c_ver in added:
        lines.append(f"| ➕ **新增组件** | `{name}` | — | `{c_ver}` |")

    for name, p_ver in removed:
        lines.append(f"| ➖ **移除组件** | `{name}` | `{p_ver}` | — |")

    lines.append("")

    # 折叠展示未变动组件
    if unchanged:
        lines.append(f"<details><summary><b>点击展开未变动组件清单 ({len(unchanged)} 个)</b></summary>")
        lines.append("")
        lines.append("| 软件包名称 | 当前版本 |")
        lines.append("| :--- | :--- |")
        for name, ver in unchanged:
            lines.append(f"| `{name}` | `{ver}` |")
        lines.append("</details>")
        lines.append("")

    return "\n".join(lines)


def build_text_diff(added, removed, changed, unchanged, curr_count, is_first_run=False):
    """构建纯文本 diff 格式"""
    lines = []
    lines.append("=" * 70)
    lines.append("OpenWrt 固件软件包清单变动对比报告 (Manifest Diff)")
    lines.append("=" * 70)

    if is_first_run:
        lines.append("状态: 首次构建记录（未发现历史比对基准）。")
        lines.append(f"本次固件集成软件包总数: {curr_count}")
        lines.append("=" * 70)
        return "\n".join(lines)

    total_changes = len(added) + len(removed) + len(changed)
    lines.append(f"软件包总数: {curr_count} (变动项: {total_changes}, 保持未变: {len(unchanged)})")
    lines.append(f"🔼 变更/升级: {len(changed)} | ➕ 新增: {len(added)} | ➖ 移除: {len(removed)}")
    lines.append("-" * 70)

    if total_changes == 0:
        lines.append("✨ 未检测到任何变动，所有软件包版本与上次构建完全一致。")
        lines.append("=" * 70)
        return "\n".join(lines)

    if changed:
        lines.append("\n[🔼 版本变更 / 升级]")
        for name, p_ver, c_ver in changed:
            lines.append(f"  * {name}: {p_ver} -> {c_ver}")

    if added:
        lines.append("\n[➕ 新增软件包]")
        for name, c_ver in added:
            lines.append(f"  + {name}: {c_ver}")

    if removed:
        lines.append("\n[➖ 移除软件包]")
        for name, p_ver in removed:
            lines.append(f"  - {name}: {p_ver}")

    lines.append("\n" + "=" * 70)
    return "\n".join(lines)


def print_terminal_summary(added, removed, changed, unchanged, curr_count, is_first_run=False):
    """在终端输出美观、带色彩的统计与差异概览"""
    # 终端颜色代码 (TTY 判断)
    is_tty = sys.stdout.isatty()
    C_GREEN = "\033[32m" if is_tty else ""
    C_RED = "\033[31m" if is_tty else ""
    C_YELLOW = "\033[33m" if is_tty else ""
    C_CYAN = "\033[36m" if is_tty else ""
    C_BOLD = "\033[1m" if is_tty else ""
    C_RESET = "\033[0m" if is_tty else ""

    print(f"\n{C_BOLD}==> 软件包清单对比分析 (Manifest Diff):{C_RESET}")
    if is_first_run:
        print(f"  {C_CYAN}ℹ 首次记录构建基准{C_RESET}，本次固件共纳入 {C_BOLD}{curr_count}{C_RESET} 个软件包。")
        return

    total_changes = len(added) + len(removed) + len(changed)
    if total_changes == 0:
        print(f"  {C_GREEN}✓ 与上次构建完全一致{C_RESET} (共 {curr_count} 个软件包，无增减或版本变化)。")
        return

    print(f"  {C_BOLD}总包数:{C_RESET} {curr_count} | {C_BOLD}变动项:{C_RESET} {total_changes} "
          f"({C_YELLOW}🔼 变更: {len(changed)}{C_RESET} | "
          f"{C_GREEN}➕ 新增: {len(added)}{C_RESET} | "
          f"{C_RED}➖ 移除: {len(removed)}{C_RESET} | "
          f"⏸ 保持: {len(unchanged)})")

    if changed:
        print(f"\n  {C_YELLOW}[版本变更 ({len(changed)})]:{C_RESET}")
        for name, p_ver, c_ver in changed:
            print(f"    * {C_BOLD}{name}{C_RESET}: {p_ver} -> {C_YELLOW}{c_ver}{C_RESET}")

    if added:
        print(f"\n  {C_GREEN}[新增软件包 ({len(added)})]:{C_RESET}")
        for name, c_ver in added:
            print(f"    + {C_GREEN}{name}{C_RESET} ({c_ver})")

    if removed:
        print(f"\n  {C_RED}[移除软件包 ({len(removed)})]:{C_RESET}")
        for name, p_ver in removed:
            print(f"    - {C_RED}{name}{C_RESET} ({p_ver})")
    print("")


def main():
    parser = argparse.ArgumentParser(description="OpenWrt 固件软件包清单 (.manifest) 差异对比分析工具")
    parser.add_argument("previous", help="历史版本 manifest 清单文件路径或通配符模式")
    parser.add_argument("current", help="本次构建 manifest 清单文件路径或通配符模式")
    parser.add_argument("--output-diff", help="输出纯文本差异对比报告的目标文件路径", default=None)
    parser.add_argument("--output-md", help="输出 Markdown 格式差异报告的目标文件路径", default=None)
    parser.add_argument("--summary", action="store_true", help="若检测到 GitHub Actions 环境，自动将报告追加至 $GITHUB_STEP_SUMMARY")

    args = parser.parse_args()

    prev_path = find_file(args.previous)
    curr_path = find_file(args.current)

    if not curr_path or not os.path.isfile(curr_path):
        print(f"错误: 未找到当前清单文件: '{args.current}'", file=sys.stderr)
        sys.exit(1)

    curr_pkgs = parse_manifest(curr_path)
    is_first_run = False

    if not prev_path or not os.path.isfile(prev_path):
        is_first_run = True
        prev_pkgs = {}
    else:
        prev_pkgs = parse_manifest(prev_path)

    added, removed, changed, unchanged = generate_diff(prev_pkgs, curr_pkgs)

    # 1. 终端美化打印
    print_terminal_summary(added, removed, changed, unchanged, len(curr_pkgs), is_first_run)

    # 2. 写入纯文本 diff 文件
    if args.output_diff:
        text_diff = build_text_diff(added, removed, changed, unchanged, len(curr_pkgs), is_first_run)
        os.makedirs(os.path.dirname(os.path.abspath(args.output_diff)), exist_ok=True)
        with open(args.output_diff, "w", encoding="utf-8") as f:
            f.write(text_diff)
        print(f"  [+] 纯文本报告已生成: {args.output_diff}")

    # 3. 写入 Markdown diff 文件
    md_report = build_markdown_report(added, removed, changed, unchanged, len(curr_pkgs), is_first_run)
    if args.output_md:
        os.makedirs(os.path.dirname(os.path.abspath(args.output_md)), exist_ok=True)
        with open(args.output_md, "w", encoding="utf-8") as f:
            f.write(md_report)
        print(f"  [+] Markdown 报告已生成: {args.output_md}")

    # 4. 写入 GitHub Actions Step Summary
    if args.summary:
        summary_file = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary_file:
            try:
                with open(summary_file, "a", encoding="utf-8") as f:
                    f.write("\n" + md_report + "\n")
                print("  [+] 已写入 GitHub Step Summary")
            except Exception as e:
                print(f"  [-] 写入 Step Summary 失败: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()

