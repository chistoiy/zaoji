import 'package:flutter/material.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import '../data/timer_board.dart';
import '../data/timer_scope.dart';
import '../theme.dart';
import 'timer_full_page.dart';

/// 计时面板（R47 重做）：**多计时器并行 + 按目标时间戳倒计时**。
///
/// ## 与旧实现的两处本质区别
///
/// ① 状态不在弹层里，而在 [TimerBoard] 上。旧的 `_TimerSheet` 自己持有
///    `Timer? _ticker` 与 `int _remaining`——弹层一关表就没了，切到别的屏也在走的东西消失。
///    做菜现场的动线是「点胶囊起表 → 关弹层看步骤 → 中途再起第二个 → 回来看剩多少」，
///    所以表必须活在跨页面的地方（FR-COOK-03「切换不丢失」的最小说法）。
/// ② 剩余量一律走 [KitchenTimer.remainingAt]，没有任何地方 `-= 1`。
///    Web 端后台把定时器节流到几十秒一跳，回来看到的仍是正确剩余（FR-COOK-05）。
///
/// 面板本身刻意不画第二个环：三个并行时三个环既占屏又没法比较，
/// 改成「一行一个 + 细进度条」，当前焦点行放大字——和原型一致。
/// 点时间胶囊 = **起一个新表**，不打开面板。
///
/// 为什么不弹面板：面板是模态的，一开就把底下的步骤文字与其余胶囊全吃掉，
/// 「再起第二个表」这个动作在物理上做不到（app 测试连点两次只起了一个，就是这么撞出来的）。
/// 表起来后由 [TimerOverlay] 的悬浮球跟着你（FR-COOK-03），要看列表点球。
void startKitchenTimer(BuildContext context, {
  required String sourceText,
  required int seconds,
}) {
  TimerScope.of(context).start(sourceText, seconds);
}

/// 打开计时面板（悬浮球点它）。已存在的表全部列出，各自可暂停/加时/关闭。
Future<void> showTimerPanel(BuildContext context, {required TimerBoard board}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    backgroundColor: context.zj.paper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(ZaojiRadius.xl)),
    ),
    builder: (_) => _TimerBoardSheet(board: board),
  );
}

class _TimerBoardSheet extends StatelessWidget {
  const _TimerBoardSheet({required this.board});

  final TimerBoard board;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: board,
      builder: (context, _) {
        final timers = board.timers;
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 2, 20, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('计时器',
                      style: ZaojiText.displayOf(context,
                          fontSize: 17, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 8),
                  // 计数徽标只在 ≥2 时出现：一个表的时候它是噪声
                  if (timers.length > 1)
                    _CountBadge(n: timers.length)
                  else
                    const SizedBox.shrink(),
                  const Spacer(),
                  if (timers.isNotEmpty)
                    TextButton(
                      key: const ValueKey('timer-close-all'),
                      // 故意不 pop：关掉所有表后面板留下「没有在计的表」这个空态，
                      // 用户能确认「真没了」而不是「界面消失了」。弹层自己拖下去就行。
                      onPressed: board.closeAll,
                      child: const Text('全部关闭'),
                    ),
                ],
              ),
              if (timers.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6, bottom: 4),
                  child: Text(
                    '没有在计的表',
                    key: const ValueKey('timer-board-empty'),
                    style: TextStyle(fontSize: 13, color: context.zj.muted),
                  ),
                )
              else
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final t in timers)
                          _TimerRow(board: board, timer: t),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.n});

  final int n;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('timer-count'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: context.zj.accent,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '并行 $n',
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: context.zj.onAccent,
        ),
      ),
    );
  }
}

class _TimerRow extends StatelessWidget {
  const _TimerRow({required this.board, required this.timer});

  final TimerBoard board;
  final KitchenTimer timer;

  @override
  Widget build(BuildContext context) {
    // 剩余量每个心跳由 board 推一次重建；这里**只读不算**，
    // 组件里再存一份倒计时就是回到旧 bug 的路径。
    final left = timer.remainingAt(board.nowMs);
    final progress = timerProgress(timer, nowMs: board.nowMs);
    return Container(
      key: ValueKey('timer-row-${timer.id}'),
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      decoration: BoxDecoration(
        color: context.zj.paper2,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(
          color: timer.done ? context.zj.ok : context.zj.lineSoft,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  timer.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: context.zj.muted),
                ),
              ),
              Text(
                timer.done
                    ? '时间到'
                    : timer.running
                        ? '计时中'
                        : '已暂停',
                key: ValueKey('timer-state-${timer.id}'),
                style: TextStyle(
                  fontSize: 11.5,
                  color: timer.done
                      ? context.zj.ok
                      : timer.running
                          ? context.zj.amber
                          : context.zj.muted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                timerClockLabel(left),
                key: ValueKey('timer-time-${timer.id}'),
                style: ZaojiText.displayOf(context,
                  fontSize: 34,
                  fontWeight: FontWeight.w500,
                  color: timer.done ? context.zj.ok : context.zj.ink,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 5,
                      backgroundColor: context.zj.lineSoft,
                      valueColor: AlwaysStoppedAnimation(
                        timer.done ? context.zj.ok : context.zj.accent,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _TimerButton(
                key: ValueKey('timer-toggle-${timer.id}'),
                label: timer.done
                    ? '再来一次'
                    : timer.running
                        ? '暂停'
                        : '继续',
                primary: true,
                onTap: () => board.toggle(timer.id),
              ),
              const SizedBox(width: 8),
              _TimerButton(
                key: ValueKey('timer-extend-${timer.id}'),
                label: '+1 分',
                onTap: () => board.extend(timer.id, 60),
              ),
              const SizedBox(width: 8),
              _TimerButton(
                key: ValueKey('timer-reset-${timer.id}'),
                label: '重置',
                onTap: () => board.reset(timer.id),
              ),
              const SizedBox(width: 8),
              // 全屏形态的入口（FR-COOK-03 的另一态）：手上沾着油时只想一眼看到大数字。
              // ★ 先收起面板再推全屏：面板不叠在全屏底下，否则从全屏回退会落回一个
              //   看不见的面板，再点悬浮球就是**两层面板**（测试里 close-all 撞成两个就是这个）。
              _TimerButton(
                key: ValueKey('timer-full-${timer.id}'),
                label: '全屏',
                onTap: () {
                  final nav = Navigator.of(context);
                  nav.pop();
                  TimerFullPage.push(nav, board, timer.id);
                },
              ),
              const Spacer(),
              IconButton(
                key: ValueKey('timer-close-${timer.id}'),
                onPressed: () => board.close(timer.id),
                icon: Icon(Icons.close, size: 19, color: context.zj.muted),
                tooltip: '关掉这个',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TimerButton extends StatelessWidget {
  const _TimerButton({
    required super.key,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: primary ? context.zj.accent : context.zj.surface,
          foregroundColor: primary ? context.zj.onAccent : context.zj.ink2,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZaojiRadius.sm),
          ),
        ),
        child: Text(label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: primary ? FontWeight.w700 : FontWeight.w600,
            )),
      ),
    );
  }
}
