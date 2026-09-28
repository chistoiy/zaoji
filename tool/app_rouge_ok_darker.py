#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R39 · 胭脂米白的「充足绿」压深一档。

审计（基线已换成默认的蓝染粗布）报出唯一一处真退化：
rouge 的 badge-ok 文字 #3A6B4E 压在 ok-bg 上只有 4.36，而默认那套同一处是 5.12。
判据是"新主题不许比默认差"，所以把它压到 #2F6247（实测 5.00）。

两边一起改：原型 `[data-theme="rouge"]` 与 Dart 的 ZaojiTokens.rouge——
`app/test/theme_test.dart` 会逐令牌比对 ok 这一项，漏改一边就红。
"""
import pathlib
import sys

NL = chr(10)

PAIRS = [
    ("zaoji-prototype.html",
     "  --ok:#3A6B4E; --ok-bg:rgba(58,107,78,.12);",
     "  --ok:#2F6247; --ok-bg:rgba(47,98,71,.13);"),
    ("app/lib/theme.dart",
     "    ok: Color(0xFF3A6B4E)," + NL + "    okBg: Color(0x1F3A6B4E),",
     "    ok: Color(0xFF2F6247)," + NL + "    okBg: Color(0x212F6247),"),
]


def main() -> int:
    for rel, a, b in PAIRS:
        p = pathlib.Path(rel)
        t = p.read_text(encoding="utf-8")
        if t.count(a) != 1:
            raise SystemExit("FATAL %s hits=%d" % (rel, t.count(a)))
        p.write_text(t.replace(a, b), encoding="utf-8")
        print("ok", rel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
