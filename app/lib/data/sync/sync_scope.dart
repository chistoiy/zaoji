import 'package:flutter/material.dart';

import 'sync_engine.dart';

/// 把 [SyncEngine] 注入组件树——与 StoreScope 同一套思路：
/// 测试自建引擎、init 发生在测试自己的 zone 里，避免 zone 陷阱（见 store_scope.dart）。
class SyncScope extends InheritedWidget {
  const SyncScope({super.key, required this.engine, required super.child});

  final SyncEngine engine;

  static SyncEngine of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SyncScope>()!.engine;

  @override
  bool updateShouldNotify(SyncScope oldWidget) => oldWidget.engine != engine;
}
