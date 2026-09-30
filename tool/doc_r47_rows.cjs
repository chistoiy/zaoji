// R47 划账：往交接文档 §六 与 §九 各插一行表格。
//
// 为什么用脚本而不是 Edit：这两处都是**表格中间插行**，
// 用「下一行的行首」当锚点会把它吞成悬挂续行（用户级记忆里连栽过两次）。
// 脚本按行首前缀定位整行，在后面追加，并当场校验：
//   · 命中恰好 1 次；
//   · 新增行的列数与表头一致（3 列 = 4 个竖线）；
//   · 全文不出现以空格开头的悬挂续行；
//   · 文件只变长不变短。
// 用法：node tool/doc_r47_rows.cjs
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const DOC = path.join(ROOT, '灶记-交接文档.md');
const SNAP = path.join(ROOT, 'dist', 'handover_before_r47_rows.md');

const ROW6 = '| 20 | **R47 第一段已完成（2026-09-30，本轮未完）** | ✅ **计时内核 deadline 化 + 多计时器并行 + 悬浮球与全屏两形态 + `KitchenPrefs` 本机偏好**（FR-COOK-03/04/05、FR-SET-02、FR-SET-03 的震动这一路、NFR-REL-03）：落地细节、反漂移证据与 11 颗坑分别见 §五 R47 与 §7.10。**基线** shared **193**（177→193）· server 320（未动）· app **351**（329→351）· analyze 三处 0。**R47 还欠三条**：① **FR-COOK-09 常亮 + FR-COOK-14 通知栏与声音**——`wakelock_plus`（latest 1.8.0）与 `flutter_local_notifications`（latest 22.3.1）已实测在 tuna 镜像可取（`curl -sL .../dart-pub/api/packages/<name>` 回 200 带 JSON），**但依赖没引、Android 清单没动**，通知这一路要真机验收，当前计时结束只有震动与视觉；② **FR-PAN-04 的「到期提醒」**（三态高亮 R28 就做实了，缺的是推送时机，跟 ① 同批）；③ **FR-PAN-06 首页「即将过期 / 快没了」卡 + FR-PLAN-09 开饭前投待办**——★ ③ 是 FR-SET-01 的钥匙：待办根本没有落点（备菜清单是派生、不落库，见 §五 R23），所以「开饭前提醒」那枚开关现在**刻意只存在于原型**，实现不上「能打开但什么都不发生」的控件。产物 / 版本号 / push 一概没动；本轮零 schema 改动，不欠「apk + exe 同发」 |';

const ROW9 = '| R47 | 2026-09-30 | **计时内核 deadline 化 + 多计时器并行 + 悬浮球与全屏两形态 + 本机偏好（第一段，本轮未完）**（用户：「继续」——按计划书 §22.2 R47 范围自挑，先做内核再谈形态，内核不稳时接通知等于给流沙装门）。① **内核进 `shared/lib/src/timer_clock.dart`**：唯一的时间源是 `endAtMs`（目标时间戳），剩余一律 `remainingAt(nowMs)` 现算，`leftSeconds` 只是显示缓存；`timerStart/Pause/Resume/Reset/Extend/Tick/Restart` 全纯函数，`shared/test/timer_clock_test.dart` **16 例**（177→193）钉住「暂停存同一戳、加时改的是戳不是显示、续跑必须重算戳（否则切后台回来立刻跳零）、回拨不产生负剩余」。**NFR-REL-03「后台 10 分钟误差 <2 秒」从「不可能满足」变成有证据**：`timers_r47_test` 用注入的假时钟拨 10 分钟断言正好减 600 秒。② **App 侧从「sheet 里一个 `Timer?`」改成「设备生命周期的板」**：`data/timer_board.dart`（可注入 `clock/ulids/vibrate`，250ms ticker **只在有跑表时挂着**，否则 widget 测试留未完成 Timer）+ `data/timer_scope.dart`（照本项目一贯的 `InheritedWidget`，不引全局单例）+ `ui/timer_sheet.dart` 整体重写（**胶囊点击直接起表不弹层**，面板交给悬浮球点开，`timer-close-all` 关完刻意不 pop 要让人看见空态）+ `ui/timer_overlay.dart`（`OverlayEntry` 挂 navigator root，可拖、钳在安全区，`n>1` 才显 ×N）+ `ui/timer_full_page.dart`（环形进度与上一个/下一个切焦点，FR-COOK-03「切形态不丢」）。`app/test/timers_r47_test.dart` **14 例**：三个并行各自暂停加时关闭互不牵连、关一个不影响另一个。③ **`KitchenPrefs` 本机偏好**（`models.dart` + `recipe_store.dart` 的 `_loadKitchenPrefs` 已进 `_doInit`，吃 R45/R46 那条冷启动教训；落 `local_pref` 的 `kitchen_prefs` 键，scope 本机所以不同步）：`me_page.dart` 加「提醒与计时」区块，**只放做了事的 `prefs-timer-float` 与 `prefs-vibrate` 两路**；★ **FR-SET-01 刻意没上 UI**——它要的「开饭前投待办」没有落点，摆一个空转开关正是这一轮查漏补缺在清的东西。`app/test/kitchen_prefs_r47_test.dart` **8 例**（含「关悬浮窗后起表也不上屏，不是看得见点不动的假关闭」「偏好翻转当场听得见」「真重载读得回」）。④ **原型同步**（先原型后实现的铁律）：`S.timers/timerSeq/timerFocus` 与同一套 `endAt` 算术、`.tf-others` 其他计时器列表、`.tf-nav/.tf-idx` 位序与上下一个、`.fab-count` 徽标、`.lead-row/.lead-chip` 就地档位，内部状态挂 `window.__zaoji` 供深链；两份走查全绿——`tool/proto_timers_r47_walk.cjs`（32 条，含拨表反漂移与三并行）、`tool/proto_prefs_r47_walk.cjs`（17 条，含「翻开关真的改状态、文案跟着变」「刷新回默认，原型不假装持久」）。⑤ **基线** shared 177→**193** · server 320（未动）· app 329→**351** · analyze 三处 0；**没发行**（产物 / 版本号 / push 都没动，零改列所以不欠「apk + exe 同发」）；**本轮未完**：常亮与通知栏（FR-COOK-09/14）、到期提醒（FR-PAN-04）、首页卡与投待办（FR-PAN-06/FR-PLAN-09）——见 §六-20 |';

function guard(label, cond, extra) {
  if (!cond) {
    console.error('✘ ' + label + (extra ? '  [' + extra + ']' : ''));
    process.exit(1);
  }
  console.log('✔ ' + label);
}

const src = fs.readFileSync(DOC, 'utf8');
fs.writeFileSync(SNAP, src);

const lines = src.split('\n');
const cols = (l) => (l.match(/\|/g) || []).length;

// §六：锚在 19 那一行整行
const i19 = lines.findIndex((l) => l.startsWith('| 19 | **R46 已完成'));
guard('§六 找到锚行「| 19 | **R46 已完成」恰好一次',
  i19 >= 0 && lines.filter((l) => l.startsWith('| 19 | **R46 已完成')).length === 1,
  'i19=' + i19);
guard('§六 锚行列数与表头一致（4 个竖线）', cols(lines[i19]) === 4, 'cols=' + cols(lines[i19]));

// §九：锚在 R46 那一行整行
const j46 = lines.findIndex((l) => l.startsWith('| R46 | 2026-09-29 |'));
guard('§九 找到锚行「| R46 | 2026-09-29 |」恰好一次',
  j46 >= 0 && lines.filter((l) => l.startsWith('| R46 | 2026-09-29 |')).length === 1,
  'j46=' + j46);
guard('§九 锚行列数 4', cols(lines[j46]) === 4, 'cols=' + cols(lines[j46]));

guard('待插入两行的列数也是 4', cols(ROW6) === 4 && cols(ROW9) === 4,
  cols(ROW6) + '/' + cols(ROW9));

// 先插靠后的那条，索引才不会错位
const out = [...lines];
// 本仓库的 md 有 CRLF 的（原型那类），插入行要跟锚行同一个行尾
const cr = lines[i19].endsWith('\r') || lines[j46].endsWith('\r');
guard('行尾判定：' + (cr ? 'CRLF' : 'LF'), true);
const row6 = ROW6 + (cr ? '\r' : '');
const row9 = ROW9 + (cr ? '\r' : '');
out.splice(j46 + 1, 0, row9);
out.splice(i19 + 1, 0, row6);

const dangling = out.filter((l) => l.startsWith(' |') || l.startsWith('| 20 |  ') );
guard('全文没有以空格开头的悬挂续行', dangling.length === 0, 'n=' + dangling.length);

const text = out.join('\n');
guard('文件只变长', text.length > src.length, src.length + ' -> ' + text.length);
guard('两行各只出现一次',
  text.split('\n').filter((l) => l.startsWith('| 20 | **R47 第一段已完成')).length === 1 &&
  text.split('\n').filter((l) => l.startsWith('| R47 | 2026-09-30 |')).length === 1);

fs.writeFileSync(DOC, text);
console.log('  §六 第 ' + (i19 + 2) + ' 行插了 20；§九 第 ' + (j46 + 2) + ' 行插了 R47');
console.log('  快照：' + path.relative(ROOT, SNAP));
console.log('全部通过');
