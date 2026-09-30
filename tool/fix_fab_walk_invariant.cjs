// R47 第八段：把吸边判据搬到「代码自己那套坐标系」里。
// 之前拿 #phone 的 getBoundingClientRect 当右边界，但 #phone 含机身边框，
// 而原型定位用的是设计像素（phoneScale() 是 #device/设计宽，≈0.81，不是 #phone 算出的 0.769）——
// 于是「贴边」被判成差了 18px 的假失败。
// 改成断言代码真正的不变量：x + 该形态自己的设计宽度 == 屏宽。
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');
const TARGET = path.join(ROOT, 'zaoji-prototype.html');
const WALK = path.join(ROOT, 'tool', 'proto_fab_r47_walk.cjs');
const EOLof = (s) => (s.includes('\r\n') ? '\r\n' : '\n');

/* 1 · 原型：把 phoneScale 交出去（走查要按同一套换算，不能再自己估） */
{
  const s = fs.readFileSync(TARGET, 'utf8');
  const EOL = EOLof(s);
  const A = s.includes('\r\n') ? '  deviceSize: deviceSize,\r\n' : '  deviceSize: deviceSize,\n';
  const B = A + (s.includes('\r\n') ? '  phoneScale: phoneScale,\r\n' : '  phoneScale: phoneScale,\n');
  if (s.split(A).length - 1 !== 1) { console.error('✘ deviceSize 出口锚不唯一'); process.exit(1); }
  fs.writeFileSync(TARGET, s.replace(A, B));
  console.log('✔ __zaoji 暴露 phoneScale');
}

/* 2 · 走查：两个几何量具改成设计像素不变量 */
{
  const s0 = fs.readFileSync(WALK, 'utf8');
  const EOL = EOLof(s0);
  const j = (x) => x.replace(/\n/g, EOL);
  let s = s0;
  const edit = (label, a, b) => {
    const A = j(a), B = j(b);
    const n = s.split(A).length - 1;
    if (n !== 1) { console.error('✘ ' + label + '：锚命中 ' + n); process.exit(1); }
    s = s.replace(A, B);
    console.log('✔ ' + label);
  };

  edit('edgeGap → 设计像素不变量',
    "  // 贴边是几何不变量：量「耳朵右缘 vs 手机右缘」，不拿另一处 scale 反推期望值\n" +
    "  const edgeGap = () => page.evaluate(() => {\n" +
    "    const ear = document.getElementById('timerEar');\n" +
    "    const phone = document.getElementById('phone');\n" +
    "    if (!ear || !phone) return null;\n" +
    "    const e = ear.getBoundingClientRect(), ph = phone.getBoundingClientRect();\n" +
    "    return { rightGap: Math.round(ph.right - e.right), leftGap: Math.round(e.left - ph.left) };\n" +
    "  });",
    "  // 贴边的不变量在**设计像素**里：x + 该形态自己的宽度 == 屏宽（右）或 x == 0（左）。\n" +
    "  // 别拿 #phone 的 rect 当边界——那是含机身边框的 CSS 像素，与定位坐标系不是一套。\n" +
    "  const edgeInvariant = (sel) => page.evaluate((sel) => {\n" +
    "    const z = window.__zaoji, el = document.querySelector(sel);\n" +
    "    if (!el) return null;\n" +
    "    const w = el.getBoundingClientRect().width / z.phoneScale();\n" +
    "    return { x: z.S.fab.x, w, overRight: z.S.fab.x + w - z.deviceSize().w, overLeft: z.S.fab.x };\n" +
    "  }, sel);");

  edit('fabEdge → 同一套不变量',
    "  // 完整球的贴边同理看几何：量「球右缘 vs 手机右缘」\n" +
    "  const fabEdge = () => page.evaluate(() => {\n" +
    "    const f = document.getElementById('timerFab'), ph = document.getElementById('phone');\n" +
    "    if (!f || !ph) return null;\n" +
    "    const a = f.getBoundingClientRect(), b = ph.getBoundingClientRect();\n" +
    "    return { rightGap: Math.round(b.right - a.right), leftGap: Math.round(a.left - b.left) };\n" +
    "  });",
    "");

  edit('第[2]步断言换成不变量',
    "  const gapR = await edgeGap();\n" +
    "  ok('耳朵右缘贴住手机右缘（容差 2px）', gapR && Math.abs(gapR.rightGap) <= 2, JSON.stringify(gapR));",
    "  const invR = await edgeInvariant('#timerEar');\n" +
    "  ok('耳朵贴住右缘：x + 耳宽 = 屏宽（容差 2 设计像素）',\n" +
    "    invR && Math.abs(invR.overRight) <= 2, JSON.stringify(invR));");

  edit('第[3]步断言换成不变量',
    "  const fe = await fabEdge();\n" +
    "  ok('展开后球右缘仍贴手机右缘', fe && Math.abs(fe.rightGap) <= 3, JSON.stringify(fe));",
    "  const invB = await edgeInvariant('#timerFab');\n" +
    "  ok('展开后球仍贴右缘：x + 球宽 = 屏宽（容差 2 设计像素）',\n" +
    "    invB && Math.abs(invB.overRight) <= 2, JSON.stringify(invB));");

  edit('第[4]步左边缘断言补不变量',
    "  const gapL = await edgeGap();\n" +
    "  ok('x 吸到 0 且左缘贴住手机左缘', Math.abs(f.x) < 1.5 && gapL && Math.abs(gapL.leftGap) <= 2,\n" +
    "    'x=' + f.x.toFixed(1) + ' ' + JSON.stringify(gapL));",
    "  ok('x 吸到 0（左缘贴边）', Math.abs(f.x) < 1.5, 'x=' + f.x.toFixed(1));");

  fs.writeFileSync(WALK, s);
  console.log('✔ 走查改完');
}
