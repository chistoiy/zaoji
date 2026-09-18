/// 中文数字解析。
///
/// 菜谱文本里「三分钟」「两勺」「半小时」极常见，而正则只认阿拉伯数字，
/// 所以必须先把中文数字归一。这一层两端共用，**不允许各写一套**——
/// 否则手机上认出 3 分钟、网页端认不出，是很典型的端间行为漂移。
library;

const Map<String, int> _digits = {
  '零': 0, '〇': 0,
  '一': 1, '壹': 1,
  '二': 2, '贰': 2, '两': 2,
  '三': 3, '叁': 3,
  '四': 4, '肆': 4,
  '五': 5, '伍': 5,
  '六': 6, '陆': 6,
  '七': 7, '柒': 7,
  '八': 8, '捌': 8,
  '九': 9, '玖': 9,
};

const Map<String, int> _magnitudes = {
  '十': 10, '拾': 10,
  '百': 100, '佰': 100,
  '千': 1000, '仟': 1000,
};

/// 中文量词。出现在数字与单位之间时应当忽略，
/// 例如「一个半小时」里的「个」、「两碗水」里的「碗」。
const Set<String> _measureWords = {
  '个', '只', '颗', '根', '把', '头', '块', '朵', '片', '张', '条',
  '瓣', '盒', '袋', '瓶', '罐', '包', '束', '串', '碗', '杯', '勺',
  '汤匙', '茶匙', '大勺', '小勺', '钟头', '次', '遍',
};

/// 解析中文数字。无法解析时返回 `null`（**不要返回 0**，
/// 因为 0 是合法数值，混用会让上层无法区分「解析失败」与「数量为零」）。
///
/// 支持：`五` / `十五` / `二十` / `二十三` / `一百` / `一百零五` / `两` / `半` / `一个半`
double? parseChineseNumber(String input) {
  var s = input.trim();
  if (s.isEmpty) return null;

  // 「一个半」→ 1.5；「半」→ 0.5
  // 注意顺序：先判尾部的「半」，再判纯「半」。
  final endsWithHalf = s.endsWith('半') && s.length > 1;
  if (endsWithHalf) s = s.substring(0, s.length - 1);

  // 去掉量词，让「两碗」等价于「两」
  for (final w in _measureWords) {
    if (s.contains(w)) s = s.replaceAll(w, '');
  }
  if (s.isEmpty) {
    // 原本就是「半」「个半」这类
    return endsWithHalf ? 0.5 : null;
  }

  if (s == '半') return 0.5;

  var total = 0;
  var pending = 0;
  var hasPending = false;
  var matched = false;

  for (final rune in s.runes) {
    final ch = String.fromCharCode(rune);
    final d = _digits[ch];
    if (d != null) {
      pending = d;
      hasPending = true;
      matched = true;
      continue;
    }
    final m = _magnitudes[ch];
    if (m != null) {
      // 「十五」这种省略了前导一的写法，按 1 处理
      final n = hasPending ? pending : 1;
      total += n * m;
      pending = 0;
      hasPending = false;
      matched = true;
      continue;
    }
    // 出现未识别字符 → 整体判定为不可解析，不做部分解析，
    // 因为「三分之一个」这类断章取义比解析失败更危险。
    return null;
  }

  if (!matched) return null;
  total += pending;
  final value = total.toDouble();
  return endsWithHalf ? value + 0.5 : value;
}

/// 严格判断一个字符串是否「整体」是中文数字（可带量词和「半」）。
bool isChineseNumber(String s) => parseChineseNumber(s) != null;
