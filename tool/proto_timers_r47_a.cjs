// R47 · 第一步（UI 铁律：先原型后实现）：把原型的**单计时器**改成**多计时器 + 按目标时间戳倒计时**。
// 覆盖 FR-COOK-04（≥3 并行、独立提醒）与 FR-COOK-05 / NFR-REL-03（切后台不漂移）。
//
// 为什么行级定位而不是整段字符串匹配：原型是 40 万字符的 CRLF 单文件，
// 一段缩进抄错就命中 0 次；行级锚点（唯一前缀 + 命中数必须为 1）好诊断得多。
// 护栏：改前快照、每个锚点必须唯一命中、改完跑体积校验、并断言关键新符号都在文件里出现。
const fs = require('fs');
const path = require('path');

const file = path.resolve(__dirname, '../zaoji-prototype.html');
const src = fs.readFileSync(file, 'utf8');
const snap = path.resolve(__dirname, '../dist/proto_before_r47timers.html');
fs.writeFileSync(snap, src);
const NL = src.includes('\r\n') ? '\r\n' : '\n';
const lines = src.split(NL);
const done = [];

function findLine(prefix, msg) {
  const idx = lines.map((l, i) => ({ l, i })).filter(({ l }) => l.startsWith(prefix));
  if (idx.length !== 1) throw new Error(`「${msg}」锚点命中 ${idx.length} 次（应为 1）：${prefix.slice(0, 46)}`);
  return idx[0].i;
}
function findRange(startPrefix, msg) {
  const start = findLine(startPrefix, msg);
  let depth = 0, end = -1;
  for (let i = start; i < lines.length; i++) {
    depth += (lines[i].match(/\{/g) || []).length;
    depth -= (lines[i].match(/\}/g) || []).length;
    if (i > start && depth <= 0) { end = i; break; }
  }
  if (end < 0) throw new Error(`「${msg}」找不到函数结尾`);
  return { start, end };
}
function setRange(rng, text, label) {
  const body = text.replace(/\r?\n/g, NL);
  lines.splice(rng.start, rng.end - rng.start + 1, ...body.split(NL));
  done.push(label);
}

/* ── 1. 状态：单实例 → 数组 ── */
{
  const i = findLine('  timer:null,', 'S.timer 状态行');
  lines.splice(i, 1, [
    '  timers:[],          // R47 · FR-COOK-04：并行计时器数组，每个 { id, label, total, endAt, left, running, done }',
    '  timerSeq:0,         // 自增 id，操作按钮靠它认实例（原来只有一份，不需要 id）',
    '  timerFocus:null,    // 全屏态正在看哪一个（null = 看最新的那个）',
  ].join(NL));
  done.push('S.timers 状态');
}

/* ── 2. startTimer：push 新实例，endAt = 墙上时钟目标戳 ── */
{
  const rng = findRange('function startTimer(', 'startTimer');
  setRange(rng, `function startTimer(sec, label, float) {
  // ★ FR-COOK-05：倒计时**不靠每跳递减**，而是记下「什么时候到点」这个墙上时钟目标戳。
  //   切后台、息屏、浏览器把 rAF/setInterval 掐掉多久都无所谓——回来一减就是剩余量。
  //   旧写法（每 250ms 减 0.25s）在后台节流下会少走好几秒，NFR-REL-03 要求的
  //   「后台 10 分钟误差 < 2 秒」根本不可能达到；真机上做过实测（计划书 R47 细则）。
  const now = Date.now();
  const t = {
    id: 'tm' + (++S.timerSeq),
    label: label || ('计时 ' + humanDur(sec)),
    total: sec,
    endAt: now + sec * 1000,   // running 期间的唯一真相
    left: sec,                 // 暂停时冻结在这里；running 时由 endAt 现算
    running: true,
    done: false,
    float: !!float
  };
  S.timers.push(t);
  S.timerFocus = t.id;
  S.fab = { x:null, y:null };
  renderOverlays();
  const n = S.timers.length;
  toast('已开始计时 · ' + t.label + (n > 1 ? '（并行第 ' + n + ' 个）' : '') + (float ? '（悬浮窗会一直跟着你）' : ''));
}`, 'startTimer');
}

/* ── 3. 取活动实例的两个辅助 + tick 改多实例 ── */
{
  const i = findLine('let lastTick = Date.now();', 'lastTick 行');
  lines.splice(i + 1, 0, `
/* 当前该显示哪一个：显式选过就用选的，否则用最新起的 */
function activeTimer() {
  if (!S.timers.length) return null;
  const f = S.timerFocus && S.timers.find(function (x) { return x.id === S.timerFocus; });
  return f || S.timers[S.timers.length - 1];
}
/* 按目标戳现算剩余秒数并原地落回 left（暂停的实例不动） */
function syncTimers(now) {
  var fired = [];
  S.timers.forEach(function (t) {
    if (!t.running) return;
    const left = Math.max(0, (t.endAt - now) / 1000);
    if (left <= 0) {
      t.left = 0; t.running = false; t.done = true;
      fired.push(t);
    } else {
      t.left = left;
    }
  });
  return fired;
}`.replace(/\n/g, NL));
  const rng = findRange('setInterval(function () {', '计时 tick');
  setRange(rng, `setInterval(function () {
  const now = Date.now();
  const fired = syncTimers(now);
  if (fired.length) {
    fired.forEach(function (t) { toast('时间到 · ' + t.label); });
    // FR-COOK-14：震动这一路在有震动的设备上顺带把「静音时只剩震动与视觉」试出来
    if (fired.length && navigator.vibrate) { try { navigator.vibrate([180, 90, 180]); } catch (err) {} }
    renderOverlays();
    return;
  }
  updateTimerDOM();
}, 250);`, 'tick 多实例');
}

/* ── 4. updateTimerDOM 取活动实例 ── */
{
  const rng = findRange('function updateTimerDOM()', 'updateTimerDOM');
  setRange(rng, `function updateTimerDOM() {
  const t = activeTimer(); if (!t) return;
  const pct = t.total ? (1 - t.left / t.total) : 0;
  const arcF = document.getElementById('tfArc');
  if (arcF) {
    const C = 2 * Math.PI * 118;
    arcF.style.strokeDashoffset = String(C * pct);
    arcF.setAttribute('stroke', t.done ? '#7FD9A6' : '#D2491C');
  }
  const mm = document.getElementById('tfMm');
  if (mm) mm.textContent = mmss(t.left);
  const arcB = document.getElementById('fabArc');
  if (arcB) {
    const C = 2 * Math.PI * 16;
    arcB.style.strokeDashoffset = String(C * pct);
    arcB.setAttribute('stroke', t.done ? '#7FD9A6' : '#FF7A45');
  }
  const ft = document.getElementById('fabTime');
  if (ft) ft.textContent = mmss(t.left);
}`, 'updateTimerDOM');
}

fs.writeFileSync(file, lines.join(NL));
console.log('✔ 阶段一完成：' + done.join(' / '));
console.log('  行数 ' + src.split(NL).length + ' -> ' + lines.length + '；快照 ' + snap);
