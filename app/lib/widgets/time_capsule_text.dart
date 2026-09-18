import 'package:flutter/material.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import '../theme.dart';

/// 把一句步骤原文切成「普通文字 + 琥珀时间胶囊」。
///
/// ## 这里为什么值得单独抽一个函数
///
/// 产品的第一个记忆点是：用户写「小火炖 20 分钟」，查看时「20 分钟」
/// 自动变成一颗可点的琥珀胶囊。而**原文一个字都不能改写**——
/// 所以 `shared` 返回的是**区间**，这个函数负责把区间变成 spans。
///
/// 两端（Android 与 Web）跑的是同一份 `parseStepTimes`，
/// 但「区间 → 高亮」这一步是用 Flutter 的 `TextSpan` 做的，
/// 所以必须在这里再验一次：区间切出来的字符串，要和 `hit.text` 完全一致。
///
/// ## 为什么用 `WidgetSpan` 而不是 `TextSpan` + backgroundColor
///
/// 胶囊要圆角、要内边距、要带一个小图标，`TextDecoration` 做不到。
/// 代价是 `WidgetSpan` 不参与文字排版，所以下面用
/// `PlaceholderAlignment.middle` 并控制内边距，避免把行高撑开。
List<InlineSpan> buildTimeCapsuleSpans(
  String text, {
  required void Function(StepTimeHit hit) onTap,
  TextStyle? style,
}) {
  final hits = parseStepTimes(text);
  if (hits.isEmpty) return [TextSpan(text: text, style: style)];

  final spans = <InlineSpan>[];
  var cursor = 0;

  for (final hit in hits) {
    // 区间必须落在原文范围内——越界会让 substring 直接抛异常，
    // 而"抛异常"比"悄悄切错字"好，所以这里不吞错误。
    assert(
      hit.start >= 0 && hit.end <= text.length && hit.start < hit.end,
      'parseStepTimes 返回了越界区间 ${hit.start}..${hit.end}（原文长度 ${text.length}）',
    );
    assert(
      text.substring(hit.start, hit.end) == hit.text,
      '区间与 hit.text 不一致：区间切出「${text.substring(hit.start, hit.end)}」，'
      '但 hit.text 是「${hit.text}」。'
      '这说明解析器返回的偏移不是针对原文的（全角/规范化之后没映射回去），'
      '高亮会切错字。',
    );

    if (hit.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, hit.start), style: style));
    }
    spans.add(WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: TimeCapsule(
        // 胶囊上显示**原文**（「20 分钟」），不是换算后的 «20 分钟»。
        // 两者经常一样，但「半个 小时」这种就会不一样——那时必须忠于原文。
        text: text.substring(hit.start, hit.end),
        hit: hit,
        onTap: () => onTap(hit),
      ),
    ));
    cursor = hit.end;
  }

  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: style));
  }
  return spans;
}

/// 一颗琥珀时间胶囊。点一下起计时器。
class TimeCapsule extends StatelessWidget {
  const TimeCapsule({
    super.key,
    required this.text,
    required this.hit,
    required this.onTap,
  });

  final String text;
  final StepTimeHit hit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      // 读屏时要说明它可点、且点了会干什么，否则用户不知道这里有交互
      label: '时间 $text，点击开始计时',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1.5),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.fromLTRB(6, 1.5, 8, 1.5),
            decoration: BoxDecoration(
              color: ZaojiColors.amberBg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: ZaojiColors.amber.withValues(alpha: 0.35)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.timer_outlined, size: 13, color: ZaojiColors.amber),
                const SizedBox(width: 3),
                Text(
                  text,
                  style: const TextStyle(
                    color: ZaojiColors.amber,
                    fontWeight: FontWeight.w600,
                    // tabular figures：数字等宽，几颗胶囊排在一起时不会参差不齐
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
