import '../models.dart';

/// R33 · 数据体检（账本自查）。
///
/// 判定全在这份**纯函数**里：不吃时钟、不查库——时钟是入参 `now`，
/// 数据由页面从 store 现取。这样每条阈值都能用假日期钉死测试，
/// 页面只负责排版和跳转。
///
/// **有意没做的**：「建档很久却没做过的冷灶菜」——recipe 没有创建时间列
/// （R24 就记过这笔账，拿 updated_at 猜会漂），等下一次加列窗口再说。

/// 问题条目点进去落到哪。
enum HealthTarget { kitchen, recipeList, shopping }

/// 挂着没完成的做菜会话（体检视角）。名字由页面查好带进来——
/// 纯函数不碰 store，也就别把 id 当文案。
class ZombieSession {
  final String recipeId;
  final String recipeName;
  final DateTime startedAt;

  const ZombieSession({
    required this.recipeId,
    required this.recipeName,
    required this.startedAt,
  });
}

/// 一组同类问题。`detail` 是给人看的点名串（前 8 个 + 省略号兜底），
/// 跳转目标对整组生效。count=0 的组不会出现在输出里。
class HealthIssue {
  final String key;
  final String title;
  final List<String> names;
  final int count;
  final HealthTarget target;

  const HealthIssue({
    required this.key,
    required this.title,
    required this.names,
    this.target = HealthTarget.kitchen,
  }) : count = names.length;

  String get detail {
    final shown = names.take(8).join(' · ');
    return names.length > 8 ? '$shown …' : shown;
  }
}

/// 全量体检。输出顺序固定：残缺菜谱 → 库存 → 做菜会话 → 购物清单。
/// 空组直接缺席（不产出 count=0 的占位条）。
List<HealthIssue> healthIssues({
  required List<Recipe> recipes,
  required List<PantryItem> pantry,
  required List<ShoppingItem> shopping,

  /// 未完成会话（页面已把菜名查好）。
  required List<ZombieSession> zombies,

  /// 清单项 id → 建档时刻（schema 没给清单项业务时间列，只能外置）。
  required Map<String, DateTime> shoppingAges,
  required DateTime now,
  int staleDays = 14,
}) {
  final issues = <HealthIssue>[];

  final noIng =
      recipes.where((r) => r.ingredients.isEmpty).map((r) => r.name).toList();
  if (noIng.isNotEmpty) {
    issues.add(HealthIssue(
        key: 'no-ingredients',
        title: '还没有食材的菜谱',
        names: noIng,
        target: HealthTarget.recipeList));
  }
  final noStep =
      recipes.where((r) => r.steps.isEmpty).map((r) => r.name).toList();
  if (noStep.isNotEmpty) {
    issues.add(HealthIssue(
        key: 'no-steps',
        title: '还没有步骤的菜谱',
        names: noStep,
        target: HealthTarget.recipeList));
  }

  final today = DateTime(now.year, now.month, now.day);
  final expired = <String>[];
  for (final p in pantry) {
    final e = p.expireAt;
    if (e == null || e.length < 10) continue;
    final d = DateTime.tryParse(e);
    if (d == null) continue;
    if (DateTime(d.year, d.month, d.day).isBefore(today)) expired.add(p.name);
  }
  if (expired.isNotEmpty) {
    issues.add(HealthIssue(
        key: 'expired-pantry',
        title: '已过保质期的库存',
        names: expired,
        target: HealthTarget.kitchen));
  }

  if (zombies.isNotEmpty) {
    final zs = zombies.toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt)); // 最久的排前
    issues.add(HealthIssue(
        key: 'zombie-sessions',
        title: '挂着没做完的做菜会话',
        names: [
          for (final z in zs)
            '${z.recipeName} · 已挂起 ${now.difference(z.startedAt).inHours} 小时',
        ],
        target: HealthTarget.recipeList));
  }

  final stale = shopping
      .where((s) =>
          !s.bought &&
          now.difference(shoppingAges[s.id] ?? now).inDays >= staleDays)
      .map((s) => s.name)
      .toList();
  if (stale.isNotEmpty) {
    issues.add(HealthIssue(
        key: 'stale-shopping',
        title: '挂了很久的未购清单项',
        names: stale,
        target: HealthTarget.shopping));
  }

  return issues;
}
