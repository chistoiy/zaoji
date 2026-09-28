import 'package:zaoji_shared/zaoji_shared.dart';

import '../models.dart';
import 'recipe_store.dart' show MenuPlan;

/// R34 · 文字分享的三种产物（FR-SHARE-01/03/04/07/08/09/10）。
///
/// 纯函数、零依赖、零 I/O——面板负责排版与复制/存文件，这里只管**账面与红线**：
/// · **一个字都不改写**：步骤/注意原文照贴（时间胶囊的立场同款——渲染期高亮，
///   不在产出期动用户的字）；
/// · FR-SHARE-07 红线：产物里不得出现 URL / 服务器地址 / token——
///   这些函数**根本没有**这些入参，红线是结构性的，测试只是再钉一遍；
/// · FR-SHARE-09 红线：烹饪历史（做过几次/最近日期）与库存全量默认不进产物。

const String kShareSignature = '— 来自 灶记 ZAOJI · 家庭菜谱手账 —';

/// 分量列的固定间隔（`· 番茄        2 个`）——全角环境下比动态对齐稳。
const String _gap = '        ';

String _dots(int difficulty) {
  final d = difficulty.clamp(1, 3);
  return '${'●' * d}${'○' * (3 - d)}';
}

/// 「2 个」×2 → 「4 个」；小数取整到一位；「适量/一小撮」等模糊量**原样**。
///
/// 只认「数字 + 单位」这一种形状，别的宁可不缩放也不瞎改——
/// 用户写的「半个」被算成「1 个」比不缩放糟糕得多（展示永远用原文的立场）。
String scaleQtyText(String raw, double factor) {
  if (factor == 1.0) return raw;
  final m = RegExp(r'^\s*(\d+(?:\.\d+)?)\s*(.*)$').firstMatch(raw);
  if (m == null) return raw;
  final v = (double.parse(m.group(1)!) * factor * 10).roundToDouble() / 10;
  final num = v == v.roundToDouble() ? v.round().toString() : '$v';
  final rest = m.group(2)!;
  return rest.isEmpty ? num : '$num $rest';
}

/// 菜品长文（竖版长图将来排同样的信息密度）。
String shareRecipe({
  required Recipe recipe,
  required int servings,
  String? nutritionLine,
  bool withIngredients = true,
  bool withSteps = true,
  bool withNotes = true,
  bool withSignature = true,
}) {
  final b = StringBuffer()
    ..writeln('【${recipe.name}】')
    ..writeln('${recipe.sub} · 难度 ${_dots(recipe.difficulty)}'
        ' · 约 ${recipe.selfTime} 分钟 · $servings 人份');
  if (withIngredients) {
    final factor = recipe.servings <= 0 ? 1.0 : servings / recipe.servings;
    b.writeln();
    b.writeln('— 食材（$servings 人份）—');
    for (final i in recipe.ingredients) {
      b.writeln('· ${i.name}$_gap${scaleQtyText(i.qty, factor)}');
    }
  }
  if (withSteps) {
    b.writeln();
    b.writeln('— 步骤 —');
    for (var i = 0; i < recipe.steps.length; i++) {
      b.writeln('${i + 1}. ${recipe.steps[i].text}');
    }
  }
  if (withNotes && recipe.notes.trim().isNotEmpty) {
    b.writeln();
    b.writeln('— 注意 —');
    b.writeln(recipe.notes.trim());
  }
  if (nutritionLine != null) {
    b.writeln();
    b.writeln(nutritionLine);
  }
  if (withSignature) {
    b.writeln();
    b.write(kShareSignature);
  }
  return b.toString().trimRight();
}

/// 菜单卡文本：`【周六 · 晚餐】18:30 开饭` + 菜名带难度耗时。
String shareMenu({
  required MenuPlan menu,
  required List<Recipe> dishes,
  bool withSignature = true,
}) {
  final b = StringBuffer()
    ..writeln('【${_weekday(menu.day)} · ${menu.meal}】'
        '${menu.serveAt.isEmpty ? '' : ' ${menu.serveAt} 开饭'}')
    ..writeln();
  if (dishes.isEmpty) {
    b.writeln('还没配菜');
  } else {
    for (final r in dishes) {
      b.writeln('· ${r.name}（难度 ${_dots(r.difficulty)} · 约 ${r.selfTime} 分钟）');
    }
  }
  if (menu.note.trim().isNotEmpty) {
    b.writeln();
    b.writeln(menu.note.trim());
  }
  if (withSignature) {
    b.writeln();
    b.write(kShareSignature);
  }
  return b.toString().trimRight();
}

/// 备菜/买菜清单（FR-SHARE-08：每行 `☐` 可打勾）。
String sharePrep({
  required String day,
  required String meal,
  required List<MergedLine> lines,
  bool withSources = true,
  bool withSignature = true,
}) {
  final b = StringBuffer()
    ..writeln('【${_weekday(day)} · $meal】备菜清单')
    ..writeln();
  for (final l in lines) {
    final src = withSources && l.from.length > 1 ? ' ← ${l.from.join("、")}' : '';
    b.writeln('☐ ${l.name}$_gap${l.qtyText}$src');
  }
  if (withSignature) {
    b.writeln();
    b.write(kShareSignature);
  }
  return b.toString().trimRight();
}

const _kWeekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// 'YYYY-MM-DD' → '周六'。解析不出来退回原串——宁可见生日期，不可见错星期。
String _weekday(String day) {
  final d = DateTime.tryParse(day);
  if (d == null) return day;
  return _kWeekdays[d.weekday - 1];
}
