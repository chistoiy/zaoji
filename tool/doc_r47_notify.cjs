// R47 第三段（计时结束通知与声音）落地后的划账：改交接文档五处。
//
// 全是**整行替换或按整行前缀插入**，不做「拿下一行行首当锚点」那种插法
// （那颗坑在 §7.10 里记着）。每步都断言命中次数、列数、行数、行尾。
// 用法：node tool/doc_r47_notify.cjs
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DOC = path.join(ROOT, '灶记-交接文档.md');
const SNAP = path.join(ROOT, 'dist', 'handover_before_r47_notify.md');

const guard = (label, cond, extra) => {
  if (!cond) { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); process.exit(1); }
  console.log('✔ ' + label);
};

let src = fs.readFileSync(DOC, 'utf8');
fs.writeFileSync(SNAP, src);
const cols = (l) => (l.match(/\|/g) || []).length;

/* ——— ① §五 R47：标题与边界那句 ——— */
const oldTitle = '### R47 · 2026-09-30 · 计时内核 deadline 化 + 多计时器并行 + 悬浮球/全屏两形态 + 本机偏好 + 屏幕常亮（**第一、二段，本轮未完**）';
const newTitle = '### R47 · 2026-09-30 · 计时内核 deadline 化 + 多计时器并行 + 悬浮球/全屏两形态 + 本机偏好 + 屏幕常亮 + 计时结束通知（**前三段，本轮未完**）';
guard('§五 标题命中一次', src.split(oldTitle).length - 1 === 1);
src = src.replace(oldTitle, newTitle);

const oldEdge = '**先说清楚边界**：R47 的范围（计划书 §22.2）还包括通知栏提醒、到期提醒、首页过期卡、开饭前投待办——\r\n**这两段交了计时（①~④）、偏好（③）与常亮（⑤）**，其余的账写在下面「还没做的」里，别把这一节当整轮划掉。';
const newEdge = '**先说清楚边界**：R47 的范围（计划书 §22.2）还剩到期提醒、首页过期卡、开饭前投待办没做——\r\n**前三段交了计时（①~④）、偏好（③⑤⑥）与常亮（⑤）、计时结束通知与声音（⑥）**，其余写在下面「还没做的」里，别把这一节当整轮划掉。';
guard('§五 边界那句命中一次', src.split(oldEdge).length - 1 === 1);
src = src.replace(oldEdge, newEdge);

/* ——— ② §五：基线那句 + 新增 ⑥ 段 ——— */
const oldBase = '**基线**：shared **193**（177→193）· server 320（未动）· app 329 → **351**（第一段：新增 14 + 8，`recipe_flow_test` 的胶囊用例改写成悬浮球链）→ **361**（第二段：`wake_r47_test` 新增 10）·\r\nanalyze 三处全 0。';
const newBase = '**基线**：shared **193**（177→193）· server 320（未动）· app 329 → **351**（第一段：新增 14 + 8，`recipe_flow_test` 的胶囊用例改写成悬浮球链）\r\n→ **361**（第二段：`wake_r47_test` 新增 10）→ **377**（第三段：`notify_r47_test` 新增 16）· analyze 三处全 0。\r\n\r\n⑥ **第三段（同日接上）· 计时结束的通知与声音（FR-COOK-14 + FR-SET-03 的第二路）**。\r\n' +
'引了 `flutter_local_notifications`（**22.3.1**，连带 `timezone` 与四个平台包，其中**自带 web 实现** `flutter_local_notifications_web`，\r\n' +
'所以 Android 与 Web 用同一个插件、不必自己写 `Notification` 的 js_interop）。\r\n' +
'**API 是先读包源码再用的**：这一版 `initialize`/`show` 都改成了命名参数，\r\n' +
'`AndroidNotificationChannel` 那一项的字段叫 `description`、`AndroidNotificationDetails` 的叫 `channelDescription`（不对称，编译一次才点出来）。\r\n' +
'新增 `app/lib/data/timer_alert.dart`：`TimerAlert` 是**带授权状态机的发送闸门**，三张嘴全部可注入\r\n' +
'（`NoticeSender` / `PermissionRequester` / `PermissionReader` + `SystemSettingsOpener`）——\r\n' +
'插件在测试区是黑盒，而这一段真正要断的是**闸门**：没授权一条都不发、`skippedCount` 要留痕、\r\n' +
'并行到点各发一条且**同一条计时器复用同一个通知 id**（否则攒一屏垃圾横幅）、一条发送失败不牵连另一条。\r\n' +
'★ **初始态是 `unknown` 而不是 `granted`**：Android 启动时 `areNotificationsEnabled()` 读得到真值可以收敛，\r\n' +
'Web 在用户点之前**读不到**，只能保持 unknown。把它写成 granted 的后果是设置页少掉授权入口、而通知永远发不出去——\r\n' +
'正是本轮在清的那类「看着开着其实没通」。\r\n' +
'闸门是**两道**：本机 `KitchenPrefs.notifyOn`（`main._onTimersFired` 里先过）与系统授权（`TimerAlert.fire` 里再过），\r\n' +
'各管各的、任何一道关着都不发；`enableVibration: false` 写在渠道上是刻意的——震动归 `vibrateOn` 那一路，\r\n' +
'渠道再振一次就变成「设置里关不掉的震动」。\r\n' +
'接线：`TimerBoard` 多了一个**可后接**的 `onFired`（不是构造参数，因为板子可能是测试注入的、那时构造早跑完了），\r\n' +
'新的 `AlertScope` 与 `TimerScope`/`WakeScope` 同层挂在 `MaterialApp` 之上。\r\n' +
'Android 清单补 `POST_NOTIFICATIONS`，并由 `notify_r47_test.dart` 里一条读清单的测试钉住\r\n' +
'（与 `manifest_guard_test` 的 INTERNET 同一手法：这条漏了，Android 13+ 上通知永远发不出去，症状像功能没做）。\r\n' +
'★ **UI 先原型后实现**：`tool/proto_notify_r47.cjs` + `tool/proto_notify_r47_fix.cjs` 把「计时结束通知」「通知带声音」\r\n' +
'两行与「开启系统通知授权」入口做进原型，`tool/proto_notify_r47_walk.cjs`（**22 条断言**）钉住\r\n' +
'「没授权时声音那行不出现但给得出一条能点的授权入口」「翻开关不许把自己算成已授权」「关掉通知后两行都收起」「刷新回默认」。\r\n' +
'守卫：`app/test/notify_r47_test.dart` **16 例**；反向验证做了两道门\r\n' +
'（`tool/notify_r47_mutation.cjs permGate` → `Expected: <0> Actual: <1>`；`prefGate` → `Expected: empty Actual: [AlertNotice]`；`restore` 装回后 16 例重新全绿）。\r\n' +
'**这一段有一件必须说清的没做完**：通知**能不能真的弹出来只能在真机上看**——\r\n' +
'测试区里插件是黑盒，逻辑闸门都钉住了，但系统弹框、渠道实际呈现、Web 的 https 安全上下文这三件事本机验不了，\r\n' +
'按 §六-1 的真机清单走。';
guard('§五 基线那句命中一次', src.split(oldBase).length - 1 === 1);
src = src.replace(oldBase, newBase);

/* ——— ③ §五「还没做的」整块重写 ——— */
const oldTodo = '**还没做的**（R47 剩下的两条，接手从这里接）：\r\n' +
'① **FR-COOK-14 的通知栏与声音**——**常亮（FR-COOK-09）已经做完**（见上面 ⑤），剩这一路：\r\n' +
'`flutter_local_notifications` **还没引**（镜像可达、latest 22.3.1，但 API 要先读源码确认——大版本改动多），\r\n' +
'Android 清单/权限与 Web 的 Notification API 都要接，**并且要真机验收**（本机测试区里通知是黑盒）。\r\n' +
'当前计时结束只有震动与视觉，`TimerBoard.tickAt` 返回的「本次新到点的实例」就是留给这一路的钩子。\r\n' +
'② **FR-PAN-04 的「到期提醒」**（三态高亮 R28 就做实了，缺的是推送时机，跟 ① 同批）。\r\n' +
'③ **FR-PAN-06 首页卡 + FR-PLAN-09 开饭前投待办**——后者是 FR-SET-01 的钥匙，先要定「待办落在哪儿」。';
const newTodo = '**还没做的**（R47 剩下的账，接手从这里接）：\r\n' +
'① **通知这一路的真机验收**：逻辑与清单都落地了（⑥），但「系统弹框长什么样、渠道真的出声、Web 在 https 下能弹」\r\n' +
'三件事只能在真机上看（Android 13+ 与浏览器都要用户手势里授权）。**别把 16 例全绿读成「通知已验收」。**\r\n' +
'② **FR-PAN-04 的「到期提醒」**：三态高亮 R28 就做实了，缺的正是**推送时机**——现在 `TimerAlert` 已经是一条通到通知栏的路，\r\n' +
'补的是「库存到期/临期」那一批往同一条渠道上发（要一个新的通知 id 规则，别与计时器撞）。\r\n' +
'③ **FR-PAN-06 首页卡 + FR-PLAN-09 开饭前投待办**：后者是 FR-SET-01 的钥匙，先要定「待办落在哪儿」\r\n' +
'（项目里没有待办实体，备菜清单是派生不落库；建表 = 改列轮 = apk 与 exe 必须同发那笔硬账）。\r\n' +
'**FR-PAN-06 不依赖通知**，可以单独先做，前提是先定「首页」是哪一屏（App 五个标签里没有独立的「首页」）。\r\n' +
'④ **FR-SET-03 的语音那一路**（TTS，FR-COOK-12/13）按计划书后置到 R53 之后，不卡这一轮。';
guard('§五「还没做的」整块命中一次', src.split(oldTodo).length - 1 === 1);
src = src.replace(oldTodo, newTodo);

/* ——— ④ §六-20 与 §九 R47 两行整行重写 ——— */
const ROW6 = '| 20 | **R47 前三段已完成（2026-09-30，本轮未完）** | ✅ **计时内核 deadline 化 + 多计时器并行 + 悬浮球与全屏两形态 + `KitchenPrefs` 本机偏好 + 屏幕常亮 + 计时结束通知与声音**（FR-COOK-03/04/05/**09**/**14**、FR-SET-02、FR-SET-03 的震动与声音两路、NFR-REL-03）：细节、反漂移证据、引用计数与授权态的立场见 §五 R47 ①~⑥，坑在 §7.10。**基线** shared **193**（177→193）· server 320（未动）· app **377**（329→351→361→377）· analyze 三处 0 · 四份原型走查全绿（timers 32 条、prefs 17 条、notify 22 条、nutrition 40 条）。★ **通知这一路本机只验到逻辑闸门，没验到真机呈现**：系统弹框、渠道实际出声、Web 在 https 下能否弹，都要连 §六-1 的真机清单一起走，别把 16 例全绿当验收。**还欠三条**：① **FR-PAN-04 到期提醒**——三态高亮 R28 就做实了，缺的是推送时机，而 `TimerAlert` 现在已经是那条通到通知栏的路，补的是把临期/过期库存挂上同一渠道（**要新的 id 规则，别与计时器撞**）；② **FR-PAN-06 首页「即将过期 / 快没了」卡 + FR-PLAN-09 开饭前投待办**——② 里的「投待办」是 FR-SET-01 的钥匙：项目里**没有待办实体**（备菜清单派生、不落库），所以「开饭前提醒」那枚开关现在刻意只在原型里，实现不上「能打开但什么都不发生」的控件；要推进先由用户拍**待办落在哪儿**（建 `plan_task` 表 = 改列轮 = apk 与 exe 必须同发），以及 App 五个标签里「首页」指哪一屏；③ FR-SET-03 的**语音**那一路（TTS）按计划书后置 R53。产物 / 版本号 / push 一概没动；三轮都零 schema 改动，不欠「apk + exe 同发」 |';
const ROW9 = '| R47 | 2026-09-30 | **计时内核 deadline 化 + 多计时器并行 + 悬浮球与全屏两形态 + 本机偏好 + 屏幕常亮 + 计时结束通知与声音（前三段，本轮未完）**（用户：「继续」——按计划书 §22.2 R47 范围自挑，先做内核再谈形态，内核不稳时接通知等于给流沙装门）。① **内核进 `shared/lib/src/timer_clock.dart`**：唯一时间源是 `endAtMs`（目标戳），剩余一律 `remainingAt(nowMs)` 现算；`shared/test/timer_clock_test.dart` **16 例**（177→193）钉住「暂停存同一戳、加时改的是戳不是显示、续跑必须重算戳（否则切后台回来立刻跳零）、回拨不产生负剩余」。**NFR-REL-03「后台 10 分钟误差 <2 秒」从不可能变成有证据**：注入假时钟拨 10 分钟，断言正好减 600 秒。② **App 侧从「sheet 里一个 `Timer?`」改成「设备生命周期的板」**：`data/timer_board.dart`（可注入 `clock/ulids/vibrate`，250ms ticker 只在有跑表时挂着）+ `data/timer_scope.dart` + `ui/timer_sheet.dart` 整体重写（**胶囊点击直接起表不弹层**；`timer-close-all` 关完刻意不 pop 要让人看见空态）+ `ui/timer_overlay.dart`（`OverlayEntry` 挂 navigator root、可拖、钳在安全区、`n>1` 才显 ×N）+ `ui/timer_full_page.dart`（环形进度与上一个/下一个，FR-COOK-03「切形态不丢」）。`timers_r47_test` **14 例**：三并行各自暂停加时关闭互不牵连。③ **`KitchenPrefs` 本机偏好**（`_loadKitchenPrefs` 进 `_doInit`，吃 R45/R46 冷启动教训；落 `local_pref` 的 `kitchen_prefs`，本机 scope 不同步）：`me_page` 加「提醒与计时」区块；★ **FR-SET-01 刻意没上 UI**（「开饭前投待办」没有落点，不放空转开关）。`kitchen_prefs_r47_test` **8 例**。④ **原型同步**（先原型后实现的铁律）：`S.timers/timerSeq/timerFocus` 与同一套 `endAt` 算术、`.tf-others`、`.tf-nav/.tf-idx`、`.fab-count`、`.lead-row/.lead-chip`、内部状态挂 `window.__zaoji`；`proto_timers_r47_walk`（32 条）、`proto_prefs_r47_walk`（17 条）全绿。⑤ **常亮（FR-COOK-09）**：`wakelock_plus`（1.5.2）做成 `data/screen_wake.dart` 的**两路引用计数**（`cook` / `timer`），最后一路撤掉才关灯——不做计数就会出现「计时器先跑完把正在盯步骤的屏幕关了」；`WakeScope` 注入、拨锁可注入、失败只咽掉记 `lastError`；`wake_r47_test` **10 例** + `tool/wake_r47_mutation.cjs` 反向验证（摘计数 → 2 条红）。⑥ **计时结束通知与声音（FR-COOK-14 + FR-SET-03 第二路）**：`flutter_local_notifications` **22.3.1**（自带 web 实现，Android/Web 同一个插件），**API 先读包源码再用**（`initialize`/`show` 改命名参数；渠道字段叫 `description` 而 details 的叫 `channelDescription`）；`data/timer_alert.dart` 是**带授权状态机的发送闸门**，发送/要权限/读权限/去设置四张嘴全可注入；★ **初始态 unknown 而非 granted**（Web 授权前读不到，猜成 granted 会让入口消失且永远发不出）；**两道闸门**（本机 `notifyOn` + 系统授权）各管各的，渠道 `enableVibration: false` 把震动留给 `vibrateOn`；`TimerBoard.onFired` 做成**可后接**字段（板子可能是测试注入的，构造参数来不及）；`AlertScope` 同层挂载；Android 清单补 `POST_NOTIFICATIONS` 并由测试读清单钉住；`me_page` 三行随授权态出没（没授权就不摆那枚无效的声音开关，但给出能点的授权入口）；原型先做（`proto_notify_r47.cjs` + `_fix.cjs`，走查 `proto_notify_r47_walk` **22 条**含「翻开关不许把自己算成已授权」）；`notify_r47_test` **16 例** + `tool/notify_r47_mutation.cjs` 两道门各摘一次都红过。★ **通知只验到逻辑闸门，真机呈现没验**（系统弹框/渠道出声/Web 是否可弹都要真机）。⑦ **基线** shared 177→**193** · server 320（未动）· app 329→**377** · analyze 三处 0；**没发行**（产物 / 版本号 / push 都没动，零改列所以不欠「apk + exe 同发」）；**本轮未完**：到期提醒（FR-PAN-04 的推送时机）、首页卡与投待办（FR-PAN-06/FR-PLAN-09，后者要先拍待办落哪儿）——见 §六-20 |';
const lines = src.split('\n');
const i6 = lines.findIndex((l) => l.startsWith('| 20 | **R47 第一、二段已完成'));
const i9 = lines.findIndex((l) => l.startsWith('| R47 | 2026-09-30 |'));
guard('§六-20 行找得到且唯一', i6 >= 0 && lines.filter((l) => l.startsWith('| 20 | **R47')).length === 1, 'i6=' + i6);
guard('§九 R47 行找得到且唯一', i9 >= 0 && lines.filter((l) => l.startsWith('| R47 | 2026-09-30 |')).length === 1, 'i9=' + i9);
guard('两行现在都是 3 列', cols(lines[i6]) === 4 && cols(lines[i9]) === 4, cols(lines[i6]) + '/' + cols(lines[i9]));
guard('新行也是 3 列', cols(ROW6) === 4 && cols(ROW9) === 4, cols(ROW6) + '/' + cols(ROW9));
const cr = lines[i6].endsWith('\r');
guard('行尾：' + (cr ? 'CRLF' : 'LF'), true);
lines[i6] = ROW6 + (cr ? '\r' : '');
lines[i9] = ROW9 + (cr ? '\r' : '');
src = lines.join('\n');
guard('§六-20 不再写着「第一、二段」', src.includes('| 20 | **R47 前三段已完成'));

/* ——— ⑤ §7.10 追加本段坑（按整行前缀找末行再插入） ——— */
const PIT = [
  '| ★ **反向验证的锚必须按目标文件的行尾拼** | `main.dart` 是 CRLF、`timer_alert.dart` 是 LF：用 `\\n` 写的多行锚在 CRLF 文件里**一条都命不中**，脚本报了「锚没命中」就退出——这比假成功好，但第一次跑到这里时我差点把“没变异成功”当成“验证过了”。工装现在把行尾判出来再 `join(EOL)`，并把「快照里含原逻辑」「变异确实落盘」都写成断言 |',
  '| ★ **`AndroidNotificationChannel` 的字段叫 `description`，`AndroidNotificationDetails` 的叫 `channelDescription`** | 同一个插件里两处不对称，写串了就编译不过。任何“照着上一个版本印象写”的第三方 API 都要先读包源码——v22 还把 `initialize`/`show` 全改成了命名参数 |',
  '| ★ **授权态不许猜：读不到就是 unknown** | Android 启动时 `areNotificationsEnabled()` 读得到真值；Web 在用户点之前**读不到**。把 unknown 当 granted 写死的后果是设置页少掉授权入口、通知永远发不出去，而 UI 上一切看起来正常。渠道上 `enableVibration: false` 同理：**震动只归 `vibrateOn` 那一路管**，渠道再振一次就变成「设置里关不掉的震动」 |',
  '| ★ **原型第一版把「翻开关」当成「点授权」** | 翻 `notifyOn` 到开就顺手把 `S.notifyPerm` 写成 granted——走查第 [2] 步当场抓到（点一下应该是**关掉这一路**，不是去授权）。授权是系统弹框、只能在手势里发起，必须是一行**独立入口**；开关只管要不要。同理「只写一句要去授权却不给按钮」也是半个假功能 |',
  '| ★ **新 `InheritedWidget` 又打红了一个「页面直挂」harness**（同一个坑第二次命中） | `me_page` 读 `AlertScope` 之后 `me_page_access_test` 全红。§7.10 上一条已经记过 `allergen_r40`，这轮再中一次——说明它属于**约定**不属于偶然：**给页面加注入依赖时，先 `grep -rn "PageName(" test/` 把所有裸挂的 harness 一起补 scope** |',
];
const anchorPrefix = '| ★ **注入的 `TimerBoard` 不由 App 关，用例结尾必须自己 `closeAll()`**';
const l2 = src.split('\n');
const hits = l2.map((l, i) => [l, i]).filter(([l]) => l.startsWith(anchorPrefix));
guard('§7.10 末行锚点唯一', hits.length === 1, 'n=' + hits.length);
const at = hits[0][1];
guard('锚行 3 个竖线（2 栏表）', cols(l2[at]) === 3, 'cols=' + cols(l2[at]));
guard('新行也都 3 个竖线', PIT.every((r) => cols(r) === 3), PIT.map(cols).join('/'));
const cr2 = l2[at].endsWith('\r');
l2.splice(at + 1, 0, ...PIT.map((r) => r + (cr2 ? '\r' : '')));
src = l2.join('\n');
guard('§7.10 行数 +5', src.split('\n').length === l2.length);

const checks = [
  ['标题升到「前三段」', /\*\*前三段，本轮未完\*\*）】?/],
];
guard('⑥ 段进了文档', src.includes('⑥ **第三段（同日接上）· 计时结束的通知与声音'));
guard('基线写了 377', src.includes('→ **377**（第三段：`notify_r47_test` 新增 16）'));
guard('真机未验收写在三处', (src.match(/真机/g) || []).length >= 6);
guard('全文没有以空格开头的悬挂续行', src.split('\n').filter((l) => l.startsWith(' |')).length === 0);
guard('文件只变长', src.length > fs.readFileSync(SNAP, 'utf8').length);

fs.writeFileSync(DOC, src);
console.log('✔ 已写入 ' + path.relative(ROOT, DOC) + '（快照：' + path.relative(ROOT, SNAP) + '）');
