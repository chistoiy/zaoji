import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// 计时结束往通知栏发的那一路（R47 · FR-COOK-14），以及它的**系统授权态**。
///
/// ## 为什么授权态要单独成一个状态机
///
/// 通知不是 App 自己能决定的事：Android 13+ 与浏览器的 Notification API 都要
/// **用户在系统弹框里点一次允许**，而且**只能在用户手势里发起**。
/// 所以这里的初始态是 [NotifyPermission.unknown]，而不是假装「肯定是开着的」：
/// * Android 启动时能读到真实值（`areNotificationsEnabled`），于是不用再劝；
/// * Web 在用户点之前**读不到**，只能保持 unknown，界面上给出「开启授权」那一行。
///
/// 把 unknown 写成 granted 的话，设置页会少掉授权入口、而通知永远发不出去——
/// 症状正是本轮查漏补缺在清的那类「看着开着其实没通」。
///
/// ## 为什么 sender 可注入
///
/// widget 测试区没有插件通道实现，真调会 `MissingPluginException`；
/// 而这里真正要断的是**闸门**：没授权时一条都不发、声音关掉时 `sound=false`、
/// 一次到点发几条。所以发送动作是一个可替换的 [NoticeSender]，
/// 与 `ScreenWake` 同一手法（见 `screen_wake.dart` 头注）。
class TimerAlert extends ChangeNotifier {
  TimerAlert({
    NoticeSender? sender,
    PermissionRequester? requestPermission,
    PermissionReader? readPermission,
    SystemSettingsOpener? openSettings,
  })  : _sender = sender ?? _pluginSend,
        _requestPermission = requestPermission ?? _pluginRequest,
        _readPermission = readPermission ?? _pluginRead,
        _openSettings = openSettings ?? _pluginOpenSettings;

  /// 通知渠道 id：渠道与横幅都靠它对齐，改名要连真机上已有的渠道一起想清楚。
  static const String channelId = 'zaoji_timer';
  static const String channelName = '计时结束';
  static const String channelDescription = '厨房计时器到点提醒（并行时每个实例一条）';

  final NoticeSender _sender;
  final PermissionRequester _requestPermission;
  final PermissionReader _readPermission;

  /// 去系统设置改通知权限（denied 那一路的唯一出路）。
  final SystemSettingsOpener _openSettings;

  NotifyPermission permission = NotifyPermission.unknown;

  /// 发送/授权失败时留下的最后一句话（成功路径不改它）。
  String? lastError;

  int _sent = 0;
  int _skipped = 0;

  /// 真发出去几条（测试与取证都读这两个计数，别去猜插件状态）。
  int get sentCount => _sent;

  /// 因为没授权而被挡掉几条。
  int get skippedCount => _skipped;

  /// 启动时调一次：Android 能把 unknown 收敛成真值，Web 读不到就保持 unknown。
  Future<void> init() async {
    try {
      final r = await _readPermission();
      if (r == true) {
        permission = NotifyPermission.granted;
      } else if (r == false && !kIsWeb) {
        // 只有原生端「读到 false」才是被拒；Web 那边读不到统一留给 unknown。
        permission = NotifyPermission.denied;
      }
    } catch (e) {
      lastError = e.toString();
    }
    notifyListeners();
  }

  /// 由**用户手势**发起（设置页那一行「开启系统通知授权」）。
  /// 返回是否拿到了授权。
  Future<bool> requestAccess() async {
    try {
      final ok = await _requestPermission();
      permission = ok ? NotifyPermission.granted : NotifyPermission.denied;
    } catch (e) {
      lastError = e.toString();
      permission = NotifyPermission.denied;
    }
    notifyListeners();
    return permission == NotifyPermission.granted;
  }

  /// 被拒过一次之后，系统不再让 App 反复弹框——这时唯一的正规出路是去系统设置里改。
  /// 没有这一口，denied 那一路就成了死胡同（界面上写着「去系统设置里改」却不给入口）。
  /// Web 端没有这个 API：那里点不动就还是走 [requestAccess]。
  Future<void> openSystemSettings() async {
    try {
      await _openSettings();
    } catch (e) {
      lastError = e.toString();
    }
  }

  /// 计时器到点那一批（FR-COOK-14）。文案与 id 在这里拼，发送统一走 [send]。
  ///
  /// [sound] 是「通知带声音」这一路（FR-SET-03）：关掉仍是发通知，只是静默落一条横幅。
  /// [vibrate] 是「计时结束震动」那一路（FR-SET-03）——★ 它走**通知自己的振动**，
  /// 不再只靠 `HapticFeedback.vibrate()`：后者在系统「触摸反馈」关掉时会被静默吞掉
  /// （真机实测：`settings get system haptic_feedback_enabled` = 0 时完全没感觉），
  /// 而渠道级 `enableVibration` 一直是 false（那是为了不让它变成「设置里关不掉的震动」）。
  /// 两者一叠加，用户得到的就是「到点既不响也不震」——所以这里按每条通知传，
  /// 开关仍然只管这一路：`vibrateOn` 关 → 传 false → 真的不振。
  Future<int> fire(List<KitchenTimer> fired, {required bool sound, bool vibrate = false}) =>
      send([
        for (final t in fired)
          AlertNotice(
            id: noticeIdOf(t.id),
            title: '「${t.label}」时间到',
            body: t.done ? '该起锅了' : '还剩一点，别忘了',
            sound: sound,
            vibrate: vibrate,
          ),
      ]);

  /// 通用出口：**任何一路**要往通知栏发都走这里（计时器、库存临期都共用同一道授权闸门）。
  ///
  /// 没有授权就一条都不发——挡掉而不是抛，因为这是常态不是异常（Web 授权前、
  /// Android 上被拒过，都是正常状态）。挡掉的条数进 [skippedCount] 留痕。
  Future<int> send(List<AlertNotice> notices) async {
    if (notices.isEmpty) return 0;
    if (permission != NotifyPermission.granted) {
      _skipped += notices.length;
      return 0;
    }
    var n = 0;
    for (final notice in notices) {
      try {
        await _sender(notice);
        n++;
        _sent++;
      } catch (e) {
        // 一条失败不挡住后面那几条：并行计时器本来就是各发各的。
        lastError = e.toString();
      }
    }
    notifyListeners();
    return n;
  }

  /// 计时器通知 id：**ULID → 正整数**，同一条计时器多次到点撞同一个 id，
  /// 系统会把旧的那条替换掉而不是攒一屏垃圾。
  ///
  /// ★ **一律 ≥ [timerIdFloor]**：库存那两路（过期 / 临期）用的是 1、2 这种小固定 id，
  /// 两边分成互不重叠的两段，就不会出现「一条过期提醒把计时器横幅顶掉」。
  static int noticeIdOf(String timerId) =>
      (timerId.hashCode & 0x07ffffff) | timerIdFloor;

  /// 计时器 id 的下界（库存占用它以下的号段）。
  static const int timerIdFloor = 1000;

  // ——— 以下是默认实现：真插件 ———

  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  /// 应用启动时调一次：建渠道 + 初始化。失败只记 `lastError` 那一类，
  /// 由调用方（`main.dart`）吞掉——通知发不出去不该让 App 起不来。
  static Future<void> setupPlugin() async {
    await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('@mipmap/ic_launcher'),
        web: const WebInitializationSettings(),
      ),
    );
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(AndroidNotificationChannel(
      channelId,
      channelName,
      description: channelDescription,
      importance: Importance.max,
      // 震动归 KitchenPrefs.vibrateOn 那一路（TimerBoard 里），渠道自己不重复振。
      enableVibration: false,
    ));
  }

  static Future<void> _pluginSend(AlertNotice n) => _plugin.show(
        id: n.id,
        title: n.title,
        body: n.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            channelDescription: channelDescription,
            importance: Importance.max,
            priority: Priority.high,
            category: AndroidNotificationCategory.reminder,
            playSound: n.sound,
            // ★ 振动按**每条通知**决定：渠道那一层一直是 false（否则变成「设置里关不掉的震动」），
            //   而 App 侧的 HapticFeedback 会被系统「触摸反馈」开关静默吞掉——
            //   两头都不振 = 用户以为功能没做。这里传 vibrateOn，开关仍然说一不二。
            enableVibration: n.vibrate,
          ),
          web: WebNotificationDetails(
            isSilent: !n.sound,
            requireInteraction: true,
          ),
        ),
      );

  static Future<bool> _pluginRequest() async {
    if (kIsWeb) {
      final p = _plugin
          .resolvePlatformSpecificImplementation<
              WebFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      return p != null && await p == true;
    }
    final p = _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    return p != null && await p == true;
  }

  static Future<void> _pluginOpenSettings() async {
    await _plugin.openAppNotificationSettings();
  }

  static Future<bool?> _pluginRead() async {
    // Web 在用户点过之前读不到授权态，这里不去猜（理由见类头注）。
    if (kIsWeb) return null;
    return _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.areNotificationsEnabled();
  }
}

/// 一条要发的通知。**id 复用**是刻意的（同一条计时器不堆两条横幅）。
class AlertNotice {
  const AlertNotice({
    required this.id,
    required this.title,
    required this.body,
    required this.sound,
    this.vibrate = false, // 静默是默认：只有灶上到点那一路会传 true
  });

  final int id;
  final String title;
  final String body;
  final bool sound;

  /// 这条通知要不要振动（FR-SET-03 的震动那一路）。
  final bool vibrate;
}

/// 发一条通知（默认走插件；测试里换成记录用的假实现）。
typedef NoticeSender = Future<void> Function(AlertNotice notice);

/// 向系统要授权，返回是否同意。
typedef PermissionRequester = Future<bool> Function();

/// 打开系统的通知设置页（异步：插件调用本身要 await）。
typedef SystemSettingsOpener = Future<void> Function();

/// 读当前授权态；`null` = 这一端读不出来（Web 授权前就是这种）。
typedef PermissionReader = Future<bool?> Function();

/// 系统通知授权态。
enum NotifyPermission { unknown, granted, denied }
