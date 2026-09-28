#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R39 · 把 ZaojiText.display/body 的调用点改成带 context 的版本。

为什么单独一刀：真产物截图（tool/app_theme_shots.cjs）在夜灶暖光下发现
**菜名几乎看不见**——`ZaojiText.display(fontSize: …)` 不传 color 时，
默认值是"默认那套主题的墨色"（编译期常量，翻不过来）。
不带 context 的工厂函数改不动这件事，所以补 `displayOf/bodyOf`，
默认色取当前主题的 ink；调用点统一换过去。

复用 app_theme_codemod 的作用域判断（同一套"这里有没有 context"的规矩），
判不出来的原样留着并打印，交给人看。

用法：D:/app_workplace/python3.11/python.exe tool/app_text_ctx_codemod.py [--dry]
"""
import pathlib
import re
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
from app_theme_codemod import has_context  # noqa: E402

FILES = sorted(pathlib.Path("app/lib/ui").glob("*.dart")) + \
    sorted(pathlib.Path("app/lib/widgets").glob("*.dart")) + \
    [pathlib.Path("app/lib/main.dart")]

CALL = re.compile(r"\bZaojiText\.(display|body)\(")


def main() -> int:
    dry = "--dry" in sys.argv
    total = 0
    orphans = []
    for path in FILES:
        src = path.read_text(encoding="utf-8")
        out = src
        n = 0
        for m in reversed(list(CALL.finditer(src))):
            if not has_context(out, m.start()):
                orphans.append((path.name, out[:m.start()].count("\n") + 1,
                                m.group(0)))
                continue
            kind = m.group(1)
            out = (out[:m.start()] + "ZaojiText.%sOf(context, " % kind
                   + out[m.end():])
            n += 1
        total += n
        if n:
            print("%-34s %d 处" % (path.name, n))
            if not dry:
                path.write_text(out, encoding="utf-8")
    print("合计 %d 处%s" % (total, "（dry）" if dry else ""))
    if orphans:
        print("== 拿不到 context、原样留着 ==")
        for name, line, ref in orphans:
            print("  %s:%d %s" % (name, line, ref))
    return 0


if __name__ == "__main__":
    sys.exit(main())
