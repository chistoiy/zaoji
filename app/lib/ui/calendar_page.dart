import 'package:flutter/material.dart';

import '../data/recipe_store.dart';
import '../data/store_scope.dart';
import '../theme.dart';
import 'menu_detail_page.dart';
import 'recipe_detail_page.dart';

/// 日历（R24）：做过什么、排了什么，一眼看全。
///
/// 点只有两种：做过菜（cook_session 完成记录）与排了菜单（menu.day）。
/// 刻意没有「新增菜品」第三种点——recipe 表没有创建时间列，
/// 用 updated_at 猜会漂；要它得先给 schema 加列，单独开轮次。
class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  late DateTime _focus = DateTime.now();
  late String _selected = _iso(DateTime.now());

  MonthMarks _marks = const MonthMarks.empty();
  List<CookEvent> _events = const [];

  static String _iso(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  RecipeStore? _listenedStore;

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

  bool _busy = false;

  Future<void> _refresh() async {
    final store = StoreScope.of(context);
    if (_busy) return;
    _busy = true;
    final marks = await store.monthMarks(_focus.year, _focus.month);
    final events = await store.cookEventsOn(_selected);
    _busy = false;
    if (!mounted) return;
    setState(() {
      _marks = marks;
      _events = events;
    });
  }

  void _shiftMonth(int delta) {
    setState(() {
      _focus = DateTime(_focus.year, _focus.month + delta, 1);
    });
    _refresh();
  }

  void _selectDay(String day) {
    setState(() => _selected = day);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final todayIso = _iso(DateTime.now());
    final selMenus = store.menus.where((m) => m.day == _selected).toList();

    return Scaffold(
      backgroundColor: ZaojiColors.paper,
      appBar: AppBar(
        title: const Text('日历'),
        backgroundColor: ZaojiColors.paper,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 32),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_focus.year} 年 ${_focus.month} 月',
                  key: const ValueKey('cal-month'),
                  style: ZaojiText.display(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                '本月开火 ${_marks.cookCount} 次',
                style: const TextStyle(
                    fontSize: 12, color: ZaojiColors.muted),
              ),
              IconButton(
                key: const ValueKey('cal-prev'),
                icon: const Icon(Icons.chevron_left),
                onPressed: () => _shiftMonth(-1),
              ),
              IconButton(
                key: const ValueKey('cal-next'),
                icon: const Icon(Icons.chevron_right),
                onPressed: () => _shiftMonth(1),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _grid(store, todayIso),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              _Dot(Color(0xFFB2491C), '做过菜品'),
              SizedBox(width: 16),
              _Dot(Color(0xFF2A5F6B), '菜单安排'),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            _selected == todayIso
                ? '今天 · ${_events.length + selMenus.length} 条记录'
                : '${_selected.substring(5).replaceAll('-', '/')} · '
                    '${_events.length + selMenus.length} 条记录',
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: ZaojiColors.ink2),
          ),
          const SizedBox(height: 8),
          for (final m in selMenus) _menuCard(store, m),
          for (final e in _events) _cookRow(store, e),
          if (selMenus.isEmpty && _events.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 26),
              child: Center(
                child: Text('这一天还没有记录\n做了菜或排了菜单，都会自动落到这里',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12.5,
                        height: 1.7,
                        color: ZaojiColors.muted)),
              ),
            ),
        ],
      ),
    );
  }

  Widget _grid(RecipeStore store, String todayIso) {
    final first = DateTime(_focus.year, _focus.month, 1);
    final startWd = first.weekday - 1; // 周一开局
    final cells = <Widget>[];
    for (var i = 0; i < 6; i++) {
      for (var w = 0; w < 7; w++) {
        final idx = i * 7 + w;
        final d = DateTime(
            _focus.year, _focus.month, 1 - startWd + idx);
        final iso = _iso(d);
        final inMonth = d.month == _focus.month;
        final hasCook = _marks.cookDays.contains(iso);
        final hasMenu = _marks.menuDays.contains(iso);
        cells.add(
          InkWell(
            key: ValueKey('cal-$iso'),
            customBorder: const CircleBorder(),
            onTap: () => _selectDay(iso),
            child: Container(
              margin: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                color: iso == _selected
                    ? const Color(0x14D2491C)
                    : null,
                shape: BoxShape.circle,
                border: iso == todayIso
                    ? Border.all(color: ZaojiColors.accent, width: 1.4)
                    : null,
              ),
              child: SizedBox(
                height: 42,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '${d.day}',
                      style: TextStyle(
                        fontSize: 13.5,
                        color: inMonth
                            ? ZaojiColors.ink
                            : ZaojiColors.muted.withValues(alpha: .5),
                        fontWeight: iso == todayIso
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (hasCook)
                          const _MiniDot(Color(0xFFB2491C)),
                        if (hasMenu)
                          const _MiniDot(Color(0xFF2A5F6B)),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
    }
    return Column(
      children: [
        Row(
          children: [
            for (final w in const ['一', '二', '三', '四', '五', '六', '日'])
              Expanded(
                child: Text(w,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 11, color: ZaojiColors.muted)),
              ),
          ],
        ),
        const SizedBox(height: 4),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 0.82,
          children: cells,
        ),
      ],
    );
  }

  Widget _menuCard(RecipeStore store, MenuPlan m) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(ZaojiRadius.md),
      child: InkWell(
        key: ValueKey('cal-menu-${m.id}'),
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => MenuDetailPage(menuId: m.id))),
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(ZaojiRadius.md),
            border: Border.all(color: ZaojiColors.lineSoft),
          ),
          child: Row(
            children: [
              const Icon(Icons.event_available,
                  size: 18, color: Color(0xFF2A5F6B)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${m.meal} · ${m.recipeIds.length} 道菜',
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600),
                ),
              ),
              if (m.serveAt.isNotEmpty)
                Text(m.serveAt,
                    style: const TextStyle(
                        fontSize: 12, color: ZaojiColors.muted)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cookRow(RecipeStore store, CookEvent e) {
    final recipe = store.recipeById(e.recipeId);
    return InkWell(
      key: ValueKey('cal-cook-${e.time}-${e.recipeId}'),
      borderRadius: BorderRadius.circular(ZaojiRadius.md),
      onTap: recipe == null
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => RecipeDetailPage(recipe: recipe))),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(ZaojiRadius.md),
          border: Border.all(color: ZaojiColors.lineSoft),
        ),
        child: Row(
          children: [
            Text(e.time,
                style: const TextStyle(
                    fontSize: 12.5,
                    color: ZaojiColors.muted,
                    fontFeatures: [FontFeature.tabularFigures()])),
            const SizedBox(width: 10),
            Expanded(
              child: Text(e.recipeName,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600)),
            ),
            Text('${e.minutes} 分钟',
                style:
                    const TextStyle(fontSize: 12, color: ZaojiColors.muted)),
          ],
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot(this.color, this.label);
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _MiniDot(color),
        const SizedBox(width: 5),
        Text(label,
            style:
                const TextStyle(fontSize: 11.5, color: ZaojiColors.muted)),
      ],
    );
  }
}

class _MiniDot extends StatelessWidget {
  const _MiniDot(this.color);
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }
}
