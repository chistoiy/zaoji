"""从 Chrome 的 netlog 里把真实请求过的 URL 抽出来。

用途：判断「断网时 App 还能不能跑」。Chrome 的 `--log-net-log` 是权威证据——
它记录浏览器真正发起的请求，不依赖服务端日志（服务端日志拿不到浏览器行为，
而且当前那个服务实例是后台任务拉起的，stdout 进了任务日志不是文件）。

判定标准很明确：
  · 出现 `fonts.gstatic.com` 或 `www.gstatic.com` → 运行时在联网取资源，家里断网就废
  · 只出现 `127.0.0.1:8666` → 真正自足
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path
from urllib.parse import urlparse

REPORT = Path(__file__).resolve().parent / "_netlog_out.txt"


def collect_urls(node: object, out: list[str]) -> None:
    """netlog 是嵌套 JSON，URL 存在各种 params 里，递归找 'url' 字段。"""
    if isinstance(node, dict):
        for k, v in node.items():
            if k == "url" and isinstance(v, str):
                out.append(v)
            else:
                collect_urls(v, out)
    elif isinstance(node, list):
        for v in node:
            collect_urls(v, out)


def main() -> int:
    lines: list[str] = []
    for path_str in sys.argv[1:]:
        p = Path(path_str)
        lines.append(f"══ {p.name}  ({p.stat().st_size / 1024 / 1024:.2f} MB)")
        data = json.loads(p.read_text(encoding="utf-8", errors="replace"))
        urls: list[str] = []
        collect_urls(data, urls)

        hosts: Counter[str] = Counter()
        ext_urls: list[str] = []
        font_urls: list[str] = []
        wasm_urls: list[str] = []
        for u in urls:
            if not isinstance(u, str):
                continue
            try:
                host = urlparse(u).hostname or ""
            except ValueError:
                continue
            hosts[host] += 1
            if "gstatic" in host or "googleapis" in host:
                ext_urls.append(u)
            if ".woff2" in u or ".ttf" in u or ".otf" in u:
                font_urls.append(u)
            if ".wasm" in u or "canvaskit" in u:
                wasm_urls.append(u)

        lines.append(f"   URL 条目总数 = {len(urls)}")
        lines.append("   ── 按主机 Top 12 ──")
        for h, c in hosts.most_common(12):
            lines.append(f"      {h or '(空)':<40} x{c}")

        lines.append("   ── 外部（Google）URL ──")
        uniq_ext = sorted(set(ext_urls))
        if uniq_ext:
            for u in uniq_ext[:12]:
                lines.append(f"      {u}")
            if len(uniq_ext) > 12:
                lines.append(f"      …另有 {len(uniq_ext) - 12} 条")
        else:
            lines.append("      无 ✔")

        lines.append("   ── 字体 URL ──")
        for u in sorted(set(font_urls))[:10]:
            lines.append(f"      {u}")
        if not font_urls:
            lines.append("      无")

        lines.append("   ── canvaskit/wasm URL ──")
        for u in sorted(set(wasm_urls))[:6]:
            lines.append(f"      {u}")
        if not wasm_urls:
            lines.append("      无")
        lines.append("")

    text = "\n".join(lines)
    REPORT.write_text(text, encoding="utf-8")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
