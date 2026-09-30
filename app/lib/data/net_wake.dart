import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// 网络恢复即同步（R47 第七段 · 需求书 §9.2 S1「飞行模式新增 10 道菜 → 恢复网络后自动同步」）。
///
/// ## 为什么这一路要单独成文件
///
/// 同步原本有四条触发线：写入防抖 3 秒、失败退避 ≤8 次、15 分钟兜底、启动一次。
/// 飞行模式里连做十道菜，全部写进本地库并排进 change_log，然后：
/// 防抖那次同步**必然失败**（没网），退避 8 次在几分钟内烧完，
/// 之后就只能等 15 分钟兜底或用户手动「立即同步」。
/// 需求书要的是「恢复网络后自动同步」——**恢复**这个事件没人听，所以 S1 不成立
/// （计划书 §22.3 第 1 条点名的就是这个洞）。这里补的就是那一只耳朵。
///
/// ## 三条判定口径，各有用例钉着
///
/// ① **第一个事件只记录不触发**：启动路径自己已经同步过一次（`main.dart` 的 postFrame），
///    把「开 App 时读到 wifi」当成恢复，等于每次冷启动多打一轮无谓的同步。
/// ② **只有离线→在线的上升沿才算恢复**：wifi 直接切移动网络（没断过）不算；
///    在线时反复抖动也不算。平台侧的流已经 `distinct` 过，但那只是去重复读数，
///    不代替边沿判定。
/// ③ **上升沿要合并**：现实中恢复的那一瞬间常连着好几条读数（none→vpn→wifi）。
///    每次上升沿都同步一遍，就是在网络刚通的时候连环打服务端。
///    所以 [debounce] 窗口内的多次上升沿只回调一次。
///
/// ## 为什么失败只留痕不响
///
/// 监听是"让同步更及时"，不是数据正确性的一部分：桌面预览、测试区、
/// 个别没通道的运行环境都会在这里抛 `MissingPluginException`。
/// 让它炸掉 App，或者让一次同步失败变成一条红字，都不符合"这一路是体验"的定位
/// （与 `screen_wake.dart` 同一立场：咽掉、记 [lastError]、继续干活）。
class NetWake {
  NetWake({
    required Stream<List<ConnectivityResult>> Function() streamOf,
    required FutureOr<void> Function() onOnline,
    Duration debounce = const Duration(seconds: 3),
  })  : _streamOf = streamOf,
        _onOnline = onOnline,
        _debounce = debounce;

  /// 取流的**函数**而不是流本身：`Connectivity()` 依赖平台通道，
  /// 把它当构造参数取就会在 App 起来的那一刻（甚至 dispose 里）碰通道。
  /// 交给 [start] 去取，取不到与订不上都归同一处 try/catch。
  final Stream<List<ConnectivityResult>> Function() _streamOf;
  final FutureOr<void> Function() _onOnline;
  final Duration _debounce;

  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _timer;

  /// 最近一次读数（`null` = 一条都还没收到）。取证与测试读它，别去猜内部状态。
  List<ConnectivityResult>? lastResults;

  /// 认出过几次「离线→在线」的上升沿（与 [triggers] 对比就是合并率）。
  int edges = 0;

  /// 真的回调过几次 [onOnline]（合并之后）。
  int triggers = 0;

  /// 监听/回调失败时留下的最后一句话（成功路径不改它）。
  String? lastError;

  /// 是否已经启动过（重复 start 不该订阅两次——那会让一次恢复同步两遍）。
  bool get isListening => _sub != null;

  /// 「离线」= 读数只含 none（平台文档：没有连接时列表里就只有它）。
  static bool isOffline(List<ConnectivityResult> r) =>
      r.isEmpty || r.every((x) => x == ConnectivityResult.none);

  /// 开始监听。**幂等**：已经订着就什么都不做。
  void start() {
    if (_sub != null) return;
    try {
      _sub = _streamOf().listen(_onEvent, onError: (Object e) {
        // 流自己报错不等于"没有网络"，只记痕并继续订着（下一次恢复还要能听见）。
        lastError = e.toString();
      });
    } catch (e) {
      // 桌面预览 / 测试区没有通道实现，构造订阅就会抛。咽掉：这一路是体验。
      lastError = e.toString();
      _sub = null;
    }
  }

  void _onEvent(List<ConnectivityResult> results) {
    final previous = lastResults;
    lastResults = results;
    // ① 第一个事件只记录：启动已经同步过一次，不把它当恢复。
    if (previous == null) return;
    // ② 上升沿：上一次是离线，这次不是。
    if (!isOffline(previous) || isOffline(results)) return;
    edges++;
    // ③ 合并：窗口内再来上升沿只是重置倒计时，到点只回调一次。
    _timer?.cancel();
    _timer = Timer(_debounce, () async {
      _timer = null;
      try {
        triggers++;
        await _onOnline();
      } catch (e) {
        // 一次同步失败不该让监听哑掉——退避与兜底那两线还在。
        lastError = e.toString();
      }
    });
  }

  /// 撤手：取消订阅与未触发的定时器（widget 测试的 FakeAsync 纪律：收尾不能留 Timer）。
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    final sub = _sub;
    _sub = null;
    try {
      await sub?.cancel();
    } catch (e) {
      lastError = e.toString();
    }
  }
}

/// 生产用的监听源。**单独一个函数**是为了让测试能换成 `StreamController.stream`：
/// `Connectivity()` 是单例且依赖平台通道，在测试区构造订阅就会抛
/// （与 `ScreenWake` 的 `WakeToggle`、`TimerAlert` 的 `NoticeSender` 同一手法）。
Stream<List<ConnectivityResult>> connectivityStream() =>
    Connectivity().onConnectivityChanged;
