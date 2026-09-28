import 'package:flutter/material.dart';

import '../data/recipe_store.dart';
import '../data/store_scope.dart';
import '../models.dart';
import '../theme.dart';
import 'recipe_detail_page.dart';

/// 烹饪统计（R32 · FR-LOG-05）：这个月开火了多少、最常做谁、手报的准不准。
///
/// 三条口径钉死在这里：
/// · **本月**一切以 `cook_session.finished_at` 为准（和 R24 日历同一把尺，
///   进行中/软删的不进账）——两处数字必须对得上，不然用户第一眼就发现账是假的。
/// · **最常做榜是全家累计**（recipe.cooked_count 随同步累加，跨设备同一本账），
///   刻意不跟随月份切换——「你家最常做的菜」和「这个月做了什么」是两个问题。
/// · 校准对照只用 **自报耗时 > 0** 的菜（没报过耗时没有「准不准」可言），
///   差 >3 分钟才值得列出来（FR-REC-03 同款阈值）。
class StatsPage extends StatefulWidget {
  const StatsPage({super.key, required this.year, required this.month});

  final int year;
  final int month;

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  List<MonthSession> _sessions = const [];
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 不在 initState 里取 StoreScope（依赖 InheritedWidget 的异步要等依赖就位）；
    // 一次性闩——页面是静态月份，不需要跟 store 变化重查。
    if (!_started) {
      _started = true;
      _load();
    }
  }

  Future<void> _load() async {
    final store = StoreScope.of(context);
    final ss = await store.monthSessions(widget.year, widget.month);
    if (!mounted) return;
    setState(() => _sessions = ss);
  }

  String get _monthLabel => '${widget.year} 年 ${widget.month} 月';

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);

    // ── 本月三数：开火次数 / 几道菜 / 累计分钟 ──
    final dishes = {for (final s in _sessions) s.recipeId}.length;
    final totalMin =
        _sessions.fold<int>(0, (acc, s) => acc + s.minutes);

    // ── 最常做榜（全家累计，不随月份变）──
    final top = store.recipes
        .where((r) => r.cookedCount > 0)
        .toList()
      ..sort((a, b) => b.cookedCount.compareTo(a.cookedCount));
    final top5 = top.take(5).toList();

    // ── 热度分布：按全部有做过记录的菜分档 ──
    var justOnce = 0, few = 0, regular = 0;
    for (final r in top) {
      if (r.cookedCount == 1) {
        justOnce++;
      } else if (r.cookedCount <= 4) {
        few++;
      } else {
        regular++;
      }
    }

    // ── 校准对照：本月按菜聚合均值 vs 自报 ──
    final byRecipe = <String, List<int>>{};
    for (final s in _sessions) {
      byRecipe.putIfAbsent(s.recipeId, () => []).add(s.minutes);
    }
    final calib = <(Recipe, double)>[];
    byRecipe.forEach((id, ms) {
      final r = store.recipeById(id);
      if (r == null || r.selfTime <= 0) return;
      final avg = ms.reduce((a, b) => a + b) / ms.length;
      if ((avg - r.selfTime).abs() > 3) calib.add((r, avg));
    });
    calib.sort((a, b) =>
        (b.$2 - b.$1.selfTime).abs().compareTo((a.$2 - a.$1.selfTime).abs()));

    return Scaffold(
      backgroundColor: context.zj.paper,
      appBar: AppBar(
        title: Text('烹饪统计 · $_monthLabel'),
        backgroundColor: context.zj.paper,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
        children: [
          if (_sessions.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: Text('这个月还没有开火记录',
                    key: ValueKey('stats-empty'),
                    style: TextStyle(fontSize: 13, color: context.zj.muted)),
              ),
            )
          else
            _card(
              key: 'stats-overview',
              title: '本月',
              child: Row(
                children: [
                  _num('${_sessions.length}', '开火'),
                  _num('$dishes', '道菜'),
                  _num(totalMin >= 60
                      ? '${(totalMin / 60).floor} 时 ${totalMin % 60} 分'
                      : '$totalMin 分', '在灶前'),
                ],
              ),
            ),
          if (top5.isNotEmpty)
            _card(
              key: 'stats-top',
              title: '最常做 · 全家累计',
              child: Column(
                children: [
                  for (var i = 0; i < top5.length; i++)
                    _topRow(top5[i], i + 1),
                ],
              ),
            ),
          if (top.isNotEmpty)
            _card(
              key: 'stats-dist',
              title: '热度分布',
              child: Row(
                children: [
                  _num('$justOnce', '只做过 1 次'),
                  _num('$few', '2~4 次'),
                  _num('$regular', '5 次以上'),
                ],
              ),
            ),
          if (calib.isNotEmpty)
            _card(
              key: 'stats-calib',
              title: '耗时校准 · 本月实际 vs 自报',
              child: Column(
                children: [
                  for (final (r, avg) in calib.take(6)) _calibRow(r, avg),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _card({
    required String key,
    required String title,
    required Widget child,
  }) {
    return Container(
      key: ValueKey(key),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: context.zj.surface,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(color: context.zj.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: context.zj.muted)),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _num(String value, String label) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: ZaojiText.displayOf(context, 
                  fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(label,
              style:
                  TextStyle(fontSize: 11.5, color: context.zj.muted)),
        ],
      ),
    );
  }

  Widget _topRow(Recipe r, int rank) {
    final last =
        r.lastCooked.length >= 10 ? r.lastCooked.substring(5, 10) : '';
    return InkWell(
      key: ValueKey('stats-top-${r.id}'),
      borderRadius: BorderRadius.circular(8),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => RecipeDetailPage(recipe: r))),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
        child: Row(
          children: [
            SizedBox(
              width: 22,
              child: Text('$rank',
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: context.zj.accent)),
            ),
            Expanded(
              child: Text(r.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600)),
            ),
            if (last.isNotEmpty)
              Text(last,
                  style: TextStyle(
                      fontSize: 11.5, color: context.zj.muted)),
            const SizedBox(width: 8),
            Text('${r.cookedCount} 次',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: context.zj.ink)),
          ],
        ),
      ),
    );
  }

  Widget _calibRow(Recipe r, double avg) {
    final diff = avg - r.selfTime;
    final abs = diff.abs();
    return Padding(
      key: ValueKey('stats-calib-${r.id}'),
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(r.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          Text('自报 ${r.selfTime} 分 · 实际 ${avg.round()} 分',
              style: TextStyle(
                  fontSize: 12, color: context.zj.muted)),
          const SizedBox(width: 8),
          Text(diff > 0 ? '慢 ${abs.round()} 分' : '快 ${abs.round()} 分',
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: diff > 0
                      ? context.zj.accent
                      : context.zj.tagMethod)),
        ],
      ),
    );
  }
}
