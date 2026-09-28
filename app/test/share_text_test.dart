import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/share_text.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// R34 · 文字分享的三个对象（FR-SHARE-01/03/07/08/09/10）。
///
/// 纯函数、零依赖、零 I/O——面板只排版，这里管**账面和红线**：
/// · 红线 FR-SHARE-07：产物不得出现 URL/服务器地址/token（逐条钉死）；
/// · 红线 FR-SHARE-09：默认不含隐私块（库存全量、烹饪历史、过敏原）；
/// · 清单样式 FR-SHARE-08：备菜/买菜用 `☐` 可勾选行。
void main() {
  final tomato = Recipe(
    id: 'r1',
    name: '番茄炒蛋',
    sub: '十五分钟的家常底味',
    difficulty: 1,
    selfTime: 10,
    servings: 2,
    notes: '① 番茄要选熟透的\n② 全程别超过 4 分钟',
    ingredients: const [
      Ingredient('番茄', '2 个'),
      Ingredient('鸡蛋', '3 个', isMain: true),
    ],
    steps: const [Step('鸡蛋打散，加一小撮盐搅匀，静置 3 分钟。'), Step('番茄切滚刀块。')],
    cookedCount: 23,
    lastCooked: '2026-09-14',
  );

  group('菜品文本', () {
    test('全开：标题/食材/步骤/注意/署名逐块都在，时间关键词原样保留', () {
      final t = shareRecipe(
        recipe: tomato,
        servings: 2,
        nutritionLine: '每份 ≈ 210 千卡 · 整锅 ≈ 420 千卡',
      );
      expect(t, startsWith('【番茄炒蛋】'));
      expect(t, contains('十五分钟的家常底味 · 难度 ●○○ · 约 10 分钟 · 2 人份'));
      expect(t, contains('— 食材（2 人份）—'));
      expect(t, contains('· 番茄        2 个'));
      expect(t, contains('静置 3 分钟')); // 步骤原文一个字不改（时间胶囊立场同款）
      expect(t, contains('— 注意 —'));
      expect(t, contains('每份 ≈ 210 千卡'));
      expect(t, endsWith('— 来自 灶记 ZAOJI · 家庭菜谱手账 —'));
    });

    test('★ 勾选排除逐块生效；全关只剩标题行', () {
      final t = shareRecipe(
        recipe: tomato,
        servings: 2,
        withIngredients: false,
        withSteps: false,
        withNotes: false,
        withSignature: false,
      );
      expect(t, contains('【番茄炒蛋】'));
      expect(t, isNot(contains('食材')));
      expect(t, isNot(contains('鸡蛋打散')));
      expect(t, isNot(contains('注意')));
      expect(t, isNot(contains('灶记')));
    });

    test('缩放分量：基数 2 按 4 人份分享 → 标注按几人份', () {
      final t = shareRecipe(recipe: tomato, servings: 4);
      expect(t, contains('— 食材（4 人份）—'));
    });

    test('★ 红线 FR-SHARE-09：烹饪历史（做过几次/最近日期）不进产物', () {
      final t = shareRecipe(recipe: tomato, servings: 2);
      expect(t, isNot(contains('23')));
      expect(t, isNot(contains('2026-09-14')));
      expect(t, isNot(contains('做过')));
    });

    test('★ 红线 FR-SHARE-07：三种产物全文无 http/地址/token', () {
      final menu = MenuPlan(id: 'm1', day: '2026-09-26', meal: '晚餐', serveAt: '18:30', recipeIds: const ['r1']);
      final lines = [
        MergedLine(
          key: 'k',
          name: '番茄',
          parts: const [
            Amount(value: null, unit: '个', kind: AmountKind.unparsed, raw: '2 个')
          ],
          from: const ['番茄炒蛋'],
          anyVague: false,
        ),
      ];
      for (final t in [
        shareRecipe(recipe: tomato, servings: 2),
        shareMenu(menu: menu, dishes: [tomato]),
        sharePrep(day: '2026-09-26', meal: '晚餐', lines: lines),
      ]) {
        expect(t, isNot(contains('http')));
        expect(t, isNot(contains('192.168')));
        expect(t, isNot(contains('token')));
        expect(t, isNot(contains('8666')));
      }
    });
  });

  group('菜单文本', () {
    final menu = MenuPlan(
        id: 'm1', day: '2026-09-26', meal: '晚餐', serveAt: '18:30', recipeIds: const ['r1']);

    test('【周六 · 晚餐】+ 开饭时间 + 菜名（难度/耗时）', () {
      final t = shareMenu(menu: menu, dishes: [tomato]);
      expect(t, contains('【周六 · 晚餐】'));
      expect(t, contains('18:30 开饭'));
      expect(t, contains('· 番茄炒蛋（难度 ●○○ · 约 10 分钟）'));
      expect(t, contains('— 来自 灶记'));
    });

    test('没定开饭时间不提；周一到周日的折算按 day 走', () {
      final m2 = MenuPlan(id: 'm2', day: '2026-09-28', meal: '早餐', recipeIds: const []);
      final t = shareMenu(menu: m2, dishes: []);
      expect(t, contains('【周一 · 早餐】'));
      expect(t, isNot(contains('开饭')));
      expect(t, contains('还没配菜'));
    });
  });

  group('备菜清单文本', () {
    final lines = [
      MergedLine(
          key: 'a',
          name: '番茄',
          parts: const [
            Amount(value: null, unit: '个', kind: AmountKind.unparsed, raw: '2 个')
          ],
          from: const ['番茄炒蛋'],
          anyVague: false),
      MergedLine(
          key: 'b',
          name: '盐',
          parts: const [
            Amount(value: null, unit: '适量', kind: AmountKind.vague, raw: '适量')
          ],
          from: const ['番茄炒蛋', '红烧肉'],
          anyVague: true),
    ];

    test('★ FR-SHARE-08：每行 ☐ 开头可打勾；合并行标来源', () {
      final t = sharePrep(day: '2026-09-26', meal: '晚餐', lines: lines);
      final rows = t.split('\n').where((l) => l.startsWith('☐')).toList();
      expect(rows, hasLength(2));
      expect(rows.first, '☐ 番茄        2 个');
      expect(t, contains('盐        适量 ← 番茄炒蛋、红烧肉'));
    });

    test('来源可关（买菜的人不需要知道每样来自哪道菜）', () {
      final t = sharePrep(day: '2026-09-26', meal: '晚餐', lines: lines, withSources: false);
      expect(t, isNot(contains('←')));
      expect(t, contains('☐ 盐        适量'));
    });
  });
}
