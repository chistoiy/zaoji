import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji/ui/recipe_detail_page.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// R46 · 热量手填与二次编辑（FR-AI-69~74 + 验收 A6/A17/A18）。
///
/// 这一族**完全不碰网络**：手填走的就是那条一直存在、却从来没人接的
/// `saveNutrition` 通道。所以这里不挂假服务端、也不配 AI——
/// 「未配置也能填」本身就是被测对象（FR-AI-69）。
///
/// 份数基数**默认跟菜谱自己的份数**（Q6）。种子里那道菜是 2 人份，
/// 所以断言一律从 `r.servings` 推，不把 4 写死——写死过一次，测试结果就跟着种子漂。
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

  Future<Recipe> pumpDetail(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(414, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final r = store.recipes.first;
    // ★ StoreScope 必须在 MaterialApp **之上**（与 main.dart 同构）：
    //   showModalBottomSheet 的内容挂在 Navigator 的 Overlay 里，
    //   作用域放在 home 下面，弹层里 StoreScope.of 就是 null（第一版栽在这）。
    await tester.pumpWidget(StoreScope(
      store: store,
      child: MaterialApp(home: RecipeDetailPage(recipe: r)),
    ));
    await tester.pump();
    return r;
  }

  String previewText(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('nutri-preview'))).data!;

  Future<void> openManualSheet(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('nutri-manual-entry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('nutri-edit-sheet')), findsOneWidget);
  }

  Future<void> seedAi(Recipe r, {double per = 186, double total = 744}) =>
      store.saveNutrition(
        r.id,
        NutritionDraft(
          perServingKcal: per,
          totalKcal: total,
          proteinG: 12,
          fatG: 9,
          carbG: 21,
          basisJson: _legacyBasis,
          confidence: 0.6,
          source: 'ai',
          model: 'deepseek-flash',
          servingsBasis: 4,
        ),
      );

  group('入口（FR-AI-69：没配 AI 也得能填）', () {
    testWidgets('没算过时，估算入口与手填入口**并排都在**', (tester) async {
      await pumpDetail(tester);
      expect(find.byKey(const ValueKey('nutrition-entries')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-calories-entry')), findsOneWidget);
      expect(find.byKey(const ValueKey('nutri-manual-entry')), findsOneWidget);
      expect(find.text('手动填写热量'), findsOneWidget);
      // FR-AI-27：没算过不画占位数字
      expect(find.byKey(const ValueKey('nutrition-card')), findsNothing);
    });

    testWidgets('弹层打得开、六个框都在、空态画「—」不画 0', (tester) async {
      final r = await pumpDetail(tester);
      await openManualSheet(tester);
      for (final k in [
        'nutri-per', 'nutri-total', 'nutri-serv', 'nutri-p', 'nutri-f', 'nutri-c'
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget, reason: k);
      }
      final p = previewText(tester);
      expect(p, contains('每份 ≈ —'), reason: '空态不许显示 0');
      expect(p, contains('整锅约 —'));
      expect(p, contains('按 ${r.servings} 人份'), reason: '基数默认跟菜谱份数（Q6）');
    });
  });

  group('手填落库（FR-AI-70 + 验收 A6/A17）', () {
    testWidgets('填每份 150 → 整锅自动折算 → 保存后是手动态、不挂 AI 免责', (tester) async {
      final r = await pumpDetail(tester);
      await openManualSheet(tester);

      await tester.enterText(find.byKey(const ValueKey('nutri-per')), '150');
      await tester.pump();
      expect(previewText(tester), allOf(contains('每份 ≈ 150'), contains('整锅约 ${150 * r.servings}')));

      await tester.tap(find.byKey(const ValueKey('nutri-save')));
      await tester.pumpAndSettle();

      final n = store.nutritionFor(r.id)!;
      expect(n.source, 'manual');
      expect(n.perServingKcal, 150);
      expect(n.totalKcal, 150 * r.servings);
      expect(n.confidence, isNull, reason: '手填没有「把握度」');

      expect(find.byKey(const ValueKey('nutrition-card-manual')), findsOneWidget);
      expect(find.text('手动填写'), findsWidgets);
      expect(find.textContaining('不能用于医疗或饮食处方'), findsNothing,
          reason: 'Q4：数是自己填的，再挂 AI 免责等于把责任指错地方');
      // 脚上三枚：看依据 / 手动改 / 用 AI 重算
      expect(find.byKey(const ValueKey('nutri-basis-btn')), findsOneWidget);
      expect(find.byKey(const ValueKey('nutri-edit-btn')), findsOneWidget);
      expect(find.text('用 AI 重算'), findsOneWidget);
    });

    testWidgets('改份数基数：整锅不变、每份重算（FR-AI-72 + 验收 A18）', (tester) async {
      final r = await pumpDetail(tester);
      await openManualSheet(tester);
      await tester.enterText(find.byKey(const ValueKey('nutri-per')), '150');
      await tester.pump();
      final total = 150 * r.servings;
      await tester.enterText(find.byKey(const ValueKey('nutri-serv')), '6');
      await tester.pump();
      expect(
          previewText(tester),
          allOf(contains('每份 ≈ ${(total / 6).round()}'), contains('整锅约 $total'),
              contains('按 6 人份')),
          reason: '份数只动每份，不许动总量');

      await tester.tap(find.byKey(const ValueKey('nutri-save')));
      await tester.pumpAndSettle();
      final n = store.nutritionFor(r.id)!;
      expect(n.servingsBasis, 6);
      expect(n.totalKcal, total);
      expect(n.perServingKcal, (total / 6).round());
      expect(find.text('按 6 人份'), findsWidgets);
    });

    testWidgets('每份留空 → 行内提示挡下，不落库（弹层里挂 SnackBar 看不见）', (tester) async {
      final r = await pumpDetail(tester);
      await openManualSheet(tester);
      await tester.tap(find.byKey(const ValueKey('nutri-save')));
      await tester.pump();
      expect(find.text('每份千卡得填个正数'), findsOneWidget);
      expect(find.byKey(const ValueKey('nutri-edit-sheet')), findsOneWidget,
          reason: '挡下时弹层必须还在，填了一半的东西不许丢');
      expect(store.nutritionFor(r.id), isNull);
    });
  });

  group('AI 结果的二次编辑（FR-AI-70/71/73）', () {
    testWidgets('AI 值改小手动态：卡上带「AI 原估」，看依据里两段都在', (tester) async {
      final r = store.recipes.first;
      await seedAi(r);
      await pumpDetail(tester);
      expect(find.byKey(const ValueKey('nutrition-card')), findsOneWidget,
          reason: 'AI 态还是同一张卡，只换来源标');
      expect(find.textContaining('不能用于医疗或饮食处方'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('nutri-edit-btn')));
      await tester.pumpAndSettle();
      // 已有数据时从「手动改」进的是同一个弹层，且带着旧值
      expect(tester.widget<TextField>(find.byKey(const ValueKey('nutri-per'))).controller!.text, '186');
      await tester.enterText(find.byKey(const ValueKey('nutri-per')), '95');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('nutri-save')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('nutri-ai-echo')), findsOneWidget);
      expect(find.textContaining('AI 原估 186'), findsWidgets);
      final n = store.nutritionFor(r.id)!;
      expect(n.source, 'manual');
      final basis = NutritionBasis.decode(n.basisJson);
      expect(basis.ai?.perServingKcal, 186);
      expect(basis.items.length, 2, reason: '手改不该把逐食材依据抹掉');

      await tester.tap(find.byKey(const ValueKey('nutri-basis-btn')));
      await tester.pumpAndSettle();
      final sheetText = tester
          .widgetList<Text>(find.descendant(
              of: find.byKey(const ValueKey('nutri-basis-sheet')),
              matching: find.byType(Text)))
          .map((t) => t.data ?? '')
          .join(' | ');
      expect(sheetText, contains('AI 原估 · 每份'));
      expect(sheetText, contains('现在生效 · 每份（手填）'));
      expect(sheetText, contains('鸡蛋'));
    });

    testWidgets('第二次手改不该把 AI 原值冲掉（留痕只抄第一次）', (tester) async {
      final r = store.recipes.first;
      await seedAi(r);
      await pumpDetail(tester);
      for (final per in ['95', '80']) {
        await tester.tap(find.byKey(const ValueKey('nutri-edit-btn')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('nutri-per')), per);
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('nutri-save')));
        await tester.pumpAndSettle();
      }
      final n = store.nutritionFor(r.id)!;
      expect(n.perServingKcal, 80);
      expect(NutritionBasis.decode(n.basisJson).ai?.perServingKcal, 186,
          reason: 'AI 原始估算永远是那一份，不该被第二次手改抄成 95');
    });

    testWidgets('手动态重载之后来源与数值都还在（真重载）', (tester) async {
      final r = await pumpDetail(tester);
      await openManualSheet(tester);
      await tester.enterText(find.byKey(const ValueKey('nutri-per')), '120');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('nutri-save')));
      await tester.pumpAndSettle();

      await store.reloadForTest();
      final n = store.nutritionFor(r.id)!;
      expect(n.isManual, isTrue);
      expect(n.perServingKcal, 120);
      expect(n.servingsBasis, r.servings);
    });
  });

  group('超限要真二次确认（FR-AI-74）', () {
    testWidgets('填 25000 点保存：第一下只出确认条、不落库；点确定保存才落', (tester) async {
      final r = await pumpDetail(tester);
      await openManualSheet(tester);
      await tester.enterText(find.byKey(const ValueKey('nutri-per')), '25000');
      await tester.pump();
      expect(find.byKey(const ValueKey('nutri-confirm-bar')), findsNothing,
          reason: '填上就拦是把二次确认做成一次');

      await tester.tap(find.byKey(const ValueKey('nutri-save')));
      await tester.pump();
      expect(find.byKey(const ValueKey('nutri-confirm-bar')), findsOneWidget);
      expect(store.nutritionFor(r.id), isNull, reason: '确认之前不许落库');

      await tester.tap(find.byKey(const ValueKey('nutri-save-confirm')));
      await tester.pumpAndSettle();
      expect(store.nutritionFor(r.id)?.perServingKcal, 25000);
    });

    testWidgets('确认条出现后把数值改回正常 → 确认条自己收回', (tester) async {
      await pumpDetail(tester);
      await openManualSheet(tester);
      await tester.enterText(find.byKey(const ValueKey('nutri-per')), '25000');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('nutri-save')));
      await tester.pump();
      expect(find.byKey(const ValueKey('nutri-confirm-bar')), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('nutri-per')), '300');
      await tester.pump();
      expect(find.byKey(const ValueKey('nutri-confirm-bar')), findsNothing);
    });
  });
}

/// R27 那代存下来的**纯数组**依据——顺便钉住向后兼容：
/// 手改时 items 原样带走，AI 留痕另存在同一段 JSON 里。
const _legacyBasis = '[{"name":"鸡蛋","kcal":216},{"name":"番茄","kcal":72}]';
