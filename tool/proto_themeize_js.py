#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R39 主题轮 · JS 段里 style="..." 的颜色收进主题令牌。

只动 style 属性内部，**绝不动 SVG 的 fill/stroke 属性**：
那两类字面量看起来一模一样（#3E6B4F 既出现在 style="color:" 里，
也出现在插画调色板 pal:[...] 里），但语义完全相反——
前者是"纸上的 UI 字色"，必须随主题翻；后者是"这道菜这幅画的配色"，
五套主题下都应该长一样，翻了插画就花了。

用法：D:/app_workplace/python3.11/python.exe tool/proto_themeize_js.py
"""
import pathlib
import re
import sys

P = pathlib.Path("zaoji-prototype.html")

# style 属性内部：整值唯一 → 令牌
STYLE_MAP = [
    (r"#2F5B40\b", "var(--ok)"),
    (r"#3E6B4F\b", "var(--ok)"),
    (r"#D2491C\b", "var(--accent)"),
    (r"#A8350F\b", "var(--accent-deep)"),
    (r"#8E2F0C\b", "var(--accent-deep)"),
    (r"#6E4468\b", "var(--ai)"),
    (r"#4A2C48\b", "var(--ai)"),
    (r"#8E8274\b", "var(--muted)"),
    (r"#231C15\b", "var(--ink)"),
    (r"#5A4E42\b", "var(--ink-2)"),
    (r"#4A4034\b", "var(--ink-2)"),
    (r"#FBF6EC\b", "var(--paper)"),
    (r"#F4ECDD\b", "var(--paper-2)"),
    (r"#FFF7E9\b", "var(--tint)"),
    (r"#FFF3E8\b", "var(--tint-2)"),
    (r"#FFF3EA\b", "var(--on-accent)"),
    (r"#2A5F6B\b", "var(--t-method)"),
    (r"#37634A\b", "var(--t-ingredient)"),
    (r"rgba\(55,99,74,", "rgba(var(--ok-rgb),"),
    (r"rgba\(110,68,138,", "rgba(var(--ai-rgb),"),
    (r"rgba\(210,73,28,", "rgba(var(--accent-rgb),"),
    (r"rgba\(35,28,21,", "rgba(var(--ink-rgb),"),
    (r"rgba\(62,107,79,", "rgba(var(--ok-rgb),"),
]

STYLE_RE = re.compile(r'style="[^"]*"')


def main() -> int:
    t = P.read_text(encoding="utf-8")
    orig = len(t)
    i = t.find("</style>")
    head, js = t[:i], t[i:]

    n = 0
    skipped = 0

    def fix(m):
        nonlocal n, skipped
        s = m.group(0)
        # 左侧「设计定调」面板里的色卡是在**展示这五个字面量本身**
        # （纸/墨/柿红……），把它们换成 var 就等于把说明书变成了自我指涉。
        before = js[max(0, m.start() - 80):m.start()]
        if 'class="swatch"' in before or 'data-label=' in before:
            skipped += 1
            return s
        for pat, rep in STYLE_MAP:
            s, k = re.subn(pat, rep, s, flags=re.IGNORECASE)
            n += k
        return s

    js2 = STYLE_RE.sub(fix, js)
    out = head + js2
    if abs(len(out) - orig) / orig > 0.05:
        print("FATAL 体积变化越界，不落盘")
        return 3
    P.write_text(out, encoding="utf-8")
    print("style 属性内替换 %d 处，跳过色卡 %d 处（SVG fill/stroke 与插画调色板未动）" % (n, skipped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
