#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R39 主题轮 · 第二轮定向修：审计点名的"强调色面上的反白"与渐变端点收进令牌。

为什么逐条写整段而不是全局替换：同一片色值在不同选择器下语义不同——
#FFF3EA 在按钮上是"强调色上的字"（要随主题翻成近黑），
在封面图/沉浸面上是"压暗层上的字"（**刻意不随主题翻**，见 CSS 里 --scrim-rgb 注释）。
盲替会把后者一起翻错。

每条都要求"恰好命中一次"，任何一条不对就整体不落盘。
用法：D:/app_workplace/python3.11/python.exe tool/proto_theme_fix2.py
"""
import pathlib
import sys

P = pathlib.Path("zaoji-prototype.html")

FIXES = [
    # —— 统计条/匹配条的渐变末端：跟着自己的主色提亮，不再钉死一个橙/绿 ——
    ("background:linear-gradient(90deg,var(--accent),#E0703B)",
     "background:linear-gradient(90deg,var(--accent),color-mix(in srgb, var(--accent) 62%, #fff))",
     "统计条渐变末端"),
    ("background:linear-gradient(90deg,var(--t-ingredient),#5A9A6E)",
     "background:linear-gradient(90deg,var(--t-ingredient),color-mix(in srgb, var(--t-ingredient) 62%, #fff))",
     "匹配条渐变末端"),
    # —— 悬浮「添加菜品」：本体就是强调色 ——
    ("background:linear-gradient(150deg,#E2571F,#C33F14);\n  color:#FFF3E8;",
     "background:linear-gradient(150deg,var(--accent),var(--accent-deep));\n  color:var(--on-accent);",
     "悬浮添加按钮"),
    # —— 强调色面上的反白，一律走 --on-accent ——
    (".tf-btn.tf-main{width:78px;height:78px;background:var(--accent);color:#FFF3EA;",
     ".tf-btn.tf-main{width:78px;height:78px;background:var(--accent);color:var(--on-accent);",
     "全屏计时器主按钮"),
    (".cook-btn.primary{background:var(--accent);color:#FFF3EA;",
     ".cook-btn.primary{background:var(--accent);color:var(--on-accent);",
     "做菜模式主按钮"),
    ('.trash-row[aria-pressed="true"] .trash-box{background:var(--accent);border-color:var(--accent);color:#fff}',
     '.trash-row[aria-pressed="true"] .trash-box{background:var(--accent);border-color:var(--accent);color:var(--on-accent)}',
     "回收站勾选框"),
    ("  background:var(--accent);color:#FFF3EA;\n}\n.allergen-banner",
     "  background:var(--accent);color:var(--on-accent);\n}\n.allergen-banner",
     "过敏原图标"),
    ("font-size:19px;font-weight:700;color:#FFF3EA;\n}\n.member-nm",
     "font-size:19px;font-weight:700;color:var(--on-accent);\n}\n.member-nm",
     "成员头像字色"),
    # —— AI 徽标的紫本来就该跟 --ai 走 ——
    ("color:#5B3A8E", "color:var(--ai)", "AI 徽标字色"),
    # —— 令牌微调：让"弱化文字/成功徽标"在三种底上都过 4.5:1 ——
    ("--ink:#F2E8D9; --ink-2:#C9B9A5; --muted:#94836F;",
     "--ink:#F2E8D9; --ink-2:#C9B9A5; --muted:#A08E78;",
     "night muted 提亮"),
    ("--ok:#2F6B52; --ok-bg:rgba(47,107,82,.12);",
     "--ok:#2A6049; --ok-bg:rgba(42,96,73,.13);",
     "indigo ok 压深"),
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
            print("FATAL「%s」命中 %d 次（需要恰好 1 次），整体不落盘" % (why, hits))
            return 2
        todo.append((a, b, why))
    for a, b, why in todo:
        t = t.replace(a, b)
        print("改 1 处：%s" % why)
    if not todo:
        print("无需改动")
        return 0
    if abs(len(t) - orig) / orig > 0.05:
        print("FATAL 体积变化越界")
        return 3
    P.write_text(t, encoding="utf-8")
    print("第二轮定向修完成：%d 处" % len(todo))
    return 0


if __name__ == "__main__":
    sys.exit(main())
