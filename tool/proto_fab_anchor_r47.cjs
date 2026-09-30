// R47 第八段：修原型里「耳朵收起后没真的贴边」。
// 吸附时用的是整颗球的宽度（~200 设计像素），可耳朵只有 26px——
// 于是 collapsed 之后耳朵停在 x=189 处悬在半空，右缘离屏幕右缘还差 124px。
// 修法：把「贴哪一边」当事实源，收起用耳朵宽度定位、展开用球宽定位；
// 球宽在 pointerdown 那一刻量一次存进 S.fab.ballW（CSS 宽度会随内容变，不写死）。
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');
const TARGET = path.join(ROOT, 'zaoji-prototype.html');
const SNAP = path.join(ROOT, 'dist', 'zaoji-prototype_before_r47fabanchor.html');

const before = fs.readFileSync(TARGET, 'utf8');
if (!fs.existsSync(SNAP)) fs.writeFileSync(SNAP, before);
const EOL = before.includes('\r\n') ? '\r\n' : '\n';
const j = (x) => x.replace(/\n/g, EOL);
let out = before;
let n = 0;
const edit = (label, from0, to0, wantHits) => {
  n++;
  const from = j(from0), to = j(to0);
  const hits = out.split(from).length - 1;
  const need = wantHits === undefined ? 1 : wantHits;
  if (hits !== need) { console.error(`✘ [${n}] ${label}：锚命中 ${hits} 次（要 ${need}）`); process.exit(1); }
  out = out.split(from).join(to);
  console.log(`✔ [${n}] ${label}`);
};

// 1) 状态里带 ballW（默认态工厂与 S 初始化两处一起改，别再留两份形状）
edit('fabDefault 加 ballW',
  "function fabDefault() { return { x:null, y:null, side:'right', collapsed:false }; }",
  "/* EAR_W = 耳朵宽（与 .timer-fab.is-ear 的 width 对齐）。\n" +
  "   ballW = 完整球宽，pointerdown 时量一次：它是吸边定位要用的数，写死就会随内容宽度漂。 */\n" +
  "const EAR_W = 26;\n" +
  "function fabDefault() { return { x:null, y:null, side:'right', collapsed:false, ballW:null }; }\n" +
  "/* 贴哪一边就是事实源：left 钉 0，right 钉「屏宽 - 该形态自己的宽度」。 */\n" +
  "function fabAnchorX(side, w) { return side === 'left' ? 0 : deviceSize().w - w; }");
edit('S 初始化那行同步形状',
  "  fab:{ x:null, y:null, side:'right', collapsed:false }, // = fabDefault() 的形状，改这里要一起改它",
  "  fab:{ x:null, y:null, side:'right', collapsed:false, ballW:null }, // = fabDefault() 的形状，改这里要一起改它");

// 2) pointerdown：把量到的球宽存进状态
edit('pointerdown 记下 ballW',
  "  dragW = dragCtx.w;",
  "  dragW = dragCtx.w;\n  S.fab.ballW = dragCtx.w;");

// 3) pointerup：收起时用耳朵自己的宽度贴边
edit('pointerup 用 EAR_W 贴边',
  "  S.fab.side = nearLeft ? 'left' : 'right';\n" +
  "  S.fab.x = nearLeft ? 0 : PW - dragW;\n" +
  "  S.fab.collapsed = true;",
  "  S.fab.side = nearLeft ? 'left' : 'right';\n" +
  "  S.fab.x = fabAnchorX(S.fab.side, EAR_W); // 收起态贴边要用耳朵的宽度，不是球的\n" +
  "  S.fab.collapsed = true;");

// 4) 点耳朵展开：换回球宽贴同一边
edit('展开时换球宽贴边',
  "  if (act === 'fab-expand') { S.fab.collapsed = false; renderOverlays(); return; }",
  "  if (act === 'fab-expand') {\n" +
  "    S.fab.collapsed = false;\n" +
  "    // 展开后球比耳朵宽得多，沿用耳朵的 x 会让球的右缘探出屏幕——按球宽重贴同一边。\n" +
  "    if (S.fab.collapsed === false && S.fab.x !== null) S.fab.x = fabAnchorX(S.fab.side, S.fab.ballW || dragW);\n" +
  "    renderOverlays(); return;\n" +
  "  }");

if (out === before) { console.error('✘ 一个字节都没变'); process.exit(1); }
fs.writeFileSync(TARGET, out);
console.log(`✔ 已落盘（${before.length} → ${out.length} 字节）`);
