import 'package:flutter/material.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import '../data/timer_board.dart';
import '../theme.dart';
import 'timer_sheet.dart';

/// 悬浮计时球（R47 · FR-COOK-03「计时器支持全屏与悬浮窗两种形态，悬浮窗可拖动」）。
///
/// ## 为什么不是弹层
///
/// 上一版把计时器做成 modal bottom sheet：面板一开，底下的时间胶囊就被模态遮罩吃掉，
/// **「再起第二个表」这个动作在物理上做不到**（app 测试就是这么撞出来的：连点两次只起了一个）。
/// 做菜现场的动线是「一手看步骤、一手起表」，所以计时器必须活在**页面之上**的一层里：
/// 这里用 `Navigator` 的 root `Overlay`，它跨路由存在——切屏、进详情、进做菜模式，球都还在。
///
/// ## 拖动不越界
///
/// 位置钳在 `MediaQuery` 的安全区内（留一边 8px），松手也不会跑到状态栏或屏幕外。
/// 这条不是审美：球跑到屏幕外就等于计时器彻底丢了，用户只剩「重起一个」。
/// 球的固定外形。**钳位与本体必须用同一组常量**：
/// 第一版钳位按 78 宽算、球实际按内容长到 118+（并行时还挂 ×N 徽标），
/// 结果往右下猛拖能把它拖出屏幕右缘 42px——测试 `悬浮球可拖动且不越界` 就是这么抓到的。
/// 现在球被钉死在这个尺寸，钳位算的就是它真正的边。
const double _kBallW = 146;
const double _kBallH = 46;

class TimerOverlay {
  TimerOverlay({
    required this.board,
    required this.navigatorKey,
    this.visible,
    this.visibilityListenable,
  });

  final TimerBoard board;
  final GlobalKey<NavigatorState> navigatorKey;

  /// 悬浮窗开关（FR-SET-02）。关掉时不插 entry——界面上真的少一个东西，
  /// 而不是「看得见但点不动」的假关闭。
  final bool Function()? visible;

  /// 开关翻转时要立刻重算：偏好属于 store，而 store 不是 board。
  final Listenable? visibilityListenable;

  OverlayEntry? _entry;
  Offset? _pos; // null = 用默认位置（右下角）

  bool get isAttached => _entry != null;

  /// 跟着计时台活：有表且允许悬浮窗就上屏，条件不满足就自己收掉。
  void attach() {
    board.addListener(_sync);
    visibilityListenable?.addListener(_sync);
    _sync();
  }

  void detach() {
    board.removeListener(_sync);
    visibilityListenable?.removeListener(_sync);
    _entry?.remove();
    _entry = null;
  }

  void _sync() {
    final shouldShow = board.count > 0 && (visible?.call() ?? true);
    if (shouldShow && _entry == null) {
      final overlay = navigatorKey.currentState?.overlay;
      if (overlay == null) return; // navigator 还没建好，下一次心跳再来
      _entry = OverlayEntry(builder: (_) => _buildBall());
      overlay.insert(_entry!);
    } else if (!shouldShow && _entry != null) {
      _entry?.remove();
      _entry = null;
      _pos = null;
    } else if (_entry != null) {
      _entry?.markNeedsBuild();
    }
  }

  Widget _buildBall() {
    return IgnorePointer(
      // 球本身之外整屏都不吃掉：否则它变成一层看不见的挡板
      ignoring: false,
      child: LayoutBuilder(
        builder: (context, cons) {
          final pad = MediaQuery.of(context).padding;
          final safe = Rect.fromLTRB(
            8,
            pad.top + 8,
            cons.maxWidth - _kBallW - 8,
            cons.maxHeight - _kBallH - pad.bottom - 8,
          );
          final defaultPos = Offset(safe.right, safe.bottom - 8);
          final pos = _pos ?? defaultPos;
          final clamped = Offset(
            pos.dx.clamp(safe.left, safe.right),
            pos.dy.clamp(safe.top, safe.bottom),
          );
          return Stack(
            children: [
              Positioned(
                left: clamped.dx,
                top: clamped.dy,
                child: GestureDetector(
                  // 拖动只改本机位置：它是「这台设备怎么看方便」，不进同步（同备菜板口径）
                  onPanUpdate: (d) {
                    _pos = Offset(
                      (_pos?.dx ?? clamped.dx) + d.delta.dx,
                      (_pos?.dy ?? clamped.dy) + d.delta.dy,
                    );
                    _entry?.markNeedsBuild();
                  },
                  onTap: () => showTimerPanel(context, board: board),
                  // ★ 尺寸在这里钉死，钳位算的就是本体边（见 _kBallW 的头注）
                  child: SizedBox(
                    width: _kBallW,
                    height: _kBallH,
                    child: _TimerBall(board: board),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 球本体：焦点表的剩余时间 + 并行计数。
///
/// 数字走 [KitchenTimer.remainingAt]，这里**不做任何递减**——
/// 心跳只负责「该重画了」，值永远由目标戳现算（FR-COOK-05）。
class _TimerBall extends StatelessWidget {
  const _TimerBall({required this.board});

  final TimerBoard board;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: board,
      builder: (context, _) {
        final timers = board.timers;
        final focus = timers.isEmpty
            ? null
            : (timers.last.done && timers.length > 1 ? timers.first : timers.last);
        final left = focus == null ? 0.0 : focus.remainingAt(board.nowMs);
        final n = timers.length;
        return Semantics(
          button: true,
          label: '计时器，${focus?.label ?? ''} 剩余 ${timerClockLabel(left)}',
          child: Container(
            key: const ValueKey('timer-ball'),
            // 宽高由外层 SizedBox 钉死（钳位算的就是它），这里只负责把内容摆正
            width: double.infinity,
            height: double.infinity,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: focus != null && focus.done
                    ? [context.zj.ok, context.zj.ok]
                    : [context.zj.accent, const Color(0xFF8E2F0C)],
              ),
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 18,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  focus != null && focus.running
                      ? Icons.timer_outlined
                      : focus != null && focus.done
                          ? Icons.alarm_on_outlined
                          : Icons.pause_circle_outline,
                  size: 16,
                  color: context.zj.onAccent,
                ),
                const SizedBox(width: 7),
                Text(
                  timerClockLabel(left),
                  key: const ValueKey('timer-ball-time'),
                  style: TextStyle(
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    color: context.zj.onAccent,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (n > 1) ...[
                  const SizedBox(width: 8),
                  Container(
                    key: const ValueKey('timer-ball-count'),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.22),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '×$n',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: context.zj.onAccent,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
