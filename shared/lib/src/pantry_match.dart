import 'dart:convert';

/// 库存 × 菜谱匹配（R28 · 清空冰箱）。
///
/// **为什么放 shared**：这是「买不买、做什么」的判定算法——
/// 算错一次，用户就跑一次冤枉腿。放 shared 让 app 与将来的推荐页
/// 消费同一份实现，与服务端同仓库同测试钉住（同 `ingredient.dart` 的立场）。
///
/// 匹配规则（FR-RECO-02/03，按需求逐条对）：
/// - 食材同名比对走**归一键**（别名表复用 `ingredient.dart` 的显式词表），
///   主料缺失**大幅降权**——主料不齐的菜排进「差一点」都是误导；
/// - 「适量/少许」类模糊量算**存在即可**，不比对分量；
/// - 常备调料（`isStaple`）不参与缺失计算（FR-PAN-05）——
///   盐永远“算有”，但没盐的菜照样是真缺盐，这类噪音一次就能劝退用户。
///
/// 输出分三组（FR-RECO-03）：
/// `canCook` 主配料全齐 / `almostThere` 缺 1~2 样（不含被降权的缺主料）/
/// `needShopping` 其余。
class PantryMatch {
  const PantryMatch._();

  /// [recipes]：`{id, name, ingredients:[{name, qtyText, isMain, isStapleOk?}...]}`
  /// （调用方已把菜谱行整理好；这里不认 schema，只认最小形状）。
  /// [pantry]：`{name, aliasKey, have(0/1), qtyValue(null=只记有), isStaple}`。
  /// 返回按匹配度排序的三组结果，每条含 `matched` / `missing` 明细。
  static Map<String, Object?> recommend({
    required List<Map<String, Object?>> recipes,
    required List<Map<String, Object?>> pantry,
    int almostThreshold = 2,
  }) {
    // 库存索引：优先按归一键，名称兜底。只收「有货」的（have=1）。
    final have = <String>{};
    for (final p in pantry) {
      final has = (p['have'] as int? ?? 1) == 1;
      if (!has) continue;
      final key = '${p['aliasKey'] ?? ''}'.trim();
      final name = '${p['name'] ?? ''}'.trim();
      if (key.isNotEmpty) have.add(key);
      if (name.isNotEmpty) have.add(name);
    }

    bool stocked(Map<String, Object?> ing) {
      final name = '${ing['name'] ?? ''}'.trim();
      final key = '${ing['aliasKey'] ?? ''}'.trim();
      return (key.isNotEmpty && have.contains(key)) || have.contains(name);
    }

    final canCook = <Map<String, Object?>>[];
    final almostThere = <Map<String, Object?>>[];
    final needShopping = <Map<String, Object?>>[];

    for (final r in recipes) {
      final ings = ((r['ingredients'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, Object?>())
          .toList();
      final matched = <String>[];
      final missing = <Map<String, Object?>>[];
      var missingMain = false;
      for (final i in ings) {
        final isMain = i['isMain'] == true || i['isMain'] == 1;
        // 常备调料豁免：库没配它也不该判缺（没盐的判定交给用户常识）
        final stapleOk = i['isStaple'] == true || i['isStaple'] == 1;
        if (stapleOk || stocked(i)) {
          matched.add('${i['name']}');
        } else {
          missing.add({
            'name': i['name'],
            'qtyText': i['qtyText'] ?? '',
            'isMain': isMain,
          });
          if (isMain) missingMain = true;
        }
      }
      final total = ings.isEmpty ? 1 : ings.length;
      // 匹配度：已覆盖 / 所需；**缺主料直接打七折再减 0.3**——
      // 「差一样主料」和「差一样姜丝」不是同一种差一点（FR-RECO-02 的大幅降权）。
      var score = (total - missing.length) / total;
      if (missingMain) score = score * 0.7 - 0.3;

      final entry = {
        'id': r['id'],
        'name': r['name'],
        'matched': matched,
        'missing': missing,
        'missingMain': missingMain,
        'score': double.parse(score.clamp(0.0, 1.0).toStringAsFixed(4)),
      };
      if (missing.isEmpty) {
        canCook.add(entry);
      } else if (missing.length <= almostThreshold && !missingMain) {
        almostThere.add(entry);
      } else {
        needShopping.add(entry);
      }
    }

    int byScore(Map<String, Object?> a, Map<String, Object?> b) =>
        (b['score'] as double).compareTo(a['score'] as double);
    canCook.sort(byScore);
    almostThere.sort(byScore);
    needShopping.sort(byScore);
    return {
      'canCook': canCook,
      'almostThere': almostThere,
      'needShopping': needShopping,
    };
  }

  /// 库存行的归一键 = 名称清洗（与写入侧一致的最低约定）。
  static String aliasKeyOf(String name) {
    final n = name.trim();
    // 常见单位尾巴剁掉：「番茄2个」→「番茄」；纯中文名原样。
    return n.replaceAll(RegExp(r'\d+(\.\d+)?\s*(个|克|g|kg|斤|两|ml|L|l|袋|盒|包|根|只|头|块|片|勺|汤匙)*$'), '').trim();
  }
}
