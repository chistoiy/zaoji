// R47 第四段（库存到期提醒）的反向验证工装。
//
// 用法：
//   node tool/pantry_r47_mutation.cjs stamp   —— 「被闸门挡掉也落戳」（用户点完授权今天反而不提醒）
//   node tool/pantry_r47_mutation.cjs dedupe  —— 「不去重」（回前台一次就多一次提醒）
//   node tool/pantry_r47_mutation.cjs restore —— 从 dist 快照装回
//
// 行尾必须跟着目标文件（这条坑在 §7.10 记着），多行锚一律用数组 join。
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const WATCH = path.join(ROOT, 'app', 'lib', 'data', 'pantry_watch.dart');
const SNAP = path.join(ROOT, 'dist', 'pantry_watch_pristine.dart');

const MODES = {
  stamp: {
    anchor: ['    if (n > 0) await _markNotified(today);'],
    bad: ['    // ★ 变异：不管发没发出去都落戳', '    await _markNotified(today);'],
  },
  dedupe: {
    anchor: ['    if (_lastNotifiedDay() == today) return 0;'],
    bad: ['    // ★ 变异：不做当天去重'],
  },
};

const arg = process.argv[2];
const guard = (label, cond, extra) => {
  if (!cond) { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); process.exit(1); }
  console.log('✔ ' + label);
};

if (arg === 'restore') {
  guard('快照在', fs.existsSync(SNAP));
  const text = fs.readFileSync(SNAP, 'utf8');
  guard('快照里是原逻辑', !text.includes('★ 变异'));
  fs.writeFileSync(WATCH, text);
  console.log('✔ 装回 ' + path.relative(ROOT, WATCH));
  process.exit(0);
}

const m = MODES[arg];
if (!m) { console.error('未知模式：' + arg); process.exit(1); }
const src = fs.readFileSync(WATCH, 'utf8');
const crlf = src.indexOf('\r\n') >= 0;
const EOL = crlf ? '\r\n' : '\n';
const anchor = m.anchor.join(EOL);
const bad = m.bad.join(EOL);

console.log('· 行尾判定：' + (crlf ? 'CRLF' : 'LF'));
if (!fs.existsSync(SNAP)) fs.writeFileSync(SNAP, src);
guard('改前快照已存且含原逻辑', fs.readFileSync(SNAP, 'utf8').indexOf(anchor) >= 0);
guard('锚唯一命中', src.split(anchor).length - 1 === 1, 'n=' + (src.split(anchor).length - 1));

fs.writeFileSync(WATCH, src.replace(anchor, bad));
const after = fs.readFileSync(WATCH, 'utf8');
guard('变异确实落盘', after.includes('★ 变异') && after.length !== src.length);
console.log('✔ 变异已写入 ' + path.relative(ROOT, WATCH) + '（跑完记得 restore）');
