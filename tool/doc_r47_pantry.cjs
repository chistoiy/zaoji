// R47 第四段（库存到期提醒 FR-PAN-04 的推送时机）落地后的划账：改交接文档。
//
// 写法遵守记过的三条坑：
//  · 全是**整行替换 / 整块替换 / 按整行前缀插入**，不拿下一行行首当锚点（表格插行会吞行首）；
//  · 每步断言命中次数、列数、行数，改前拍快照，改后校验只变长；
//  · 行尾跟随目标文件（这份文档是 CRLF），多行文本一律 join(EOL) 而不是硬写 \n。
// 用法：node tool/doc_r47_pantry.cjs
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DOC = path.join(ROOT, '灶记-交接文档.md');
const SNAP = path.join(ROOT, 'dist', 'handover_before_r47_pantry.md');

const guard = (label, cond, extra) => {
  if (!cond) { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); process.exit(1); }
  console.log('✔ ' + label);
};

const before = fs.readFileSync(DOC, 'utf8');
fs.writeFileSync(SNAP, before);
guard('快照已存', fs.readFileSync(SNAP, 'utf8') === before);

const lines = before.split('\n');
const EOL = lines.some((l) => l.endsWith('\r')) ? '\r' : '';
const cols = (l) => (l.match(/\|/g) || []).length;
const find = (prefix, wantCols) => {
  const hits = lines.map((l, i) => [l, i]).filter(([l]) => l.startsWith(prefix));
  guard('锚唯一：' + prefix.slice(0, 28), hits.length === 1, 'n=' + hits.length);
  const i = hits[0][1];
  if (wantCols !== undefined) guard('列数 ' + prefix.slice(0, 18), cols(lines[i]) === wantCols, cols(lines[i]));
  return i;
};
// 多行块：数组 → 带行尾的行序列
const block = (arr) => arr.map((l) => l + EOL);

/* ——— ① §五 标题 ——— */
{
  const i = find('### R47 · 2026-09-30 ·');
  lines[i] =
    '### R47 · 2026-09-30 · 计时内核 deadline 化 + 多计时器并行 + 悬浮球/全屏两形态 + 本机偏好 + 屏幕常亮 + 计时结束通知 + 库存到期提醒（**前四段，本轮未完**）' + EOL;
}

/* ——— ② §五 边界那句（两行整块替换） ——— */
{
  const i = find('**先说清楚边界**');
  guard('第二行是「前三段交了计时」', lines[i + 1].startsWith('**前三段交了计时'));
  lines.splice(i, 2, ...block([
    '**先说清楚边界**：R47 的范围（计划书 §22.2）还剩首页过期卡、开饭前投待办没做——',
    '**前四段交了计时（①~④）、偏好（③⑤⑥⑦）与常亮（⑤）、计时结束通知与声音（⑥）、库存到期提醒（⑦）**，其余写在下面「还没做的」里，别把这一节当整轮划掉。',
  ]));
}

/* ——— ③ §五 基线那句（两行整块替换） ——— */
{
  const i = find('**基线**：shared **193**（177→193）· server 320（未动）· app 329 → **351**');
  guard('第二行是「→ **361**（第二段」', lines[i + 1].startsWith('→ **361**（第二段'));
  lines.splice(i, 2, ...block([
    '**基线**：shared **193**（177→193）· server 320（未动）· app 329 → **351**（第一段：新增 14 + 8，`recipe_flow_test` 的胶囊用例改写成悬浮球链）',
    '→ **361**（第二段：`wake_r47_test` 新增 10）→ **377**（第三段：`notify_r47_test` 新增 16）→ **389**（第四段：`pantry_expiry_r47_test` 新增 12）· analyze 三处全 0。',
  ]));
}

/* ——— ④ 新增 ⑦ 段 + 「还没做的」整块重写 ——— */
{
  const i = find('**还没做的**（R47 剩下的账，接手从这里接）：');
  let end = -1;
  for (let j = i; j < lines.length; j++) {
    if (lines[j].startsWith('**产物/版本号/push 一概没动**')) { end = j; break; }
  }
  guard('「还没做的」块找得到结尾行', end > i, 'end=' + end);

  const NEW7 = [
    '⑦ **第四段（同日接上）· 库存到期与临期的提醒（FR-PAN-04 的推送时机）**。',
    '判定函数（`PantryItem.expState` 的 `bad`/`soon` 三态）R28 就做实了，这一轮补的**只是推送时机**——所以新增的代码里没有一条新业务规则，',
    '全是「什么时候发、发几条、发过没有、谁有权静音它」。',
    '新增 `app/lib/data/pantry_watch.dart`：`PantryWatch` 挂在**打开 App 与回前台**这两处（`main._initAlert` 等 store 就绪后一次、',
    '`didChangeAppLifecycleState(resumed)` 一次），**刻意不做后台定时**——那要 Android 精确闹钟与 APNs 级的调度，是 M3 的事；',
    '本机只保证「打开时一定看得见」，并且**同一天只发一次**（去重戳落 `local_pref`）。',
    '★ **聚合到最多两条**（过期一条、临期一条，各带 3 个名字与「等 N 样」）：14 项库存发 14 条横幅，用户接下来做的事是**去系统里把整个通知权限关掉**，',
    '那连灶上的到点提醒也没了——安静地少发不是偷懒，是保住另一路。`sound: false` 同理：到期提醒是「有空看一眼」，只有灶上到点才该响。',
    '通知 id 用**号段分界**：库存占 1、2，计时器一律落在 `TimerAlert.timerIdFloor`（1000）以上，两条路永不互相覆盖横幅（同 id 系统会当成同一条替换掉）。',
    '为此把 `TimerAlert.fire()` 拆出通用的 `send(List<AlertNotice>)`，计时与库存共用同一道授权闸门。',
    '★ **两枚开关各管各的**：`KitchenPrefs` 新增 `expiryNotifyOn`（默认开），**没有复用计时器那枚 `notifyOn`**——',
    '想静音到期提醒的人不该顺手把正在灶上跑的计时器也关掉；这条独立性由测试断言。',
    '**当日去重戳**落 `local_pref` 的 `pantry_expiry_notified_day`，只认 `^\\d{4}-\\d{2}-\\d{2}$`（脏值当没有，不猜），',
    '`_loadExpiryStamp` 进 `_doInit`（吃 R45/R46 那条「冷启动漏加载」的链）。★ **被闸门挡掉时不落戳**：',
    '没授权或被本机开关关掉就写「今天已经提醒过」，用户当场点完授权后**今天反而不会再提醒**——那是这条最隐蔽的自毁。',
    '守卫：`app/test/pantry_expiry_r47_test.dart` **12 例**（含两条真重载：戳与 `expiryNotifyOn` 都重建 store 读回）；',
    '反向验证 `tool/pantry_r47_mutation.cjs` 两次——`stamp`（把「发成功才落戳」改成无条件落戳）→ ★ 那条不落戳的用例红',
    '（`Expected: \x27\x27 Actual: \x272026-09-30\x27`）；`dedupe`（摘掉当日比对）→ 「同一天第二次开 App 不再发」红（`Expected: <0> Actual: <1>`）；',
    '`restore` 装回后 12 例重新全绿。',
    '★ **UI 先原型后实现**：`tool/proto_expiry_r47.cjs` 在「我的」页加「库存到期提醒」一行（`ic(\'alert\')` 线性图标、',
    '副文案写明「打开 App 时提醒一次，同一天不重复」，**无条件出现**——它不随系统授权态出没，本机开关归本机开关），',
    '走查 `tool/proto_expiry_r47_walk.cjs` 全 PASS。实现侧 `me_page` 同一行落在声音那行之后。',
    '这一段和第三段一样，**本机只验到逻辑**：横幅到底长什么样、Web 在 https 下能不能弹，仍要真机（见下面「还没做的」①）。',
    '',
  ];
  const TODO = [
    '**还没做的**（R47 剩下的账，接手从这里接）：',
    '① **通知的真机验收（两路一起）**：计时到点（⑥）与库存到期（⑦）的逻辑、闸门、清单都落地了，',
    '但「系统弹框长什么样、渠道真的出声、Web 在 https 下能弹」这三件事只能在真机上看（Android 13+ 与浏览器都要在用户手势里授权）。',
    '**别把 16 例 + 12 例全绿读成「通知已验收」。**',
    '② **FR-PAN-06 首页「即将过期 / 快没了」卡**：判定函数与计数（`PantryWatch.lastBad/lastSoon`）都是现成的，**不依赖通知**，',
    '卡住的只有「首页是哪一屏」——App 五个标签里没有独立的「首页」，这一条要用户拍。',
    '③ **FR-PLAN-09 开饭前投待办**：它是 FR-SET-01 的钥匙，先要定「待办落在哪儿」（项目里没有待办实体，备菜清单派生不落库；',
    '建 `plan_task` 表 = 改列轮 = apk 与 exe 必须同发那笔硬账）。★ 所以 FR-SET-01 那枚开关刻意只在原型里，',
    '实现不上「能打开但什么都不发生」的控件。',
    '④ **FR-SET-03 的语音那一路**（TTS，FR-COOK-12/13）按计划书后置到 R53 之后，不卡这一轮。',
    '**产物/版本号/push 一概没动**；前四段零 schema 改动，所以不欠「apk+exe 同发」——但 ②③ 一旦要做就会打破这条。',
  ];
  lines.splice(i, end - i + 1, ...block(NEW7.concat(TODO)));
}

/* ——— ⑤ §六-20 整行重写（3 列） ——— */
{
  const i = find('| 20 | **R47 前三段已完成', 4);
  lines[i] = ('| 20 | **R47 前四段已完成（2026-09-30，本轮未完）** | ✅ **计时内核 deadline 化 + 多计时器并行 + 悬浮球与全屏两形态 + `KitchenPrefs` 本机偏好 + 屏幕常亮 + 计时结束通知与声音 + 库存到期提醒**（FR-COOK-03/04/05/**09**/**14**、**FR-PAN-04 的推送时机**、FR-SET-02、FR-SET-03 的震动与声音两路、NFR-REL-03）：细节、反漂移证据、引用计数、授权态与通知号段分界见 §五 R47 ①~⑦，坑在 §7.10。**基线** shared **193**（177→193）· server 320（未动）· app **389**（329→351→361→377→389）· analyze 三处 0 · 原型走查全绿（timers 32 / prefs 17 / notify 22 / expiry / nutrition 40）。★ **通知两路本机只验到逻辑闸门，没验到真机呈现**：系统弹框、渠道实际出声、Web 在 https 下能否弹，都要连 §六-1 的真机清单一起走，别把全绿当验收。**还欠三条**：① **FR-PAN-06 首页「即将过期 / 快没了」卡**——判定与计数（`PantryWatch.lastBad/lastSoon`）现成、**不依赖通知**，卡住的只是「App 五个标签里没有独立首页，这张卡挂哪一屏」，要用户拍；② **FR-PLAN-09 开饭前投待办**——它是 FR-SET-01 的钥匙，项目里**没有待办实体**（备菜清单派生、不落库），那枚开关因此刻意只在原型里，实现不上「能打开但什么都不发生」的控件；要推进先由用户拍**待办落在哪儿**（建 `plan_task` 表 = 改列轮 = apk 与 exe 必须同发）；③ FR-SET-03 的**语音**那一路（TTS）按计划书后置 R53。产物 / 版本号 / push 一概没动；前四段都零 schema 改动，不欠「apk + exe 同发」——但 ①② 一动就会破这条 |') + EOL;
  guard('§六-20 新行仍是 3 列', cols(lines[i]) === 4, cols(lines[i]));
}

/* ——— ⑥ §九 R47 行：小改三处（标题、插入 ⑦、基线号） ——— */
{
  const i = find('| R47 | 2026-09-30 |', 4);
  let row = lines[i].replace(/\r$/, '');
  guard('行首写「前三段」', row.includes('（前三段，本轮未完）'));
  row = row.replace('（前三段，本轮未完）', '（前四段，本轮未完）');
  guard('有 ⑦ 基线那段', row.split('⑦ **基线**').length - 1 === 1);
  const NEW7ROW = '⑦ **库存到期提醒（FR-PAN-04 的推送时机）**：判定三态 R28 就有，这轮只补推送时机——`data/pantry_watch.dart` 挂在「打开 App / 回前台」这一次判定上（★ **刻意不做后台定时**，那要精确闹钟与 APNs，是 M3）；过期与临期**聚合成最多两条**、各带 3 个名字（发 14 条只会逼用户关掉整个通知权限，连灶上的表一起哑），`sound:false`（到期是「有空看一眼」）；★ **通知 id 号段分界**：库存占 1/2，计时器一律落在 `TimerAlert.timerIdFloor`（1000）以上，两条路不互盖，为此把 `fire()` 拆出通用 `send(List<AlertNotice>)`；★ **独立开关 `expiryNotifyOn`**（不复用计时器那枚：静音库存提醒不该顺手关掉灶上的表）；**当日去重戳**落 `local_pref` 的 `pantry_expiry_notified_day`（只认 `YYYY-MM-DD`，脏值当没有），★ **被闸门挡掉不落戳**（否则用户当场授权后今天反而不提醒）；`pantry_expiry_r47_test` **12 例**含两条真重载，`tool/pantry_r47_mutation.cjs` 的 `stamp`/`dedupe` 各红 1 条；原型 `proto_expiry_r47.cjs` + 走查全 PASS。';
  row = row.replace('⑦ **基线**', NEW7ROW + '⑧ **基线**');
  guard('基线那项改成 app **389**', row.includes('app 329→**377**'));
  row = row.replace('app 329→**377**', 'app 329→**351**→**361**→**377**→**389**');
  guard('结尾「本轮未完」那句换掉', row.includes('**本轮未完**：到期提醒（FR-PAN-04 的推送时机）'));
  row = row.replace(
    '**本轮未完**：到期提醒（FR-PAN-04 的推送时机）、首页卡与投待办（FR-PAN-06/FR-PLAN-09，后者要先拍待办落哪儿）——见 §六-20',
    '**本轮未完**：通知两路的**真机验收**、首页卡（FR-PAN-06，这张卡挂哪一屏要拍）与开饭前投待办（FR-PLAN-09，先拍待办落哪儿）——见 §六-20');
  guard('行数没变（单行替换）', !row.includes('\n'));
  guard('改后仍是 3 列', (row.match(/\|/g) || []).length === 4, (row.match(/\|/g) || []).length);
  lines[i] = row + EOL;
}

/* ——— ⑦ §7.10 标题与追加坑（按整行前缀插，不拿下一行行首当锚点） ——— */
{
  const i = find('### 7.10 R47 新增的坑');
  lines[i] = '### 7.10 R47 新增的坑（计时内核 / 偏好 / 常亮 / 通知 / 到期提醒，每条都真红过）' + EOL;

  const PIT = [
    '| ★ **被闸门挡掉时不许写「今天已经提醒过」** | 去重戳如果无条件落盘，症状是「用户点了授权，今天反而再也不提醒」——**最合理的那步操作把功能自己关掉了**，而且只在当天有效、复现一次就过去。`stamp` 变异（摘掉 `if (n > 0)`）钉的就是这条，红在「被授权闸门挡掉时不落戳」 |',
    '| ★ **两条通知路共用一套 id 就必须分区段** | 通知 id 相同会被系统当成同一条**替换**，于是「库存到期」能把「计时到点」的横幅顶掉。库存只占 1、2，计时器一律落在 1000 以上的号段（`noticeIdOf` 把 floor 并进高位），并用一条测试断言号段互不重叠——别等它在真机上偶发一次 |',
    '| ★ **到期提醒要聚合，且聚合数要写进注释** | 判定完有 14 项就发 14 条横幅是「更完整」的写法，但用户下一步是去系统里关掉整个通知权限，灶上的到点提醒跟着一起没。最终口径：**最多两条**（过期 / 临期各一条）、各带 3 个名字加「等 N 样」。因果不写进注释，下一个人会当保守实现优化掉 |',
    '| ★ **借来的开关会串味** | 到期提醒最初挂在计时器的 `notifyOn` 上，但「我想静音库存」与「灶上到点不要响」是两回事，后者还带安全属性。改成独立的 `expiryNotifyOn`，并断言翻一枚不动另一枚 |',
    '| ★ **本机偏好的旧值要认格式，不认就当没有** | `local_pref` 是一段 JSON 字符串，可能被手改坏、也可能被旧版本写过别的形状。去重戳只接受 `^\\d{4}-\\d{2}-\\d{2}$`：脏值若被当成「今天已提醒」，这条提醒就**永久静音**。测试里专门喂了一条坏值 |',
    '| ★ **flutter_test / drift 的两条 API 落差**（工装级） | `group(..., tags:)` 在 flutter_test 里不支持（是跑不起来，不是跳过）；drift 的裸 `Variable` 没有 `driftVar()` 这类工厂函数，要 `import \'package:drift/drift.dart\' show Variable` |',
  ];
  const at = find('| ★ **新 `InheritedWidget` 又打红了一个「页面直挂」harness**', 3);
  guard('末行是 2 栏表', cols(lines[at]) === 3, cols(lines[at]));
  guard('新坑每行也都 2 栏', PIT.every((r) => (r.match(/\|/g) || []).length === 3), PIT.map((r) => (r.match(/\|/g) || []).length).join('/'));
  lines.splice(at + 1, 0, ...block(PIT));
}

/* ——— 落盘前总校验 ——— */
const after = lines.join('\n');
guard('⑦ 段进了文档', after.includes('⑦ **第四段（同日接上）· 库存到期与临期的提醒'));
guard('基线写了 389', after.includes('**389**（第四段：`pantry_expiry_r47_test` 新增 12）'));
guard('§六-20 升到「前四段已完成」', after.includes('| 20 | **R47 前四段已完成'));
guard('§九 那行有 ⑦ 库存到期提醒', (after.match(/⑦ \*\*库存到期提醒/g) || []).length === 1);
guard('还欠的三条里没有 FR-PAN-04（已划掉）', !after.includes('还欠三条**：① **FR-PAN-04'));
guard('没有以空格开头的悬挂续行', after.split('\n').filter((l) => l.startsWith(' |')).length === 0);
guard('行数只增不减', after.split('\n').length > before.split('\n').length, before.split('\n').length + ' → ' + after.split('\n').length);
guard('文件只变长', after.length > before.length, before.length + ' → ' + after.length);

fs.writeFileSync(DOC, after);
console.log('✔ 已写入 ' + path.relative(ROOT, DOC) + '（快照：' + path.relative(ROOT, SNAP) + '）');
