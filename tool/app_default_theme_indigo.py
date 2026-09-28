#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R39 收尾 · 把"默认主题"从柿红暖纸改判为蓝染粗布。

默认值散在五个地方（Dart 的 fallback、原型的 DEFAULT_THEME、图标纸底、
manifest 的两个颜色、审计脚本的基线）。漏改任何一个，就会出现
"文档说蓝、启动是红"这种没人能信的状态。每条都要求恰好命中一次。
"""
import pathlib
import sys

NL = chr(10)


def patch(rel, pairs):
    p = pathlib.Path(rel)
    t = p.read_text(encoding="utf-8")
    for a, b in pairs:
        if t.count(a) != 1:
            raise SystemExit("FATAL %s hits=%d :: %r" % (rel, t.count(a), a[:46]))
        t = t.replace(a, b)
    p.write_text(t, encoding="utf-8")
    print("ok", rel)


# ── 1) Dart：fallback 换成 indigo ─────────────────────────────────────
patch("app/lib/theme.dart", [
    ("""  /// 找不到 extension 时的兜底（例如 widget 测试里手搓的 ThemeData）。
  /// 用 [shihong] 而不是造一份"通用默认"——兜底色就是设计定调那套，
  /// 这样测试里看到的颜色和没配主题时用户看到的颜色是同一个东西。
  static const ZaojiTokens fallback = shihong;""",
     """  /// 找不到 extension 时的兜底（例如 widget 测试里手搓的 ThemeData），
  /// 也是**没选过主题时的默认那套**。
  ///
  /// ★ R39 收尾由用户拍板：默认从「柿红暖纸」换成「蓝染粗布」。
  ///   理由不只是偏好——靛蓝把强调色让出来之后，绿色能完整留给"充足"
  ///   这个状态语义（原来强调色和状态色都是红/绿系，一屏里打架）；
  ///   而且主按钮的反白对比过了 AA（柿红那套只有 4.09，要修就得动品牌色）。
  ///   ★ 改默认主题要一起改的四处：原型的 DEFAULT_THEME、图标纸底、
  ///     manifest 的 background/theme-color、审计脚本 THEMES 的第一个（基线）。
  static const ZaojiTokens fallback = indigo;"""),
])

# ── 2) 删掉 ZaojiColors 别名（全仓库已零引用）─────────────────────────
p = pathlib.Path("app/lib/theme.dart")
t = p.read_text(encoding="utf-8")
i = t.find("/// 旧的名字仍然可用")
j = t.find("/// 圆角。原型里定的是")
if i < 0 or j < 0 or j <= i:
    raise SystemExit("FATAL ZaojiColors 段定位失败")
p.write_text(t[:i] + t[j:], encoding="utf-8")
print("ZaojiColors 别名已删（零引用；留着只会诱人写出不随主题翻的代码）")

# ── 3) 原型：默认主题与 themeById 兜底 ────────────────────────────────
patch("zaoji-prototype.html", [
    ("  theme:'shihong',     // R39 五套主题之一；本机偏好，不参与同步（见 SCREENS.theme 头注）",
     "  theme:DEFAULT_THEME, // R39 五套主题之一；本机偏好，不参与同步（见 SCREENS.theme 头注）"),
    # DEFAULT_THEME 必须定义在 S **之前**：S 在 2877 行、THEMES 在 2920 行，
    # 把常量放 THEMES 旁边会让 S 初始化时踩到 TDZ（const 不提升值）。
    ("const S = {\n  mode:'android',",
     "// 默认那套：R39 收尾由用户拍板，从 shihong 改成 indigo" + NL +
     "//（理由见 app/lib/theme.dart 的 fallback 注释：状态色不再和强调色打架 + 主按钮过 AA）" + NL +
     "// 放在 S 之前定义——S 初始化时就要读它，const 不提升值。" + NL +
     "const DEFAULT_THEME = 'indigo';" + NL + NL +
     "const S = {" + NL + "  mode:'android',"),
    ("const THEMES = [", "const THEMES = ["),
    ("function themeById(id) {" + NL +
     "  return THEMES.filter(function (t) { return t.id === id; })[0] || THEMES[0];" + NL +
     "}",
     "function themeById(id) {" + NL +
     "  return THEMES.filter(function (t) { return t.id === id; })[0] || themeById(DEFAULT_THEME);" + NL +
     "}"),
    ('<button class="theme-btn" data-act="theme" data-theme="shihong" aria-pressed="true" title="柿红暖纸">',
     '<button class="theme-btn" data-act="theme" data-theme="shihong" aria-pressed="false" title="柿红暖纸">'),
    ('<button class="theme-btn" data-act="theme" data-theme="indigo" aria-pressed="false" title="蓝染粗布">',
     '<button class="theme-btn" data-act="theme" data-theme="indigo" aria-pressed="true" title="蓝染粗布">'),
])

# ── 4) 审计基线 = 新的默认主题（数组第一个就是基线）──────────────────
patch("tool/proto_theme_audit.cjs", [
    ("const THEMES = ['shihong', 'indigo', 'rouge', 'night', 'stone'];",
     "// 第一个是**基线**：判据是『新主题不许比默认主题更差』，换默认主题要换这里" + NL +
     "const THEMES = ['indigo', 'shihong', 'rouge', 'night', 'stone'];"),
])

# ── 5) 图标纸底与 manifest / index.html 的品牌色 ──────────────────────
patch("app/tool/gen_icons.dart", [
    ("/// 暖纸底（与 ZaojiTokens.shihong.paper 同值；改主题默认色时这里要跟）。" + NL +
     "const _paper = 0xFFFBF6EC;",
     "/// 纸底：跟**默认主题**的纸色走（现在是蓝染粗布 = 冷白）。" + NL +
     "/// 改默认主题时这里和 web/manifest.json 的两个颜色要一起改。" + NL +
     "const _paper = 0xFFF2F5F8;"),
])
patch("app/web/manifest.json", [
    ('"background_color": "#FBF6EC"', '"background_color": "#F2F5F8"'),
    ('"theme_color": "#D2491C"', '"theme_color": "#2B5D8C"'),
])
patch("app/web/index.html", [
    ('<meta name="theme-color" content="#D2491C">', '<meta name="theme-color" content="#2B5D8C">'),
])

# ── 6) 测试与文档里的"默认"口径 ──────────────────────────────────────
patch("app/test/theme_test.dart", [
    ("    test('默认是柿红暖纸', () {\n      expect(store.themeId, 'shihong');",
     "    test('默认是蓝染粗布（R39 收尾改判）', () {\n      expect(store.themeId, 'indigo');"),
    ("      expect(store.tokens.id, 'shihong');\n    });",
     "      expect(store.tokens.id, 'indigo');\n    });"),
    ("      store.setTheme('从没有过的一套');\n      expect(store.themeId, 'shihong');",
     "      store.setTheme('从没有过的一套');\n      expect(store.themeId, 'indigo');"),
    ("          expect(onAccent, greaterThanOrEqualTo(4.5),\n              reason: '新增的四套主题没有沿用旧缺口的份');",
     "          expect(onAccent, greaterThanOrEqualTo(4.5),\n              reason: '除柿红那套以外，其它四套没有沿用旧缺口的份');"),
    ("    expect(ZaojiTokens.all.map((e) => e.id),\n          ['shihong', 'indigo', 'rouge', 'night', 'stone']);",
     "    expect(ZaojiTokens.all.map((e) => e.id),\n          ['shihong', 'indigo', 'rouge', 'night', 'stone'],\n          reason: '设置页顺序不变；默认是 indigo，靠 fallback 表达，不靠排序');"),
])
patch("app/test/icon_guard_test.dart", [
    ("      expect(s, contains('#FBF6EC'), reason: '启动背景色 = 默认主题的纸色');",
     "      expect(s, contains('#F2F5F8'), reason: '启动背景色 = 默认主题（蓝染粗布）的纸色');"),
])
patch("README.md", [
    ("- **我的 → 主题**：柿红暖纸（默认）/ 蓝染粗布 / 胭脂米白 / 夜灶暖光 / 青石夜色。",
     "- **我的 → 主题**：蓝染粗布（默认）/ 柿红暖纸 / 胭脂米白 / 夜灶暖光 / 青石夜色。"),
])

print("默认主题改判完成")
