/* eslint-disable */
/**
 * R46 第二刀：修走查抓到的真 bug。
 * `input-nf` 分支被写进了 **click 分派器**，而输入框发的是 `input` 事件 →
 * 数值永远停在 0、超限确认条永不出现、保存永远被「得填个正数」挡下（走查 [2][3][4] 一片红的根因）。
 * 这一刀：① 把死代码从点击分派器里摘掉 ② 提成全局函数 ③ 接进既有的 input 监听（照 input-pan 的写法）
 * ④ 顺手把空值的预览从「每份 ≈ 0」改成「每份 ≈ —」（空态画 0 会让人以为已经填过了）。
 * 护栏：快照 + 锚点恰好命中一次 + 内联脚本 vm 语法自检 + 体积区间。
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..');
const target = path.join(root, 'zaoji-prototype.html');
const snap = path.join(root, 'dist', 'proto_before_r46_fix2.html');
const src = fs.readFileSync(target, 'utf8');
fs.writeFileSync(snap, src, 'utf8');
const beforeBytes = Buffer.byteLength(src, 'utf8');
let L = src.split(/\r?\n/);

const assert1 = (pred, what) => {
  const hits = [];
  L.forEach((l, i) => { if (pred(l, i)) hits.push(i); });
  if (hits.length !== 1) {
    console.error(`ABORT: 锚点「${what}」命中 ${hits.length} 次（要恰好 1 次），未改动。`);
    process.exit(1);
  }
  return hits[0];
};

/* ① 摘掉点击分派器里的 input-nf 死分支 */
{
  const s = assert1((l) => l.trim() === "if (act === 'input-nf') {", 'input-nf 死分支');
  let e = s;
  while (e < L.length && L[e] !== '  }') e++;
  if (e >= L.length) { console.error('ABORT: 死分支收尾没找到'); process.exit(1); }
  L.splice(s, e - s + 1);
}

/* ② 提成全局函数，放在 sheetNutriEdit 之后；顺带空态预览改画「—」 */
{
  const i = assert1((l) => l.trim().startsWith("'<button type=\"button\" class=\"btn btn-primary\" style=\"flex:1.4\" data-act=\"nutri-edit-save\">'"), 'sheetNutriEdit 的收尾');
  let j = i;
  while (j < L.length && L[j] !== '}') j++;
  if (j >= L.length) { console.error('ABORT: sheetNutriEdit 的收尾花括号没找到'); process.exit(1); }
  const at = j;
  const fn = [
    "",
    "/* 输入即时折算：per / total / serv 三者互相推导，谁后改谁说话（FR-AI-72 + Q5）。",
    "   重画整个弹层会丢焦点，所以画完把光标放回刚才那个框——与搜索框同一套处理（见 input-pan）。 */",
    "function nutriFormInput(el) {",
    "  const f = S.nutriForm;",
    "  if (!f) return;",
    "  const k = el.dataset.nf;",
    "  const raw = el.value.trim();",
    "  f[k] = raw === '' ? null : (Number(raw) || 0);",
    "  nutriFormCalc(f, k);",
    "  f.warn = (k === 'per' || k === 'total') && f.per > 20000;",
    "  S.sheet = sheetNutriEdit(f.rid);",
    "  renderOverlays();",
    "  const back = document.querySelector('[data-nf=\"' + k + '\"]');",
    "  if (back) { back.focus(); try { back.setSelectionRange(back.value.length, back.value.length); } catch (err) {} }",
    "}",
  ];
  L.splice(at + 1, 0, ...fn);
}
{
  const i = assert1((l) => l.includes("'<div class=\"nutri-preview\">每份 ≈ ' + (f.per || 0)"), '预览行空态');
  L[i] = L[i]
    .replace("(f.per || 0)", "(f.per == null ? '—' : f.per)")
    .replace("(f.total || 0)", "(f.total == null ? '—' : f.total)");
}

/* ③ 接进既有的 input 监听（照 input-pan 那条的写法） */
{
  const i = assert1((l) => l.trim() === "} else if (a === 'input-pan') {", 'input-pan 分支');
  L.splice(i, 0,
    "  } else if (a === 'input-nf') {",
    "    nutriFormInput(e.target);",
    "    return;");
}

/* ④ 校验后出盘 */
const out = L.join('\r\n');
{
  const scripts = [];
  const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g;
  let m;
  while ((m = re.exec(out))) scripts.push(m[1]);
  scripts.forEach(function (body, k) {
    if (!/\S/.test(body)) return;
    try { new vm.Script(body, { filename: 'inline#' + k }); }
    catch (err) { console.error('ABORT: 内联脚本 #' + k + ' 语法不过：' + err.message); process.exit(1); }
  });
  console.log(`内联脚本语法自检：${scripts.length} 段通过`);
}
if (/if \(act === 'input-nf'\)/.test(out)) { console.error('ABORT: 死分支没摘干净'); process.exit(1); }
const afterBytes = Buffer.byteLength(out, 'utf8');
if (!(Math.abs(afterBytes - beforeBytes) < 40000)) {
  console.error(`ABORT: 体积异常 ${beforeBytes} → ${afterBytes}`); process.exit(1);
}
fs.writeFileSync(target, out, 'utf8');
console.log(`OK  ${beforeBytes} → ${afterBytes} B`);
console.log(`快照 ${path.relative(root, snap)}`);
