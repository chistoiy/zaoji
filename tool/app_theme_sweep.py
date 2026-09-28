#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R39 主题轮 · 第二刀：把 UI 里剩下的写死颜色收进主题令牌。

第一刀（app_theme_codemod.py）吃的是 ZaojiColors.* 那 400 多处；
这一刀吃的是**绕过令牌直接写死的** `Colors.white` / `Color(0xFF...)`。
这些才是深色主题下真正会坏的地方——它们不会报错，只是"白底白字"。

分两类处理：
  A. 按参数名判的（fillColor / backgroundColor / foregroundColor / textColor）：
     输入框底色、卡片底色 → surface；彩底上的字 → onAccent。这类是机械的。
  B. 按字面量整值判的（0xFF2F5B40 就是"成功绿"、0xFFE6DCC9 就是分隔线）：
     一个值一个语义，映射唯一，所以也敢机械改。

**不动的**：dish_art.dart（插画配色，五套主题下就该长一样）、
压在图片/遮罩上的半透明黑（0x18110B 系、0x80000000、Colors.black 的阴影）——
理由和原型 CSS 里 --scrim-rgb 那段注释一样：它们底下不是纸。

用法：D:/app_workplace/python3.11/python.exe tool/app_theme_sweep.py [--dry]
"""
import pathlib
import re
import sys

UI = sorted(pathlib.Path("app/lib/ui").glob("*.dart"))
WIDGETS = [pathlib.Path("app/lib/widgets/cover_image.dart"),
           pathlib.Path("app/lib/widgets/time_capsule_text.dart"),
           pathlib.Path("app/lib/widgets/chili_scale.dart")]

# A 类：参数名 → 替换。左边是"参数名: 值"的整段，避免跨参数误伤。
BY_PARAM = [
    ("fillColor: Colors.white", "fillColor: context.zj.surface"),
    ("backgroundColor: Colors.white", "backgroundColor: context.zj.surface"),
    ("foregroundColor: Colors.white", "foregroundColor: context.zj.onAccent"),
    ("textColor: Colors.white", "textColor: context.zj.onAccent"),
    ("selectedForegroundColor: Colors.white", "selectedForegroundColor: context.zj.onAccent"),
]

# B 类：整值 → 令牌。只在 UI 目录里生效（插画目录不在 FILES 里）。
BY_VALUE = [
    (r"Color\(0xFF2F5B40\)", "context.zj.ok"),
    (r"Color\(0xFF2E7D32\)", "context.zj.ok"),
    (r"Color\(0x142E7D32\)", "context.zj.okBg"),
    (r"Color\(0xFFE6DCC9\)", "context.zj.line"),
    (r"Color\(0xFFB2491C\)", "context.zj.accent"),
    (r"Color\(0xFF37634A\)", "context.zj.tagIngredient"),
    (r"Color\(0x1437634A\)", "context.zj.okBg"),
    (r"Color\(0xFF2A5F6B\)", "context.zj.tagMethod"),
    (r"Color\(0xFFFFF4E9\)", "context.zj.onAccent"),
    (r"Color\(0xFFFFF3E8\)", "context.zj.tint2"),
    (r"Color\(0xFFFFF7EE\)", "context.zj.onAccent"),
    (r"Color\(0xFFFFF1E4\)", "context.zj.onAccent"),
    (r"Color\(0xFFFFD9C4\)", "context.zj.onAccent"),
    (r"Color\(0xFFF5EBF4\)", "context.zj.onAccent"),
    (r"Color\(0xFFF3E7F2\)", "context.zj.onAccent"),
    (r"Color\(0xFFC33F14\)", "context.zj.accentDeep"),
    (r"Color\(0xFFE2571F\)", "context.zj.accent"),
    (r"Color\(0xFFA3320D\)", "context.zj.warn"),
    (r"Color\(0xFF6E4468\)", "context.zj.ai"),
    (r"Color\(0x336E4468\)", "context.zj.aiBg"),
    (r"Color\(0x406E4468\)", "context.zj.aiBg"),
    (r"Color\(0x3C6E4468\)", "context.zj.aiBg"),
    (r"Color\(0x1A6E4468\)", "context.zj.aiBg"),
    (r"Color\(0x14D2491C\)", "context.zj.accentSoft"),
    (r"Color\(0x212E491C\)", "context.zj.accentSoft"),
    (r"Color\(0x09231C15\)", "context.zj.lineSoft"),
    (r"Color\(0x123A2816\)", "context.zj.lineSoft"),
]

# 这些字面量属于"压暗层/阴影"，五套主题下都不翻，保留。
KEEP = [
    r"Color\(0xDD18110B\)", r"Color\(0x4D18110B\)", r"Color\(0x3318110B\)",
    r"Color\(0xE6FFFFFF\)", r"Color\(0x80000000\)", r"Colors\.black",
    r"Color\(0x80C33F14\)", r"Color\(0x5CC33F14\)",
]


# 第二阶段：剩下的 `color: Colors.white` 按"上面几行是什么部件"判。
#   BoxDecoration/Material/Scaffold/Container 打头 → 它是**卡片底色** → surface
#   Icon/TextStyle/Text 打头 → 它是**彩底上的字/图标** → onAccent
#   判不出来的原样留着并打印，交给人看——猜错一处的代价是"深色主题下白底白字"。
# 只吃"整行就是一个 color 参数"这一种形状，且**必须把缩进和行尾逗号带回来**：
# 第一版用 sub 换成替换文本，把缩进和逗号一起吃掉了（22 处语法错，
# analyze 当场抓到，tool/app_theme_repair.py 负责还原）。
WHITE_LINE = re.compile(r"^(\s*)color: Colors\.white,\s*$")
SURFACE_HINT = re.compile(r"(BoxDecoration|Material|Scaffold|Container|Card)\(")
ONACCENT_HINT = re.compile(r"(Icon|TextStyle|Text|Row|Column)\(")


def classify_white(src):
    lines = src.split("\n")
    hits = {"surface": 0, "onAccent": 0, "skip": 0}
    for i, ln in enumerate(lines):
        if not WHITE_LINE.match(ln):
            continue
        window = "\n".join(lines[max(0, i - 4):i])
        m = WHITE_LINE.match(ln)
        if not m:
            continue
        indent = m.group(1)
        if SURFACE_HINT.search(window):
            lines[i] = indent + "color: context.zj.surface,"
            hits["surface"] += 1
        elif ONACCENT_HINT.search(window):
            lines[i] = indent + "color: context.zj.onAccent,"
            hits["onAccent"] += 1
        else:
            hits["skip"] += 1
            print("   判不出来，留着：%d: %s" % (i + 1, ln.strip()))
    return "\n".join(lines), hits


def main() -> int:
    dry = "--dry" in sys.argv
    total = 0
    for path in UI + WIDGETS:
        src = path.read_text(encoding="utf-8")
        n = 0
        for a, b in BY_PARAM:
            c = src.count(a)
            if c:
                src = src.replace(a, b)
                n += c
        for pat, rep in BY_VALUE:
            src, c = re.subn(pat, rep, src)
            n += c
        src, hits = classify_white(src)
        n += hits["surface"] + hits["onAccent"]
        if n:
            src, _ = _deconst(src)
            total += n
            print("%-34s %d 处（含白底归类 surface=%d / onAccent=%d）"
                  % (path.name, n, hits["surface"], hits["onAccent"]))
            if not dry:
                path.write_text(src, encoding="utf-8")
    print("合计 %d 处%s" % (total, "（dry，未落盘）" if dry else ""))
    return 0


def _deconst(src):
    """去掉那些表达式里已经出现 context.zj 的 const（声明型改 final）。"""
    n = 0
    for m in reversed(list(re.finditer(r"\bconst\s+", src))):
        after = m.end()
        end = _expr_end(src, after)
        expr = src[after:end]
        if "context.zj." not in expr:
            continue
        if re.match(r"[A-Za-z_][\w$]*\s*=", expr):
            src = src[:m.start()] + "final " + src[after:]
        else:
            src = src[:m.start()] + src[after:]
        n += 1
    return src, n


def _expr_end(src, i):
    depth = 0
    while i < len(src):
        c = src[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return i
            depth -= 1
        elif c in ",;" and depth == 0:
            return i
        i += 1
    return i


if __name__ == "__main__":
    sys.exit(main())
