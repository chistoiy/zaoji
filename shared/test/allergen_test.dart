import 'package:test/test.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// R40 · 过敏原命中判定（FR-SET-04/05）。
///
/// 这一组测试是**安全侧的**：判定错一次的后果不是"界面难看"，
/// 是把含过敏原的菜当安全菜端上桌。所以每条断言都在钉一件事——
/// 该报的必须报出来，而"报什么"由用户填的词决定，算法不替他猜、也不替他漏。
void main() {
  Map<String, Object?> member(
    String id,
    String name, {
    List<String> allergies = const [],
    List<String> dislikes = const [],
  }) =>
      {'id': id, 'name': name, 'allergens': allergies, 'dislikes': dislikes};

  group('双向包含（原型原有能力，必须保住）', () {
    test('「虾」命中基围虾 / 虾仁 / 虾滑', () {
      for (final ing in ['基围虾', '虾仁', '虾滑', '白虾']) {
        expect(AllergenMatch.hit(ingredient: ing, word: '虾'), isTrue,
            reason: '$ing 含「虾」，漏报等于让爸爸吃下去');
      }
    });

    test('反向也成立：「鸡蛋」命中食材行里的"蛋"', () {
      expect(AllergenMatch.hit(ingredient: '蛋', word: '鸡蛋'), isTrue,
          reason: '小宝过敏写"鸡蛋"、菜里只写"蛋"，也得报');
    });

    test('不相关的食材不误命中', () {
      expect(AllergenMatch.hit(ingredient: '番茄', word: '虾'), isFalse);
      expect(AllergenMatch.hit(ingredient: '土豆', word: '牛奶'), isFalse);
    });
  });

  group('类名表（这张表存在的唯一理由）', () {
    test('「贝类」命中扇贝 / 花甲 / 蚝油——纯包含永远命不中它们', () {
      for (final ing in ['扇贝', '花甲', '蚝油', '生蚝', '干贝', '鲍鱼']) {
        expect(AllergenMatch.hit(ingredient: ing, word: '贝类'), isTrue,
            reason: '$ing 字面上没有"贝类"两个字，靠包含会漏报');
      }
    });

    test('坚果 / 麸质 / 乳制品 / 芝麻 各自展开', () {
      expect(AllergenMatch.hit(ingredient: '腰果', word: '坚果'), isTrue);
      expect(AllergenMatch.hit(ingredient: '核桃', word: '坚果'), isTrue);
      expect(AllergenMatch.hit(ingredient: '面条', word: '麸质'), isTrue);
      expect(AllergenMatch.hit(ingredient: '馒头', word: '小麦'), isTrue);
      expect(AllergenMatch.hit(ingredient: '黄油', word: '牛奶'), isTrue);
      expect(AllergenMatch.hit(ingredient: '香油', word: '芝麻'), isTrue);
      expect(AllergenMatch.hit(ingredient: '芫荽', word: '香菜'), isTrue);
    });

    test('表外食材不硬凑：瓜子不是坚果、白糖不是麸质', () {
      expect(AllergenMatch.hit(ingredient: '白糖', word: '麸质'), isFalse);
      expect(AllergenMatch.hit(ingredient: '豆腐', word: '贝类'), isFalse);
    });

    test('★ 类名展开只对「过敏」生效，忌口不展开', () {
      // 忌口是口味问题。把"爸爸不吃贝类"扩成拦住每一道扇贝，
      // 用户三天后就开始无视所有提示——那时真正的过敏也一起被无视。
      final hits = AllergenMatch.matchRecipe(
        ingredients: ['扇贝', '蒜蓉'],
        members: [member('m2', '爸爸', dislikes: ['贝类'])],
      );
      expect(hits, isEmpty);

      final same = AllergenMatch.matchRecipe(
        ingredients: ['扇贝', '蒜蓉'],
        members: [member('m2', '爸爸', allergies: ['贝类'])],
      );
      expect(same, hasLength(1));
    });
  });

  group('归一与脏输入', () {
    test('带量词尾巴的食材行原文也能命中', () {
      expect(AllergenMatch.norm('基围虾 400 g'), '基围虾');
      expect(AllergenMatch.hit(ingredient: '虾 400克', word: '虾'), isTrue);
      expect(AllergenMatch.hit(ingredient: '盐 适量', word: '盐'), isTrue);
    });

    test('★ 空词不许命中一切（否则一个空过敏原就废掉整份菜谱）', () {
      expect(AllergenMatch.hit(ingredient: '番茄', word: ''), isFalse);
      expect(AllergenMatch.hit(ingredient: '番茄', word: '   '), isFalse);
      final hits = AllergenMatch.matchRecipe(
        ingredients: ['番茄', '鸡蛋'],
        members: [member('m1', '妈妈', allergies: ['', '  '])],
      );
      expect(hits, isEmpty);
    });

    test('成员表缺字段 / 传了非字符串元素也不炸', () {
      final hits = AllergenMatch.matchRecipe(ingredients: ['虾'], members: [
        {'id': 'm1', 'name': '妈妈'},
        {'id': 'm2', 'name': '爸爸', 'allergens': [null, 12, '虾']},
        {'id': 'm3'},
      ]);
      expect(hits, hasLength(1));
      expect(hits.single.memberName, '爸爸');
    });
  });

  group('整道菜的聚合结果', () {
    test('按人按词聚合，命中食材原文回显', () {
      final hits = AllergenMatch.matchRecipe(
        ingredients: ['基围虾', '豆腐', '香葱'],
        members: [
          member('m1', '妈妈', allergies: ['花生', '坚果'], dislikes: ['香菜']),
          member('m2', '爸爸', allergies: ['虾', '贝类'], dislikes: ['葱']),
          member('m3', '小宝', allergies: ['鸡蛋'], dislikes: ['辣椒']),
        ],
      );
      expect(
        hits.map((h) => '${h.memberName}/${h.word}←${h.ingredient}'),
        containsAll(['爸爸/虾←基围虾', '爸爸/葱←香葱']),
      );
      expect(hits.where((h) => h.memberName == '爸爸' && h.isAllergy), hasLength(1));
      expect(hits.where((h) => h.memberName == '爸爸' && !h.isAllergy), hasLength(1),
          reason: '忌口"葱"命中"香葱"，是提示不是警告');
      expect(hits.where((h) => h.memberName == '妈妈'), isEmpty,
          reason: '这道菜里没有花生/坚果/香菜');
    });

    test('过敏项排在忌口项前面（界面直接按序渲染）', () {
      final hits = AllergenMatch.matchRecipe(
        ingredients: ['香菜', '虾'],
        members: [
          member('m2', '爸爸', allergies: ['虾'], dislikes: ['香菜']),
        ],
      );
      expect(hits.first.isAllergy, isTrue);
      expect(hits.last.isAllergy, isFalse);
    });

    test('同一人同词同食材不重复报', () {
      final hits = AllergenMatch.matchRecipe(
        ingredients: ['虾', '虾仁'],
        members: [member('m2', '爸爸', allergies: ['虾', '甲壳类'])],
      );
      final keys = hits.map((h) => '${h.memberId}|${h.word}|${h.ingredient}');
      expect(keys.toSet().length, keys.length);
    });

    test('没有成员时返回空，不抛', () {
      expect(AllergenMatch.matchRecipe(ingredients: ['虾'], members: []), isEmpty);
    });
  });
}
