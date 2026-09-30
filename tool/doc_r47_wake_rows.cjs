// R47 第二段（常亮）落地后，把 §六-20 与 §九 R47 那两行**整行重写**。
//
// 为什么整行重写而不是在行尾追加：这两行里写着「wakelock 一个都没有」，
// 现在已经不成立了——留着就是 R46 那轮清掉的那类过时文案（本轮自己立的规矩）。
// 表格行改写用脚本 + 前缀断言，不用 Edit（行太长容易撞「吞下一行行首」那颗坑）。
// 用法：node tool/doc_r47_wake_rows.cjs
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DOC = path.join(ROOT, '灶记-交接文档.md');
const SNAP = path.join(ROOT, 'dist', 'handover_before_r47_wake_rows.md');

const ROW6 = '| 20 | **R47 第一、二段已完成（2026-09-30，本轮未完）** | ✅ **计时内核 deadline 化 + 多计时器并行 + 悬浮球与全屏两形态 + `KitchenPrefs` 本机偏好 + 屏幕常亮**（FR-COOK-03/04/05、**FR-COOK-09**、FR-SET-02、FR-SET-03 的震动这一路、NFR-REL-03）：落地细节、反漂移证据、引用计数的理由与 11 颗坑见 §五 R47 ①~⑤ 与 §7.10。常亮做成 `data/screen_wake.dart` 的**两路引用计数**（`cook` 由做菜屏自己登记、`timer` 跟着计时台），摘掉计数做反向验证过（`tool/wake_r47_mutation.cjs`）。**基线** shared **193**（177→193）· server 320（未动）· app **361**（329→351→361）· analyze 三处 0。**R47 还欠两条半**：① **FR-COOK-14 的通知栏与声音**——`flutter_local_notifications` **还没引**（tuna 镜像 latest 22.3.1 可取，但大版本 API 要先读源码确认），Android 清单/权限 + Web 的 Notification API 都要接，**这一路只能在真机上验收**；钩子已经留好了：`TimerBoard.tickAt` 返回「本次新到点的实例」；② **FR-PAN-04 的到期提醒**（三态高亮 R28 就做实了，缺推送时机，跟 ① 同批）；③ **FR-PAN-06 首页卡 + FR-PLAN-09 开饭前投待办**——★ ③ 里「投待办」是 FR-SET-01 的钥匙：待办根本没有落点（备菜清单是派生、不落库，见 §五 R23），所以「开饭前提醒」那枚开关现在**刻意只存在于原型**，实现不上「能打开但什么都不发生」的控件；而 **FR-PAN-06 不依赖通知**，可以单独先做，前提是先定「首页」是哪屏（App 五个标签里没有独立的「首页」）。产物 / 版本号 / push 一概没动；本轮零 schema 改动，不欠「apk + exe 同发」 |';

const ROW9 = '| R47 | 2026-09-30 | **计时内核 deadline 化 + 多计时器并行 + 悬浮球与全屏两形态 + 本机偏好 + 屏幕常亮（第一、二段，本轮未完）**（用户：「继续」——按计划书 §22.2 R47 范围自挑，先做内核再谈形态，内核不稳时接通知等于给流沙装门）。① **内核进 `shared/lib/src/timer_clock.dart`**：唯一的时间源是 `endAtMs`（目标时间戳），剩余一律 `remainingAt(nowMs)` 现算，`leftSeconds` 只是显示缓存；`timerStart/Pause/Resume/Reset/Extend/Tick/Restart` 全纯函数，`shared/test/timer_clock_test.dart` **16 例**（177→193）钉住「暂停存同一戳、加时改的是戳不是显示、续跑必须重算戳（否则切后台回来立刻跳零）、回拨不产生负剩余」。**NFR-REL-03「后台 10 分钟误差 <2 秒」从「不可能满足」变成有证据**：`timers_r47_test` 用注入的假时钟拨 10 分钟断言正好减 600 秒。② **App 侧从「sheet 里一个 `Timer?`」改成「设备生命周期的板」**：`data/timer_board.dart`（可注入 `clock/ulids/vibrate`，250ms ticker **只在有跑表时挂着**，否则 widget 测试留未完成 Timer）+ `data/timer_scope.dart`（照本项目一贯的 `InheritedWidget`，不引全局单例）+ `ui/timer_sheet.dart` 整体重写（**胶囊点击直接起表不弹层**，面板交给悬浮球点开，`timer-close-all` 关完刻意不 pop 要让人看见空态）+ `ui/timer_overlay.dart`（`OverlayEntry` 挂 navigator root，可拖、钳在安全区，`n>1` 才显 ×N）+ `ui/timer_full_page.dart`（环形进度与上一个/下一个切焦点，FR-COOK-03「切形态不丢」）。`app/test/timers_r47_test.dart` **14 例**：三个并行各自暂停加时关闭互不牵连、关一个不影响另一个。③ **`KitchenPrefs` 本机偏好**（`models.dart` + `recipe_store.dart` 的 `_loadKitchenPrefs` 已进 `_doInit`，吃 R45/R46 那条冷启动教训；落 `local_pref` 的 `kitchen_prefs` 键，scope 本机所以不同步）：`me_page.dart` 加「提醒与计时」区块，**只放做了事的 `prefs-timer-float` 与 `prefs-vibrate` 两路**；★ **FR-SET-01 刻意没上 UI**——它要的「开饭前投待办」没有落点，摆一个空转开关正是这一轮查漏补缺在清的东西。`app/test/kitchen_prefs_r47_test.dart` **8 例**（含「关悬浮窗后起表也不上屏」「偏好翻转当场听得见」「真重载读得回」）。④ **原型同步**（先原型后实现的铁律）：`S.timers/timerSeq/timerFocus` 与同一套 `endAt` 算术、`.tf-others`、`.tf-nav/.tf-idx`、`.fab-count`、`.lead-row/.lead-chip`，内部状态挂 `window.__zaoji` 供深链；两份走查全绿——`tool/proto_timers_r47_walk.cjs`（32 条）、`tool/proto_prefs_r47_walk.cjs`（17 条）。⑤ **第二段：屏幕常亮（FR-COOK-09）**——引 `wakelock_plus`（解析到 1.5.2，镜像可达），做成 `data/screen_wake.dart` 的**引用计数记账本**而不是静态调用：`cook`（做菜屏 `didChangeDependencies` 登记、`dispose` 撤手）与 `timer`（`main.dart` 跟着计时台有无跑表同步）**两路各自开合，最后一路撤掉才真的关灯**；不做计数就会出现「计时器先跑完把正在盯步骤的屏幕关了」。拨锁动作可注入（`WakeToggle`，测试区没有通道实现且要断的是命令序列），失败只咽掉记 `lastError`（常亮是体验不是数据，不该让「进入做菜模式」挂掉）；新 `WakeScope` 与 `TimerScope` 同层挂在 `MaterialApp` 之上。`app/test/wake_r47_test.dart` **10 例**，**反向验证做过**（`tool/wake_r47_mutation.cjs apply` 摘掉计数 → 2 条红 `Expected: [true] Actual: [true, false]` → `revert`）；这一段零 UI 变化所以原型不动。⑥ **基线** shared 177→**193** · server 320（未动）· app 329→**361** · analyze 三处 0；**没发行**（产物 / 版本号 / push 都没动，零改列所以不欠「apk + exe 同发」）；**本轮未完**：通知栏与声音（FR-COOK-14 剩两路）、到期提醒（FR-PAN-04）、首页卡与投待办（FR-PAN-06/FR-PLAN-09）——见 §六-20 |';

function guard(label, cond, extra) {
  if (!cond) { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); process.exit(1); }
  console.log('✔ ' + label);
}

const src = fs.readFileSync(DOC, 'utf8');
fs.writeFileSync(SNAP, src);
const lines = src.split('\n');
const cols = (l) => (l.match(/\|/g) || []).length;

const i6 = lines.findIndex((l) => l.startsWith('| 20 | **R47 第一段已完成'));
const i9 = lines.findIndex((l) => l.startsWith('| R47 | 2026-09-30 |'));
guard('§六-20 那一行找得到（且只有一行）',
  i6 >= 0 && lines.filter((l) => l.startsWith('| 20 | **R47')).length === 1, 'i6=' + i6);
guard('§九 R47 那一行找得到（且只有一行）',
  i9 >= 0 && lines.filter((l) => l.startsWith('| R47 | 2026-09-30 |')).length === 1, 'i9=' + i9);
guard('旧行是 4 个竖线（3 列）', cols(lines[i6]) === 4 && cols(lines[i9]) === 4,
  cols(lines[i6]) + '/' + cols(lines[i9]));
guard('新行也是 4 个竖线', cols(ROW6) === 4 && cols(ROW9) === 4, cols(ROW6) + '/' + cols(ROW9));
guard('新行里不再出现「wakelock 一个都没有」这类过时断言',
  !ROW6.includes('一个都没有') && !ROW9.includes('一个都没有'));
guard('新行写明了常亮已完成', ROW6.includes('FR-COOK-09') && ROW9.includes('屏幕常亮'));

const cr = lines[i6].endsWith('\r');
const out = [...lines];
out[i6] = ROW6 + (cr ? '\r' : '');
out[i9] = ROW9 + (cr ? '\r' : '');
const text = out.join('\n');
guard('行数不变（整行替换，不是插入）', out.length === lines.length, lines.length + ' -> ' + out.length);
guard('全文没有以空格开头的悬挂续行', text.split('\n').filter((l) => l.startsWith(' |')).length === 0);

fs.writeFileSync(DOC, text);
console.log('  §六-20 → 第 ' + (i6 + 1) + ' 行；§九 R47 → 第 ' + (i9 + 1) + ' 行');
console.log('  快照：' + path.relative(ROOT, SNAP));
console.log('全部通过');
