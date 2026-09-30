import 'package:flutter/material.dart';

import 'timer_alert.dart';

/// 把 [TimerAlert] 注入组件树（R47 · FR-COOK-14）。
///
/// 挂 `MaterialApp` 之上、与 `TimerScope`/`WakeScope` 同层——设置页那一行
/// 「开启系统通知授权」是从 navigator 里推出来的页面上点的，
/// 挂在页面里取不到（R46/R47 已经各撞过一次了）。
class AlertScope extends InheritedWidget {
  const AlertScope({super.key, required this.alert, required super.child});

  final TimerAlert alert;

  static TimerAlert of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<AlertScope>();
    if (w == null) {
      throw StateError('组件树上没有 AlertScope——在 MaterialApp 外面包一层 '
          'AlertScope(alert: ...)，否则「计时结束通知」无处发起系统授权');
    }
    return w.alert;
  }

  static TimerAlert? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AlertScope>()?.alert;

  @override
  bool updateShouldNotify(AlertScope oldWidget) => oldWidget.alert != alert;
}
