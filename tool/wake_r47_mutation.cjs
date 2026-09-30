// 反向验证工装：故意把实现改坏，看新闸门会不会红。
// 用法：node tool/wake_r47_mutation.cjs <apply|revert>
//   apply  —— 摘掉 done() 的引用计数条件（最后一路没撤就关灯）
//   revert —— 从 pristine 快照装回去
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');
const TARGET = path.join(ROOT, 'app', 'lib', 'data', 'screen_wake.dart');
const PRISTINE = path.join(ROOT, 'dist', 'screen_wake_pristine.dart');

const mode = process.argv[2];
if (mode === 'apply') {
  const src = fs.readFileSync(TARGET, 'utf8');
  const anchor = '    if (!_reasons.remove(reason)) return;\n    if (_reasons.isEmpty) _apply(false);';
  if (src.indexOf(anchor) < 0) { console.error('✘ 锚点没命中，不动文件'); process.exit(1); }
  fs.writeFileSync(TARGET, src.replace(anchor,
    '    if (!_reasons.remove(reason)) return;\n    _apply(false); // ★ 变异：摘掉引用计数'));
  console.log('✔ 变异已写入（done() 不再数剩下几路）');
} else {
  const back = fs.readFileSync(PRISTINE, 'utf8');
  if (back.indexOf('if (_reasons.isEmpty) _apply(false);') < 0) {
    console.error('✘ pristine 快照里没有原逻辑，拒绝装回'); process.exit(1);
  }
  fs.writeFileSync(TARGET, back);
  console.log('✔ 已从快照装回原实现');
}
