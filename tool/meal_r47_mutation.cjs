// R47 第六段（开饭前投待办）的反向验证：摘掉两处**决策**，看测试是否真的红。
//
// 为什么挑这两刀（§7.10：别只摘算术，摘决策才验得到口径）：
//   prefGate —— 「本机开关关掉就不投」。摘了它，FR-SET-01 那枚开关变成装饰，
//                而用户明确关掉的提醒还在往通知栏发。
//   stamp    —— 「只有真发出去才落当日戳」。摘了它（无条件落），
//                症状是「用户当场点完授权，这一餐反而永远不会投」——最合理那步操作把功能自己关掉。
// 用法：node tool/meal_r47_mutation.cjs prefGate|stamp|restore
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const TARGET = path.join(ROOT, 'app', 'lib', 'data', 'meal_reminder.dart');
const SNAP = path.join(ROOT, 'dist', 'meal_reminder_pristine_r47meal.dart');

const mode = process.argv[2];
const guard = (label, cond, extra) => {
  if (!cond) { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); process.exit(1); }
  console.log('✔ ' + label);
};

if (mode === 'restore') {
  guard('快照在', fs.existsSync(SNAP));
  const s = fs.readFileSync(SNAP, 'utf8');
  guard('快照里是原逻辑', s.includes('    if (!_enabled()) return 0;'));
  guard('快照里是原逻辑（落戳那刀）', s.includes('    if (n > 0) await _markNotified(keyOf(pick.menu));'));
  fs.writeFileSync(TARGET, s);
  const back = fs.readFileSync(TARGET);
  guard('装回后与快照逐字节一致', back.equals(fs.readFileSync(SNAP)));
  console.log('✔ 装回 app/lib/data/meal_reminder.dart');
  process.exit(0);
}

const MUT = {
  prefGate: {
    from: '    if (!_enabled()) return 0;',
    to: '    // ★ 变异：摘掉「本机开关关掉就不投」这道闸门（FR-SET-01 变装饰）\n    if (false) return 0;',
  },
  stamp: {
    from: '    if (n > 0) await _markNotified(keyOf(pick.menu));',
    to: '    // ★ 变异：一条都没发出去也照样落戳（今天这餐被永久静音）\n    await _markNotified(keyOf(pick.menu));',
  },
};
const m = MUT[mode];
if (!m) { console.error('✘ 模式只能是 prefGate / stamp / restore，收到：' + mode); process.exit(1); }

const src = fs.readFileSync(TARGET, 'utf8');
if (!fs.existsSync(SNAP)) { fs.writeFileSync(SNAP, src); console.log('✔ 改前快照已存 dist/meal_reminder_pristine_r47meal.dart'); }
const snap = fs.readFileSync(SNAP, 'utf8');
guard('快照里是原逻辑', snap.includes(m.from), mode);

// 行尾跟随目标文件（记过的坑：LF 锚在 CRLF 文件里一条都命不中）
const crlf = src.includes('\r\n');
const join = (s) => (crlf ? s.replace(/\n/g, '\r\n') : s);
const from = join(m.from), to = join(m.to);
guard('锚唯一命中', src.split(from).length - 1 === 1, 'n=' + (src.split(from).length - 1));

const out = src.replace(from, to);
guard('变异已落盘', out.includes(to) && !out.includes(from));
fs.writeFileSync(TARGET, out);
console.log('✔ 变异[' + mode + ']已写入 app/lib/data/meal_reminder.dart（跑完记得 restore）');
