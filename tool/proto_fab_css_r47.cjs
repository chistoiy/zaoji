// R47 第八段：把「贴边」从 JS 算宽度改成 CSS 锚定（snapped 时 right:0 / left:0）。
// 为什么：球宽随标签文字长度变（实测同一颗球 140 / 195 / 200 都出现过），
// 「屏宽 - 量出来的宽度」这套数学怎么量都会漂，展开时还要再贴一次；
// 而 CSS 的 right:0 天生就是贴边，不需要知道任何东西的宽度。
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');
const TARGET = path.join(ROOT, 'zaoji-prototype.html');
const WALK = path.join(ROOT, 'tool', 'proto_fab_r47_walk.cjs');
const SNAP = path.join(ROOT, 'dist', 'zaoji-prototype_before_r47fabcss.html');
const EOLof = (s) => (s.includes('\r\n') ? '\r\n' : '\n');

const raw = fs.readFileSync(TARGET, 'utf8');
if (!fs.existsSync(SNAP)) fs.writeFileSync(SNAP, raw);
const EOL = EOLof(raw);
const j = (x) => x.replace(/\n/g, EOL);
let out = raw, n = 0;
const edit = (label, a, b) => {
  n++;
  const A = j(a), B = j(b);
  const hits = out.split(A).length - 1;
  if (hits !== 1) { console.error(`✘ [${n}] ${label}：锚命中 ${hits} 次（要 1）`); process.exit(1); }
  out = out.replace(A, B);
  console.log(`✔ [${n}] ${label}`);
};

/* 1 · 状态与工具：去掉 ballW / fabAnchorX / anchorFabToEdge，换成 snapped */
edit('fabDefault 换成 snapped，删掉宽度数学',
  "/* EAR_W = 耳朵宽（与 .timer-fab.is-ear 的 width 对齐）。\n" +
  "   ballW = 完整球宽，pointerdown 时量一次：它是吸边定位要用的数，写死就会随内容宽度漂。 */\n" +
  "const EAR_W = 26;\n" +
  "function fabDefault() { return { x:null, y:null, side:'right', collapsed:false, ballW:null }; }\n" +
  "/* 贴哪一边就是事实源：left 钉 0，right 钉「屏宽 - 该形态自己的宽度」。 */\n" +
  "function fabAnchorX(side, w) { return side === 'left' ? 0 : deviceSize().w - w; }\n" +
  "/* 展开后按「渲染出来的真实宽度」再贴一次边：球宽随标签文字变，量一次存着就会漂。 */\n" +
  "function anchorFabToEdge() {\n" +
  "  const f = document.getElementById('timerFab');\n" +
  "  if (!f || S.fab.x === null) return;\n" +
  "  const sc = phoneScale() || 1;\n" +
  "  const w = f.getBoundingClientRect().width / sc;\n" +
  "  S.fab.ballW = w;\n" +
  "  S.fab.x = fabAnchorX(S.fab.side, w);\n" +
  "  f.style.left = S.fab.x + 'px';\n" +
  "}",
  "/* snapped = 吸附在某一侧：贴边交给 CSS 的 right:0 / left:0，**不算任何宽度**。\n" +
  "   （球宽随标签文字变，实测同一颗球量出 140 / 195 / 200，靠「屏宽减宽度」必然漂。）\n" +
  "   collapsed = 收成耳朵。两者独立：贴着边也可以展开成完整球。 */\n" +
  "function fabDefault() { return { x:null, y:null, side:'right', collapsed:false, snapped:false }; }");

edit('S 初始化跟 fabDefault 同形状',
  "  fab:{ x:null, y:null, side:'right', collapsed:false, ballW:null }, // = fabDefault() 的形状，改这里要一起改它",
  "  fab:{ x:null, y:null, side:'right', collapsed:false, snapped:false }, // = fabDefault() 的形状，改这里要一起改它");

/* 2 · 渲染：snapped 时按边锚定，否则用自由坐标 */
edit('timerFabHTML 的 style 支持 snapped',
  "  const x = S.fab.x, y = S.fab.y;\n" +
  "  const style = (x !== null && y !== null) ? 'left:' + x + 'px;top:' + y + 'px;right:auto;bottom:auto;' : '';",
  "  const y = S.fab.y;\n" +
  "  /* snapped：横向交给 right:0 / left:0（贴边），纵向仍用 top；自由态：left+top 都写。 */\n" +
  "  const style = S.fab.snapped\n" +
  "    ? ((S.fab.side === 'left' ? 'left:0;right:auto;' : 'right:0;left:auto;') +\n" +
  "       (y !== null ? 'top:' + y + 'px;bottom:auto;' : ''))\n" +
  "    : (S.fab.x !== null && y !== null ? 'left:' + S.fab.x + 'px;top:' + y + 'px;right:auto;bottom:auto;' : '');");

/* 3 · 起拖：吸附态要先把手算坐标落地，否则拖起来会跳 */
edit('pointerdown：吸附态起拖先转成自由坐标',
  "  if (S.fab.x === null || S.fab.y === null) {\n" +
  "    const pr = document.getElementById('phone').getBoundingClientRect();\n" +
  "    const fr = fab.getBoundingClientRect();\n" +
  "    S.fab.x = (fr.left - pr.left) / sc;\n" +
  "    S.fab.y = (fr.top - pr.top) / sc;\n" +
  "  }",
  "  if (S.fab.x === null || S.fab.y === null || S.fab.snapped) {\n" +
  "    // 贴着边的元素没有横向自由坐标：起拖前按当前矩形算出来，并退出吸附态，\n" +
  "    // 否则第一下就会从 right:0 跳到 left:x 上（手感是「球弹走了」）。\n" +
  "    const pr = document.getElementById('phone').getBoundingClientRect();\n" +
  "    const fr = fab.getBoundingClientRect();\n" +
  "    S.fab.x = (fr.left - pr.left) / sc;\n" +
  "    S.fab.y = (fr.top - pr.top) / sc;\n" +
  "    S.fab.snapped = false;\n" +
  "  }");

edit('pointerdown 不再记 ballW',
  "  dragW = dragCtx.w;\n  S.fab.ballW = dragCtx.w; // 只是初值；展开时会按渲染宽度再刷一次",
  "  dragW = dragCtx.w; // 只用于「离边多远」的判定，不参与定位");

/* 4 · 松手：置 snapped，不再算 x */
edit('pointerup 改成置 snapped',
  "  S.fab.side = nearLeft ? 'left' : 'right';\n" +
  "  S.fab.x = fabAnchorX(S.fab.side, EAR_W); // 收起态贴边要用耳朵的宽度，不是球的\n" +
  "  S.fab.collapsed = true;",
  "  S.fab.side = nearLeft ? 'left' : 'right';\n" +
  "  S.fab.snapped = true; // 贴边交给 CSS：耳朵和展开后的球都自动贴住同一条边\n" +
  "  S.fab.collapsed = true;");

/* 5 · 展开：不再需要重贴边 */
edit('fab-expand 去掉重贴边',
  "  if (act === 'fab-expand') {\n" +
  "    // 展开后球比耳朵宽得多，沿用耳朵的 x 会让球右缘探出屏幕：先渲染再按真实宽度重贴同一边。\n" +
  "    S.fab.collapsed = false;\n" +
  "    renderOverlays();\n" +
  "    anchorFabToEdge();\n" +
  "    return;\n" +
  "  }",
  "  if (act === 'fab-expand') {\n" +
  "    // 只切形态：贴哪一边由 snapped/side 决定，CSS 自己会把它贴回去（不需要重算宽度）。\n" +
  "    S.fab.collapsed = false;\n" +
  "    renderOverlays();\n" +
  "    return;\n" +
  "  }");

if (out.includes('anchorFabToEdge') || out.includes('fabAnchorX') || out.includes('ballW')) {
  console.error('✘ 宽度数学还有残留'); process.exit(1);
}
fs.writeFileSync(TARGET, out);
console.log(`✔ 原型已落盘（${raw.length} → ${out.length} 字节）`);

/* ───────── 走查：判据换成「计算样式真的锚在那条边」 ───────── */
{
  const w0 = fs.readFileSync(WALK, 'utf8');
  const WE = EOLof(w0);
  const wj = (x) => x.replace(/\n/g, WE);
  let w = w0;
  const wedit = (label, a, b, want) => {
    const A = wj(a), B = wj(b);
    const hits = w.split(A).length - 1;
    const need = want === undefined ? 1 : want;
    if (hits !== need) { console.error('✘ ' + label + '：锚命中 ' + hits + '（要 ' + need + '）'); process.exit(1); }
    w = w.split(A).join(B);
    console.log('✔ ' + label);
  };

  wedit('不变量量具 → 计算样式锚定',
    "  // 贴边的不变量在**设计像素**里：x + 该形态自己的宽度 == 屏宽（右）或 x == 0（左）。\n" +
    "  // 别拿 #phone 的 rect 当边界——那是含机身边框的 CSS 像素，与定位坐标系不是一套。\n" +
    "  const edgeInvariant = (sel) => page.evaluate((sel) => {\n" +
    "    const z = window.__zaoji, el = document.querySelector(sel);\n" +
    "    if (!el) return null;\n" +
    "    const w = el.getBoundingClientRect().width / z.phoneScale();\n" +
    "    return { x: z.S.fab.x, w, overRight: z.S.fab.x + w - z.deviceSize().w, overLeft: z.S.fab.x };\n" +
    "  }, sel);",
    "  // 贴边现在是 CSS 锚定（right:0 / left:0），所以判据直接读计算样式：\n" +
    "  // 锚在那条边 = 该方向是 0px、另一方向是 auto。这比量矩形更贴近「到底靠什么贴边」。\n" +
    "  const anchored = (sel) => page.evaluate((sel) => {\n" +
    "    const el = document.querySelector(sel);\n" +
    "    if (!el) return null;\n" +
    "    const cs = getComputedStyle(el);\n" +
    "    return { right: cs.right, left: cs.left, snapped: window.__zaoji.S.fab.snapped,\n" +
    "      side: window.__zaoji.S.fab.side };\n" +
    "  }, sel);");

  wedit('第[2]步',
    "  const invR = await edgeInvariant('#timerEar');\n" +
    "  ok('耳朵贴住右缘：x + 耳宽 = 屏宽（容差 2 设计像素）',\n" +
    "    invR && Math.abs(invR.overRight) <= 2, JSON.stringify(invR));",
    "  const aR = await anchored('#timerEar');\n" +
    "  ok('耳朵锚在右缘（right:0 / left:auto）',\n" +
    "    aR && aR.right === '0px' && aR.left === 'auto' && aR.snapped === true && aR.side === 'right',\n" +
    "    JSON.stringify(aR));");

  wedit('第[3]步',
    "  const invB = await edgeInvariant('#timerFab');\n" +
    "  ok('展开后球仍贴右缘：x + 球宽 = 屏宽（容差 2 设计像素）',\n" +
    "    invB && Math.abs(invB.overRight) <= 2, JSON.stringify(invB));",
    "  const aB = await anchored('#timerFab');\n" +
    "  ok('展开后球仍锚在右缘（同一条边，不用重算宽度）',\n" +
    "    aB && aB.right === '0px' && aB.left === 'auto' && aB.snapped === true, JSON.stringify(aB));");

  wedit('第[4]步',
    "  ok('x 吸到 0（左缘贴边）', Math.abs(f.x) < 1.5, 'x=' + f.x.toFixed(1));",
    "  const aL = await anchored('#timerEar');\n" +
    "  ok('耳朵锚在左缘（left:0 / right:auto）',\n" +
    "    aL && aL.left === '0px' && aL.right === 'auto' && aL.side === 'left', JSON.stringify(aL));");

  wedit('第[5]步补自由态',
    "  ok('中间松手不收起', f.collapsed === false, JSON.stringify(f));",
    "  ok('中间松手不收起', f.collapsed === false, JSON.stringify(f));\n" +
    "  ok('中间松手也不吸附（snapped=false，坐标是自由的）', f.snapped === false, JSON.stringify(f));");

  wedit('第[3]步那条 x 对比改成读 snapped/side（宽度数学已废）',
    "  ok('展开后 x 按球宽往回挪（不是被重置回默认角）', f.x > 100 && f.x < snappedX,\n    'x=' + f.x.toFixed(1) + ' 收起时=' + snappedX.toFixed(1));",
    "  ok('展开后仍记着贴右（side=right，没被重置回默认角）', f.side === 'right' && f.snapped === true,\n    JSON.stringify(f));");

  fs.writeFileSync(WALK, w);
  console.log('✔ 走查改完');
}
