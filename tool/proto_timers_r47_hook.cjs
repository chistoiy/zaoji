// R47 · 原型调试出口补三件：startTimer / syncTimers / activeTimer。
// 走查脚本要在无头 Chrome 里「把墙上时钟拨快 10 分钟」验 endAt 法不漂移，
// 拿不到这几个函数就只能靠真等——CI 上等 10 分钟不现实，那条断言也就永远没被钉过。
const fs = require('fs');
const path = require('path');
const file = path.resolve(__dirname, '../zaoji-prototype.html');
const src = fs.readFileSync(file, 'utf8');
fs.writeFileSync(path.resolve(__dirname, '../dist/proto_before_r47hook.html'), src);

const ANCHOR = '  S: S, themes: THEMES, screens: Object.keys(SCREENS),';
const n = src.split(ANCHOR).length - 1;
if (n !== 1) throw new Error('锚点命中 ' + n + ' 次，应为 1');
const NL = src.includes('\r\n') ? '\r\n' : '\n';
const add = [
  '  // R47：计时内核的可测出口。S 是 IIFE 里的局部量，以前只暴露了 S 本身，',
  '  // 走查脚本没法「拨时钟」验证 endAt 法，只能靠真等 10 分钟——那条断言因此一直没被钉过。',
  "  startTimer: startTimer, syncTimers: syncTimers, activeTimer: activeTimer, renderOverlays: renderOverlays,",
].join(NL);
const out = src.replace(ANCHOR, ANCHOR + NL + add);
if (out === src) throw new Error('没写进去');
fs.writeFileSync(file, out);
console.log('✔ 出口已补：' + src.length + ' -> ' + out.length);
