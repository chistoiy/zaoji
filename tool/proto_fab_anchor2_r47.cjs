// R47 第八段收尾：展开后要按「渲染出来的真实球宽」再贴一次边。
// 上一版把球宽在 pointerdown 量一次存进状态，但球宽随标签文字长度变（实测 196.5 vs 200.3），
// 展开后右缘就探出屏幕 16px。改成：渲染完读 DOM 宽度 → 重贴边 → 顺手把 ballW 更新掉。
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');
const TARGET = path.join(ROOT, 'zaoji-prototype.html');
const WALK = path.join(ROOT, 'tool', 'proto_fab_r47_walk.cjs');
const EOLof = (s) => (s.includes('\r\n') ? '\r\n' : '\n');

/* —— 原型 —— */
{
  const before = fs.readFileSync(TARGET, 'utf8');
  const EOL = EOLof(before);
  const j = (x) => x.replace(/\n/g, EOL);
  let out = before;
  const edit = (label, a, b) => {
    const A = j(a), B = j(b);
    const n = out.split(A).length - 1;
    if (n !== 1) { console.error('✘ ' + label + '：锚命中 ' + n); process.exit(1); }
    out = out.replace(A, B);
    console.log('✔ ' + label);
  };

  edit('加 anchorFabToEdge()',
    "function fabAnchorX(side, w) { return side === 'left' ? 0 : deviceSize().w - w; }",
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
    "}");

  edit('展开分支改成 render 后重贴边',
    "  if (act === 'fab-expand') {\n" +
    "    S.fab.collapsed = false;\n" +
    "    // 展开后球比耳朵宽得多，沿用耳朵的 x 会让球的右缘探出屏幕——按球宽重贴同一边。\n" +
    "    if (S.fab.collapsed === false && S.fab.x !== null) S.fab.x = fabAnchorX(S.fab.side, S.fab.ballW || dragW);\n" +
    "    renderOverlays(); return;\n" +
    "  }",
    "  if (act === 'fab-expand') {\n" +
    "    // 展开后球比耳朵宽得多，沿用耳朵的 x 会让球右缘探出屏幕：先渲染再按真实宽度重贴同一边。\n" +
    "    S.fab.collapsed = false;\n" +
    "    renderOverlays();\n" +
    "    anchorFabToEdge();\n" +
    "    return;\n" +
    "  }");

  edit('吸边收起后也刷新 ballW（供下次展开用）',
    "  dragW = dragCtx.w;\n  S.fab.ballW = dragCtx.w;",
    "  dragW = dragCtx.w;\n  S.fab.ballW = dragCtx.w; // 只是初值；展开时会按渲染宽度再刷一次");

  if (out === before) { console.error('✘ 原型没变化'); process.exit(1); }
  fs.writeFileSync(TARGET, out);
  console.log('✔ 原型已落盘');
}

/* —— 走查：第[3]步那条对比方向写反了（展开后球更宽，x 必然变小）—— */
{
  const before = fs.readFileSync(WALK, 'utf8');
  const EOL = EOLof(before);
  const j = (x) => x.replace(/\n/g, EOL);
  const A = j("  ok('x 仍在右半区（没被重置回默认角）', f.x > snappedX - 4, 'x=' + f.x.toFixed(1) + ' 收起时=' + snappedX.toFixed(1));");
  const B = j("  ok('展开后 x 按球宽往回挪（不是被重置回默认角）', f.x > 100 && f.x < snappedX,\n    'x=' + f.x.toFixed(1) + ' 收起时=' + snappedX.toFixed(1));");
  if (before.split(A).length - 1 !== 1) { console.error('✘ 走查锚不唯一'); process.exit(1); }
  fs.writeFileSync(WALK, before.replace(A, B));
  console.log('✔ 走查断言方向改对');
}
