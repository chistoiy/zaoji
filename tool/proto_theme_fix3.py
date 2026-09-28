#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R39 主题轮 · 第三轮：把审计报出的"新主题比默认主题差"的四处令牌压回去。

判据是相对的（新主题不许比柿红暖纸更差），所以这里的每个值都是
拿 tool/proto_theme_audit.cjs 实测出来的比值定的，不是凭手感调的。
"""
import pathlib
import sys

P = pathlib.Path("zaoji-prototype.html")
NL = chr(10)

FIXES = [
    # 胭脂米白的琥珀偏浅，压到比默认主题更深一档
    ("--amber:#8E6419; --amber-2:#B8863A;",
     "--amber:#7E5A12; --amber-2:#A87C1E;",
     "rouge 琥珀压深"),
    # 两套深色的 muted：菜单卡上那行开饭时间比默认主题暗，提亮
    ("--ink:#F2E8D9; --ink-2:#C9B9A5; --muted:#A08E78;",
     "--ink:#F2E8D9; --ink-2:#C9B9A5; --muted:#B5A48D;",
     "night muted 再提亮"),
    ("--ink:#E3EBEA; --ink-2:#B4C2C4; --muted:#83969A;",
     "--ink:#E3EBEA; --ink-2:#B4C2C4; --muted:#95A9AD;",
     "stone muted 再提亮"),
    # 成员头像的底是**固定的饱和色**（不随主题翻），字也就不能翻：
    # 深色主题下 --on-accent 是近黑，压在深赭色头像上就是 2.9:1。
    ("font-size:19px;font-weight:700;color:var(--on-accent);" + NL + "}" + NL + ".member-nm",
     "font-size:19px;font-weight:700;color:var(--on-scrim);" + NL + "}" + NL + ".member-nm",
     "成员头像字色改回恒定浅"),
    # 做菜页计时条：底色是 rgba(ink,.93) 的"反色条"，
    # 深色主题下它是浅底，hover 再把字刷成纯白就等于看不见
    (".cook-timer .tb:hover{background:rgba(255,255,255,.2);color:#fff}",
     ".cook-timer .tb:hover{background:rgba(var(--paper-rgb),.22)}",
     "计时条 hover 不再刷白"),
]


def main() -> int:
    t = P.read_text(encoding="utf-8")
    orig = len(t)
    todo = []
    for a, b, why in FIXES:
        hits = t.count(a)
        if hits == 0 and b in t:
            print("已是修好的样子：%s" % why)
            continue
        if hits != 1:
            print("FATAL「%s」命中 %d 次，整体不落盘" % (why, hits))
            return 2
        todo.append((a, b, why))
    for a, b, why in todo:
        t = t.replace(a, b)
        print("改 1 处：%s" % why)
    if abs(len(t) - orig) / orig > 0.05:
        print("FATAL 体积变化越界")
        return 3
    P.write_text(t, encoding="utf-8")
    print("第三轮完成：%d 处" % len(todo))
    return 0


if __name__ == "__main__":
    sys.exit(main())
