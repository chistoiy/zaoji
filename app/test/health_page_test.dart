import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/ui/health_page.dart';
import 'package:zaoji/ui/kitchen_page.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// R33 · 数据体检页：排版、跳转、改完账自动跟上。
///
/// 判定逻辑在 health_test.dart 用假时钟钉死；这里走真 now——
/// 种子数据不带过期库存、菜谱都完整，所以默认库应当是「账本没有要紧的事」，
/// 问题全靠测试自己造。时间断言全部相对 now（禁写死日期，防爆时间炸弹）。
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

  Future<void> pump(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(540, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(StoreScope(
      store: store,
      child: const MaterialApp(home: HealthPage()),
    ));
    await tester.pumpAndSettle();
  }

  /// 过期日 = 昨天（相对 now）。
  final yesterday =
      DateTime.now().subtract(const Duration(days: 1)).toIso8601String().substring(0, 10);

  /// 把清单项的 HLC 物理段搬到 n 天前 → 过 14 天积压线。
  Future<void> ageShopping(String name, int days) async {
    final id = store.shoppingItems.firstWhere((s) => s.name == name).id;
    final hlc = Hlc.now('node',
            wallMs: DateTime.now().subtract(Duration(days: days)).millisecondsSinceEpoch)
        .encode();
    await store.dbOrNull!.customUpdate(
      'UPDATE shopping_item SET updated_at = ? WHERE id = ?',
      variables: [drift.Variable<String>(hlc), drift.Variable<String>(id)],
    );
    await store.reloadForTest();
  }

  testWidgets('空账本 → 「账本没有要紧的事」而不是空列表页', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('health-allclear')), findsOneWidget);
    expect(find.text('账本没有要紧的事'), findsOneWidget);
  });

  testWidgets('造出的问题逐组点名：残缺 / 过期库存 / 积压清单', (tester) async {
    await store.createRecipe(RecipeDraft(name: '无米菜')); // 缺食材缺步骤
    await store.upsertPantry(name: '过期牛奶', expireAt: yesterday);
    await store.addShoppingItems([
      (name: '积压葱', qtyText: null, recipeId: null),
    ]);
    await ageShopping('积压葱', 20);
    await pump(tester);

    final noIng = find.byKey(const ValueKey('health-no-ingredients'));
    expect(noIng, findsOneWidget);
    expect(find.text('还没有食材的菜谱'), findsOneWidget);
    expect(find.text('还没有步骤的菜谱'), findsOneWidget);
    expect(find.text('已过保质期的库存'), findsOneWidget);
    expect(find.descendant(of: noIng, matching: find.text('1')), findsOneWidget);
    expect(find.text('挂了很久的未购清单项'), findsOneWidget);
    // 种子菜不进残缺组——组里只有点名造出来的那道。
    expect(find.descendant(of: noIng, matching: find.text('无米菜')), findsOneWidget);
  });

  testWidgets('★ 僵尸会话：48 小时前开火 → 点名「已挂起 48 小时」', (tester) async {
    final r = await store.createRecipe(RecipeDraft(name: '挂着'));
    final started = DateTime.now().subtract(const Duration(hours: 48));
    await store.dbOrNull!.customInsert(
      'INSERT INTO cook_session (id, updated_at, updated_by, rev, deleted_at, '
      'recipe_id, started_at, finished_at, current_step, servings_used, state) '
      "VALUES ('zs1', '000000000000-0000-node', 'node', 1, NULL, ?, ?, NULL, 0, NULL, NULL)",
      variables: [
        drift.Variable<String>(r.id),
        drift.Variable<String>(started.toIso8601String().substring(0, 19)),
      ],
    );
    await pump(tester);
    expect(find.text('挂着没做完的做菜会话'), findsOneWidget);
    expect(find.textContaining('挂着 · 已挂起 48 小时'), findsOneWidget);
  });

  testWidgets('点「已过保质期的库存」跳厨房页', (tester) async {
    await store.upsertPantry(name: '过期酸奶', expireAt: yesterday);
    await pump(tester);

    await tester.tap(find.byKey(const ValueKey('health-expired-pantry')));
    await tester.pumpAndSettle();
    expect(find.byType(KitchenPage), findsOneWidget);
    expect(find.byType(HealthPage), findsNothing);
  });

  testWidgets('★ 改完一条问题，账自动跟上（不退出重进）', (tester) async {
    await store.createRecipe(RecipeDraft(name: '残缺一'));
    await store.createRecipe(RecipeDraft(name: '残缺二'));
    await pump(tester);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('health-no-ingredients')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );

    // 给「残缺一」补上食材 → store 通知让页面重查，缺食材组从 2 变 1。
    final r = store.recipes.firstWhere((x) => x.name == '残缺一');
    await store.updateRecipe(r.id,
        RecipeDraft(name: '残缺一', ingredients: [const IngredientDraft(name: '盐', qty: '1 勺')]));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const ValueKey('health-no-ingredients')),
        matching: find.text('1'),
      ),
      findsOneWidget,
    );
  });
}
