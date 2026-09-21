import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji/ui/calendar_page.dart';
import 'package:zaoji/ui/menu_detail_page.dart';
import 'package:zaoji/ui/recipe_detail_page.dart';

String _iso(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// R24 · 日历页的页面行为。
///
/// 全部走今天的相对日期：测试不赌系统时钟落在哪个月，
/// 「今天」在页面里就是默认选中日，标记、记录、空态都挂在它周围。
void main() {
  late RecipeStore store;
  final now = DateTime.now();
  final todayIso = _iso(now);

  setUp(() async {
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
  });

  tearDown(() async {
    await store.dbOrNull!.close();
    store.dispose();
  });

  // StoreScope 必须挂在 MaterialApp **之上**（和生产 main.dart 同构）——
  // 挂 home 下面的话 push 出去的详情页落在 scope 外，静默失败（R23 §7.1）。
  // 画布给到 540×2000：六行月历在近一屏高，默认 800×600 下
  // 图例和当日面板在 ListView 折叠区外根本不会构建（R20 的教训）。
  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(540, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(StoreScope(
      store: store,
      child: const MaterialApp(home: CalendarPage()),
    ));
    await tester.pumpAndSettle();
  }

  /// 直接把会话摆到「今天」的某一小时——真 startCooking 只会写现在，
  /// 而耗时断言要精确的分秒。SQL 与 calendar_store_test 同款。
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

  Future<Recipe> makeRecipe(String name) =>
      store.createRecipe(RecipeDraft(name: name));

  testWidgets('首屏：当月标题、两色图例，今天默认选中且是空态', (tester) async {
    await pump(tester);
    expect(find.text('${now.year} 年 ${now.month} 月'), findsOneWidget);
    expect(find.text('做过菜品'), findsOneWidget);
    expect(find.text('菜单安排'), findsOneWidget);
    expect(find.byKey(ValueKey('cal-$todayIso')), findsOneWidget);
    expect(find.textContaining('这一天还没有记录'), findsOneWidget);
    expect(find.text('0 条记录'), findsNothing); // 记录数与「今天」前缀同行
    expect(find.textContaining('今天 · 0 条记录'), findsOneWidget);
  });

  testWidgets('翻月：标题跟着走，开火数只数当月', (tester) async {
    final r = await makeRecipe('葱油拌面');
    await seedSession(
        's1', r.id, '${todayIso}T18:05:00', '${todayIso}T18:19:00');

    await pump(tester);
    expect(find.text('本月开火 1 次'), findsOneWidget);

    final next = DateTime(now.year, now.month + 1);
    await tester.tap(find.byKey(const ValueKey('cal-next')));
    await tester.pumpAndSettle();
    expect(find.text('${next.year} 年 ${next.month} 月'), findsOneWidget);
    expect(find.text('本月开火 0 次'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('cal-prev')));
    await tester.pumpAndSettle();
    expect(find.text('${now.year} 年 ${now.month} 月'), findsOneWidget);
    expect(find.text('本月开火 1 次'), findsOneWidget);
  });

  testWidgets('当天有记录：做菜行带时刻和耗时，菜单卡带道数', (tester) async {
    final r = await makeRecipe('番茄炒蛋');
    await seedSession(
        's1', r.id, '${todayIso}T18:05:00', '${todayIso}T18:19:00');
    final m = await store.createMenu(day: todayIso, meal: '晚餐', serveAt: '18:30');
    await store.addDish(m.id, r.id);

    await pump(tester);
    expect(find.textContaining('今天 · 2 条记录'), findsOneWidget);
    expect(find.byKey(ValueKey('cal-cook-18:19-${r.id}')), findsOneWidget);
    expect(find.text('18:19'), findsOneWidget);
    expect(find.text('14 分钟'), findsOneWidget);
    expect(find.byKey(ValueKey('cal-menu-${m.id}')), findsOneWidget);
    expect(find.text('晚餐 · 1 道菜'), findsOneWidget);
    expect(find.text('18:30'), findsOneWidget);
  });

  testWidgets('点菜单卡进菜单详情', (tester) async {
    final m = await store.createMenu(day: todayIso, meal: '晚餐');
    await pump(tester);

    await tester.ensureVisible(find.byKey(ValueKey('cal-menu-${m.id}')));
    await tester.tap(find.byKey(ValueKey('cal-menu-${m.id}')));
    await tester.pumpAndSettle();
    expect(find.byType(MenuDetailPage), findsOneWidget);
  });

  testWidgets('点做菜行进菜谱详情', (tester) async {
    final r = await makeRecipe('蚝油生菜');
    await seedSession(
        's1', r.id, '${todayIso}T19:40:00', '${todayIso}T19:47:00');
    await pump(tester);

    await tester.ensureVisible(find.byKey(ValueKey('cal-cook-19:47-${r.id}')));
    await tester.tap(find.byKey(ValueKey('cal-cook-19:47-${r.id}')));
    await tester.pumpAndSettle();
    expect(find.byType(RecipeDetailPage), findsOneWidget);
  });

  testWidgets('换选一个没有记录的日子 → 回到空态', (tester) async {
    final other = DateTime(now.year, now.month, now.day == 1 ? 2 : 1);
    await pump(tester);

    final otherIso = _iso(other);
    await tester.ensureVisible(find.byKey(ValueKey('cal-$otherIso')));
    await tester.tap(find.byKey(ValueKey('cal-$otherIso')));
    await tester.pumpAndSettle();

    expect(find.textContaining('这一天还没有记录'), findsOneWidget);
    expect(
        find.textContaining(
            '${otherIso.substring(5).replaceAll('-', '/')} · 0 条记录'),
        findsOneWidget);
  });
}
