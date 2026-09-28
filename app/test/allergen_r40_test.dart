import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji/ui/cooking_page.dart';
import 'package:zaoji/ui/members_page.dart';
import 'package:zaoji/ui/prep_page.dart';
import 'package:zaoji/ui/recipe_detail_page.dart';
import 'package:zaoji/widgets/allergen_bits.dart';

/// R40 · 成员与过敏原（FR-SET-04/05）。
///
/// 这个文件验的是**"警示有没有真的出现在该出现的地方"**：
/// 判定本身在 `shared/allergen_test.dart` 里测过了，这里一遍都不重测——
/// 两边都测判定等于两边都可能测错。
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

  // StoreScope 挂在 MaterialApp **之上**（与 main.dart 的接线一致），
  // 否则 showModalBottomSheet / showDialog 的路由找不到 scope。
  Future<void> pump(WidgetTester tester, Widget page) async {
    // 画布放大到 540×1600：成员弹层和过敏确认框的内容都比默认 600 高，
    // 默认尺寸下保存/取消按钮会被顶到屏幕外，点下去命中的是遮罩（假失败）。
    // 与 ai/日历/体检那几份页面测试同一手法。
    await tester.binding.setSurfaceSize(const Size(540, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(StoreScope(
      store: store,
      child: MaterialApp(home: page),
    ));
  }

  Future<Recipe> shrimpDish() => store.createRecipe(RecipeDraft(
        name: '蒜蓉粉丝蒸虾',
        ingredients: const [
          IngredientDraft(name: '基围虾', qty: '400 g'),
          IngredientDraft(name: '龙口粉丝', qty: '1 把'),
          IngredientDraft(name: '蒜', qty: '6 瓣'),
        ],
        steps: const ['蒸 8 分钟'],
      ));

  Future<void> addShrimpAllergy() => store.createMember(
      name: '小宝', allergens: const ['虾'], dislikes: const ['蒜']);

  group('成员页', () {
    testWidgets('空态：没有人就一个添加入口，不塞假家人', (tester) async {
      await pump(tester, const MembersPage());
      expect(store.members, isEmpty);
      expect(find.text('还没有添加家人'), findsOneWidget);
      expect(find.byKey(const ValueKey('member-first-add')), findsOneWidget);
      // 没有成员时不该出现"警示设置"——两个开关都是空谈
      expect(find.text('警示设置'), findsNothing);
    });

    testWidgets('弹层建档：称呼+过敏词+忌口词，保存后进库并显示在卡上',
        (tester) async {
      await pump(tester, const MembersPage());
      await tester.tap(find.byKey(const ValueKey('member-first-add')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('member-name')), '小宝');
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('member-word')), '虾');
      await tester.ensureVisible(find.byKey(const ValueKey('member-word-add')));
      await tester.tap(find.byKey(const ValueKey('member-word-add')));
      await tester.pump();
      // 切到"不吃"再填一个词：两组必须分开（混填等于把忌口升级成警告）
      await tester.tap(find.byKey(const ValueKey('member-target-dislike')));
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('member-word')), '蒜');
      await tester.ensureVisible(find.byKey(const ValueKey('member-word-add')));
      await tester.tap(find.byKey(const ValueKey('member-word-add')));
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('member-save')));
      await tester.tap(find.byKey(const ValueKey('member-save')));
      await tester.pumpAndSettle();

      expect(store.members.length, 1);
      final m = store.members.single;
      expect(m.allergens, ['虾']);
      expect(m.dislikes, ['蒜']);
      expect(find.text('小宝'), findsOneWidget);
      expect(find.byKey(ValueKey('member-${m.id}')), findsOneWidget);
    });

    testWidgets('重名不许建（提示挂在称呼框下，不靠看不见摸不着的 SnackBar）',
        (tester) async {
      await addShrimpAllergy();
      await pump(tester, const MembersPage());
      await tester.tap(find.byKey(const ValueKey('member-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('member-name')), '小宝');
      await tester.pump();
      await tester.ensureVisible(find.byKey(const ValueKey('member-save')));
      await tester.tap(find.byKey(const ValueKey('member-save')));
      await tester.pumpAndSettle();

      expect(find.text('已经有位「小宝」了'), findsOneWidget);
      expect(store.members.length, 1);
    });

    testWidgets('常见词一点就加：填「贝类」这种类名是允许的', (tester) async {
      await pump(tester, const MembersPage());
      await tester.tap(find.byKey(const ValueKey('member-first-add')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('member-name')), '爸爸');
      await tester.tap(find.text('贝类'));
      await tester.pump();
      expect(find.byKey(const ValueKey('member-word-贝类')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('member-save')));
      await tester.tap(find.byKey(const ValueKey('member-save')));
      await tester.pumpAndSettle();
      expect(store.members.single.allergens, ['贝类']);
    });
  });

  group('四处警示（FR-SET-05：条纹 + 图标 + 写明是谁）', () {
    testWidgets('菜谱详情：横幅 + 命中食材行有条纹标签，未命中的行干干净净',
        (tester) async {
      await addShrimpAllergy();
      final r = await shrimpDish();
      await pump(tester, RecipeDetailPage(recipe: r));
      await tester.pumpAndSettle();

      expect(find.text('这道菜含过敏原，注意分餐'), findsOneWidget);
      expect(find.byKey(const ValueKey('ing-alert-基围虾')), findsOneWidget);
      // 忌口是另一档：蒜那行带"忌口"标签
      expect(find.text('小宝 忌口 蒜'), findsOneWidget);
      // 没命中的粉丝那行不许被拖着一起标红
      expect(find.byKey(const ValueKey('ing-alert-龙口粉丝')), findsNothing);

      final tag = tester.widget<AllergenTag>(find
          .descendant(of: find.byKey(const ValueKey('ing-alert-基围虾')), matching: find.byType(AllergenTag))
          .first);
      expect(tag.allergy, isTrue);
      // 三重冗余：标签里有图标（CustomPaint 条纹 + Icon），不是纯颜色
      expect(
          find.descendant(
              of: find.byKey(const ValueKey('ing-alert-基围虾')),
              matching: find.byIcon(Icons.warning_amber_rounded)),
          findsWidgets);
    });

    testWidgets('警示开关关掉后，详情与做菜模式都不再标（全局开关是真的）',
        (tester) async {
      await addShrimpAllergy();
      final r = await shrimpDish();
      store.setAllergenWarnInRecipes(false);
      await pump(tester, RecipeDetailPage(recipe: r));
      await tester.pumpAndSettle();
      expect(find.text('这道菜含过敏原，注意分餐'), findsNothing);
      expect(find.byKey(const ValueKey('ing-alert-基围虾')), findsNothing);
      store.setAllergenWarnInRecipes(true);
      await pump(tester, RecipeDetailPage(recipe: r));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ing-alert-基围虾')), findsOneWidget);
    });

    testWidgets('做菜模式：横幅钉在顶部，勾选面板收起也拦得住', (tester) async {
      await addShrimpAllergy();
      final r = await shrimpDish();
      final session = await store.startCooking(r.id);
      await pump(tester,
          CookingPage(recipe: r, sessionId: session, initialStep: 0, initialChecked: const {}));
      await tester.pumpAndSettle();
      expect(find.text('注意分餐'), findsOneWidget);
      expect(find.text('小宝 对「虾」过敏'), findsOneWidget);
    });

    testWidgets('备菜清单：合并后的行也标（买虾之前就看得见）', (tester) async {
      await addShrimpAllergy();
      final r = await shrimpDish();
      final menu = await store.createMenu(day: '2026-09-29', meal: '晚餐');
      await store.addDish(menu.id, r.id);
      await pump(tester, PrepPage(menuId: menu.id));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('prep-alert-基围虾')), findsOneWidget);
    });
  });

  group('排菜单拦截（FR-SET-04 第二个开关）', () {
    testWidgets('命中过敏原时先确认，取消就不加', (tester) async {
      await addShrimpAllergy();
      final r = await shrimpDish();
      final menu = await store.createMenu(day: '2026-09-29', meal: '晚餐');

      await pump(tester, RecipeDetailPage(recipe: r));
      await tester.tap(find.byKey(const ValueKey('add-to-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('addmenu-${menu.id}')));
      await tester.pumpAndSettle();

      // 确认框里写明是谁、对什么、在哪样食材上
      expect(find.text('蒜蓉粉丝蒸虾 含过敏原'), findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(AlertDialog),
              matching: find.textContaining('小宝 对「虾」过敏')),
          findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(store.menuById(menu.id)!.recipeIds, isEmpty);
      // 取消确认只关掉确认框，选餐弹层还在（改选别餐不用重新进来一遍）
      expect(find.byKey(ValueKey('addmenu-${menu.id}')), findsOneWidget);

      // 「仍然加入」也必须点得到：拦是问一次，不是禁止
      await tester.tap(find.byKey(ValueKey('addmenu-${menu.id}')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('allergen-confirm-add')));
      await tester.tap(find.byKey(const ValueKey('allergen-confirm-add')));
      await tester.pumpAndSettle();
      expect(store.menuById(menu.id)!.recipeIds, [r.id]);
    });

    testWidgets('开关关掉就直接加，不多问一次', (tester) async {
      await addShrimpAllergy();
      store.setAllergenConfirmOnMenu(false);
      final r = await shrimpDish();
      final menu = await store.createMenu(day: '2026-09-29', meal: '晚餐');

      await pump(tester, RecipeDetailPage(recipe: r));
      await tester.tap(find.byKey(const ValueKey('add-to-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('addmenu-${menu.id}')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('allergen-confirm-add')), findsNothing);
      expect(store.menuById(menu.id)!.recipeIds, [r.id]);
    });

    testWidgets('没命中的菜不加戏：正常菜直接进菜单', (tester) async {
      await addShrimpAllergy();
      final r = await store.createRecipe(RecipeDraft(
          name: '凉拌黄瓜',
          ingredients: const [IngredientDraft(name: '黄瓜', qty: '2 根')]));
      final menu = await store.createMenu(day: '2026-09-29', meal: '晚餐');

      await pump(tester, RecipeDetailPage(recipe: r));
      await tester.tap(find.byKey(const ValueKey('add-to-menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('addmenu-${menu.id}')));
      await tester.pumpAndSettle();
      expect(store.menuById(menu.id)!.recipeIds, [r.id]);
    });
  });

  group('两个开关都是本机偏好', () {
    test('写库并随重载恢复（不参与同步）', () async {
      store.setAllergenWarnInRecipes(false);
      store.setAllergenConfirmOnMenu(false);
      // 偏好写入是 unawaited 的异步落库，重载前得让它落地
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await store.reloadForTest();
      expect(store.allergenWarnInRecipes, isFalse);
      expect(store.allergenConfirmOnMenu, isFalse);
    });
  });
}
