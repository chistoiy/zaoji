/// 一键备菜的食材合并。
///
/// 输入「若干道菜的食材清单」，输出「一份去重、分量累加过的采购清单」。
/// 规则来自 FR-PLAN-04 ~ 07：
/// ① 同名食材合并为一条；
/// ② 可换算单位折算后相加（200 g + 0.3 kg = 500 g）；
/// ③ 「适量」类**不参与累加**，只保留一次；
/// ④ 别名归一（番茄 / 西红柿 是同一样东西）。
///
/// 表现要求：合并结果要能**解释自己**——用户看到「500 g」时，
/// 应该能点开看到「来自：番茄炒蛋 200 g、番茄牛腩 0.3 kg」。
library;

import 'units.dart';

class IngredientRef {
  final String name;
  final String qty;

  /// 主食材标记。用于推荐算法判定「主料缺失则匹配度减半」。
  final bool isMain;

  /// 调用方（App 查本地库 / 服务端查 DB）预先算好的归一键。
  /// 为空时由 `resolver` 现场算。
  final String? aliasKey;

  const IngredientRef({
    required this.name,
    required this.qty,
    this.isMain = false,
    this.aliasKey,
  });
}

/// 合并后的一行。
class MergedLine {
  final String key;
  final String name;

  /// 各量纲的分量。质量已归一到 g，体积到 ml，个量词按原单位保留。
  final List<Amount> parts;

  /// 来源菜品名（去重，保序）——「这 500 g 是哪儿来的」
  final List<String> from;

  /// 是否含模糊量
  final bool anyVague;

  const MergedLine({
    required this.key,
    required this.name,
    required this.parts,
    required this.from,
    required this.anyVague,
  });

  /// 渲染成分量文本，如 `500 g + 2 个`。
  String get qtyText {
    if (parts.isEmpty) return '';
    final rendered = <String>[];
    for (final p in parts) {
      switch (p.kind) {
        case AmountKind.mass:
        case AmountKind.volume:
          rendered.add(formatAmount(p.value!, p.unit, p.kind));
        case AmountKind.count:
          rendered.add(formatAmount(p.value!, p.unit, p.kind));
        case AmountKind.vague:
          if (!rendered.contains(p.unit)) rendered.add(p.unit);
        case AmountKind.unparsed:
          if (!rendered.contains(p.raw)) rendered.add(p.raw);
      }
    }
    return rendered.join(' + ');
  }

  /// 是否为「合并产生」的行（用于界面上标「3 道菜合并」）
  bool get isMerged => from.length > 1 || parts.length > 1;

  @override
  String toString() => '$name $qtyText ← ${from.join("、")}';
}

/// 别名归一函数。App 端从 SQLite 读别名表，服务端从自己的库读，
/// 但**算法必须是这一个**。
typedef AliasResolver = String Function(String rawName);

/// 最保守的默认归一：只做宽度与空白处理。
/// 不猜、不猜、不猜——猜错会把两道菜的用量加到同一条上。
String identityAliasResolver(String rawName) => normalizeWidth(rawName).trim();

/// 「加工形态」后缀。
///
/// 这是子串兜底匹配最容易踩的坑：
/// `龙口粉丝` → `粉丝` 是对的；但 `番茄酱` → `番茄` 就**错得离谱**——
/// 一个是蔬菜一个是调味料，把它们累加到一起，用户会买错东西。
///
/// 判断依据：多出来的部分如果**全部**由这些字构成，说明它是"加工过的形态"，
/// 不是同一样东西，拒绝归一。
const Set<String> _processedFormChars = {
  '酱', '汁', '粉', '干', '丝', '片', '块', '条', '油', '醋', '膏',
  '精', '沫', '泥', '沙', '蓉', '松', '脯', '皮', '壳', '籽', '仁',
  '米', '面', '糊', '浆', '卤', '糟', '腌', '泡', '烤', '炸', '熏',
};

bool _isProcessedForm(String extra) =>
    extra.isNotEmpty && extra.split('').every(_processedFormChars.contains);

/// 基于已知食材词表的归一器。
///
/// 做两件事：
/// ① 精确命中 → 返回词表里的键；
/// ② **子串兜底**：`龙口粉丝 → 粉丝`、`带皮五花肉 → 五花肉`、`嫩豆腐 → 豆腐`。
///    取最长匹配，避免「五花肉」被「肉」抢走；并排除加工形态（见上）。
class PantryAliasResolver {
  final Set<String> known;
  final Map<String, String> explicit;

  PantryAliasResolver(Iterable<String> knownKeys, {Map<String, String>? explicit})
      : known = knownKeys.toSet(),
        explicit = explicit ?? const {};

  String resolve(String rawName) {
    final raw = normalizeWidth(rawName).trim();
    if (raw.isEmpty) return raw;

    final byMap = explicit[raw];
    if (byMap != null) return byMap;
    if (known.contains(raw)) return raw;

    // 最长子串匹配：已知词是 raw 的一部分
    String? best;
    for (final k in known) {
      if (k.isEmpty) continue;
      if (!raw.contains(k)) continue;
      if (best != null && k.length <= best.length) continue;
      // ★ 关键防护：多出来的部分是「加工形态」时拒绝归一。
      //   番茄 ≠ 番茄酱（蔬菜 vs 调味料），辣椒 ≠ 干辣椒，
      //   但 粉丝 ＝ 龙口粉丝。这三条必须同时成立才算对。
      final extra = raw.replaceFirst(k, '');
      if (_isProcessedForm(extra)) continue;
      best = k;
    }
    if (best != null) return best;

    // 反向：raw 是已知词的一部分（用户写「粉丝」，库存里叫「龙口粉丝」）
    for (final k in known) {
      if (raw.isNotEmpty && k.contains(raw) && (best == null || k.length < best.length)) {
        best = k;
      }
    }
    return best ?? raw;
  }
}

/// 合并多批食材。
///
/// [batches] 每一项是一道菜的食材列表，顺序即 [from] 里来源菜名的顺序。
/// [sourceNames] 与 [batches] 一一对应，用于「来自哪几道菜」。
List<MergedLine> mergeIngredients(
  List<List<IngredientRef>> batches, {
  List<String>? sourceNames,
  AliasResolver resolver = identityAliasResolver,
}) {
  final groupKeys = <String>[]; // 保持首次出现顺序
  final grouped = <String, List<_Entry>>{};

  for (var b = 0; b < batches.length; b++) {
    final source = (sourceNames != null && b < sourceNames.length)
        ? sourceNames[b]
        : '第 ${b + 1} 道菜';
    for (final ref in batches[b]) {
      final key = ref.aliasKey ?? resolver(ref.name);
      final normalized = key.isEmpty ? normalizeWidth(ref.name).trim() : key;
      if (normalized.isEmpty) continue;

      if (!grouped.containsKey(normalized)) {
        grouped[normalized] = <_Entry>[];
        groupKeys.add(normalized);
      }
      grouped[normalized]!.add(_Entry(ref: ref, source: source));
    }
  }

  final out = <MergedLine>[];
  for (final key in groupKeys) {
    final entries = grouped[key]!;

    // 按量纲 + 单位桶累加
    final massTotal = <double>[0];
    final volumeTotal = <double>[0];
    final countTotals = <String, double>{};
    final vagueParts = <Amount>[];
    final rawParts = <Amount>[];
    final from = <String>[];
    var anyVague = false;

    for (final e in entries) {
      if (!from.contains(e.source)) from.add(e.source);
      final amount = parseAmount(e.ref.qty);
      switch (amount.kind) {
        case AmountKind.mass:
          massTotal[0] += amount.value!;
        case AmountKind.volume:
          volumeTotal[0] += amount.value!;
        case AmountKind.count:
          countTotals[amount.unit] = (countTotals[amount.unit] ?? 0) + amount.value!;
        case AmountKind.vague:
          anyVague = true;
          if (!vagueParts.any((p) => p.unit == amount.unit)) vagueParts.add(amount);
        case AmountKind.unparsed:
          if (!rawParts.any((p) => p.raw == amount.raw)) rawParts.add(amount);
      }
    }

    final parts = <Amount>[];
    // 质量：大于 0 才输出。0 值没有意义，且会渲染成刺眼的「0 g」。
    if (massTotal[0] > 0) {
      parts.add(Amount(
        value: massTotal[0],
        unit: 'g',
        kind: AmountKind.mass,
        raw: formatAmount(massTotal[0], 'g', AmountKind.mass),
      ));
    }
    if (volumeTotal[0] > 0) {
      parts.add(Amount(
        value: volumeTotal[0],
        unit: 'ml',
        kind: AmountKind.volume,
        raw: formatAmount(volumeTotal[0], 'ml', AmountKind.volume),
      ));
    }
    // 个量词：按单位名稳定排序，保证两端渲染顺序一致
    final countKeys = countTotals.keys.toList()..sort();
    for (final u in countKeys) {
      parts.add(Amount(
        value: countTotals[u],
        unit: u,
        kind: AmountKind.count,
        raw: formatAmount(countTotals[u]!, u, AmountKind.count),
      ));
    }
    parts.addAll(vagueParts);
    parts.addAll(rawParts);

    out.add(MergedLine(
      key: key,
      name: _displayName(entries.map((e) => e.ref.name).toList()),
      parts: parts,
      from: from,
      anyVague: anyVague,
    ));
  }

  return out;
}

class _Entry {
  final IngredientRef ref;
  final String source;
  const _Entry({required this.ref, required this.source});
}

/// 展示名取**最短**的那个 —— 通常最短的是最通用的写法
/// （「番茄」比「本地小番茄」更适合当合并后的标题）。
String _displayName(List<String> names) {
  if (names.isEmpty) return '';
  var best = names.first;
  for (final n in names) {
    if (n.length < best.length) best = n;
  }
  return best;
}
