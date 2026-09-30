/* eslint-disable */
// 把 _NutritionBasisSheet.build 里的 _row(...) 调用补上 context 实参
// （定义改成收 context 之后调用点要跟着；定义那一行不动）。行尾原样保留。
const fs = require('fs');
const path = require('path');
const f = path.resolve(__dirname, '..', 'app/lib/ui/recipe_detail_page.dart');
const src = fs.readFileSync(f, 'utf8');
const NL = src.includes('\r\n') ? '\r\n' : '\n';
const lines = src.split(/\r?\n/);
let n = 0;
const outLines = lines.map((l) => {
  if (/Widget _row\(/.test(l)) return l; // 定义不动
  if (/_row\(/.test(l) && !/_row\(context/.test(l)) {
    const next = l.replace(/_row\(/g, '_row(context, ');
    n++;
    return next;
  }
  return l;
});
if (n < 6) { console.error('ABORT: 只改了 ' + n + ' 处，比预期少，先别写盘'); process.exit(1); }
fs.writeFileSync(f, outLines.join(NL), 'utf8');
console.log(`OK 补了 ${n} 处调用；行尾 ${NL === '\r\n' ? 'CRLF' : 'LF'}`);
