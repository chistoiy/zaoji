// R47 第八段划账（第二份）：计划书 + 盘点表。
// 交接文档那份在 tool/doc_r47_tf.cjs（已跑）。这里同样每处带命中断言，不中就整批不写盘。
// 用法：node tool/doc_r47_tf_plan.cjs [--check]
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const EOL = (f) => (fs.readFileSync(f, 'utf8').includes('\r\n') ? '\r\n' : '\n');
const j = (s, eol) => s.split('\n').map((x) => x.replace(/\r$/, '')).join(eol);

const PLAN = path.join(ROOT, '灶记-开发计划书.md');
const GAP = path.join(ROOT, '灶记-功能查漏补缺-2026-09-29.md');

const eighth = '- **★ 第八段（同日接上）· 悬浮球两态收口 + 全屏含通知栏 + 到点振动走通知**：' +
  '四条都来自用户当场提的三句加一句追加，全部是**决策**不是算术。' +
  '① **靠边收起**——拖到左右任一条边（离边 <40 设计像素）松手就吸附并收成 26×66 的窄耳朵（只留计时图标与并行 `×N`），' +
  '点耳朵展开**仍贴同一条边**（贴哪边是事实源，不随形态变），停在中间既不吸附也不收起；' +
  '② **占场互斥**——`TimerBoard` 加**按来源分账**的占场表（`occupyScreen(who)/releaseScreen(who)`），' +
  '全屏页与**计时面板**开着时球整条不上屏；★ 面板那条是测试撞出来的（球浮在面板上会吃掉「全屏/关闭」按钮），' +
  '★ 不共用一个计数是因为面板 pop 的 `whenComplete` 会晚于全屏登记、共用就会把全屏那次一起减掉；' +
  '③ **全屏页含通知栏**（需求原话「全屏要包含通知栏的，当前没有」）——`ColoredBox` 让深色底从 y=0 铺到底 +' +
  ' `AnnotatedRegion<SystemUiOverlayStyle>` 声明状态栏透明与**浅色图标**（★ `SystemUiOverlayStyle.light` 指的是' +
  '「浅色背景配深色图标」，与直觉相反，所以逐项写死不用常量），离屏自动恢复，不在 dispose 里手改样式；' +
  '④ **到点振动走通知本身**——`AlertNotice.vibrate` 每条传、跟着 `vibrateOn`，渠道 `enableVibration` 仍 false，' +
  '因为真机 `haptic_feedback_enabled=0` 会把 `HapticFeedback.vibrate()` 静默吞掉（两头都不振 = 用户以为功能没做）；' +
  '★ 声音那一路按拍板**不引播放库**，渠道 importance=5 已带通知音，要不要响交给系统通知设置。' +
  '原型先行：`timerFullHTML()` 里画进一条浅色 `.statusbar`，走查加到 **27 条**全 PASS；' +
  '守卫 `timer_ball_r47_test` **15 例**（新文件）+ `notify_r47_test` +2 + 库存/开饭各 1 条「别的路不许振」；' +
  '反向验证 `tool/r47tf_mutation.cjs` **四刀**（occupy/snap/vibrate/overlay）各红一条、装回逐字节一致。' +
  '★ 顺手修掉一条**时间炸弹**：`meal_reminder_r47_test` 两处拿 `now + 6 小时` 当今天的种子，晚上跑跨天 → ' +
  '设置页那一行根本不存在（表现为「白天绿、晚上红」）。' +
  '基线 app **432→449**、shared 193、server 320 未动、analyze 三处 0；零改列，' +
  '但**形态改动要进真机得重编 apk**（在包里的 0.16.0+14 是第八段之前编的）。见交接文档 §五 R47 ⑪、§7.10、§六-20。';

const JOBS = [
  {
    file: PLAN,
    edits: [
      {
        name: '计划书：S1 那条后面接第八段',
        from: '三刀各红一条。见交接文档 §五 R47 ⑩。',
        to: '三刀各红一条。见交接文档 §五 R47 ⑩。\n' + eighth,
      },
      {
        name: '计划书：R47 行补上形态两态与通知栏',
        from: '| **R47** | 厨房现场体验 + 提醒基建 | FR-COOK-03/04/05/09/12(可后置)/14、FR-SET-01/02/03、FR-PAN-04/06、FR-PLAN-09、NFR-REL-03 | 否 | L | **P0** |',
        to: '| **R47** | 厨房现场体验 + 提醒基建（★ 八段收口：FR-COOK-03 的"两种形态"补齐为**吸边收起 + 占场互斥 + 全屏含通知栏**） | FR-COOK-03/04/05/09/12(可后置)/14、FR-SET-01/02/03、FR-PAN-04/06、FR-PLAN-09、NFR-REL-03 | 否 | L | **P0** |',
      },
    ],
  },
  {
    file: GAP,
    edits: [
      {
        name: '盘点：R47 行 七段 → 八段',
        from: '✅ **七段全部落地（2026-09-30）**',
        to: '✅ **八段全部落地（2026-09-30）**',
      },
      {
        name: '盘点：R47 行补第八段一句话',
        from: '也收了（`NetWake`：上升沿 + 合并 + 首事件不算恢复） | 否 | P0 |',
        to: '也收了（`NetWake`：上升沿 + 合并 + 首事件不算恢复）；**第八段**收的是**形态这一族的三条决策**——' +
          '悬浮球**靠边收成耳朵**（点耳朵展开仍贴同一条边）、全屏页与计时面板**占场时球必须让位**、' +
          '全屏页**含通知栏**（深色底顶到 y=0 + 浅色状态栏图标），外加**到点振动改走通知本身**' +
          '（真机 `haptic_feedback_enabled=0` 让老路两头都不振）。app 基线 **449**，零改列。 | 否 | P0 |',
      },
      {
        name: '盘点：缺口 1（厨房现场体验整组）标注已收口',
        from: '`me_page.dart:22-24` 自认「完整设置页 FR-SET-01~09 等 M2+」 |',
        to: '`me_page.dart:22-24` 自认「完整设置页 FR-SET-01~09 等 M2+」 **[2026-09-30 R47 八段收口：插件已引两个、' +
          '计时改成目标戳 + ≥3 并行 + 悬浮球（可吸边收起）与全屏两态且两者占场互斥、四组开关齐、通知三路真机已过；' +
          '只剩 TTS 后置 R53 与后台准点投递（M3）]** |',
      },
    ],
  },
];

const check = process.argv.includes('--check');
let bad = 0;
const staged = [];
for (const job of JOBS) {
  const eol = EOL(job.file);
  let text = fs.readFileSync(job.file, 'utf8');
  const bytesBefore = Buffer.byteLength(text);
  for (const e of job.edits) {
    const from = j(e.from, eol);
    const hits = text.split(from).length - 1;
    if (hits !== 1) {
      console.log(`[${e.name}] 命中 ${hits} 次 → FAIL`);
      bad++;
      continue;
    }
    console.log(`[${e.name}] OK`);
    text = text.replace(from, j(e.to, eol));
  }
  const grew = Buffer.byteLength(text) - bytesBefore;
  if (!check && grew < 200) {
    console.log(`[${path.basename(job.file)}] 体积只变 ${grew} 字节，可疑，跳过写盘`);
    bad++;
    continue;
  }
  staged.push([job.file, text, grew]);
}
if (bad) {
  console.log(`\n锚点校验失败 ${bad} 处，未写盘。`);
  process.exit(1);
}
if (check) {
  console.log('\n--check：锚点全部命中，未写盘。');
  process.exit(0);
}
for (const [f, text, grew] of staged) {
  fs.writeFileSync(f + '.bak_r47tf', fs.readFileSync(f), 'utf8');
  fs.writeFileSync(f, text, 'utf8');
  console.log(`写盘 ${path.basename(f)}：+${grew} bytes（备份 .bak_r47tf）`);
}
