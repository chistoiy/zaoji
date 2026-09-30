// R47 第八段**补正**划账：「全屏要包含通知栏」我第一轮理解错了。
// 装机截图后用户补的那句「顶部还是没有全屏」才是判据：要的是**把通知栏盖掉**（immersive），
// 不是"铺到它底下 + 换浅色图标"。这份脚本改的是账本，不是代码（代码已改并验过）。
// 用法：node tool/doc_r47_tf2.cjs [--check]
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const HAND = path.join(ROOT, '灶记-交接文档.md');
const PLAN = path.join(ROOT, '灶记-开发计划书.md');
const GAP = path.join(ROOT, '灶记-功能查漏补缺-2026-09-29.md');

const OLD_PARA =
  '★ **全屏页含通知栏**（用户原话「全屏要包含通知栏的，当前没有」）：`TimerFullPage` 外面套一层' +
  '`ColoredBox(key: timer-full-bg)` 让深色底**从 y=0 铺到底**，再用 `AnnotatedRegion<SystemUiOverlayStyle>` 声明状态栏透明 + **浅色图标**' +
  '（★ 读源码核对过：`SystemUiOverlayStyle.light` / `.dark` 的名字指的是**图标**颜色，不是背景色——' +
  '`system_chrome.dart:316` 的 `light` 里就是 `statusBarIconBrightness: Brightness.light`，' +
  '而 `material/app.dart:1003` 给深色主题推的正是 `.light`。这个命名历史上翻转过，谁记错谁调反，所以逐项写死、不借那两个常量）；' +
  '★ 退出这屏**必须自己显式推回**「深色图标 + 透明栏」那一记——`RenderView._updateSystemChrome` 读不到注解时是直接 `return`（不还原），' +
  '而 `MaterialApp._themeBuilder` 那个第二写家兜底用的是**实心黑导航栏**的默认样式，冒充不了我们这份；' +
  '用例因此断"推给系统的调用记录"而不是 `SystemChrome.latestStyle`（详见 §7.10 最后一条）。' +
  '原型同步（铁律：先原型后实现）——`timerFullHTML()` 里画进一条浅色 `.statusbar`，走查加三条判据（画了状态栏 / 文字转浅色 / 顶到这一屏最上沿），27 条全 PASS。';

const NEW_PARA =
  '★ **全屏页盖掉通知栏**（需求走了两轮：先「全屏要包含通知栏的，当前没有」，装机后又补一句「顶部还是没有全屏」——' +
  '**第二句才是判据**：要的是这一屏**没有**那条栏，不是"铺到它底下、图标换浅色"）。' +
  '`TimerFullPage.push` 里 `SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky)` 把状态栏与导航栏**整条收掉**，' +
  '`dispose` 里设回 `edgeToEdge`（★ 框架同样不会替我们还原**模式**——少这一记就是"退出全屏之后别的页也没有状态栏"）。' +
  '选 `immersiveSticky` 而不是 `immersive`：灶台上不该因为手划一下就把栏常驻回来，还顺手吃掉那次滑动手势。' +
  '上一版那两件（`ColoredBox(key: timer-full-bg)` 深色底顶到 y=0、`AnnotatedRegion` 浅色图标）**保留但换了角色**：' +
  'sticky 允许用户从边缘把栏短暂划回来，那一刻的配色由它们兜。' +
  '★ 三条读框架源码读出来的账（都是"看着该自动恢复，其实不会"）：' +
  '① `SystemUiOverlayStyle.light` / `.dark` 的名字指的是**图标**色不是背景色（`services/system_chrome.dart:316`），' +
  '命名历史上翻转过，所以逐项写死、不借常量；' +
  '② `RenderView._updateSystemChrome` 在读不到任何注解时是**直接 return**，不还原样式（`rendering/view.dart:445`）；' +
  '③ 这个 App 里还有**第二个写家** `MaterialApp._themeBuilder`（`material/app.dart:1003`），每次构建按主题推一记默认样式，' +
  '而那份的导航栏是**实心黑**——所以退出这屏要显式推我们那记「深色图标 + 透明栏」，' +
  '用例断的是**推给系统的调用记录**而不是 `SystemChrome.latestStyle`（比最终值测到的是"谁最后写"的竞态，' +
  '第一版就是这么假绿的：摘掉收尾代码测试照样绿）。' +
  '原型同步（铁律：先原型后实现）：`timerFullHTML()` **撤掉**上一轮画进去的那条 `.statusbar`（真全屏就不该有它），' +
  '走查判据跟着翻成「屏内没有 `.statusbar` 节点」+「深色底顶到手机框最上沿且铺满整屏」，27 条全 PASS。';

const OLD_TODO =
  '④ **⑪ 那三件形态改动欠真机走查**：吸边耳朵的手感（阈值 40 设计像素在 2400px 宽的屏上是宽是窄）、' +
  '全屏页在 Android 15 边到边下**通知栏实际是不是浅色**（widget 测的是声明，不是系统真画出来的样子）、' +
  '面板开着时球让位之后回退的手感。这三条测试钉的是几何与声明，只有真机说得上话。';

const NEW_TODO =
  '④ ~~⑪ 那三件形态改动欠真机走查~~ ✅ **[2026-10-01 已过，Xiaomi 14 / HyperOS OS3.0.306 / release 0.16.0+15，' +
  '截图留档 `dist/r47tf_device/01..09`](§五 R47 ⑪ 末)**：起表后拖到左缘松手 → 收成贴边耳朵（`08_ear_left`）、' +
  '点耳朵展开**仍贴左缘**且读数一路没断（`09_expanded_left` 00:24）；面板开着时球**确实不在屏上**（`05_panel`）；' +
  '进全屏**状态栏与导航栏整条没了**（`06_full`，targetSdk 36 上 immersiveSticky 仍然生效，这条之前不确定）；' +
  '退出全屏状态栏回来、球回右下角（`07_back`）。★ 顺带结掉一条旧不确定：`0.16.0+14` 那份 apk 里"全屏页压着球"的旧行为已被 +15 覆盖。';

const OLD_TAIL =
  '**产物/版本号/push 一概没动**；八段全程零 schema 改动，所以不欠「apk+exe 同发」。' +
  '★ 但**⑪ 是界面形态改动**：要让真机看到，得重编 apk（0.16.0+14 那份是第八段之前编的，' +
  '里面还是「全屏页压着球 + 到点不震 + 通知栏不接管」的旧行为）。';

const NEW_TAIL =
  '八段全程零 schema 改动，所以不欠「apk+exe 同发」。' +
  '**[2026-10-01 补正后已收口]**：形态三件 + 「盖掉通知栏」这条补正一起提交并推双远端（`5de707f` 与其后一笔），' +
  '版本号按上轮定的走法提到 **0.16.0+15**（pubspec 与 `android/local.properties` 一起核过），' +
  '重编 arm64 apk（32.57 MB）→ `verify_apk.ps1` arm64 四件全 OK、装机 `versionCode=2015 targetSdk=36` 实读对上。' +
  '★ 一条诚实记录：**上一轮我报过"已提到 +15"，其实当时没提**（装的还是 +14），这次是真的；' +
  '`verify_apk.ps1` 整体仍判 FAIL——那是 v7a 还是 9-29 的旧包（versionCode 1013），要发版得先把 v7a 重编。';

const NEW_ROW =
  '| ★★ **用户说的「全屏」是"没有状态栏"，不是"铺到状态栏底下"**（需求两轮才收敛） | ' +
  '第一轮按字面做成"深色底顶到 y=0 + 状态栏图标转浅色"，装机截图用户回一句「顶部还是没有全屏」才对：' +
  '要的是 `immersiveSticky` 把栏**收掉**。教训两条：① 涉及"全屏 / 沉浸 / 通栏"这类**边界词**，' +
  '先在真机上截一张图对着看，别在桌面脑补语义；② 原型是判据——真全屏那一屏**不该画状态栏**，' +
  '上一轮我还往 `timerFullHTML()` 里画了一条进去（把误解写进了设计稿），这次撤掉并把走查判据翻成「屏内没有 `.statusbar`」 |';

const JOBS = [
  {
    file: HAND,
    edits: [
      { name: '§五 ⑪ 含通知栏段 → 盖掉通知栏段', from: OLD_PARA, to: NEW_PARA },
      {
        name: '§五 ⑪ 反向验证：五刀 → 七刀',
        from: '反向验证 `tool/r47tf_mutation.cjs` **五刀**（`occupy` / `snap` / `vibrate` / `overlay` / `noRestore`）：',
        to: '反向验证 `tool/r47tf_mutation.cjs` **七刀**（`occupy` / `snap` / `vibrate` / `overlay` / `noRestore` / `immersive` / `immersiveRestore`）：',
      },
      { name: '「还没做的」④ → 真机已过', from: OLD_TODO, to: NEW_TODO },
      { name: '「还没做的」收尾：产物/版本号/push', from: OLD_TAIL, to: NEW_TAIL },
      { name: '§六-20 行头：⑪ 欠走查 → 已过', from: '通知三路真机已过，⑪ 三件形态欠走查）** |', to: '通知三路真机已过，⑪ 形态三件 + 全屏盖栏也已过真机）** |' },
      { name: '§六-20 含通知栏 → 盖掉通知栏', from: '全屏页**含通知栏**（深色底顶到 y=0、状态栏图标转浅色）', to: '全屏页**盖掉通知栏**（`immersiveSticky`；深色底顶到 y=0 与浅色图标退为"栏被划回来那一刻"的兜底）' },
      { name: '§六-20 五刀 → 七刀', from: '反向验证 `tool/r47tf_mutation.cjs` 五刀各红一条、装回逐字节一致。', to: '反向验证 `tool/r47tf_mutation.cjs` 七刀各红一条、装回逐字节一致。' },
      { name: '§六-20 基线 449 → 451', from: 'app **449**（329→351→361→377→389→400→420→432→449）', to: 'app **451**（329→351→361→377→389→400→420→432→449→451）' },
      { name: '§九 基线 449 → 451', from: '→**449** · analyze 三处 0', to: '→**451** · analyze 三处 0' },
      { name: '§九 含通知栏 → 盖掉通知栏', from: '★ **全屏页含通知栏**——`ColoredBox` 让深色底从 y=0 铺到底 + `AnnotatedRegion` 声明浅色状态栏图标，', to: '★ **全屏页盖掉通知栏**（补正：用户第二轮说「顶部还是没有全屏」，要的是 `immersiveSticky` 收掉栏，不是铺到它底下换浅色图标），' },
      { name: '§九 五刀 → 七刀', from: '`tool/r47tf_mutation.cjs` 五刀（occupy/snap/vibrate/overlay/noRestore）各红一条、装回逐字节一致；', to: '`tool/r47tf_mutation.cjs` 七刀（occupy/snap/vibrate/overlay/noRestore/immersive/immersiveRestore）各红一条、装回逐字节一致；' },
      { name: '§九 尾巴：欠走查 + 没进 apk → 都已结', from: '仍欠 ⑪ 三件形态的真机手感，且**这份改动没进 apk**（0.16.0+14 是第八段之前编的）。', to: '★ ⑪ 形态三件与「盖掉通知栏」已于 2026-10-01 真机走过（0.16.0+15，截图 `dist/r47tf_device/`），见 §五 R47 ⑪ 末。' },
      { name: '§7.10 追加一条（边界词要在真机上对图）', from: '按**我们那一记的指纹**（深色图标 + 两套栏都透明）断言——变异脚本这才真的能把它摘红 |', to: '按**我们那一记的指纹**（深色图标 + 两套栏都透明）断言——变异脚本这才真的能把它摘红 |' + '\n' + NEW_ROW },
    ],
  },
  {
    file: PLAN,
    edits: [
      {
        name: '计划书：③ 全屏含通知栏 → 盖掉',
        from: '③ **全屏页含通知栏**（需求原话「全屏要包含通知栏的，当前没有」）——`ColoredBox` 让深色底从 y=0 铺到底 + `AnnotatedRegion<SystemUiOverlayStyle>` 声明状态栏透明与**浅色图标**',
        to: '③ **全屏页盖掉通知栏**（需求两轮：「全屏要包含通知栏的」→ 装机后「顶部还是没有全屏」，要的是**没有**那条栏）' +
          '——`SystemChrome.setEnabledSystemUIMode(immersiveSticky)` 收掉状态栏与导航栏、退出设回 `edgeToEdge`；' +
          '深色底顶到 y=0 与 `AnnotatedRegion` 浅色图标退为"栏被短暂划回来"那一刻的兜底',
      },
      { name: '计划书：五刀 → 七刀', from: '反向验证 `tool/r47tf_mutation.cjs` **五刀**（occupy/snap/vibrate/overlay/noRestore）各红一条、装回逐字节一致。', to: '反向验证 `tool/r47tf_mutation.cjs` **七刀**（occupy/snap/vibrate/overlay/noRestore/immersive/immersiveRestore）各红一条、装回逐字节一致。' },
      { name: '计划书：基线与真机', from: '基线 app **432→449**、shared 193、server 320 未动、analyze 三处 0；零改列，但**形态改动要进真机得重编 apk**（在包里的 0.16.0+14 是第八段之前编的）。', to: '基线 app **432→449→451**、shared 193、server 320 未动、analyze 三处 0；零改列。★ 形态改动已随 **0.16.0+15** 重编 arm64 并装机，' +
        '四条（吸边耳朵 / 展开仍贴边 / 面板让位 / 全屏盖栏）2026-10-01 真机已过（截图 `dist/r47tf_device/`）。' },
    ],
  },
  {
    file: GAP,
    edits: [
      {
        name: '盘点：含通知栏 → 盖掉通知栏',
        from: '全屏页**含通知栏**（深色底顶到 y=0 + 浅色状态栏图标）',
        to: '全屏页**盖掉通知栏**（`immersiveSticky`；需求两轮才收敛：「包含通知栏」= 要没有那条栏）',
      },
      {
        name: '盘点：app 基线 449 → 451',
        from: 'app 基线 **449**，零改列。',
        to: 'app 基线 **451**，零改列；★ 形态三件与全屏盖栏已随 0.16.0+15 装机、2026-10-01 真机已过。',
      },
    ],
  },
];

const check = process.argv.includes('--check');
let bad = 0;
const staged = new Map();
for (const job of JOBS) {
  const raw = fs.readFileSync(job.file, 'utf8');
  const eol = raw.includes('\r\n') ? '\r\n' : '\n';
  const j = (s) => s.split('\n').map((x) => x.replace(/\r$/, '')).join(eol);
  let text = staged.get(job.file) || raw;
  for (const e of job.edits) {
    const from = j(e.from), to = j(e.to);
    const hits = text.split(from).length - 1;
    if (hits !== 1) {
      console.log(`[${path.basename(job.file)}] ${e.name} → 命中 ${hits} 次 FAIL`);
      bad++;
      continue;
    }
    console.log(`[${path.basename(job.file)}] ${e.name} OK`);
    text = text.replace(from, to);
  }
  staged.set(job.file, text);
}
if (bad) { console.log(`\n${bad} 处锚点没对上，未写盘。`); process.exit(1); }
if (check) { console.log('\n--check：全部命中，未写盘。'); process.exit(0); }
for (const [f, text] of staged) {
  const grew = Buffer.byteLength(text) - Buffer.byteLength(fs.readFileSync(f));
  fs.writeFileSync(f, text, 'utf8');
  console.log(`写盘 ${path.basename(f)}：${grew >= 0 ? '+' : ''}${grew} bytes`);
}
