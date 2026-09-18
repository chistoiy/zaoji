/// 步骤文本里的时间关键词解析。
///
/// 这是产品的**第一个记忆点**：用户写步骤时随手写「小火炖 20 分钟」，
/// 查看菜谱时「20 分钟」自动变成一颗琥珀色胶囊，点一下直接起计时器。
///
/// 两条硬要求：
/// ① **原文一个字都不能改写**——所以返回的是**区间**，不是替换后的字符串。
///    上层拿区间去做高亮渲染，文本本身保持用户写的样子。
/// ② 识别必须保守：宁可漏掉一个「半个多小时」，也不要误把「三分之一个」
///    认成 3 分钟——错误的计时器比没有计时器更伤人。
library;

import 'units.dart';

class StepTimeHit {
  /// 在原文中的起止（UTF-16 code unit）。
  /// 用 UTF-16 而不是 rune 下标，是为了能直接喂给
  /// Flutter 的 `TextSpan` 和 JS 的 `String.prototype.slice`，两端零换算。
  final int start;
  final int end;

  /// 命中的原文片段（原样，未做任何改写）
  final String text;

  final int minSeconds;
  final int maxSeconds;

  /// 该命中对应的单位换算秒数；`0` 表示这是合并后的复合时长。
  final int unitSeconds;

  const StepTimeHit({
    required this.start,
    required this.end,
    required this.text,
    required this.minSeconds,
    required this.maxSeconds,
    required this.unitSeconds,
  });

  /// 建议的计时时长。区间取**上限**——做菜时宁多勿少，
  /// 提前关火容易，菜糊了没法救。
  int get suggestedSeconds => maxSeconds;

  bool get isRange => minSeconds != maxSeconds;

  Duration get suggested => Duration(seconds: suggestedSeconds);
  Duration get min => Duration(seconds: minSeconds);
  Duration get max => Duration(seconds: maxSeconds);

  /// 人类可读时长，用于计时器标题与通知。
  /// 注意：**不是**用来替换原文的——胶囊上显示的仍是 `text`。
  String get label {
    final lo = _human(minSeconds);
    final hi = _human(maxSeconds);
    return isRange ? '$lo–$hi' : hi;
  }

  static String _human(int total) {
    if (total < 60) return '$total 秒';
    if (total % 3600 == 0) return '${total ~/ 3600} 小时';
    if (total >= 3600) {
      final h = total ~/ 3600;
      final m = (total % 3600) ~/ 60;
      return m == 0 ? '$h 小时' : '$h 小时 $m 分钟';
    }
    if (total % 60 == 0) return '${total ~/ 60} 分钟';
    return '$total 秒';
  }

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        'text': text,
        'min': minSeconds,
        'max': maxSeconds,
      };

  static StepTimeHit fromJson(Map<String, dynamic> j) => StepTimeHit(
        start: j['start'] as int,
        end: j['end'] as int,
        text: j['text'] as String,
        minSeconds: j['min'] as int,
        maxSeconds: j['max'] as int,
        unitSeconds: 0,
      );

  @override
  String toString() => '[$start,$end) "$text" ${label}';
}

// ─────────────────────── 内部实现 ───────────────────────

class _TimeUnit {
  final String name;
  final int seconds;
  const _TimeUnit(this.name, this.seconds);
}

/// 按**长度降序**排列，保证「分钟」先于「分」被匹配到。
/// 否则「5分钟」会被切成「5分」+「钟」，留下一个孤零零的「钟」。
const List<_TimeUnit> _units = [
  _TimeUnit('小时', 3600),
  _TimeUnit('钟头', 3600),
  _TimeUnit('分钟', 60),
  _TimeUnit('秒钟', 1),
  _TimeUnit('分', 60),
  _TimeUnit('秒', 1),
];

/// 单位后面紧跟这些字，说明它不是在表达时长，直接跳过。
/// 典型误判：「三分之一个洋葱」——不排除的话会变成「3 分钟」。
const Set<String> _blockedAfterUnit = {'之', '/', '／', '比'};

const Set<String> _rangeSeparators = {'-', '~', '～', '—', '–', '至', '到'};

const String _cnNumberChars = '零〇一二三四五六七八九十百千两半壹贰叁肆伍陆柒捌玖拾佰仟';

bool _isNumberChar(String ch) =>
    (ch.codeUnitAt(0) >= 0x30 && ch.codeUnitAt(0) <= 0x39) ||
    ch == '.' ||
    ch == '/' ||
    _cnNumberChars.contains(ch) ||
    // 量词也允许出现：`半个 小时`、`三个 钟头`。
    // 不做这一步的话，向左回看到「个」就断了，「再炖半个小时」会识别不出。
    kMeasureChars.contains(ch);

bool _isSpace(String ch) => ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';

/// 区间连接符「到」「至」是汉字，会被 `_isNumberChar` 拦下，所以不冲突。
bool _isRangeSeparator(String ch) => _rangeSeparators.contains(ch);

class _NumScan {
  final int start;
  final double minValue;
  final double maxValue;
  const _NumScan(this.start, this.minValue, this.maxValue);
}

/// 从单位左侧回看，取出数值；若有区间分隔符则取出区间。
_NumScan? _scanAmountBackward(String s, int unitStart) {
  var p = unitStart - 1;
  while (p >= 0 && _isSpace(s[p])) p--;
  if (p < 0 || !_isNumberChar(s[p])) return null;

  final endA = p + 1;
  // 往左收集数字字符。
  //
  // ★ 必须能跨过**夹在中间的空格**：「再焖 1 个半小时」里，
  // 数字 1 与量词 个 之间有一个空格。如果在这里停下，
  // 拿到的 token 会是「个半」，而 `parseNumericToken` 恰好容忍了那个孤零零的
  // 「个」并返回 0.5 —— 于是这道菜的时长被静默算成 30 分钟，应该是 90 分钟。
  // **差 3 倍，而且不报错。**
  //
  // 判据：空格左边还是数字字符才算数；否则那个空格就是边界。
  // 空格在 token 内部没关系，`parseNumericToken` 会自己去掉。
  while (p >= 0) {
    if (_isNumberChar(s[p])) {
      p--;
      continue;
    }
    if (_isSpace(s[p])) {
      var t = p;
      while (t >= 0 && _isSpace(s[t])) {
        t--;
      }
      if (t >= 0 && _isNumberChar(s[t])) {
        p = t;
        continue;
      }
    }
    break;
  }
  final startA = p + 1;

  final valueA = parseNumericToken(s.substring(startA, endA));
  if (valueA == null) return null;

  // 再往左看有没有区间分隔符（5-6分钟 / 30～40分钟 / 10 到 15 分钟）
  var q = startA - 1;
  while (q >= 0 && _isSpace(s[q])) q--;
  if (q >= 0 && _isRangeSeparator(s[q])) {
    var r = q - 1;
    while (r >= 0 && _isSpace(s[r])) r--;
    if (r >= 0 && _isNumberChar(s[r])) {
      final endB = r + 1;
      while (r >= 0 && _isNumberChar(s[r])) r--;
      final startB = r + 1;
      final valueB = parseNumericToken(s.substring(startB, endB));
      if (valueB != null) {
        final lo = valueB < valueA ? valueB : valueA;
        final hi = valueB < valueA ? valueA : valueB;
        return _NumScan(startB, lo, hi);
      }
    }
  }

  return _NumScan(startA, valueA, valueA);
}

/// 合并「1 小时 30 分钟」这类复合时长。
///
/// 不合并的话，用户会看到两颗胶囊，点哪个都不对——他要的是 90 分钟。
List<StepTimeHit> _mergeAdjacent(List<StepTimeHit> hits, String text) {
  if (hits.length < 2) return hits;

  final out = <StepTimeHit>[hits.first];
  for (var k = 1; k < hits.length; k++) {
    final prev = out.last;
    final cur = hits[k];

    final between = text.substring(prev.end, cur.start);
    final onlyGlue = between.runes.every((r) {
      final ch = String.fromCharCode(r);
      return _isSpace(ch) || ch == '、' || ch == '，' || ch == ',';
    });

    final isCompound = prev.unitSeconds >= 3600 &&
        cur.unitSeconds > 0 &&
        cur.unitSeconds < 3600 &&
        onlyGlue;

    if (isCompound) {
      out[out.length - 1] = StepTimeHit(
        start: prev.start,
        end: cur.end,
        text: text.substring(prev.start, cur.end),
        minSeconds: prev.minSeconds + cur.minSeconds,
        maxSeconds: prev.maxSeconds + cur.maxSeconds,
        unitSeconds: 0, // 复合时长，不再参与二次合并
      );
    } else {
      out.add(cur);
    }
  }
  return out;
}

/// 解析一段文本里的全部时间关键词，按出现顺序返回。
///
/// ```
/// parseStepTimes('小火炖 20 分钟，然后大火收汁 30 秒')
/// // → [ [4,10) "20 分钟" 20 分钟 , [18,22) "30 秒" 30 秒 ]
/// ```
List<StepTimeHit> parseStepTimes(String text) {
  if (text.isEmpty) return const [];

  // 全角 → 半角是**等长**替换（每个 code unit 一对一），
  // 所以索引可以安全地映射回原文。
  final s = normalizeWidth(text);

  final hits = <StepTimeHit>[];
  var i = 0;
  while (i < s.length) {
    _TimeUnit? unit;
    for (final u in _units) {
      if (s.startsWith(u.name, i)) {
        unit = u;
        break;
      }
    }
    if (unit == null) {
      i++;
      continue;
    }

    final after = i + unit.name.length;
    if (after < s.length && _blockedAfterUnit.contains(s[after])) {
      i = after;
      continue;
    }

    final amount = _scanAmountBackward(s, i);
    if (amount == null) {
      i = after;
      continue;
    }

    hits.add(StepTimeHit(
      start: amount.start,
      end: after,
      text: text.substring(amount.start, after),
      minSeconds: (amount.minValue * unit.seconds).round(),
      maxSeconds: (amount.maxValue * unit.seconds).round(),
      unitSeconds: unit.seconds,
    ));
    i = after;
  }

  return _mergeAdjacent(hits, text);
}

/// 快速判断「这段文本里有没有可点的时间胶囊」。
/// 列表页只需要知道有无，不需要全部命中项。
bool hasStepTimes(String text) => parseStepTimes(text).isNotEmpty;
