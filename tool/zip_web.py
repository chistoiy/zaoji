#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 app/build/web 打成发布用的 zip（Release 四件套里的 web 那一件）。

以前这一步是 dist/ 下一个版本号写死的临时脚本（zip_web.py），
每轮复制改一行——容易漏改，也容易把 zip 打到上一版的产物上。
现在版本号从 app/pubspec.yaml 现读，产物目录里缺 index.html 就直接拒。

用法：python tool/zip_web.py [输出目录]     （默认 dist/release_v<版本>/）
"""
import os
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "app" / "build" / "web"


def version() -> str:
    text = (ROOT / "app" / "pubspec.yaml").read_text(encoding="utf-8")
    m = re.search(r"^version:\s*(\d+\.\d+\.\d+)\+(\d+)", text, re.M)
    if not m:
        raise SystemExit("读不到 app/pubspec.yaml 的 version")
    return m.group(1), m.group(2)


def main() -> int:
    ver, code = version()
    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "dist" / f"release_v{ver}"
    if not (SRC / "index.html").exists():
        raise SystemExit(f"产物不完整：{SRC}\\index.html 不在——先跑 app/tool/build_web.ps1")
    # 打进去之前先数一遍关键件，缺 wasm/字体的 zip 发出去就是白屏
    needed = ["index.html", "main.dart.js", "flutter_bootstrap.js",
              "sqlite3.wasm", "drift_worker.js", "manifest.json",
              "icons/Icon-512.png", "favicon.png"]
    missing = [n for n in needed if not (SRC / n).exists()]
    if missing:
        raise SystemExit("产物缺这些关键件，拒绝打包：" + ", ".join(missing))

    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / f"zaoji_web_v{ver}.zip"
    if out.exists():
        out.unlink()
    n = 0
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for root, _dirs, files in os.walk(SRC):
            for f in files:
                p = Path(root) / f
                z.write(p, p.relative_to(SRC).as_posix())
                n += 1
    print(f"zaoji_web_v{ver}.zip：{n} 个文件，{out.stat().st_size:,} B → {out}")
    print(f"（app 版本线 {ver}+{code}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
