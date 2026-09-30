// R47 第四段（库存到期提醒）落地后：改「开发计划书」与「功能查漏补缺」两份文档的状态行。
//
// 只做**行内片段替换**（这两份要改的都是整段长行，不做跨行插桩），每处断言命中恰好一次。
// 用法：node tool/doc_r47_pantry_plan.cjs
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const guard = (label, cond, extra) => {
  if (!cond) { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); process.exit(1); }
  console.log('✔ ' + label);
};

function patch(file, edits) {
  const P = path.join(ROOT, file);
  const SNAP = path.join(ROOT, 'dist', 'r47pantry_' + file.replace(/[^\w]/g, '_') + '.bak');
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
  ['§22.1 落地状态：三→四段',
    '**R47 前三段已完成（2026-09-30，本轮未完）**',
    '**R47 前四段已完成（2026-09-30，本轮未完）**'],
  ['§22.1 落地状态：补第四段与基线',
    ' + **计时结束通知与声音**，基线 shared 177→**193** · app 329→**377**',
    ' + **计时结束通知与声音** + **库存到期提醒**，基线 shared 177→**193** · app 329→**389**'],
  ['§22.1 落地状态：剩下的三条换掉',
    '**剩下的**（到期提醒的推送时机、首页过期卡、开饭前投待办）见交接文档 §六-20。★ 通知这一路**只验到逻辑闸门，真机呈现欠着**。',
    '**剩下的**（通知两路的真机验收、首页过期卡、开饭前投待办）见交接文档 §六-20。★ 通知这两路（计时到点与库存到期）都**只验到逻辑闸门，真机呈现欠着**。'],
  ['§22.2 标题',
    '🔶 **前三段已落地（2026-09-30：计时内核 + 两形态 + 本机偏好 + 常亮 + 通知与声音），本轮未完**',
    '🔶 **前四段已落地（2026-09-30：计时内核 + 两形态 + 本机偏好 + 常亮 + 通知与声音 + 库存到期提醒），本轮未完**'],
  ['§22.2 实况那句',
    '当前实况（**前三段做完后，前半已过时**',
    '当前实况（**前四段做完后，前半已过时**'],
  ['§22.2 文件头自认那句',
    '（这一轮收掉，只有通知栏/常亮还欠）',
    '（这一轮收掉；通知栏与常亮的**逻辑与清单**都齐了，欠的是真机呈现）'],
  ['§22.2 落地段：接第四段 + 基线 + 坑数',
    '（见交接文档 §五 R47 ⑥ 末）。基线 shared 177→193 · app 329→351→361→**377** · server 320 未动 · analyze 三处 0，未发行、零改列。细则与 19 颗坑见',
    '（见交接文档 §五 R47 ⑥ 末）。**同日第四段**：第一条尾巴上的 **FR-PAN-04 到期提醒的推送时机**做完逻辑（`data/pantry_watch.dart` 挂在「打开 App / 回前台」这一次判定上，★ 刻意不做后台定时；过期与临期**聚合成最多两条**、通知 id 用号段与计时器分开、★ 独立开关 `expiryNotifyOn`、★ 被闸门挡掉不落当日戳；`pantry_expiry_r47_test` 12 例含两条真重载 + `stamp`/`dedupe` 两次变异各红一条；原型先行、走查全 PASS）——★ 同样**只验到逻辑，横幅呈现要真机**（见交接文档 §五 R47 ⑦ 末）。基线 shared 177→193 · app 329→351→361→377→**389** · server 320 未动 · analyze 三处 0，未发行、零改列。细则与 25 颗坑见'],
  ['§22.2 副产品那条：状态改口',
    ' 🔶 **基建通了，三条没交**：',
    ' 🔶 **基建通了，三条里第一条已交（2026-09-30 第四段）**：'],
  ['§22.2 副产品那条：FR-PAN-04 写实',
    'FR-PAN-04 到期提醒差的只是「把临期/过期库存挂上同一渠道 + 一套不与计时器撞的通知 id 规则」；',
    '**FR-PAN-04 到期提醒已交**：`PantryWatch` 把过期/临期挂上同一条渠道（授权闸门共用），通知 id 号段分界（库存 1/2、计时器一律 1000 以上），当日去重戳落 `local_pref`，静音走**独立的** `expiryNotifyOn`——见交接文档 §五 R47 ⑦；'],
]);

/* ——— 功能查漏补缺盘点 ——— */
patch('灶记-功能查漏补缺-2026-09-29.md', [
  ['提醒基建那条的现状',
    '**一条前置卡四条**：没有任何通知调度基建（无插件、无排程）。',
    '**一条前置卡四条**：~~没有任何通知调度基建~~（**2026-09-30 R47 第三、四段补上了**：`flutter_local_notifications` + `TimerAlert` 授权闸门 + `PantryWatch` 推送时机；仍**无后台排程**，触发点是打开 App / 回前台）。'],
  ['R47 行的状态',
    '🔶 **前三段 2026-09-30 已落地**：',
    '🔶 **前四段 2026-09-30 已落地**：'],
  ['R47 行：补库存到期',
    '+ **计时结束通知 FR-COOK-14**；**还欠**到期提醒的推送时机、首页过期卡、开饭前投待办',
    '+ **计时结束通知 FR-COOK-14** + **库存到期提醒 FR-PAN-04 的推送时机**；**还欠**首页过期卡、开饭前投待办'],
]);

console.log('全部改完。下一步：node tool/doc_table_lint.cjs');
