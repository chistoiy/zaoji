import 'dart:convert';

import 'package:test/test.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// R46 · 热量的手填换算与依据编码（FR-AI-69~74）。
///
/// 钉的是「算错就会同步到另一台」的那几条：份数改动只能动每份、
/// 不能动整锅；空值不许画 0；老行（纯数组的依据）必须还能解出来。
void main() {
  group('换算（FR-AI-72 + Q5）', () {
    test('改每份 → 整锅 = 每份 × 份数', () {
      final c = nutriApply(const NutritionCalc(servings: 4), NutritionField.per, '150');
      expect(c.perServingKcal, 150);
      expect(c.totalKcal, 600);
      expect(c.servings, 4);
    });

    test('改整锅 → 每份 = 整锅 ÷ 份数', () {
      final c = nutriApply(const NutritionCalc(servings: 6), NutritionField.total, '720');
      expect(c.perServingKcal, 120);
      expect(c.totalKcal, 720);
    });

    test('份数 4→6：整锅不变、每份重算成 2/3', () {
      const start = NutritionCalc(perServingKcal: 150, totalKcal: 600, servings: 4);
      final c = nutriApply(start, NutritionField.servings, '6');
      expect(c.totalKcal, 600, reason: '份数改动绝不该动总量');
      expect(c.perRounded, 100);
      expect(c.servings, 6);
    });

    test('只有每份、没填整锅时改份数：先用旧份数补出总量再折算', () {
      // 3 人份 × 每份 100 = 整锅 300；改成 6 人份 → 每份 50，而不是「300 当 6 人份」再错一次
      const start = NutritionCalc(perServingKcal: 100, servings: 3);
      final c = nutriApply(start, NutritionField.servings, 6);
      expect(c.totalKcal, 300);
      expect(c.perRounded, 50);
    });

    test('份数脏值兜住：0/负数/超范围都不让除零', () {
      expect(nutriSanitizeServings('0', fallback: 4), 4);
      expect(nutriSanitizeServings(-2, fallback: 5), 5);
      expect(nutriSanitizeServings('', fallback: 4), 4);
      expect(nutriSanitizeServings(null, fallback: 4), 4);
      expect(nutriSanitizeServings('1000'), 99);
      const start = NutritionCalc(perServingKcal: 100, totalKcal: 400, servings: 4);
      final c = nutriApply(start, NutritionField.servings, '0');
      expect(c.servings, 4, reason: '填 0 当没填，回到原份数');
      expect(c.perServingKcal, isNot(isNaN));
    });

    test('清空一个字段不会把另一个也变成 0', () {
      final c = nutriApply(const NutritionCalc(perServingKcal: 120, totalKcal: 720, servings: 6),
          NutritionField.per, '');
      expect(c.perServingKcal, isNull, reason: '空就是空，UI 画「—」而不是 0');
      expect(c.totalKcal, 720);
    });

    test('负数按 0 收，不产生负热量', () {
      final c = nutriApply(const NutritionCalc(servings: 4), NutritionField.per, '-50');
      expect(c.perServingKcal, 0);
      expect(c.totalKcal, 0);
    });
  });

  group('校验与二次确认（FR-AI-74）', () {
    test('每份为空或不正 → needPerServing', () {
      expect(nutriCheck(const NutritionCalc(), armed: false), NutritionCheck.needPerServing);
      expect(nutriCheck(const NutritionCalc(perServingKcal: 0), armed: false),
          NutritionCheck.needPerServing);
    });

    test('超上限 → 第一次要确认、点了确认之后放行', () {
      const c = NutritionCalc(perServingKcal: 25000, servings: 4);
      expect(nutriCheck(c, armed: false), NutritionCheck.needConfirm);
      expect(nutriCheck(c, armed: true), NutritionCheck.ok);
    });

    test('正常值不拦', () {
      expect(nutriCheck(const NutritionCalc(perServingKcal: 186), armed: false),
          NutritionCheck.ok);
    });
  });

  group('依据编码（FR-AI-71，向后兼容是硬要求）', () {
    test('R27 那代的老行：basis 是纯数组，照样解得出逐项、没有留痕', () {
      final legacy = jsonEncode([
        {'name': '鸡蛋', 'kcal': 216},
        {'name': '番茄', 'kcal': 72},
      ]);
      final b = NutritionBasis.decode(legacy);
      expect(b.items.length, 2);
      expect(NutritionBasis.itemName(b.items.first), '鸡蛋');
      expect(NutritionBasis.itemKcal(b.items.first), 216);
      expect(b.ai, isNull);
    });

    test('新形状：items + ai 留痕，往返一致', () {
      const b = NutritionBasis(
        items: [
          {'name': '牛肉末', 'kcal': 250, 'qty': '100 g'}
        ],
        ai: NutritionAiEcho(perServingKcal: 264, totalKcal: 1056, model: 'deepseek-flash', confidence: 0.9),
      );
      final back = NutritionBasis.decode(b.encode());
      expect(back.items.single['name'], '牛肉末');
      expect(back.ai?.perServingKcal, 264);
      expect(back.ai?.model, 'deepseek-flash');
    });

    test('脏数据（不是 JSON）解成空依据，不抛异常', () {
      expect(NutritionBasis.decode('不是 json').items, isEmpty);
      expect(NutritionBasis.decode(null).items, isEmpty);
      expect(NutritionBasis.decode('').items, isEmpty);
    });

    test('逐项的键名兼容：服务端给 qty / 原型给 q 都认', () {
      final b = NutritionBasis.decode(jsonEncode([
        {'name': '油', 'k': 132, 'q': '约 15 ml'},
        {'name': '盐', 'kcal': 0, 'amount': '少许'},
      ]));
      expect(NutritionBasis.itemKcal(b.items.first), 132);
      expect(NutritionBasis.itemQty(b.items.first), '约 15 ml');
      expect(NutritionBasis.itemQty(b.items.last), '少许');
    });
  });

  group('留痕该留谁（第二次手改不该把 AI 原始值冲掉）', () {
    test('上一版是 AI → 抄它的当前值', () {
      final echo = nutriEchoFor(const NutritionBasis(),
          prevSource: 'ai', prevPer: 186, prevTotal: 744, prevModel: 'm', prevConfidence: 0.6);
      expect(echo?.perServingKcal, 186);
      expect(echo?.model, 'm');
    });

    test('上一版已是手动态且带着留痕 → 原样带走', () {
      const prev = NutritionBasis(
          items: [], ai: NutritionAiEcho(perServingKcal: 186, totalKcal: 744));
      final echo = nutriEchoFor(prev,
          prevSource: 'manual', prevPer: 95, prevTotal: 380, prevModel: null, prevConfidence: null);
      expect(echo?.perServingKcal, 186, reason: '95 是上一次手改的值，不该盖掉 AI 原估');
    });

    test('纯手填（从没算过）→ 没有留痕', () {
      final echo = nutriEchoFor(const NutritionBasis(),
          prevSource: null, prevPer: null, prevTotal: null, prevModel: null, prevConfidence: null);
      expect(echo, isNull);
    });
  });
}
