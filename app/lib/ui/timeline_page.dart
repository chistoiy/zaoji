import 'package:flutter/material.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import '../data/recipe_store.dart';
import '../data/store_scope.dart';
import '../theme.dart';
import 'calendar_page.dart';
import 'menu_detail_page.dart';
import 'recipe_detail_page.dart';

/// 时间线（R48 · FR-LOG-01）：这台家里的灶什么时候开过火，倒着翻。
///
/// ## 为什么单独一屏，而不是并进日历
///
/// 日历回答的是「那一天有什么」（按月看），时间线回答的是「最近发生过什么」
/// （按时间流看，不用先选月份）。两屏吃的是**同一批事件**——
/// 取数在 [RecipeStore.timelineEvents]，排序/分组/过滤/「没有的时刻」在
/// `shared/lib/src/timeline.dart`，两屏各自只换一种排法，不各写一份口径。
///
/// ## 两条"宁可少画"的口径（原型与实现同一份）
///
/// · **菜单事件没有时刻**：`menu` 表只有 `day / meal / serve_at`，没有创建时刻列。
///   那一行的时间位显示「全天」，不拿 HLC 或 ULID 前缀编一个钟点出来。
/// · **`created_at` 为空的老菜不进「菜品」**：schema v7 之前建的菜没有这个事实，
///   不出现，也不猜一个日子——猜出来的那一天在时间线上是个假记录。
class TimelinePage extends StatefulWidget {
  const TimelinePage({super.key});

  @override
  State<TimelinePage> createState() => _TimelinePageState();
}

class _TimelinePageState extends State<TimelinePage> {
  /// 一页 90 天。家庭规模一个月几十条，一次 90 天正好是"一个季度在灶上"的量。
  static const int _windowDays = 90;

  /// null = 全部。分段过滤器切的是数据源，不是按钮样式。
  TimelineKind? _kind;
  int _pages = 1;
  List<TimelineItem> _items = const [];
  String _today = '';

  RecipeStore? _listenedStore;
  bool _busy = false;

  static String _iso(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = StoreScope.of(context);
    if (_listenedStore != store) {
      _listenedStore?.removeListener(_refresh);
      store.addListener(_refresh);
      _listenedStore = store;
    }
    _refresh();
  }

  @override
  void dispose() {
    _listenedStore?.removeListener(_refresh);
    super.dispose();
  }

  /// 与日历页同一个"一次性闩"写法：store 每次通知都要重查，
  /// 但查询没回来之前再通知一次不该叠第二趟。
  Future<void> _refresh() async {
    if (_busy) return;
    _busy = true;
    final store = StoreScope.of(context);
    final now = DateTime.now();
    final midnight = DateTime(now.year, now.month, now.day);
    final today = _iso(midnight);
    final toDay = _iso(midnight.add(const Duration(days: 1)));
    final fromDay = _iso(midnight
        .subtract(Duration(days: _windowDays * _pages - 1)));
    final items = await store.timelineEvents(fromDay: fromDay, toDay: toDay);
    _busy = false;
    if (!mounted) return;
    setState(() {
      _items = items;
      _today = today;
    });
  }

  /// 当前过滤器下的分组结果（排序与分组都在 shared 里，这里不重复实现）。
  List<TimelineDay> get _days =>
      timelineGrouped(timelineFiltered(_items, kind: _kind));

  @override
  Widget build(BuildContext context) {
    final shown = _days.fold<int>(0, (a, d) => a + d.items.length);
    return Scaffold(
      backgroundColor: context.zj.paper,
      appBar: AppBar(
        title: const Text('时间线'),
        backgroundColor: context.zj.paper,
        actions: [
          // 原型这里是一条反向链到日历：同一批事件的两种看法，跳来跳去不该退到主页
          IconButton(
            key: const ValueKey('tl-open-calendar'),
            tooltip: '日历',
            icon: const Icon(Icons.calendar_month_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const CalendarPage())),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<String>(
                  key: const ValueKey('tl-filter'),
                  segments: [
                    // 「全部」+ 三类的说法都取自 shared 那份 timelineKindLabel，
                    // 徽标与过滤器共用一套字，不在两处各写一遍
                    const ButtonSegment(value: 'all', label: Text('全部')),
                    for (final k in TimelineKind.values)
                      ButtonSegment(
                        value: k.name,
                        // key 挂在 label 上（`ButtonSegment` 自己没有 key 参数）：
                        // 页面上「菜单」这两个字会出现三次（底部标签、这一段、行上徽标），
                        // 测试按文字点必然撞。
                        label: Text(timelineKindLabel(k),
                            key: ValueKey('tl-seg-${k.name}')),
                      ),
                  ],
                  selected: {
                    _kind?.name ?? 'all',
                  },
                  showSelectedIcon: false,
                  style: SegmentedButton.styleFrom(
                    selectedBackgroundColor: context.zj.accentSoft,
                    selectedForegroundColor: context.zj.accentDeep,
                  ),
                  onSelectionChanged: (s) => setState(
                      () => _kind = timelineKindOf(s.first)),
                ),
              ),
            ),
            Expanded(
              child: shown == 0
                  ? _empty()
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      itemCount: _days.length,
                      itemBuilder: (context, i) => _dayGroup(_days[i]),
                    ),
            ),
            // ★ 「看更早」在空窗口里也要点得到：整段历史都比这一页更早的人，
            //   第一屏必然什么都没有——把按钮藏在"有数据才出现"后面，他就永远翻不到。
            _earlier(),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Text(
        _kind == null ? '还没有记录' : '这一类还没有记录',
        style: TextStyle(fontSize: 12.5, color: context.zj.muted),
      ),
    );
  }

  Widget _earlier() {
    return Align(
      alignment: Alignment.center,
      child: TextButton(
        key: const ValueKey('tl-earlier'),
        onPressed: () {
          // 窗口整体往前推一页：不是"追加"，所以 _pages 变了要重查
          setState(() => _pages++);
          _refresh();
        },
        child: const Text('看更早'),
      ),
    );
  }

  Widget _dayGroup(TimelineDay d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 14, 2, 6),
          child: Row(
            children: [
              Text(
                timelineDayLabel(d.day, today: _today),
                key: ValueKey('tl-day-${d.day}'),
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: context.zj.muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        for (final e in d.items) _row(e),
      ],
    );
  }

  Widget _row(TimelineItem e) {
    return InkWell(
      key: ValueKey('tl-${e.kind.name}-${e.refId}-${e.day}${e.time}'),
      borderRadius: BorderRadius.circular(ZaojiRadius.md),
      onTap: () => _open(e),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Rail(kind: e.kind),
            const SizedBox(width: 10),
            SizedBox(
              // ★ 菜单事件没有时刻 → 「全天」占同一格，行首不会因此错位
              width: 40,
              child: Text(
                timelineTimeLabel(e),
                style: TextStyle(
                  fontSize: 12,
                  color: context.zj.muted,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          e.title,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 13.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _KindBadge(kind: e.kind),
                    ],
                  ),
                  if (e.detail.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      e.detail,
                      style:
                          TextStyle(fontSize: 12, color: context.zj.muted),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 点一行回到那件事的现场：菜做过的进菜谱详情，菜单进那一餐，新菜进菜谱详情。
  void _open(TimelineItem e) {
    final store = StoreScope.of(context);
    final nav = Navigator.of(context);
    if (e.kind == TimelineKind.menu) {
      final id = e.refId;
      if (id == null) return;
      nav.push(MaterialPageRoute(
          builder: (_) => MenuDetailPage(menuId: id)));
      return;
    }
    final id = e.refId;
    if (id == null) return;
    final recipe = store.recipeById(id);
    if (recipe == null) return; // 菜被删了：这一行还留着（那是发生过的事实），但没有可去的地方
    nav.push(MaterialPageRoute(
        builder: (_) => RecipeDetailPage(recipe: recipe)));
  }
}

/// 左侧那条竖线 + 一个点。形状与日历格子里那三个点**同一套语言**
/// （FR-LOG-02 色盲友好：做菜实心圆 / 菜单空心圆 / 菜品方块）。
class _Rail extends StatelessWidget {
  const _Rail({required this.kind});

  final TimelineKind kind;

  @override
  Widget build(BuildContext context) {
    final color = switch (kind) {
      TimelineKind.cook => context.zj.accent,
      TimelineKind.menu => context.zj.tagMethod,
      TimelineKind.recipe => context.zj.ok,
    };
    return SizedBox(
      width: 16,
      child: Stack(
        alignment: Alignment.topCenter,
        children: [
          // 每一行自己画一段通高竖线，拼起来就是一条连续的时间轴
          Positioned(
            top: 0,
            bottom: 0,
            child: SizedBox(
              width: 1,
              child: ColoredBox(color: context.zj.line),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: kind == TimelineKind.menu
                    ? context.zj.paper
                    : color,
                border: kind == TimelineKind.menu
                    ? Border.all(color: color, width: 1.6)
                    : null,
                shape: kind == TimelineKind.recipe
                    ? BoxShape.rectangle
                    : BoxShape.circle,
                borderRadius:
                    kind == TimelineKind.recipe ? BorderRadius.circular(2) : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 类型徽标（字取自 shared 的 [timelineKindLabel]）。
class _KindBadge extends StatelessWidget {
  const _KindBadge({required this.kind});

  final TimelineKind kind;

  @override
  Widget build(BuildContext context) {
    final color = switch (kind) {
      TimelineKind.cook => context.zj.accent,
      TimelineKind.menu => context.zj.tagMethod,
      TimelineKind.recipe => context.zj.ok,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        timelineKindLabel(kind),
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }
}
