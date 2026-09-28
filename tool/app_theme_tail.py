#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R39 · 收掉 app_theme_codemod 剩下的 10 处手工尾巴。

为什么机器没吃掉：三种情况都是"检测的边界"，不是"改不了"——
  · `_stepBtn` 在 StatelessWidget 的私有方法里，压根没有 context → 给它加一个参数；
  · `_group(List<Map<String, Object?>> list, BuildContext context, ...)`
    参数表里带括号，正则 `[^()]*` 跨不过去 → 手工确认这里有 context；
  · `showXxxSheet(BuildContext context, {...})` 参数表换行且带 `{` → 同上。
"""
import pathlib
import sys

EDITS = [
    ("app/lib/ui/kitchen_page.dart", [
        # _stepBtn：StatelessWidget 里没有 context，把 context 传进去
        ("  Widget _stepBtn(IconData icon, String label, VoidCallback onTap) =>",
         "  Widget _stepBtn(BuildContext context, IconData icon, String label,\n          VoidCallback onTap) =>"),
        ("color: ZaojiColors.ink2,\n      );",
         "color: context.zj.ink2,\n      );"),
        ("_stepBtn(Icons.remove,\n                    '减少 ${item.name}', () => store.adjustPantry(item.id, -1)),",
         "_stepBtn(context, Icons.remove,\n                    '减少 ${item.name}', () => store.adjustPantry(item.id, -1)),"),
        ("_stepBtn(Icons.add, '增加 ${item.name}',\n                    () => store.adjustPantry(item.id, 1)),",
         "_stepBtn(context, Icons.add, '增加 ${item.name}',\n                    () => store.adjustPantry(item.id, 1)),"),
        # _group：参数表带括号，机器没认出来；这里 context 是有的
        ("const TextStyle(fontSize: 12, color: ZaojiColors.muted)),",
         "TextStyle(fontSize: 12, color: context.zj.muted)),"),
        ("border: Border.all(color: ZaojiColors.line),",
         "border: Border.all(color: context.zj.line),"),
        ("? ZaojiColors.accent.withValues(alpha: .1)\n                                  : ZaojiColors.amberBg,",
         "? context.zj.accent.withValues(alpha: .1)\n                                  : context.zj.amberBg,"),
        ("? ZaojiColors.accent\n                                      : ZaojiColors.amber),",
         "? context.zj.accent\n                                      : context.zj.amber),"),
        ("color: ZaojiColors.accent)),",
         "color: context.zj.accent)),"),
    ]),
    ("app/lib/ui/menus_page.dart", [
        ("backgroundColor: ZaojiColors.paper,", "backgroundColor: context.zj.paper,"),
    ]),
    ("app/lib/ui/timer_sheet.dart", [
        ("backgroundColor: ZaojiColors.paper,", "backgroundColor: context.zj.paper,"),
    ]),
]


def main() -> int:
    for rel, pairs in EDITS:
        p = pathlib.Path(rel)
        t = p.read_text(encoding="utf-8")
        for a, b in pairs:
            hits = t.count(a)
            if hits != 1:
                print("FATAL %s 里「%s」命中 %d 次，整体不落盘" % (rel, a[:40], hits))
                return 2
            t = t.replace(a, b)
        p.write_text(t, encoding="utf-8")
        print("%-34s 改了 %d 处" % (rel, len(pairs)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
