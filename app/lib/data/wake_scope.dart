import 'package:flutter/material.dart';

import 'screen_wake.dart';

/// 把 [ScreenWake] 注入组件树（R47 · FR-COOK-09）。
///
/// 与 `TimerScope` 同一族：**不做全局单例**，跟着树活、跟着树 dispose。
/// 必须挂在 `MaterialApp` 之上——做菜模式是从 navigator 推上来的一屏，
/// 挂在某个页面里会让下一屏取不到（R46 就为这条红过一次）。
class WakeScope extends InheritedWidget {
  const WakeScope({super.key, required this.wake, required super.child});

  final ScreenWake wake;

  static ScreenWake of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<WakeScope>();
    if (w == null) {
      throw StateError('组件树上没有 WakeScope——在 MaterialApp 外面包一层 '
          'WakeScope(wake: ...)，否则做菜模式的屏幕常亮无处登记');
    }
    return w.wake;
  }

  static ScreenWake? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<WakeScope>()?.wake;

  @override
  bool updateShouldNotify(WakeScope oldWidget) => oldWidget.wake != wake;
}
