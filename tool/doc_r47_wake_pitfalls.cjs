// 往交接文档 §7.10 那张「R47 坑」表**末尾追加**第二段（常亮）踩到的三颗坑。
//
// 表格插行是这个仓库的老事故点（用下一行的行首当锚点会把它的行首吞掉），
// 所以这里按「整行前缀」定位、用 splice 追加、当场断言列数与残行。
// 用法：node tool/doc_r47_wake_pitfalls.cjs
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DOC = path.join(ROOT, '灶记-交接文档.md');
const SNAP = path.join(ROOT, 'dist', 'handover_before_r47_wake_pitfalls.md');

const ROWS = [
  '| ★ **`setUp` 里 `await store.ready()`，App 根测试会 `pumpAndSettle timed out`** | `setUp` 跑在**真实区**，`testWidgets` 体跑在 FakeAsync 区，两边不是同一个时钟；从真实区把 store 递进测试区，界面永远设不完（四条用例一起红，看着像实现坏了）。**store / 计时台 / 记账本一律在 testWidgets 体内造、体内 `addTearDown`**（与 `kitchen_prefs_r47_test.dart` 同一口径） |',
  '| ★ **新增 `InheritedWidget` 依赖会把「页面直挂」的窄 harness 打红** | 做菜屏加了 `WakeScope.of(context)` 之后，`allergen_r40_test.dart` 那个 `StoreScope + MaterialApp(home: CookingPage)` 的裸挂立刻炸。**修法是给 harness 补上 scope，不是把 `of()` 换成 `maybeOf()`**——后者会把「漏挂」从响一声变成静默不生效，正是本项目一直反对的那种假绿 |',
  '| ★ **注入的 `TimerBoard` 不由 App 关，用例结尾必须自己 `closeAll()`** | 跑表期间有 250ms 周期心跳，`addTearDown(board.dispose)` 跑在绑定不变量检查**之后**，所以留到最后就是「A Timer is still pending even after the widget tree was disposed」。两条用例红在这一行上，与实现无关 |',
];

const guard = (label, cond, extra) => {
  if (!cond) { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); process.exit(1); }
  console.log('✔ ' + label);
};

const src = fs.readFileSync(DOC, 'utf8');
fs.writeFileSync(SNAP, src);
const lines = src.split('\n');
const cols = (l) => (l.match(/\|/g) || []).length;

// 锚：§7.10 那张表的最后一行（按整行前缀）
const anchorPrefix = '| ★ **结构性编辑大文件，脚本不如手工**';
const hits = lines.map((l, i) => [l, i]).filter(([l]) => l.startsWith(anchorPrefix));
guard('找到 §7.10 末行锚点且唯一', hits.length === 1, 'n=' + hits.length);
const at = hits[0][1];
guard('锚行是 2 列（3 个竖线，§7.10 这张表是「坑 / 实况」两栏）', cols(lines[at]) === 3, 'cols=' + cols(lines[at]));
guard('锚行确实在 §7.10 之后、§八 之前',
  lines.slice(0, at).some((l) => l.startsWith('### 7.10')) &&
  lines.slice(at).some((l) => l.startsWith('## 八')),
  '区间判断失败');

ROWS.forEach((r, i) => guard('新行 ' + (i + 1) + ' 也是 3 个竖线', cols(r) === 3, 'cols=' + cols(r)));

const cr = lines[at].endsWith('\r');
const out = [...lines];
out.splice(at + 1, 0, ...ROWS.map((r) => r + (cr ? '\r' : '')));
const text = out.join('\n');
guard('行数 +3', out.length === lines.length + 3, lines.length + ' -> ' + out.length);
guard('全文没有以空格开头的悬挂续行',
  text.split('\n').filter((l) => l.startsWith(' |')).length === 0);
guard('三行各只出现一次',
  ROWS.every((r) => text.split('\n').filter((l) => l.startsWith(r.slice(0, 28))).length === 1));

fs.writeFileSync(DOC, text);
console.log('  追加在第 ' + (at + 2) + '~' + (at + 4) + ' 行');
console.log('  快照：' + path.relative(ROOT, SNAP));
console.log('全部通过');
