// R47 第三段 · 原型补丁 ②：把「去授权」做成一行正规入口，而不是塞进副标题里。
//
// 为什么补这一刀：第一版把「打开它要向系统要一次授权」写成一句文字，
// 但**没有可点的入口**——那等于告诉用户一件事却不给做它的地方。
// 授权是系统弹框，只能在用户手势里调，所以给一行按钮（照「复位悬浮按钮」那行的先例）。
// 用法：node tool/proto_notify_r47_fix.cjs
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const FILE = path.join(ROOT, 'zaoji-prototype.html');
const lf = (s) => s.replace(/\n/g, '\r\n');
let src = fs.readFileSync(FILE, 'utf8');
const before = src.length;

function sub(name, anchor, replacement) {
  const a = lf(anchor);
  const n = src.split(a).length - 1;
  if (n !== 1) {
    console.error(`✘ [${name}] 锚命中 ${n} 次（要 1 次），不动文件`);
    process.exit(1);
  }
  src = src.replace(a, lf(replacement));
  console.log(`✔ ${name}`);
}

/* ① 文案收窄：未授权只说「还没拿到」，被拒再说「去系统设置」 */
sub('未授权文案',
  `            ? (S.notifyPerm === 'granted' ? '到点在通知栏提醒一次'\n              : (S.notifyPerm === 'denied' ? '系统已拒绝，只剩震动与视觉' : '打开它要向系统要一次授权'))\n`,
  `            ? (S.notifyPerm === 'granted' ? '到点在通知栏提醒一次'\n              : (S.notifyPerm === 'denied' ? '系统已拒绝，去系统设置里开' : '还没拿到系统授权'))\n`);

/* ② 通知行后面补一行「去授权」入口：只在没授权时出现，拿到就自己收掉 */
sub('去授权入口行',
  `        '<span class="switch" role="switch" tabindex="0" data-act="pref-switch" data-pref="notifyOn" aria-checked="' + (S.prefs.notifyOn ? 'true' : 'false') + '"></span></div>' +\n`,
  `        '<span class="switch" role="switch" tabindex="0" data-act="pref-switch" data-pref="notifyOn" aria-checked="' + (S.prefs.notifyOn ? 'true' : 'false') + '"></span></div>' +\n` +
  `      (S.prefs.notifyOn && S.notifyPerm !== 'granted'\n` +
  `        ? '<button type="button" class="row row-btn" data-act="notify-perm">' +\n` +
  `          '<span class="row-ico">' + ic('bell', 18) + '</span>' +\n` +
  `          '<span class="row-main"><span class="row-title">开启系统通知授权</span>' +\n` +
  `          '<span class="row-sub">' + (S.notifyPerm === 'denied' ? '被拒过，得去系统设置里改' : '系统会弹一次确认，只有手势里能调') + '</span></span>' +\n` +
  `          ic('chevR', 16, 'row-chevr') + '</button>'\n` +
  `        : '') +\n`);

/* ③ 处理器：点它就是发起授权；原型只能模拟「允许」这一支 */
sub('授权处理器',
  `  if (act === 'lead-pick') {\n`,
  `  /* R47 · 发起系统通知授权。真机在这里调 requestNotificationsPermission()，\n` +
  `     原型只能模拟「用户点了允许」；被拒那一支走 denied 文案与入口行的措辞 */\n` +
  `  if (act === 'notify-perm') {\n` +
  `    S.notifyPerm = 'granted';\n` +
  `    renderScreen();\n` +
  `    return;\n` +
  `  }\n` +
  `  if (act === 'lead-pick') {\n`);

/* ④ 摘掉第一版「翻到开就自动算已授权」的假动作：授权只能由那一行入口发起 */
sub('摘掉自动授权',
  `    /* R47 · 真机在这里调 requestNotificationsPermission()；原型只能模拟「允许」这一支 */\n` +
  `    if (k === 'notifyOn' && S.prefs.notifyOn && S.notifyPerm !== 'granted') S.notifyPerm = 'granted';\n`,
  `    /* R47 · 开关只管「要不要通知」；授权是系统弹框，只能由 notify-perm 那一行发起，\n` +
  `       这里绝不能翻个开关就把自己算成已授权（那是假绿的原型版） */\n`);

const checks = [
  ['还没拿到系统授权', /还没拿到系统授权/],
  ['去系统设置里开', /系统已拒绝，去系统设置里开/],
  ['data-act="notify-perm"', /data-act="notify-perm"/],
  ['row-title 开启系统通知授权', /开启系统通知授权/],
  ["S.notifyPerm = 'granted';", /S\.notifyPerm = 'granted';/],
];
for (const [name, re] of checks) {
  if (!re.test(src)) { console.error('✘ 自检没过：' + name); process.exit(1); }
  console.log(`✔ ${name}`);
}
if (src.length <= before) { console.error(`✘ 体积没变大 ${before} -> ${src.length}`); process.exit(1); }
console.log(`✔ 体积 ${before} -> ${src.length}（+${src.length - before}）`);
fs.writeFileSync(FILE, src);
console.log('✔ 已写入 ' + path.relative(ROOT, FILE));
