#!/usr/bin/env python3
"""让官方 ImageBuilder 原样传递 APK 身份约束，不拆分摘要、不解释 shell 运算符。"""

from pathlib import Path
import sys


def configure(makefile):
    content = makefile.read_text()
    marker = "# custom-feed: APK identity constraints"
    if marker in content:
        return
    start = content.find("define FormatPackages\n")
    end = content.find("\nendef", start)
    if start < 0 or end < 0:
        raise SystemExit("错误: ImageBuilder 缺少支持的 FormatPackages，拒绝继续装配")
    original = content[start:end]
    if "$(subst =, ,$(pkg))" not in original or "$(call GetABISuffix,$(pkg_name))" not in original:
        raise SystemExit("错误: ImageBuilder FormatPackages 已变化，请检查 APK 身份约束兼容性")
    replacement = """# custom-feed: APK identity constraints
define FormatPackages
$(strip $(foreach pkg,$(strip $(subst \",,$(1))),
  $(if $(findstring @custom><Q1,$(pkg)),
    '$(pkg)',
    $(eval pkg_name:=$(firstword $(subst =, ,$(pkg))))
    $(eval pkg_ver:=)
    $(if $(findstring =,$(pkg)),$(eval pkg_ver:==$(lastword $(subst =, ,$(pkg)))))
    $(pkg_name)$(call GetABISuffix,$(pkg_name))$(pkg_ver)
  )
))"""
    makefile.write_text(content[:start] + replacement + content[end:])


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("用法: configure-imagebuilder-apk.py <ImageBuilder目录>")
    configure(Path(sys.argv[1]) / "Makefile")
