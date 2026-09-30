// R47 通知三路的真机验收结果落档（Android 侧已过，Web/是否 audible 仍欠）。
// 同一套写法：整行/整块替换 + 命中断言 + 列数校验 + 快照 + 体积护栏。
// 用法：node tool/doc_r47_devcheck.cjs
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DOC = path.join(ROOT, '灶记-交接文档.md');
const SNAP = path.join(ROOT, 'dist', 'handover_before_r47_devcheck.md');

const guard = (label, cond, extra) => {
  if (!cond) { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); process.exit(1); }
  console.log('✔ ' + label);
};

const before = fs.readFileSync(DOC, 'utf8');
fs.writeFileSync(SNAP, before);
const lines = before.split('\n');
const EOL = lines.some((l) => l.endsWith('\r')) ? '\r' : '';
const cols = (l) => (l.match(/\|/g) || []).length;
const find = (prefix, wantCols) => {
  const hits = lines.map((l, i) => [l, i]).filter(([l]) => l.startsWith(prefix));
  guard('锚唯一：' + prefix.slice(0, 32), hits.length === 1, 'n=' + hits.length);
  const i = hits[0][1];
  if (wantCols !== undefined) guard('列数 ' + prefix.slice(0, 20), cols(lines[i]) === wantCols, String(cols(lines[i])));
  return i;
};
const block = (arr) => arr.map((l) => l + EOL);

/* ——— ① 「还没做的」① 块改成真机验收读数 ——— */
{
  const i = find('① **通知的真机验收（三路一起）**');
  guard('第二行是「但「系统弹框长什么样」', lines[i + 1].startsWith('但「系统弹框长什么样'));
  guard('第三行是「别把 16 例」', lines[i + 2].startsWith('**别把 16 例'));
  lines.splice(i, 3, ...block([
    '① **通知的真机验收：Android 侧三路已过（2026-09-30，Xiaomi 14 / HyperOS OS3.0.306，release 包 0.16.0+14）**。',
    '计时到点 `id=87321592`「「30 秒」时间到 / 该起锅了」、库存到期 `id=2`「4 样三天内到期 / 小里脊、排骨、茄子 等 4 样」、',
    '开饭待办 `id=100`「16:00 晚餐 · 还剩 68 分钟开饭 / 1 道菜 · 备菜 10 样 · 步骤 6 步」——三条同框在架。',
    '★ 顺手在真机上验到的还有：**号段互不重叠**（1/2、100、八位数实测各占一段）、通知正文与「我的」那一行**逐字相同**',
    '（`MealDigest.summary` 一处算两处吃）、渠道 `zaoji_timer` 系统侧 `importance=5` + 带通知音 URI + `mVibrationEnabled=false`',
    '（震动只归 `vibrateOn` 那一路）、权限翻转后「通知带声音」那行**才出现**、被闸门挡掉的那一趟**没有落当日戳**',
    '（开完权限立刻补发出来了）、「全部关闭」后面板留「没有在计的表」空态、悬浮球跨 tab 存活到 `00:00`。',
    '**仍然欠两件**：★ 渠道**是否真的 audible** adb 读不到（软件侧证据齐了：`playSound=true` + 渠道有声音 URI），',
    '要人在场听到才算数；以及 **Web 端在 https 下能不能弹**——那要 iPhone Safari 与桌面浏览器各验一次，与 §六-1 那份清单一起走。',
  ]));
}

/* ——— ② §六-20 那行的 ★ 改口 ——— */
{
  const i = find('| 20 | **R47 七段已完成', 4);
  let row = lines[i].replace(/\r$/, '');
  const OLD = '★ **通知三路（⑥⑦⑨）本机只验到逻辑闸门，没验到真机呈现**：系统弹框、渠道实际出声、Web 在 https 下能否弹，都要连 §六-1 的真机清单一起走，别把全绿当验收。';
  guard('§六-20 那句 ★ 原样命中（replace 不是空转）', row.includes(OLD));
  const NEW = '★ **通知三路（⑥⑦⑨）Android 侧已真机验收（2026-09-30，Xiaomi 14 / HyperOS，release 0.16.0+14）**：三条同框在架、号段互不重叠、正文与设置页那行逐字相同、渠道 importance=5 带声音且不自己振、被闸门挡掉那趟没落戳——读数见 §五 R47「还没做的」①。**还欠两件**：渠道是否真出声只能靠人在场听到；Web 在 https 下能否弹要与 §六-1 清单一起验。';
  row = row.replace(OLD, NEW);
  row = row.replace('**R47 剩下的只有**：① 上面那句真机验收（要设备时段）；',
    '**R47 剩下的只有**：① 通知的 audible 与 Web 端呈现（Android 三路已过）；');
  guard('§六-20 已改口', row.includes('Android 侧已真机验收') && row.includes('① 通知的 audible 与 Web 端呈现'));
  guard('改后仍是 3 列', (row.match(/\|/g) || []).length === 4, String((row.match(/\|/g) || []).length));
  lines[i] = row + EOL;
}

/* ——— ③ §九 R47 行：在 ⑪ 基线之后补一条真机验收 ——— */
{
  const i = find('| R47 | 2026-09-30 |', 4);
  let row = lines[i].replace(/\r$/, '');
  guard('有 ⑪ 基线那项', row.includes('⑪ **基线**'));
  const OLD_TAIL = '——见 §六-20 |';
  guard('行尾锚原样命中', row.endsWith(OLD_TAIL), row.slice(-40));
  const ADD = '⑫ **真机验收（同日补，Xiaomi 14 / HyperOS OS3.0.306 / release 0.16.0+14）**：通知三路同框在架——计时到点 `id=87321592`「「30 秒」时间到 / 该起锅了」、库存到期 `id=2`「4 样三天内到期 / 小里脊、排骨、茄子 等 4 样」、开饭待办 `id=100`「16:00 晚餐 · 还剩 68 分钟开饭 / 1 道菜 · 备菜 10 样 · 步骤 6 步」；★ 号段互不重叠、通知正文与「我的」那行逐字相同、渠道 `zaoji_timer` 系统侧 importance=5 且带通知音、`mVibrationEnabled=false`、权限翻转后「通知带声音」那行才出现、被闸门挡掉那趟**没落当日戳**（开完权限立刻补发=自毁防护成立）、「全部关闭」后留空态、悬浮球跨 tab 存活到 00:00。★ 装机这一路还撞出两条：`flutter_local_notifications` 要 **core library desugaring**（只在第一次真编才炸，见 §7.10），以及 **HyperOS 的应用级通知总开关与 appops 是两层**。仍欠：渠道是否真 audible（要人在场听到）与 Web 在 https 下能否弹。';
  row = row.slice(0, row.length - OLD_TAIL.length) + ADD + OLD_TAIL;
  guard('改后仍是 3 列', (row.match(/\|/g) || []).length === 4, String((row.match(/\|/g) || []).length));
  lines[i] = row + EOL;
}

/* ——— ④ §7.10 追加一条工装坑（HyperOS 两层通知开关那条上一轮已记）——— */
  const PIT = [
    '| ★ **MIUI 中文标点会把 adb 注入的冒号变成全角，两条注入通道都一样** | 给「开饭时间」填 `16:00`：`input text` 与 `input keyboard text` 都落成了 `16：00`，`KEYCODE_COLON(243)` 干脆被吞成空。表单的 ASCII 校验（`^\\d{1,2}:\\d{2}$`）**拒得对**，报了「开饭时间要写成 18:30 这样」。解法：先点键盘上的「中/英」把输入法切到英文再 `input text`。★ 记这条是因为它长得像实现 bug——其实是工装与 IME 打架 |',
  ];
{
  const at = find('| ★ **HyperOS 上「通知权限」是两层，appop 过了不等于能发**', 3);
  guard('新坑每行都是 2 栏', PIT.every((r) => (r.match(/\|/g) || []).length === 3),
    PIT.map((r) => String((r.match(/\|/g) || []).length)).join('/'));
  lines.splice(at + 1, 0, ...block(PIT));
}

const after = lines.join('\n');
guard('① 块写了三路读数', after.includes('开饭待办 `id=100`'));
guard('§六-20 不再写「没验到真机呈现」', !after.includes('没验到真机呈现'));
guard('§九 那行有 ⑫ 真机验收', (after.match(/⑫ \*\*真机验收/g) || []).length === 1);
guard('行数只增不减', after.split('\n').length >= before.split('\n').length,
  before.split('\n').length + ' → ' + after.split('\n').length);
guard('体积只变长', after.length > before.length, before.length + ' → ' + after.length);
guard('没有以空格开头的悬挂续行', after.split('\n').filter((l) => l.startsWith(' |')).length === 0);
fs.writeFileSync(DOC, after);
console.log('✔ 已写入 灶记-交接文档.md（快照：' + path.relative(ROOT, SNAP) + '）');
