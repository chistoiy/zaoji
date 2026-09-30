// R47 第八段补正：「全屏要包含通知栏」= 这一屏**把通知栏整条盖掉**（immersive），
// 不是"铺到它底下 + 换浅色图标"。上一轮我理解反了，原型也跟着画错了一条状态栏进来。
//
// 这次改三处：
//   1. `timerFullHTML()` 撤掉上一轮塞进去的那条 `statusBar()`；
//   2. 撤掉配套的 `.timer-full .statusbar` 配色规则（没有那条栏了，规则就是空转）；
//   3. 换成一条**能表达"盖掉"的**声明：`.timer-full` 顶到 `inset:0` 的最上沿，
//      并且这一屏里**不存在** `.statusbar` 节点——走查按这两条断言。
//
// 用法：node tool/proto_tfbar_r47_undo.cjs [--check]
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const FILE = path.join(ROOT, 'zaoji-prototype.html');
const SNAP = path.join(ROOT, 'dist', 'zaoji-prototype_before_r47tfundo.html');
const raw = fs.readFileSync(FILE, 'utf8');
const eol = raw.includes('\r\n') ? '\r\n' : '\n';
const j = (s) => s.split('\n').map((x) => x.replace(/\r$/, '')).join(eol);

const EDITS = [
  {
    name: '撤掉 timerFullHTML 里那条状态栏（全屏 = 盖掉它）',
    from: "  return '<div class=\"timer-full\">' +\n    statusBar() +\n    '<div class=\"timer-full-inner\">' +",
    to: "  /* 这一屏是**真全屏**（R47 第八段补正）：把通知栏整条盖掉，所以这里**不画**状态栏。\n" +
        "     上一轮理解成「铺到状态栏底下 + 换浅色图标」，那是「含住」，用户要的是「没有」。 */\n" +
        "  return '<div class=\"timer-full\">' +\n    '<div class=\"timer-full-inner\">' +",
  },
  {
    name: '撤掉配套的配色规则',
    from: `/* R47：全屏计时页**从状态栏那一层开始画**——深色底顶到屏幕最上沿，
   时间/信号/电量以浅色浮在上面（对应 Flutter 侧 SystemUiOverlayStyle.light）。
   状态栏本体复用别的屏那一条 markup，只在这里换配色与层级。 */
.timer-full .statusbar{position:relative;z-index:2;color:#FFF3E8;opacity:.92}`,
    to: `/* R47 第八段补正：全屏计时页**盖掉**通知栏（Flutter 侧 immersiveSticky），
   所以这一屏里没有 .statusbar 节点；深色底顶到 inset:0 的最上沿就是"整屏都是它"。 */`,
  },
];

const check = process.argv.includes('--check');
let text = raw;
let bad = 0;
for (const e of EDITS) {
  const from = j(e.from), to = j(e.to);
  const hits = text.split(from).length - 1;
  if (hits !== 1) {
    console.log(`[${e.name}] 命中 ${hits} 次 → FAIL`);
    bad++;
    continue;
  }
  console.log(`[${e.name}] OK`);
  text = text.replace(from, to);
}
if (bad) { console.log('锚点没全中，未写盘。'); process.exit(1); }
if (check) { console.log('--check：命中，未写盘。'); process.exit(0); }
if (!fs.existsSync(SNAP)) fs.writeFileSync(SNAP, raw, 'utf8');
fs.writeFileSync(FILE, text, 'utf8');
// 编码自检（上一轮的 latin1 事故：新插入中文前先确认这份是干净 UTF-8）
const buf = fs.readFileSync(FILE);
let i = 0, illegal = 0;
while (i < buf.length) {
  const c = buf[i];
  const n = c < 0x80 ? 1 : (c & 0xE0) === 0xC0 ? 2 : (c & 0xF0) === 0xE0 ? 3 : (c & 0xF8) === 0xF0 ? 4 : 0;
  if (!n) { illegal++; i++; continue; }
  let ok = true;
  for (let k = 1; k < n; k++) if ((buf[i + k] & 0xC0) !== 0x80) { ok = false; break; }
  if (!ok) { illegal++; i++; continue; }
  i += n;
}
console.log(`写盘完成：${buf.length} bytes（快照 dist/zaoji-prototype_before_r47tfundo.html）`);
console.log(illegal === 0 ? 'UTF-8 合法性：干净' : `★ UTF-8 非法序列 ${illegal} 处！`);
