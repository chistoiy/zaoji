// R47 第八段 · 原型：悬浮球「拖到边缘自动吸附收成耳朵」+ 点耳朵展开。
// UI 铁律：先改原型再动实现。「全屏时球不显示」原型本来就是互斥渲染
// （renderOverlays 里 at.float 与全屏二选一），是实现把 OverlayEntry 一直挂着——那一件不需要改原型。
// 用法：node tool/proto_fab_r47.cjs   （前置快照 dist/zaoji-prototype_before_r47fab.html）
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const TARGET = path.join(ROOT, 'zaoji-prototype.html');
const SNAP = path.join(ROOT, 'dist', 'zaoji-prototype_before_r47fab.html');

const before = fs.readFileSync(TARGET, 'utf8');
if (!fs.existsSync(SNAP)) {
  console.error('✘ 先拍快照（cp zaoji-prototype.html dist/zaoji-prototype_before_r47fab.html）再跑');
  process.exit(1);
}
console.log('✔ 前置快照在');

// 行尾跟随目标文件（原型是 CRLF）
const EOL = before.includes('\r\n') ? '\r\n' : '\n';
const j = (s) => s.replace(/\n/g, EOL);
let out = before;
let n = 0;
const edit = (label, from0, to0) => {
  n++;
  const from = j(from0), to = j(to0);
  const hits = out.split(from).length - 1;
  if (hits !== 1) { console.error(`✘ [${n}] ${label}：锚命中 ${hits} 次（要 1 次），一个字节都不改`); process.exit(1); }
  out = out.replace(from, to);
  console.log(`✔ [${n}] ${label}`);
};

/* 1 · 耳朵的样式：贴在边缘的一条窄耳朵，圆角只朝内 */
edit('加 .timer-fab.is-ear 样式',
  ".timer-fab.is-paused .fab-ring{opacity:.5}\n",
  ".timer-fab.is-paused .fab-ring{opacity:.5}\n" +
  "/* R47 第八段：拖到左/右边缘松手就吸边收成「耳朵」——挡内容的面积从 148px 缩到 26px，\n" +
  "   点一下耳朵回到完整球。收起态不丢计时（耳朵上带 ×N 徽标），也不自动弹回去。 */\n" +
  ".timer-fab.is-ear{width:26px;height:66px;padding:0;gap:0;border-radius:0 13px 13px 0;\n" +
  "  display:flex;flex-direction:column;align-items:center;justify-content:center;overflow:visible}\n" +
  ".timer-fab.is-ear.on-left{border-radius:13px 0 0 13px}\n" +
  ".timer-fab.is-ear .ear-ico{display:grid;place-items:center;color:rgba(251,246,236,.86)}\n" +
  ".timer-fab.is-ear .fab-ring,.timer-fab.is-ear .fab-info,.timer-fab.is-ear .fab-act{display:none}\n");

/* 2 · 状态：球多两个字段（贴哪一侧、是否收成耳朵） */
edit('S.fab 加 side / collapsed',
  "  fab:{ x:null, y:null },",
  "  fab:{ x:null, y:null, side:'right', collapsed:false },");

/* 3 · 渲染：collapsed 时只画耳朵，不画完整球 */
edit('timerFabHTML 加耳朵分支',
  "  const x = S.fab.x, y = S.fab.y;\n" +
  "  const style = (x !== null && y !== null) ? 'left:' + x + 'px;top:' + y + 'px;right:auto;bottom:auto;' : '';\n",
  "  const x = S.fab.x, y = S.fab.y;\n" +
  "  const style = (x !== null && y !== null) ? 'left:' + x + 'px;top:' + y + 'px;right:auto;bottom:auto;' : '';\n" +
  "  /* 耳朵态：只剩一条贴边的窄耳朵 + （并行时）×N 徽标。点开回到完整球。 */\n" +
  "  if (S.fab.collapsed) {\n" +
  "    return '<div class=\"timer-fab is-ear' + (S.fab.side === 'left' ? ' on-left' : '') +\n" +
  "      (t.running ? '' : ' is-paused') + (t.done ? ' is-done' : '') + '\" id=\"timerEar\" style=\"' + style + '\" ' +\n" +
  "      'data-act=\"fab-expand\" role=\"button\" tabindex=\"0\" aria-label=\"展开计时器\">' +\n" +
  "      '<span class=\"ear-ico\">' + ic('timer', 15) + '</span>' +\n" +
  "      (S.timers.length > 1 ? '<span class=\"fab-count num\">' + S.timers.length + '</span>' : '') +\n" +
  "      '</div>';\n" +
  "  }\n");

/* 4 · 拖拽结束：靠近左/右边缘就吸附并收成耳朵 */
edit('pointerup 加吸边判定',
  "document.addEventListener('pointerup', function () {\n" +
  "  if (!dragCtx) return;\n" +
  "  dragCtx = null;\n" +
  "  const fab = document.getElementById('timerFab');\n" +
  "  if (fab) fab.classList.remove('dragging');\n" +
  "});",
  "document.addEventListener('pointerup', function () {\n" +
  "  if (!dragCtx) return;\n" +
  "  dragCtx = null;\n" +
  "  const fab = document.getElementById('timerFab');\n" +
  "  if (fab) fab.classList.remove('dragging');\n" +
  "  /* 松手时离哪条边不到 40px 就吸到那条边，并收成耳朵；停在中间则保持完整球。 */\n" +
  "  const PW = deviceSize().w;\n" +
  "  const nearLeft = S.fab.x <= 40;\n" +
  "  const nearRight = S.fab.x + dragW >= PW - 40;\n" +
  "  if (!nearLeft && !nearRight) return;\n" +
  "  S.fab.side = nearLeft ? 'left' : 'right';\n" +
  "  S.fab.x = nearLeft ? 0 : PW - dragW;\n" +
  "  S.fab.collapsed = true;\n" +
  "  renderOverlays();\n" +
  "});");

// dragW：拖拽开始时记下球宽，pointerup 里要用（dragCtx 已清掉，所以提成模块变量）
edit('记下拖拽时的球宽供 pointerup 用',
  "  dragCtx = { sx:e.clientX, sy:e.clientY, ox:S.fab.x, oy:S.fab.y, w:fab.getBoundingClientRect().width / sc, h:fab.getBoundingClientRect().height / sc };\n",
  "  dragCtx = { sx:e.clientX, sy:e.clientY, ox:S.fab.x, oy:S.fab.y, w:fab.getBoundingClientRect().width / sc, h:fab.getBoundingClientRect().height / sc };\n" +
  "  dragW = dragCtx.w;\n");
edit('声明 dragW',
  "document.addEventListener('pointerdown', function (e) {\n" +
  "  const fab = e.target.closest('#timerFab');\n",
  "let dragW = 148; // 完整球的宽（吸边时要把 x 钉到「屏宽 - 球宽」）\n" +
  "document.addEventListener('pointerdown', function (e) {\n" +
  "  const fab = e.target.closest('#timerFab');\n");

/* 5 · 点耳朵展开 */
edit('点耳朵回到完整球',
  "  if (act === 'fab-drag') return;\n",
  "  if (act === 'fab-drag') return;\n" +
  "  if (act === 'fab-expand') { S.fab.collapsed = false; renderOverlays(); return; }\n");

/* 6 · 走查出口：把 deviceSize 也交出去，吸边期望要从屏宽现算 */
edit('__zaoji 暴露 deviceSize',
  "  MENUS: MENUS, mealTodoTargets: mealTodoTargets, mealDigest: mealDigest,\n",
  "  MENUS: MENUS, mealTodoTargets: mealTodoTargets, mealDigest: mealDigest,\n" +
  "  // R47 第八段：吸边的期望值是「屏宽 - 球宽」，所以屏宽要能拿到（不从 DOM 反推）。\n" +
  "  deviceSize: deviceSize,\n");

const growth = out.length - before.length;
if (growth < 800 || growth > 6000) {
  console.error('✘ 体积变化异常：' + growth + ' 字节（预期 +800 ~ +6000），不落盘');
  process.exit(1);
}
if (!/is-ear/.test(out) || !/fab-expand/.test(out)) { console.error('✘ 关键片段没进去'); process.exit(1); }
fs.writeFileSync(TARGET, out);
console.log(`✔ 已落盘（+${growth} 字节，${out.split(EOL).length} 行）`);
