/* R47 第八段 · 原型：全屏计时页「包含通知栏」
 *
 * 需求：全屏计时页要从屏幕最顶上开始画（状态栏那一条也在这张深色页里，
 * 时间和图标走浅色），而不是让系统状态栏压出一段别的底色。
 *
 * 手法（不是拍脑袋）：
 *  · `.timer-full` 本来就是 `inset:0`，但它把手机外框里那条 `.statusbar` 盖掉了，
 *    于是设计稿上看不出「这页含不含通知栏」。
 *  · 现在把同一条状态栏**画进这一页里**（浅色文字），语义就显式了：
 *    深色底顶到屏幕最上沿，状态栏内容以浅色浮在它上面。
 *  · 只改 CSS 与 `timerFullHTML()` 两处；`statusBar()` 本体不动（别的屏共用）。
 *
 * 用法：node tool/proto_tfbar_r47.cjs          （改）
 *       node tool/proto_tfbar_r47.cjs --check  （只校验现状）
 */
const fs = require('fs');
const path = require('path');

const FILE = path.join(__dirname, '..', 'zaoji-prototype.html');
const raw = fs.readFileSync(FILE, 'utf8');
const EOL = raw.includes('\r\n') ? '\r\n' : '\n';
const bytesBefore = raw.length;

function j(s) {
  return s.split('\n').map((x) => x.replace(/\r$/, '')).join(EOL);
}

const EDITS = [
  {
    name: 'CSS：.timer-full 里的状态栏转浅色',
    from: `.timer-full-inner{position:relative;z-index:2;flex:1;display:flex;flex-direction:column;padding:16px 24px 30px}`,
    to: `.timer-full-inner{position:relative;z-index:2;flex:1;display:flex;flex-direction:column;padding:16px 24px 30px}
/* R47：全屏计时页**从状态栏那一层开始画**——深色底顶到屏幕最上沿，
   时间/信号/电量以浅色浮在上面（对应 Flutter 侧 SystemUiOverlayStyle.light）。
   状态栏本体复用别的屏那一条 markup，只在这里换配色与层级。 */
.timer-full .statusbar{position:relative;z-index:2;color:#FFF3E8;opacity:.92}`,
  },
  {
    name: 'JS：timerFullHTML 里画进状态栏',
    from: `  return '<div class="timer-full">' +
    '<div class="timer-full-inner">' +`,
    to: `  return '<div class="timer-full">' +
    statusBar() +
    '<div class="timer-full-inner">' +`,
  },
];

const check = process.argv.includes('--check');
let out = raw;
let bad = 0;
for (const e of EDITS) {
  const from = j(e.from);
  const to = j(e.to);
  const hits = out.split(from).length - 1;
  if (hits !== 1) {
    console.log(`[${e.name}] 命中 ${hits} 次（要求恰好 1）→ ${hits === 0 ? 'FAIL' : 'FAIL(歧义)'}`);
    bad++;
    continue;
  }
  if (check) {
    console.log(`[${e.name}] 现状已符合（命中 1）`);
    continue;
  }
  out = out.replace(from, to);
  console.log(`[${e.name}] OK`);
}

if (bad) {
  console.log(`锚点校验失败 ${bad} 处，未写盘。`);
  process.exit(1);
}
if (check) {
  console.log('--check：只读校验通过');
  process.exit(0);
}

const grew = out.length - bytesBefore;
if (grew < 60 || grew > 4000) {
  console.log(`体积变化 ${grew} 不在预期区间，未写盘。`);
  process.exit(1);
}
fs.writeFileSync(FILE, out, 'utf8');
console.log(`写盘完成：+${grew} bytes（${bytesBefore} → ${out.length}）`);
