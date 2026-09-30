// R47 第五段（厨房告警卡 FR-PAN-06）落地后：改「开发计划书」与「功能查漏补缺」。
// 只做行内片段替换，每处断言命中恰好一次；改前拍快照、改后校验行数不变且只变长。
// 用法：node tool/doc_r47_pantry_card_plan.cjs
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const guard = (label, cond, extra) => {
  if (!cond) { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); process.exit(1); }
  console.log('✔ ' + label);
};

function patch(file, edits) {
  const P = path.join(ROOT, file);
  const SNAP = path.join(ROOT, 'dist', 'r47card_' + file.replace(/[^\w]/g, '_') + '.bak');
  const before = fs.readFileSync(P, 'utf8');
  fs.writeFileSync(SNAP, before);
  let src = before;
  for (const [label, oldSub, newSub] of edits) {
    const n = src.split(oldSub).length - 1;
    guard(file + ' · ' + label, n === 1, 'n=' + n);
    src = src.replace(oldSub, newSub);
    guard(file + ' · ' + label + '（落盘后在）', src.includes(newSub));
  }
  guard(file + ' · 只变长', src.length > before.length, before.length + ' → ' + src.length);
  guard(file + ' · 行数没变（纯行内替换）', src.split('\n').length === before.split('\n').length);
  fs.writeFileSync(P, src);
  console.log('  → 写入 ' + file + '（快照：dist/' + path.basename(SNAP) + '）');
}

/* ——— 开发计划书 ——— */
patch('灶记-开发计划书.md', [
  ['§22.1 落地状态：四→五段',
    '**R47 前四段已完成（2026-09-30，本轮未完）**',
    '**R47 前五段已完成（2026-09-30，本轮未完）**'],
  ['§22.1 落地状态：补第五段与基线',
    ' + **库存到期提醒**，基线 shared 177→**193** · app 329→**389**',
    ' + **库存到期提醒** + **厨房顶部告警卡**，基线 shared 177→**193** · app 329→**400**'],
  ['§22.1 落地状态：剩下的换掉',
    '**剩下的**（通知两路的真机验收、首页过期卡、开饭前投待办）见交接文档 §六-20。',
    '**剩下的**（通知两路的真机验收、开饭前投待办 + FR-SET-01 那枚开关）见交接文档 §六-20——**待办落点已由用户拍定：继续派生、不建 `plan_task` 表**。'],
  ['§22.2 标题',
    '🔶 **前四段已落地（2026-09-30：计时内核 + 两形态 + 本机偏好 + 常亮 + 通知与声音 + 库存到期提醒），本轮未完**',
    '🔶 **前五段已落地（2026-09-30：计时内核 + 两形态 + 本机偏好 + 常亮 + 通知与声音 + 库存到期提醒 + 厨房告警卡），本轮未完**'],
  ['§22.2 实况那句',
    '当前实况（**前四段做完后，前半已过时**',
    '当前实况（**前五段做完后，前半已过时**'],
  ['§22.2 落地段：接第五段 + 基线 + 坑数',
    '（见交接文档 §五 R47 ⑦ 末）。基线 shared 177→193 · app 329→351→361→377→**389** · server 320 未动 · analyze 三处 0，未发行、零改列。细则与 25 颗坑见',
    '（见交接文档 §五 R47 ⑦ 末）。**同日第五段**：**FR-PAN-06 首页卡**——「首页是哪一屏」由用户拍定挂**厨房 tab 顶部**（打开时的触达归通知那一路，卡管「人已在厨房页，一眼看到先处理谁」）。判定与文案不与通知各写一份：`pantry_watch.dart` 抽出 `pantryAlertOf` + `PantryAlert.names` 两处共用；★ 这张卡**整组取代**库存头部那四枚计数徽标（同一屏两份计数=两份要维护的说法），摘之前四个数逐一对齐、含「卡里有但通知不发」的「没有」；三条行为（空数据不渲染 / 去处按钮只在没别的出口的段出现 / 库存一改卡当场跟着变）各有用例；`proto_pantry_card_r47.cjs` 先行 + 走查 37 条全 PASS、`pantry_card_r47_test` 11 例、`pancard_r47_mutation.cjs` 的 `empty`/`button` 各红一条。基线 shared 177→193 · app 329→351→361→377→389→**400** · server 320 未动 · analyze 三处 0，未发行、零改列。细则与 30 颗坑见'],
  ['§22.2 副产品那条：两条已交',
    ' 🔶 **基建通了，三条里第一条已交（2026-09-30 第四段）**：',
    ' ✅ **基建通了，三条里前两条已交（2026-09-30 第四、五段）**：'],
  ['§22.2 副产品那条：FR-PAN-06 已交',
    '★ **FR-PAN-06 首页卡压根不依赖通知**，随时可以单独做，前提是先定「首页」是哪一屏（App 五个标签里没有独立首页）；',
    '**FR-PAN-06 首页卡已交**（用户拍定挂厨房 tab 顶部，见交接文档 §五 R47 ⑧）；'],
  ['§22.2 副产品那条：投待办已拍板',
    'FR-PLAN-09「投待办」要先拍待办落在哪儿（备菜清单是派生不落库，建 `plan_task` 表就是改列轮 = apk 与 exe 必须同发那笔硬账，见 §22.2-R50）——**这是设计决策不是机械活，等用户拍**。',
    'FR-PLAN-09「投待办」**方向已拍（2026-09-30 用户定）：继续派生、不建 `plan_task` 表**——待办不可勾选、不跨设备留痕（与 R23 备菜板同一口径），换来的是**这一条仍然零改列、不欠 apk+exe 同发**；要做的是「开饭前 N 分钟投一条通知 + 把 FR-SET-01 的开关与提前量档位上 `me_page`（档位就地内嵌）」，见交接文档 §五 R47「还没做的」②。'],
]);

/* ——— 功能查漏补缺盘点 ——— */
patch('灶记-功能查漏补缺-2026-09-29.md', [
  ['提醒基建那条的现状',
    '（**2026-09-30 R47 第三、四段补上了**：`flutter_local_notifications` + `TimerAlert` 授权闸门 + `PantryWatch` 推送时机；仍**无后台排程**，触发点是打开 App / 回前台）。',
    '（**2026-09-30 R47 第三~五段补上了**：`flutter_local_notifications` + `TimerAlert` 授权闸门 + `PantryWatch` 推送时机 + 厨房顶部告警卡（FR-PAN-06）；仍**无后台排程**，触发点是打开 App / 回前台）。四条里只剩 FR-SET-01/FR-PLAN-09 那一对。'],
  ['R47 行的状态',
    '🔶 **前四段 2026-09-30 已落地**：',
    '🔶 **前五段 2026-09-30 已落地**：'],
  ['R47 行：补告警卡与还欠',
    '+ **库存到期提醒 FR-PAN-04 的推送时机**；**还欠**首页过期卡、开饭前投待办（后两条卡在「待办落在哪儿」这个决策上）',
    '+ **库存到期提醒 FR-PAN-04 的推送时机** + **厨房顶部告警卡 FR-PAN-06**（落点由用户拍定：厨房 tab 顶部，并整组取代库存头部那四枚计数徽标）；**还欠**开饭前投待办与 FR-SET-01 那枚开关（**待办落点已拍：继续派生、不建 `plan_task` 表**，所以仍零改列）'],
]);

console.log('✔ 全部改完。下一步：node tool/doc_table_lint.cjs');
