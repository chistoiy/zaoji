/// R47 · 厨房计时器的内核：**按目标时间戳倒计时**，支持多实例并行。
///
/// 放 shared 的理由与 `nutrition_math.dart` 同一条：Android 与 Web 是两份编译产物，
/// 「切后台回来还剩多少」这种口径各写一遍必然会漂；做菜页、悬浮球、
/// 将来的时间轴排程（R50 的等待类步骤自动转计时器）都要吃同一套算法。
///
/// 三条硬口径（需求书 FR-COOK-04 / FR-COOK-05、NFR-REL-03）：
/// ① **剩余量 = `endAtMs - now`**，不是每跳减一格。旧实现（`timer_sheet.dart` 的
///    `Timer.periodic` + `_remaining -= 1`）在浏览器后台节流/息屏下会少走好几秒，
///    「后台 10 分钟误差 < 2 秒」根本达不到——这是本轮换内核的唯一理由。
/// ② 暂停把剩余量**冻结**在 [KitchenTimer.leftSeconds]，续跑用冻结值**重算** `endAtMs`。
///    续跑时若沿用旧的 `endAtMs`，回来会立刻跳到 0。
/// ③ 每个实例自带 id，所有操作都以实例为单位——两个锅不能共用一个暂停键。
library;

import 'dart:math' as math;

/// 一个计时器实例的不可变快照。
class KitchenTimer {
  const KitchenTimer({
    required this.id,
    required this.label,
    required this.totalSeconds,
    required this.endAtMs,
    required this.leftSeconds,
    this.running = false,
    this.done = false,
  });

  /// 稳定标识（ULID 或本机自增）。列表操作与提醒都要靠它认实例。
  final String id;

  /// 显示名，来自步骤里的那句话（「水开后大火蒸 6 分钟」）。
  final String label;

  /// 起表时的总时长，用于画进度环的比例。**加时会不会改它**见 [timerExtend]。
  final int totalSeconds;

  /// 目标墙上时钟戳（毫秒）。running 期间的唯一真相；暂停/完成后无意义。
  final int? endAtMs;

  /// 暂停或完成时冻结的剩余秒数；running 期间由 [remainingAt] 现算，不读它。
  final double leftSeconds;

  final bool running;
  final bool done;

  /// 到点没有：running 且目标戳已过期。
  bool isExpiredAt(int nowMs) => running && (endAtMs ?? 0) <= nowMs;

  /// **唯一**的剩余量取法。UI 不许自己拿 `endAtMs` 减，也不许自己递减。
  double remainingAt(int nowMs) =>
      running ? math.max(0, (endAtMs! - nowMs) / 1000.0) : leftSeconds;

  KitchenTimer copyWith({
    String? label,
    int? totalSeconds,
    int? endAtMs,
    double? leftSeconds,
    bool? running,
    bool? done,
  }) =>
      KitchenTimer(
        id: id,
        label: label ?? this.label,
        totalSeconds: totalSeconds ?? this.totalSeconds,
        endAtMs: endAtMs ?? this.endAtMs,
        leftSeconds: leftSeconds ?? this.leftSeconds,
        running: running ?? this.running,
        done: done ?? this.done,
      );
}

/// 起一个表：目标戳 = 现在 + 时长，立刻走。
KitchenTimer timerStart({
  required String id,
  required String label,
  required int totalSeconds,
  required int nowMs,
}) =>
    KitchenTimer(
      id: id,
      label: label,
      totalSeconds: totalSeconds,
      endAtMs: nowMs + totalSeconds * 1000,
      leftSeconds: totalSeconds.toDouble(),
      running: true,
    );

/// 暂停：把剩余量按当前目标戳冻结，之后不再随时间变。
KitchenTimer timerPause(KitchenTimer t, {required int nowMs}) => t.running
    ? t.copyWith(
        running: false,
        leftSeconds: t.remainingAt(nowMs),
      )
    : t;

/// 续跑：**用冻结的剩余量重算目标戳**。
/// 沿用旧戳的话，暂停 3 分钟再续会立刻归零（这是换内核时最容易写错的一处）。
KitchenTimer timerResume(KitchenTimer t, {required int nowMs}) => t.running || t.done
    ? t
    : t.copyWith(
        running: true,
        endAtMs: nowMs + (t.leftSeconds.round() * 1000),
      );

/// 重置：回到起表时长，停在暂停态（不自己开跑——重置的意图是「我要重新决定」）。
KitchenTimer timerReset(KitchenTimer t, {required int nowMs}) => t.copyWith(
      running: false,
      done: false,
      leftSeconds: t.totalSeconds.toDouble(),
      endAtMs: nowMs + t.totalSeconds * 1000,
    );

/// 加时。**改的是目标戳**（running 中），只改显示值的话下一次 tick 会立刻减回去。
/// 进度环的分母跟着抬，否则加完时环反而「倒退」。
KitchenTimer timerExtend(KitchenTimer t, int extraSeconds, {required int nowMs}) {
  if (t.running) {
    final newEnd = (t.endAtMs ?? nowMs) + extraSeconds * 1000;
    return t.copyWith(
      endAtMs: newEnd,
      totalSeconds: math.max(t.totalSeconds, ((newEnd - nowMs) / 1000).round()),
      done: false,
    );
  }
  final left = t.leftSeconds + extraSeconds;
  return t.copyWith(
    leftSeconds: left,
    totalSeconds: math.max(t.totalSeconds, left.round()),
    done: false,
  );
}

/// 一次心跳的结果：新列表 + 本次到点的实例（提醒只对到点那一个发）。
class TimerTickResult {
  const TimerTickResult({required this.timers, required this.fired});
  final List<KitchenTimer> timers;

  /// 这一次跨过零点的实例。没到点的是空表。
  final List<KitchenTimer> fired;
}

/// 把所有 running 的实例按目标戳结算一遍。
///
/// 注意它**不改 leftSeconds**（running 期间剩余量由 [KitchenTimer.remainingAt] 现算），
/// 只做「到点」这一件事的状态迁移。所以反复调它不会累积误差——这正是想要的性质。
TimerTickResult timerTick(List<KitchenTimer> timers, {required int nowMs}) {
  final fired = <KitchenTimer>[];
  final next = <KitchenTimer>[];
  for (final t in timers) {
    if (t.isExpiredAt(nowMs)) {
      final doneOne = t.copyWith(running: false, done: true, leftSeconds: 0);
      fired.add(doneOne);
      next.add(doneOne);
    } else {
      next.add(t);
    }
  }
  return TimerTickResult(timers: next, fired: fired);
}

/// 完成态点一下重来（原型的 `timer-toggle` 在 done 上的分支）。
KitchenTimer timerRestart(KitchenTimer t, {required int nowMs}) => t.copyWith(
      done: false,
      running: true,
      endAtMs: nowMs + t.totalSeconds * 1000,
      leftSeconds: t.totalSeconds.toDouble(),
    );

/// 显示用：`mm:ss`，向上取整到秒（0.4 秒还剩就别显示 00:00，会以为结束了）。
String timerClockLabel(double seconds) {
  final s = seconds.ceil();
  final m = s ~/ 60;
  final r = s % 60;
  return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
}

/// 进度环的比例（0 = 刚起表，1 = 到点）。分母为 0 时返回 0，别画 NaN。
double timerProgress(KitchenTimer t, {required int nowMs}) {
  if (t.totalSeconds <= 0) return 0;
  final left = t.remainingAt(nowMs);
  return (1 - left / t.totalSeconds).clamp(0.0, 1.0);
}
