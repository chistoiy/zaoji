// R47 第七段（网络恢复即同步 · 需求书 §9.2 S1）落地后的划账。
// 与 doc_r47_meal.cjs 同一套写法：整行/整块替换 + 命中断言 + 列数校验 + 快照 + 体积护栏。
// 门禁数字从 dist/r47meal_gate.log 现读并断言「只升不降」，不 hand-copy。
// 用法：node tool/doc_r47_net.cjs
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DOC = path.join(ROOT, '灶记-交接文档.md');
const PLAN = path.join(ROOT, '灶记-开发计划书.md');
const GAP = path.join(ROOT, '灶记-功能查漏补缺-2026-09-29.md');
const LOG = path.join(ROOT, 'dist', 'r47meal_gate.log');

const guard = (label, cond, extra) => {
  if (!cond) { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); process.exit(1); }
  console.log('✔ ' + label);
};

/* ——— ⓪ 门禁读数 ——— */
const logText = fs.readFileSync(LOG, 'utf8');
const counts = (logText.match(/\+(\d+): All tests passed!/g) || []).map((s) => parseInt(s.replace(/^\+/, ''), 10));
guard('日志里三条全绿读数（shared / server / app）', counts.length === 3, counts.join('/'));
const [SH, SV, AP] = counts;
guard('shared 只升不降（≥193）', SH >= 193, String(SH));
guard('server 只升不降（≥320）', SV >= 320, String(SV));
guard('app 只升不降（≥432 = 420 + 本段 12）', AP >= 432, String(AP));
guard('日志里没有 analyze 问题', !/[1-9]\d* issues? found/i.test(logText));

const open = (file, snap) => {
  const before = fs.readFileSync(file, 'utf8');
  fs.writeFileSync(snap, before);
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
  return { before, lines, EOL, cols, find, block, snap };
};
const save = (file, d) => {
  const after = d.lines.join('\n');
  guard('行数只增不减 ' + path.basename(file), after.split('\n').length >= d.before.split('\n').length,
    d.before.split('\n').length + ' → ' + after.split('\n').length);
  guard('体积变化合理 ' + path.basename(file),
    after.length > d.before.length && after.length < d.before.length + 20000,
    d.before.length + ' → ' + after.length);
  guard('没有以空格开头的悬挂续行 ' + path.basename(file),
    after.split('\n').filter((l) => l.startsWith(' |')).length === 0);
  fs.writeFileSync(file, after);
  console.log('✔ 已写入 ' + path.relative(ROOT, file) + '（快照：' + path.relative(ROOT, d.snap) + '）');
};

/* ══════════════ ① 交接文档 ══════════════ */
{
  const d = open(DOC, path.join(ROOT, 'dist', 'handover_before_r47_net.md'));
  const { lines, EOL, find, block } = d;

  // 标题 / 边界 / 基线
  {
    const i = find('### R47 · 2026-09-30 ·');
    guard('标题还写六段', lines[i].includes('（**六段，代码收口，欠真机**）'));
    lines[i] = lines[i].replace('+ 开饭前投待办（**六段，代码收口，欠真机**）',
      '+ 开饭前投待办 + 网络恢复即同步（**七段，代码全部收口，欠真机**）') + EOL;

    const j = find('**先说清楚边界**');
    guard('第二行是「六段交了计时」', lines[j + 1].startsWith('**六段交了计时'));
    lines.splice(j, 2, ...block([
      '**先说清楚边界**：R47 的范围（计划书 §22.2 与 §22.3 第 1 条）到第七段**代码全部收口**——',
      '**七段交了计时（①~④）、偏好（③⑤⑥⑧）与常亮（⑤）、计时结束通知与声音（⑥）、库存到期提醒（⑦）、厨房顶部告警卡（⑧）、开饭前投待办（⑨）、网络恢复即同步（⑩）**；'
      + '剩下的只有「通知三路（⑥⑦）的真机呈现」、语音那一路（后置 R53）与后台准点投递（M3 的架构账），写在下面「还没做的」里，别把这一节当整轮划掉。',
    ]));

    const k = find('**基线**：shared **193**');
    guard('基线续行以「→ **361**（第二段」开头', lines[k + 1].startsWith('→ **361**（第二段'));
    guard('续行末尾是第六段那句', lines[k + 1].includes('新增 20）· analyze 三处全 0。'));
    lines[k + 1] = lines[k + 1].replace(
      '新增 20）· analyze 三处全 0。',
      '新增 20）→ **' + AP + '**（第七段：`net_wake_r47_test` 新增 12）· analyze 三处全 0。') + EOL;
    guard('基线那句写了 ' + AP, lines[k + 1].includes('**' + AP + '**（第七段'));
  }

  // ⑩ 段 + 「还没做的」补一句
  {
    const i = find('**还没做的**（R47 剩下的账，接手从这里接）：');
    const NEW10 = [
      '⑩ **第七段（同日接上）· 网络恢复即同步（需求书 §9.2 S1）**。',
      '这条洞是计划书 §22.3 第 1 条点名的：同步原本有四条触发线（写入防抖 3s、失败退避 ≤8 次、',
      '15 分钟兜底、启动一次），**没有一条听得见「网通了」这个事件**——飞行模式里连做十道菜',
      '全部写进本地库并排进 `change_log`，防抖那次同步必然失败，退避几分钟就烧完，',
      '之后只能等 15 分钟兜底或用户手动「立即同步」。需求书那句「恢复网络后自动同步」因此不成立。',
      '新增 `app/lib/data/net_wake.dart`：`NetWake` 订阅 `connectivity_plus`（**7.3.1**，'
      + '**先读包源码再用**：`onConnectivityChanged` 是 `Stream<List<ConnectivityResult>>`、列表恒非空、'
      + '平台侧已经 `distinct` 过——但那只是去重复读数，**不代替边沿判定**）。三条判定各有用例钉着：',
      '★ **第一个事件只记录不触发**：启动路径自己已经同步过一次（`main.dart` 的 postFrame），'
      + '把「开 App 时读到 wifi」当成恢复，等于每次冷启动多打一轮无谓的同步。',
      '★ **只有「离线 → 在线」的上升沿才算恢复**：wifi 直接切移动网络（用户根本没断过）不打扰；'
      + '「现在在线」与「刚刚恢复」是两件事，前者是电平、后者才是边沿。',
      '★ **去抖窗口内的多次上升沿合并成一次**：现实中恢复那一秒常连着好几条读数（none→vpn→wifi），'
      + '每次上升沿都同步一遍就是在刚通的时候连环打服务端。`edges` 与 `triggers` 两个计数并排放，'
      + '为的就是能断言「认了 3 次、只同步 1 次」——合并率是可测的，不是"感觉挺安静"。',
      '★ **失败一律咽掉记 `lastError`**：`onOnline` 抛、流自己报错、桌面预览/测试区没有通道，'
      + '都不能让这只耳朵聋掉或把 App 炸掉（与 `screen_wake.dart` 同一立场：这一路是体验不是数据）。',
      '取的是**流的函数**（`streamOf`）而不是流本身：否则 `late final _net` 在 dispose 里被碰到时'
      + '也会去构造平台订阅，那条 `MissingPluginException` 就成了测试区的崩溃而不是留痕。',
      '接线：`_ensureSync()` 里引擎建好之后 `_net.start()`（**幂等**——订两次就会一次恢复同步两遍），'
      + '恢复时走的是同一个 `syncIfPaired`（未配对仍是安静 no-op，不需要在这里再判一遍）；'
      + '`dispose` 里自己创建的才自己关（注入的归测试管，与计时台同一口径）。',
      '这一段**零 UI 变化**，所以原型不动（「先改原型」那条铁律管的是有视觉形态的部分，与 ⑤ 常亮同例）。',
      '守卫：`app/test/net_wake_r47_test.dart` **12 例**（含「ZaojiApp 起来之后从断到通」那条真动线）。'
      + '反向验证 `tool/net_r47_mutation.cjs` 三刀——`firstEvent` → ★「第一个事件只记录」红'
      + '（`Expected: <0> Actual: <1>`）；`edge` → ★「没断过就不算恢复」红（`Expected: <0> Actual: <2>`）；'
      + '`merge`（去抖窗口归零）→ ★「三次上升沿合并成一次」红（`Expected: <0> Actual: <2>`）；'
      + '`restore` 装回后 12 例重新全绿（与快照逐字节核对过）。',
      '',
    ];
    lines.splice(i, 0, ...block(NEW10));

    const t = find('③ **后台准点投递**');
    lines[t] = ('③ **后台准点投递**（人不在 App 里也按点开饭前弹）：要 Android 精确闹钟 + APNs 级调度，是 M3 的架构账；'
      + '⑦ 与 ⑨ 都刻意只挂在「打开 App / 回前台」上，别把它当成已完成。'
      + '★ 别与 ⑩ 混为一谈：⑩ 补的是「网络恢复时把攒下的写推上去」，不是「到点没打开 App 也能弹」。') + EOL;
  }

  // §六-20 整行重写
  {
    const i = find('| 20 | **R47 六段已完成', 4);
    lines[i] = ('| 20 | **R47 七段已完成（2026-09-30，代码全部收口；欠真机验收）** | ✅ **计时内核 deadline 化 + 多计时器并行 + 悬浮球与全屏两形态 + `KitchenPrefs` 本机偏好 + 屏幕常亮 + 计时结束通知与声音 + 库存到期提醒 + 厨房顶部告警卡 + 开饭前投待办 + 网络恢复即同步**（FR-COOK-03/04/05/**09**/**14**、**FR-PAN-04 的推送时机**、**FR-PAN-06**、FR-SET-01、FR-SET-02、FR-SET-03 的震动与声音两路、**FR-PLAN-09**、NFR-REL-03、**需求书 §9.2 S1**）：细节、反漂移证据、引用计数、授权态、通知号段、投递窗口、边沿判定与合并、以及「一份口径」的抽法见 §五 R47 ①~⑩，坑在 §7.10。**基线** shared **' + SH + '**（177→' + SH + '）· server **' + SV + '**（未动）· app **' + AP + '**（329→351→361→377→389→400→420→' + AP + '）· analyze 三处 0 · 原型走查全绿（timers 32 / prefs 17 / notify 22 / expiry 17 / 告警卡 33 / 投待办 33 / nutrition 40）。★ **通知三路（⑥⑦⑨）本机只验到逻辑闸门，没验到真机呈现**：系统弹框、渠道实际出声、Web 在 https 下能否弹，都要连 §六-1 的真机清单一起走，别把全绿当验收。**R47 剩下的只有**：① 上面那句真机验收（要设备时段）；② 语音那一路（TTS，后置 R53 之后）；③ 后台准点投递（M3 的架构账，刻意不做，别与 ⑩ 的「恢复即同步」混为一谈）。产物 / 版本号 / push 一概没动，七段全程零改列，不欠「apk + exe 同发」 |') + EOL;
    guard('§六-20 新行仍是 3 列', d.cols(lines[i]) === 4, String(d.cols(lines[i])));
  }

  // §九 R47 行：插 ⑩（S1）、基线改号 ⑪、补 ' + AP + '、结尾改口
  {
    const i = find('| R47 | 2026-09-30 |', 4);
    let row = lines[i].replace(/\r$/, '');
    guard('行首写「六段，代码收口」', row.includes('（六段，代码收口，欠真机验收）'));
    row = row.replace('（六段，代码收口，欠真机验收）', '（七段，代码全部收口，欠真机验收）');
    guard('有 ⑩ 基线那项', row.split('⑩ **基线**').length - 1 === 1);
    const NEW10ROW = '⑩ **网络恢复即同步（需求书 §9.2 S1，第七段）**：计划书 §22.3 第 1 条点名的洞——四条同步触发线（防抖 3s / 退避 ≤8 次 / 15 分钟兜底 / 启动一次）里**没有一条听得见「网通了」**，飞行模式攒下的写在退避烧完之后就躺着不动；`data/net_wake.dart` 订 `connectivity_plus`（7.3.1，先读包源码：流给的是 `List<ConnectivityResult>`、平台侧已 `distinct` 但那不代替边沿判定），三条判定各有用例——★ **首事件只记录不触发**（启动已同步过一次）、★ **只有离线→在线的上升沿算恢复**（换网络不打扰）、★ **窗口内多次上升沿合并成一次**（`edges`/`triggers` 两个计数就是合并率）；★ 失败一律咽掉记 `lastError`（`onOnline` 抛、流报错、桌面/测试区没通道都不能聋掉这只耳朵），注入的是**取流的函数**而不是流本身（否则 dispose 里碰到 `late final` 就会去构造平台订阅）；接线在 `_ensureSync()` 之后 `_net.start()`（幂等），走同一个 `syncIfPaired`。零 UI 变化所以原型不动；`net_wake_r47_test` **12 例** + `net_r47_mutation.cjs` 三刀（`firstEvent`/`edge`/`merge`）各红一条，★ 变异点要挑不破坏空安全提升的那一行（摘 `if (previous == null) return;` 会连带摘掉类型提升，编译不过的"红"不是证据）。';
    row = row.replace('⑩ **基线**', NEW10ROW + '⑪ **基线**');
    guard('⑩ 段文字与 ⑪ 基线都在了', row.includes(NEW10ROW) && row.includes('⑪ **基线**'));
    guard('基线那项里有 420', row.includes('**400**→**420**'));
    row = row.replace('**400**→**420**', '**400**→**420**→**' + AP + '**');
    guard('基线链里有 ' + AP, row.includes('**420**→**' + AP + '**'));
    guard('结尾「代码收口」那句还在', row.includes('**代码收口**：R47 六段全部落地'));
    const OLD_TAIL = '**代码收口**：R47 六段全部落地，剩下的只有**通知三路（⑥⑦⑨）的真机验收**（要设备时段）、语音那一路（TTS，后置 R53 之后）与**后台准点投递**（M3 的架构账，本轮刻意不做）——见 §六-20';
    const NEW_TAIL = '**代码全部收口**：R47 七段全部落地（含 §22.3 第 1 条点名的 S1），剩下的只有**通知三路（⑥⑦⑨）的真机验收**（要设备时段）、语音那一路（TTS，后置 R53 之后）与**后台准点投递**（M3 的架构账，刻意不做，别与 ⑩ 的「恢复即同步」混为一谈）——见 §六-20';
    guard('结尾那句锚原样命中（replace 不是空转）', row.includes(OLD_TAIL));
    row = row.replace(OLD_TAIL, NEW_TAIL);
    guard('改后仍是 3 列', (row.match(/\|/g) || []).length === 4, String((row.match(/\|/g) || []).length));
    lines[i] = row + EOL;
  }

  // §7.10 标题与追加坑
  {
    const i = find('### 7.10 R47 新增的坑');
    lines[i] = '### 7.10 R47 新增的坑（计时内核 / 偏好 / 常亮 / 通知 / 到期提醒 / 告警卡 / 投待办 / 网络监听，每条都真红过）' + EOL;

    const PIT = [
      '| ★ **反向验证的变异点不能踩到类型系统**（编译不过的"红"不是证据） | 想摘「第一个事件只记录不触发」，最直接的是把 `if (previous == null) return;` 改成 `if (false) return;`——可那一行同时是 `previous` 的**空安全提升**，摘掉之后下一行 `isOffline(previous)` 报 `List<X>?` 不能赋给 `List<X>`，测试停在"加载失败"。改成把**声明行**换成 `lastResults ?? const [none]`：类型照旧提升，被摘掉的才是行为 |',
      '| ★ **平台通道的监听要注入「取流的函数」，不是流本身** | `NetWake(stream: Connectivity().onConnectivityChanged)` 会在 `late final _net` 被触碰的那一刻就去碰通道（dispose 里访问也算触碰），测试区那条 `MissingPluginException` 于是成了崩溃而不是留痕。改成 `streamOf: connectivityStream`，取流与订阅收进 `start()` 的同一个 try/catch |',
      '| ★ **「恢复」是边沿不是电平，三条判定少一条都变骚扰** | 首事件当恢复 = 每次开 App 多一轮同步；「现在在线」当恢复 = 用户换个网络也被打扰；不合并 = 刚通那一秒连环打服务端。`edges` 与 `triggers` 两个计数并排放，才能断言「认了 3 次、只同步 1 次」——安静是可测的，不是感觉 |',
    ];
    const at = find('| ★ **走查里 favicon 那条 404 用控制台文本分不出来**', 3);
    guard('新坑每行也都是 2 栏', PIT.every((r) => (r.match(/\|/g) || []).length === 3),
      PIT.map((r) => String((r.match(/\|/g) || []).length)).join('/'));
    lines.splice(at + 1, 0, ...block(PIT));
  }

  const all = lines.join('\n');
  guard('⑩ 段进了文档', all.includes('⑩ **第七段（同日接上）· 网络恢复即同步'));
  guard('§六-20 升到七段', all.includes('| 20 | **R47 七段已完成'));
  guard('§九 那行有 ⑪ 基线', all.includes('⑪ **基线**'));
  save(DOC, d);
}

/* ══════════════ ② 开发计划书 ══════════════ */
{
  const d = open(PLAN, path.join(ROOT, 'dist', 'plan_before_r47_net.md'));
  const { lines, EOL, find, block } = d;

  const i = find('### R47 · 厨房现场体验 + 提醒基建（P0）');
  guard('标题还写六段', lines[i].includes('✅ **六段全部落地'));
  lines[i] = ('### R47 · 厨房现场体验 + 提醒基建（P0） ✅ **七段全部落地（2026-09-30：计时内核 + 两形态 + 本机偏好 + 常亮 + 通知与声音 + 库存到期提醒 + 厨房告警卡 + 开饭前投待办 + 网络恢复即同步）· 代码全部收口，欠通知三路的真机验收**') + EOL;

  // 在「提醒基建是这一轮的副产品」那条 bullet 之后补一条 S1
  const j = find('- **提醒基建是这一轮的副产品**');
  lines.splice(j + 1, 0, ...block([
    '- **S1「飞行模式新增 → 恢复网络后自动同步」是这一轮的附带账**（计划书 §22.3 第 1 条：四条同步触发线里没有一条听得见「网通了」）。 ✅ **第七段完成（2026-09-30）**：`data/net_wake.dart` 订 `connectivity_plus`（7.3.1），★ 首事件只记录不触发 / ★ 只有离线→在线的上升沿算恢复 / ★ 窗口内多次上升沿合并成一次（`edges` 与 `triggers` 两个计数就是合并率）；失败一律咽掉记 `lastError`（没通道的运行环境不许把 App 炸掉），注入的是**取流的函数**而不是流本身；接线在 `_ensureSync()` 之后 `_net.start()`（幂等），走同一个 `syncIfPaired`。零 UI 变化所以原型不动；`net_wake_r47_test` **12 例** + `net_r47_mutation.cjs` 三刀各红一条。见交接文档 §五 R47 ⑩。',
  ]));

  // §22.3 第 1 行结案
  const k = find('| 1 | **S1 场景（飞行模式新增 → 恢复网络自动同步）不成立**', 5);
  lines[k] = ('| 1 | ✅ **[2026-09-30 R47 第七段结案] S1 场景（飞行模式新增 → 恢复网络自动同步）**：原来四条触发线（写入防抖 3s / 退避 ≤8 次 / 15 分钟兜底 / 启动一次）里没有 connectivity 监听，飞行模式攒下的写在退避烧完后就躺着不动 | `app/lib/data/net_wake.dart`（`NetWake`：首事件只记录 + 离线→在线上升沿 + 窗口内合并）；接线 `app/lib/main.dart` 的 `_ensureSync()` 之后 `_net.start()`；守卫 `app/test/net_wake_r47_test.dart` 12 例，反向验证 `tool/net_r47_mutation.cjs` 的 `firstEvent`/`edge`/`merge` 各红一条 | R47 ✅ |') + EOL;
  guard('§22.3 第 1 行仍是 4 列', d.cols(lines[k]) === 5, String(d.cols(lines[k])));

  save(PLAN, d);
}

/* ══════════════ ③ 盘点表 ══════════════ */
{
  const d = open(GAP, path.join(ROOT, 'dist', 'gap_before_r47_net.md'));
  const { lines, EOL, find } = d;

  const i = find('| 同步 | S1「飞行模式新增 → 恢复网络自动同步」', 4);
  lines[i] = ('| 同步 | S1「飞行模式新增 → 恢复网络自动同步」 | ✅ **已结案（2026-09-30 R47 第七段）**：`app/lib/data/net_wake.dart` 订 `connectivity_plus`，恢复时走同一个 `syncIfPaired`。三条判定各有用例钉着——**首事件不算恢复**（启动已同步过一次）、**换网络不算恢复**（只认离线→在线的上升沿）、**刚通那一秒的多次上升沿合并成一次**。原来「只有写入防抖 3s / 退避 ≤8 次 / 15 分钟兜底 / 启动一次」的洞补上了（S5 幂等、S6 抗回拨两端本来就有真协议测试） |') + EOL;
  guard('盘点「同步」行仍是 3 列', d.cols(lines[i]) === 4, String(d.cols(lines[i])));

  const j = find('| **R47** |', 5);
  let row = lines[j].replace(/\r$/, '');
  guard('R47 行还写「六段全部落地」', row.includes('✅ **六段全部落地（2026-09-30）**'));
  row = row.replace('✅ **六段全部落地（2026-09-30）**', '✅ **七段全部落地（2026-09-30）**');
  const OLD_TAIL2 = '**只剩**通知三路（⑥⑦⑨）的**真机呈现**与语音那一路（TTS 后置 R53）';
  guard('R47 行结尾那句锚原样命中（replace 不是空转）', row.includes(OLD_TAIL2));
  row = row.replace(
    OLD_TAIL2,
    OLD_TAIL2 + '。★ 顺带把 §22.3 第 1 条点名的 **S1 网络恢复即同步**也收了（`NetWake`：上升沿 + 合并 + 首事件不算恢复）');
  guard('改后仍是 4 列', (row.match(/\|/g) || []).length === 5, String((row.match(/\|/g) || []).length));
  lines[j] = row + EOL;

  save(GAP, d);
}

console.log('—— 划账完成：交接文档 / 计划书 / 盘点三处都改了，记得跑 node tool/doc_table_lint.cjs');
