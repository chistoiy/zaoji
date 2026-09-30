import 'package:flutter/material.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import '../data/timer_board.dart';
import '../theme.dart';

/// 全屏计时器（R47 · FR-COOK-03 的另一种形态）。
///
/// 原型 `timerFullHTML` 对应这一屏：**大环 + 大字读数 + 三个动作 + 快捷档**，
/// 左上角收成悬浮窗、右上角关闭。为什么要两种形态：
/// 手上沾着油和面时不需要看清小字，只需要一眼瞟到「还有多久」；
/// 而悬浮窗是「我要继续看步骤」的时候用的。两者共用同一个 [TimerBoard]，
/// 所以切形态不丢进度（FR-COOK-03「切换不丢失」的字面意思）。
class TimerFullPage extends StatefulWidget {
  const TimerFullPage({super.key, required this.board, required this.timerId});

  final TimerBoard board;
  final String timerId;

  static Future<void> open(BuildContext context, TimerBoard board, String timerId) {
    return Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TimerFullPage(board: board, timerId: timerId),
    ));
  }

  /// 已经拿着导航器时用这个（面板的「全屏」入口）：面板要先 pop 掉再推，
  /// 那个瞬间弹层的 context 已经失效，只能提前把 NavigatorState 取出来。
  static Future<void> push(
      NavigatorState nav, TimerBoard board, String timerId) {
    return nav.push(MaterialPageRoute<void>(
      builder: (_) => TimerFullPage(board: board, timerId: timerId),
    ));
  }

  @override
  State<TimerFullPage> createState() => _TimerFullPageState();
}

class _TimerFullPageState extends State<TimerFullPage> {
  late String _id = widget.timerId;

  /// 焦点可以在并行的几个表之间切：全屏态只关当前这个，其余照走。
  void _shift(int delta) {
    final ids = widget.board.timers.map((t) => t.id).toList();
    final i = ids.indexOf(_id);
    if (i < 0 || ids.length < 2) return;
    setState(() => _id = ids[(i + delta + ids.length) % ids.length]);
  }

  /// 横滑切表按**累计位移**判，不按松手速度：
  /// `tester.drag` 是瞬发的，`primaryVelocity` 会是 0，靠速度判的写法在测试里永不触发
  /// （首版就这么瞎了一次），而且真人慢慢划也应该换表。
  double _dragAcc = 0;
  void _onDragUpdate(DragUpdateDetails d) {
    _dragAcc += d.delta.dx;
    if (_dragAcc <= -48) {
      _shift(1);
      _dragAcc = 0;
    } else if (_dragAcc >= 48) {
      _shift(-1);
      _dragAcc = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.board,
      builder: (context, _) {
        final t = widget.board.timers.where((x) => x.id == _id).firstOrNull;
        if (t == null) {
          // 表在别处被关掉了：这一屏没有存在意义，安静退出而不是画一个空壳
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).maybePop();
          });
          return const SizedBox.shrink();
        }
        final left = t.remainingAt(widget.board.nowMs);
        final progress = timerProgress(t, nowMs: widget.board.nowMs);
        final n = widget.board.timers.length;
        return Scaffold(
          backgroundColor: const Color(0xFF231C15),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 26),
              child: Column(
                children: [
                  Row(
                    key: const ValueKey('timer-full-top'),
                    children: [
                      IconButton(
                        key: const ValueKey('timer-full-min'),
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.zoom_out_map,
                            size: 21, color: Color(0xFFFFF3E8)),
                        tooltip: '收成悬浮窗',
                      ),
                      Expanded(
                        child: Text(
                          t.label,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            color: Color(0xFFF5EEE0),
                          ),
                        ),
                      ),
                      if (n > 1) ...[
                        IconButton(
                          key: const ValueKey('timer-full-prev'),
                          onPressed: () => _shift(-1),
                          icon: const Icon(Icons.chevron_left,
                              size: 20, color: Color(0xFFB9A98F)),
                          tooltip: '上一个',
                        ),
                        Text(
                          _indexLabel,
                          key: const ValueKey('timer-full-count'),
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFFB9A98F)),
                        ),
                        IconButton(
                          key: const ValueKey('timer-full-next'),
                          onPressed: () => _shift(1),
                          icon: const Icon(Icons.chevron_right,
                              size: 20, color: Color(0xFFB9A98F)),
                          tooltip: '下一个',
                        ),
                      ],
                      IconButton(
                        key: const ValueKey('timer-full-close'),
                        onPressed: () {
                          widget.board.close(_id);
                          Navigator.of(context).pop();
                        },
                        icon: const Icon(Icons.close,
                            size: 21, color: Color(0xFFFFF3E8)),
                        tooltip: '关掉这个',
                      ),
                    ],
                  ),
                  const Spacer(),
                  GestureDetector(
                    // 大环本身是切表手势：横滑一下就换下一个并行表，
                    // 不用先把悬浮窗收回去点列表
                    onHorizontalDragStart: (_) => _dragAcc = 0,
                    onHorizontalDragUpdate: _onDragUpdate,
                    child: SizedBox(
                      width: 250,
                      height: 250,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          SizedBox.expand(
                            child: CircularProgressIndicator(
                              value: progress,
                              strokeWidth: 9,
                              backgroundColor:
                                  const Color(0x22FFF3E8),
                              valueColor: AlwaysStoppedAnimation(
                                t.done ? const Color(0xFF7FD9A6) : Color(0xFFD2491C),
                              ),
                            ),
                          ),
                          Text(
                            timerClockLabel(left),
                            key: const ValueKey('timer-full-time'),
                            style: TextStyle(
                              fontSize: 54,
                              fontWeight: FontWeight.w500,
                              color: t.done
                                  ? const Color(0xFF7FD9A6)
                                  : const Color(0xFFFFF3E8),
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    t.done
                        ? '时间到'
                        : t.running
                            ? '正在计时'
                            : '已暂停',
                    key: const ValueKey('timer-full-state'),
                    style: const TextStyle(
                        fontSize: 13, color: Color(0xFFB9A98F)),
                  ),
                  const Spacer(),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _RoundBtn(
                        key: const ValueKey('timer-full-reset'),
                        icon: Icons.refresh,
                        onTap: () => widget.board.reset(_id),
                      ),
                      const SizedBox(width: 22),
                      _BigToggle(
                        key: const ValueKey('timer-full-toggle'),
                        running: t.running,
                        done: t.done,
                        onTap: () => widget.board.toggle(_id),
                      ),
                      const SizedBox(width: 22),
                      _RoundBtn(
                        key: const ValueKey('timer-full-extend'),
                        icon: Icons.add,
                        onTap: () => widget.board.extend(_id, 60),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (final q in const [(1, '1 分'), (3, '3 分'), (5, '5 分'), (10, '10 分')])
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: TextButton(
                            key: ValueKey('timer-full-quick-${q.$1}'),
                            onPressed: () =>
                                widget.board.start(t.label, q.$1 * 60),
                            child: Text(
                              q.$2,
                              style: const TextStyle(
                                  fontSize: 13, color: Color(0xFFF5EEE0)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 「第几个」的显示：全屏态左右切表时要让人知道切到哪了。
  String get _indexLabel {
    final ids = widget.board.timers.map((t) => t.id).toList();
    final i = ids.indexOf(_id);
    return i < 0 ? '?' : '${i + 1}/${ids.length}';
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required super.key, required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 46,
      height: 46,
      child: IconButton(
        onPressed: onTap,
        icon: Icon(icon, size: 20, color: const Color(0xFFFFF3E8)),
        style: IconButton.styleFrom(
          backgroundColor: const Color(0x22FFF3E8),
        ),
      ),
    );
  }
}

class _BigToggle extends StatelessWidget {
  const _BigToggle({
    required super.key,
    required this.running,
    required this.done,
    required this.onTap,
  });

  final bool running;
  final bool done;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 78,
      height: 78,
      child: IconButton(
        onPressed: onTap,
        icon: Icon(
          done
              ? Icons.replay
              : running
                  ? Icons.pause
                  : Icons.play_arrow,
          size: 34,
          color: context.zj.onAccent,
        ),
        style: IconButton.styleFrom(
          backgroundColor: const Color(0xFFD2491C),
        ),
        tooltip: done ? '再来一次' : running ? '暂停' : '继续',
      ),
    );
  }
}
