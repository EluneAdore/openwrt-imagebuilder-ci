#!/usr/bin/env python3
"""Validate the transitive FullCone package build dependencies."""

from pathlib import Path
import re
import sys


FIREWALL4 = "$(curdir)/feeds/base/firewall4/compile"
NFTABLES = "$(curdir)/feeds/base/nftables/compile"
LIBNFTNL = "$(curdir)/feeds/base/libnftnl/compile"
FULLCONE = "$(curdir)/fullcone/fullconenat-nft/compile"
LINUX = "$(curdir)/kernel/linux/compile"

TARGET_RE = re.compile(r"^\$\(curdir\)/[^\s(),]+/compile$")


def parse_dependencies(text: str) -> dict[str, set[str]]:
    dependencies: dict[str, set[str]] = {}
    for line in text.splitlines():
        if "/compile +=" not in line:
            continue
        target, prerequisites = line.split(" +=", 1)
        if not TARGET_RE.fullmatch(target):
            continue
        dependencies.setdefault(target, set()).update(
            prerequisite
            for prerequisite in prerequisites.split()
            if TARGET_RE.fullmatch(prerequisite)
        )
    return dependencies


def reachable(dependencies: dict[str, set[str]], start: str) -> set[str]:
    closure: set[str] = set()
    pending = [start]
    while pending:
        target = pending.pop()
        if target in closure:
            continue
        closure.add(target)
        pending.extend(dependencies.get(target, ()))
    return closure


def validate_dependencies(dependencies: dict[str, set[str]]) -> None:
    required_nodes = (FIREWALL4, NFTABLES, LIBNFTNL, FULLCONE, LINUX)
    missing_nodes = [node for node in required_nodes if node not in dependencies]
    if missing_nodes:
        raise ValueError(
            "FullCone package DAG 缺少目标: " + ", ".join(missing_nodes)
        )

    firewall4_closure = reachable(dependencies, FIREWALL4)
    for node in (NFTABLES, FULLCONE, LINUX):
        if node not in firewall4_closure:
            raise ValueError(f"FullCone package DAG 从 {FIREWALL4} 无法到达 {node}")

    nftables_closure = reachable(dependencies, NFTABLES)
    if LIBNFTNL not in nftables_closure:
        raise ValueError(f"FullCone package DAG 从 {NFTABLES} 无法到达 {LIBNFTNL}")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"用法: {Path(argv[0]).name} PACKAGedeps", file=sys.stderr)
        return 2

    path = Path(argv[1])
    if not path.is_file():
        print(f"SDK 未生成 {path}", file=sys.stderr)
        return 1

    try:
        validate_dependencies(parse_dependencies(path.read_text()))
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
