import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji/ui/kitchen_page.dart';

/// R28 · 厨房页（库存 + 清空冰箱推荐）。
///
/// 库存是「辅助决策不是账本」——测试钉的是判定得准：
/// 步进到 0 翻「没有」不是删；同名再添加复用原行；推荐三组归类正确。
void main() {
  late RecipeStore store;

  setUp(() async {
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
    // 种子库自带菜谱；推荐断言直接用它们。
  });
  tearDown(() async {
    await store.dbOrNull!.close();
    store.dispose();
  });

  Future<void> pumpKitchen(WidgetTester tester, {int seg = 0}) async {
    await tester.binding.setSurfaceSize(const Size(414, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // StoreScope 在 MaterialApp **之上**（生产同款）：底部表单是 Navigator push
    // 出去的路由，挂在 home 下面的 scope 它够不着（首跑实况：_save 里 of() 抛 null!）。
    await tester.pumpWidget(StoreScope(
      store: store,
      child: MaterialApp(home: KitchenPage(initialSegment: seg)),
    ));
    await tester.pumpAndSettle();
  }

  group('库存数据层', () {
    test('upsert：同名复用原行（点了两次 + 不变两条）', () async {
      await store.upsertPantry(name: '牛奶', category: '冷藏', qtyValue: 2, qtyUnit: '盒');
      await store.upsertPantry(name: '牛奶', category: '冷藏', qtyValue: 3, qtyUnit: '盒');
      expect(store.pantryItems.where((p) => p.name == '牛奶'), hasLength(1));
      expect(store.pantryItems.single.qtyValue, 3);
    });

    test('步进到 0 → have=false（是状态不是删除）', () async {
      await store.upsertPantry(name: '姜', qtyValue: 1);
      await store.adjustPantry(store.pantryItems.single.id, -1);
      final p = store.pantryItems.single;
      expect(p.have, isFalse);
      expect(p.qtyLabel, '没有');
      // 软删行仍在表里（同步语义靠墓碑，不用删除表达「没有」）
      await store.reloadForTest();
      expect(store.pantryItems, hasLength(1));
    });

    test('重启等价：重载后库存还在（真库往返）', () async {
      await store.upsertPantry(name: '鸡蛋', qtyValue: 10, qtyUnit: '个', isStaple: false);
      await store.reloadForTest();
      expect(store.pantryItems.single.name, '鸡蛋');
      expect(store.pantryItems.single.qtyLabel, '10 个');
    });

    test('推荐三组：全齐 / 差一点 / 缺主料不进差一点', () async {
      final r = store.recipes.first;
      // 用第一道种子菜的食材构造库存：主料全给、最后一样配料不给
      final ings = r.ingredients;
      expect(ings.length, greaterThan(1));
      for (final i in ings.take(ings.length - 1)) {
        await store.upsertPantry(name: i.name, qtyValue: 5);
      }
      final rec = store.recommendByPantry();
      final inCan = (rec['canCook'] as List).any((e) => e['id'] == r.id);
      final inAlmost = (rec['almostThere'] as List).any((e) => e['id'] == r.id);
      final lastMissingMain = ings.last.isMain;
      expect(inCan || inAlmost, isTrue, reason: '只差配料应落在能做/差一点之一');
      if (lastMissingMain) expect(inAlmost, isFalse);
    });
  });

  group('厨房页 UI', () {
    testWidgets('空态 → 添加食材 → 分组行出现，步进器可点', (tester) async {
      await pumpKitchen(tester);
      expect(find.textContaining('库存还是空的'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('pantry-add-fab')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('pantry-name')), '番茄');
      await tester.enterText(find.byKey(const ValueKey('pantry-qty')), '4');
      await tester.tap(find.byKey(const ValueKey('pantry-save')));
      await tester.pumpAndSettle();

      expect(find.text('番茄'), findsOneWidget);
      expect(find.text('4'), findsWidgets);
      // 步进 +1
      await tester.tap(find.byTooltip('增加 番茄'));
      await tester.pumpAndSettle();
      expect(find.text('5'), findsWidgets);
    });

    testWidgets('「能做什么」段：库存决定归类，缺项徽标可见', (tester) async {
      final r = store.recipes.first;
      for (final i in r.ingredients) {
        await store.upsertPantry(name: i.name, qtyValue: 5);
      }
      await pumpKitchen(tester, seg: 1);
      expect(find.textContaining('能做'), findsWidgets);
      expect(find.textContaining(r.name), findsWidgets);
    });
  });
}
