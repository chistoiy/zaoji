import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// 厨房计时器台：**多实例并行 + 按目标时间戳倒计时**（R47 · FR-COOK-04/05）。
///
/// ## 为什么它要活在页面之外
///
/// 旧实现把状态放在 `_TimerSheet` 里：弹层一关，表就没了；切到别的屏，
/// 正在走的「炖 60 分钟」也随之消失。做菜现场的真实动线是
/// 「点胶囊起表 → 关弹层继续看步骤 → 中途还得起第二个表 → 回来看剩多少」，
/// 所以状态必须挂在一个跨页面活着的东西上——这里就是一个 [ChangeNotifier]，
/// 由 `TimerScope` 注入（**不是全局单例**，理由同 `StoreScope` 的头注：
/// 全局单例 + FakeAsync 测试区是陷阱）。
///
/// ## 心跳只做一件事
///
/// `_ticker` 每 250ms 调一次 [timerTick]：它**不改剩余量**（剩余量由
/// `endAtMs - now` 现算），只把跨过零点的实例迁移成 done。
/// 所以哪怕 Web 端把定时器节流到 1 分钟一跳，回来显示的仍是正确的剩余秒数——
/// 这就是 FR-COOK-05 要的东西，也是本轮换内核的全部理由。
class TimerBoard extends ChangeNotifier {
  TimerBoard({
    int Function()? clock,
    UlidFactory? ulids,
    bool Function()? vibrate,
    this.onFired,
  }) : _clock = clock ?? _systemClock,
       _ulids = ulids ?? UlidFactory(),
       _vibrate = vibrate ?? _defaultVibrate;

  static int _systemClock() => DateTime.now().millisecondsSinceEpoch;
  static bool _defaultVibrate() {
    // 网页端是空操作，真机上震一下。失败不该让计时器崩掉。
    HapticFeedback.vibrate();
    return true;
  }

  /// 注入时钟：测试要能把时间「拨快 10 分钟」而不真等（与原型走查同一个手法）。
  final int Function() _clock;
  final UlidFactory _ulids;

  /// 到点提醒的可关开关。R47-3 接本地通知时，这里会变成「震动/声音/语音」三路（FR-SET-03）。
  final bool Function() _vibrate;

  /// 「谁到点了」往外说一口（通知栏那一路走这里，见 `timer_alert.dart`）。
  ///
  /// 与 [_vibrate] 分开是有意的：震动是本机即时反馈，通知要过系统授权这道门，
  /// 两者的开关与失败方式都不一样，塞进同一个闸门就会互相顶掉。
  ///
  /// 做成**可后接**的字段而不是构造参数：接线方是 `main.dart`，
  /// 它可能拿到的是测试注入的板子（那时构造函数已经跑完了），
  /// 只有可赋值才做得到「不管板子是谁造的，提醒都从同一个闸门出」。
  void Function(List<KitchenTimer> fired)? onFired;

  List<KitchenTimer> _timers = const [];
  Timer? _ticker;
  bool _disposed = false;

  /// 测试与悬浮球用得到：本台当前有没有在走的表。
  bool get hasRunning => _timers.any((t) => t.running);
  int get count => _timers.length;
  List<KitchenTimer> get timers => _timers;
  int get nowMs => _clock();

  // ── 计时界面占场（R47 第八段）──────────────────────────────────────
  //
  /// 悬浮球在**计时界面自己占场**时必须消失。现在有两种：
  ///  · 全屏计时页——原型从第一版就是互斥渲染（`at.float` 与全屏二选一），
  ///    实现却把 `OverlayEntry` 一直挂在 root overlay 上，于是全屏页右下角还压着一颗球；
  ///  · 计时面板——球点开的就是它。面板列着每张表的「全屏/关闭」按钮，
  ///    球浮在它们上面会把按钮吃掉（414×844 上必撞，测试里加一条状态栏 padding 就复现了）。
  ///
  /// 记在板上而不是记在 overlay 里：板是这一族唯一的事实源，且它已经会被通知。
  /// 用**按来源计数的表**而不是 bool：
  ///  · 「全屏页里再 push 一层、退回来时球不该提前回来」→ 计数；
  ///  · 「面板 pop 与全屏 push 交错完成」→ 必须分得清是谁在占场。
  ///    面板那条 future 的 `whenComplete` 会在全屏登记**之后**才回调，
  ///    共用一个计数就会被它把全屏的登记一起减掉（球又冒出来），所以按来源分账。
  final Map<String, int> _occupants = {};
  bool get screenOccupied => _occupants.isNotEmpty;

  /// ★ 置位/撤手都会通知，但**不能在当前 build 帧里通知**：
  ///   悬浮球那层是 `ListenableBuilder`，在 build 中被 markNeedsBuild 会直接抛
  ///   （第一版把 `enterFullScreen()` 放在全屏页的 `initState` 里就是这么炸的）。
  ///   所以：调用点尽量放在 build 之外（`TimerFullPage.push` 是点击回调），
  ///   这里再兜一道——处在回调阶段就推到本帧结束后。
  void occupyScreen(String who) {
    _occupants[who] = (_occupants[who] ?? 0) + 1;
    _notifySafe();
  }

  void releaseScreen(String who) {
    final left = (_occupants[who] ?? 0) - 1;
    if (left > 0) {
      _occupants[who] = left;
    } else {
      _occupants.remove(who);
    }
    _notifySafe();
  }

  void _notifySafe() {
    if (_disposed) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      // 推到本帧结束后再通知：那一帧可能正好把板子拆了（app 卸载 / 测试收尾），
      // 所以这里必须再确认一次还活着，否则就是「TimerBoard was used after being disposed」。
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
      // 延后就要保证真有一帧会来，否则监听者永远等不到这次通知
      SchedulerBinding.instance.scheduleFrame();
    } else {
      notifyListeners();
    }
  }

  /// 起一个表。**已存在的表不受影响**（并行口径）。
  KitchenTimer start(String label, int seconds) {
    final t = timerStart(
      id: _ulids.next(),
      label: label,
      totalSeconds: seconds,
      nowMs: _clock(),
    );
    _timers = [..._timers, t];
    _ensureTicker();
    notifyListeners();
    return t;
  }

  void toggle(String id) {
    final t = _find(id);
    if (t == null) return;
    _replace(
      t.done
          ? timerRestart(t, nowMs: _clock())
          : t.running
          ? timerPause(t, nowMs: _clock())
          : timerResume(t, nowMs: _clock()),
    );
  }

  void pause(String id) {
    final t = _find(id);
    if (t != null && t.running) _replace(timerPause(t, nowMs: _clock()));
  }

  void resume(String id) {
    final t = _find(id);
    if (t != null && !t.running && !t.done) {
      _replace(timerResume(t, nowMs: _clock()));
    }
  }

  void reset(String id) {
    final t = _find(id);
    if (t != null) _replace(timerReset(t, nowMs: _clock()));
  }

  void extend(String id, int seconds) {
    final t = _find(id);
    if (t != null) _replace(timerExtend(t, seconds, nowMs: _clock()));
  }

  /// 关掉一个：**只删这一个**。剩下 N-1 个继续各走各的。
  void close(String id) {
    _timers = _timers.where((t) => t.id != id).toList();
    _ensureTicker();
    notifyListeners();
  }

  void closeAll() {
    _timers = const [];
    _ticker?.cancel();
    _ticker = null;
    notifyListeners();
  }

  /// 提醒闸门是否放行。**只有这一路真的接了线**才把这一行摆进设置页（FR-SET-03）。
  int get remindedCount => _reminded;
  int _reminded = 0;

  /// 把时间拨到 `nowMs` 并结算一次。生产里由心跳调用；测试直接调它验不漂移。
  /// 返回本次**新**到点的实例（提醒只对它们发）。
  List<KitchenTimer> tickAt(int nowMs) {
    final r = timerTick(_timers, nowMs: nowMs);
    _timers = r.timers;
    if (r.fired.isNotEmpty) {
      // ★ 三路提醒（FR-COOK-14）：震动走本机闸门，通知走 `TimerAlert` 的授权闸门。
      if (_vibrate()) _reminded += r.fired.length;
      // 回调里自己决定要不要 await（通知那条是异步的）；这里只负责**说一声**，
      // 不等回包——心跳每 250ms 一次，等通道会把心跳拖住。
      onFired?.call(r.fired);
    }
    if (r.fired.isNotEmpty || r.timers.any((t) => t.running)) notifyListeners();
    _ensureTicker();
    return r.fired;
  }

  /// 当前剩余量（秒）。UI 一律走这里，别自己减。
  double remainingOf(String id) {
    final t = _find(id);
    return t == null ? 0 : t.remainingAt(_clock());
  }

  KitchenTimer? _find(String id) {
    for (final t in _timers) {
      if (t.id == id) return t;
    }
    return null;
  }

  void _replace(KitchenTimer next) {
    _timers = [
      for (final t in _timers)
        if (t.id == next.id) next else t,
    ];
    _ensureTicker();
    notifyListeners();
  }

  /// 有在走的表才留心跳；全停/全关就停掉——不留空转的 Timer，
  /// 否则 widget 测试收尾会被「A Timer is still pending」挂住（本仓库踩过多次）。
  void _ensureTicker() {
    if (hasRunning) {
      _ticker ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
        tickAt(_clock());
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    super.dispose();
  }
}
