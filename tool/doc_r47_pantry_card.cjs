// R47 第五段（厨房 tab 顶部库存告警卡 · FR-PAN-06）落地后的划账：改交接文档。
// 与 doc_r47_pantry.cjs 同一套写法：整行/整块替换 + 命中断言 + 列数校验 + 快照 + 只变长。
// 用法：node tool/doc_r47_pantry_card.cjs
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DOC = path.join(ROOT, '灶记-交接文档.md');
const SNAP = path.join(ROOT, 'dist', 'handover_before_r47_pantry_card.md');

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
  guard('锚唯一：' + prefix.slice(0, 30), hits.length === 1, 'n=' + hits.length);
  const i = hits[0][1];
  if (wantCols !== undefined) guard('列数 ' + prefix.slice(0, 18), cols(lines[i]) === wantCols, cols(lines[i]));
  return i;
};
const block = (arr) => arr.map((l) => l + EOL);

/* ——— ① 标题 / 边界 / 基线 ——— */
{
  const i = find('### R47 · 2026-09-30 ·');
  lines[i] = '### R47 · 2026-09-30 · 计时内核 deadline 化 + 多计时器并行 + 悬浮球/全屏两形态 + 本机偏好 + 屏幕常亮 + 计时结束通知 + 库存到期提醒 + 厨房告警卡（**前五段，本轮未完**）' + EOL;

  const j = find('**先说清楚边界**');
  guard('第二行是「前四段交了计时」', lines[j + 1].startsWith('**前四段交了计时'));
  lines.splice(j, 2, ...block([
    '**先说清楚边界**：R47 的范围（计划书 §22.2）只剩「开饭前投待办 + 它的设置页开关」与通知两路的真机验收没做——',
    '**前五段交了计时（①~④）、偏好（③⑤⑥⑧）与常亮（⑤）、计时结束通知与声音（⑥）、库存到期提醒（⑦）、厨房顶部告警卡（⑧）**，其余写在下面「还没做的」里，别把这一节当整轮划掉。',
  ]));

  const k = find('**基线**：shared **193**（177→193）· server 320（未动）· app 329 → **351**');
  guard('第二行以「→ **361**（第二段」开头', lines[k + 1].startsWith('→ **361**（第二段'));
  lines[k + 1] = lines[k + 1].replace(
    '新增 12）· analyze 三处全 0。',
    '新增 12）→ **400**（第五段：`pantry_card_r47_test` 新增 11）· analyze 三处全 0。') + '';
  guard('基线那句写了 400', lines[k + 1].includes('**400**（第五段'));
}

/* ——— ② 新增 ⑧ 段 + 「还没做的」整块重写 ——— */
{
  const i = find('**还没做的**（R47 剩下的账，接手从这里接）：');
  let end = -1;
  for (let j = i; j < lines.length; j++) {
    if (lines[j].startsWith('**产物/版本号/push 一概没动**')) { end = j; break; }
  }
  guard('「还没做的」块找得到结尾行', end > i, 'end=' + end);

  const NEW8 = [
    '⑧ **第五段（同日接上）· 厨房 tab 顶部的库存告警卡（FR-PAN-06）**。',
    '「首页是哪一屏」这条卡在产品决策上，用户拍的落点是**厨房 tab 顶部**（不是菜谱那屏）——',
    '理由值得记下来：打开 App 时的触达已经归 ⑦ 的通知那一路，这张卡管的是「人已经在厨房页了，一眼看到该先处理谁」，',
    '域一致、零新增导航。判定与文案口径**不与卡片各写一份**：`pantry_watch.dart` 里抽出 `pantryAlertOf(items, now)` 与',
    '`PantryAlert.names()`，通知与卡片吃同一个纯函数（两处各写一遍过滤条件，过两天必然漂成两种说法——R28 那组头部徽标已经是第三种说法了）。',
    '★ **这张卡顺手把库存头部那四枚计数徽标整组取代了**（已过期 / 快到期 / 快没了 / 没有）：同一屏两份计数就是两份要维护的说法。',
    '摘之前按「去重要查场景覆盖」逐个数对过——四个数卡里都在，包括**卡里有、通知里没有**的「没有」（家里没有不是紧急事件，不该吵人，但你得看得见）。',
    '卡的行为口径三条，各有用例钉着：① **四组全空 → 整卡不渲染**（FR-PAN-06 的验收判据就是「有数据时出现」）；',
    '② 「按库存找菜」那颗去处按钮**只在没有别的出口的段上出现**（「能做什么」段本身就在目的地，点了没反应的按钮不放）；',
    '③ 数据是实况不是照片——库存一改（新增过期项、把过期项改成远日期）卡当场跟着变，不用重进页面。',
    '★ 用词统一：组统计一律「已过期」（`expState == \'bad\'` 含今天与更早，成组时宁可说重不说轻），',
    '单行分得清就说准话（到期日正好今天 → 「今天到期」，更早 → 「已过期」）；卡片、头部、通知三处同一个词。',
    '原型先行（铁律）：`tool/proto_pantry_card_r47.cjs` 把卡做进 `pantryWatchCard(cur)` 并挂到三个厨房子段顶部，',
    '同时摘掉库存段头部那三枚徽标与一句教学文案（「有 N 样快过期了，点下面的…」——卡本身就是那个提示加那个去处，UI 只留功能标签）；',
    '走查 `tool/proto_pantry_card_r47_walk.cjs`（**37 条**）全 PASS，期望值一律从 `window.__zaoji.PANTRY` **现算**（不从 DOM 反推 DOM）。',
    '守卫：`app/test/pantry_card_r47_test.dart` **11 例**；反向验证 `tool/pancard_r47_mutation.cjs` 两次——',
    '`empty`（摘掉「有数据才出现」）→ ★「没数据：整卡不出现」红；`button`（摘掉「已在目的地就不给按钮」）→ ★「去处按钮」那条红；',
    '`restore` 装回后 11 例重新全绿（改完核对过与快照逐字节一致）。',
    '',
  ];
  const TODO = [
    '**还没做的**（R47 剩下的账，接手从这里接）：',
    '① **通知的真机验收（两路一起）**：计时到点（⑥）与库存到期（⑦）的逻辑、闸门、清单都落地了，',
    '但「系统弹框长什么样、渠道真的出声、Web 在 https 下能弹」这三件事只能在真机上看（Android 13+ 与浏览器都要在用户手势里授权）。',
    '**别把 16 例 + 12 例全绿读成「通知已验收」。**',
    '② **FR-PLAN-09 开饭前投待办 + FR-SET-01 那枚开关**：方向用户已拍——**继续派生、不建 `plan_task` 表**',
    '（待办不可勾选、不跨设备留痕，与 R23 备菜板同一口径；建表是改列轮，会触发「apk 与 exe 必须同发」那笔硬账）。',
    '要做的是：开饭前 N 分钟（`KitchenPrefs.mealLeadMinutes` 字段早就在，只是没有 UI 也没有行为）在 App 处于前台时，',
    '把当餐菜单的备菜与制作步骤摘要投成一条通知（复用 `TimerAlert.send` 那道授权闸门 + 与 ⑦ 同一套当日去重戳口径，通知 id 用**新号段**别与 1/2 和计时器撞）；',
    '同时把 FR-SET-01 的开关与提前量档位上进 `me_page`（档位就地内嵌，禁两段式弹层）。',
    '③ **FR-SET-03 的语音那一路**（TTS，FR-COOK-12/13）按计划书后置到 R53 之后，不卡这一轮。',
    '**产物/版本号/push 一概没动**；前五段零 schema 改动，所以不欠「apk+exe 同发」——② 按「派生不开表」拍板后**仍然不欠**。',
  ];
  lines.splice(i, end - i + 1, ...block(NEW8.concat(TODO)));
}

/* ——— ③ §六-20 整行重写 ——— */
{
  const i = find('| 20 | **R47 前四段已完成', 4);
  lines[i] = ('| 20 | **R47 前五段已完成（2026-09-30，本轮未完）** | ✅ **计时内核 deadline 化 + 多计时器并行 + 悬浮球与全屏两形态 + `KitchenPrefs` 本机偏好 + 屏幕常亮 + 计时结束通知与声音 + 库存到期提醒 + 厨房顶部告警卡**（FR-COOK-03/04/05/**09**/**14**、**FR-PAN-04 的推送时机**、**FR-PAN-06**、FR-SET-02、FR-SET-03 的震动与声音两路、NFR-REL-03）：细节、反漂移证据、引用计数、授权态、通知号段与「一份口径」的抽法见 §五 R47 ①~⑧，坑在 §7.10。**基线** shared **193**（177→193）· server 320（未动）· app **400**（329→351→361→377→389→400）· analyze 三处 0 · 原型走查全绿（timers 32 / prefs 17 / notify 22 / expiry 17 / 告警卡 33 / nutrition 40）。★ **通知两路本机只验到逻辑闸门，没验到真机呈现**：系统弹框、渠道实际出声、Web 在 https 下能否弹，都要连 §六-1 的真机清单一起走，别把全绿当验收。**还欠两条**：① 上面那句真机验收（要设备时段）；② **FR-PLAN-09 开饭前投待办 + FR-SET-01 那枚开关**——方向已由用户拍定：**继续派生、不建 `plan_task` 表**（所以仍然零改列、不欠 apk+exe 同发），细则与落点写在 §五 R47「还没做的」②。产物 / 版本号 / push 一概没动 |') + EOL;
  guard('§六-20 新行仍是 3 列', cols(lines[i]) === 4, cols(lines[i]));
}

/* ——— ④ §九 R47 行：插 ⑧、基线加 400、结尾改口 ——— */
{
  const i = find('| R47 | 2026-09-30 |', 4);
  let row = lines[i].replace(/\r$/, '');
  guard('行首写「前四段」', row.includes('（前四段，本轮未完）'));
  row = row.replace('（前四段，本轮未完）', '（前五段，本轮未完）');
  guard('有 ⑧ 基线那段', row.split('⑧ **基线**').length - 1 === 1);
  const NEW8ROW = '⑧ **厨房顶部告警卡（FR-PAN-06）**：落点由用户拍——挂**厨房 tab 顶部**（打开时的触达归 ⑦ 的通知，这张卡管「人已在厨房页，一眼看到先处理谁」）；判定与文案**不与通知各写一份**，`pantry_watch.dart` 抽出 `pantryAlertOf` + `PantryAlert.names` 给两处共用；★ 这张卡**整组取代**了库存头部那四枚计数徽标（同一屏两份计数=两份要维护的说法），摘之前按「去重先查覆盖」逐个数对齐，含**卡里有、通知里没有**的「没有」；三条行为各有用例：四组全空不渲染（FR-PAN-06 验收判据）、「按库存找菜」只在没别的出口的段出现（在目的地不放假按钮）、库存一改卡当场跟着改；用词统一（组统计一律「已过期」，单行分得清说「今天到期」）；`proto_pantry_card_r47.cjs` 先行 + 走查 37 条全 PASS（期望从 `__zaoji.PANTRY` 现算）、`pantry_card_r47_test` **11 例**、`pancard_r47_mutation.cjs` 的 `empty`/`button` 各红一条。';
  row = row.replace('⑧ **基线**', NEW8ROW + '⑨ **基线**');
  guard('基线那项里有 389', row.includes('app 329→**351**→**361**→**377**→**389**'));
  row = row.replace('app 329→**351**→**361**→**377**→**389**', 'app 329→**351**→**361**→**377**→**389**→**400**');
  guard('结尾「本轮未完」那句换掉', row.includes('**本轮未完**：通知两路的**真机验收**'));
  row = row.replace(
    '**本轮未完**：通知两路的**真机验收**、首页卡（FR-PAN-06，这张卡挂哪一屏要拍）与开饭前投待办（FR-PLAN-09，先拍待办落哪儿）——见 §六-20',
    '**本轮未完**：通知两路的**真机验收**（要设备时段）与**开饭前投待办 + FR-SET-01 开关**（FR-PLAN-09；落点已拍：**继续派生、不建 `plan_task` 表**，所以仍零改列）——见 §六-20');
  guard('改后仍是 3 列', (row.match(/\|/g) || []).length === 4, (row.match(/\|/g) || []).length);
  lines[i] = row + EOL;
}

/* ——— ⑤ §7.10 标题与追加坑 ——— */
{
  const i = find('### 7.10 R47 新增的坑');
  lines[i] = '### 7.10 R47 新增的坑（计时内核 / 偏好 / 常亮 / 通知 / 到期提醒 / 告警卡，每条都真红过）' + EOL;

  const PIT = [
    '| ★ **加摘要控件之前先查它让谁下岗**（反向的去重） | 厨房告警卡上线时，库存头部那四枚计数徽标（已过期/快到期/快没了/没有）就成了同一屏第二份计数。摘掉的条件是**四个数在新位置一个不少**——包括「没有」：它不发通知（家里没有不是紧急事件），但徽标一直在给它留位置。去重从来不只是"删重复"，也是"搬家别丢东西" |',
    '| ★ **卡片与通知共用一份口径，靠的是抽纯函数而不是抄文案** | `pantryAlertOf(items, now)` + `PantryAlert.names()` 一次实现两处吃（卡渲染、通知正文），并有一条用例直接断言「卡里那串名字 == 通知 body」。以前这类"同一句话写两遍"是漂的温床：R28 的头部徽标、⑦ 的通知标题、这轮的卡，三处三种说法 |',
    '| ★ **「有数据才出现」与「已在目的地就不给按钮」都是决策，不是算术** | 所以反向验证专挑这两刀：`pancard_r47_mutation.cjs empty` 摘掉空判定 → 「没数据：整卡不出现」红；`button` 摘掉段判定 → 「去处按钮」那条红。**别只摘算术**——摘算术谁都会红，摘决策才验得到口径 |',
    '| ★ **走查工装的期望要从数据现算，且必须在导航之后取** | 本轮同一类坑撞两次：① 在 `page.goto` 之前就 `evaluate` 读 `window.__zaoji`，页面还是空的，报 `Cannot read properties of undefined`；② 上一段结束时人在另一个子段，却拿本段的 DOM 断言（`.pan-item` 数量为 0 被读成"实现误伤了列表"）。**从 DOM 反推 DOM 是假绿，跨段读 DOM 是假红** |',
    '| ★ **组统计宁可说重，单行说准** | `expState == \'bad\'` 含"今天到期"与"更早"。成组时一律写「已过期」（说轻了会让人以为还能放一放），单行分得清就写「今天到期」。这类口径要一次定到词，否则卡片、徽标、通知三处各写各的，用户读到的是三个东西 |',
  ];
  const at = find('| ★ **flutter_test / drift 的两条 API 落差**（工装级）', 3);
  guard('新坑每行也都 2 栏', PIT.every((r) => (r.match(/\|/g) || []).length === 3), PIT.map((r) => (r.match(/\|/g) || []).length).join('/'));
  lines.splice(at + 1, 0, ...block(PIT));
}

const after = lines.join('\n');
guard('⑧ 段进了文档', after.includes('⑧ **第五段（同日接上）· 厨房 tab 顶部的库存告警卡'));
guard('基线写了 400', after.includes('**400**（第五段：`pantry_card_r47_test` 新增 11）'));
guard('§六-20 升到「前五段已完成」', after.includes('| 20 | **R47 前五段已完成'));
guard('§九 那行有 ⑧ 厨房顶部告警卡', (after.match(/⑧ \*\*厨房顶部告警卡/g) || []).length === 1);
guard('§六-20 不再写「还欠三条」', !after.includes('**还欠三条**'));
guard('没有以空格开头的悬挂续行', after.split('\n').filter((l) => l.startsWith(' |')).length === 0);
guard('行数只增不减', after.split('\n').length > before.split('\n').length, before.split('\n').length + ' → ' + after.split('\n').length);
guard('文件只变长', after.length > before.length, before.length + ' → ' + after.length);

fs.writeFileSync(DOC, after);
console.log('✔ 已写入 ' + path.relative(ROOT, DOC) + '（快照：' + path.relative(ROOT, SNAP) + '）');
