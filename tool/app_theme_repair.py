#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修 app_theme_sweep 自己造成的伤口。

`WHITE_LINE.sub("color: context.zj.surface", ...)` 这个写法把**整个匹配**
（含行首缩进和行尾逗号）换掉了，于是 22 处变成"顶格 + 少一个逗号"。
analyze 立刻抓到（Expected to find ','），这正是"改完必须跑静态检查"的意义。

修法：把被压成一行、顶格、无逗号的 `color: context.zj.xxx` 还原成
下一行的缩进 + 原样 + 逗号。
"""
import pathlib
import re
import sys

BROKEN = re.compile(r"^color: context\.zj\.(surface|onAccent)$", re.M)


def main() -> int:
    total = 0
    for path in sorted(pathlib.Path("app/lib/ui").glob("*.dart")):
        src = path.read_text(encoding="utf-8")
        lines = src.split("\n")
        out = []
        n = 0
        for i, ln in enumerate(lines):
            m = BROKEN.match(ln)
            if not m:
                out.append(ln)
                continue
            # 用下一行的缩进对齐（下一行就是被逗号隔开的那个兄弟参数）
            nxt = lines[i + 1] if i + 1 < len(lines) else "        "
            indent = nxt[: len(nxt) - len(nxt.lstrip())]
            out.append("%scolor: context.zj.%s," % (indent, m.group(1)))
            n += 1
        if n:
            path.write_text("\n".join(out), encoding="utf-8")
            print("%-34s 还原 %d 处" % (path.name, n))
            total += n
    print("合计还原 %d 处" % total)
    return 0 if total else 0


if __name__ == "__main__":
    sys.exit(main())
