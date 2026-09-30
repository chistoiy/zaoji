// 小补丁：把第四段原型走查的断言条数（17 条）补进三份文档里那两处含糊说法。
// 用法：node tool/doc_r47_pantry_count.cjs
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');
const guard = (label, cond, extra) => {
  if (!cond) { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); process.exit(1); }
  console.log('✔ ' + label);
};
function patch(file, edits) {
  const P = path.join(ROOT, file);
  const before = fs.readFileSync(P, 'utf8');
  fs.writeFileSync(path.join(ROOT, 'dist', 'r47count_' + file.replace(/[^\w]/g, '_') + '.bak'), before);
  let src = before;
  for (const [label, oldSub, newSub] of edits) {
    const n = src.split(oldSub).length - 1;
    guard(file + ' · ' + label, n === 1, 'n=' + n);
    src = src.replace(oldSub, newSub);
  }
  guard(file + ' · 行数没变', src.split('\n').length === before.split('\n').length);
  fs.writeFileSync(P, src);
}
patch('灶记-交接文档.md', [
  ['§五 ⑦ 走查条数', 'tool/proto_expiry_r47_walk.cjs` 全 PASS', 'tool/proto_expiry_r47_walk.cjs`（**17 条**）全 PASS'],
  ['§六-20 走查条数', 'notify 22 / expiry / nutrition 40', 'notify 22 / expiry 17 / nutrition 40'],
  ['§九 走查条数', '原型 `proto_expiry_r47.cjs` + 走查全 PASS', '原型 `proto_expiry_r47.cjs` + 走查 17 条全 PASS'],
]);
patch('灶记-开发计划书.md', [
  ['§22.2 走查条数', '原型先行、走查全 PASS', '原型先行、走查 17 条全 PASS'],
]);
console.log('✔ 全部改完');
