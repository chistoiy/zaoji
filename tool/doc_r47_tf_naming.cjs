// 纠一条注释里的错账：`SystemUiOverlayStyle.light` / `.dark` 的名字指的是**图标**颜色，
// 不是背景颜色（本仓库第一版注释写反了，读 framework 源码核对：
// `services/system_chrome.dart:316` 的 `light` 里 `statusBarIconBrightness: Brightness.light`；
// `material/app.dart:1003` 给深色主题推的正是 `.light`）。
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');

const FIX = [
  {
    file: path.join(ROOT, '灶记-交接文档.md'),
    from: '（★ 命名坑：Flutter 的 `SystemUiOverlayStyle.light` 指「浅色背景配深色图标」，与直觉相反，所以这里逐项写死不用那两个常量）',
    to: '（★ 读源码核对过：`SystemUiOverlayStyle.light` / `.dark` 的名字指的是**图标**颜色，' +
      '不是背景色——`system_chrome.dart:316` 的 `light` 里就是 `statusBarIconBrightness: Brightness.light`，' +
      '而 `material/app.dart:1003` 给深色主题推的正是 `.light`。这个命名历史上翻转过，谁记错谁调反，' +
      '所以逐项写死、不借那两个常量）',
  },
  {
    file: path.join(ROOT, '灶记-开发计划书.md'),
    from: '（★ `SystemUiOverlayStyle.light` 指的是「浅色背景配深色图标」，与直觉相反，所以逐项写死不用常量）',
    to: '（★ 名字指的是**图标**色不是背景色，`system_chrome.dart:316` 核对过；命名翻转过几次，所以逐项写死不用常量）',
  },
];

let bad = 0;
const staged = new Map();
const check = process.argv.includes('--check');
for (const e of FIX) {
  const raw = fs.readFileSync(e.file, 'utf8');
  const eol = raw.includes('\r\n') ? '\r\n' : '\n';
  const j = (s) => s.split('\n').map((x) => x.replace(/\r$/, '')).join(eol);
  const base = staged.get(e.file) || raw;
  const from = j(e.from), to = j(e.to);
  const hits = base.split(from).length - 1;
  if (hits !== 1) {
    console.log(`[${path.basename(e.file)}] 命中 ${hits} 次 → FAIL :: ${e.from.slice(0, 40)}`);
    bad++;
    continue;
  }
  console.log(`[${path.basename(e.file)}] OK`);
  staged.set(e.file, base.replace(from, to));
}
if (bad) { console.log(`${bad} 处没对上，未写盘。`); process.exit(1); }
if (check) { console.log('--check：命中，未写盘。'); process.exit(0); }
for (const [f, text] of staged) {
  fs.writeFileSync(f, text, 'utf8');
  console.log(`写盘 ${path.basename(f)}`);
}
