import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji/ui/kitchen_page.dart';

/// R30 · 购物清单闭环：加购去重 → 勾选 → 购物入库变库存。
/// 清单是集合不是流水：同名第二次加必须是 0 新增，否则买菜会被同一根葱刷屏。
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

  Future<void> pumpKitchen(WidgetTester tester, {int seg = 2}) async {
    await tester.binding.setSurfaceSize(const Size(414, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(StoreScope(
      store: store,
      child: MaterialApp(home: KitchenPage(initialSegment: seg)),
    ));
    await tester.pumpAndSettle();
  }

  group('数据层', () {
    test('同名去重 + 勾选 + 入库一条龙', () async {
      final n1 = await store.addShoppingItems([
        (name: '番茄', qtyText: '2个', recipeId: null),
        (name: '鸡蛋', qtyText: null, recipeId: null),
      ], source: 'reco');
      expect(n1, 2);
      final n2 = await store.addShoppingItems([
        (name: '番茄', qtyText: '5个', recipeId: null),
      ]);
      expect(n2, 0, reason: '同名再加不重复成行（清单是集合）');
      expect(store.shoppingItems.length, 2);

      final tomato = store.shoppingItems.firstWhere((x) => x.name == '番茄');
      await store.toggleShoppingBought(tomato.id, true);
      expect(store.shoppingItems.firstWhere((x) => x.name == '番茄').bought,
          isTrue);

      final stocked = await store.stockInBoughtShopping();
      expect(stocked, 1);
      // 入库后：库存多了番茄（qty 从「2个」解析成 2/个），清单只剩鸡蛋
      expect(store.pantryItems.map((p) => p.name), contains('番茄'));
      final pan = store.pantryItems.firstWhere((p) => p.name == '番茄');
      expect(pan.qtyValue, 2);
      expect(pan.qtyUnit, '个');
      expect(store.shoppingItems.map((x) => x.name), ['鸡蛋']);

      // 重启等价：入库与删除都随重载保持
      await store.reloadForTest();
      expect(store.pantryItems.map((p) => p.name), contains('番茄'));
      expect(store.shoppingItems.map((x) => x.name), ['鸡蛋']);
    });

    test('移除是软删（同步要看到消失）', () async {
      await store.addShoppingItems([(name: '葱', qtyText: null, recipeId: null)]);
      final id = store.shoppingItems.single.id;
      await store.removeShopping(id);
      expect(store.shoppingItems, isEmpty);
      final logged = await store.dbOrNull!
          .customSelect('SELECT deleted_at FROM shopping_item')
          .get();
      expect(
          logged.any((r) => r.read<String?>('deleted_at') != null), isTrue,
          reason: '墓碑在——别的设备会同步到这次删除');
    });
  });

  group('厨房页第三段', () {
    testWidgets('空态文案 → 手动加一行 → 勾选入库', (tester) async {
      await pumpKitchen(tester);
      expect(find.textContaining('购物清单是空的'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('shopping-add-fab')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.byKey(const ValueKey('shopping-name')), '五花肉');
      await tester.enterText(
          find.byWidgetPredicate(
              (w) => w is TextField && w.decoration?.labelText?.contains('要多少') == true),
          '500g');
      await tester.tap(find.byKey(const ValueKey('shopping-save')));
      await tester.pumpAndSettle();
      expect(find.textContaining('五花肉'), findsWidgets);

      await tester.pumpAndSettle();
      // 没勾选前按钮不该存在（boughtCount=0 时整行隐藏）——
      // 这里不能用 tap：找不到元素的 tap 直接抛（首跑实况），断言用 find 就够
      expect(find.byKey(const ValueKey('shopping-stockin')), findsNothing);

      // 勾上 → 入库按钮现身 → 点它 → 库存有五花肉、清单清空
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('shopping-stockin')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('shopping-stockin')));
      await tester.pumpAndSettle();
      expect(find.textContaining('已入库 1 样'), findsOneWidget);
      expect(store.shoppingItems, isEmpty);
      expect(store.pantryItems.map((p) => p.name), contains('五花肉'));
    });
  });
}
