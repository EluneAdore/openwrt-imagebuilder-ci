#!/usr/bin/env python3
"""Locate prepared nftables-json source roots in an OpenWrt SDK build_dir."""

from __future__ import annotations

import argparse
from pathlib import Path


SOURCE_MARKERS = (
    Path("src/parser_bison.y"),
    Path("src/scanner.l"),
    Path("src/statement.c"),
)


def find_nftables_build_roots(build_dir: Path) -> list[Path]:
    roots: list[Path] = []

    if not build_dir.is_dir():
        return roots

    for target_dir in sorted(build_dir.glob("target-*")):
        package_dir = target_dir / "nftables-json"
        if not package_dir.is_dir():
            continue

        for candidate in sorted(package_dir.glob("nftables-*")):
            if not candidate.is_dir():
                continue
            if all((candidate / marker).is_file() for marker in SOURCE_MARKERS):
                roots.append(candidate)

    return roots


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("build_dir", type=Path)
    args = parser.parse_args()

    for root in find_nftables_build_roots(args.build_dir):
        print(root)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
