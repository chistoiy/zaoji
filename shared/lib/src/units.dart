/// 单位换算与分量解析。
///
/// 产品定位是「**辅助决策，不是账本**」——允许只记「有 / 没有」，
/// 也允许模糊。所以这里的原则是：
/// 能精确换算的（g / kg / 斤 / ml / L）**必须**精确折算；
/// 不能精确换算的（一勺、一把、少许）**绝不假装精确**，
/// 宁可原样列出，也不要给用户一个算错的数字。
library;

import 'cn_number.dart';

/// 分量的量纲。
enum AmountKind {
  /// 质量，一律归一到克
  mass,

  /// 体积，一律归一到毫升
  volume,

  /// 个量词（个 / 只 / 根 / 勺 …），只按**同名单位**相加
  count,

  /// 模糊量（适量 / 少许），不参与累加
  vague,

  /// 解析不出，原样保留
  unparsed,
}

class Amount {
  /// 归一后的数值。`vague` / `unparsed` 时为 null。
  final double? value;

  /// 归一后的单位：mass→`g`，volume→`ml`，count→原单位名。
  final String unit;

  final AmountKind kind;

  /// 用户原文，展示与回写都用它，避免"我写的是适量，你给我看成 0"
  final String raw;

  const Amount({
    required this.value,
    required this.unit,
    required this.kind,
    required this.raw,
  });

  /// 能否参与累加。模糊量与解析失败都不能。
  bool get isAddable =>
      value != null && kind != AmountKind.vague && kind != AmountKind.unparsed;

  @override
  String toString() => '$raw(${kind.name}${value == null ? '' : ' $value$unit'})';
}

/// 质量 → 克
const Map<String, double> kMassToGram = {
  'kg': 1000, '千克': 1000, '公斤': 1000,
  '斤': 500, '两': 50,
  'g': 1, '克': 1,
  'mg': 0.001, '毫克': 0.001,
};

/// 体积 → 毫升。
///
/// 键**一律小写**：匹配前会把输入转成小写，
/// 所以 `1.5 L`、`1.5l`、`1.5 升` 三者等价。
///
/// 踩过的坑：表里只写了 `'l'` 而漏了 `'L'`，
/// 结果「1.5 L」静默退化成 unparsed —— 它不会报错，只是默默算不对。
/// 这类 bug 只有单测能挡住。
const Map<String, double> kVolumeToMl = {
  'l': 1000, '升': 1000,
  'ml': 1, '毫升': 1, 'cc': 1,
};

/// 个量词。**不做跨量词换算**——「1 个番茄 + 200 g 番茄」就是两个数，
/// 硬加只会得到一个错误的数字。
const Set<String> kCountUnits = {
  '个', '只', '颗', '根', '把', '头', '块', '朵', '片', '张', '条', '瓣',
  '盒', '袋', '瓶', '罐', '包', '束', '串', '扎', '筐', '篮',
  '勺', '大勺', '小勺', '汤匙', '茶匙', '碗', '杯', '碟', '盘',
};

/// 模糊量。归到这一类的词，**只保留一次，绝不累加**。
/// 「适量 ×3」是备菜清单里最让人恼火的东西。
const Set<String> kVagueAmounts = {
  '适量', '少许', '少量', '一些', '若干', '足量', '按需',
  '酌情', '随口味', '看情况', '随意', '一点', '些许', '一撮',
};

/// 全角 → 半角（数字、字母、空格、常见标点）。
/// 中文输入法下这是高频情况：`２ 个`、`ｇ`、全角空格。
String normalizeWidth(String s) {
  final buf = StringBuffer();
  for (final rune in s.runes) {
    if (rune == 0x3000) {
      buf.write(' ');
    } else if (rune >= 0xFF01 && rune <= 0xFF5E) {
      buf.writeCharCode(rune - 0xFEE0);
    } else {
      buf.writeCharCode(rune);
    }
  }
  return buf.toString();
}

final RegExp _rangePattern = RegExp(
  r'^(\d+(?:\.\d+)?)\s*(?:-|~|～|—|–|至|到)\s*(\d+(?:\.\d+)?)$',
);
final RegExp _fractionPattern = RegExp(r'^(\d+)\s*/\s*(\d+)$');
final RegExp _decimalPattern = RegExp(r'^\d+(?:\.\d+)?$');

/// 单个的量词字。
///
/// 用于把 `2个` / `两个` / `半个` 这类 token 剥成**纯数值**。
/// 注意它只影响数值解析，**不改变单位判定**。
///
/// 踩过的坑：`parseStepTimes('再炖半个小时')` 一开始返回空——
/// 因为「个」不被认作数值字符，向左回看时直接断了，
/// 而「半个 小时」恰恰是最常见的写法之一。
const String kMeasureChars = '个只颗根把头块朵片张条瓣盒袋瓶罐包束串碗杯勺次遍';

/// 解析数值片段（不含单位）。
///
/// 支持：`2` / `0.3` / `1/2` / `三` / `一个半` / `2个半` / `半` /
/// `200-250`（区间取上限——备菜时宁可多买）。
double? parseNumericToken(String token) {
  var t = normalizeWidth(token).trim().replaceAll(' ', '');
  if (t.isEmpty) return null;

  // 「一个半」「2个半」= X + 0.5
  final endsWithHalf = t.endsWith('半') && t.length > 1;
  if (endsWithHalf) t = t.substring(0, t.length - 1);

  // 剥掉尾部量词，让剩下的部分能被当作纯数值解析
  while (t.isNotEmpty && kMeasureChars.contains(t[t.length - 1])) {
    t = t.substring(0, t.length - 1);
  }

  if (t.isEmpty) return endsWithHalf ? 0.5 : null;
  if (t == '半') return 0.5;

  double? value;

  final r = _rangePattern.firstMatch(t);
  if (r != null) {
    value = double.parse(r.group(2)!);
  } else {
    final f = _fractionPattern.firstMatch(t);
    if (f != null) {
      final den = double.parse(f.group(2)!);
      if (den == 0) return null;
      value = double.parse(f.group(1)!) / den;
    } else if (_decimalPattern.hasMatch(t)) {
      value = double.parse(t);
    } else {
      value = parseChineseNumber(t);
    }
  }

  if (value == null) return null;
  return endsWithHalf ? value + 0.5 : value;
}

/// 把「2 个」「200 g」「适量」解析为结构化分量。
Amount parseAmount(String rawInput) {
  final raw = rawInput.trim();
  if (raw.isEmpty) {
    return Amount(value: null, unit: '', kind: AmountKind.unparsed, raw: raw);
  }

  final s = normalizeWidth(raw).trim();
  final compact = s.replaceAll(' ', '');
  // 单位匹配一律走小写，让 `1.5 L` / `1.5l` / `1.5 升` 等价。
  // 位置一一对应，所以拿 `compact` 取数值片段仍然安全。
  final lower = compact.toLowerCase();
  if (compact.isEmpty) {
    return Amount(value: null, unit: '', kind: AmountKind.unparsed, raw: raw);
  }

  for (final v in kVagueAmounts) {
    if (compact.contains(v)) {
      return Amount(value: null, unit: v, kind: AmountKind.vague, raw: raw);
    }
  }

  // 从右往左剥离单位：按长度降序尝试，避免「千克」被「克」抢先匹配。
  final candidates = <MapEntry<String, AmountKind>>[];
  kMassToGram.forEach((u, _) => candidates.add(MapEntry(u, AmountKind.mass)));
  kVolumeToMl.forEach((u, _) => candidates.add(MapEntry(u, AmountKind.volume)));
  for (final u in kCountUnits) {
    candidates.add(MapEntry(u, AmountKind.count));
  }
  candidates.sort((a, b) => b.key.length.compareTo(a.key.length));

  for (final c in candidates) {
    if (!lower.endsWith(c.key)) continue;
    // 「l」这种单字母单位必须要求前面不是字母，否则「oil」会被切成「oi」+「l」
    if (c.key.length == 1 && lower.length > 1) {
      final prev = lower[lower.length - 2];
      if (RegExp(r'[a-z]').hasMatch(prev)) continue;
    }
    final head = compact.substring(0, compact.length - c.key.length);
    final num = parseNumericToken(head);
    if (num == null) continue;

    switch (c.value) {
      case AmountKind.mass:
        final factor = kMassToGram[c.key]!;
        return Amount(
          value: num * factor,
          unit: 'g',
          kind: AmountKind.mass,
          raw: raw,
        );
      case AmountKind.volume:
        final factor = kVolumeToMl[c.key]!;
        return Amount(
          value: num * factor,
          unit: 'ml',
          kind: AmountKind.volume,
          raw: raw,
        );
      case AmountKind.count:
        return Amount(
          value: num,
          unit: c.key,
          kind: AmountKind.count,
          raw: raw,
        );
      case AmountKind.vague:
      case AmountKind.unparsed:
        break;
    }
  }

  // 没有任何数字也要能识别出「半」：如「半勺」已被上面覆盖，
  // 这里是「半个」这种单位缺失的情况。
  final lone = parseNumericToken(compact);
  if (lone != null) {
    return Amount(value: lone, unit: '', kind: AmountKind.unparsed, raw: raw);
  }

  return Amount(value: null, unit: '', kind: AmountKind.unparsed, raw: raw);
}

/// 把归一后的数值格式化回人类可读。
/// `500` → `500 g`；`1500` → `1.5 kg`；`1` → `1 个`。
String formatAmount(double value, String unit, AmountKind kind) {
  if (kind == AmountKind.mass && unit == 'g' && value >= 1000) {
    return '${_trimZero(value / 1000)} kg';
  }
  if (kind == AmountKind.volume && unit == 'ml' && value >= 1000) {
    return '${_trimZero(value / 1000)} L';
  }
  return '${_trimZero(value)}${unit.isEmpty ? '' : ' $unit'}';
}

String _trimZero(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  // 只保留一位小数，避免 0.30000000000000004 这种东西出现在界面上
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}
