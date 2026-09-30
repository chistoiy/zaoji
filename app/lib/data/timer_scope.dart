import 'package:flutter/material.dart';

import 'timer_board.dart';

/// 把 [TimerBoard] 注入组件树。
///
/// 与 `StoreScope` 同一个理由：**不做全局单例**。
/// 计时台里有周期 Timer，全局单例会让它活在被 FakeAsync 管辖之外，
/// 测试收尾时留下「A Timer is still pending」；跟着树活、跟着树 dispose 才干净。
///
/// 放在 `StoreScope` 外层还是内层都行——它不依赖数据库。
/// 唯一要求：**要跨页面活着**，所以挂在 `MaterialApp` 之上（弹层从 navigator 推，
/// 挂在页面里会找不到；这是 R46 就钉过的同一条）。
class TimerScope extends InheritedWidget {
  const TimerScope({super.key, required this.board, required super.child});

  final TimerBoard board;

  /// 取不到就抛人话异常：漏挂 scope 的表现是「点时间胶囊没反应」，
  /// 那种静默失败比崩更难查，所以宁可响。
  static TimerBoard of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<TimerScope>();
    if (w == null) {
      throw StateError('组件树上没有 TimerScope——在 MaterialApp 外面包一层 '
          'TimerScope(board: ...)，否则计时器活不过页面切换');
    }
    return w.board;
  }

  /// 有就返回、没有返回 null：给「可有可无」的地方用（如悬浮球只在主页挂）。
  static TimerBoard? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TimerScope>()?.board;

  @override
  bool updateShouldNotify(TimerScope oldWidget) => oldWidget.board != board;
}
