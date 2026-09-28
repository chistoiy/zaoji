import 'package:flutter/material.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import '../theme.dart';

/// 过敏原的视觉词汇（R40 · FR-SET-05）。
///
/// 需求写死了三重冗余：**斜条纹底纹 + 图标 + 写明「谁对什么」**。
/// 少任何一重都不算达标——只靠红色，色觉障碍的用户看到的是一堆
/// "和别处颜色不太一样的字"，那和没标一样。
///
/// 这一组控件被四处共用（菜谱详情 / 列表卡片 / 菜单详情 / 做菜模式），
/// 所以写在一个文件里：**任何一处想"稍微改一下"，就该停下来想想
/// 是不是四处都该改**——警示语言分叉的代价是用户学着重新认一遍。

/// 头像色块用的色板。取主题令牌而不是存 hex 进库：
/// 成员表里的 `avatar` 是**编号**，颜色属于主题，换肤时要跟着翻。
List<Color> avatarColors(BuildContext context) {
  final zj = context.zj;
  return [
    zj.tagCuisine,
    zj.tagMethod,
    zj.tagIngredient,
    zj.accent,
    zj.ai,
    zj.amber2,
  ];
}

class AvatarChip extends StatelessWidget {
  const AvatarChip({
    required this.name,
    required this.index,
    this.size = 42,
    this.ring = false,
    super.key,
  });

  final String name;
  final int index;
  final double size;
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final zj = context.zj;
    final colors = avatarColors(context);
    final bg = colors[index % colors.length];
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(size * 0.34),
        border: ring ? Border.all(color: zj.accent, width: 2) : null,
      ),
      alignment: Alignment.center,
      child: Text(
        name,
        style: TextStyle(
          fontSize: size * 0.42,
          fontWeight: FontWeight.w700,
          color: zj.onAccent,
        ),
      ),
    );
  }
}

/// 斜条纹底纹。CSS 的 `repeating-linear-gradient` 在 Flutter 没有对应物，
/// 所以自己画：底色 + 一组 45° 斜线。
class _StripePainter extends CustomPainter {
  _StripePainter({required this.base, required this.stripe});

  final Color base;
  final Color stripe;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = base);
    final p = Paint()
      ..color = stripe
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.butt;
    // 斜线从左上到右下铺满整个矩形（含外溢部分由裁剪处理）
    canvas.clipRect(Offset.zero & size);
    const gap = 9.0;
    for (var d = -size.height; d < size.width + size.height; d += gap) {
      canvas.drawLine(
        Offset(d, 0),
        Offset(d + size.height, size.height),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_StripePainter old) =>
      old.base != base || old.stripe != stripe;
}

/// 条纹容器：给警示条与命中的食材行共用。
///
/// 底色与斜线色都从调用处给，因为**两档警示的条纹颜色不同**：
/// 过敏走强调色，忌口走琥珀色——共用一个色就等于共用一个强度。
class StripeBackground extends StatelessWidget {
  const StripeBackground({
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.radius = ZaojiRadius.sm,
    this.border,
    this.base,
    this.stripe,
    super.key,
  });

  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final BoxBorder? border;
  final Color? base;
  final Color? stripe;

  @override
  Widget build(BuildContext context) {
    final zj = context.zj;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        border: border,
      ),
      child: ClipRRect(
        // 斜条纹由 CustomPaint 铺满，圆角靠这里裁；边框留在外层 Container
        borderRadius: BorderRadius.circular(radius),
        child: CustomPaint(
          painter: _StripePainter(
            base: base ?? zj.warnBg,
            stripe: stripe ?? zj.accent.withValues(alpha: 0.07),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// 页面顶部那条"有 N 道菜和家里成员冲突"的警告横幅。
class AllergenBanner extends StatelessWidget {
  const AllergenBanner({required this.title, this.body, super.key});

  final String title;
  final Widget? body;

  @override
  Widget build(BuildContext context) {
    final zj = context.zj;
    return StripeBackground(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
      radius: ZaojiRadius.md,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: zj.accent,
              borderRadius: BorderRadius.circular(9),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.warning_amber_rounded,
                size: 17, color: zj.onAccent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: zj.accentDeep)),
                if (body != null) ...[const SizedBox(height: 4), body!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 一枚「谁 · 对什么」的标签。过敏是警告档（条纹 + 图标 + 强调色），
/// 忌口是提示档（淡一档、不带感叹号）——两档必须一眼分得开。
///
/// 标签**自己也要带条纹**：FR-SET-05 的三重冗余是按"每一处警示"算的，
/// 光有颜色的小药丸在色觉障碍用户那里就是一堆同样灰的字，
/// 列表卡片上一排小标签只靠底色区分根本分不出过敏和忌口。
class AllergenTag extends StatelessWidget {
  const AllergenTag({
    required this.word,
    required this.allergy,
    this.who = '',
    this.mode = AllergenTagMode.full,
    super.key,
  });

  final String who;
  final String word;
  final bool allergy;

  /// 写多少字：三处空间不一样，但**条纹和感叹号一处都不能少**
  /// （FR-SET-05 的三重冗余是按每一处警示算的，不是按最宽的那处算的）。
  final AllergenTagMode mode;

  @override
  Widget build(BuildContext context) {
    final zj = context.zj;
    final tone = allergy ? zj.accent : zj.amber2;
    final color = allergy ? zj.warn : zj.amber;
    final label = switch (mode) {
      // 文案也跟着两档走：把忌口写成"过敏"是虚报，
      // 用户看到的第一反应是"这人瞎标的"，整条警示就没人信了
      AllergenTagMode.full =>
        '$who ${allergy ? '过敏 ·' : '忌口'} $word',
      AllergenTagMode.word => word,
      AllergenTagMode.who => who,
    };
    return StripeBackground(
      base: tone.withValues(alpha: 0.07),
      stripe: tone.withValues(alpha: 0.20),
      radius: ZaojiRadius.pill,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      border: Border.all(color: tone.withValues(alpha: 0.45)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (allergy) ...[
            Icon(Icons.warning_amber_rounded, size: 12, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }
}

enum AllergenTagMode { full, word, who }

/// 忌口标签（提示档）单独给个名字，调用处读起来不用记布尔参数。
class DislikeTag extends StatelessWidget {
  const DislikeTag({required this.who, required this.word, super.key});
  final String who;
  final String word;

  @override
  Widget build(BuildContext context) =>
      AllergenTag(who: who, word: word, allergy: false);
}

/// 排菜单前的过敏拦截（FR-SET-04「排菜单时拦截」开关）。
///
/// 返回 false 表示"不要加"。**是确认，不是禁止**：家里可能就是有人
/// 对虾过敏但今晚这桌没人吃虾——拦死了，用户会绕开这个功能去别处排菜，
/// 那时这条警示也就跟着废了。所以默认焦点放在「取消」，但「仍然加入」始终点得到。
Future<bool> confirmAllergenAddToMenu(
  BuildContext context, {
  required List<AllergenHit> hits,
  required String recipeName,
  required String mealLabel,
}) async {
  final groups = groupAllergenHits(hits).where((g) => g.allergy).toList();
  if (groups.isEmpty) return true;
  final zj = context.zj;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('$recipeName 含过敏原'),
      // 命中项可能有很多条（一锅虾十种写法）。内容包滚动，
      // 两个按钮才不会在小屏上被挤出屏幕——确认框点不到按钮等于没有确认框
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('添加到「$mealLabel」前再确认一次：',
                style: TextStyle(fontSize: 12.5, color: zj.ink2)),
            const SizedBox(height: 8),
            for (final g in groups)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text.rich(TextSpan(
                  style: TextStyle(fontSize: 12.5, color: zj.ink, height: 1.6),
                  children: [
                    TextSpan(
                        text: g.who,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    TextSpan(text: ' 对「${g.word}」过敏（${g.ings.join('、')}）'),
                  ],
                )),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消')),
        FilledButton(
          key: const ValueKey('allergen-confirm-add'),
          style: FilledButton.styleFrom(backgroundColor: zj.accentDeep),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('仍然加入'),
        ),
      ],
    ),
  );
  return ok == true;
}

/// 一道菜上「同一个人 + 同一个词」的命中合起来。
///
/// 判定出来的是逐食材的细颗粒（虾命中 3 样食材就是 3 条），
/// 但警示要按人读：「妈妈 对「虾」过敏（基围虾、虾皮、虾滑）」——
/// 把三条同样的"妈妈 过敏 · 虾"并排摆出来，等于让人自己再做一遍聚合。
class AllergenGroup {
  const AllergenGroup({
    required this.who,
    required this.word,
    required this.ings,
    required this.allergy,
  });

  final String who;
  final String word;
  final List<String> ings;
  final bool allergy;
}

List<AllergenGroup> groupAllergenHits(List<AllergenHit> hits) {
  final order = <String>[];
  final map = <String, AllergenGroup>{};
  for (final h in hits) {
    final k = '${h.memberId}|${h.kind}|${h.word}';
    final g = map[k];
    if (g == null) {
      order.add(k);
      map[k] = AllergenGroup(
          who: h.memberName,
          word: h.word,
          ings: [h.ingredient],
          allergy: h.isAllergy);
    } else if (!g.ings.contains(h.ingredient)) {
      map[k] = AllergenGroup(
          who: g.who,
          word: g.word,
          ings: [...g.ings, h.ingredient],
          allergy: g.allergy);
    }
  }
  // 警告排在提示前面（matchRecipe 已排过，这里防调用方拼接后失序）
  final list = [for (final k in order) map[k]!];
  list.sort((a, b) => (b.allergy ? 1 : 0).compareTo(a.allergy ? 1 : 0));
  return list;
}

/// 菜谱详情 / 菜单详情 / 做菜模式共用的那条顶部横幅。
///
/// 只在**有过敏命中**时才出现（忌口不足以拉起一条横幅，那是行内提示的活），
/// 没命中就返回零尺寸——调用处不用自己判空。
class RecipeAllergenBanner extends StatelessWidget {
  const RecipeAllergenBanner({
    required this.hits,
    this.title = '这道菜含过敏原，注意分餐',
    this.padding = const EdgeInsets.only(bottom: 14),
    this.withIngredients = true,
    super.key,
  });

  final List<AllergenHit> hits;
  final String title;

  /// 各页面的间距不同，但横幅本体必须长得一样。
  final EdgeInsets padding;

  /// 做菜模式里没空看食材清单（原型也只写「谁对什么过敏」），关掉这一段。
  final bool withIngredients;

  @override
  Widget build(BuildContext context) {
    final zj = context.zj;
    final groups =
        groupAllergenHits(hits).where((g) => g.allergy).toList();
    if (groups.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: padding,
      child: AllergenBanner(
        title: title,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final g in groups)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text.rich(TextSpan(
                  style: TextStyle(fontSize: 11.5, color: zj.ink2, height: 1.6),
                  children: [
                    TextSpan(
                        text: g.who,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    TextSpan(
                        text: ' 对「${g.word}」过敏'
                            '${withIngredients ? '（${g.ings.join('、')}）' : ''}'),
                  ],
                )),
              ),
          ],
        ),
      ),
    );
  }
}
