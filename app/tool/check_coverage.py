"""比较各个子集 profile 对「烹饪词汇」的覆盖，用来决定切到哪一档。

## 为什么单独做这件事

体积数据只回答了「多大」，没回答「切了之后会不会缺字」。
而对菜谱 App 来说，缺字恰恰是最难受的失败方式——它不出错、不报警，
只是把你辛苦录入的菜名显示成一个方块。

而且这类字有很强的规律：**它们在菜谱里天天出现，却往往不在最常用的一千字里**。
比如「蚝油」的蚝、「焯水」的焯、「藠头」的藠。所以专门拿一批这样的字来试。

## 踩过的坑

第一版写成 `if ch not in cmap` —— cmap 的键是**整数码点**不是字符串，
于是所有字符都被判为「缺失」，报出「覆盖 0/101」这种假结论。
判覆盖一律用 `ord(ch) in cmap`。
"""

from __future__ import annotations

import sys
from pathlib import Path

from fontTools.ttLib import TTFont

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from build_fonts import CACHE, build_codepoints  # noqa: E402

REPORT = HERE / "_coverage_out.txt"

FONT = "NotoSansSC-Regular.otf"

# 烹饪场景词汇。挑的就是最容易缺的那批：做法动词、蔬菜、水产、面点、发酵物、器具。
VOCAB = {
    "做法动词": "焖炖煸熘汆焯煨扒炝拌腌渍卤酿蘸勾芡烩煸炒爆煸",
    "蔬菜": "藠荸莼蕹茼蒿莴笋藕菱荠蕨菌菇茄椒葱姜蒜芥芹韭苔薹蘘萹苋茴",
    "水产": "鲈鳜鲳鲅鳕鲭鳝鳅鲍蚬蛏蚝蛤蜊蛎鱿鲷鲨鲲鳢",
    "肉禽部位": "腩腱肘蹄肋胗胰肚胛脍臊",
    "面点": "馍馕馄饨饺粑粿粽糕馒馓馃饽",
    "发酵调味": "酪酥醪糟醅酱醋豉麴",
    "器具": "甑甏簋箅笊篱甗镬鏊笸",
    "杂": "靥氽氲氤馇饹",
}

PROFILES = ["ui", "gb2312", "gbk", "cjk"]


def main() -> int:
    src = CACHE / FONT
    if not src.exists():
        print(f"✘ 缺源字体 {src}")
        return 1
    font = TTFont(str(src), lazy=True)
    cmap = font.getBestCmap()

    all_chars = "".join(VOCAB.values())
    uniq = sorted(set(all_chars))

    lines: list[str] = []
    lines.append(f"源字体 = {FONT}    字形数 = {len(cmap)}")
    lines.append(f"词汇表 = {len(uniq)} 个不重复汉字")
    lines.append("")

    # 源字体自己缺哪些（这是天花板）
    src_missing = [c for c in uniq if ord(c) not in cmap]
    lines.append(f"源字体自身缺字：{len(src_missing)} 个")
    if src_missing:
        lines.append("   " + " ".join(f"{c}(U+{ord(c):04X})" for c in src_missing))
    lines.append("")

    lines.append("=== 各 profile 的覆盖 ===")
    header = f"{'profile':<10}{'码点数':>9}{'覆盖':>12}{'缺失数':>8}"
    lines.append(header)
    lines.append("-" * 40)

    detail: dict[str, list[str]] = {}
    for prof in PROFILES:
        cps, _ = build_codepoints(prof)
        missing = [c for c in uniq if ord(c) not in cps]
        detail[prof] = missing
        ok = len(uniq) - len(missing)
        lines.append(f"{prof:<10}{len(cps):>9}{f'{ok}/{len(uniq)}':>12}{len(missing):>8}")

    lines.append("")
    for prof in PROFILES:
        m = detail[prof]
        if not m:
            lines.append(f"✔ {prof}：词汇表全覆盖")
            continue
        lines.append(f"✘ {prof} 缺 {len(m)} 个：")
        # 按类分组展示，好看清「缺的是哪一类」
        for cat, chars in VOCAB.items():
            miss = [c for c in chars if c in m]
            if miss:
                lines.append(f"     {cat}: {''.join(sorted(set(miss)))}")

    lines.append("")
    lines.append("=== 结论提示 ===")
    lines.append("若 gb2312 缺失集中在「器具」「杂」这类生僻字上，可以接受；")
    lines.append("若「蔬菜」「水产」「做法动词」有缺，则必须用 cjk。")

    text = "\n".join(lines)
    REPORT.write_text(text, encoding="utf-8")
    print(text)
    font.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
