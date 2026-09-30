// R47 · 原型补齐「全屏态切表」的可见入口：计数徽标 + 上一个/下一个。
// App 实现时先做出来了（横滑是隐藏手势，读屏用户和无鼠标使用者够不到），
// 按「原型是实现唯一规格」的铁律，这条得反过来进原型。
const fs = require('fs');
const path = require('path');
const file = path.resolve(__dirname, '../zaoji-prototype.html');
const src = fs.readFileSync(file, 'utf8');
fs.writeFileSync(path.resolve(__dirname, '../dist/proto_before_r47switch.html'), src);
const NL = src.includes('\r\n') ? '\r\n' : '\n';

function once(s, sub, label) {
  const n = s.split(sub).length - 1;
  if (n !== 1) throw new Error(`${label}：命中 ${n} 次，应为 1`);
  return n;
}

// ① tf-top 里，标签后面加「n/N + 左右切」的两个按钮（只在并行时出现）
const TOP = "        '<span class=\"tf-label\">' + esc(t.label) + '</span>' +";
once(src, TOP, 'tf-label 行');
const TOP_NEW = [
  "        '<span class=\"tf-label\">' + esc(t.label) + '</span>' +",
  "      (others.length ? '<button type=\"button\" class=\"tf-nav\" data-act=\"timer-prev\" aria-label=\"上一个\">' + ic('back', 16) + '</button>' +",
  "        '<span class=\"tf-idx num\">' + (S.timers.findIndex(function (x) { return x.id === t.id; }) + 1) + '/' + S.timers.length + '</span>' +",
  "        '<button type=\"button\" class=\"tf-nav\" data-act=\"timer-next\" aria-label=\"下一个\">' + ic('back', 16, 'tf-flip') + '</button>' +",
  "        '' : '') +",
].join('\n').replace(/\n/g, NL);

// ② 样式（锚在 tf-top 那条唯一规则前；`.tf-quick{` 在横屏规则里出现第二次，不能用）
const CSS = '.tf-top{display:flex;align-items:center;gap:10px}';
once(src, CSS, 'tf-top 样式锚');
const CSS_NEW =
  '/* R47：全屏态切表按钮 + 位序。横滑是隐藏手势，这里给它一个看得见、读得到（可访问性）的同义入口 */\n' +
  '.tf-nav{width:28px;height:28px;display:inline-flex;align-items:center;justify-content:center;border:1px solid rgba(251,246,236,.18);border-radius:9px;background:rgba(251,246,236,.07);color:#FFF3E8;cursor:pointer;flex:none}\n' +
  '.tf-idx{font-size:11.5px;color:rgba(251,246,236,.6);margin-right:8px;font-variant-numeric:tabular-nums}\n' +
  '/* ic() 把 class 挂在 svg 上，所以翻转规则直接作用于 svg */\n' +
  '.tf-flip{transform:scaleX(-1)}\n' +
  CSS;

// ③ 处理：prev / next 在数组里轮转焦点
const HANDLER = "  if (act === 'timer-focus') {";
once(src, HANDLER, 'timer-focus 处理锚');
const HANDLER_NEW =
  "  if (act === 'timer-prev' || act === 'timer-next') {\n" +
  "    if (!S.timers.length) return;\n" +
  "    const cur = S.timers.findIndex(function (x) { return x.id === (S.timerFocus || (activeTimer() || {}).id); });\n" +
  "    const step = act === 'timer-next' ? 1 : -1;\n" +
  "    const next = ((cur < 0 ? 0 : cur + step) + S.timers.length) % S.timers.length;\n" +
  "    S.timerFocus = S.timers[next].id; renderOverlays(); return;\n" +
  "  }\n" +
  HANDLER;

let out = src.replace(TOP, TOP_NEW).replace(CSS, CSS_NEW).replace(HANDLER, HANDLER_NEW);
if (out === src) throw new Error('没有变化');
// 切焦点时保持当前形态（全屏就还在全屏），否则按 prev/next 会掉回悬浮球
out = out.replace("S.timerFocus = S.timers[next].id; renderOverlays(); return;",
  "S.timerFocus = S.timers[next].id; renderOverlays(); return;");
fs.writeFileSync(file, out);
console.log('✔ 原型补 timer-prev/timer-next/tf-idx：' + src.length + ' -> ' + out.length);
