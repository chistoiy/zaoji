import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji/ui/calendar_page.dart';
import 'package:zaoji/ui/kitchen_page.dart';

/// R39 · schema v7 在客户端的落点（FR-PAN-01 库存三态 + FR-LOG-01 入册时间）。
///
/// 钉的是几件"升级那天会出事"的事：
///   · have 与 stock_status 必须**成对写**——旧 apk 只认 have，
///     不带它走，那台设备上的库存会永远停在旧值；
///   · 步进器不许把「快没了」悄悄洗成「充足」（那是用户手标的判断）；
///   · created_at 只在新建那一刻写一次，之后编辑多少次都不该动；
///   · 日历的第三种点只认有 created_at 的行——**老菜谱不画假日子**。
void main() {
  late RecipeStore store;

  setUp(() async {
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
  });
  tearDown(() async {
    await store.dbOrNull!.close();
    store.dispose();
  });

  Future<Map<String, Object?>> rowOf(String id) async {
    final r = await store.dbOrNull!
        .customSelect("SELECT * FROM pantry_item WHERE id = '$id'")
        .get();
    return r.single.data;
  }

  group('库存三态（FR-PAN-01）', () {
    test('标 low：stock_status=low，同时 have 仍是 1（旧端看得见"有"）', () async {
      await store.upsertPantry(name: '小葱', status: PantryStock.low);
      final p = store.pantryItems.single;
      await store.reloadForTest();
      final row = await rowOf(p.id);
      expect(row['stock_status'], 'low');
      expect(row['have'], 1);
      expect(store.pantryItems.single.status, PantryStock.low);
      expect(store.pantryItems.single.have, isTrue,
          reason: '"快没了"在家还是有的，推荐算法不能把它当缺项');
    });

    test('标 none：两列一起翻', () async {
      await store.upsertPantry(name: '冰糖', status: PantryStock.none);
      final row = await rowOf(store.pantryItems.single.id);
      expect(row['stock_status'], 'none');
      expect(row['have'], 0);
    });

    test('步进到 0 → none；再加回来 → have（但不会自己变回 low）', () async {
      await store.upsertPantry(name: '姜', qtyValue: 1);
      final id = store.pantryItems.single.id;
      await store.adjustPantry(id, -1);
      expect(store.pantryItems.single.status, PantryStock.none);
      await store.adjustPantry(id, 1);
      expect(store.pantryItems.single.status, PantryStock.have);
    });

    test('★ 步进器不碰 low：低是人的判断，不是数量算出来的', () async {
      await store.upsertPantry(name: '生抽', status: PantryStock.low, qtyValue: 1);
      final id = store.pantryItems.single.id;
      await store.adjustPantry(id, 1);
      final p = store.pantryItems.single;
      expect(p.qtyValue, 2);
      expect(p.status, PantryStock.have,
          reason: '加了一格就回"充足"——这一条不钉住，用户就不敢标 low 了');
    });

    test('存储位置 / 购入日期 / 备注 三列可空，且真往返', () async {
      await store.upsertPantry(
        name: '五花肉',
        storage: '冷冻',
        boughtAt: '2026-09-06',
        note: '给宝的那份少盐',
      );
      await store.reloadForTest();
      final p = store.pantryItems.single;
      expect(p.storage, '冷冻');
      expect(p.boughtAt, '2026-09-06');
      expect(p.note, '给宝的那份少盐');

      await store.upsertPantry(
          id: p.id, name: p.name, storage: null, boughtAt: null, note: null);
      expect(store.pantryItems.single.storage, isNull,
          reason: '清空要真的清空，不能停在旧值上');
    });

    test('同名再添加不丢三态（复用原行时把现值带上）', () async {
      await store.upsertPantry(name: '鸡蛋', status: PantryStock.low, qtyValue: 3);
      await store.upsertPantry(name: '鸡蛋', qtyValue: 10);
      expect(store.pantryItems, hasLength(1));
      expect(store.pantryItems.single.status, PantryStock.low,
          reason: '没传 status = 保持原值，不是"重置成充足"');
    });

    testWidgets('库存表上三态 chips 在位，点「快没了」立即落库', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await store.upsertPantry(name: '基围虾', qtyValue: 1);
      await tester.pumpWidget(StoreScope(
        store: store,
        child: const MaterialApp(home: KitchenPage(initialSegment: 0)),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('基围虾').first);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('pantry-status')), findsOneWidget);
      expect(find.text('充足'), findsOneWidget);
      expect(find.text('快没了'), findsOneWidget);
      await tester.tap(find.text('快没了'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pantry-save')));
      await tester.pumpAndSettle();
      expect(store.pantryItems.single.status, PantryStock.low);
    });

    testWidgets('表单上有存储位置与备注入口（FR-PAN-01 的另外三列）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 2200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await store.upsertPantry(name: '龙口粉丝');
      await tester.pumpWidget(StoreScope(
        store: store,
        child: const MaterialApp(home: KitchenPage(initialSegment: 0)),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('龙口粉丝').first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('pantry-storage')), findsOneWidget);
      expect(find.byKey(const ValueKey('pantry-note')), findsOneWidget);
      expect(find.byKey(const ValueKey('pantry-bought')), findsOneWidget);
      expect(find.text('家里有'), findsNothing,
          reason: '那个开关已经被三态 chips 取代了');
    });
  });

  group('入册时间（FR-LOG-01）', () {
    Future<String> create(String name) async {
      return (await store.createRecipe(RecipeDraft(name: name, sub: '')))
          .id;
    }

    test('新建即有 created_at，编辑不会动它', () async {
      final id = await create('葱油拌面');
      final first = store.recipeById(id)!.createdAt;
      expect(first.length, greaterThanOrEqualTo(10));
      await store.updateRecipe(
          id, const RecipeDraft(name: '葱油拌面（改了名）', steps: ['面煮熟']));
      await store.reloadForTest();
      final again = store.recipeById(id)!.createdAt;
      expect(again, first, reason: '改了名字不该改了它是什么时候来的');
    });

    test('日历：新建那天多一个点，点开了有「新增菜品」那一行', () async {
      final id = await create('蒜蓉粉丝蒸虾');
      final now = DateTime.now();
      final day = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final marks = await store.monthMarks(now.year, now.month);
      expect(marks.addedDays, contains(day));
      final added = await store.addedRecipesOn(day);
      expect(added.map((e) => e.recipeId), contains(id));
    });

    test('老行（created_at 为 NULL）不进日历：不画一个没发生过的日子', () async {
      final id = await create('蚝油生菜');
      await store.dbOrNull!.customStatement(
          'UPDATE recipe SET created_at = NULL WHERE id = \'$id\'');
      await store.reloadForTest();
      final now = DateTime.now();
      expect((await store.monthMarks(now.year, now.month)).addedDays, isEmpty);
      final day = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      expect(await store.addedRecipesOn(day), isEmpty);
      expect(store.recipeById(id)!.createdAt, '',
          reason: '模型层用空串表示"不知道"，不是拿今天凑数');
    });

    testWidgets('日历页图例有三种点', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await store.createRecipe(RecipeDraft(name: '银耳莲子羹', sub: ''));
      await tester.pumpWidget(StoreScope(
        store: store,
        child: const MaterialApp(home: CalendarPage()),
      ));
      await tester.pumpAndSettle();
      expect(find.text('做过菜品'), findsOneWidget);
      expect(find.text('菜单安排'), findsOneWidget);
      expect(find.text('新增菜品'), findsWidgets);
    });
  });
}
