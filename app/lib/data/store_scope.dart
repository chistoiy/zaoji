import 'package:flutter/material.dart';

import 'recipe_store.dart';

/// 把 [RecipeStore] 注入组件树。
///
/// ## 为什么用 InheritedWidget 而不是全局单例
///
/// **全局单例 + widget 测试是 zone（区）陷阱**：`setUpAll` 在真实 async 区
/// 完成的 Future，它的监听器排在真实 zone 的微任务队列里——
/// `testWidgets` 的 FakeAsync 区推帧时**永远看不到它完成**，
/// 症状是「pumpAndSettle 超时」，而同样的代码在纯 `test()` 里一切正常。
/// 修法不是绕，而是让每个测试自建 store、init 发生在测试自己的区里，
/// 页面通过 context 取——依赖也跟着干净了（生产代码不需要任何改动）。
class StoreScope extends InheritedWidget {
  const StoreScope({super.key, required this.store, required super.child});

  final RecipeStore store;

  static RecipeStore of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StoreScope>()!.store;

  @override
  bool updateShouldNotify(StoreScope oldWidget) => oldWidget.store != store;
}
