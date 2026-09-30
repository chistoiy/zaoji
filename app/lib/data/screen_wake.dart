import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// 谁需要屏幕常亮，以及**要不要真亮着**（R47 · FR-COOK-09）。
///
/// ## 为什么是「记账本」而不是一枚布尔
///
/// 做菜现场同时有两路人需要屏幕别灭：**做菜模式本身**（手是湿的，划不动屏就废了）
/// 和**正在走的计时器**（「炖 40 分钟」期间人会在锅里翻东西，屏一灭锁屏就看不见剩余）。
/// 两路各自开、各自关，谁都不能替对方决定灭屏——所以这里按 `reason` 计数：
/// **最后一路撤掉才真的关锁**。用一枚布尔会出的事故是：
/// 计时器先跑完把锁撤了，而人还在做菜模式里盯着步骤，屏就此熄灭。
///
/// ## 为什么要注入 toggle
///
/// 插件是静态方法（`WakelockPlus.toggle`），widget 测试里没有通道实现，
/// 真调会 `MissingPluginException` 把无关的用例炸掉；而且测试要断的是
/// **「第几次调、参数是什么」这种命令序列**，不是屏幕真灭没灭。
/// 所以外部只看到 [need]/[done]/[active]，落盘动作交给一个可替换的 [WakeToggle]。
///
/// ## 失败为什么不响
///
/// 常亮是体验，不是数据。桌面/无通道的运行环境（以及个别 ROM）会直接抛，
/// 让它冒出来会把「进入做菜模式」整个搞挂。这里吞掉异常并记住最后一次错误，
/// 由 [lastError] 暴露给取证用（本项目的日志口径：一条记录一行，别在这里刷屏）。
class ScreenWake extends ChangeNotifier {
  ScreenWake({WakeToggle? toggle}) : _toggle = toggle ?? _pluginToggle;

  /// 真的去拨锁的那一步；测试里换成记录调用序列的假实现。
  final WakeToggle _toggle;

  final Set<String> _reasons = <String>{};
  bool? _applied;

  /// 拨锁失败时留下的最后一句话（成功路径不改它）。
  String? lastError;

  /// 当前有哪几路在要常亮（顺序稳定，便于断言与取证）。
  List<String> get reasons => _reasons.toList(growable: false);

  /// 有没有任意一路在要。
  bool get active => _reasons.isNotEmpty;

  /// [reason] 这一路要常亮。**重复登记不产生第二次拨锁**。
  void need(String reason) {
    if (!_reasons.add(reason)) return;
    _apply(true);
  }

  /// [reason] 这一路撤了。**只有最后一路撤掉才真的关灯**。
  void done(String reason) {
    if (!_reasons.remove(reason)) return;
    if (_reasons.isEmpty) _apply(false);
  }

  /// 现在命令下去的状态。还没拨过任何一次时返回 `false`
  /// （`_applied` 内部用 `null` 区分「还没开始」与「已经关」，别把这两态并成一态）。
  bool get commanded => _applied ?? false;

  void _apply(bool on) {
    // 同值不重发：插件自己也会去重，但我们连累它的次数越少越好。
    if (_applied == on) return;
    _applied = on;
    try {
      _toggle(on);
    } catch (e) {
      lastError = e.toString();
    }
    notifyListeners();
  }

  static void _pluginToggle(bool on) {
    // 不 await：调用点都在 UI 动线里（进页面 / 起表），
    // 等通道回包会把动线挂住；失败由 lastError 之外的 try/catch 兜。
    unawaited(WakelockPlus.toggle(enable: on).catchError((Object e) {
      // 静态类上没有地方存错误，退回到 zone 的未处理异常之前先咽一次，
      // 免得桌面预览与无通道环境把「进入做菜模式」搞挂。
      debugPrint('wakelock 拨锁失败：$e');
    }));
  }

  /// 跟着组件树收：撤掉所有路并关灯。
  /// 幂等——已经空了也不会多发一次拨锁。
  void releaseAll() {
    if (_reasons.isEmpty && _applied != true) return;
    _reasons.clear();
    _apply(false);
  }

  @override
  void dispose() {
    _reasons.clear();
    super.dispose();
  }
}

/// 拨锁动作本身（[ScreenWake] 的可注入出口）。
typedef WakeToggle = void Function(bool on);
