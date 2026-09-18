import 'package:test/test.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

IngredientRef _r(String name, String qty, {bool main = false}) =>
    IngredientRef(name: name, qty: qty, isMain: main);

void main() {
  group('parseAmount · 分量解析', () {
    test('质量归一为克', () {
      expect(parseAmount('200 g').value, 200);
      expect(parseAmount('0.3 kg').value, 300);
      expect(parseAmount('1 斤').value, 500);
      expect(parseAmount('2 两').value, 100);
      expect(parseAmount('200 克').value, 200);
    });

    test('体积归一为毫升', () {
      expect(parseAmount('200 ml').value, 200);
      expect(parseAmount('1.5 L').value, 1500);
      expect(parseAmount('200 毫升').value, 200);
    });

    test('个量词保持原单位', () {
      final a = parseAmount('2 个');
      expect(a.value, 2);
      expect(a.unit, '个');
      expect(a.kind, AmountKind.count);
    });

    test('中文数字', () {
      expect(parseAmount('三个').value, 3);
      expect(parseAmount('两勺').value, 2);
      expect(parseAmount('半勺').value, 0.5);
    });

    test('分数', () {
      expect(parseAmount('1/2 个').value, 0.5);
    });

    test('区间取上限（备菜宁可多买）', () {
      expect(parseAmount('200-250 g').value, 250);
    });

    test('模糊量单独归类', () {
      final a = parseAmount('适量');
      expect(a.kind, AmountKind.vague);
      expect(a.isAddable, isFalse);
      expect(parseAmount('少许').kind, AmountKind.vague);
    });

    test('解析不出就老实承认', () {
      final a = parseAmount('常备');
      expect(a.kind, AmountKind.unparsed);
      expect(a.raw, '常备');
    });

    test('全角数字', () {
      expect(parseAmount('２００ g').value, 200);
    });

    test('单字母单位不吞掉英文单词', () {
      // 「oil」不应被切成「oi」+「l」
      final a = parseAmount('oil');
      expect(a.kind, AmountKind.unparsed);
    });
  });

  group('mergeIngredients · 去重与累加', () {
    test('同单位直接相加', () {
      final r = mergeIngredients([
        [_r('番茄', '200 g')],
        [_r('番茄', '300 g')],
      ], sourceNames: ['番茄炒蛋', '番茄牛腩']);
      expect(r, hasLength(1));
      expect(r.first.qtyText, '500 g');
    });

    test('跨单位折算：g + kg', () {
      final r = mergeIngredients([
        [_r('牛腩', '200 g')],
        [_r('牛腩', '0.3 kg')],
      ]);
      expect(r.first.qtyText, '500 g');
    });

    test('斤 折算进 g', () {
      final r = mergeIngredients([
        [_r('五花肉', '1 斤')],
        [_r('五花肉', '200 g')],
      ]);
      expect(r.first.qtyText, '700 g');
    });

    test('超过 1kg 自动换算显示', () {
      final r = mergeIngredients([
        [_r('土豆', '800 g')],
        [_r('土豆', '700 g')],
      ]);
      expect(r.first.qtyText, '1.5 kg');
    });

    test('个量词按同名相加', () {
      final r = mergeIngredients([
        [_r('鸡蛋', '2 个')],
        [_r('鸡蛋', '3 个')],
      ]);
      expect(r.first.qtyText, '5 个');
    });

    test('☆ 不同量词绝不混加', () {
      final r = mergeIngredients([
        [_r('小葱', '1 个')],
        [_r('小葱', '1 根')],
      ]);
      // 「1 个 + 1 根」是诚实的；「2」是错的
      expect(r, hasLength(1));
      expect(r.first.qtyText, '1 个 + 1 根');
    });

    test('☆ 质量与个数并存时也不硬加', () {
      final r = mergeIngredients([
        [_r('番茄', '200 g')],
        [_r('番茄', '1 个')],
      ]);
      expect(r.first.qtyText, '200 g + 1 个');
    });

    test('☆ 适量只保留一次，绝不出现「适量 ×3」', () {
      final r = mergeIngredients([
        [_r('食盐', '适量')],
        [_r('食盐', '适量')],
        [_r('食盐', '适量')],
      ]);
      expect(r, hasLength(1));
      expect(r.first.qtyText, '适量');
      expect(r.first.anyVague, isTrue);
    });

    test('适量与确定量并存', () {
      final r = mergeIngredients([
        [_r('食盐', '3 g')],
        [_r('食盐', '适量')],
      ]);
      expect(r.first.qtyText, '3 g + 适量');
    });

    test('无法解析的量原样保留（不丢数据）', () {
      final r = mergeIngredients([
        [_r('神秘调料', '常备')],
      ]);
      expect(r.first.qtyText, '常备');
    });

    test('来源菜品去重且保序', () {
      final r = mergeIngredients([
        [_r('番茄', '1 个')],
        [_r('番茄', '2 个')],
        [_r('番茄', '3 个')],
      ], sourceNames: ['番茄炒蛋', '番茄牛腩', '番茄汤']);
      expect(r.first.from, ['番茄炒蛋', '番茄牛腩', '番茄汤']);
      expect(r.first.qtyText, '6 个');
    });

    test('展示名取最短（通常是最通用的写法）', () {
      final resolver = PantryAliasResolver(['番茄']);
      final r = mergeIngredients([
        [_r('本地小番茄', '2 个')],
        [_r('番茄', '1 个')],
      ], resolver: resolver.resolve);
      expect(r, hasLength(1));
      expect(r.first.name, '番茄', reason: '「本地小番茄」与「番茄」归一后取更通用的那个');
      expect(r.first.qtyText, '3 个');
    });

    test('空输入不炸', () {
      expect(mergeIngredients([]), isEmpty);
      expect(mergeIngredients([[]]), isEmpty);
    });

    test('保持首次出现顺序', () {
      final r = mergeIngredients([
        [_r('番茄', '1 个'), _r('鸡蛋', '2 个'), _r('小葱', '1 根')],
      ]);
      expect(r.map((e) => e.name).toList(), ['番茄', '鸡蛋', '小葱']);
    });
  });

  group('PantryAliasResolver · 别名归一', () {
    test('精确命中', () {
      final r = PantryAliasResolver(['粉丝', '五花肉']);
      expect(r.resolve('粉丝'), '粉丝');
    });

    test('子串兜底：龙口粉丝 → 粉丝', () {
      final r = PantryAliasResolver(['粉丝', '五花肉']);
      expect(r.resolve('龙口粉丝'), '粉丝');
    });

    test('子串兜底：带皮五花肉 → 五花肉', () {
      final r = PantryAliasResolver(['粉丝', '五花肉']);
      expect(r.resolve('带皮五花肉'), '五花肉');
    });

    test('最长匹配优先：糯米 不被 米 抢走', () {
      final r = PantryAliasResolver(['米', '糯米']);
      expect(r.resolve('糯米'), '糯米');
    });

    test('☆ 加工形态拒绝归一：番茄酱 ≠ 番茄', () {
      final r = PantryAliasResolver(['番茄', '牛肉']);
      // 这是最容易造成"买错东西"的一类 bug
      expect(r.resolve('番茄酱'), '番茄酱');
      expect(r.resolve('番茄汁'), '番茄汁');
      expect(r.resolve('牛肉干'), '牛肉干');
      // 而规格前缀仍然要归一
      expect(r.resolve('本地番茄'), '番茄');
    });

    test('显式映射优先级最高（西红柿 → 番茄）', () {
      final r = PantryAliasResolver(
        ['番茄'],
        explicit: {'西红柿': '番茄'},
      );
      expect(r.resolve('西红柿'), '番茄');
    });

    test('未知词原样返回', () {
      final r = PantryAliasResolver(['番茄']);
      expect(r.resolve('罗勒叶'), '罗勒叶');
    });

    test('归一后确实合并成一条', () {
      final resolver = PantryAliasResolver(['粉丝']);
      final r = mergeIngredients([
        [_r('龙口粉丝', '100 g')],
        [_r('粉丝', '50 g')],
      ], resolver: resolver.resolve);
      expect(r, hasLength(1));
      expect(r.first.qtyText, '150 g');
    });
  });

  group('真实场景：一餐三道菜的备菜清单', () {
    test('合并结果可解释', () {
      final r = mergeIngredients([
        [
          _r('番茄', '2 个', main: true),
          _r('鸡蛋', '3 个'),
          _r('小葱', '1 根'),
          _r('食盐', '适量'),
        ],
        [
          _r('番茄', '300 g', main: true),
          _r('牛腩', '500 g'),
          _r('食盐', '适量'),
          _r('番茄酱', '2 汤匙'),
        ],
      ], sourceNames: ['番茄炒蛋', '番茄牛腩']);

      final byName = {for (final e in r) e.name: e};

      expect(byName['番茄']!.qtyText, '300 g + 2 个');
      expect(byName['番茄']!.from, ['番茄炒蛋', '番茄牛腩']);
      expect(byName['鸡蛋']!.qtyText, '3 个');
      expect(byName['食盐']!.qtyText, '适量');
      // 番茄酱必须独立成行，不能被并进番茄
      expect(byName.containsKey('番茄酱'), isTrue);
      expect(byName['番茄酱']!.qtyText, '2 汤匙');
    });
  });
}
