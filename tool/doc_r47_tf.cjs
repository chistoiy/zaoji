// R47 第八段划账：把「悬浮球吸边收起 / 占场互斥 / 全屏含通知栏 / 到点振动走通知」写进账本。
//
// 为什么用脚本而不是手改：这份文档 3500+ 行、单行最长 4000+ 字符（§六-20 与 §九 那两行），
// 手改极易撞掉表格行首（记过的坑：Markdown 表格插行会吞掉下一行行首）。
// 所以每一处都带**命中断言**（要求恰好 1 次），任何一处不中就整批不写盘。
//
// 用法：node tool/doc_r47_tf.cjs          （改）
//       node tool/doc_r47_tf.cjs --check  （只校验锚点，不写盘）
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const FILE = path.join(ROOT, '灶记-交接文档.md');
const SNAP = path.join(ROOT, 'dist', 'handover_before_r47_tf.md');
const raw = fs.readFileSync(FILE, 'utf8');
const EOL = raw.includes('\r\n') ? '\r\n' : '\n';
const j = (s) => s.split('\n').map((x) => x.replace(/\r$/, '')).join(EOL);
const bytesBefore = Buffer.byteLength(raw);

const EDITS = [
  {
    name: '§五 R47 标题：七段 → 八段',
    from: '+ 网络恢复即同步（**七段，代码全部收口，欠真机**）',
    to: '+ 网络恢复即同步 + **悬浮球吸边收起 / 占场互斥 / 全屏含通知栏 / 到点振动走通知**（**八段，代码全部收口，形态三件欠真机走查**）',
  },
  {
    name: '§五 边界段：范围与已交清单',
    from: '**先说清楚边界**：R47 的范围（计划书 §22.2 与 §22.3 第 1 条）到第七段**代码全部收口**——',
    to: '**先说清楚边界**：R47 的范围（计划书 §22.2 与 §22.3 第 1 条）到第八段**代码全部收口**——',
  },
  {
    name: '§五 边界段第二行：补第八段交了什么',
    from: '网络恢复即同步（⑩）**；剩下的只有「通知三路（⑥⑦）的真机呈现」',
    to: '网络恢复即同步（⑩）、**第八段交了悬浮球的吸边收起与占场互斥与全屏含通知栏与到点振动（⑪）**；' +
      '剩下的只有「通知三路（⑥⑦）的真机呈现」与**⑪ 那三件形态改动的真机手感**',
  },
  {
    name: '§五 新增 ⑪ 段（第八段全文）',
    from: '**还没做的**（R47 剩下的账，接手从这里接）：',
    to: '⑪ **第八段（同日接上）· 悬浮球两态收口：吸边耳朵 / 占场互斥 / 全屏含通知栏 / 到点振动走通知**。\n' +
      '这一段的四条都来自用户当场提的三句 + 一句追加，全部是**决策**而不是算术，所以每条都有用例钉着：\n' +
      '★ **靠边收起（吸边耳朵）**：拖到左/右任一条边（离边 <40 设计像素）松手 → 吸附 + 收成 26×66 的窄耳朵，' +
      '耳朵只留计时图标与并行时的 `×N`；点耳朵展开回完整球，**仍贴同一条边**（贴哪一边是事实源，不随形态变，' +
      '所以展开不重算坐标、也不弹回默认右下角）。停在中间松手既不吸附也不收起——用户会找不到球。' +
      '口径与原型一致（`tool/proto_fab_r47_walk.cjs` 里 [2]~[5] 那几段就是这四态）。\n' +
      '★ **占场互斥**：`TimerBoard` 新增**按来源分账的占场表**（`occupyScreen(who)/releaseScreen(who)`，' +
      '`Map<String,int>`），悬浮球在 `screenOccupied` 时整条 `OverlayEntry` 不上屏。两个占场方：' +
      '**全屏计时页**（原型从第一版就是「全屏 / 悬浮窗」二选一，实现却把 entry 一直挂着）与' +
      '**计时面板**（★ 这条是测试撞出来的：面板就是球的展开态，球继续浮在上面会把面板里的「全屏/关闭」按钮吃掉，' +
      '414×844 加一条状态栏 padding 必撞）。★ **为什么不共用一个计数**：面板 pop 的 `whenComplete` 会在全屏 push 登记' +
      '**之后**才回调，共用一计就会把全屏那次登记一起减掉（球又冒出来）。\n' +
      '★ **全屏页含通知栏**（用户原话「全屏要包含通知栏的，当前没有」）：`TimerFullPage` 外面套一层' +
      '`ColoredBox(key: timer-full-bg)` 让深色底**从 y=0 铺到底**，再用 `AnnotatedRegion<SystemUiOverlayStyle>` 声明' +
      '状态栏透明 + **浅色图标**（★ 命名坑：Flutter 的 `SystemUiOverlayStyle.light` 指「浅色背景配深色图标」，' +
      '与直觉相反，所以这里逐项写死不用那两个常量）；离开这屏 AnnotatedRegion 自己失效，**不在 dispose 里手动改样式**' +
      '（那种写法迟早漏恢复）。原型同步（铁律：先原型后实现）——`timerFullHTML()` 里画进一条浅色 `.statusbar`，' +
      '走查加三条判据（画了状态栏 / 文字转浅色 / 顶到这一屏最上沿），27 条全 PASS。\n' +
      '★ **到点振动走通知本身**：`AlertNotice` 多一个 `vibrate`（默认 false），`fire(..., vibrate:)` 按每条传，' +
      '`main._onTimersFired` 传 `vibrateOn`；渠道级 `enableVibration` **仍然 false**（否则变成设置里关不掉的震动）。' +
      '为什么非改不可：真机读到 `settings get system haptic_feedback_enabled` = **0**，' +
      '`HapticFeedback.vibrate()` 被系统「触摸反馈」静默吞掉，而渠道那一层一直是 false —— **两头都不振**，' +
      '用户得到的就是「到点既不响也不震」，看起来像功能没做。声音那一路按用户拍板**不引播放库**：' +
      '渠道 importance=5 已经带通知音，要不要响由用户在系统通知设置里改（App 里那枚 `soundOn` 管 `playSound`）。\n' +
      '守卫：`app/test/timer_ball_r47_test.dart` **15 例**（新文件：吸边四态 + 展开仍贴同一条边 + 并行计数 + ' +
      '全屏/面板占场两例 + 含通知栏三例）；`notify_r47_test` +2 例（振动是每条的参数、开关跟着 vibrateOn 走）；' +
      '`meal_reminder_r47_test` / `pantry_expiry_r47_test` 各加一条「别的路不许顺手振」。\n' +
      '反向验证 `tool/r47tf_mutation.cjs` **四刀**（`occupy` / `snap` / `vibrate` / `overlay`）：' +
      '每刀摘掉一条决策 → 对应那一条用例真的红（脚本还断言「红的就是这一条」，防止编译错冒充证据）→ 装回后与快照逐字节一致。\n' +
      '★ 顺手修掉一条**时间炸弹**：`meal_reminder_r47_test` 里两处拿 `DateTime.now().add(6 小时)` 当今天的种子，' +
      '晚上跑就跨到明天，而设置页只列**今天**的餐次 → 表现为「白天绿、晚上红」。现在统一走 `laterToday(lead)`' +
      '（取「now+lead」与「今天 23:59」里较早那个）。\n' +
      '\n' +
      '**还没做的**（R47 剩下的账，接手从这里接）：',
  },
  {
    name: '「还没做的」补 ④：三件形态欠真机手感',
    from: '★ 别与 ⑩ 混为一谈：⑩ 补的是「网络恢复时把攒下的写推上去」，不是「到点没打开 App 也能弹」。',
    to: '★ 别与 ⑩ 混为一谈：⑩ 补的是「网络恢复时把攒下的写推上去」，不是「到点没打开 App 也能弹」。\n' +
      '④ **⑪ 那三件形态改动欠真机走查**：吸边耳朵的手感（阈值 40 设计像素在 2400px 宽的屏上是宽是窄）、' +
      '全屏页在 Android 15 边到边下**通知栏实际是不是浅色**（widget 测的是声明，不是系统真画出来的样子）、' +
      '面板开着时球让位之后回退的手感。这三条测试钉的是几何与声明，只有真机说得上话。' +
      '★ 另外 ⑤ 的振动**只验到「通知带上了振动标记」**——真机上震没震仍要人在场（`haptic_feedback_enabled=0` 那台机器' +
      '连系统触感都关了，通知振动是否被同一开关管住，本轮没读到）。',
  },
  {
    name: '「还没做的」收尾行：六段 → 八段 + 形态要进包得重编',
    from: '**产物/版本号/push 一概没动**；六段全程零 schema 改动，所以不欠「apk+exe 同发」。',
    to: '**产物/版本号/push 一概没动**；八段全程零 schema 改动，所以不欠「apk+exe 同发」。' +
      '★ 但**⑪ 是界面形态改动**：要让真机看到，得重编 apk（0.16.0+14 那份是第八段之前编的，' +
      '里面还是「全屏页压着球 + 到点不震 + 通知栏不接管」的旧行为）。',
  },
  {
    name: '§六-20 行：七段 → 八段 + 基线 449',
    from: '| 20 | **R47 七段已完成（2026-09-30，代码全部收口；欠真机验收）** |',
    to: '| 20 | **R47 八段已完成（2026-09-30，代码全部收口；通知三路真机已过，⑪ 三件形态欠走查）** |',
  },
  {
    name: '§六-20 行：指针 ①~⑩ → ~⑪ + 基线只升',
    from: '的抽法见 §五 R47 ①~⑩，坑在 §7.10。**基线** shared **193**（177→193）· server **320**（未动）· app **432**（329→351→361→377→389→400→420→432）· analyze 三处 0',
    to: '的抽法见 §五 R47 ①~⑪，坑在 §7.10。**第八段（⑪）交了：悬浮球靠边收成耳朵（点耳朵展开仍贴同一条边）+ ' +
      '全屏页与计时面板**占场互斥**（球该让位就让位，否则吃掉面板按钮）+ 全屏页**含通知栏**（深色底顶到 y=0、' +
      '状态栏图标转浅色）+ 到点**振动走通知本身**（`haptic_feedback_enabled=0` 让老路两头都不振）；' +
      '反向验证 `tool/r47tf_mutation.cjs` 四刀各红一条、装回逐字节一致。**基线** shared **193**（177→193）· ' +
      'server **320**（未动）· app **449**（329→351→361→377→389→400→420→432→449）· analyze 三处 0',
  },
  {
    name: '§六-20 行尾：七段 → 八段',
    from: '产物 / 版本号 / push 一概没动，七段全程零改列，不欠「apk + exe 同发」 |',
    to: '产物 / 版本号 / push 一概没动，八段全程零改列，不欠「apk + exe 同发」；★ ⑪ 是形态改动，' +
      '真机要看见得重编 apk |',
  },
  {
    name: '§九 行：基线 432 → 449',
    from: '· app 329→**351**→**361**→**377**→**389**→**400**→**420**→**432** · analyze 三处 0；**没发行**',
    to: '· app 329→**351**→**361**→**377**→**389**→**400**→**420**→**432**→**449** · analyze 三处 0；**没发行**',
  },
  {
    name: '§九 行：追加 ⑬ 第八段',
    from: '仍欠：渠道是否真 audible（要人在场听到）与 Web 在 https 下能否弹。——见 §六-20 |',
    to: '仍欠：渠道是否真 audible（要人在场听到）与 Web 在 https 下能否弹。' +
      '⑬ **第八段（同日接上）· 悬浮球两态收口**（用户三句 + 一句追加）：★ **靠边收起**——拖到左右任一条边（离边 <40 设计像素）' +
      '松手就吸附并收成 26×66 的窄耳朵（只留计时图标与 `×N`），点耳朵展开**仍贴同一条边**（贴哪边是事实源，不随形态变），' +
      '停在中间既不吸附也不收起；★ **占场互斥**——`TimerBoard` 加**按来源分账**的占场表（`occupyScreen(who)`），' +
      '全屏页与**计时面板**开着时球整条不上屏（面板那条是测试撞出来的：球浮在面板上会吃掉「全屏/关闭」按钮），' +
      '★ 不共用一个计数是因为面板 pop 的 `whenComplete` 会晚于全屏登记，共用就会把全屏那次一起减掉；' +
      '★ **全屏页含通知栏**——`ColoredBox` 让深色底从 y=0 铺到底 + `AnnotatedRegion` 声明浅色状态栏图标，' +
      '离屏自动恢复（不在 dispose 里手改样式），原型先画进 `timerFullHTML()` 再动实现（走查 27 条全 PASS）；' +
      '★ **到点振动走通知本身**——`AlertNotice.vibrate` 每条传、跟 `vibrateOn`，渠道 `enableVibration` 仍 false，' +
      '因为真机 `haptic_feedback_enabled=0` 会把 `HapticFeedback.vibrate()` 静默吞掉（两头都不振=用户以为没做），' +
      '声音那一路按拍板不引播放库、交给系统通知设置；`timer_ball_r47_test` **15 例** + notify +2 + 库存/开饭各 1 条「别的路不许振」，' +
      '`tool/r47tf_mutation.cjs` 四刀（occupy/snap/vibrate/overlay）各红一条、装回逐字节一致；★ 顺手修掉一条**时间炸弹**' +
      '（`now+6 小时` 当今天的种子，晚上跑跨天 → 设置页那一行根本不存在）。仍欠 ⑪ 三件形态的真机手感，' +
      '且**这份改动没进 apk**（0.16.0+14 是第八段之前编的）。——见 §六-20 |',
  },
  {
    name: '§7.10 标题：补上第八段',
    from: '### 7.10 R47 新增的坑（计时内核 / 偏好 / 常亮 / 通知 / 到期提醒 / 告警卡 / 投待办 / 网络监听，每条都真红过）',
    to: '### 7.10 R47 新增的坑（计时内核 / 偏好 / 常亮 / 通知 / 到期提醒 / 告警卡 / 投待办 / 网络监听 / 悬浮球两态，每条都真红过）',
  },
];

// §7.10 表格新增行（锚在最后一条数据行的行尾，插在其后）
const TAIL_ROW =
  '★ 记这条是因为它长得像实现 bug——其实是工装与 IME 打架 |';
const NEW_ROWS = [
  '| ★★ **在 `initState` 里通知监听者 = build 期 markNeedsBuild，直接炸** | 全屏页登记"我占场"最直觉的位置就是 `initState`，' +
  '结果悬浮球那层 `ListenableBuilder` 抛「setState() or markNeedsBuild() called during build」（测试当场撞出来）。' +
  '两条一起改：① **登记口收敛到点击回调**（`TimerFullPage.push`），`open` 也委托给它，不给"忘了登记"留旁路；' +
  '② 板子里再加一道 `_notifySafe()`——处在 `persistentCallbacks` 就推到本帧后再通知，并 `scheduleFrame()` 保证真有一帧会来。' +
  '★ 延后通知还要防"那一帧把板子拆了"：postFrame 回调撞上 `TimerBoard.dispose()` 就是 `used after being disposed`，' +
  '所以要带 `_disposed` 双保险（测试收尾那条红就是这么来的） |',
  '| ★ **两处登记同一个计数 = 退出全屏后球再也不回来** | 第一版 `push()` 与 `initState()` 各 `enterFullScreen()` 一次、' +
  '`dispose()` 只减一次 → 深度 +2/-1 永远回不了 0，球被永久隐藏。修法不是"记得配对"，是**只留一个登记口**。' +
  '★ 同类问题在占场表上又出现一次：面板与全屏共用一计时，面板 pop 的 `whenComplete` 在全屏登记之后才回调，' +
  '把全屏那次一起减掉 → 分账（`Map<来源,计数>`）才是对的 |',
  '| ★ **悬浮球会吃掉它下面那个面板的按钮**（不是几何洁癖，是点不到） | 球挂在 navigator root 的 Overlay 上，' +
  '面板是模态路由——两者同层，球的位置（右下角）正好压住面板里每行的「全屏/关闭」。' +
  '★ 之前一直没响是因为用例的屏高 2200 且没有系统栏，两者**刚好错开**；给 `tester.view.padding` 加一条 `bottom:24` 立刻复现' +
  '（`The finder ... could not find any matching widgets` 出现在点「全屏」那一步）。结论：**悬浮物与它自己唤起的界面不能同屏共存** |',
  '| ★ **吸边阈值会跟"只拖一点点"打架**（改判据前先确认逻辑没错） | 阈值 40 设计像素、球宽 146、默认位置离右缘只有 8：' +
  '从贴右展开后往左拖 60，`tester.drag` 里约 20 被 touch slop 吃掉，落点仍在阈值内 → 又被吸回收起，看着像 bug。' +
  '与原型逐字对齐后确认**这是口径**（原型同一条 `x + w >= PW - 40`），于是改用例：拖 150 才算"真的离开边"，' +
  '另开一条从**左**边起拖的用例去验"坐标从当前贴边位置实体化"（右边那条验不出来：默认右下角与贴右只差 8px） |',
  '| ★ **`dart format` 在这个仓库里是破坏性操作** | 顺手格式化了三个文件：`git diff --stat` 从几十行变成 413 行整份重排，' +
  '而且格式把一条 `if (...) 单语句` 拆成两行，**自己引入** `curly_braces_in_flow_control_structures` 告警——' +
  '门禁那条 issue 是工装造的，不是代码的。抽查仓库里没碰过的文件（timer_sheet/home_shell/recipe_store/main）全部 Changed，' +
  '说明这个仓库从来不按 dart format 排版。结论：**改 Dart 用 Edit/带锚脚本，缩进跟着文件走** |',
  '| ★ **脚本按 latin1 回写 UTF-8 大文件 = 把新插入的中文写成非法字节** | 给原型打补丁的脚本读 latin1、写 latin1，' +
  '原有字节确实保真，但**新插入那段中文**在 JS 里是 UTF-16，按 latin1 编码只留低字节 → 落盘成非法 UTF-8。' +
  '症状不在补丁本身，而在**另一个不相干的测试**：`theme_test` 读原型比色值，抛 `Failed to decode data using encoding \'utf-8\'`，' +
  '五套主题一片红，看着像色板漂移。修法：从快照装回原型 + 脚本改 utf8，并加一条"逐字节校验 UTF-8 合法性"的自检 |',
  '| ★ **变异脚本中途不能 `process.exit`** | 第一版在"红的就是这一条"那一步用硬退出，`finally` 没跑，' +
  '源码**留在变异态**（下一轮门禁一片红，先要怀疑工装）。改成：变异过程中的硬校验一律 `throw`，' +
  '外层 `try/catch/finally` 保证装回，判据失败只记账不中断 |',
];

const check = process.argv.includes('--check');
let out = raw;
let bad = 0;
for (const e of EDITS) {
  const from = j(e.from), to = j(e.to);
  const hits = out.split(from).length - 1;
  if (hits !== 1) {
    console.log(`[${e.name}] 命中 ${hits} 次（要求恰好 1）→ FAIL`);
    bad++;
    continue;
  }
  console.log(`[${e.name}] OK`);
  if (!check) out = out.replace(from, to);
}
// 表格行：锚在最后一条数据行之后插
{
  const anchor = j(TAIL_ROW);
  const hits = out.split(anchor).length - 1;
  if (hits !== 1) {
    console.log(`[§7.10 新增 ${NEW_ROWS.length} 行] 锚命中 ${hits} 次 → FAIL`);
    bad++;
  } else {
    console.log(`[§7.10 新增 ${NEW_ROWS.length} 行] OK`);
    if (!check) out = out.replace(anchor, anchor + EOL + NEW_ROWS.map((r) => j(r)).join(EOL));
  }
}
if (bad) {
  console.log(`\n锚点校验失败 ${bad} 处，未写盘。`);
  process.exit(1);
}
if (check) {
  console.log('\n--check：锚点全部命中，未写盘。');
  process.exit(0);
}

const grew = Buffer.byteLength(out) - bytesBefore;
if (grew < 1000) {
  console.log(`体积只变了 ${grew} 字节，不像加了八处内容，未写盘。`);
  process.exit(1);
}
fs.writeFileSync(SNAP, raw, 'utf8');
fs.writeFileSync(FILE, out, 'utf8');
// 插完跑一次表格列数校验（记过的坑：插行会吞掉下一行行首 / 裸竖线打乱列数）
const lines = out.split(EOL);
let rows = 0, wrong = [];
for (let i = 0; i < lines.length; i++) {
  const l = lines[i];
  if (!l.startsWith('| ★') && !l.startsWith('| 20 |') && !l.startsWith('| ⑪')) continue;
  rows++;
  const cells = l.replace(/\\\|/g, '').split('|').length - 2;
  if (l.startsWith('| ★') && cells !== 2) wrong.push(`${i + 1} 行 ${cells} 列`);
}
console.log(`写盘完成：+${grew} bytes；快照 dist/handover_before_r47_tf.md；§7.10 附近数据行 ${rows} 条`);
console.log(wrong.length ? '★ 列数异常：' + wrong.join('；') : '列数校验：新增行都是 2 列');
