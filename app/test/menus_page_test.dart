import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji/ui/menu_detail_page.dart';
import 'package:zaoji/ui/menus_page.dart';
import 'package:zaoji/ui/prep_page.dart';
import 'package:zaoji/ui/recipe_detail_page.dart';

/// R23 · 菜单 + 备菜的页面行为。
///
/// 全是 StoreScope 单机页（不碰网络、不碰 vault），所以本文件里
/// 没有真 HTTP——那颗「同文件 testWidgets 让全文件吃 400 mock」的雷
/// （R22 §7.1）与此无关，但也正因如此这里必须一个引擎都不接。
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

  // StoreScope 挂到 MaterialApp **之上**——和生产接线一致（main.dart 就是这么包的）。
  // 挂在 home 下面的话，push 的路由 / showModalBottomSheet 都落在 scope 外面，
  // StoreScope.of 直接找不到（这颗雷是照着 R12「全局单例 + widget 测试」的坑反着挖的）。
  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(StoreScope(
      store: store,
      child: MaterialApp(home: page),
    ));
  }

  Future<Recipe> makeRecipe(String name,
      [List<IngredientDraft> ings = const []]) {
    return store.createRecipe(RecipeDraft(name: name, ingredients: ings));
  }

  Widget wrapped(Widget w) =>
      StoreScope(store: store, child: MaterialApp(home: w));

  testWidgets('菜单页新建：餐次表单填完落库并出现在卡列表', (tester) async {
    await pump(tester, const MenusPage());
    expect(find.text('还没排过菜单'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('menu-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '自定义'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('meal-name-custom')), '下午茶');
    await tester.enterText(
        find.byKey(const ValueKey('meal-serve-at')), '15:30');
    await tester.tap(find.byKey(const ValueKey('meal-save')));
    await tester.pumpAndSettle();

    expect(store.menus, hasLength(1));
    expect(store.menus.single.meal, '下午茶');
    expect(store.menus.single.serveAt, '15:30');
    expect(find.textContaining('下午茶'), findsWidgets);
  });

  testWidgets('自定义餐次不填名字 → 就地报错，不落库', (tester) async {
    await pump(tester, const MenusPage());
    await tester.tap(find.byKey(const ValueKey('menu-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, '自定义'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('meal-save')));
    await tester.pumpAndSettle();

    expect(find.text('自定义餐次总得有个名字'), findsOneWidget);
    expect(store.menus, isEmpty);
  });

  testWidgets('菜单详情页：移除菜品、加菜、编辑开饭时间', (tester) async {
    final m = await store.createMenu(day: '2026-09-17', meal: '晚餐', serveAt: '18:30');
    final a = await makeRecipe('番茄炒蛋');
    final b = await makeRecipe('蚝油生菜');
    await store.addDish(m.id, a.id);
    await store.addDish(m.id, b.id);

    await pump(tester, MenuDetailPage(menuId: m.id));
    expect(find.text('番茄炒蛋'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('dish-remove-${a.id}')));
    await tester.pumpAndSettle();
    expect(find.text('番茄炒蛋'), findsNothing);
    expect(store.menuById(m.id)!.recipeIds, [b.id]);

    await tester.tap(find.byKey(const ValueKey('dish-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('pick-${a.id}')));
    await tester.pumpAndSettle();
    expect(find.text('番茄炒蛋'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('menu-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('meal-serve-at')), '19:00');
    await tester.tap(find.byKey(const ValueKey('meal-save')));
    await tester.pumpAndSettle();
    expect(store.menuById(m.id)!.serveAt, '19:00');
  });

  testWidgets('删除菜单：确认后连菜品行一起软删并退出', (tester) async {
    final m = await store.createMenu(day: '2026-09-17', meal: '晚餐');
    final a = await makeRecipe('菜A');
    await store.addDish(m.id, a.id);

    await pump(tester, MenuDetailPage(menuId: m.id));
    await tester.tap(find.byKey(const ValueKey('menu-delete')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('menu-delete-confirm')));
    await tester.pumpAndSettle();

    expect(store.menus, isEmpty);
    final c = await store.dbOrNull!
        .customSelect(
          'SELECT COUNT(*) AS c FROM menu_item WHERE deleted_at IS NULL',
        )
        .getSingle();
    expect(c.data['c'], 0);
  });

  testWidgets('菜谱详情「加入菜单」：选一餐加进来', (tester) async {
    final m = await store.createMenu(day: '2026-09-17', meal: '晚餐');
    final r = await makeRecipe('葱油拌面');

    await pump(tester, RecipeDetailPage(recipe: r));
    await tester.tap(find.byKey(const ValueKey('add-to-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('addmenu-${m.id}')));
    await tester.pumpAndSettle();

    expect(store.menuById(m.id)!.recipeIds, [r.id]);
  });

  testWidgets('备菜屏：合并行勾选进「已备齐」、排除可恢复、手动项可增删', (tester) async {
    final m = await store.createMenu(day: '2026-09-17', meal: '晚餐');
    final a = await makeRecipe('番茄炒蛋', const [
      IngredientDraft(name: '番茄', qty: '2 个'),
      IngredientDraft(name: '盐', qty: '适量'),
    ]);
    await store.addDish(m.id, a.id);

    await pump(tester, PrepPage(menuId: m.id));
    expect(find.text('番茄'), findsOneWidget);
    expect(find.text('2 个'), findsOneWidget);

    // 勾选「番茄」→ 移入已备齐
    await tester.tap(find.byKey(const ValueKey('prep-check-番茄')));
    await tester.pumpAndSettle();
    expect(find.text('已备齐'), findsOneWidget);
    expect(store.prepBoardOf(m.id).done, contains('番茄'));

    // 排除「盐」→ 出现在已排除区，可恢复
    await tester.tap(find.byKey(const ValueKey('prep-exclude-盐')));
    await tester.pumpAndSettle();
    expect(find.text('已排除 1 项'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('prep-restore-盐')));
    await tester.pumpAndSettle();
    expect(find.text('盐'), findsOneWidget);

    // 手动加一项、再删掉
    await tester.enterText(
        find.byKey(const ValueKey('prep-extra-name')), '嫩豆腐');
    await tester.enterText(
        find.byKey(const ValueKey('prep-extra-qty')), '2 块');
    await tester.tap(find.byKey(const ValueKey('prep-add-extra')));
    await tester.pumpAndSettle();
    expect(find.text('嫩豆腐'), findsOneWidget);
    expect(find.text('2 块'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('prep-remove-x:嫩豆腐')));
    await tester.pumpAndSettle();
    expect(find.text('嫩豆腐'), findsNothing);
  });

  testWidgets('备菜屏：合并行能点开看来源', (tester) async {
    final m = await store.createMenu(day: '2026-09-17', meal: '晚餐');
    final a = await makeRecipe('番茄炒蛋', const [
      IngredientDraft(name: '番茄', qty: '200 g'),
    ]);
    final b = await makeRecipe('番茄牛腩', const [
      IngredientDraft(name: '番茄', qty: '0.3 kg'),
    ]);
    await store.addDish(m.id, a.id);
    await store.addDish(m.id, b.id);

    await pump(tester, PrepPage(menuId: m.id));
    expect(find.text('500 g'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('prep-sources-番茄')));
    await tester.pumpAndSettle();
    expect(find.textContaining('来自：番茄炒蛋、番茄牛腩'), findsOneWidget);
  });

  testWidgets('菜单被别的设备删掉时，详情页原地给体面收场', (tester) async {
    final m = await store.createMenu(day: '2026-09-17', meal: '晚餐');
    await tester.pumpWidget(wrapped(MenuDetailPage(menuId: m.id)));
    await store.deleteMenu(m.id);
    await tester.pumpAndSettle();
    expect(find.text('这个菜单已经不存在了'), findsOneWidget);
  });
}
