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

/// 耳朵形态（R47 第八段）：吸到边上后收成一条窄耳朵，挡内容的宽度从 146 缩到 26。
/// 高度比球略高一点，是为了让"点一下展开"这个目标不至于太小（NFR-UX-11）。
const double _kEarW = 26;
const double _kEarH = 66;

/// 离边多远就算"靠边"——松手时按这个阈值决定要不要吸附（与原型同一口径 40 设计像素）。
const double _kSnapEdge = 40;

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

  // R47 第八段 · 吸边收起的两条状态。
  //
  // `_snapped` 是事实源：贴着某一侧时**横向位置由边决定**（左=0、右=屏宽-本体宽），
  // 不存 x。Flutter 这边不存在原型那种"量出来的宽度会漂"的问题——
  // 球与耳朵的宽高都是钉死的常量（见 `_kBallW` / `_kEarW`），所以算得准。
  bool _snapped = false;
  bool _onLeft = false;
  bool _collapsed = false;

  /// 当前形态的本体宽度（钳位与贴边都按它算）。
  double get _bodyW => _collapsed ? _kEarW : _kBallW;
  double get _bodyH => _collapsed ? _kEarH : _kBallH;

  bool get isAttached => _entry != null;

  /// 取证用：现在是不是收成耳朵了（测试断言状态，不去猜 DOM 长相）。
  bool get isCollapsed => _collapsed;

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
    // ★ 计时界面自己占场时不上屏（全屏页 / 计时面板，见 `TimerBoard.screenOccupied`）：
    //   原型里这两种形态与悬浮球是互斥的，实现却把 entry 一直挂着，
    //   于是全屏页右下角压着一颗球、面板里的按钮也被球吃掉。
    final shouldShow =
        board.count > 0 && !board.screenOccupied && (visible?.call() ?? true);
    if (shouldShow && _entry == null) {
      final overlay = navigatorKey.currentState?.overlay;
      if (overlay == null) return; // navigator 还没建好，下一次心跳再来
      _entry = OverlayEntry(builder: (_) => _buildBall());
      overlay.insert(_entry!);
    } else if (!shouldShow && _entry != null) {
      _entry?.remove();
      _entry = null;
      // ★ 只在「一张表都不剩」时才把位置与形态清回默认。
      //   全屏页打开也会走这条分支，那时清掉的话退回来球就弹回右下角、耳朵也展开了——
      //   用户会以为是自己点丢了。
      if (board.count == 0) {
        _pos = null;
        _snapped = false;
        _onLeft = false;
        _collapsed = false;
      }
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
          final w = _bodyW, h = _bodyH;
          final safe = Rect.fromLTRB(
            8,
            pad.top + 8,
            cons.maxWidth - w - 8,
            cons.maxHeight - h - pad.bottom - 8,
          );
          // 贴边态：横向由「哪条边」决定（本体宽度是常量，算得准）；
          // 自由态：用拖出来的坐标，钳在安全区内（跑出去就等于计时器丢了）。
          final x = _snapped
              ? (_onLeft ? 0.0 : cons.maxWidth - w)
              : (_pos?.dx ?? safe.right).clamp(safe.left, safe.right);
          final y = (_pos?.dy ?? safe.bottom - 8).clamp(safe.top, safe.bottom);

          final Widget body;
          if (_collapsed) {
            body = _TimerEar(
              board: board,
              onLeft: _onLeft,
              // 只切形态：贴哪一边保持不变（展开后不该跳回右下角）
              onTap: () {
                _collapsed = false;
                _entry?.markNeedsBuild();
              },
            );
          } else {
            body = GestureDetector(
              onPanStart: (_) {
                if (!_snapped) return;
                // 从贴边状态起拖：先把横向坐标实体化，否则第一帧会从边上跳走
                _pos = Offset(_onLeft ? 0.0 : cons.maxWidth - _kBallW, y);
                _snapped = false;
              },
              // 拖动只改本机位置：它是「这台设备怎么看方便」，不进同步（同备菜板口径）
              //
              // ★ 钳位必须在**拖的过程中**做，而不是只在渲染时做：
              //   第一版只钳渲染值，`_pos` 累加的是原始位移（往右猛拖 600 会存成 868），
              //   于是下一次 `onPanEnd` 拿这个没钳过的值判"靠不靠边"，一判就中，
              //   球在离边很远的地方自己收成耳朵。真实位置才是判据的唯一来源。
              onPanUpdate: (d) {
                final nx = (_pos?.dx ?? x) + d.delta.dx;
                final ny = (_pos?.dy ?? y) + d.delta.dy;
                _pos = Offset(
                  nx.clamp(safe.left, safe.right),
                  ny.clamp(safe.top, safe.bottom),
                );
                _entry?.markNeedsBuild();
              },
              onPanEnd: (_) {
                final cx = _pos?.dx ?? x;
                final nearLeft = cx <= _kSnapEdge;
                final nearRight = cx + _kBallW >= cons.maxWidth - _kSnapEdge;
                if (!nearLeft && !nearRight) {
                  _snapped = false;
                } else {
                  // 靠边松手 = 吸附 + 收成耳朵（用户要的就是「别挡内容」）
                  _onLeft = nearLeft;
                  _snapped = true;
                  _collapsed = true;
                }
                _entry?.markNeedsBuild();
              },
              onTap: () => showTimerPanel(context, board: board),
              // ★ 尺寸在这里钉死，钳位与贴边算的就是本体边（见 _kBallW 的头注）
              child: SizedBox(
                width: _kBallW,
                height: _kBallH,
                child: _TimerBall(board: board),
              ),
            );
          }

          return Stack(
            children: [Positioned(left: x, top: y, child: body)],
          );
        },
      ),
    );
  }
}

/// 耳朵形态：贴边的一条窄耳朵，只留一个计时图标与并行计数（收起也不丢「还有几张表」）。
///
/// 它是**可点的**：点一下展开成完整球。收起来不显示读数是有意的——
/// 读数属于「展开看」那一层，耳朵的职责只是「别挡住下面的菜，同时告诉你我还在」。
class _TimerEar extends StatelessWidget {
  const _TimerEar({
    required this.board,
    required this.onLeft,
    required this.onTap,
  });

  final TimerBoard board;
  final bool onLeft;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: board,
      builder: (context, _) {
        final n = board.count;
        final anyDone = board.timers.any((t) => t.done);
        return Semantics(
          button: true,
          label: '展开计时器${n > 1 ? '，共 $n 个' : ''}',
          child: GestureDetector(
            key: const ValueKey('timer-ear'),
            onTap: onTap,
            child: Container(
              width: _kEarW,
              height: _kEarH,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: anyDone
                      ? [context.zj.ok, context.zj.ok]
                      : [context.zj.accent, const Color(0xFF8E2F0C)],
                ),
                // 圆角只朝屏幕内侧：贴着边的那一侧是平的，看着才是"长在外面"
                borderRadius: onLeft
                    ? const BorderRadius.only(
                        topRight: Radius.circular(13),
                        bottomRight: Radius.circular(13),
                      )
                    : const BorderRadius.only(
                        topLeft: Radius.circular(13),
                        bottomLeft: Radius.circular(13),
                      ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.28),
                    blurRadius: 14,
                    offset: Offset(onLeft ? 4 : -4, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    anyDone ? Icons.alarm_on_outlined : Icons.timer_outlined,
                    size: 15,
                    color: context.zj.onAccent,
                  ),
                  if (n > 1)
                    Text(
                      '×$n', // 与完整球的计数同一写法（一处 ×N，两处不该两种说法）
                      key: const ValueKey('timer-ear-count'),
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: context.zj.onAccent,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
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
            : (timers.last.done && timers.length > 1
                  ? timers.first
                  : timers.last);
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
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
