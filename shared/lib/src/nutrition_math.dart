/// R46 · 热量的手填换算与「依据」编码。
///
/// 放 shared 的理由只有一条（§8.1 的判断标准）：**Android 与 Web 是两份不同的
/// 编译产物，同一个换算规则各写一遍必然会漂**。详情页弹层、列表徽标、将来统计页
/// 的「按份数折算」都要吃同一套口径，所以收在这里并配单测。
///
/// 三条口径来自需求书 §4.5.7 的拍板：
/// ① 来源只有 `ai` / `manual` 两态——「手改过的 AI 值」= manual + 依据里留一份 AI 原值，
///    **不新增第三种枚举**（加枚举要动同步白名单校验和三处 UI 分支）；
/// ② 改份数时**整锅总量不变、每份重算**（FR-AI-72）；
/// ③ 每份 / 整锅谁后改谁说话，另一个跟着折算（Q5：只要求填一个）。
library;

import 'dart:convert';

/// 用户刚改动的那个字段。换算的分支全靠它，所以做成枚举而不是字符串。
enum NutritionField { per, total, servings }

/// 一份热量草稿的换算状态。`null` = 还没填（UI 画「—」，不画 0——
/// 空态画 0 会让人以为已经填过了，这是原型走查时定下的口径）。
class NutritionCalc {
  final double? perServingKcal;
  final double? totalKcal;
  final int servings;

  const NutritionCalc({
    this.perServingKcal,
    this.totalKcal,
    this.servings = 4,
  });

  NutritionCalc copyWith({
    double? perServingKcal,
    double? totalKcal,
    int? servings,
  }) =>
      NutritionCalc(
        perServingKcal: perServingKcal ?? this.perServingKcal,
        totalKcal: totalKcal ?? this.totalKcal,
        servings: servings ?? this.servings,
      );

  int? get perRounded => perServingKcal?.round();
  int? get totalRounded => totalKcal?.round();
}

/// 每份千卡的荒谬上限：超过它要**二次确认**才允许保存（FR-AI-74）。
///
/// 为什么是 20000：一道菜每份超过两万大卡意味着「一锅油」级别的录入错误，
/// 而真实存在的极端高热量菜（一大锅红烧肉按 1 人份算）也在几千到一万之间。
const double kNutritionAbsurdPerServing = 20000;

/// 份数基数下限：0 或负数会让「每份 = 总 ÷ 份数」除零或翻负号。
int nutriSanitizeServings(Object? raw, {int fallback = 4}) {
  final n = raw is num ? raw.toInt() : int.tryParse('${raw ?? ''}');
  if (n == null || n < 1) return fallback;
  return n > 99 ? 99 : n;
}

double? nutriParse(Object? raw) {
  if (raw == null) return null;
  if (raw is num) return raw.toDouble();
  final s = '$raw'.trim();
  if (s.isEmpty) return null;
  return double.tryParse(s);
}

/// **换算主函数**：把「用户在 [changed] 里填的 [value]」并进口前状态，返回三元组。
///
/// 规则（对齐原型走查钉下的行为）：
/// - 改「每份」→ 整锅 = 每份 × 份数；
/// - 改「整锅」→ 每份 = 整锅 ÷ 份数；
/// - 改「份数」→ 整锅不变，每份 = 整锅 ÷ 新份数（FR-AI-72）；
///   整锅还没填时，先用**旧份数**把整锅补齐再重算，避免「3 人份 ×100 千卡改成 6 人份
///   变成每份 50」这种把 3 人份的总量当 6 人份总量的错解。
NutritionCalc nutriApply(NutritionCalc cur, NutritionField changed, Object? value) {
  switch (changed) {
    case NutritionField.per:
      final per = nutriParse(value);
      if (per == null) return NutritionCalc(totalKcal: cur.totalKcal, servings: cur.servings);
      final p = per < 0 ? 0.0 : per;
      return NutritionCalc(
        perServingKcal: p,
        totalKcal: p * cur.servings,
        servings: cur.servings,
      );
    case NutritionField.total:
      final total = nutriParse(value);
      if (total == null) return NutritionCalc(perServingKcal: cur.perServingKcal, servings: cur.servings);
      final t = total < 0 ? 0.0 : total;
      return NutritionCalc(
        perServingKcal: t / cur.servings,
        totalKcal: t,
        servings: cur.servings,
      );
    case NutritionField.servings:
      final next = nutriSanitizeServings(value, fallback: cur.servings);
      // 先把整锅定下来：有整锅用整锅，没有就用「每份 × 旧份数」补
      final base = cur.totalKcal ?? (cur.perServingKcal == null ? null : cur.perServingKcal! * cur.servings);
      final per = cur.perServingKcal;
      if (base == null) {
        return NutritionCalc(perServingKcal: per, totalKcal: null, servings: next);
      }
      return NutritionCalc(
        perServingKcal: base / next,
        totalKcal: base,
        servings: next,
      );
  }
}

/// 保存前的校验结果。UI 只管文案，判定收在这里（两端同一口径）。
enum NutritionCheck { ok, needPerServing, needConfirm }

NutritionCheck nutriCheck(NutritionCalc c, {required bool armed}) {
  final per = c.perServingKcal;
  if (per == null || per <= 0) return NutritionCheck.needPerServing;
  if (per > kNutritionAbsurdPerServing && !armed) return NutritionCheck.needConfirm;
  return NutritionCheck.ok;
}

/// 「看依据」里 AI 原值的留痕（手改之后不覆盖，FR-AI-71）。
class NutritionAiEcho {
  final double? perServingKcal;
  final double? totalKcal;
  final String? model;
  final double? confidence;

  const NutritionAiEcho({
    this.perServingKcal,
    this.totalKcal,
    this.model,
    this.confidence,
  });

  Map<String, Object?> toJson() => {
        if (perServingKcal != null) 'per': perServingKcal,
        if (totalKcal != null) 'total': totalKcal,
        if (model != null && '$model'.isNotEmpty) 'model': model,
        if (confidence != null) 'confidence': confidence,
      };

  static NutritionAiEcho? fromJson(Map<String, Object?> j) {
    final per = nutriParse(j['per']);
    final total = nutriParse(j['total']);
    if (per == null && total == null) return null;
    return NutritionAiEcho(
      perServingKcal: per,
      totalKcal: total,
      model: j['model'] == null ? null : '${j['model']}',
      confidence: nutriParse(j['confidence']),
    );
  }
}

/// nutrition 表 `basis` 列的编解码。
///
/// **向后兼容是硬要求**：R27 起这一列存的是「逐食材贡献的 JSON 数组」
/// （服务端回 `per_ingredient` 原样编码），同步过来的老行也还是那个形状。
/// 所以解码要同时吃两种：数组 = 只有逐项；对象 = `{items, ai}`。
/// 编码一律写成对象——老版本读到对象会拿不到逐项吗？不会：老 UI 本来就没有
/// 「看依据」这一段（R46 才补上），而这一列**只做展示、不参与任何计算或判定**，
/// 所以换形状不动同步协议、不 bump 版本。
class NutritionBasis {
  /// 逐食材贡献，原样保留（服务端给什么形状就存什么，别丢字段）。
  final List<Map<String, Object?>> items;
  final NutritionAiEcho? ai;

  const NutritionBasis({this.items = const [], this.ai});

  static NutritionBasis decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const NutritionBasis();
    Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } catch (_) {
      // 脏数据不该让详情页崩——按「没有依据」处理
      return const NutritionBasis();
    }
    if (parsed is List) {
      return NutritionBasis(items: [for (final e in parsed) if (e is Map) e.cast<String, Object?>()]);
    }
    if (parsed is Map) {
      final j = parsed.cast<String, Object?>();
      final list = j['items'];
      final aiRaw = j['ai'];
      return NutritionBasis(
        items: [
          if (list is List)
            for (final e in list)
              if (e is Map) e.cast<String, Object?>()
        ],
        ai: aiRaw is Map ? NutritionAiEcho.fromJson(aiRaw.cast<String, Object?>()) : null,
      );
    }
    return const NutritionBasis();
  }

  String encode() => jsonEncode({
        'items': items,
        if (ai != null) 'ai': ai!.toJson(),
      });

  /// 逐项里的热量数字（键名以服务端契约 `kcal` 为准，兼容 `k`）。
  static double? itemKcal(Map<String, Object?> item) => nutriParse(item['kcal'] ?? item['k']);
  static String itemName(Map<String, Object?> item) => '${item['name'] ?? ''}';
  static String itemQty(Map<String, Object?> item) => '${item['qty'] ?? item['q'] ?? item['amount'] ?? ''}';
}

/// 手改时决定「AI 原值留痕」留谁（FR-AI-71）：
/// - 上一版是 AI → 抄它的当前值；
/// - 上一版已经是手动态且本来就带着留痕 → **原样带走**（第二次手改不该把 AI 原始值冲掉）；
/// - 纯手填（从没算过）→ 没有留痕。
NutritionAiEcho? nutriEchoFor(NutritionBasis previous, {required String? prevSource, required double? prevPer, required double? prevTotal, required String? prevModel, required double? prevConfidence}) {
  if (prevSource == 'ai') {
    return NutritionAiEcho(
      perServingKcal: prevPer,
      totalKcal: prevTotal,
      model: prevModel,
      confidence: prevConfidence,
    );
  }
  return previous.ai;
}
