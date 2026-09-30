// R47 第四段 · 原型「库存到期提醒」开关行（FR-PAN-04 的推送时机 + 它的本机开关）。
//
// 为什么这行是**无条件**出现的（不像「通知带声音」要等授权）：
// 它写的是这台设备要不要参与到期提醒这条策略，与「系统授权到了没有」是两件事；
// 没授权时它照样是个真实的开关（关掉就真的不发），不是「能打开但什么都不发生」。
// 用法：node tool/proto_expiry_r47.cjs
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const FILE = path.join(ROOT, 'zaoji-prototype.html');
const SNAP = path.join(ROOT, 'dist', 'zaoji-prototype_pre_r47expiry.html');

const src0 = fs.readFileSync(FILE, 'utf8');
fs.writeFileSync(SNAP, src0);
const crlf = src0.indexOf('\r\n') >= 0;
const EOL = crlf ? '\r\n' : '\n';
let src = src0;

function sub(name, linesOld, linesNew) {
  const a = linesOld.join(EOL);
  const n = src.split(a).length - 1;
  if (n !== 1) {
    console.error('✘ [' + name + '] 锚命中 ' + n + ' 次（要 1 次），不动文件');
    process.exit(1);
  }
  src = src.replace(a, linesNew.join(EOL));
  console.log('✔ ' + name);
}

/* ① 偏好状态多一路 */
sub('prefs-state',
  [`    soundOn:true,          // FR-SET-03 通知带声音（关掉＝只留一条静默横幅）`],
  [`    soundOn:true,          // FR-SET-03 通知带声音（关掉＝只留一条静默横幅）`,
   `    expiryNotifyOn:true,   // FR-PAN-04 库存到期提醒（打开 App 时提醒，同一天不重复）`]);

/* ② 声音行之后补一行到期提醒；它不依赖授权态，所以出现在两段条件表达式之外 */
sub('expiry-row',
  [`          '<span class="switch" role="switch" tabindex="0" data-act="pref-switch" data-pref="soundOn" aria-checked="' + (S.prefs.soundOn ? 'true' : 'false') + '"></span></div>'`,
   `        : '') +`,
   `    '</div></div>' +`],
  [`          '<span class="switch" role="switch" tabindex="0" data-act="pref-switch" data-pref="soundOn" aria-checked="' + (S.prefs.soundOn ? 'true' : 'false') + '"></span></div>'`,
   `        : '') +`,
   `      '<div class="row"><span class="row-ico">' + ic('alert', 18) + '</span>' +`,
   `        '<span class="row-main"><span class="row-title">库存到期提醒</span><span class="row-sub">打开 App 时提醒一次，同一天不重复</span></span>' +`,
   `        '<span class="switch" role="switch" tabindex="0" data-act="pref-switch" data-pref="expiryNotifyOn" aria-checked="' + (S.prefs.expiryNotifyOn ? 'true' : 'false') + '"></span></div>' +`,
   `    '</div></div>' +`]);

const checks = [
  ['prefs.expiryNotifyOn', /expiryNotifyOn:true,/],
  ['行标题「库存到期提醒」', /库存到期提醒/],
  ['data-pref="expiryNotifyOn"', /data-pref="expiryNotifyOn"/],
  ['副标题说的是策略不是授权', /打开 App 时提醒一次，同一天不重复/],
];
for (const [name, re] of checks) {
  if (!re.test(src)) { console.error('✘ 自检没过：' + name); process.exit(1); }
  console.log('✔ ' + name);
}
if (src.length <= src0.length) {
  console.error('✘ 体积没变大：' + src0.length + ' -> ' + src.length);
  process.exit(1);
}
console.log('✔ 体积 ' + src0.length + ' -> ' + src.length + '（+' + (src.length - src0.length) + '）');
fs.writeFileSync(FILE, src);
console.log('✔ 已写入 ' + path.relative(ROOT, FILE) + '；快照 dist/zaoji-prototype_pre_r47expiry.html');
