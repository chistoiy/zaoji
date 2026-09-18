import 'package:flutter/material.dart';

import '../theme.dart';

/// 难度辣椒刻度。**产品的三个记忆点之一。**
///
/// 为什么不用星星或圆点：这个产品的场景是灶台边，「几个辣椒」比「几颗星」
/// 更贴近厨房的语言，而且一眼能看出辣度。原型里已经这么定了。
///
/// 用 `CustomPaint` 画而不是找图标，是因为 Material 里没有辣椒，
/// 而形状是这套设计的记忆点之一——拿个火苗凑合会让它变成一个普通 App。
class ChiliScale extends StatelessWidget {
  const ChiliScale({
    super.key,
    required this.level,
    this.total = 3,
    this.size = 14,
    this.offColor,
  });

  /// 1 ~ [total]。
  final int level;
  final int total;
  final double size;

  /// 空位辣椒的颜色。默认用分隔线色（在纸底上）；
  /// **封面插画上要传浅色**——底图是深色遮罩，线色会看不见。
  final Color? offColor;

  /// 原型 `diffLabel()`：难度的一句话说法，跟在辣椒后面。
  static String diffLabel(int level) =>
      const ['', '轻松', '还行', '费功夫'][level.clamp(0, 3)];

  @override
  Widget build(BuildContext context) {
    final filled = level.clamp(0, total);
    final off = offColor ?? ZaojiColors.line;
    return Semantics(
      // 读屏用户看不到辣椒，必须把量表直接说出来
      label: '难度 $filled 级，共 $total 级',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < total; i++)
            Padding(
              padding: EdgeInsets.only(right: i == total - 1 ? 0 : 2),
              child: CustomPaint(
                size: Size(size, size),
                painter: _ChiliPainter(
                  filled: i < filled,
                  fillColor: ZaojiColors.chili,
                  offColor: off,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChiliPainter extends CustomPainter {
  const _ChiliPainter({
    required this.filled,
    required this.fillColor,
    required this.offColor,
  });

  final bool filled;
  final Color fillColor;
  final Color offColor;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final body = Path()
      // 尖端在左下
      ..moveTo(w * 0.10, h * 0.94)
      // 左缘向上鼓出来
      ..cubicTo(w * 0.00, h * 0.56, w * 0.20, h * 0.24, w * 0.60, h * 0.18)
      // 顶部圆润地转过来
      ..cubicTo(w * 0.94, h * 0.13, w * 0.98, h * 0.42, w * 0.80, h * 0.60)
      // 右缘收回尖端
      ..cubicTo(w * 0.62, h * 0.80, w * 0.32, h * 0.88, w * 0.10, h * 0.94)
      ..close();

    final color = filled ? fillColor : offColor;
    canvas.drawPath(
      body,
      Paint()
        ..color = color
        ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..strokeJoin = StrokeJoin.round,
    );

    // 梗。空心时也画，这样刻度看起来仍是一排辣椒而不是一排色块。
    canvas.drawLine(
      Offset(w * 0.58, h * 0.18),
      Offset(w * 0.76, h * 0.04),
      Paint()
        ..color = color
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_ChiliPainter old) =>
      old.filled != filled || old.fillColor != fillColor || old.offColor != offColor;
}
