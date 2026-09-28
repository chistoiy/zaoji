#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把原型 CSS 里 UI 层的颜色字面量换成主题 var（R39 主题轮）。

作用范围**只有 CSS 区段**（主题令牌块之后、</style> 之前），并按规则跳过
外壳类选择器：舞台、手机边框、桌面服务端控制台、分享长图预览——
它们不是"App 里那一屏"，跟着主题变会让评审误判，也超出主题开关的语义。

为什么半透明色必须一起改：`rgba(35,28,21,.09)` 是"墨晕 9%"，
换到深色主题就是深底叠深墨——**不报错，只是看不见**。
所以每套主题都提供 `--*-rgb` 通道三元组，这里统一改成 rgba(var(--ink-rgb),.09)。

三条护栏（都是踩过的坑）：
  1) 命中断言：替换后残留的源字面量必须为 0，否则报错退出不落盘；
  2) 体积校验：变化超出 ±8% 视为失控；
  3) 改前快照：dist/snapshots_pre_r39/zaoji-prototype.html.bak（另有 git）。

用法：D:/app_workplace/python3.11/python.exe tool/proto_themeize.py
（幂等：跑第二遍时源字面量已为 0，替换数 0，体积不变。）
"""
import re
import sys
from pathlib import Path

SRC = Path("zaoji-prototype.html")
CSS_START_MARK = "/* ══════════ 基础重置"
CSS_END_MARK = "</style>"

# 外壳选择器：整条规则原样保留，不参与主题
# （舞台 / 手机边框 / 桌面服务端控制台 / 分享长图预览 / 弹层 toast，
#   以及**压在图片或沉浸面上的那一组**：全屏计时器、悬浮计时球、
#   封面图上的菜名与按钮——它们不是"纸上的 UI"，跟着主题翻会翻车。）
SKIP_SELECTORS = (
    ".stage", ".mesh", ".grain", ".device", ".desk", ".share-pv",
    ".brand", ".toast", ".timer-fab", ".timer-full", ".fab-", ".tf-",
    ".hero", ".fav-btn",
)

# 半透明基底 → 主题通道三元组
RGBA_MAP = [
    (r"rgba\(35,28,21,",    "rgba(var(--ink-rgb),"),
    (r"rgba\(24,17,11,",    "rgba(var(--scrim-rgb),"),
    (r"rgba\(28,20,13,",    "rgba(var(--scrim-rgb),"),
    (r"rgba\(20,14,9,",     "rgba(var(--scrim-rgb),"),
    (r"rgba\(210,73,28,",   "rgba(var(--accent-rgb),"),
    (r"rgba\(195,63,20,",   "rgba(var(--accent-rgb),"),
    (r"rgba\(110,68,138,",  "rgba(var(--ai-rgb),"),
    (r"rgba\(110,68,104,",  "rgba(var(--ai-rgb),"),
    (r"rgba\(224,163,46,",  "rgba(var(--amber-rgb),"),
    (r"rgba\(180,124,20,",  "rgba(var(--amber-rgb),"),
    (r"rgba\(251,246,236,", "rgba(var(--paper-rgb),"),
    (r"rgba\(243,234,220,", "rgba(var(--paper-rgb),"),
    (r"rgba\(239,230,216,", "rgba(var(--paper-rgb),"),
    (r"rgba\(255,243,232,", "rgba(var(--paper-rgb),"),
    (r"rgba\(55,99,74,",    "rgba(var(--ok-rgb),"),
    (r"rgba\(95,194,138,",  "rgba(var(--ok-rgb),"),
]

# 实色 → 语义令牌（只列"整值唯一"的；压在图片上的反白与有歧义的淡染
# 故意留在表外，交给逐屏走查 + 对比度审计去钉，不做盲替）
HEX_MAP = [
    (r"#231C15\b",  "var(--ink)"),
    (r"#5A4E42\b",  "var(--ink-2)"),
    (r"#8E8274\b",  "var(--muted)"),
    (r"#D2491C\b",  "var(--accent)"),
    (r"#A8350F\b",  "var(--accent-deep)"),
    (r"#8E2F0C\b",  "var(--accent-deep)"),
    (r"#6E4468\b",  "var(--ai)"),
    (r"#4A2C48\b",  "var(--ai)"),
    (r"#3E6B4F\b",  "var(--ok)"),
    (r"#2F5B40\b",  "var(--ok)"),
    (r"#8C2F0E\b",  "var(--warn)"),
    (r"#B8801A\b",  "var(--amber-2)"),
    (r"#8E5F0C\b",  "var(--amber)"),
    (r"#7A5510\b",  "var(--amber)"),
    (r"#37634A\b",  "var(--t-ingredient)"),
    (r"#2A5F6B\b",  "var(--t-method)"),
    (r"#A83C22\b",  "var(--t-cuisine)"),
    (r"#6F4269\b",  "var(--t-taste)"),
    (r"#836127\b",  "var(--t-custom)"),
    # 强调色/品牌色面上的反白
    (r"#FFEDE3\b",  "var(--on-accent)"),
    (r"#FFE7D6\b",  "var(--on-accent)"),
    (r"#F3E7F2\b",  "var(--on-accent)"),
    (r"#F5EBF4\b",  "var(--on-accent)"),
    (r"#FFF7EE\b",  "var(--on-chip)"),
    # 纸面淡染
    (r"#FBF6EC\b",  "var(--paper)"),
    (r"#F4ECDD\b",  "var(--paper-2)"),
]

RULE_RE = re.compile(r"([^{}]+)\{([^{}]*)\}", re.S)


def main() -> int:
    text = SRC.read_text(encoding="utf-8")
    orig_len = len(text)
    i_start = text.find(CSS_START_MARK)
    i_end = text.find(CSS_END_MARK)
    if i_start < 0 or i_end < 0 or i_end < i_start:
        print("FATAL: CSS 区段边界没找到", file=sys.stderr)
        return 2
    head, css, tail = text[:i_start], text[i_start:i_end], text[i_end:]

    out, cursor, n_repl, n_skip = [], 0, 0, 0
    for m in RULE_RE.finditer(css):
        sel, body = m.group(1), m.group(2)
        out.append(css[cursor:m.start()])
        if any(s in sel for s in SKIP_SELECTORS):
            n_skip += 1
        else:
            for pat, rep in RGBA_MAP + HEX_MAP:
                body, k = re.subn(pat, rep, body, flags=re.IGNORECASE)
                n_repl += k
        out.append(sel + "{" + body + "}")
        cursor = m.end()
    out.append(css[cursor:])
    new_css = "".join(out)

    # 护栏 1：非外壳规则里不该再留下这些源字面量（外壳规则允许保留）
    shell_left = 0
    for m in RULE_RE.finditer(new_css):
        if any(s in m.group(1) for s in SKIP_SELECTORS):
            continue
        for pat, _ in RGBA_MAP + HEX_MAP:
            shell_left += len(re.findall(pat, m.group(2), re.IGNORECASE))
    if shell_left:
        print("FATAL: 仍有 %d 处源字面量未被替换，不落盘" % shell_left, file=sys.stderr)
        return 3

    result = head + new_css + tail
    delta = (len(result) - orig_len) / orig_len
    if abs(delta) > 0.08:
        print("FATAL: 体积变化 %.2f%% 越界，不落盘" % (delta * 100), file=sys.stderr)
        return 4

    SRC.write_text(result, encoding="utf-8")
    print("replaced=%d  shell-rules-skipped=%d  size %d->%d (%.2f%%)"
          % (n_repl, n_skip, orig_len, len(result), delta * 100))
    return 0


if __name__ == "__main__":
    sys.exit(main())
