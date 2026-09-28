/// 过敏原与忌口命中判定（R40 · FR-SET-04/05）。
///
/// **为什么放 shared**：这是"能不能给家人吃"的判定。Android 端算一套、
/// Web 端算另一套，早晚会有一台设备在某个菜上不报警——而漏报的代价是
/// 有人被送急诊。判定必须只有一份实现、一份测试（同 `conflict.dart` 的立场）。
///
/// ## 一条贯穿全文件的立场：宁可误报，不可漏报
///
/// 误报 = 屏幕上多一条"妈妈 过敏 · 花生"，人看一眼就知道怎么处理；
/// 漏报 = 一道含过敏原的菜被当成安全菜端上桌。**两种错误的代价差着数量级**，
/// 所以所有边界都往"报出来"那侧倾斜：
///
/// - 「虾」命中"基围虾"、"虾皮"、"虾滑"（双向包含）；
/// - 「贝类」这类**类名**光靠包含命中不了"扇贝/花甲/蚝油"——它们字面上没有"贝类"两个字。
///   这是原型的朴素写法真正的漏洞，也是 [kCategoryWords] 存在的唯一理由；
/// - ★ **同物异名**（成员填「番茄」、菜里写「西红柿」）光靠包含也命中不了，
///   而且这是**漏报方向**。别名表 [kIngredientAliases] 由调用方传进来，
///   与备菜合并**共用同一张表**（R42 把它从 app 挪进 shared 就是为了这件事）；
/// - 不确定的加工品（"食用香精""可能含有坚果"）不在词表里，
///   那种信息只有用户自己知道——所以成员页允许自由填词（填什么就命中什么）。
///
/// ## 过敏 ≠ 忌口
///
/// [AllergenHit.isAllergy] 为真走**警告**（条纹 + 图标 + 写明谁），
/// 忌口只走**提示**（淡一档）。把"爸爸不吃香菜"做成红色警告，
/// 用户三天后就开始无视所有警告——那时真正的过敏也一起被无视了。
///
/// 归一器 `norm` 与别名表都来自 `ingredient.dart`：**一份表、两处用**，
/// 判定与合并对同一样东西的叫法必须一致。

library;

import 'ingredient.dart';
class AllergenWord {
  const AllergenWord(this.text);

  /// 用户填的那个词（"虾"、"贝类"、"香菜"……）。
  final String text;
}

/// 一次命中：谁、因为哪个词、命中在哪样食材上。
class AllergenHit {
  const AllergenHit({
    required this.memberId,
    required this.memberName,
    required this.word,
    required this.kind,
    required this.ingredient,
  });

  final String memberId;
  final String memberName;

  /// 成员填的那个过敏原/忌口词（原样回显，不改写用户的字）。
  final String word;

  /// 'allergy'（过敏，警告） / 'dislike'（忌口，提示）。
  final String kind;

  /// 命中的食材行原文（"基围虾 400 g" 里的"基围虾"）。
  final String ingredient;

  bool get isAllergy => kind == 'allergy';

  @override
  String toString() => '$memberName|$kind|$word←$ingredient';
}

class AllergenMatch {
  const AllergenMatch._();

  /// **类名 → 成员词**。只有"字面上不含类名"的食材才需要这张表：
  /// 「虾」→"基围虾" 靠双向包含就能命中，不必进来占位；
  /// 「贝类」→"扇贝/花甲/蚝油" 靠包含永远命不中，必须列出来。
  ///
  /// 词表只放**高置信**成员（吃了就出事的那一类），刻意不追求穷尽：
  /// 酱油算不算大豆、燕麦算不算麸质，是各家的医嘱问题，不是算法问题——
  /// 用户在成员页自己加词就能覆盖，比在这里替他猜更负责。
  static const Map<String, List<String>> kCategoryWords = {
    '贝类': [
      '扇贝', '蛤蜊', '花甲', '生蚝', '牡蛎', '蚝油', '鲍鱼', '蛏子',
      '青口', '贻贝', '淡菜', '干贝', '瑶柱', '蚬子', '海螺', '田螺', '蚌',
    ],
    '甲壳类': ['虾', '蟹', '龙虾', '小龙虾', '皮皮虾', '虾皮', '虾米', '虾滑', '蟹黄', '磷虾'],
    '坚果': [
      '核桃', '腰果', '杏仁', '榛子', '松子', '开心果', '夏威夷果',
      '碧根果', '山核桃', '板栗', '栗子', '杏仁露',
    ],
    '花生': ['花生', '落花生', '长生果', '花生酱', '花生油'],
    '鱼类': [
      '鱼', '三文鱼', '金枪鱼', '鲈鱼', '鲫鱼', '黄花鱼', '带鱼', '秋刀鱼',
      '鳕鱼', '鲢鱼', '鳙鱼', '鲷鱼', '鳗鱼', '鱼丸', '鱼露', '鱼豆腐',
    ],
    '麸质': [
      '小麦', '面粉', '面条', '挂面', '馒头', '包子', '饺子', '馄饨',
      '面包', '蛋糕', '面筋', '大麦', '麸皮', '饼干',
    ],
    '乳制品': ['牛奶', '鲜奶', '奶油', '黄油', '奶酪', '芝士', '奶粉', '炼乳', '酸奶', '马苏里拉'],
    '蛋类': ['鸡蛋', '蛋黄', '蛋白', '蛋液', '鹌鹑蛋', '皮蛋', '咸鸭蛋', '沙拉酱'],
    '大豆': ['大豆', '黄豆', '黑豆', '豆腐', '豆浆', '豆干', '腐竹', '毛豆', '豆皮'],
    '芝麻': ['芝麻', '黑芝麻', '白芝麻', '香油', '麻油', '芝麻酱'],
    '香菜': ['香菜', '芫'],
    '芒果': ['芒果', '杧果'],
    '辣椒': ['辣椒', '小米辣', '干辣椒', '豆瓣酱', '辣酱', '甜椒', '彩椒'],
    '葱': ['葱', '小葱', '大葱', '香葱', '洋葱', '葱花'],
    '蒜': ['蒜', '大蒜', '蒜苗', '蒜苔', '蒜末', '蒜蓉'],
  };

  /// 归一：去空白、去尾部的"数量 + 单位"与模糊量词（"基围虾 400 g" → "基围虾"）。
  /// 与原型 `allergenHits()` 里那条 replace 同语义，但那边只砍了单位没砍数字，
  /// "虾 400克" 归一出来是"虾400"——两边都保留这条，是为了让"食材行原文"
  /// 直接喂进来也能命中；砍不干净就是漏报，所以这里循环剥到不动为止。
  static String norm(String raw) {
    var s = raw.replaceAll(RegExp(r'\s+'), '');
    final tail = RegExp(
        r'(?:[\d.]+)?(?:克|千克|公斤|kg|g|G|毫升|升|ml|L|个|只|头|把|片|段|颗|粒|勺|根|条|块|适量|少许|一点|若干)$');
    String prev;
    do {
      prev = s;
      s = s.replaceFirst(tail, '');
    } while (s != prev && s.isNotEmpty);
    return s;
  }

  /// 找出某个词所属的类：键命中（"贝类"）或成员命中（"牛奶" ∈ 乳制品）都算。
  ///
  /// ★ 成员也算，是因为**用户填的是具体词、不是类名**：他写"牛奶"，
  ///   那"黄油/奶酪/奶油"就该一起报；只认键等于这张表对半数填法失效。
  ///   副作用要说清楚：填"虾"会连带报蟹（同属甲壳类）——
  ///   甲壳类交叉过敏在医嘱里很常见，而本文件的立场是宁可多报一次。
  static List<String>? _groupOf(String word) {
    for (final e in kCategoryWords.entries) {
      if (e.key == word) return e.value;
      if (e.value.any((m) => m == word)) return e.value;
    }
    return null;
  }

  /// 一个过敏原词与一个食材名是否算命中。
  ///
  /// 三条任一即命中（顺序按"最常见 → 最兜底"）：
  ///  1. 归一后相等，**或两边经 [aliases] 展开成同义词后相等/互相包含**
  ///     （R42：成员填「番茄」、菜里写「西红柿」必须命中——那是漏报方向）；
  ///  2. 双向包含（食材名含词，或词含食材名——"鸡蛋"↔"蛋"两个方向都要成立）；
  ///  3. 词是类名（在 [kCategoryWords] 里），且食材名命中该类任一成员词。
  ///
  /// 第 3 条**只对过敏做**：忌口误报的代价是"提示多了没人看"，
  /// 而"爸爸不吃葱"因为"洋葱"被拦一道菜，纯属添堵。
  /// 第 1 条的别名展开**过敏与忌口都做**：西红柿和番茄是同一样东西，
  /// 不是"同类"，展开它没有任何猜的成分，关掉只会漏报。
  static bool hit({
    required String ingredient,
    required String word,
    bool expandCategory = true,
    Map<String, String> aliases = const {},
  }) {
    final i = norm(ingredient), w = norm(word);
    if (i.isEmpty || w.isEmpty) return false;
    // 两边各自展开成同义词组（空别名表时就是各自本身，行为与 R40 完全一致）
    // 变量别叫 is/in：`is` 是 Dart 的关键字，`in` 在 for 里也是
    final iSet = aliases.isEmpty ? {i} : aliasGroup(i, aliases);
    final wSet = aliases.isEmpty ? {w} : aliasGroup(w, aliases);
    for (final a in iSet) {
      for (final b in wSet) {
        if (a.isEmpty || b.isEmpty) continue;
        if (a == b) return true;
        if (a.contains(b) || b.contains(a)) return true;
      }
    }
    if (!expandCategory) return false;
    for (final b in wSet) {
      // 走 _groupOf 而不是 kCategoryWords[b]：用户填的多半是"牛奶""小麦"这种
      // **成员词**，只查键的话这张表对半数填法直接失效（第一轮测试就是这么红的）。
      final members = _groupOf(b);
      if (members == null) continue;
      for (final a in iSet) {
        if (a.isEmpty) continue;
        if (members.any((m) => m.isNotEmpty && (a.contains(m) || m.contains(a)))) {
          return true;
        }
      }
    }
    return false;
  }

  /// 一道菜 × 全家成员 → 命中清单（按人聚合，过敏排在忌口前）。
  ///
  /// [ingredients]：食材名原文列表（详情页/卡片都从这儿喂，保证四处口径一致）。
  /// [members]：`{id, name, allergens:[...], dislikes:[...]}`。
  /// [aliases]：同义词表（`kIngredientAliases`）。调用方按本机开关决定传不传，
  /// 判定本身不猜开关语义。
  static List<AllergenHit> matchRecipe({
    required List<String> ingredients,
    required List<Map<String, Object?>> members,
    Map<String, String> aliases = const {},
  }) {
    final out = <AllergenHit>[];
    final seen = <String>{};
    for (final m in members) {
      final id = '${m['id'] ?? ''}';
      final name = '${m['name'] ?? ''}';
      // 先过敏后忌口：聚合视图里"警告"要排在"提示"前面
      final rounds = <(List<String>, String)>[
        (_words(m['allergens']), 'allergy'),
        (_words(m['dislikes']), 'dislike'),
      ];
      for (final (words, kind) in rounds) {
        final expand = kind == 'allergy';
        for (final raw in words) {
          if (norm(raw).isEmpty) continue;
          for (final ing in ingredients) {
            if (!hit(
                ingredient: ing,
                word: raw,
                expandCategory: expand,
                aliases: aliases)) continue;
            final key = '$id|$kind|$raw|$ing';
            if (!seen.add(key)) continue;
            out.add(AllergenHit(
              memberId: id,
              memberName: name,
              word: raw,
              kind: kind,
              ingredient: ing,
            ));
          }
        }
      }
    }
    out.sort((a, b) => (b.isAllergy ? 1 : 0).compareTo(a.isAllergy ? 1 : 0));
    return out;
  }

  /// schema 里 allergens/dislikes 存的是 JSON 数组文本，调用方解好再传；
  /// 这里只兜"传了 null / 非字符串元素"两种脏形状，不猜任何内容。
  static List<String> _words(Object? raw) => raw is List
      ? [for (final e in raw) '$e']
      : const <String>[];
}
