// R47 第八段收尾：把「到点振动」这条从"只验到标记"升级成"真机已确认"，
// 并记下那条读到的答案：通知自带的振动**不受**系统「触摸反馈」开关管住。
// 用法：node tool/doc_r47_tf3.cjs [--check]
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');
const HAND = path.join(ROOT, '灶记-交接文档.md');

const OLD =
  '★ 另外 ⑤ 的振动**只验到「通知带上了振动标记」**——真机上震没震仍要人在场（`haptic_feedback_enabled=0` 那台机器' +
  '连系统触感都关了，通知振动是否被同一开关管住，本轮没读到）。';

const NEW =
  '★ **⑤ 的振动同日转"真机已确认"**（用户回「有震动」）：`haptic_feedback_enabled` 实测**仍是 0**，' +
  '而到点那条通知仍震到了——`dumpsys notification --noredact` 读到 `channel=zaoji_timer id=111007737 importance=4`、' +
  '渠道 `mVibrationEnabled=true`。**这条就是本轮改动的全部理由**：老路只调 `HapticFeedback.vibrate()`，' +
  '而它被系统「触摸反馈」开关静默吞掉；改走通知自带的振动之后，同一个关着触感的环境里用户真的感觉到了。' +
  '★ 顺带记一条读数细节：渠道 `mOriginalImp=5` 但 `mImportance=4`、`mUserLockedFields=16` ——' +
  '说明用户在系统通知设置里动过这一档（这正是上轮拍板"声音交给系统通知设置"的那条路，App 不越权改它）。' +
  '**仍然欠的只剩 audible 本身**：adb 读不到"有没有响"，`playSound=true` + 渠道有声音 URI 只是软件侧证据。';

const raw = fs.readFileSync(HAND, 'utf8');
const eol = raw.includes('\r\n') ? '\r\n' : '\n';
const j = (s) => s.split('\n').map((x) => x.replace(/\r$/, '')).join(eol);
const from = j(OLD), to = j(NEW);
const hits = raw.split(from).length - 1;
if (hits !== 1) {
  console.log(`锚点命中 ${hits} 次 → 未写盘。`);
  process.exit(1);
}
console.log('[交接文档] ⑤ 振动：只验到标记 → 真机已确认 OK');
if (process.argv.includes('--check')) {
  console.log('--check：命中，未写盘。');
  process.exit(0);
}
fs.writeFileSync(HAND, raw.replace(from, to), 'utf8');
console.log('写盘 灶记-交接文档.md');
