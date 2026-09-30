// 修 proto_fab_r47_walk.cjs 的两条吸边断言：
// 原写法拿「屏宽 - 我自己量的球宽」当期望，而原型吸附用的是 pointerdown 那一刻
// 从 #device 比例算出的球宽——两处 scale 口径不同（#phone vs #device），差出 10px。
// 贴边本质是几何不变量：直接量「耳朵右缘 vs 手机右缘」，位置是否被重置则用状态比状态。
const fs = require('fs');
const p = 'tool/proto_fab_r47_walk.cjs';
let s = fs.readFileSync(p, 'utf8');
const EOL = s.includes('\r\n') ? '\r\n' : '\n';
const j = (x) => x.replace(/\n/g, EOL);

const pairs = [
  // 1) 加一个几何量具
  ["  const dragFab = async (dxDesign, dyDesign) => {",
   "  // 贴边是几何不变量：量「耳朵右缘 vs 手机右缘」，不拿另一处 scale 反推期望值\n" +
   "  const edgeGap = () => page.evaluate(() => {\n" +
   "    const ear = document.getElementById('timerEar');\n" +
   "    const phone = document.getElementById('phone');\n" +
   "    if (!ear || !phone) return null;\n" +
   "    const e = ear.getBoundingClientRect(), ph = phone.getBoundingClientRect();\n" +
   "    return { rightGap: Math.round(ph.right - e.right), leftGap: Math.round(e.left - ph.left) };\n" +
   "  });\n" +
   "  const dragFab = async (dxDesign, dyDesign) => {"],
  // 2) 右边缘：改成几何断言，并记下吸附后的 x 供下一步对比
  ["  ok('x 精确吸到「屏宽 - 球宽」', Math.abs(f.x - (PW - ballW)) < 1.5, 'x=' + f.x.toFixed(1) + ' 期望=' + (PW - ballW).toFixed(1));",
   "  const gapR = await edgeGap();\n" +
   "  ok('耳朵右缘贴住手机右缘（容差 2px）', gapR && Math.abs(gapR.rightGap) <= 2, JSON.stringify(gapR));\n" +
   "  const snappedX = f.x;"],
  // 3) 展开后位置没被重置：拿上一步记下的 x 比
  ["  ok('x 保持在右边（没被重置）', Math.abs(f.x - (PW - ballW)) < 2, 'x=' + f.x.toFixed(1));",
   "  ok('展开后 x 保持吸边位置（没被重置回默认角）', Math.abs(f.x - snappedX) < 0.01,\n" +
   "    'x=' + f.x.toFixed(2) + ' 上一步=' + snappedX.toFixed(2));"],
  // 4) 左边缘：同样用几何断言
  ["  ok('x 吸到 0', Math.abs(f.x) < 1.5, 'x=' + f.x.toFixed(1));",
   "  const gapL = await edgeGap();\n" +
   "  ok('x 吸到 0 且左缘贴住手机左缘', Math.abs(f.x) < 1.5 && gapL && Math.abs(gapL.leftGap) <= 2,\n" +
   "    'x=' + f.x.toFixed(1) + ' ' + JSON.stringify(gapL));"],
  // 5) ballW 那条降级成"读到了"，不再当期望值用
  ["  ok('球宽读到了（吸边判据要用它）', ballW > 80 && ballW < 260, 'ballW=' + ballW.toFixed(1) + ' PW=' + PW);",
   "  ok('球与屏的宽度关系合理（球没宽过屏幕）', ballW > 80 && ballW < PW, 'ballW=' + ballW.toFixed(1) + ' PW=' + PW);"],
];

for (const [a, b] of pairs) {
  const A = j(a), B = j(b);
  const n = s.split(A).length - 1;
  if (n !== 1) { console.error('✘ 锚命中 ' + n + ' 次：' + a.slice(0, 46)); process.exit(1); }
  s = s.replace(A, B);
  console.log('✔ ' + a.trim().slice(0, 40));
}
fs.writeFileSync(p, s);
console.log('✔ 走查断言改完');
