// R47 第六段（开饭前投待办 · FR-PLAN-09 + FR-SET-01）落地后的划账。
// 与 doc_r47_pantry_card.cjs 同一套写法：整行/整块替换 + 命中断言 + 列数校验 + 快照 + 只变长。
// ★ 门禁数字不 hand-copy：从 dist/r47meal_gate.log 现读并断言「只升不降」。
// 用法：node tool/doc_r47_meal.cjs
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DOC = path.join(ROOT, '灶记-交接文档.md');
const PLAN = path.join(ROOT, '灶记-开发计划书.md');
const GAP = path.join(ROOT, '灶记-功能查漏补缺-2026-09-29.md');
const LOG = path.join(ROOT, 'dist', 'r47meal_gate.log');
const SNAP = path.join(ROOT, 'dist', 'handover_before_r47_meal.md');
const SNAP_PLAN = path.join(ROOT, 'dist', 'plan_before_r47_meal.md');
const SNAP_GAP = path.join(ROOT, 'dist', 'gap_before_r47_meal.md');

const guard = (label, cond, extra) => {
  if (!cond) { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); process.exit(1); }
  console.log('✔ ' + label);
};

/* ——— ⓪ 门禁读数：从日志现算，不抄 ——— */
const logText = fs.readFileSync(LOG, 'utf8');
const counts = (logText.match(/\+(\d+): All tests passed!/g) || [])
  .map((s) => parseInt(s.replace(/^\+/, ''), 10));
guard('日志里三条全绿读数（shared / server / app）', counts.length === 3, counts.join('/'));
const [SH, SV, AP] = counts;
guard('shared 只升不降（≥193）', SH >= 193, String(SH));
guard('server 只升不降（≥320）', SV >= 320, String(SV));
guard('app 只升不降（≥420 = 400 + 本段 20）', AP >= 420, String(AP));
guard('日志里没有 analyze 问题', !/[1-9]\d* issues? found/i.test(logText),
    (logText.match(/issues? found/gi) || []).join('/'));
const NEW_APP = AP; // 本段后的 app 基线

/* ——— 工具 ——— */
const open = (file, snap) => {
  const before = fs.readFileSync(file, 'utf8');
  fs.writeFileSync(snap, before);
  const lines = before.split('\n');
  const EOL = lines.some((l) => l.endsWith('\r')) ? '\r' : '';
  const cols = (l) => (l.match(/\|/g) || []).length;
  const find = (prefix, wantCols) => {
    const hits = lines.map((l, i) => [l, i]).filter(([l]) => l.startsWith(prefix));
    guard('锚唯一：' + prefix.slice(0, 30), hits.length === 1, 'n=' + hits.length);
    const i = hits[0][1];
    if (wantCols !== undefined) guard('列数 ' + prefix.slice(0, 18), cols(lines[i]) === wantCols, String(cols(lines[i])));
    return i;
  };
  const block = (arr) => arr.map((l) => l + EOL);
  return { before, lines, EOL, cols, find, block, snap };
};
const save = (file, d, opt = {}) => {
  const after = d.lines.join('\n');
  guard('行数只增不减 ' + path.basename(file), after.split('\n').length >= d.before.split('\n').length,
    d.before.split('\n').length + ' → ' + after.split('\n').length);
  if (opt.allowShrink) {
    // 整行替换（把两行结论改写得更短）允许变短，但不许短过一屏——那是误删的量级
    guard('只微幅变短（整行改写）' + path.basename(file),
      after.length > d.before.length - 4000, d.before.length + ' → ' + after.length);
  } else {
    guard('文件只变长 ' + path.basename(file), after.length > d.before.length,
      d.before.length + ' → ' + after.length);
  }
  guard('没有以空格开头的悬挂续行 ' + path.basename(file),
    after.split('\n').filter((l) => l.startsWith(' |')).length === 0);
  fs.writeFileSync(file, after);
  console.log('✔ 已写入 ' + path.relative(ROOT, file) + '（快照：' + path.relative(ROOT, d.snap) + '）');
};

const ONLY = process.argv[2]; // 划账分三段：doc / plan / gap（重跑只补没做的那段）
if (!ONLY || ONLY === 'doc') {
  const d = open(DOC, SNAP);
  const { lines, EOL, find, block } = d;

  // 标题 / 边界 / 基线
  {
    const i = find('### R47 · 2026-09-30 ·');
    guard('标题还写着前五段', lines[i].includes('（**前五段，本轮未完**）'));
    lines[i] = lines[i].replace('+ 厨房告警卡（**前五段，本轮未完**）',
      '+ 厨房告警卡 + 开饭前投待办（**六段，代码收口，欠真机**）') + EOL;

    const j = find('**先说清楚边界**');
    guard('第二行是「前五段交了计时」', lines[j + 1].startsWith('**前五段交了计时'));
    lines.splice(j, 2, ...block([
      '**先说清楚边界**：R47 的范围（计划书 §22.2）到这一段**代码全部收口**——',
      '**六段交了计时（①~④）、偏好（③⑤⑥⑧）与常亮（⑤）、计时结束通知与声音（⑥）、库存到期提醒（⑦）、厨房顶部告警卡（⑧）、开饭前投待办（⑨）**；'
      + '剩下的只有「通知三路（⑥⑦⑨）的真机呈现」与语音那一路，写在下面「还没做的」里，别把这一节当整轮划掉。',
    ]));

    const k = find('**基线**：shared **193**（177→193）· server 320（未动）· app 329 → **351**');
    guard('基线续行以「→ **361**（第二段」开头', lines[k + 1].startsWith('→ **361**（第二段'));
    guard('续行末尾是第五段那句', lines[k + 1].includes('新增 11）· analyze 三处全 0。'));
    lines[k + 1] = lines[k + 1].replace(
      '新增 11）· analyze 三处全 0。',
      '新增 11）→ **' + NEW_APP + '**（第六段：`meal_reminder_r47_test` 新增 20）· analyze 三处全 0。') + EOL;
    guard('基线那句写了 ' + NEW_APP, lines[k + 1].includes('**' + NEW_APP + '**（第六段'));
  }

  // ⑨ 段 + 「还没做的」整块重写
  {
    const i = find('**还没做的**（R47 剩下的账，接手从这里接）：');
    let end = -1;
    for (let j = i; j < lines.length; j++) {
      if (lines[j].startsWith('**产物/版本号/push 一概没动**')) { end = j; break; }
    }
    guard('「还没做的」块找得到结尾行', end > i, 'end=' + end);

    const NEW9 = [
      '⑨ **第六段（同日收口）· 开饭前投待办（FR-PLAN-09 + FR-SET-01）**。',
      '方向是用户拍定的：**继续派生、不建 `plan_task` 表**——这一段仍然零 schema 改动，所以不欠「apk + exe 同发」。',
      '待办的落点就是**一条通知**：新增 `app/lib/data/meal_reminder.dart` 的 `MealReminderWatch`，',
      '判定「今天 + 定了开饭时间 + 排了菜 + 现在落在 `[开饭 − 提前量, 开饭)` 窗口里」（`mealServeTime` / `mealLeadLeft` 都是纯函数，'
      + '时刻形状不认就当没有——`25:99` 与 `\'\'` 一律 null，**不猜**）。',
      '★ **一处算法两处吃**：正文用 `digestOfMenu(store, menu)` 现算的 `3 道菜 · 备菜 13 样 · 步骤 12 步`，' +
      '备菜样数走 `mergeForPrep()` 的**归并之后**条数（不是各道菜食材数相加，与备菜清单同一口径），' +
      '`me_page` 那一行下方列的今日投递用的就是同一个 `MealDigest.summary`——' +
      '有一条用例直接断言「页面上那行 == 通知 body」（⑧ 抽 `pantryAlertOf` 的同一手法，别又写成两份文案）。',
      '★ **一次只投开饭最早的那一餐**：一个窗口里两餐都到期就投两条，等于让用户在通知栏里排菜的序——那是 R50 时间轴的活。' +
      '没被选中那餐**不占戳**，所以第一餐投完，下一餐在自己窗口里会顶上来（用例钉住）。',
      '★ **去重键按餐次、不按天**：`YYYY-MM-DD#餐名`，落 `local_pref` 的 `meal_reminder_notified`。' +
      '库存那枚按天是对的（一天一次就够），这里按天会让「提醒过早餐」把晚餐的投递机会一起吃掉——同一族戳要按被提醒对象的粒度设计。',
      '★ **戳的校验不能交给 `DateTime.tryParse`**：Dart 的解析器会把越界分量**归一**（实测 `2026-13-99` → `2027-04-09`），它不是校验器；' +
      '只能自己按分量卡（「下个月 0 号」= 本月最后一天，闰年与大小月交给 DateTime 自己算）。写新的一餐时把非当天的键剪掉——日期在键里，所以这一步不用读时钟。',
      '★ **被闸门挡掉不落戳**（⑦ 那条自毁在这里同形）：一条都没发出去就记成「今天这餐投过了」，用户点完授权反而永远等不到。',
      '★ **通知 id 用新号段 100**：库存占 1、2，开饭占 100，计时器一律 ≥ `TimerAlert.timerIdFloor`(1000)，三段互不重叠且有用例断言边界；' +
      'id 固定一条，重复提醒是**覆盖**而不是堆叠。`sound: false` 与 ⑦ 同一理由（这是「有空看一眼」，响的该是灶上的表）。',
      '★ **开关是自己的 `mealReminderOn`**，没借计时器那枚 `notifyOn`——真动线那条用例专门把 `notifyOn` 关掉，仍要求这一餐投得出去（借开关会串味，见 §7.10）。',
      '触发点与 ⑦ 同两处：`main._initAlert`（`_store.ready()` 之后，`_loadMenus` 已经在 `_doInit` 里跑完）与 `didChangeAppLifecycleState(resumed)`；' +
      '★ **刻意不做后台排程**（要系统级精确闹钟与 APNs，是 M3 的架构账），所以口径是「开饭前那一刻你正好拿着手机，它就一定投得出去」。',
      'UI 先原型后实现（铁律）：`tool/proto_meal_r47.cjs` 把「今天会投给谁、投出去多长」列进 `me` 屏那一行下方，' +
      '并如实给出「今天没有定了开饭时间的餐次」与「还没排菜」两态（就地六档 chips 第四段就在，这轮补的是投递摘要）；' +
      '同时**摘掉第四段那次脚本改写留下的一处未闭合 `<div class="row">`**——它把后面的行都吞进了一个空 row，' +
      '当时的走查只数 chip 数量、没数层级，所以它一直没响。',
      '走查 `tool/proto_meal_r47_walk.cjs`（**33 条**）全 PASS：期望一律从 `window.__zaoji.MENUS` + `mealDigest()` **现算**' +
      '（造空数据两态：抹掉 `time` → 空态文案；清空 `dishes` → 「还没排菜」），另有层级断言（那一行的父级就是 `.list`、偏好段里没有空 `.row`）。',
      '守卫：`app/test/meal_reminder_r47_test.dart` **20 例**（含四条真重载：戳本身、脏值被拒、跨天剪枝、`mealReminderOn` 与提前量持久化不串味）。' +
      '★ 上一段那条「FR-SET-01 刻意缺席」的断言随之翻面：`kitchen_prefs_r47_test` 现在要求这一行**在**场（缺席与在场各有一条断言钉着，注释写明为什么翻）。',
      '反向验证 `tool/meal_r47_mutation.cjs` 两刀——`prefGate`（摘「本机开关关掉就不投」）→ ★「开关关掉：一条都不发」红（`Expected: <0> Actual: <1>`）；' +
      '`stamp`（改成无条件落戳）→ ★「被授权闸门挡掉不落戳」红（`Expected: empty Actual: Set:[\'2026-12-25#晚餐\']`）；' +
      '`restore` 装回后 20 例重新全绿（与快照逐字节比过）。',
      '★ 这一段和 ⑥⑦ 一样**只验到逻辑闸门**：横幅在真机上长什么样、Web 在 https 下能不能弹，仍欠着（见下面「还没做的」①）。',
      '',
    ];
    const TODO = [
      '**还没做的**（R47 剩下的账，接手从这里接）：',
      '① **通知的真机验收（三路一起）**：计时到点（⑥）、库存到期（⑦）、开饭前投待办（⑨）的逻辑、闸门、清单都落地了，',
      '但「系统弹框长什么样、渠道真的出声、Web 在 https 下能弹」这三件事只能在真机上看（Android 13+ 与浏览器都要在用户手势里授权）。',
      '**别把 16 例 + 12 例 + 20 例全绿读成「通知已验收」。**',
      '② **FR-SET-03 的语音那一路**（TTS，FR-COOK-12/13）按计划书后置到 R53 之后，不卡这一轮。',
      '③ **后台准点投递**（人不在 App 里也按点开饭前弹）：要 Android 精确闹钟 + APNs 级调度，是 M3 的架构账；' +
      '⑦ 与 ⑨ 都刻意只挂在「打开 App / 回前台」上，别把它当成已完成。',
      '**产物/版本号/push 一概没动**；六段全程零 schema 改动，所以不欠「apk+exe 同发」。',
    ];
    lines.splice(i, end - i + 1, ...block(NEW9.concat(TODO)));
  }

  // §六-20 整行重写
  {
    const i = find('| 20 | **R47 前五段已完成', 4);
    lines[i] = ('| 20 | **R47 六段已完成（2026-09-30，代码收口；欠真机验收）** | ✅ **计时内核 deadline 化 + 多计时器并行 + 悬浮球与全屏两形态 + `KitchenPrefs` 本机偏好 + 屏幕常亮 + 计时结束通知与声音 + 库存到期提醒 + 厨房顶部告警卡 + 开饭前投待办**（FR-COOK-03/04/05/**09**/**14**、**FR-PAN-04 的推送时机**、**FR-PAN-06**、FR-SET-01、FR-SET-02、FR-SET-03 的震动与声音两路、**FR-PLAN-09**、NFR-REL-03）：细节、反漂移证据、引用计数、授权态、通知号段、投递窗口与「一份口径」的抽法见 §五 R47 ①~⑨，坑在 §7.10。**基线** shared **' + SH + '**（177→' + SH + '）· server **' + SV + '**（未动）· app **' + NEW_APP + '**（329→351→361→377→389→400→' + NEW_APP + '）· analyze 三处 0 · 原型走查全绿（timers 32 / prefs 17 / notify 22 / expiry 17 / 告警卡 33 / 投待办 33 / nutrition 40）。★ **通知三路（⑥⑦⑨）本机只验到逻辑闸门，没验到真机呈现**：系统弹框、渠道实际出声、Web 在 https 下能否弹，都要连 §六-1 的真机清单一起走，别把全绿当验收。**R47 剩下的只有**：① 上面那句真机验收（要设备时段）；② 语音那一路（TTS，后置 R53 之后）；③ 后台准点投递（M3 的架构账，本轮刻意不做）。产物 / 版本号 / push 一概没动，六段全程零改列，不欠「apk + exe 同发」 |') + EOL;
    guard('§六-20 新行仍是 3 列', d.cols(lines[i]) === 4, String(d.cols(lines[i])));
  }

  // §九 R47 行：插 ⑨（投递）并把基线改号 ⑩、补 ' + NEW_APP + '、结尾改口
  {
    const i = find('| R47 | 2026-09-30 |', 4);
    let row = lines[i].replace(/\r$/, '');
    guard('行首写「前五段，本轮未完」', row.includes('（前五段，本轮未完）'));
    row = row.replace('（前五段，本轮未完）', '（六段，代码收口，欠真机验收）');
    guard('有 ⑨ 基线那项', row.split('⑨ **基线**').length - 1 === 1);
    const NEW9ROW = '⑨ **开饭前投待办（FR-PLAN-09 + FR-SET-01，第六段收口）**：方向由用户拍定——**继续派生、不建 `plan_task` 表**，所以这一段仍零改列、不欠「apk+exe 同发」；待办落成**一条通知**（`data/meal_reminder.dart` 的 `MealReminderWatch`），判定是「今天 + 定了开饭时间 + 排了菜 + 在 `[开饭−提前量, 开饭)` 窗口里」，★ 时刻与日期形状不认就当没有；正文用 `digestOfMenu` 现算的「N 道菜 · 备菜 M 样 · 步骤 K 步」，备菜样数取 `mergeForPrep` **归并后**条数，`me_page` 那一行下方与通知正文吃同一个 `MealDigest.summary`（有用例直接断言两处相等）；★ 一次只投开饭最早那一餐、没选中的不占戳；★ 去重键按**餐次**（`YYYY-MM-DD#餐名`，落 `local_pref`）而不是按天——按天会让早餐的戳吃掉晚餐的机会；★ 戳的校验不能交给 `DateTime.tryParse`（它把 `2026-13-99` 归一成 `2027-04-09`，实测），要自己按月卡天数；★ 被闸门挡掉不落戳（与 ⑦ 同一条自毁）；★ 通知 id 开新号段 100（库存 1/2、开饭 100、计时器 ≥1000 三段互不重叠，有用例断边界）；★ 开关是自己的 `mealReminderOn`，没借 `notifyOn`（真动线用例专门关掉 `notifyOn` 仍要求投得出去）；`sound:false`、触发点只有「打开 App / 回前台」（★ 后台排程要精确闹钟，M3 的账）。原型先行 `proto_meal_r47.cjs`（顺手摘掉第四段脚本留下的一处未闭合 `.row`——当时走查只数 chip 没数层级，所以没响）+ 走查 `proto_meal_r47_walk.cjs` **33 条**全 PASS（期望从 `__zaoji.MENUS` 现算，含空态与「还没排菜」两态、层级断言）；`meal_reminder_r47_test` **20 例**含四条真重载；`meal_r47_mutation.cjs` 的 `prefGate`/`stamp` 各红一条；★ 上一段「FR-SET-01 刻意缺席」的断言翻面成「必须在场」（`kitchen_prefs_r47_test` 同步改）。';
    row = row.replace('⑨ **基线**', NEW9ROW + '⑩ **基线**');
    guard('基线那项里有 400', row.includes('app 329→**351**→**361**→**377**→**389**→**400**'));
    row = row.replace('app 329→**351**→**361**→**377**→**389**→**400**',
      'app 329→**351**→**361**→**377**→**389**→**400**→**' + NEW_APP + '**');
    guard('结尾「本轮未完」那句还在', row.includes('**本轮未完**：通知两路的**真机验收**'));
    row = row.replace(
      '**本轮未完**：通知两路的**真机验收**（要设备时段）与**开饭前投待办 + FR-SET-01 开关**（FR-PLAN-09；落点已拍：**继续派生、不建 `plan_task` 表**，所以仍零改列）——见 §六-20',
      '**代码收口**：R47 六段全部落地，剩下的只有**通知三路（⑥⑦⑨）的真机验收**（要设备时段）、语音那一路（TTS，后置 R53 之后）与**后台准点投递**（M3 的架构账，本轮刻意不做）——见 §六-20');
    guard('改后仍是 3 列', (row.match(/\|/g) || []).length === 4, String((row.match(/\|/g) || []).length));
    lines[i] = row + EOL;
  }

  // §7.10 标题与追加坑
  {
    const i = find('### 7.10 R47 新增的坑');
    lines[i] = '### 7.10 R47 新增的坑（计时内核 / 偏好 / 常亮 / 通知 / 到期提醒 / 告警卡 / 投待办，每条都真红过）' + EOL;

    const PIT = [
      '| ★ **`DateTime.tryParse` 不是校验器**（Dart 会把越界分量归一） | 「只认 `YYYY-MM-DD#餐名`」第一版写成 `tryParse(key.substring(0,10)) != null`，于是 `2026-13-99#晚餐` 被**归一成 2027-04-09** 认了下来（实测），脏值用例照样红。结论：形状正则之外要自己卡分量（月 1~12、日 ≤ 下个月 0 号），别指望解析器替你把关 |',
      '| ★ **同一族去重戳，粒度要按「被提醒的对象」定** | 库存那枚按**天**是对的（一天吵一次就够）；开饭待办照抄按天，就会让「提醒过早餐」把晚餐的投递机会一起记掉。所以本段改成 `YYYY-MM-DD#餐名`，并在写新的一餐时剪掉非当天的键——日期在键里，剪枝就不用读时钟 |',
      '| ★ **窗口判定别用 `Duration.inMinutes`** | 用 `left.inMinutes` 判「在提前量窗口里」，`17:59:30` 打开 App 时 `inMinutes` 是 0，那一分钟里投递不掉、过点又不补，出现一个谁都解释不了的缝。改成**按秒比**（`leftSec <= lead*60`），显示分钟时 `ceil` |',
      '| ★ **改 UI 要连「钉住缺席」的测试一起翻面** | `kitchen_prefs_r47_test` 里那句 `prefs-meal-reminder findsNothing` 是第五段之前**刻意**写的（待办没落点就不放空转开关）；这段落了点，它必须改成 `findsOneWidget`。翻面要在注释里写明「为什么以前要求缺席、现在要求在场」，否则下一个人当成误改改回去——缺席与在场都是决策 |',
      '| ★ **原型里未闭合的 `.row` 能活过一整轮走查** | 第四段那次脚本改写把「开饭前提醒」那一行复制成两句，留下一段没闭合的 `<div class="row">`，后面所有行都被解析器塞进这个空 row 里——当时的走查只数 `.lead-chip` 数量，所以它一直没响。结论：结构类改动要断言**父级是谁**与**有没有空 row**，光数元素数量等于没断言 |',
      '| ★ **走查里 favicon 那条 404 用控制台文本分不出来** | `Failed to load resource: … 404` 这句里**不含 URL**，所以「除 favicon 外没有 404」没法用 `page.on("console")` 判。改用 `page.on("response")` 按 URL 记 404，再单独列一条 favicon 计数 |',
    ];
    const at = find('| ★ **组统计宁可说重，单行说准**', 3);
    guard('新坑每行也都是 2 栏', PIT.every((r) => (r.match(/\|/g) || []).length === 3),
      PIT.map((r) => String((r.match(/\|/g) || []).length)).join('/'));
    lines.splice(at + 1, 0, ...block(PIT));
  }

  guard('⑨ 段进了文档', d.lines.join('\n').includes('⑨ **第六段（同日收口）· 开饭前投待办'));
  guard('「还没做的」不再列 FR-PLAN-09', !d.lines.join('\n').includes('② **FR-PLAN-09 开饭前投待办'));
  save(DOC, d);
}

if (ONLY === 'plan') { /* ══════════════ ② 开发计划书 §22.2 ══════════════ */
  const d = open(PLAN, SNAP_PLAN);
  const { lines, EOL, find } = d;

  const i = find('### R47 · 厨房现场体验 + 提醒基建（P0）');
  guard('标题还写「前五段已落地…本轮未完」', lines[i].includes('本轮未完**'));
  lines[i] = ('### R47 · 厨房现场体验 + 提醒基建（P0） ✅ **六段全部落地（2026-09-30：计时内核 + 两形态 + 本机偏好 + 常亮 + 通知与声音 + 库存到期提醒 + 厨房告警卡 + 开饭前投待办）· 代码收口，欠通知三路的真机验收**') + EOL;

  const j = find('- 设置页一次补齐 FR-SET-01/02/03 三组开关');
  lines[j] = ('- 设置页一次补齐 FR-SET-01/02/03 三组开关（提前量、悬浮窗、震动/声音/语音）——`me_page.dart:22` 自认的「完整设置页 M2+ 再扩」在这一轮收掉。 ✅ **01/02/03 三路全齐（2026-09-30 第六段补上 01）**：悬浮窗 / 震动 / 通知与声音 / **开饭前提醒 + 提前量六档就地内嵌**；`KitchenPrefs` 落 `local_pref` 不同步，翻转当场生效，声音那行只在「通知开着且已授权」时出现。**只剩语音**——按本节最后一条后置。') + EOL;

  const k = find('- **提醒基建是这一轮的副产品**');
  guard('那一bullet 结尾还写着「还没做的」②', lines[k].includes('还没做的」②'));
  lines[k] = lines[k].replace(
    '要做的是「开饭前 N 分钟投一条通知 + 把 FR-SET-01 的开关与提前量档位上 `me_page`（档位就地内嵌）」，见交接文档 §五 R47「还没做的」②。',
    '**第六段已交（2026-09-30）**：`data/meal_reminder.dart` 的 `MealReminderWatch` 把当餐摘要投成一条通知——'
    + '判定「今天 + 定了开饭时间 + 排了菜 + 在 `[开饭−提前量, 开饭)` 窗口里」，一次只投最早那一餐，'
    + '去重键按**餐次**（`YYYY-MM-DD#餐名` 落 `local_pref`）、★ 被闸门挡掉不落戳，通知 id 开新号段 100（库存 1/2、开饭 100、计时器 ≥1000），'
    + '开关用自己的 `mealReminderOn` 不借 `notifyOn`；`me_page` 那行 + 六档 chips 就地内嵌，'
    + '并把「今天会投给谁、投出去多长」如实列在行下（空态与「还没排菜」两态各有用例）。'
    + '原型先行 `proto_meal_r47.cjs` + 走查 33 条全 PASS、`meal_reminder_r47_test` 20 例含四条真重载、`meal_r47_mutation.cjs` 两刀各红一条。'
    + '★ 仍只验到逻辑闸门，真机呈现连 ⑥⑦ 一起走 §六-1。见交接文档 §五 R47 ⑨。') + EOL;

  const m = find('当前实况（**前五段做完后，前半已过时**');
  lines[m] = lines[m].replace('**前五段做完后，前半已过时**', '**六段做完后，前半已过时**') + EOL;

  guard('计划书里不再写「01 与语音仍欠」', !d.lines.join('\n').includes('**01 与语音仍欠**'));
  save(PLAN, d);
}

if (ONLY === 'gap') { /* ══════════════ ③ 盘点表 ══════════════ */
  const d = open(GAP, SNAP_GAP);
  const { lines, EOL, find } = d;

  const i = find('| 提醒基建 |', 4);
  lines[i] = ('| 提醒基建 | FR-SET-01 开饭提醒与提前量、FR-PAN-04 到期推送、FR-PAN-06 首页「即将过期/快没了」卡、FR-PLAN-09 开饭前自动投待办 | ✅ **四条全部交完（2026-09-30 R47 三~六段）**：`flutter_local_notifications` + `TimerAlert` 授权闸门 + `PantryWatch` 推送时机 + 厨房顶部告警卡（FR-PAN-06）+ **开饭前投待办（`MealReminderWatch`：窗口判定、按餐次去重、新号段 id 100、就地六档设置）**；仍**无后台排程**，触发点是打开 App / 回前台（精确闹钟属 M3）。★ 通知三路的**真机呈现**仍欠，别把全绿当验收（详见交接文档 §五 R47 ⑥⑦⑨） |') + EOL;
  guard('盘点「提醒基建」行仍是 3 列', d.cols(lines[i]) === 4, String(d.cols(lines[i])));

  const j = find('| **R47** |', 5);
  lines[j] = ('| **R47** | 厨房现场体验（常亮/通知/多计时器/时间戳内核/四组开关）+ **提醒基建**（顺带解锁 FR-PAN-04/06、FR-PLAN-09、S1 网络恢复即同步）✅ **六段全部落地（2026-09-30）**：时间戳内核 + ≥3 并行 + 悬浮球与全屏 + FR-SET-01/02/03 四路（悬浮窗·震动·通知与声音·**开饭前提醒与提前量**）+ **常亮 FR-COOK-09** + **计时结束通知 FR-COOK-14** + **库存到期提醒 FR-PAN-04 的推送时机** + **厨房顶部告警卡 FR-PAN-06**（落点由用户拍定：厨房 tab 顶部，并整组取代库存头部那四枚计数徽标）+ **开饭前投待办 FR-PLAN-09**（★ 派生不建 `plan_task` 表，所以仍零改列）；**只剩**通知三路（⑥⑦⑨）的**真机呈现**与语音那一路（TTS 后置 R53） | 否 | P0 |') + EOL;
  guard('盘点 R47 行仍是 4 列', d.cols(lines[j]) === 5, String(d.cols(lines[j])));

  save(GAP, d, { allowShrink: true }); // 两行结论改写得更短是预期的
}

console.log('—— 划账完成：交接文档 / 计划书 / 盘点三处都改了，记得跑 node tool/doc_table_lint.cjs');
