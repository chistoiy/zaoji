#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""R39 主题轮 · 把页面里的 ZaojiColors.X 迁到主题令牌 zj.X。

为什么必须动这 400 多处：`ZaojiColors.paper` 是编译期常量，
常量**做不到"跟着主题翻"**。换肤的全部工作量就在这一步，
没有第二条路（全局可变的静态色板能让代码少改，但那是拿
"测试隔离 + 重建正确性"换一个键名，不划算）。

三条规则，按优先级：
  1. 所在作用域能拿到 `context`（build 方法、State 的方法与私有函数、
     带 context 参数的函数、`(context, _) =>` 这种 builder）
     → 引用改写成 `context.zj.paper`；
  2. 拿不到 context 的（顶层常量、静态字段、没有 context 的纯函数）
     → **原样不动**，跑完打印出来给人手工处理。静默改坏比留一手更糟；
  3. 不往函数体里插 `final zj = context.zj;` 这种"顺手写法"——
     第一版这么做过，偏移算错一处就把 `return` 切成两半（analyze 里
     表现为 `Undefined name 'retu'`）。少一处状态，就少一类事故。

改完还要拆 `const`：`const TextStyle(color: zj.ink)` 不是常量表达式，
编译不过。所以第二遍从后往前扫每个 `const`，把它后面那个表达式取出来，
表达式里出现了 zj 引用就把这个 `const` 去掉（内层还有 const 的各自判断）。

用法：D:/app_workplace/python3.11/python.exe tool/app_theme_codemod.py [--dry]
"""
import pathlib
import re
import sys

ROOT = pathlib.Path("app/lib")
FILES = sorted((ROOT / "ui").glob("*.dart")) + sorted((ROOT / "widgets").glob("*.dart"))
FILES.append(ROOT / "main.dart")

TOKENS = (
    "paper|paper2|ink|ink2|muted|accent|amber|amberBg|ai|aiBg|line|lineSoft|"
    "warn|warnBg|chili|tagCuisine|tagIngredient|tagTaste|tagMethod|tagCustom"
)
REF_RE = re.compile(r"ZaojiColors\.(" + TOKENS + r")\b")

# 函数头长什么样：有一个参数表，且参数表里有 context
CTX_IN_PARAMS = re.compile(r"\((?:[^()]*)\bBuildContext\s+context\b")
CTX_PARAM = re.compile(r"\((?:[^()]*?)\bcontext\b[^()]*?\)\s*(=>|\{)")
CLASS_HEADER = re.compile(r"\bclass\s+\w+")
CONTROL = re.compile(r"^\s*(if|for|while|switch|catch|do|else|try|with)\b")


def enclosing_blocks(src, pos):
    """返回 pos 处从外到内的 { 位置列表（块起始花括号下标）。"""
    stack = []
    for m in re.finditer(r"[{}]", src[:pos]):
        if m.group(0) == "{":
            stack.append(m.start())
        elif stack:
            stack.pop()
    return stack


def block_header(src, brace):
    """取某个 { 的"头部"：上一个 } 或 ; 之后到这里为止的文本。"""
    lo = max(
        src.rfind("}", 0, brace),
        src.rfind(";", 0, brace),
    )
    return src[lo + 1:brace]


def body_style(src, brace):
    """块体还是箭头体：箭头体返回 '=>'，普通块返回 '{'。"""
    tail = src[brace:]
    if tail.startswith("=>"):
        return "=>"
    return "{"


ARROW_CTX = re.compile(r"(?:BuildContext\s+)?\(\s*context\s*(?:,_[^)]*)?\)\s*=>|\bBuildContext\s+context\s*\)\s*=>")


def in_arrow_with_context(src, pos):
    """ref 是否落在某个「带 context 的箭头体」里：`build(BuildContext context) => ...`。

    箭头体没有 `{`，块栈里根本看不到它——不单独判一次就会全被当成"拿不到
    context"，而实际上那些位置 `context.zj.x` 直接就能用。
    判法：往前找最近的"`(context…) =>`"，两者之间不允许出现 `;`
    （箭头体是一个表达式，表达式里不会有分号；出现说明已经跨到下一条语句了）。
    """
    window = src[max(0, pos - 6000):pos]
    for m in ARROW_CTX.finditer(window):
        if ";" not in window[m.end():]:
            return True
    return False


def has_context(src, pos):
    """这个位置上到底能不能喊到 `context`？三件事任一成立即可：
    ① 所在函数参数表里有 BuildContext context；② 所在类是 State 子类（this.context）；
    ③ 落在一个带 context 的箭头体里。"""
    stack = enclosing_blocks(src, pos)
    if any(re.search(r"extends\s+State<", block_header(src, b)) for b in stack):
        return True
    for brace in reversed(stack):
        head = block_header(src, brace)
        if CLASS_HEADER.search(head) or CONTROL.match(head.strip()) or "(" not in head:
            continue
        if CTX_IN_PARAMS.search(head) or CTX_PARAM.search(head):
            return True
    return in_arrow_with_context(src, pos)


def strip_bad_consts(src):
    """把"表达式里含 context.zj."的那些 const 处理掉。

    两种情形不能混为一谈：
      · `const TextStyle(color: zj.x)` —— 这是个**用法**，去掉 const 就行；
      · `const bodyStyle = TextStyle(color: zj.x)` —— 这是个**局部声明**，
        直接删掉 const 会变成给未声明变量赋值（analyze 里表现为
        `Undefined name 'bodyStyle'`），必须换成 final。
    """
    n = 0
    for m in reversed(list(re.finditer(r"\bconst\s+", src))):
        after = m.end()
        end = expression_end(src, after)
        expr = src[after:end]
        if not re.search(r"\bzj\.|context\.zj\.", expr):
            continue
        is_decl = re.match(r"[A-Za-z_][\w$]*\s*=", expr) is not None
        if is_decl:
            src = src[:m.start()] + "final " + src[after:]
        else:
            src = src[:m.start()] + src[after:]
        n += 1
    return src, n


def expression_end(src, i):
    """从 i 开始扫到一个表达式结束（深度 0 处的 , ; ) } 或行尾）。"""
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
        elif c == "\n" and depth == 0 and i + 1 < len(src) and src[i + 1] not in ".?:&|":
            # 行尾且下一行不是续行：表达式到此为止（保守判断）
            j = i + 1
            while j < len(src) and src[j] == " ":
                j += 1
            if j < len(src) and src[j] in ")]},;":
                return i
        i += 1
    return i


def process(path, dry):
    src = path.read_text(encoding="utf-8")
    refs = list(REF_RE.finditer(src))
    orphan = []
    out = src
    done = 0

    # 从后往前替换，位置才不会漂
    for m in reversed(refs):
        pos = m.start()
        if has_context(out, pos):
            out = out[:m.start()] + "context.zj." + m.group(1) + out[m.end():]
            done += 1
        else:
            orphan.append((path.name, out[:pos].count("\n") + 1, m.group(0)))

    out, deconsted = strip_bad_consts(out)

    print("%-34s refs=%3d 改好=%3d 拆 const=%3d 待手工=%d"
          % (path.name, len(refs), done, deconsted, len(orphan)))
    if not dry:
        path.write_text(out, encoding="utf-8")
    return orphan


def main():
    dry = "--dry" in sys.argv
    all_orphans = []
    for f in FILES:
        if not f.exists():
            print("跳过（不存在）：%s" % f)
            continue
        all_orphans += process(f, dry)
    print("\n== 需要手工处理的引用（所在作用域拿不到 context）==")
    for name, line, ref in all_orphans:
        print("  %s:%d  %s" % (name, line, ref))
    if not all_orphans:
        print("  无")
    return 0


if __name__ == "__main__":
    sys.exit(main())
