import 'package:test/test.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// R28 · 库存匹配算法（清空冰箱的判定地基）。
void main() {
  Map<String, Object?> recipe(String id, List<Map<String, Object?>> ings) =>
      {'id': id, 'name': id, 'ingredients': ings};
  Map<String, Object?> ing(String name,
          {bool main = false, bool staple = false, String qty = '适量'}) =>
      {'name': name, 'qtyText': qty, 'isMain': main, 'isStaple': staple};
  Map<String, Object?> stock(String name, {int have = 1, String? aliasKey}) =>
      {'name': name, 'have': have, 'aliasKey': aliasKey};

  group('三组归类（FR-RECO-03）', () {
    test('全齐 → canCook；常备豁免不算缺；缺多 → needShopping', () {
      final r = PantryMatch.recommend(
        recipes: [
          recipe('a', [ing('番茄', main: true), ing('鸡蛋', main: true)]),
          recipe('b', [ing('茄子', main: true), ing('蒜', staple: true)]),
          recipe('c', [ing('牛肉', main: true), ing('土豆'), ing('胡萝卜')]),
        ],
        pantry: [stock('番茄'), stock('鸡蛋'), stock('茄子')],
      );
      // b 的蒜是常备豁免，应算全齐；c 缺两样非主料但总数超阈值
      expect((r['canCook'] as List).map((e) => e['id']), ['a', 'b']);
      expect((r['almostThere'] as List), isEmpty);
      expect((r['needShopping'] as List).map((e) => e['id']), ['c']);
    });

    test('缺主料的大幅降权：差一样主料不进「差一点」（FR-RECO-02）', () {
      final r = PantryMatch.recommend(
        recipes: [
          recipe('main-missing', [ing('鱼', main: true), ing('姜')]),
          recipe('side-missing', [ing('豆腐', main: true), ing('葱花')]),
        ],
        pantry: [stock('姜'), stock('豆腐')],
      );
      expect((r['almostThere'] as List).map((e) => e['id']),
          ['side-missing'],
          reason: '缺主料的鱼不能和缺葱花的豆腐挤进同一组');
      expect((r['needShopping'] as List).map((e) => e['id']), ['main-missing']);
    });

    test('have=0 的库存行等于没货', () {
      final r = PantryMatch.recommend(
        recipes: [recipe('a', [ing('牛奶', main: true)])],
        pantry: [stock('牛奶', have: 0)],
      );
      expect(r['canCook'], isEmpty);
    });

    test('别名归一键命中：库存记「西红柿」，菜谱写「番茄」也算齐', () {
      final r = PantryMatch.recommend(
        recipes: [
          recipe('a', [
            {'name': '番茄', 'qtyText': '2个', 'isMain': true, 'aliasKey': '西红柿'}
          ])
        ],
        pantry: [stock('西红柿')],
      );
      expect(r['canCook'], hasLength(1));
    });

    test('组内按匹配度降序', () {
      final r = PantryMatch.recommend(
        recipes: [
          recipe('miss4',
              [ing('A', main: true), ing('B'), ing('C'), ing('D'), ing('E')]),
          recipe('miss3',
              [ing('A', main: true), ing('B'), ing('C'), ing('D')]),
        ],
        pantry: [stock('A')],
      );
      // 两样都超「差一点」阈值（缺 >2）→ 同组；覆盖率高的排前面
      final list = r['needShopping'] as List;
      expect(list.map((e) => e['id']).toList(), ['miss3', 'miss4']);
    });
  });

  group('aliasKeyOf 归一', () {
    test('剁掉数字+单位尾巴', () {
      expect(PantryMatch.aliasKeyOf('番茄2个'), '番茄');
      expect(PantryMatch.aliasKeyOf('五花肉 500g'), '五花肉');
      expect(PantryMatch.aliasKeyOf('姜'), '姜');
    });
  });
}
