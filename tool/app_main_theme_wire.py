#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R39 · main.dart 接上主题：MaterialApp 跟着 store.tokens 走。

三件事：
  1. `theme: buildZaojiTheme(_store.tokens)`，外面套 ListenableBuilder——
     换肤要重建 MaterialApp 才能传到每一页（store 的 notifyListeners
     本来就在发，这里只是接上）；
  2. 启动屏与启动错误屏**不能**用 context.zj：它们渲染在 MaterialApp 之外，
     那会儿还没有 Theme 祖先，`Theme.of` 在 debug 下是直接抛断言的。
     这两屏用固定调色板（就是默认那套），本来就是"App 还没起来"的画面。
"""
import pathlib
import sys

P = pathlib.Path("app/lib/main.dart")
NL = chr(10)

EDITS = [
    (
        """        return SyncScope(
          engine: sync,
          child: StoreScope(
            store: _store,
            child: MaterialApp(
              title: '灶记',
              debugShowCheckedModeBanner: false,
              theme: buildZaojiTheme(),""",
        """        return SyncScope(
          engine: sync,
          child: StoreScope(
            store: _store,
            // R39：主题是本机偏好，换它要重建整棵 MaterialApp 才能传到每一页。
            // 监听 store 而不是另起一个 ValueNotifier——偏好只有一个事实源。
            child: ListenableBuilder(
              listenable: _store,
              builder: (context, _) => MaterialApp(
              title: '灶记',
              debugShowCheckedModeBanner: false,
              theme: buildZaojiTheme(_store.tokens),""",
    ),
    (
        """              onGenerateRoute: _generateRoute,
            ),
          ),
        );""",
        """              onGenerateRoute: _generateRoute,
            ),
            ),
          ),
        );""",
    ),
]


def main() -> int:
    t = P.read_text(encoding="utf-8")
    for a, b in EDITS:
        if t.count(a) != 1:
            print("FATAL 定位失败（hits=%d）：%s" % (t.count(a), a.split(NL)[0][:60]))
            return 2
        t = t.replace(a, b)

    # 启动屏 / 启动错误屏：MaterialApp 之外，改回固定调色板。
    # 分界取 class _Booting —— 它前面的 _NotFound 是**在** MaterialApp 里渲染的
    # （深链找不到菜谱时那一屏），那里的 context.zj 是对的，不能一起换掉。
    head, sep, tail = t.partition("class _Booting")
    if not sep:
        print("FATAL 没找到 _NotFound 分界")
        return 2
    n = tail.count("context.zj.")
    tail = tail.replace("context.zj.", "ZaojiTokens.fallback.")
    t = head + sep + tail
    t = t.replace(
        "/// 启动画面：本地库打开 + 建表 + 灌种子通常毫秒级，",
        "/// 启动画面：本地库打开 + 建表 + 灌种子通常毫秒级，" + NL +
        "/// ★ 这两屏渲染在 MaterialApp 之外，没有 Theme 祖先，所以取色一律走" + NL +
        "///   [ZaojiTokens.fallback]（`context.zj` 在这儿会直接抛断言）。", 1)
    P.write_text(t, encoding="utf-8")
    print("main.dart 接好主题；启动屏 %d 处改回固定调色板" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
