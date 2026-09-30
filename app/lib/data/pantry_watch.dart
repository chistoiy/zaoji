import 'package:flutter/foundation.dart';

import '../models.dart';
import 'timer_alert.dart';

/// 库存到期与临期的提醒（R47 · FR-PAN-04 缺的那半：推送时机）。
///
/// ## 触发点是「打开 App / 回前台」，不是后台定时
///
/// 这台设备上没有后台进程，服务端那台只管数据不管每台设备的作息；
/// 要做「人不在 App 里也按时弹」得走系统级排程（Android 精确闹钟权限 +
/// iOS/APNs），那是 M3 的架构账。所以这里的口径是：
/// **你一进厨房，它就先把该提醒的提醒掉**——厨房里最常发生的恰恰是
/// 「打开 App 找菜谱」这个动作，而判定函数（`PantryItem.expState`）早就做实了，
/// 缺的只是这一记出口。
///
/// ## 为什么聚合成两条而不是 N 条
///
/// 14 样临期就发 14 条横幅，用户只会把通知整个关掉——那连过期都看不见了。
/// 所以过期一条、临期一条，**id 固定**（1 与 2），重复提醒是覆盖而不是堆叠；
/// 名字列前 [_maxListed] 个，剩下的写进条数里。
///
/// ## 为什么静默
///
/// 到期提醒是「有空再看一眼」，不是「锅里正烧着」。**响的是计时器那一路**
/// （见 `TimerAlert.fire`）。这里发出去的通知一律 `sound: false`。
///
/// ## 「今天已经提醒过」要落本机
///
/// 只看内存的话，冷启动一次就多一次提醒，而这条链路又确实会在一天里
/// 被走好几回（回前台、切标签、重启）。去重戳落 `local_pref`
/// （本机事实，同主题/同悬浮窗一个口径，不进同步流）。
class PantryWatch {
  PantryWatch({
    required List<PantryItem> Function() items,
    required TimerAlert alert,
    required bool Function() notifyEnabled,
    required String Function() lastNotifiedDay,
    required Future<void> Function(String day) markNotified,
    DateTime Function()? clock,
  })  : _items = items,
        _alert = alert,
        _notifyEnabled = notifyEnabled,
        _lastNotifiedDay = lastNotifiedDay,
        _markNotified = markNotified,
        _clock = clock ?? _systemClock;

  static int _systemClockMs() => DateTime.now().millisecondsSinceEpoch;
  static DateTime _systemClock() => DateTime.fromMillisecondsSinceEpoch(_systemClockMs());

  /// 过期那条占通知 id 1，临期占 2。**与计时器号段（≥ [TimerAlert.timerIdFloor]）互不重叠**，
  /// 否则一条库存横幅会把正在等的计时器横幅顶掉。
  static const int noticeIdBad = 1;
  static const int noticeIdSoon = 2;

  /// 横幅里最多列几个名字（再长就该进 App 看，不是把通知栏写成清单）。
  static const int maxListed = 3;

  final List<PantryItem> Function() _items;
  final TimerAlert _alert;
  final bool Function() _notifyEnabled;
  final String Function() _lastNotifiedDay;
  final Future<void> Function(String day) _markNotified;
  final DateTime Function() _clock;

  /// 本轮扫到的过期项（首页卡与取证都读这三个计数，别去猜通知发没发）。
  int lastBad = 0;
  int lastSoon = 0;

  /// 真发出去几条：0 可能是「本机开关关了」「没授权」「今天提醒过」「没东西可提醒」。
  ///
  /// 这四种都该静默——提醒是体验，不该把调用方（App 启动动线）挂住或抛出去。
  Future<int> checkAndNotify() async {
    final now = _clock();
    final today = _day(now);
    final a = pantryAlertOf(_items(), now);
    lastBad = a.bad.length;
    lastSoon = a.soon.length;

    if (!a.hasExpiry) return 0;
    if (!_notifyEnabled()) return 0;
    if (_lastNotifiedDay() == today) return 0;

    final notices = [
      if (a.bad.isNotEmpty)
        AlertNotice(
          id: noticeIdBad,
          title: '${a.bad.length} 样已经过期',
          body: PantryAlert.names(a.bad),
          sound: false,
        ),
      if (a.soon.isNotEmpty)
        AlertNotice(
          id: noticeIdSoon,
          title: '${a.soon.length} 样三天内到期',
          body: PantryAlert.names(a.soon),
          sound: false,
        ),
    ];
    final n = await _alert.send(notices);
    // 只有真发出去才落戳：被授权闸门挡掉时不该把「今天」记成已经提醒过，
    // 否则用户点了授权之后，这台设备今天再也不会提醒了。
    if (n > 0) await _markNotified(today);
    return n;
  }

  /// 同一次判定用的自然日戳（YYYY-MM-DD）。跨天自动重新提醒。
  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 供测试与取证：把某天记成「已提醒」（正常路径由 [checkAndNotify] 自己写）。
  @visibleForTesting
  Future<void> debugMark(String day) => _markNotified(day);
}

/// 库存告警的三组（**厨房顶部卡与通知共用这一份口径**）。
///
/// 为什么抽出来：卡片要显示「已过期 / 三天内 / 快没了」，通知要发前两组，
/// 两处各写一遍 `have && expState(now) == 'bad'` 的话，过两天必然漂成两种说法
/// （R28 那个库存头部徽标已经是第三种说法了，本轮统一成这里的）。
class PantryAlert {
  const PantryAlert({
    this.bad = const [],
    this.soon = const [],
    this.low = const [],
    this.out = const [],
  });

  /// 已过期或今天到期（`expState == 'bad'`），到期日近的在前。
  final List<PantryItem> bad;

  /// 三天内到期（`expState == 'soon'`）。
  final List<PantryItem> soon;

  /// 用户自己标成「快没了」的那些（v7 三态里的 `low`，不是按克数猜的）。
  final List<PantryItem> low;

  /// 标成「没有」的。通知不发它（家里没有不是紧急事件），
  /// 但卡片要带：库存头部原来那四枚徽标被这张卡整组取代了，覆盖不能少一块。
  final List<PantryItem> out;

  /// 四组都空 = 这张卡根本不出现（FR-PAN-06 的验收判据就是「有数据时出现」）。
  bool get isEmpty => bad.isEmpty && soon.isEmpty && low.isEmpty && out.isEmpty;

  /// 通知只关心到期两组。
  bool get hasExpiry => bad.isNotEmpty || soon.isNotEmpty;

  /// 名字最多列 [PantryWatch.maxListed] 个，剩下的写成「等 N 样」。
  /// 通知正文与卡片用的是同一个截断，免得两处数字对不上。
  static String names(List<PantryItem> xs) {
    final head = xs.take(PantryWatch.maxListed).map((p) => p.name).join('、');
    return xs.length > PantryWatch.maxListed ? '$head 等 ${xs.length} 样' : head;
  }
}

/// 从一份库存算出告警三组。**纯函数**：不读时钟、不写任何东西，
/// 所以卡片每次 build 现算都行（`now` 由调用方给，测试要能把「今天」钉住）。
PantryAlert pantryAlertOf(List<PantryItem> items, DateTime now) {
  final live = items.where((p) => p.have);
  // 「没有」的不参与到期判定：家里本来就没有，提醒它过期没意义。
  final bad = live.where((p) => p.expState(now) == 'bad').toList()
    ..sort(_cmpExpire);
  final soon = live.where((p) => p.expState(now) == 'soon').toList()
    ..sort(_cmpExpire);
  final low = items.where((p) => p.status == PantryStock.low).toList()
    ..sort(_cmpExpire);
  final out = items.where((p) => p.status == PantryStock.none).toList()
    ..sort(_cmpExpire);
  return PantryAlert(bad: bad, soon: soon, low: low, out: out);
}

/// 到期日近的排前面；没填日期的本来就不会进这些列表。
int _cmpExpire(PantryItem a, PantryItem b) =>
    (a.expireAt ?? '9999').compareTo(b.expireAt ?? '9999');

