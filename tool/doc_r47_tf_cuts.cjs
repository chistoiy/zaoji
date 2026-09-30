// 反向验证从四刀加到五刀（补了 noRestore 那一刀），把三份文档里的「四刀」改过来。
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');

const JOBS = [
  {
    file: path.join(ROOT, '灶记-交接文档.md'),
    pairs: [
      ['反向验证 `tool/r47tf_mutation.cjs` **四刀**（`occupy` / `snap` / `vibrate` / `overlay`）：',
        '反向验证 `tool/r47tf_mutation.cjs` **五刀**（`occupy` / `snap` / `vibrate` / `overlay` / `noRestore`）：'],
      ['`tool/r47tf_mutation.cjs` 四刀（occupy/snap/vibrate/overlay）各红一条、装回逐字节一致；',
        '`tool/r47tf_mutation.cjs` 五刀（occupy/snap/vibrate/overlay/noRestore）各红一条、装回逐字节一致；'],
      ['反向验证 `tool/r47tf_mutation.cjs` 四刀各红一条、装回逐字节一致。**基线**',
        '反向验证 `tool/r47tf_mutation.cjs` 五刀各红一条、装回逐字节一致。**基线**'],
    ],
  },
  {
    file: path.join(ROOT, '灶记-开发计划书.md'),
    pairs: [
      ['反向验证 `tool/r47tf_mutation.cjs` **四刀**（occupy/snap/vibrate/overlay）各红一条、装回逐字节一致。',
        '反向验证 `tool/r47tf_mutation.cjs` **五刀**（occupy/snap/vibrate/overlay/noRestore）各红一条、装回逐字节一致。'],
    ],
  },
];

let bad = 0;
const staged = new Map();
const check = process.argv.includes('--check');
for (const job of JOBS) {
  const raw = fs.readFileSync(job.file, 'utf8');
  const eol = raw.includes('\r\n') ? '\r\n' : '\n';
  const j = (s) => s.split('\n').map((x) => x.replace(/\r$/, '')).join(eol);
  let text = staged.get(job.file) || raw;
  for (const [from, to] of job.pairs) {
    const f = j(from), t = j(to);
    const hits = text.split(f).length - 1;
    if (hits !== 1) {
      console.log(`[${path.basename(job.file)}] 「${from.slice(0, 26)}…」命中 ${hits} 次 → FAIL`);
      bad++;
      continue;
    }
    console.log(`[${path.basename(job.file)}] 「${from.slice(0, 26)}…」OK`);
    text = text.replace(f, t);
  }
  staged.set(job.file, text);
}
if (bad) { console.log(`\n${bad} 处没对上，未写盘。`); process.exit(1); }
if (check) { console.log('--check：全部命中，未写盘。'); process.exit(0); }
for (const [f, text] of staged) {
  fs.writeFileSync(f, text, 'utf8');
  console.log(`写盘 ${path.basename(f)}`);
}
