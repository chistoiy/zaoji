import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/main.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji/ui/menus_page.dart';
import 'package:zaoji/ui/recipe_detail_page.dart';
import 'package:zaoji/ui/timeline_page.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import 'fss_stub.dart';

/// R48 · 时间线（FR-LOG-01）。
///
/// 三条**决策**各有用例，都不是格式检查：
/// ① 菜单事件**没有创建时刻**（`menu` 表没这一列）→ `time` 是空串、UI 写「全天」，
///    不拿 HLC / ULID 前缀编一个钟点；
/// ② `created_at` 为空的老行（schema v7 之前入册）→ 这条事件**根本不出现**，
///    也不许猜一个日子；
/// ③ 分段过滤器必须真的改条数（只切按下态的过滤器是装饰）。
/// 另加两条账：「第 N 次」跨窗口不许变（只数窗口内就是假账），
/// 以及**日历与时间线同源**（同一批数据，两处出现的日期必须一致）。
void main() {
  setUpAll(stubSecureStorageForTest);

  // ★ 全部用**相对日期**：时间线的窗口是按"今天"往前推 90 天算的，
  //   写死 2026-09-14 那种种子过些日子就掉出窗口，变成一条永远绿不了/永远绿的假用例。
  DateTime midnight() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }
  String day(int offset) {
    final d = midnight().add(Duration(days: offset));
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  String iso(int dayOffset, String hm) => '${day(dayOffset)}T$hm:00';

  late RecipeStore store;

  Future<void> boot() async {
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
  }

  Future<void> shut() async {
    await store.dbOrNull!.close();
    store.dispose();
  }

  /// 直接造一条会话行：日期要能摆到过去，真 `startCooking` 只会写「现在」。
  /// （抄 R24 日历那套工装，同一件事不该再造第二次。）
  Future<void> seedSession(String id, String recipeId, String startedIso,
      String? finishedIso,
      {bool deleted = false}) {
    final delSql = deleted ? "'2026-09-20T00:00:00'" : 'NULL';
    final finSql = finishedIso == null ? 'NULL' : '?';
    return store.dbOrNull!.customInsert(
      'INSERT INTO cook_session (id, updated_at, updated_by, rev, deleted_at, '
      'recipe_id, started_at, finished_at, current_step, servings_used, state) '
      "VALUES (?, '000000000000-0000-node', 'node', 1, $delSql, ?, ?, $finSql, 0, NULL, NULL)",
      variables: [
        drift.Variable<String>(id),
        drift.Variable<String>(recipeId),
        drift.Variable<String>(startedIso),
        if (finishedIso != null) drift.Variable<String>(finishedIso),
      ],
    );
  }

  /// 造一条"v7 之前入册"的老行：把 created_at 打回 NULL（真机升级后就是这个形状）。
  Future<void> makeOldRecipe(String id) => store.dbOrNull!.customUpdate(
        'UPDATE recipe SET created_at = NULL WHERE id = ?',
        variables: [drift.Variable<String>(id)],
      );

  Future<Recipe> makeRecipe(String name) =>
      store.createRecipe(RecipeDraft(name: name));

  group('取数（store 层）', () {
    setUp(boot);
    tearDown(shut);

    test('★ 三类事件各来一条，且按日期倒序', () async {
      final r = await makeRecipe('时间线甲菜');
      await seedSession('c1', r.id, iso(-2, '18:00'), iso(-2, '18:20'));
      await store.createMenu(day: day(-1), meal: '晚餐', serveAt: '18:30');

      final items =
          await store.timelineEvents(fromDay: day(-90), toDay: day(1));
      final kinds = items.map((e) => e.kind).toSet();
      // 新建那道菜自己也带 created_at（今天入册），所以「菜品」必然在场。
      // 断 containsAll 而不是等号：等号会因为无关事件多一类就红、少一类也红。
      expect(kinds.containsAll({TimelineKind.cook, TimelineKind.menu}), isTrue,
          reason: '$kinds');
      final at = {for (final k in kinds) k: items.indexWhere((e) => e.kind == k)};
      expect(at[TimelineKind.recipe]!, lessThan(at[TimelineKind.menu]!),
          reason: '今天入册那条在最前');
      expect(at[TimelineKind.menu]!, lessThan(at[TimelineKind.cook]!),
          reason: '昨天的菜单在今天的菜之后、前天的做菜之前');
    });

    test('★ 菜单事件没有创建时刻：time 是空串（UI 才写得出「全天」）', () async {
      await store.createMenu(day: day(-1), meal: '午餐', serveAt: '12:00');
      final items =
          await store.timelineEvents(fromDay: day(-90), toDay: day(1));
      final m = items.singleWhere((e) => e.kind == TimelineKind.menu);
      expect(m.time, isEmpty, reason: '空串 = 没有这个事实；写成 00:00 就是编的');
      expect(timelineTimeLabel(m), '全天');
      expect(m.detail, contains('12:00 开饭'), reason: '开饭时间是有的，可以写');
    });

    test('★ created_at 为空的老菜不进「菜品」（不猜日子）', () async {
      final old = await makeRecipe('时间线老菜');
      final fresh = await makeRecipe('时间线新菜');
      await makeOldRecipe(old.id);
      await store.reload();

      final items =
          await store.timelineEvents(fromDay: day(-90), toDay: day(1));
      final added =
          items.where((e) => e.kind == TimelineKind.recipe).toList();
      expect(added.map((e) => e.title), isNot(contains('时间线老菜')),
          reason: 'v7 之前入册：不知道哪天，宁可不出现');
      expect(added.map((e) => e.title), contains('时间线新菜'));
      expect(added.single.time.length, 5, reason: '新菜有入册时刻 HH:MM');
      expect(fresh.createdAt, isNotEmpty);
    });

    test('软删的会话与餐次不进账', () async {
      final r = await makeRecipe('时间线乙菜');
      await seedSession('c1', r.id, iso(-3, '18:00'), iso(-3, '18:10'),
          deleted: true);
      await seedSession('c2', r.id, iso(-3, '12:00'), null); // 进行中不算做过
      final m = await store.createMenu(day: day(-3), meal: '晚餐');
      await store.deleteMenu(m.id);

      final items =
          await store.timelineEvents(fromDay: day(-90), toDay: day(1));
      // 那道新建的菜会产生一条「菜品」事件（它确实今天入册），
      // 要验的是软删/进行中那两条**没有**变成做菜或菜单行。
      expect(items.where((e) => e.kind != TimelineKind.recipe), isEmpty,
          reason: '软删的会话与餐次、进行中的会话都不该进账');
    });

    test('★ 「第 N 次」跨窗口稳定：只数窗口内的那几趟就是假账', () async {
      final r = await makeRecipe('时间线丙菜');
      await seedSession('c1', r.id, iso(-200, '18:00'), iso(-200, '18:10'));
      await seedSession('c2', r.id, iso(-190, '18:00'), iso(-190, '18:10'));
      await seedSession('c3', r.id, iso(-2, '18:00'), iso(-2, '18:10'));

      final near = await store.timelineEvents(
          fromDay: day(-90), toDay: day(1));
      final cook = near.singleWhere((e) => e.kind == TimelineKind.cook);
      expect(cook.detail, contains('第 3 次'),
          reason: '窗口里只有这一条，但它是这道菜的第 3 次——排名要吃全量');

      final far = await store.timelineEvents(
          fromDay: day(-210), toDay: day(1));
      final olds = far
          .where((e) => e.kind == TimelineKind.cook)
          .map((e) => '${e.day}|${e.detail}')
          .toList();
      expect(olds.firstWhere((s) => s.startsWith(day(-2))), contains('第 3 次'),
          reason: '换了窗口，同一趟的"第几次"不许变');
    });

    test('★ 与日历同源：两处出现的日期必须一模一样', () async {
      final r = await makeRecipe('时间线丁菜');
      await seedSession('c1', r.id, iso(-2, '18:00'), iso(-2, '18:20'));
      await store.createMenu(day: day(-2), meal: '晚餐');
      await makeRecipe('时间线戊菜'); // 今天入册

      final n = DateTime.now();
      final marks = await store.monthMarks(n.year, n.month);
      final items =
          await store.timelineEvents(fromDay: day(-90), toDay: day(1));
      final tlDays = items.map((e) => e.day).toSet();
      final calDays = <String>{
        ...marks.cookDays,
        ...marks.menuDays,
        ...marks.addedDays,
      };
      // 只比"本月 + 日历查的那个月"能对上的一部分：日历按月查，时间线按窗口查
      expect(tlDays.containsAll(calDays), isTrue,
          reason: '日历画了点的日子，时间线里必须有对应的行');
      expect(tlDays.where((d) => calDays.contains(d)), isNotEmpty);
    });

    test('脏 created_at（形状对但不存在的日期）也不出现', () async {
      final r = await makeRecipe('时间线己菜');
      await store.dbOrNull!.customUpdate(
        'UPDATE recipe SET created_at = ? WHERE id = ?',
        variables: [
          drift.Variable<String>('2026-13-40T10:00:00'),
          drift.Variable<String>(r.id),
        ],
      );
      await store.reload();
      final items =
          await store.timelineEvents(fromDay: day(-90), toDay: day(1));
      expect(items.where((e) => e.kind == TimelineKind.recipe), isEmpty,
          reason: '没有 13 月 40 日；认不出来就当不知道，不硬凑一个日子');
    });

    test('窗口边界：fromDay 当天算，toDay 那天不算', () async {
      final r = await makeRecipe('时间线庚菜');
      await seedSession('c1', r.id, iso(-2, '18:00'), iso(-2, '18:10'));
      final inWin = await store.timelineEvents(
          fromDay: day(-2), toDay: day(1));
      expect(inWin.where((e) => e.kind == TimelineKind.cook), hasLength(1));
      final outWin = await store.timelineEvents(
          fromDay: day(-1), toDay: day(1));
      expect(outWin.where((e) => e.kind == TimelineKind.cook), isEmpty);
    });
  });

  group('界面（从菜单页那一枚进）', () {
    Future<void> pumpApp(WidgetTester tester) async {
      tester.view.physicalSize = const Size(414, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ZaojiApp(store: store));
      await tester.pumpAndSettle();
    }

    testWidgets('★ 菜单页 appbar 那枚点得开时间线', (tester) async {
      await boot();
      await pumpApp(tester);
      await tester.tap(find.text('菜单'));
      await tester.pumpAndSettle();
      expect(find.byType(MenusPage), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('menu-timeline')));
      await tester.pumpAndSettle();
      expect(find.byType(TimelinePage), findsOneWidget);
      await shut();
    });

    testWidgets('★ 三类徽标 + 菜单那行显示「全天」', (tester) async {
      await boot();
      final r = await makeRecipe('时间线徽标菜');
      await seedSession('c1', r.id, iso(-2, '18:00'), iso(-2, '18:20'));
      await store.createMenu(day: day(-2), meal: '晚餐', serveAt: '18:30');
      await pumpApp(tester);
      await tester.tap(find.text('菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-timeline')));
      await tester.pumpAndSettle();

      expect(find.text('做菜'), findsWidgets);
      expect(find.text('菜品'), findsWidgets, reason: '新建的菜有 created_at');
      expect(find.text('全天'), findsWidgets,
          reason: '菜单事件没有时刻，那一格写「全天」（示例数据里可能不止一餐）');
      await shut();
    });

    testWidgets('★ 分段过滤器真的筛：切「菜单」后只剩菜单那些行', (tester) async {
      await boot();
      final r = await makeRecipe('时间线筛菜');
      await seedSession('c1', r.id, iso(-2, '18:00'), iso(-2, '18:20'));
      await store.createMenu(day: day(-2), meal: '晚餐');
      await pumpApp(tester);
      await tester.tap(find.text('菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-timeline')));
      await tester.pumpAndSettle();

      final all = find.byWidgetPredicate((w) =>
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('tl-cook-'));
      expect(all, findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tl-seg-menu')));
      await tester.pumpAndSettle();
      expect(
          find.byWidgetPredicate((w) =>
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith('tl-cook-')),
          findsNothing,
          reason: '筛完还有做菜行 = 过滤器是装饰');
      expect(
          find.byWidgetPredicate((w) =>
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith('tl-menu-')),
          findsOneWidget);
      await shut();
    });

    testWidgets('空态：什么都没做过时不摆假记录也不留白', (tester) async {
      await boot();
      await pumpApp(tester);
      await tester.tap(find.text('菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-timeline')));
      await tester.pumpAndSettle();
      // 示例数据里有菜（都带 created_at），所以这里验的是"切到没记录的这一类"
      await tester.tap(find.byKey(const ValueKey('tl-seg-menu')));
      await tester.pumpAndSettle();
      expect(find.text('这一类还没有记录'), findsOneWidget);
      await shut();
    });

    testWidgets('点一行跳到那道菜的详情', (tester) async {
      await boot();
      final r = await makeRecipe('时间线跳转菜');
      await seedSession('c1', r.id, iso(-2, '18:00'), iso(-2, '18:20'));
      await pumpApp(tester);
      await tester.tap(find.text('菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-timeline')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('tl-cook-${r.id}-${day(-2)}18:20')));
      await tester.pumpAndSettle();
      expect(find.byType(RecipeDetailPage), findsOneWidget);
      await shut();
    });

    testWidgets('★ 「看更早」把窗口往前推一页，120 天前那条才现身', (tester) async {
      await boot();
      final r = await makeRecipe('时间线远古菜');
      await seedSession('c1', r.id, iso(-120, '18:00'), iso(-120, '18:10'));
      await pumpApp(tester);
      await tester.tap(find.text('菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu-timeline')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('tl-day-${day(-120)}')), findsNothing,
          reason: '第一页窗口只到 90 天前');

      await tester.tap(find.byKey(const ValueKey('tl-earlier')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('tl-day-${day(-120)}')), findsOneWidget,
          reason: '推一页之后那一天的日头要出现（日头文字是 12/31 这种格式，所以按 key 找）');
      await shut();
    });
  });
}
