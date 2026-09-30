/// R48 · 时间线（FR-LOG-01）：**事件的排序、分组、过滤与"没有的时刻"怎么显示**。
///
/// 放 shared 的理由与 `timer_clock.dart`、`nutrition_math.dart` 同一条：
/// Android 与 Web 是两份编译产物，「时间线怎么排、哪些事件算有时刻」各写一遍必然会漂。
/// App 侧只负责**取数**（三张表各查一次），拿到行之后全部交给这里。
///
/// 三条硬口径（都是"宁可少画，不画假的"）：
/// ① **菜单事件没有时刻**。`menu` 表只有 `day / meal / serve_at`，没有创建时刻列，
///    所以那一行只能到"哪一天"，时间位显示「全天」——
///    ★ 不拿 `updated_at` 或行 id 的 ULID 前缀倒推一个钟点出来，那是编的。
/// ② **`created_at` 为空 = 不知道哪天入的册**，这条事件直接不出现（schema v7 之前的老菜）。
///    日历上也不画那个点。"没有这条记录"和"有记录但不知道日期"在 UI 上必须同一种表现。
/// ③ 排序是**日期倒序 + 同日按时刻倒序 + 无时刻的那条落在那天最后**；
///    同刻的两条保持取数顺序——Dart 的 `List.sort` 不稳定，所以这里显式按原序 tie-break，
///    否则同一秒做的两道菜会在两次刷新之间互换位置。
library;

/// 时间线里的三类事件。与日历的三种点是同一套语言（实心圆 / 空心圆 / 方块）。
enum TimelineKind { cook, menu, recipe }

/// 字符串 → 类型；认不出来是 `null`（调用方据此跳过，不猜成某一类）。
TimelineKind? timelineKindOf(String s) => switch (s) {
      'cook' => TimelineKind.cook,
      'menu' => TimelineKind.menu,
      'recipe' => TimelineKind.recipe,
      _ => null,
    };

/// 界面上那三个字的说法（徽标与过滤器共用一份，别在两处各写一遍）。
String timelineKindLabel(TimelineKind k) => switch (k) {
      TimelineKind.cook => '做菜',
      TimelineKind.menu => '菜单',
      TimelineKind.recipe => '菜品',
    };

/// 一条时间线事件。
///
/// [time] 为**空串**表示"这一条没有时刻这个事实"（菜单事件就是），
/// 不是"00:00"——那是另一个意思，而且会被排序当成那天最早的一条。
class TimelineItem {
  const TimelineItem({
    required this.day,
    required this.kind,
    required this.title,
    this.time = '',
    this.detail = '',
    this.refId,
  });

  /// YYYY-MM-DD。
  final String day;

  /// HH:MM；空串 = 没有时刻（见 [timelineTimeLabel]）。
  final String time;

  final TimelineKind kind;

  /// 主行文字（菜名 / 餐次名）。
  final String title;

  /// 次行文字（耗时、第几次、几道菜……）。
  final String detail;

  /// 跳回原记录用的 id（recipeId / menuId）。
  final String? refId;
}

/// 时间位上显示什么：没有时刻写「全天」，而不是留白——
/// 留白会让那一行看起来像被截断了。
String timelineTimeLabel(TimelineItem item) =>
    item.time.isEmpty ? '全天' : item.time;

/// 日期头的文字：今天那一组写「今天」，其余写 `09/17`。
///
/// [today] 由调用方给（App 给本机当天，测试钉死），**这里不读 `DateTime.now()`**——
/// 纯函数里藏一个"现在"就没法做真重载回归了。
String timelineDayLabel(String day, {String? today}) {
  if (today != null && day == today) return '今天';
  if (day.length < 10) return day;
  return '${day.substring(5, 7)}/${day.substring(8, 10)}';
}

/// ISO8601 原文（或 `YYYY-MM-DD`）→ 日期串。
///
/// ★ 脏值、空串、长度不够一律 `null`，**不猜**：
/// `recipe.created_at` 在 v7 之前没有这一列，老行是 NULL；
/// 拿 `updated_at` 或 ULID 前缀补一个日子，日历与时间线上就会多出一个没发生过的日期。
String? timelineDayOf(String raw) {
  if (raw.length < 10) return null;
  final d = raw.substring(0, 10);
  final ok = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(d);
  if (!ok) return null;
  // 月份/日子越界也当不知道（`2026-13-99` 形状对但没这个日子）
  final mo = int.tryParse(d.substring(5, 7)) ?? 0;
  final dd = int.tryParse(d.substring(8, 10)) ?? 0;
  if (mo < 1 || mo > 12 || dd < 1 || dd > 31) return null;
  return d;
}

/// ISO8601 原文 → `HH:MM`；拿不到就是空串（= 没有时刻，见 [timelineTimeLabel]）。
String timelineTimeOf(String raw) {
  if (raw.length < 16) return '';
  final t = raw.substring(11, 16);
  return RegExp(r'^\d{2}:\d{2}$').hasMatch(t) ? t : '';
}

/// 排序：**日期倒序 → 同日按时刻倒序 → 无时刻的落在那天最后 → 同刻保持原序**。
///
/// Dart 的 `List.sort` 不稳定，所以这里先把原序号带上做 tie-break。
/// 不这么做的话，同一分钟里做的两道菜会在两次刷新之间互换位置——用户会觉得列表在抖。
List<TimelineItem> timelineSorted(List<TimelineItem> items) {
  final decorated = [
    for (var i = 0; i < items.length; i++) (items[i], i),
  ];
  decorated.sort((a, b) {
    final byDay = b.$1.day.compareTo(a.$1.day); // 日期倒序
    if (byDay != 0) return byDay;
    final at = a.$1.time, bt = b.$1.time;
    if (at.isEmpty != bt.isEmpty) return at.isEmpty ? 1 : -1; // 无时刻排那天最后
    final byTime = bt.compareTo(at); // 时刻倒序
    if (byTime != 0) return byTime;
    return a.$2.compareTo(b.$2); // 同刻：保持取数顺序
  });
  return [for (final (item, _) in decorated) item];
}

/// 按类型筛（[kind] 为 null = 全部）。分段过滤器吃的就是这个，
/// ★ 过滤器必须真的改条数——只切按下态不筛数据是装饰。
List<TimelineItem> timelineFiltered(List<TimelineItem> items, {TimelineKind? kind}) {
  if (kind == null) return timelineSorted(items);
  return timelineSorted(items.where((e) => e.kind == kind).toList());
}

/// 一天一组（顺序沿用传入顺序，因此先 [timelineSorted] 再分组才保序）。
class TimelineDay {
  const TimelineDay({required this.day, required this.items});

  final String day;
  final List<TimelineItem> items;
}

/// 按天分组，组间顺序 = 第一次出现的那条的顺序（倒序列表 → 新的一天在前）。
List<TimelineDay> timelineGrouped(List<TimelineItem> sorted) {
  final order = <String>[];
  final bucket = <String, List<TimelineItem>>{};
  for (final e in sorted) {
    if (!bucket.containsKey(e.day)) {
      bucket[e.day] = [];
      order.add(e.day);
    }
    bucket[e.day]!.add(e);
  }
  return [
    for (final d in order)
      TimelineDay(day: d, items: bucket[d]!),
  ];
}

/// 日历的点与时间线的行**同出一源**：从这批事件推出「哪天有哪几类」。
/// 日历页将来也应改吃这个（本轮先让时间线用它；日历那条在 §7.10 记为待收口）。
Map<String, List<TimelineKind>> timelineMarks(List<TimelineItem> items) {
  final out = <String, List<TimelineKind>>{};
  for (final e in items) {
    final list = out.putIfAbsent(e.day, () => <TimelineKind>[]);
    if (!list.contains(e.kind)) list.add(e.kind);
  }
  for (final list in out.values) {
    list.sort((a, b) => a.name.compareTo(b.name));
  }
  return out;
}
