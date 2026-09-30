// R47 第三段（通知）的反向验证工装：把实现故意改坏，看闸门会不会红。
//
// 用法：
//   node tool/notify_r47_mutation.cjs permGate   —— 摘掉「没授权不发」那道门
//   node tool/notify_r47_mutation.cjs prefGate   —— 摘掉「本机开关关掉不发」那道门
//   node tool/notify_r47_mutation.cjs restore    —— 从 dist 快照装回动过的那些文件
//
// 两条纪律写在这里：
// ① 快照先于变异落盘——装回来靠的是改前那一份，不是记忆；
// ② **锚与变异的行尾必须跟着目标文件走**（main.dart 是 CRLF、timer_alert.dart 是 LF）。
//    行尾不对时锚命不中，而「命不中」比报错危险：它会让人以为已经验证过了。
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const ALERT = path.join(ROOT, 'app', 'lib', 'data', 'timer_alert.dart');
const MAIN = path.join(ROOT, 'app', 'lib', 'main.dart');
const SNAP = {};
SNAP[ALERT] = path.join(ROOT, 'dist', 'timer_alert_pristine.dart');
SNAP[MAIN] = path.join(ROOT, 'dist', 'main_pristine_r47notify.dart');

// 多行锚点用数组写、join 时按目标行尾接起来：字面量里不混行尾，CRLF 文件也不会漏命中
const MODES = {
  permGate: {
    file: ALERT,
    anchor: [
      '    if (permission != NotifyPermission.granted) {',
      '      _skipped += fired.length;',
      '      return 0;',
      '    }',
    ],
    bad: [
      '    // ★ 变异：摘掉授权闸门（没授权也照发）',
      '    if (false) {',
      '      _skipped += fired.length;',
      '      return 0;',
      '    }',
    ],
  },
  prefGate: {
    file: MAIN,
    anchor: [
      '    if (!_store.kitchenPrefs.notifyOn) return;',
      '    unawaited(_alert.fire(fired, sound: _store.kitchenPrefs.soundOn));',
    ],
    bad: [
      '    // ★ 变异：本机开关不再拦（关掉「计时结束通知」还是照发）',
      '    unawaited(_alert.fire(fired, sound: _store.kitchenPrefs.soundOn));',
    ],
  },
};

const arg = process.argv[2];
const guard = (label, cond, extra) => {
  if (!cond) { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); process.exit(1); }
  console.log('✔ ' + label);
};

if (arg === 'restore') {
  let n = 0;
  for (const target of [ALERT, MAIN]) {
    const snap = SNAP[target];
    // 只装回动过的那份：没快照说明这个变异本轮没跑过，不该报错。
    if (!fs.existsSync(snap)) {
      console.log('· ' + path.basename(target) + ' 没有快照（本轮没动过），跳过');
      continue;
    }
    const text = fs.readFileSync(snap, 'utf8');
    guard('快照里是原逻辑（不含变异标记）', !text.includes('★ 变异'), path.basename(target));
    fs.writeFileSync(target, text);
    n++;
    console.log('✔ 装回 ' + path.relative(ROOT, target));
  }
  guard('至少恢复了一份', n > 0);
  process.exit(0);
}

const m = MODES[arg];
if (!m) { console.error('未知模式：' + arg); process.exit(1); }
const src = fs.readFileSync(m.file, 'utf8');
const crlf = src.indexOf('\r\n') >= 0;
const EOL = crlf ? '\r\n' : '\n';
const anchor = m.anchor.join(EOL);
const bad = m.bad.join(EOL);

console.log('· 行尾判定：' + (crlf ? 'CRLF' : 'LF') + ' → ' + path.basename(m.file));
const snapPath = SNAP[m.file];
if (!fs.existsSync(snapPath)) fs.writeFileSync(snapPath, src);
guard('改前快照已存且含原逻辑：' + path.relative(ROOT, snapPath),
  fs.readFileSync(snapPath, 'utf8').indexOf(anchor) >= 0);
guard('锚在目标文件里唯一命中', src.split(anchor).length - 1 === 1,
  'n=' + (src.split(anchor).length - 1));

fs.writeFileSync(m.file, src.replace(anchor, bad));
const after = fs.readFileSync(m.file, 'utf8');
guard('变异确实落盘', after.indexOf('★ 变异') >= 0 && after.length !== src.length);
console.log('✔ 变异已写入 ' + path.relative(ROOT, m.file) + '（跑完记得 restore）');
