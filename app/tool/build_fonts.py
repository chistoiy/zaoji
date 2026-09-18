"""把 Noto CJK 切成 Web 产物用的 woff2 子集。

## 为什么需要这个脚本

Flutter Web 的 CanvasKit **自己就是一个字体栈**：它不读系统字体，
文字要么来自 pubspec 里打包的字体，要么由引擎的「字体回退」机制
从 `https://fonts.gstatic.com/s/` 现拉（路径表烧在 main.dart.js 里，
本工程实测有 725 处 `.woff2` 引用，连拉丁字母的默认字体 roboto 都在其中）。

对这个项目的部署形态（家里一台常年不联网也可能断网的笔记本）来说，
「运行时去 Google 拉字体」等于「断网时全屏方块」。所以必须自带字体。

而完整的中文字体每个字重 8~15 MB，直接打进 Web 产物不现实
（M0 要测的正是首屏时间，塞一个 10 MB 字体进去，测出来的数字没有参考价值）。
所以子集化。

## 覆盖率怎么选

`--profile` 决定保留哪些字符，这是**体积与「会不会出现方块」之间的取舍**：

| profile  | 覆盖 | 说明 |
|---|---|---|
| `ui`     | 仅源码里出现的字 + ASCII + 标点 | **实测不可用**：缺 87% 的烹饪用字，见下 |
| `gb2312` | GB2312 全集（6763 汉字 + 682 符号） | 缺「藠、粿」等少数口语字 |
| `gbk`    | GBK 全集（约 21000 汉字） | 接近 Windows 中文的实际下限 |
| `cjk`    | CJK 基本区 + 扩展 A + 标点 + ASCII | 实测烹饪词汇 117/117 全中，最稳 |

> **`ui` 档是个陷阱，别用。** 实测它只覆盖 117 个烹饪常用字里的 15 个——
> 「笋、蚝、鲈、腩、饺、醋」全缺。原因是源码里没写过这些字，
> 而**用户会输入源码里没有的字**。这条教训值得留着：
> 「按自己代码里出现过的字符做子集」在用户内容可自由输入的产品上必然出事。

用法：

    python build_fonts.py --check                 # 只测量，不写产物
    python build_fonts.py --profile gb2312        # 生成到 app/assets/fonts/

脚本自己会写 `_fonts_report.txt`，**不要靠控制台输出判断结果**
（这台机器上 PowerShell 抓外部程序的中文输出不可靠）。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP = HERE.parent
CACHE = HERE / "font-cache"
OUT_DIR = APP / "assets" / "fonts"
REPORT = HERE / "_fonts_report.txt"

# 要处理的字体。
#
# **每个字体的 profile 可以不同，这是刻意的设计**：
#   · 正文字体（Sans）是「最终兜底」——用户输入的菜名、食材、备注全靠它，
#     一旦缺字就是方块，所以用 `gbk`（实测烹饪词汇 117/117）。
#   · 展示字体（Serif）只负责菜名与大标题，挂了 fontFamilyFallback 指向 Sans，
#     所以它自己缺字也不会出方块（会退到 Sans），用 `gb2312` 就够，省 4 MB。
#
# 字重：UI 里 w500/w600 出现在 12 处（卡片标题、区块标题、胶囊），
# 所以 Medium 必须打——只打 Regular 的话这些强调会全部退化成正文粗细。
FONT_SPECS: list[tuple[str, str, str]] = [
    # (源文件, 输出文件, profile)
    ("NotoSansSC-Regular.otf", "NotoSansSC-Regular.woff2", "gbk"),
    ("NotoSansSC-Medium.otf", "NotoSansSC-Medium.woff2", "gbk"),
    ("NotoSerifSC-Regular.otf", "NotoSerifSC-Regular.woff2", "gb2312"),
]

# ── 字符集构造 ────────────────────────────────────────────────


def _ranges(*pairs: tuple[int, int]) -> set[int]:
    out: set[int] = set()
    for lo, hi in pairs:
        out.update(range(lo, hi + 1))
    return out


# 标点与符号：不管哪个 profile 都要有，否则「，。」「（）」会变方块
_COMMON = _ranges(
    (0x20, 0x7E),      # ASCII 可打印
    (0xA0, 0xFF),      # Latin-1 补充（° × ÷ 之类）
    (0x2010, 0x203B),  # 连字符、破折号、引号、省略号
    (0x2044, 0x2052),  # ⁄ ⁅ ⁆ ⁇ ⁈ ⁉ ⁊ ⁋ ⁌ ⁍ ⁎ ⁏ ⁐ ⁑ ⁒
    (0x20AC, 0x20AC),  # €
    (0x2103, 0x2103),  # ℃
    (0x2109, 0x2109),  # ℉
    (0x2116, 0x2116),  # №
    (0x2190, 0x21FF),  # 箭头
    (0x2460, 0x24FF),  # ① ② ③ 圈号——需求文档里就用它编号
    (0x2500, 0x257F),  # 制表符
    (0x25A0, 0x25FF),  # 几何图形（● ○ ■ □）
    (0x2600, 0x27BF),  # 杂项符号 + Dingbats（★ ☆ ✓ ✗）
    (0x3000, 0x303F),  # CJK 标点（、。〈〉《》「」）
    (0xFE10, 0xFE1F),  # 竖排标点
    (0xFF01, 0xFF60),  # 全角 ASCII（！？～）
    (0xFFE0, 0xFFE6),  # 全角货币符号
)
# 说明：**不要**在这里加 CJK 扩展 B（U+20000–U+2A6DF）。
# Noto Sans/Serif SC 根本没有那些字形（实测 CJK 基本区覆盖 99.9%~100%，
# 扩展 B 为 0）。把它们写进码点集合只会让「字符集总数」虚高到 4 万多，
# 看起来像覆盖了，实际一个都取不到。要支持扩展 B 得另找字体。


def _gb2312() -> set[int]:
    """枚举 GB2312 的字符集（约 6763 汉字 + 682 符号）。"""
    return _by_codec("gb2312", 0xA1, 0xF8, 0xA1, 0xFF)


def _gbk() -> set[int]:
    """枚举 GBK 的字符集（约 21000 汉字）——比 GB2312 宽，是 Windows 中文的实际下限。"""
    return _by_codec("gbk", 0x81, 0xFF, 0x40, 0xFF)


def _by_codec(name: str, hi0: int, hi1: int, lo0: int, lo1: int) -> set[int]:
    out: set[int] = set()
    for hi in range(hi0, hi1):
        for lo in range(lo0, lo1):
            try:
                out.add(ord(bytes([hi, lo]).decode(name)))
            except UnicodeDecodeError:
                continue
    return out


def _source_chars() -> set[int]:
    """扫描 app/lib 下 Dart 源码里出现的所有非 ASCII 字符。

    这是「UI 固定文案」的真实集合——按钮、标题、种子菜谱全在里面。
    """
    out: set[int] = set()
    for p in (APP / "lib").rglob("*.dart"):
        text = p.read_text(encoding="utf-8", errors="replace")
        # 去掉注释以外的都留着；注释里的字也多留一点，无害
        for ch in text:
            if ord(ch) > 0x7F:
                out.add(ord(ch))
    return out


def build_codepoints(profile: str) -> tuple[set[int], dict[str, int]]:
    parts: dict[str, set[int]] = {}
    parts["common"] = set(_COMMON)
    parts["ui"] = _source_chars()

    if profile == "ui":
        pass
    elif profile == "gb2312":
        parts["gb2312"] = _gb2312()
    elif profile == "gbk":
        parts["gb2312"] = _gb2312()
        parts["gbk-extra"] = _gbk()
    elif profile == "cjk":
        parts["cjk-basic"] = _ranges((0x3400, 0x4DBF), (0x4E00, 0x9FFF), (0xF900, 0xFAFF))
    else:
        raise SystemExit(f"未知 profile: {profile}")

    total: set[int] = set()
    sizes: dict[str, int] = {}
    for k, v in parts.items():
        sizes[k] = len(v)
        total |= v
    return total, sizes


# ── 子集化 ────────────────────────────────────────────────────


def subset_font(src: Path, dst: Path, codepoints: set[int]) -> dict[str, object]:
    from fontTools import subset
    from fontTools.ttLib import TTFont

    info: dict[str, object] = {"src": src.name, "dst": dst.name}

    options = subset.Options()
    options.layout_features = ["*"]   # 保留 vert/locl 等 CJK 相关特性
    options.name_IDs = ["*"]
    options.name_legacy = True
    options.name_languages = ["*"]
    options.notdef_outline = True
    options.recalc_bounds = True
    options.recalc_timestamp = False
    options.drop_tables += ["BASE", "JSTF", "DSIG"]
    options.hinting = True

    font = subset.load_font(str(src), options)
    before = font.getBestCmap()
    info["glyphs_before"] = len(before)

    subsetter = subset.Subsetter(options=options)
    subsetter.populate(unicodes=codepoints)
    subsetter.subset(font)

    after = font.getBestCmap()
    info["glyphs_after"] = len(after)

    # 抽查关键字符是否还在。第二组特意挑了「烹饪里常见但不属于常用字」的，
    # 它们在子集化时最容易掉——掉一个就是用户菜名上的一个方块。
    probe = "灶记番茄炒蛋红烧肉分钟蒜蓉粉丝蒸虾蚝油生菜①℃"
    probe += "藠粿焯汆腩鲈饺醋焖炖煸熘荸莼蕹"
    missing = [ch for ch in probe if ord(ch) not in after]
    info["probe_missing"] = missing

    font.flavor = "woff2"
    dst.parent.mkdir(parents=True, exist_ok=True)
    font.save(str(dst))
    font.close()

    info["bytes"] = dst.stat().st_size
    info["src_bytes"] = src.stat().st_size

    # 回读校验：能重新打开、且声明的家族名对
    check = TTFont(str(dst))
    fam = ""
    for rec in check["name"].names:
        if rec.nameID == 1:
            try:
                fam = rec.toUnicode()
                break
            except Exception:  # noqa: BLE001
                continue
    info["family"] = fam
    info["reopen_ok"] = True
    check.close()
    return info


CJK_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--profile",
        default=None,
        choices=["ui", "gb2312", "gbk", "cjk"],
        help="强制所有字体都用这一档（默认按 FONT_SPECS 里各字体自己那一档）",
    )
    ap.add_argument("--check", action="store_true", help="只测量并写报告，不产出到 assets/")
    ap.add_argument("--outdir", default=None)
    args = ap.parse_args()

    lines: list[str] = []
    lines.append(f"强制 profile = {args.profile or '（按各字体自身设定）'}    check_only = {args.check}")
    lines.append("")

    lines.append("=== 源文件 ===")
    missing_src: list[str] = []
    for src_name, _, _ in FONT_SPECS:
        p = CACHE / src_name
        ok = p.exists()
        sz = f"{p.stat().st_size / 1024 / 1024:.2f} MB" if ok else "缺失"
        lines.append(f"  {'✔' if ok else '✘'} {src_name}  {sz}")
        if not ok:
            missing_src.append(src_name)
    lines.append("")

    if missing_src:
        lines.append("缺少源字体，先跑：powershell -ExecutionPolicy Bypass -File app\\tool\\download_fonts.ps1")
        REPORT.write_text("\n".join(lines), encoding="utf-8")
        print("\n".join(lines))
        return 1

    outdir = Path(args.outdir) if args.outdir else (HERE / "_fonts_staging" if args.check else OUT_DIR)
    lines.append(f"输出目录 = {outdir}")
    lines.append("")

    results = []
    for src_name, dst_name, prof in FONT_SPECS:
        prof = args.profile or prof
        codepoints, sizes = build_codepoints(prof)
        lines.append(f"── {src_name}  profile={prof}  码点 {len(codepoints)}")
        for k, v in sizes.items():
            lines.append(f"       {k:<12} {v}")
        try:
            info = subset_font(CACHE / src_name, outdir / dst_name, codepoints)
            info["profile"] = prof
            results.append(info)
        except Exception as exc:  # noqa: BLE001
            lines.append(f"   ✘ 失败：{type(exc).__name__}: {exc}")
            REPORT.write_text("\n".join(lines), encoding="utf-8")
            print("\n".join(lines))
            return 1

    lines.append("")
    lines.append("=== 结果 ===")
    total = 0
    for i in results:
        ratio = i["bytes"] / i["src_bytes"] * 100  # type: ignore[operator]
        total += i["bytes"]  # type: ignore[operator]
        lines.append(
            f"  {i['dst']}   [{i['profile']}]\n"
            f"      源 {i['src_bytes'] / 1024 / 1024:.2f} MB → 子集 "
            f"{i['bytes'] / 1024 / 1024:.2f} MB（{ratio:.1f}%）"
            f"   字形 {i['glyphs_before']} → {i['glyphs_after']}   家族「{i['family']}」"
        )
        lines.append(
            "      抽查缺字：" + ("无 ✔" if not i["probe_missing"] else str(i["probe_missing"]))
        )
    lines.append(f"  合计 = {total / 1024 / 1024:.2f} MB")

    REPORT.write_text("\n".join(lines), encoding="utf-8")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
