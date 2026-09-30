import '../models.dart';
import 'recipe_store.dart';
import 'timer_alert.dart';

/// 开饭前把当餐的备菜与制作投进待办（R47 第六段 · FR-PLAN-09 + FR-SET-01）。
///
/// ## 「投待办」投的是通知，不是新表
///
/// 需求原文要「自动把『食材准备』『菜品制作』推送进待办」。**待办不建表**是用户拍定的方向：
/// 备菜清单本来就是派生的（R23：不落库、勾选是本机备菜板），
/// 建 `plan_task` 就是改列轮，要付「apk 与 exe 必须同发」那笔硬账，
/// 换来的只是一份能跨设备留痕、能勾选的清单——而勾选态在 R23 已经决定不跨设备。
/// 所以这一路的落点是**一条通知**：告诉你「这餐现在该动手了，去备菜板看清单」，
/// 摘要与设置页那一行吃同一个纯函数（[digestOfMenu]），两处各写一遍必然漂成两种说法。
///
/// ## 触发点是「打开 App / 回前台」，不是后台排程
///
/// 与 [PantryWatch]（`pantry_watch.dart`）同一条立场：这台设备上没有后台进程，
/// 要「人不在 App 里也准点弹」得走系统级排程（Android 精确闹钟 + APNs），那是 M3 的架构账。
/// 这里的口径是：**开饭前那一刻你正好拿着手机，它就一定投得出去**。
///
/// ## 一次只投最早的一餐
///
/// 一个窗口里可能同时有两餐（提前量调到 3 小时、而两餐挨着）。
/// 投两条就是让用户在通知栏里排两道菜的序——那是 R50 时间轴排程的活。
/// 这里只投**开饭时间最早、且今天还没投过**的那一餐；投过的那一餐不再占位，
/// 所以第一餐投完，下一餐到自己窗口时会顶上来。
///
/// ## 静默、id 固定
///
/// `sound: false` 与 [PantryWatch] 同一理由：这是「有空看一眼」，响的应该是灶上的计时器。
/// id 固定一条（[noticeIdMeal]）：重复提醒是**覆盖**而不是堆叠。
/// ★ **号段**：库存占 1、2，开饭提醒占 100，计时器一律 ≥ [TimerAlert.timerIdFloor]（1000）。
/// 三段互不重叠，否则一条横幅会把另一条顶掉（同 id 系统当同一条替换）。
///
/// ## 「今天这餐投过了」要落本机，而且**被闸门挡掉时不落**
///
/// 去重戳是 `YYYY-MM-DD#餐名`（不是只按天）：一天有早中晚三餐，
/// 只按天的话提醒过早餐就把晚餐的机会也吃掉了。落 `local_pref`（本机作息，同 ⑦ 口径、不进同步流）。
/// 没授权或被本机开关关掉时**不许**写「今天投过了」——否则用户当场点完授权，
/// 这一餐反而永远不会被提醒，那是这条最隐蔽的自毁（§7.10 记过一次）。
class MealReminderWatch {
  MealReminderWatch({
    required List<MenuPlan> Function() menus,
    required MealDigest Function(MenuPlan menu) digestOf,
    required TimerAlert alert,
    required bool Function() enabled,
    required int Function() leadMinutes,
    required bool Function(String key) alreadyNotified,
    required Future<void> Function(String key) markNotified,
    DateTime Function()? clock,
  })  : _menus = menus,
        _digestOf = digestOf,
        _alert = alert,
        _enabled = enabled,
        _leadMinutes = leadMinutes,
        _alreadyNotified = alreadyNotified,
        _markNotified = markNotified,
        _clock = clock ?? _systemClock;

  static DateTime _systemClock() => DateTime.now();

  /// 开饭前提醒的固定通知 id：**100**，在库存（1、2）与计时器（≥1000）两段之间。
  static const int noticeIdMeal = 100;

  /// 去重戳的键：`YYYY-MM-DD#餐名`。日期在前，跨天自动失效（旧键不会再被匹配上）。
  static String keyOf(MenuPlan m) => '${m.day}#${m.meal}';

  final List<MenuPlan> Function() _menus;
  final MealDigest Function(MenuPlan) _digestOf;
  final TimerAlert _alert;
  final bool Function() _enabled;
  final int Function() _leadMinutes;
  final bool Function(String key) _alreadyNotified;
  final Future<void> Function(String key) _markNotified;
  final DateTime Function() _clock;

  /// 本轮扫到的「今天可投的餐次」数（取证读它，别去猜通知发没发）。
  int lastEligible = 0;

  /// 这一趟真投出去几条：0 可能是「开关关了」「今天没有定了开饭时间的餐次」
  /// 「还没进窗口」「这一餐投过」「没授权」——都该静默，不抛。
  Future<int> checkAndNotify() async {
    if (!_enabled()) return 0;
    final now = _clock();
    final lead = _leadMinutes().clamp(KitchenPrefs.minLead, KitchenPrefs.maxLead);
    lastEligible = _menus().where((m) => mealTodoEligible(m, now)).length;

    // 候选：在窗口里 + 今天这一餐还没投过 + 真的排了菜。
    // 没排菜的（摘要会是「还没排菜」）不投——一条写着「还没排菜」的待办就是垃圾。
    final due = <({MenuPlan menu, MealDigest digest, Duration left})>[];
    for (final m in _menus()) {
      final left = mealLeadLeft(m, now, lead: lead);
      if (left == null || _alreadyNotified(keyOf(m))) continue;
      final d = _digestOf(m);
      if (d.isEmpty) continue;
      due.add((menu: m, digest: d, left: left));
    }
    if (due.isEmpty) return 0;
    due.sort((a, b) => mealServeTime(a.menu)!.compareTo(mealServeTime(b.menu)!));
    final pick = due.first;
    final leftMin = (pick.left.inSeconds / 60).ceil();

    final n = await _alert.send([
      AlertNotice(
        id: noticeIdMeal,
        title: '${pick.menu.serveAt} ${pick.menu.meal} · 还剩 $leftMin 分钟开饭',
        body: pick.digest.summary,
        sound: false,
      ),
    ]);
    // 只有真发出去才落戳（理由见类头注）。
    if (n > 0) await _markNotified(keyOf(pick.menu));
    return n;
  }
}

/// 一餐要投出去的那份摘要（**设置页那一行与通知正文共用同一个 [summary]**）。
class MealDigest {
  const MealDigest({
    required this.dishNames,
    required this.ingredientCount,
    required this.stepCount,
  });

  /// 菜名，按菜单里的顺序。
  final List<String> dishNames;

  /// 备菜样数：**归并之后**的条数（同名与同义词算一样，与备菜清单同一个口径）。
  final int ingredientCount;

  /// 制作步骤总数。
  final int stepCount;

  bool get isEmpty => dishNames.isEmpty;

  /// 「3 道菜 · 备菜 13 样 · 步骤 12 步」；没排菜就说「还没排菜」。
  /// 用词与原型逐字对齐（原型是这一行的规格）。
  String get summary => isEmpty
      ? '还没排菜'
      : '${dishNames.length} 道菜 · 备菜 $ingredientCount 样 · 步骤 $stepCount 步';
}

/// 从 store 现算一餐的摘要（派生、不落库——所以菜单一改、菜一删，这行当场跟着变）。
MealDigest digestOfMenu(RecipeStore store, MenuPlan m) {
  final dishes = [
    for (final id in m.recipeIds) store.recipeById(id),
  ].whereType<Recipe>().toList();
  return MealDigest(
    dishNames: dishes.map((r) => r.name).toList(),
    // 归并后的条数才是「要备几样」，不是各道菜食材数相加。
    ingredientCount: store.mergeForPrep(m.recipeIds).length,
    stepCount: dishes.fold(0, (a, r) => a + r.steps.length),
  );
}

/// 开饭时刻。`serveAt` 是 `''`（没定时间）或形状不对 → null，**不猜**。
DateTime? mealServeTime(MenuPlan m) {
  final d = DateTime.tryParse(m.day);
  final t = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(m.serveAt);
  if (d == null || t == null) return null;
  final hh = int.tryParse(t.group(1)!);
  final mm = int.tryParse(t.group(2)!);
  if (hh == null || mm == null || hh > 23 || mm > 59) return null;
  return DateTime(d.year, d.month, d.day, hh, mm);
}

/// 「今天 + 定了开饭时间」= 这一餐是待投对象。
/// 菜还没排也算可投目标（设置页要如实显示「还没排菜」），但真投递要等 [digestOf] 有内容。
bool mealTodoEligible(MenuPlan m, DateTime now) {
  if (m.day != mealDay(now)) return false;
  return mealServeTime(m) != null;
}

/// 现在离这餐开饭还有多久、且**在提前量窗口里**才返回时长；否则 null。
///
/// 窗口是 `(开饭 - lead, 开饭)`：过了开饭点再投就没意义了（饭都上桌了）。
/// 按秒比而不是按分钟比：`17:59:30` 打开 App 也是「开饭前」，
/// 用 `inMinutes` 会在最后一分钟里出现一个谁都解释不了的缝。
Duration? mealLeadLeft(MenuPlan m, DateTime now, {required int lead}) {
  final serve = mealServeTime(m);
  if (serve == null) return null;
  if (m.day != mealDay(now)) return null;
  final leftSec = serve.difference(now).inSeconds;
  if (leftSec <= 0) return null;
  if (leftSec > lead * 60) return null;
  return Duration(seconds: leftSec);
}

/// 自然日戳（`YYYY-MM-DD`），与去重键里的日期同一格式。
String mealDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// 提前量的显示文本（`90 → 1.5 小时`、`30 → 30 分钟`、`120 → 2 小时`）。
/// 与原型 `leadLabel` 同一套规则，也是设置页副文案与档位 chip 唯一的口径。
String mealLeadLabel(int minutes) {
  if (minutes < 60) return '$minutes 分钟';
  final h = minutes / 60;
  return minutes % 60 == 0 ? '${h.toInt()} 小时' : '${h.toStringAsFixed(1)} 小时';
}

/// 「今天没有定了开饭时间的餐次」——开关开着但一趟都投不出去时，
/// 设置页要如实说出原因，而不是挂一枚什么都不发生的开关（本轮在清的那类假控件）。
const String kMealNoTargetText = '今天没有定了开饭时间的餐次';
