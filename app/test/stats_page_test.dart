import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji/ui/calendar_page.dart';
import 'package:zaoji/ui/stats_page.dart';

/// R32 · 烹饪统计页（FR-LOG-05）。
///
/// 日期全部相对「今天」——统计挂在当月，测试不赌系统时钟落在哪个月。
/// 最常做榜读的是种子数据就有的 cooked_count（全家累计口径），
/// 本月三数与校准卡读 seed 进 cook_session 的完成行。
void main() {
  late RecipeStore store;
  final now = DateTime.now();
  final todayIso =
      '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

  setUp(() async {
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
  });

  tearDown(() async {
    await store.dbOrNull!.close();
    store.dispose();
  });

  Future<void> pumpCalendar(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(540, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(StoreScope(
      store: store,
      child: const MaterialApp(home: CalendarPage()),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> seedSession(
      String id, String recipeId, String startedIso, String finishedIso) {
    return store.dbOrNull!.customInsert(
      'INSERT INTO cook_session (id, updated_at, updated_by, rev, deleted_at, '
      'recipe_id, started_at, finished_at, current_step, servings_used, state) '
      "VALUES (?, '000000000000-0000-node', 'node', 1, NULL, ?, ?, ?, 0, NULL, NULL)",
      variables: <drift.Variable<Object>>[
        drift.Variable<String>(id),
        drift.Variable<String>(recipeId),
        drift.Variable<String>(startedIso),
        drift.Variable<String>(finishedIso),
      ],
    );
  }

  Future<Recipe> makeRecipe(String name, {int selfTime = 0}) =>
      store.createRecipe(RecipeDraft(name: name, selfTime: selfTime));

  testWidgets('日历顶栏 → 统计页：本月三数与最常做同屏', (tester) async {
    final r = await makeRecipe('葱油拌面');
    await seedSession(
        's1', r.id, '${todayIso}T18:05:00', '${todayIso}T18:19:00');
    await pumpCalendar(tester);

    await tester.tap(find.byKey(const ValueKey('cal-stats')));
    await tester.pumpAndSettle();

    expect(find.byType(StatsPage), findsOneWidget);
    expect(find.text('烹饪统计 · ${now.year} 年 ${now.month} 月'), findsOneWidget);
    // 本月：开火 1 次 / 1 道菜 / 14 分钟（种子菜没有本月会话，不进本月账）。
    // 「1」不限定范围会撞上榜单名次，descendant 锁在概览卡内。
    final overview = find.byKey(const ValueKey('stats-overview'));
    expect(overview, findsOneWidget);
    expect(find.descendant(of: overview, matching: find.text('开火')), findsOneWidget);
    expect(find.descendant(of: overview, matching: find.text('道菜')), findsOneWidget);
    expect(find.descendant(of: overview, matching: find.text('1')), findsNWidgets(2));
    expect(find.text('14 分'), findsOneWidget);
    // 最常做榜（全家累计）：种子的番茄炒蛋 23 次挂在种子名下。
    expect(find.byKey(const ValueKey('stats-top')), findsOneWidget);
  });

  testWidgets('★ 校准卡：自报 10 分、实际 30 分 → 列出「慢 20 分」', (tester) async {
    final r = await makeRecipe('耗时校准菜', selfTime: 10);
    await seedSession(
        'c1', r.id, '${todayIso}T18:00:00', '${todayIso}T18:30:00');
    await pumpCalendar(tester);
    await tester.tap(find.byKey(const ValueKey('cal-stats')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('stats-calib')), findsOneWidget);
    expect(find.byKey(ValueKey('stats-calib-${r.id}')), findsOneWidget);
    expect(find.text('自报 10 分 · 实际 30 分'), findsOneWidget);
    expect(find.text('慢 20 分'), findsOneWidget);
  });

  testWidgets('差 ≤3 分钟不进校准卡；自报 0 不参与', (tester) async {
    final near = await makeRecipe('报得挺准', selfTime: 20);
    final blind = await makeRecipe('从没报过耗时');
    await seedSession(
        'n1', near.id, '${todayIso}T18:00:00', '${todayIso}T18:22:00');
    await seedSession(
        'n2', blind.id, '${todayIso}T19:00:00', '${todayIso}T19:50:00');
    await pumpCalendar(tester);
    await tester.tap(find.byKey(const ValueKey('cal-stats')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('stats-calib')), findsNothing);
    expect(find.text('慢 30 分'), findsNothing);
  });

  testWidgets('翻到没有记录的月份 → 空态而不是报错', (tester) async {
    await pumpCalendar(tester);
    await tester.tap(find.byKey(const ValueKey('cal-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cal-stats')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('stats-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('stats-overview')), findsNothing);
  });

  testWidgets('点榜单行进菜谱详情', (tester) async {
    await pumpCalendar(tester);
    await tester.tap(find.byKey(const ValueKey('cal-stats')));
    await tester.pumpAndSettle();

    final top = store.recipes.firstWhere((r) => r.cookedCount > 0);
    await tester.ensureVisible(find.byKey(ValueKey('stats-top-${top.id}')));
    await tester.tap(find.byKey(ValueKey('stats-top-${top.id}')));
    await tester.pumpAndSettle();
    // 换屏到详情页（渲染由 calendar_page_test 同款路径钉过），统计页让位。
    expect(find.byType(StatsPage), findsNothing);
  });
}
