// 修 proto_fab_r47_walk.cjs 的两处工装错：
// ① getComputedStyle 对绝对定位元素返回「用后值」——left:auto 会被解析成实际像素，
//    所以「锚在哪条边」必须读内联样式（el.style.*），那才是声明本身。
// ② 第[5]步造自由态时只改了 x，没清 snapped：渲染仍按锚定走，拖拽起点被算到左边缘，
//    于是"中间松手"其实是从边上开始拖的。
const fs = require('fs');
const p = 'tool/proto_fab_r47_walk.cjs';
const s0 = fs.readFileSync(p, 'utf8');
const EOL = s0.includes('\r\n') ? '\r\n' : '\n';
const j = (x) => x.replace(/\n/g, EOL);
let s = s0;
const edit = (label, a, b) => {
  const A = j(a), B = j(b);
  const n = s.split(A).length - 1;
  if (n !== 1) { console.error('✘ ' + label + '：锚命中 ' + n); process.exit(1); }
  s = s.replace(A, B);
  console.log('✔ ' + label);
};

edit('anchored() 改读内联样式',
  "  // 贴边现在是 CSS 锚定（right:0 / left:0），所以判据直接读计算样式：\n" +
  "  // 锚在那条边 = 该方向是 0px、另一方向是 auto。这比量矩形更贴近「到底靠什么贴边」。\n" +
  "  const anchored = (sel) => page.evaluate((sel) => {\n" +
  "    const el = document.querySelector(sel);\n" +
  "    if (!el) return null;\n" +
  "    const cs = getComputedStyle(el);\n" +
  "    return { right: cs.right, left: cs.left, snapped: window.__zaoji.S.fab.snapped,\n" +
  "      side: window.__zaoji.S.fab.side };\n" +
  "  }, sel);",
  "  // 贴边是 CSS 锚定（right:0 / left:0），所以读**内联样式**：那才是声明本身。\n" +
  "  // ★ 别用 getComputedStyle——绝对定位元素的 left/right 会返回「用后值」，\n" +
  "  //   auto 被解析成实际像素，于是永远断不出 auto。\n" +
  "  const anchored = (sel) => page.evaluate((sel) => {\n" +
  "    const el = document.querySelector(sel);\n" +
  "    if (!el) return null;\n" +
  "    return { right: el.style.right, left: el.style.left, top: el.style.top,\n" +
  "      snapped: window.__zaoji.S.fab.snapped, side: window.__zaoji.S.fab.side };\n" +
  "  }, sel);");

edit('第[2]步断言对齐内联值',
  "    aR && aR.right === '0px' && aR.left === 'auto' && aR.snapped === true && aR.side === 'right',",
  "    aR && aR.right === '0px' && aR.left === 'auto' && aR.snapped === true && aR.side === 'right',");

edit('第[5]步造自由态要连 snapped 一起清',
  "  await page.evaluate((x) => { window.__zaoji.S.fab.x = x; window.__zaoji.renderOverlays(); }, mid);",
  "  // 自由态 = 有 x 且没吸附。只改 x 不清 snapped 的话，渲染仍按锚定走，\n" +
  "  // 拖拽起点会被 pointerdown 按矩形重算到边上——那这条用例就白写了。\n" +
  "  await page.evaluate((x) => {\n" +
  "    const z = window.__zaoji;\n" +
  "    z.S.fab.snapped = false; z.S.fab.collapsed = false; z.S.fab.x = x;\n" +
  "    z.renderOverlays();\n" +
  "  }, mid);");

fs.writeFileSync(p, s);
console.log('✔ 走查两处工装错已修');
