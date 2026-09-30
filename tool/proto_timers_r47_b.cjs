// R47 · 第二步：原型的**渲染与操作**跟着多实例走（第一步已把状态与内核改掉）。
// 覆盖：做菜页计时条（列出全部并行计时器）、全屏态「其他计时器」列表、悬浮球计数徽标、
//       所有 timer-* 操作改成按 id 认实例（FR-COOK-04「独立运行、独立提醒」）。
const fs = require('fs');
const path = require('path');

const file = path.resolve(__dirname, '../zaoji-prototype.html');
const src = fs.readFileSync(file, 'utf8');
fs.writeFileSync(path.resolve(__dirname, '../dist/proto_before_r47timers_b.html'), src);
const NL = src.includes('\r\n') ? '\r\n' : '\n';
const lines = src.split(NL);
const done = [];

function findLine(prefix, msg) {
  const hits = lines.map((l, i) => ({ l, i })).filter(({ l }) => l.startsWith(prefix));
  if (hits.length !== 1) throw new Error(`「${msg}」锚点命中 ${hits.length} 次（应为 1）：${prefix.slice(0, 44)}`);
  return hits[0].i;
}
function spliceLines(start, count, text, label) {
  lines.splice(start, count, ...text.replace(/\r?\n/g, NL).split(NL));
  done.push(label);
}

/* ── 1. 全屏计时器下面加「其他计时器」列表的样式 ── */
{
  const i = findLine('.timer-full-inner{', '.timer-full-inner 样式');
  spliceLines(i + 1, 0, `
/* R47 · 并行计时器列表（FR-COOK-04）：全屏态里除主环以外，其余各占一行，能各自暂停/关闭/切焦点 */
.tf-others{margin-top:18px;display:flex;flex-direction:column;gap:7px}
.tf-other{display:flex;align-items:center;gap:10px;padding:9px 12px;border-radius:12px;
  background:rgba(251,246,236,.06);border:1px solid rgba(251,246,236,.10);cursor:pointer}
.tf-other.is-focus{background:rgba(210,73,28,.18);border-color:rgba(210,73,28,.46)}
.tf-other .ot{font-variant-numeric:tabular-nums;font-size:14px;color:#FFF3E8;min-width:52px}
.tf-other .ol{flex:1;font-size:12.5px;color:rgba(251,246,236,.72);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tf-other .ob{width:26px;height:26px;display:inline-flex;align-items:center;justify-content:center;
  border:none;border-radius:8px;background:rgba(251,246,236,.10);color:#FFF3E8;cursor:pointer}
/* 悬浮球上的并行计数：一眼知道后台挂着几个 */
.fab-count{position:absolute;top:-5px;right:-5px;min-width:17px;height:17px;padding:0 4px;
  border-radius:9px;background:var(--accent);color:#FFF3E8;font-size:10px;font-weight:700;
  display:inline-flex;align-items:center;justify-content:center;box-shadow:0 2px 8px rgba(35,28,21,.35)}`, ''.trim());
  done.push('CSS');
}

/* ── 2. 做菜页计时条：列出全部 ── */
{
  const i = findLine('  const timers = S.timer', '做菜页计时条');
  spliceLines(i, 9, `  const timers = S.timers.length
    ? '<div class="cook-timers">' + S.timers.map(function (t) {
        return '<div class="cook-timer">' +
          '<span class="tt num">' + mmss(t.left) + '</span>' +
          '<span class="tl">' + esc(t.label) +
            (t.done ? ' · 时间到' : t.running ? ' · 计时中' : ' · 已暂停') + '</span>' +
          '<button type="button" class="tb" data-act="timer-toggle" data-id="' + t.id + '" aria-label="暂停/继续">' + ic(t.running ? 'pause' : 'play', 16) + '</button>' +
          '<button type="button" class="tb" data-act="timer-reset" data-id="' + t.id + '" aria-label="重置">' + ic('reset', 16) + '</button>' +
          '<button type="button" class="tb" data-act="timer-close" data-id="' + t.id + '" aria-label="关掉这个计时器">' + ic('close', 16) + '</button>' +
        '</div>';
      }).join('') + '</div>'
    : '';`, '做菜页计时条');
}

/* ── 3. 全屏态：活动实例 + 其他实例列表 ── */
{
  const i = findLine('  const t = S.timer || ', 'timerFullHTML 首行');
  spliceLines(i, 1, `  const t = activeTimer() || { total:300, left:300, running:false, label:'5分钟', done:false };
  const others = S.timers.filter(function (x) { return x.id !== t.id; });`, '全屏态首行');

  // 在 tf-quick 那段之后插「其他计时器」列表
  const q = findLine("      '<div class=\"tf-quick\">' + QUICK.map(function (q) {", 'tf-quick 段');
  spliceLines(q, 3, `      '<div class="tf-quick">' + QUICK.map(function (q) {
        return '<button type="button" class="tf-q" data-act="timer-set" data-sec="' + q.s + '">' + q.l + '</button>';
      }).join('') + '</div>' +
      (others.length ? '<div class="tf-others">' + others.map(function (o) {
        return '<div class="tf-other" data-act="timer-focus" data-id="' + o.id + '">' +
          '<span class="ot num">' + mmss(o.left) + '</span>' +
          '<span class="ol">' + esc(o.label) + (o.done ? ' · 时间到' : o.running ? ' · 计时中' : ' · 已暂停') + '</span>' +
          '<button type="button" class="ob" data-act="timer-toggle" data-id="' + o.id + '" aria-label="暂停/继续">' + ic(o.running ? 'pause' : 'play', 14) + '</button>' +
          '<button type="button" class="ob" data-act="timer-close" data-id="' + o.id + '" aria-label="关掉这个计时器">' + ic('close', 14) + '</button>' +
        '</div>';
      }).join('') + '</div>' : '') +`, '其他计时器列表');

  // 主环上的四个按钮补 data-id（toggle/reset/add/close/min）
  const idify = [
    ['timer-min', "        '<button type=\"button\" class=\"iconbtn\" data-act=\"timer-min\" aria-label=\"收起为悬浮窗\">'"],
    ['timer-close', "        '<button type=\"button\" class=\"iconbtn\" data-act=\"timer-close\" aria-label=\"关闭计时器\">'"],
    ['timer-reset', "          '<button type=\"button\" class=\"tf-btn\" data-act=\"timer-reset\" aria-label=\"重置\">'"],
    ['timer-toggle', "          '<button type=\"button\" class=\"tf-btn tf-main\" data-act=\"timer-toggle\" aria-label=\"暂停/继续\">'"],
    ['timer-add', "          '<button type=\"button\" class=\"tf-btn\" data-act=\"timer-add\" data-sec=\"60\" aria-label=\"加一分钟\">'"],
  ];
  for (const [act, prefix] of idify) {
    const li = findLine(prefix, '全屏按钮 ' + act);
    lines[li] = lines[li].replace("data-act=\"" + act + "\"", "data-act=\"" + act + "\" data-id=\"' + t.id + '\"");
    if (!lines[li].includes('data-id')) throw new Error('全屏按钮 ' + act + ' 补 data-id 失败');
  }
  done.push('全屏态');
}

/* ── 4. 悬浮球：取活动实例 + 并行计数徽标 ── */
{
  const i = findLine("  const t = S.timer; if (!t) return '';", 'timerFabHTML 首行');
  spliceLines(i, 1, "  const t = activeTimer(); if (!t) return '';", '悬浮球首行');
  const j = findLine("    '<span class=\"fab-act\">' +", 'fab-act 段');
  for (const act of ['timer-toggle', 'timer-reset', 'timer-max']) {
    const li = lines.map((l, k) => ({ l, k })).filter(({ l }) => l.includes('data-act="' + act + '"') && l.includes('fab-btn')).map(({ k }) => k);
    if (li.length !== 1) throw new Error('悬浮球按钮 ' + act + ' 命中 ' + li.length + ' 次');
    lines[li[0]] = lines[li[0]].replace("data-act=\"" + act + "\"", "data-act=\"" + act + "\" data-id=\"' + t.id + '\"");
  }
  const k = findLine("    '<span class=\"fab-info\">' +", 'fab-info 段');
  spliceLines(k, 0, "    (S.timers.length > 1 ? '<span class=\"fab-count num\">' + S.timers.length + '</span>' : '') +", '并行计数徽标');
}

/* ── 5. overlay 出口按活动实例 ── */
{
  const i = findLine('  if (S.timer && !S.timer.float) html += timerFullHTML();', 'overlay 判定');
  spliceLines(i, 2, `  const at = activeTimer();
  if (at && !at.float) html += timerFullHTML();
  if (at && at.float) html += timerFabHTML();`, 'overlay 判定');
}

/* ── 6. timer-* 操作全部按 id 认实例 ── */
{
  const i = findLine("  if (act === 'timer-toggle') {", 'timer-toggle 处理');
  spliceLines(i, 22, `  /* ★ 每个操作都按 data-id 认实例：并行计时器要「独立运行、独立提醒」（FR-COOK-04），
     拿全局那一份来 toggle 会让两个锅共用一个暂停键。 */
  function timerOf(el) {
    const id = el && el.dataset ? el.dataset.id : null;
    return id ? (S.timers.find(function (x) { return x.id === id; }) || null) : activeTimer();
  }
  if (act === 'timer-toggle') {
    const t = timerOf(el); if (!t) return;
    if (t.done) { t.left = t.total; t.done = false; t.endAt = Date.now() + t.total * 1000; t.running = true; }
    else if (t.running) { t.left = Math.max(0, (t.endAt - Date.now()) / 1000); t.running = false; } // 暂停：把剩余量冻结下来
    else { t.endAt = Date.now() + t.left * 1000; t.running = true; }                                // 续跑：重新算目标戳
    renderOverlays(); return;
  }
  if (act === 'timer-reset') {
    const t = timerOf(el); if (!t) return;
    t.left = t.total; t.running = false; t.done = false; t.endAt = Date.now() + t.total * 1000;
    renderOverlays(); toast('计时器已重置'); return;
  }
  if (act === 'timer-set') { startTimer(parseInt(el.dataset.sec, 10), el.textContent.trim()); return; }
  if (act === 'timer-add') {
    const t = timerOf(el); if (!t) return;
    // 加时是**改目标戳**，不是改显示值：否则下一次 tick 立刻又把它减回去
    if (t.running) t.endAt += parseInt(el.dataset.sec, 10) * 1000;
    else t.left += parseInt(el.dataset.sec, 10);
    t.total = Math.max(t.total, t.running ? (t.endAt - Date.now()) / 1000 : t.left);
    t.done = false;
    updateTimerDOM(); return;
  }
  if (act === 'timer-focus') {
    const t = timerOf(el); if (!t) return;
    S.timerFocus = t.id; renderOverlays(); return;
  }
  if (act === 'timer-min') { const t = activeTimer(); if (t) t.float = true; renderOverlays(); toast('已收成悬浮窗，可拖动'); return; }
  if (act === 'timer-max') { const t = activeTimer(); if (t) t.float = false; renderOverlays(); return; }
  if (act === 'timer-close') {
    const t = timerOf(el); if (!t) return;
    S.timers = S.timers.filter(function (x) { return x.id !== t.id; });
    if (!S.timers.length) S.timerFocus = null;
    renderOverlays(); toast(S.timers.length ? '已关掉一个计时器（还剩 ' + S.timers.length + ' 个）' : '已关闭计时器');
    return;
  }`, 'timer-* 处理');
}

/* ── 7. 深链 #timer=300&float=1 跟着改 ── */
{
  const i = findLine('    if (q.float) { S.timer.float = true; renderOverlays(); }', '深链 float');
  spliceLines(i, 1, "    if (q.float) { const at = activeTimer(); if (at) at.float = true; renderOverlays(); }", '深链 float');
}

const out = lines.join(NL);
if (out.length < src.length) throw new Error('体积反而变小，可疑');
if (/S\.timer\b(?!s)/.test(out)) {
  const m = out.match(/.{0,60}S\.timer\b(?!s).{0,60}/g);
  throw new Error('还有残留的单实例引用：\n  ' + m.join('\n  '));
}
fs.writeFileSync(file, out);
console.log('✔ 第二步完成：' + done.join(' / '));
console.log('  体积 ' + src.length + ' -> ' + out.length + '，行数 ' + src.split(NL).length + ' -> ' + lines.length);
