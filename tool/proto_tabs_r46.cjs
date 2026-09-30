// R46 · 原型与实现对齐：第三个主标签在 App 里早已是「厨房」（R28 做实），
// 原型的 TABS 还写着「备菜」。只改显示名，不动 id（deep link / TAB_ALIAS 全依赖 id）。
const fs = require('fs');
const path = require('path');
const file = path.resolve(__dirname, '../zaoji-prototype.html');
const snap = path.resolve(__dirname, '../dist/proto_before_r46tabs.html');
const src = fs.readFileSync(file, 'utf8');
fs.writeFileSync(snap, src);

const edits = [
  ["  { id:'prep',     n:'备菜',  i:'basket' },",
   "  { id:'prep',     n:'厨房',  i:'basket' },"],
  ["['recipes','菜谱库'], ['menus','菜单'], ['prep','备菜待办'], ['calendar','日历'], ['me','我的'] ] },",
   "['recipes','菜谱库'], ['menus','菜单'], ['prep','厨房'], ['calendar','日历'], ['me','我的'] ] },"],
];

let out = src;
for (const [from, to] of edits) {
  const n = out.split(from).length - 1;
  if (n !== 1) throw new Error(`命中 ${n} 次（应为 1）：${from.slice(0, 40)}`);
  out = out.replace(from, to);
}
if (out.length < src.length - 40 || out.length > src.length + 40) {
  throw new Error(`体积异常 ${src.length} -> ${out.length}`);
}
fs.writeFileSync(file, out);
console.log(`✔ 原型标签对齐 2 处，${src.length} -> ${out.length}；快照 ${snap}`);
