// R47 第三段 · 原型「计时结束通知与声音」（FR-COOK-14 + FR-SET-03 声音这一路）。
//
// UI 铁律：先改原型再动实现。这一段新增的是**两行开关与一段授权态文案**，
// 所以原型必须先长成这个样子，实现才有对照物。
//
// 每条替换都带断言：锚必须唯一命中，改完体积必须变大，且当场检查新标识符出现次数。
// 用法：node tool/proto_notify_r47.cjs
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const FILE = path.join(ROOT, 'zaoji-prototype.html');
const SNAP = path.join(ROOT, 'dist', 'zaoji-prototype_pre_r47notify.html');

const lf = (s) => s.replace(/\n/g, '\r\n'); // 原型整份是 CRLF
let src = fs.readFileSync(FILE, 'utf8');
fs.writeFileSync(SNAP, src);
const before = src.length;
const hits = [];

function sub(name, anchor, replacement, expectHits = 1) {
  const a = lf(anchor);
  const n = src.split(a).length - 1;
  if (n !== expectHits) {
    console.error(`✘ [${name}] 锚命中 ${n} 次（要 ${expectHits}），不动文件`);
    process.exit(1);
  }
  src = src.replace(a, lf(replacement));
  hits.push(name);
}

/* ① 图标：声音那行要用一个线性小喇叭，仓库里没有 volume，补一个 */
sub('icon-sound',
  `  bell:'<path d="M6.6 10.2a5.4 5.4 0 0 1 10.8 0c0 4.9 1.9 6 1.9 6H4.7s1.9-1.1 1.9-6Z"/><path d="M10 19.4a2.2 2.2 0 0 0 4 0"/>',\n`,
  `  bell:'<path d="M6.6 10.2a5.4 5.4 0 0 1 10.8 0c0 4.9 1.9 6 1.9 6H4.7s1.9-1.1 1.9-6Z"/><path d="M10 19.4a2.2 2.2 0 0 0 4 0"/>',\n` +
  `  sound:'<path d="M4.6 9.4h2.9l4.2-3.4v11.8l-4.2-3.4H4.6z"/><path d="M15.2 9.2a3.9 3.9 0 0 1 0 5.6"/>',\n`);

/* ② 偏好状态：通知与声音各一路，默认都开（与 App 的 KitchenPrefs 同一份默认值） */
sub('prefs-state',
  `    vibrateOn:true,        // FR-SET-03 计时结束震动（默认开，与 App 的 KitchenPrefs 同一份默认值）\n`,
  `    vibrateOn:true,        // FR-SET-03 计时结束震动（默认开，与 App 的 KitchenPrefs 同一份默认值）\n` +
  `    notifyOn:true,         // FR-COOK-14 计时结束通知（默认开；真机第一次打开要向系统要授权）\n` +
  `    soundOn:true,          // FR-SET-03 通知带声音（关掉＝只留一条静默横幅）\n`);

/* ③ 授权态：这是系统的状态不是本机偏好，所以挂在 S 上而不是 S.prefs 里 */
sub('perm-state',
  `\n  },                      // R47：本机偏好，App 落 local_pref、不参与同步\n`,
  `\n  },                      // R47：本机偏好，App 落 local_pref、不参与同步\n` +
  `  notifyPerm:'default',   // R47 · 系统通知授权态（'default'/'granted'/'denied'）；\n` +
  `                          //   真机由系统弹框决定，原型只能模拟「用户点了允许」这一种\n`);

/* ④ 两行开关：通知行永远在；声音行只在「通知开着且已授权」时才出现——
      没授权就摆一枚能点的声音开关，又是「能打开但什么都不发生」 */
sub('ui-rows',
  `        '<span class="switch" role="switch" tabindex="0" data-act="pref-switch" data-pref="vibrateOn" aria-checked="' + (S.prefs.vibrateOn ? 'true' : 'false') + '"></span></div>' +\n`,
  `        '<span class="switch" role="switch" tabindex="0" data-act="pref-switch" data-pref="vibrateOn" aria-checked="' + (S.prefs.vibrateOn ? 'true' : 'false') + '"></span></div>' +\n` +
  `      '<div class="row"><span class="row-ico">' + ic('bell', 18) + '</span>' +\n` +
  `        '<span class="row-main"><span class="row-title">计时结束通知</span><span class="row-sub">' +\n` +
  `          (S.prefs.notifyOn\n` +
  `            ? (S.notifyPerm === 'granted' ? '到点在通知栏提醒一次'\n` +
  `              : (S.notifyPerm === 'denied' ? '系统已拒绝，只剩震动与视觉' : '打开它要向系统要一次授权'))\n` +
  `            : '不开通知，只剩震动与视觉') +\n` +
  `        '</span></span>' +\n` +
  `        '<span class="switch" role="switch" tabindex="0" data-act="pref-switch" data-pref="notifyOn" aria-checked="' + (S.prefs.notifyOn ? 'true' : 'false') + '"></span></div>' +\n` +
  `      (S.prefs.notifyOn && S.notifyPerm === 'granted'\n` +
  `        ? '<div class="row"><span class="row-ico">' + ic('sound', 18) + '</span>' +\n` +
  `          '<span class="row-main"><span class="row-title">通知带声音</span><span class="row-sub">' +\n` +
  `            (S.prefs.soundOn ? '跟着系统的音量与静音档走' : '静音：通知栏只落一条横幅') +\n` +
  `          '</span></span>' +\n` +
  `          '<span class="switch" role="switch" tabindex="0" data-act="pref-switch" data-pref="soundOn" aria-checked="' + (S.prefs.soundOn ? 'true' : 'false') + '"></span></div>'\n` +
  `        : '') +\n`);

/* ⑤ 处理器：翻「通知」到开 = 模拟系统授权通过（真机在这里调 requestNotificationsPermission） */
sub('handler',
  `    if (!(k in S.prefs)) return;\n    S.prefs[k] = !S.prefs[k];\n    renderScreen();\n`,
  `    if (!(k in S.prefs)) return;\n` +
  `    S.prefs[k] = !S.prefs[k];\n` +
  `    /* R47 · 真机在这里调 requestNotificationsPermission()；原型只能模拟「允许」这一支 */\n` +
  `    if (k === 'notifyOn' && S.prefs.notifyOn && S.notifyPerm !== 'granted') S.notifyPerm = 'granted';\n` +
  `    renderScreen();\n`);

/* —— 落地前的自检 —— */
const checks = [
  ["icon 'sound' 已加", /sound:'<path/],
  ['prefs.notifyOn', /notifyOn:true,/],
  ['prefs.soundOn', /soundOn:true,/],
  ['S.notifyPerm 状态位', /notifyPerm:'default',/],
  ['通知行开关', /data-pref="notifyOn"/],
  ['声音行开关', /data-pref="soundOn"/],
  ['授权后档位才出现', /S\.prefs\.notifyOn && S\.notifyPerm === 'granted'/],
  ['处理器里的模拟授权', /k === 'notifyOn' && S\.prefs\.notifyOn/],
];
for (const [name, re] of checks) {
  const n = (src.match(new RegExp(re.source, 'g')) || []).length;
  if (n < 1) { console.error(`✘ 自检没过：${name}（命中 ${n}）`); process.exit(1); }
  console.log(`✔ ${name}（命中 ${n}）`);
}
if (src.length <= before) {
  console.error(`✘ 体积没变大：${before} -> ${src.length}，判定为误伤`);
  process.exit(1);
}
console.log(`✔ 体积 ${before} -> ${src.length}（+${src.length - before}）`);
fs.writeFileSync(FILE, src);
console.log(`✔ 已写入 ${path.relative(ROOT, FILE)}；替换 5 处：${hits.join('、')}`);
console.log(`  改前快照：${path.relative(ROOT, SNAP)}`);
