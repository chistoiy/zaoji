// 修 doc_r47_meal.cjs 里漏写 `+` 的字符串续行（JS 不像 Dart 会自动相邻字面量拼接）。
// 规则：某行以 `'` 结尾（不带逗号），下一行以 `'` 开头 → 本行补 ` +`。
const fs = require('fs');
const p = 'tool/doc_r47_meal.cjs';
const src = fs.readFileSync(p, 'utf8');
const EOL = src.includes('\r\n') ? '\r\n' : '\n';
const L = src.split(EOL);
let fixed = 0;
for (let i = 0; i + 1 < L.length; i++) {
  const cur = L[i], next = L[i + 1];
  if (/'$/.test(cur) && !/,$/.test(cur) && /^\s*'/.test(next)) {
    L[i] = cur + ' +';
    fixed++;
  }
}
if (!fixed) { console.error('✘ 一处都没改到——规则不对，别白写'); process.exit(1); }
fs.writeFileSync(p, L.join(EOL));
console.log('✔ 补了 ' + fixed + ' 处续行的 +');
