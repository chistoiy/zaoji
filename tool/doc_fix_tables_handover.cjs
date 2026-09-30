/* eslint-disable */
// 修 4 处表格结构缺陷（node tool/doc_table_lint.cjs 扫出来的，都不是本轮新写的内容）：
//  A. §六 大表被两道空行拦腰截断 → 后面的行脱离表格、渲染成裸文本（| 8| 与 | 12| 起的那两组）
//  B. §五 某行少一根竖线（表头 4 列、该行 3 列）
//  C. §7.1 某行少一根竖线（表头 3 列、该行 2 列）
// 护栏：快照 + 每处必须恰好命中一次 + 改完立刻自检。
const fs = require('fs');
const path = require('path');
const root = path.resolve(__dirname, '..');
const target = path.join(root, '灶记-交接文档.md');
const snap = path.join(root, 'dist', 'handover_before_tablefix.md');

const src = fs.readFileSync(target, 'utf8');
const NL = src.includes('\r\n') ? '\r\n' : '\n';
let lines = src.split(/\r?\n/);
fs.writeFileSync(snap, src, 'utf8');

const hits = (pred) => {
  const out = [];
  lines.forEach((l, i) => { if (pred(l, i)) out.push(i); });
  return out;
};

// ── A. 去掉表格中间的两道空行（上一行是表格行、下一行也是表格行的那种空行）──
const strays = hits((l, i) => l.trim() === '' && /^\|/.test(lines[i - 1] || '') && /^\|/.test(lines[i + 1] || ''));
if (strays.length !== 2) {
  console.error(`ABORT: 表格内游离空行预期 2 道，实到 ${strays.length}（行号 ${strays.map((n) => n + 1)}）`);
  process.exit(1);
}
strays.reverse().forEach((i) => lines.splice(i, 1));

// ── B. §五 那条 3 列行补成 4 列（§7.2 里有一行文字几乎相同但它是 4 列、是对的，靠列数区分）──
const colsOf = (line) => {
  let n = 0, esc = false;
  for (const ch of line) {
    if (esc) { esc = false; continue; }
    if (ch === '\\') { esc = true; continue; }
    if (ch === '|') n++;
  }
  return Math.max(n - 1, 0);
};
const b = hits((l) => l.startsWith('| 2 | `conflict` / `cursor` 撞 SQLite 关键字 |') && colsOf(l) === 3);
if (b.length !== 1) { console.error(`ABORT: B 锚点实到 ${b.length} 处（要 1）`); process.exit(1); }
lines[b[0]] =
  '| 2 | `conflict` / `cursor` 撞 SQLite 关键字 | 冲突箱表叫 `conflict`、设备游标叫 `cursor` —— 都是关键字 | ' +
  '改成 `conflict_item` / `sync_cursor`，并加了一条**关键字黑名单测试**（表名、列名都查） |';

// ── C. §7.1 那条 2 列行补成 3 列（现象 / 解法 分栏）──
const c = hits((l) => l.startsWith('| ★ **这台的 WMI 是坏的：读不到进程命令行** |') && colsOf(l) === 2);
if (c.length !== 1) { console.error(`ABORT: C 锚点实到 ${c.length} 处（要 1）`); process.exit(1); }
lines[c[0]] =
  '| ★ **这台的 WMI 是坏的：读不到进程命令行** | `Get-CimInstance Win32_Process` 报「指定的类不存在」、' +
  '`Get-WmiObject Win32_Process` 报「无效类」——想知道在跑的那个服务端是带什么参数起来的，**这条路走不通** | ' +
  '改成问服务自己：`http://127.0.0.1:8666/status` 会把托管中的 web 目录原样打出来，抓 `<code>` 里那条再 ' +
  '`[IO.Path]::GetFullPath` 归一化（`upgrade_local_instance.ps1` 就是这么保住 `-w` 的） |';

fs.writeFileSync(target, lines.join(NL), 'utf8');
const out = fs.readFileSync(target, 'utf8').split(/\r?\n/);
console.log(`OK  行数 ${src.split(/\r?\n/).length} → ${out.length}`);
console.log(`快照 ${path.relative(root, snap)}`);
