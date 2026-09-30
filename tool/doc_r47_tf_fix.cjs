// 纠一条刚写错的账：文档里「离屏自动恢复 / 不在 dispose 里手改样式」是错的。
//
// 真机制（这轮读框架源码读出来的，不是猜的）：
//   · `RenderView._updateSystemChrome`（rendering/view.dart:445）在**读不到任何注解时直接 return**，
//     不会把上一次的样式还原；
//   · 但这个 App 里还有第二个写家：`MaterialApp._themeBuilder`（material/app.dart:1003）
//     每次构建都按主题亮度推一记默认样式，而那份默认的导航栏是**实心黑**；
//   · 所以退出全屏页必须自己显式推「深色图标 + 透明栏」那一记，
//     用例也要看**推给系统的调用记录**——比 `latestStyle` 测到的是"谁最后写"的竞态，
//     第一版就是这么假绿的（摘掉收尾代码，测试照样绿）。
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');

const TAIL_ROW = '★ 记这条是因为它长得像实现 bug——其实是工装与 IME 打架 |';
const NEW_ROW =
  '| ★★ **`AnnotatedRegion` 不会自动还原，而且这个 App 里还有第二个写家** | ' +
  '全屏计时页要接管状态栏（深色页配浅色图标），用的是 `AnnotatedRegion<SystemUiOverlayStyle>`。' +
  '直觉是"这屏走了注解自然失效、底下那屏回来"——**错**：`RenderView._updateSystemChrome` 在读不到任何注解时是' +
  '`return`，不还原（rendering/view.dart:445）。那为什么摘掉我们自己的收尾代码，测试还是绿的？' +
  '因为 `MaterialApp._themeBuilder` 每次构建都会按主题推一记默认样式（material/app.dart:1003）——' +
  '它是第二个写家，会替你把图标颜色兜回来，但它那份的**导航栏是实心黑**（我们要透明）。' +
  '两条落地结论：① 退出深色页**显式推回**自己那一记，别赌别人什么时候重建；' +
  '② 这类"谁最后写"的状态**不能拿 `SystemChrome.latestStyle` 当判据**（测到的是竞态），' +
  '要挂 mock handler 收 `SystemChannels.platform` 上的 `SystemChrome.setSystemUIOverlayStyle` 调用记录，' +
  '按**我们那一记的指纹**（深色图标 + 两套栏都透明）断言——变异脚本这才真的能把它摘红 |';

const FIX = [
  {
    file: path.join(ROOT, '灶记-交接文档.md'),
    from: '；离开这屏 AnnotatedRegion 自己失效，**不在 dispose 里手动改样式**（那种写法迟早漏恢复）。',
    to: '；★ 退出这屏**必须自己显式推回**「深色图标 + 透明栏」那一记——' +
      '`RenderView._updateSystemChrome` 读不到注解时是直接 `return`（不还原），' +
      '而 `MaterialApp._themeBuilder` 那个第二写家兜底用的是**实心黑导航栏**的默认样式，冒充不了我们这份；' +
      '用例因此断"推给系统的调用记录"而不是 `SystemChrome.latestStyle`（详见 §7.10 最后一条）。',
  },
  {
    file: path.join(ROOT, '灶记-交接文档.md'),
    from: '声明浅色状态栏图标，离屏自动恢复（不在 dispose 里手改样式）',
    to: '声明浅色状态栏图标，★ 退出时**显式推回**「深色图标 + 透明栏」（框架不还原 + MaterialApp 那份带实心黑导航栏，见 §7.10）',
  },
  {
    file: path.join(ROOT, '灶记-开发计划书.md'),
    from: '与直觉相反，所以逐项写死不用常量），离屏自动恢复，不在 dispose 里手改样式；',
    to: '与直觉相反，所以逐项写死不用常量），★ 退出这屏**显式**推回「深色图标 + 透明栏」——' +
      '`RenderView` 读不到注解时直接 return 不还原，而 `MaterialApp` 兜底那份默认样式带实心黑导航栏；' +
      '用例因此断"推给系统的调用记录"而不是 `latestStyle`；',
  },
];

const check = process.argv.includes('--check');
let bad = 0;
const staged = new Map();
for (const e of FIX) {
  const raw = fs.readFileSync(e.file, 'utf8');
  const eol = raw.includes('\r\n') ? '\r\n' : '\n';
  const j = (s) => s.split('\n').map((x) => x.replace(/\r$/, '')).join(eol);
  const from = j(e.from), to = j(e.to);
  const base = staged.get(e.file) || raw;
  const hits = base.split(from).length - 1;
  if (hits !== 1) {
    console.log(`[${path.basename(e.file)}] ${e.from.slice(0, 24)}… 命中 ${hits} 次 → FAIL`);
    bad++;
    continue;
  }
  console.log(`[${path.basename(e.file)}] ${e.from.slice(0, 24)}… OK`);
  staged.set(e.file, base.replace(from, to));
}
// §7.10 追加一条（锚在最后一条数据行行尾）
{
  const raw = fs.readFileSync(FIX[0].file, 'utf8');
  const eol = raw.includes('\r\n') ? '\r\n' : '\n';
  const j = (s) => s.split('\n').map((x) => x.replace(/\r$/, '')).join(eol);
  const anchor = j(TAIL_ROW);
  let base = staged.get(FIX[0].file) || raw;
  const hits = base.split(anchor).length - 1;
  if (hits !== 1) {
    console.log(`[§7.10 追加一条] 锚命中 ${hits} 次 → FAIL`);
    bad++;
  } else {
    console.log('[§7.10 追加一条] OK');
    base = base.replace(anchor, anchor + eol + j(NEW_ROW));
    staged.set(FIX[0].file, base);
  }
}
if (bad) {
  console.log(`\n锚点校验失败 ${bad} 处，未写盘。`);
  process.exit(1);
}
if (check) {
  console.log('--check：锚点全部命中，未写盘。');
  process.exit(0);
}
for (const [f, text] of staged) {
  const grew = Buffer.byteLength(text) - Buffer.byteLength(fs.readFileSync(f));
  fs.writeFileSync(f, text, 'utf8');
  console.log(`写盘 ${path.basename(f)}：${grew >= 0 ? '+' : ''}${grew} bytes`);
}
