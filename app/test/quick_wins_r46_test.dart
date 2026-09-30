import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji/ui/recipe_detail_page.dart';
import 'package:zaoji/ui/recipe_list_page.dart';

/// R46 · 快赢包（App 侧两条 FR 补漏）。
///
/// 钉的是**搜索面**和**做过记录**：
/// ① FR-REC-10 说「按名称、食材、标签搜索」，实现里第三条一直缺——
///    同一个「红烧」，标签筛选点得出来、搜索框搜不出来，两条路各说各话。
/// ② FR-REC-13 说「记录并展示每次的时间」，详情页只有累计次数，
///    「上周做过一次没有」这种判断只能靠记忆。
///
/// 树形沿用本仓库 R46 的定式：**StoreScope 在 MaterialApp 之上**
/// （弹层是从 navigator 推的，挂在 MaterialApp 里会找不到 store）。
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

  /// 结果网格里的菜名文本。**必须限定在 SliverGrid 内**——
  /// 搜索框自己就装着同一段文字（EditableText），
  /// 不加范围会出现「搜『测试戊』时『测试戊』找到 2 个」这种假失败（本文件首跑实况）。
  Finder dishText(WidgetTester tester, String name) =>
      find.descendant(of: find.byType(SliverGrid), matching: find.text(name));

  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.binding.setSurfaceSize(const Size(414, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(StoreScope(store: store, child: MaterialApp(home: page)));
    await tester.pumpAndSettle();
  }

  Future<Recipe> seed({
    required String name,
    String sub = '家常',
    Map<String, List<String>> tags = const {},
    List<IngredientDraft> ings = const [],
  }) =>
      store.createRecipe(RecipeDraft(
        name: name,
        sub: sub,
        ingredients: ings.isEmpty
            ? const [IngredientDraft(name: '盐', qty: '少许')]
            : ings,
        steps: const ['下锅', '出锅'],
        tags: tags,
      ));

  group('搜索命中标签（FR-REC-10）', () {
    // ⚠️ 菜名一律带「测试」前缀且避开示例菜：
    // `RecipeStore.ready()` 在空库时会灌 9 道示例菜（番茄炒蛋 / 麻婆豆腐 / 红烧肉…），
    // 直接复用示例名会让「同一行出现两次」——首跑就是这么假失败的。
    testWidgets('搜「红烧」命中带该标签的菜，不命中别的', (tester) async {
      await seed(name: '测试甲', tags: const {'method': ['红烧测试']});
      await seed(name: '测试乙', tags: const {'cuisine': ['粤菜测试']});
      await pump(tester, const RecipeListPage());

      await tester.enterText(find.byType(TextField).first, '红烧测试');
      await tester.pumpAndSettle();
      expect(dishText(tester, '测试甲'), findsOneWidget);
      expect(dishText(tester, '测试乙'), findsNothing);
    });

    testWidgets('标签的四个组都算（菜系/口味/操作方式/食材）', (tester) async {
      await seed(name: '测试丙', tags: const {
        'cuisine': ['菜系测试'],
        'taste': ['口味测试'],
        'method': ['做法测试'],
        'ingredient': ['食材标签测试'],
      });
      await pump(tester, const RecipeListPage());

      for (final q in ['菜系测试', '口味测试', '做法测试', '食材标签测试']) {
        await tester.enterText(find.byType(TextField).first, q);
        await tester.pumpAndSettle();
        expect(dishText(tester, '测试丙'), findsOneWidget, reason: '搜「$q」应命中');
      }
    });

    testWidgets('原来的菜名/副标题/食材三路不受影响（回归钉）', (tester) async {
      await seed(
        name: '测试丁',
        sub: '副标题测试',
        ings: const [IngredientDraft(name: '食材测试', qty: '2个', isMain: true)],
      );
      await seed(name: '测试戊');
      await pump(tester, const RecipeListPage());

      await tester.enterText(find.byType(TextField).first, '食材测试');
      await tester.pumpAndSettle();
      expect(dishText(tester, '测试丁'), findsOneWidget);
      expect(dishText(tester, '测试戊'), findsNothing);

      await tester.enterText(find.byType(TextField).first, '副标题测试');
      await tester.pumpAndSettle();
      expect(dishText(tester, '测试丁'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '测试戊');
      await tester.pumpAndSettle();
      expect(dishText(tester, '测试戊'), findsOneWidget);
      expect(dishText(tester, '测试丁'), findsNothing);
    });
  });

  group('每次做的时间（FR-REC-13）', () {
    testWidgets('做过两次 → 两行时刻 + 第 1/2 次的序数', (tester) async {
      final r = await seed(name: '蒜苗炒腊肉');
      final s1 = await store.startCooking(r.id);
      await store.finishCooking(s1);
      final s2 = await store.startCooking(r.id);
      await store.finishCooking(s2);

      await pump(tester, RecipeDetailPage(recipe: r));

      expect(find.byKey(ValueKey('cook-history-$s1')), findsOneWidget);
      expect(find.byKey(ValueKey('cook-history-$s2')), findsOneWidget);
      // 第 1 次 / 第 2 次各一次。不断言谁在上：两条 finished_at 可能同毫秒，
      // 排序在相等时不保证稳定，序数才是这条 FR 要的东西。
      expect(find.text('第 1 次'), findsOneWidget);
      expect(find.text('第 2 次'), findsOneWidget);
      expect(find.textContaining('最近 2 次'), findsOneWidget);
    });

    testWidgets('没做过时空态在，不藏这一块', (tester) async {
      final r = await seed(name: '还没做过的菜');
      await pump(tester, RecipeDetailPage(recipe: r));
      expect(find.text('还没有做过这道菜，做一次后会自动记录。'), findsOneWidget);
      expect(find.text('第 1 次'), findsNothing);
    });

    testWidgets('进行中的那次不混进记录里（顶部横幅才管它）', (tester) async {
      final r = await seed(name: '做到一半的菜');
      final done = await store.startCooking(r.id);
      await store.finishCooking(done);
      await store.startCooking(r.id); // 只开始、没完成

      await pump(tester, RecipeDetailPage(recipe: r));
      expect(find.byKey(ValueKey('cook-history-$done')), findsOneWidget);
      expect(find.text('第 2 次'), findsNothing);
    });
  });
}
