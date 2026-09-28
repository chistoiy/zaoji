import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji_shared/zaoji_shared.dart' show MergedLine;
import 'package:zaoji/models.dart';
import 'package:zaoji/ui/members_page.dart';
import 'package:zaoji/ui/recipe_detail_page.dart';

/// R42 · 同义词表接进过敏原判定（FR-SET-06 缺的那一半）。
///
/// 判定本身在 `shared/test/allergen_test.dart` 里测过了，这个文件一遍都不重测——
/// 这里只测**接线**：那张表有没有真的挂到「四处警示」和「备菜合并」上，
/// 以及原型里那一枚「食材别名归一」开关是不是**一处管两处**（而不是只管合并）。
///
/// 为什么值得单独立一个文件：R40 把表留在库存那一侧、判定这条腿空着，
/// widget 测试全绿、真产物也全绿，因为**测试用的菜和成员用的词是同一套写法**
/// （虾 ↔ 基围虾，靠包含就命中了）。"番茄 vs 西红柿"这种同物异名只有真喂进去才抓得到。
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

  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.binding.setSurfaceSize(const Size(540, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(StoreScope(
      store: store,
      child: MaterialApp(home: page),
    ));
  }

  /// 菜里一律写变体「西红柿 / 土豆」，成员一律填规范名「番茄 / 洋芋」——
  /// 反着填也一样，两个方向都由同一张表负责（shared 那边钉过了）。
  Future<Recipe> tomatoDish() => store.createRecipe(RecipeDraft(
        name: '西红柿炒蛋',
        ingredients: const [
          IngredientDraft(name: '西红柿', qty: '2 个'),
          IngredientDraft(name: '鸡蛋', qty: '3 个'),
        ],
        steps: const ['炒 4 分钟'],
      ));

  Future<void> addFamily() => store.createMember(
      name: '小宝', allergens: const ['番茄'], dislikes: const ['洋芋']);

  group('别名接到警示上', () {
    testWidgets('成员填「番茄」、菜里写「西红柿」：详情页报出来（R40 漏的就是这条）',
        (tester) async {
      await addFamily();
      final r = await tomatoDish();
      await pump(tester, RecipeDetailPage(recipe: r));
      await tester.pumpAndSettle();

      expect(find.text('这道菜含过敏原，注意分餐'), findsOneWidget);
      expect(find.byKey(const ValueKey('ing-alert-西红柿')), findsOneWidget,
          reason: '同物异名不认=漏报，过敏的漏报代价是有人被送急诊');
      // 忌口档也吃别名：成员填洋芋、菜里是土豆
      expect(find.text('小宝 忌口 鸡蛋'), findsNothing);
    });

    test('忌口那档同样认别名（洋芋 ↔ 土豆），但只算提示不算冲突', () async {
      await store.createMember(
          name: '爸爸', allergens: const [], dislikes: const ['洋芋']);
      final r = await store.createRecipe(RecipeDraft(
        name: '土豆炖牛腩',
        ingredients: const [IngredientDraft(name: '土豆', qty: '3 个')],
        steps: const ['炖 40 分钟'],
      ));
      final hits = store.allergenHitsFor(r);
      expect(hits.map((h) => h.ingredient), contains('土豆'),
          reason: '同一样东西的两种写法，忌口也该拦得住');
      expect(store.conflictingRecipeCount(), 0,
          reason: '★ 忌口不进"冲突"计数——这是 R40 定下的口径，别名接进来不能把它带偏');
    });

    testWidgets('成员页顶部汇总把别名命中的菜数进去', (tester) async {
      await addFamily();
      await tomatoDish();
      await pump(tester, const MembersPage());
      await tester.pumpAndSettle();
      expect(find.textContaining('道菜和家里的成员冲突'), findsOneWidget);
      expect(find.textContaining('西红柿'), findsWidgets,
          reason: '汇总那道菜名与成员卡里那条命中都带「西红柿」，两处都得认出来');
    });
  });

  group('一个开关管两处（原型「食材别名归一」那一行）', () {
    test('关掉开关：判定不再命中，备菜也不再折叠同义词', () async {
      await addFamily();
      final r = await tomatoDish();
      expect(store.allergenHitsFor(r).map((h) => h.ingredient), contains('西红柿'));

      final tomato2 = await store.createRecipe(RecipeDraft(
        name: '番茄蛋汤',
        ingredients: const [IngredientDraft(name: '番茄', qty: '1 个')],
        steps: const ['煮 5 分钟'],
      ));
      List<MergedLine> tomatoLines() => [
            for (final l in store.mergeForPrep([r.id, tomato2.id]))
              if (l.name.contains('番茄') || l.name.contains('西红柿')) l,
          ];
      expect(tomatoLines().length, 1,
          reason: '开着：西红柿与番茄是同一样东西，折成一行（鸡蛋那行是另一样东西，不算）');

      store.setIngredientAlias(false);
      expect(tomatoLines().length, 2,
          reason: '关掉：两张写法各算一样（合并是用户要的取舍，不替她猜）');
      expect(store.allergenHitsFor(r), isEmpty,
          reason: '★ 同一个开关必须也管得住判定，否则"关掉别名"只关了合并那一半');

      store.setIngredientAlias(true);
      expect(store.allergenHitsFor(r).map((h) => h.ingredient), contains('西红柿'));
      expect(tomatoLines().length, 1);
    });

    testWidgets('开关在成员页在位、默认开着', (tester) async {
      await addFamily();
      await pump(tester, const MembersPage());
      await tester.pumpAndSettle();
      final row = find.byKey(const ValueKey('alias-switch'));
      expect(row, findsOneWidget);
      expect(tester.widget<SwitchListTile>(row).value, isTrue,
          reason: '默认关闭的安全功能等于没有安全功能（R40 同一立场）');

      await tester.tap(row);
      await tester.pumpAndSettle();
      expect(store.ingredientAliasOn, isFalse);
    });

    test('开关是本机偏好：写库并随重载恢复，不参与同步', () async {
      store.setIngredientAlias(false);
      // 偏好落库是 unawaited 的异步，重载前让它先落地（R40 同一手法）
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await store.reloadForTest();
      expect(store.ingredientAliasOn, isFalse);
    });
  });
}
