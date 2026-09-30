/* eslint-disable */
// 修上一处版式：行 18 落在了空行之后（脱离主表 + 引用块前缺空行）。
// 目标版式：| 17 | / | 18 | / 空行 / > ### R38...。把空行与行 18 对调即可。
const fs = require('fs');
const path = require('path');
const target = path.resolve(__dirname, '..', '灶记-交接文档.md');
const src = fs.readFileSync(target, 'utf8');
const NL = src.includes('\r\n') ? '\r\n' : '\n';
const lines = src.split(/\r?\n/);

const i18 = lines.findIndex((l) => l.startsWith('| 18 | **R44 / R45 之后的实况与立项'));
if (i18 < 0) { console.error('ABORT: 找不到行 18'); process.exit(1); }
if (i18 < 1 || lines[i18 - 1].trim() !== '' || !lines[i18 - 2].startsWith('| 17 |')) {
  console.error('ABORT: 行 18 上方的形态与预期不符，不做改动');
  process.exit(1);
}
const after = lines[i18 + 1] === undefined ? '' : lines[i18 + 1];
if (!after.startsWith('> ### R38')) {
  console.error('ABORT: 行 18 下方不是 R38 引用块'); process.exit(1);
}
// 对调：空行 ↔ 行 18
[lines[i18 - 1], lines[i18]] = [lines[i18], lines[i18 - 1]];
const out = lines.join(NL);
if (Buffer.byteLength(out, 'utf8') !== Buffer.byteLength(src, 'utf8')) {
  console.error('ABORT: 对调后字节数变了'); process.exit(1);
}
const check = out.split(/\r?\n/);
if (!(check[i18 - 1].startsWith('| 18 |') && check[i18].trim() === '' && check[i18 + 1].startsWith('> ### R38'))) {
  console.error('ABORT: 对调后版式仍不对'); process.exit(1);
}
fs.writeFileSync(target, out, 'utf8');
console.log('OK 版式已修正：| 17 | → | 18 | → 空行 → 引用块');
