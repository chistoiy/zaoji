"""判断一个文件到底是不是字体、是哪种字体。

为什么要专门写这个：Google Fonts 的 `/l/font?kit=...` 端点返回的文件头部
既不是 `00010000`（TTF）也不是 `OTTO`（OTF）也不是 `wOF2`（WOFF2），
看起来像是带了一层私有封装的容器。在没弄清之前做子集化等于在猜。
"""

import io
import struct
import sys
from pathlib import Path


def sniff(path: Path) -> list[str]:
    out: list[str] = []
    data = path.read_bytes()
    out.append(f"file      = {path.name}")
    out.append(f"size      = {len(data)} bytes ({len(data) / 1024 / 1024:.2f} MB)")

    sfnt_sigs = {
        b"\x00\x01\x00\x00": "TrueType (glyf)",
        b"OTTO": "CFF/OpenType",
        b"true": "TrueType (Apple)",
        b"ttcf": "TrueType Collection",
        b"wOFF": "WOFF 1.0",
        b"wOF2": "WOFF 2.0",
    }
    found = False
    # 只在前 64KB 里找签名——正常字体的签名就在偏移 0
    for i in range(0, min(len(data) - 4, 65536)):
        sig = data[i : i + 4]
        if sig in sfnt_sigs:
            out.append(f"sfnt 签名  = {sfnt_sigs[sig]} @ 偏移 {i}")
            found = True
            break
    if not found:
        out.append("sfnt 签名  = 前 64KB 内没有找到任何已知字体签名")

    out.append(f"前 16 字节 = {data[:16].hex(' ')}")
    out.append(f"前 16 LE  = {[struct.unpack_from('<I', data, i)[0] for i in range(0, 16, 4)]}")

    # 试着当字体读
    try:
        from fontTools.ttLib import TTFont

        for probe in (0, None):
            try:
                buf = io.BytesIO(data) if probe is None else io.BytesIO(data[probe:])
                font = TTFont(buf, lazy=True)
                tables = sorted(font.reader.tables.keys())
                out.append(f"fontTools  = ✔ 打开成功（起始偏移 {probe}）")
                out.append(f"  表        = {', '.join(tables[:24])}{' …' if len(tables) > 24 else ''}")
                out.append(f"  表数量     = {len(tables)}")
                if "name" in font:
                    for rec in font["name"].names:
                        if rec.nameID in (1, 2, 4, 6):
                            try:
                                val = rec.toUnicode()
                            except Exception:
                                continue
                            out.append(f"  name[{rec.nameID}] = {val}")
                if "cmap" in font:
                    cmap = font.getBestCmap()
                    out.append(f"  cmap 字符数 = {len(cmap)}")
                    for ch in "灶记番茄炒蛋":
                        out.append(f"    '{ch}' U+{ord(ch):04X} => {'✔' if ord(ch) in cmap else '✘ 缺失'}")
                break
            except Exception as exc:  # noqa: BLE001
                out.append(f"fontTools  = ✘ 偏移 {probe} 打开失败：{type(exc).__name__}: {exc}")
    except ImportError:
        out.append("fontTools  = 未安装")

    return out


def main() -> None:
    targets = sys.argv[1:]
    if not targets:
        print("用法: identify_font.py <字体文件...>")
        raise SystemExit(2)
    lines: list[str] = []
    for t in targets:
        p = Path(t)
        if not p.exists():
            lines.append(f"✘ 不存在: {p}")
            continue
        lines.extend(sniff(p))
        lines.append("")
    text = "\n".join(lines)
    out = Path(__file__).parent / "_identify_out.txt"
    out.write_text(text, encoding="utf-8")
    print(text)


if __name__ == "__main__":
    main()
