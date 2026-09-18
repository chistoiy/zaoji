import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';

/// 起一个计时器。
///
/// **这一轮（M0）刻意只做最简单的倒计时**：需求里的多计时器、悬浮窗、
/// 通知栏提醒、屏幕常亮是 M2 的内容。M0 要验证的是
/// 「在 iPhone 的 Safari 里点一下，计时真的会走」——
/// 而这件事刚好能顺带验掉 `Timer` 与安全上下文（Web 端后台节流）的行为。
///
/// 另外这里也是「四个安全上下文能力」的第一处落点：
/// 真机上做完一道菜之后，屏幕该不该一直亮着，取决于 `wakeLock` 可不可用。
Future<void> showTimerSheet(
  BuildContext context, {
  required String sourceText,
  required int seconds,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: ZaojiColors.paper,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(ZaojiRadius.xl)),
    ),
    builder: (_) => _TimerSheet(sourceText: sourceText, seconds: seconds),
  );
}

class _TimerSheet extends StatefulWidget {
  const _TimerSheet({required this.sourceText, required this.seconds});

  final String sourceText;
  final int seconds;

  @override
  State<_TimerSheet> createState() => _TimerSheetState();
}

class _TimerSheetState extends State<_TimerSheet> {
  Timer? _ticker;
  late int _remaining = widget.seconds;
  bool _running = false;
  bool _done = false;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _toggle() {
    if (_done) {
      setState(() {
        _remaining = widget.seconds;
        _done = false;
        _running = false;
      });
      return;
    }
    if (_running) {
      _ticker?.cancel();
      setState(() => _running = false);
      return;
    }
    setState(() => _running = true);
    // 用 1 秒一跳的周期 + 递减，而不是记录开始时间来算差值：
    // 这一轮先要「看得见在走」。真机上要处理的漂移与后台节流是 M2 的事
    // （届时改成按时间戳计算，否则切后台回来会少走几秒）。
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _remaining -= 1;
        if (_remaining <= 0) {
          _remaining = 0;
          _running = false;
          _done = true;
          _ticker?.cancel();
        }
      });
      if (_done) {
        // 网页端是空操作，真机上会震一下。失败也不该让计时器崩掉
        HapticFeedback.vibrate();
      }
    });
  }

  String get _display {
    final m = (_remaining ~/ 60).toString().padLeft(2, '0');
    final s = (_remaining % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.seconds == 0 ? 0.0 : 1 - _remaining / widget.seconds;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _done ? '时间到' : '计时中',
            style: ZaojiText.display(
              fontSize: 16,
              color: ZaojiColors.ink2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            widget.sourceText,
            style: const TextStyle(fontSize: 13, color: ZaojiColors.muted),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: 190,
            height: 190,
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox.expand(
                  child: CircularProgressIndicator(
                    value: progress.clamp(0, 1),
                    strokeWidth: 6,
                    backgroundColor: ZaojiColors.lineSoft,
                    valueColor: AlwaysStoppedAnimation(
                      _done ? ZaojiColors.accent : ZaojiColors.amber,
                    ),
                  ),
                ),
                Text(
                  _display,
                  style: ZaojiText.display(
                    fontSize: 52,
                    fontWeight: FontWeight.w500,
                    color: _done ? ZaojiColors.accent : ZaojiColors.ink,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 26),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: FilledButton(
              onPressed: _toggle,
              style: FilledButton.styleFrom(
                backgroundColor: ZaojiColors.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(ZaojiRadius.md),
                ),
              ),
              child: Text(
                _done
                    ? '再来一次'
                    : _running
                        ? '暂停'
                        : '开始',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
