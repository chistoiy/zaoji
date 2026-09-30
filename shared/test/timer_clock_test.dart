import 'package:test/test.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// R47 · 计时内核。
///
/// 这一套钉的是**换内核的理由本身**：FR-COOK-05 / NFR-REL-03 要「后台 10 分钟误差 < 2 秒」，
/// 而旧实现是每 250ms 递减，节流一下就少走。所以下面最重的一条是「拨快时钟 = 正好少那么多」，
/// 以及「反复 tick 不累积误差」。并行独立性（FR-COOK-04）单独一组。
void main() {
  // 固定起点，避免测试自己变成时间炸弹（用户级规矩：测试里的时间要相对化或钉死）
  final t0 = DateTime(2026, 9, 29, 18).millisecondsSinceEpoch;
  int at(int secOffset) => t0 + secOffset * 1000;

  KitchenTimer start({String id = 'a', String label = '炖', int sec = 1800}) =>
      timerStart(id: id, label: label, totalSeconds: sec, nowMs: at(0));

  group('目标时间戳法', () {
    test('起表：剩余量就是时长，且 running', () {
      final t = start();
      expect(t.running, isTrue);
      expect(t.remainingAt(at(0)), closeTo(1800, 0.001));
      expect(t.endAtMs, at(1800));
    });

    test('★ 拨快 10 分钟 = 正好少 600 秒（后台节流不漂移）', () {
      final t = start();
      expect(t.remainingAt(at(600)), closeTo(1200, 0.001));
      // 误差预算按 NFR-REL-03 是 2 秒，这里要求的是**零**：
      // 剩余量完全由 endAt 现算，根本没有「少走」的机制存在。
      expect(1800 - t.remainingAt(at(600)), closeTo(600, 0.0001));
    });

    test('反复 tick 不累积误差（同一时刻算一百次结果一样）', () {
      final t = start();
      for (var i = 0; i < 100; i++) {
        expect(t.remainingAt(at(300)), closeTo(1500, 0.0001));
      }
    });

    test('到点归零，不出现负数', () {
      final t = start(sec: 60);
      expect(t.remainingAt(at(120)), 0);
      expect(t.isExpiredAt(at(61)), isTrue);
      expect(t.isExpiredAt(at(59)), isFalse);
    });

    test('tick 只做「到点」迁移，其余实例原样不动', () {
      final a = start(id: 'a', sec: 60);
      final b = start(id: 'b', sec: 3600);
      final r = timerTick([a, b], nowMs: at(120));
      expect(r.fired.map((t) => t.id), ['a']);
      expect(r.timers.firstWhere((t) => t.id == 'a').done, isTrue);
      expect(r.timers.firstWhere((t) => t.id == 'a').running, isFalse);
      expect(r.timers.firstWhere((t) => t.id == 'b').running, isTrue);
      expect(r.timers.firstWhere((t) => t.id == 'b').remainingAt(at(120)), closeTo(3480, 0.001));
    });
  });

  group('暂停 / 续跑 / 重置 / 加时', () {
    test('暂停把剩余量冻结在 leftSeconds', () {
      final p = timerPause(start(), nowMs: at(600));
      expect(p.running, isFalse);
      expect(p.leftSeconds, closeTo(1200, 0.001));
      // 冻结之后时间再走也不变——这是「暂停」的定义
      expect(p.remainingAt(at(9999)), closeTo(1200, 0.001));
    });

    test('★ 续跑必须用冻结值重算目标戳（沿用旧戳会当场归零）', () {
      final p = timerPause(start(), nowMs: at(600));
      final r = timerResume(p, nowMs: at(700));
      expect(r.running, isTrue);
      expect(r.remainingAt(at(700)), closeTo(1200, 1.0));
      expect(r.remainingAt(at(1000)), closeTo(900, 1.0));
    });

    test('重置回到起表时长并停在暂停态（不自己开跑）', () {
      final p = timerReset(start(), nowMs: at(900));
      expect(p.running, isFalse);
      expect(p.done, isFalse);
      expect(p.leftSeconds, 1800);
    });

    test('加时改的是目标戳：跑着的表 +60 秒，剩余就多 60 秒', () {
      final t = start();
      final e = timerExtend(t, 60, nowMs: at(0));
      expect(e.endAtMs, at(1860));
      expect(e.remainingAt(at(0)), closeTo(1860, 0.001));
      // 分母跟着抬，否则加完时进度环反而倒退
      expect(e.totalSeconds, 1860);
    });

    test('暂停态加时改 leftSeconds，不动 running', () {
      final p = timerPause(start(), nowMs: at(600));
      final e = timerExtend(p, 120, nowMs: at(600));
      expect(e.running, isFalse);
      expect(e.leftSeconds, closeTo(1320, 0.001));
    });

    test('完成态点一下 = 重新起同样的时长', () {
      final doneOne = timerTick([start(sec: 30)], nowMs: at(60)).fired.single;
      final r = timerRestart(doneOne, nowMs: at(100));
      expect(r.running, isTrue);
      expect(r.done, isFalse);
      expect(r.remainingAt(at(100)), closeTo(30, 0.001));
    });
  });

  group('并行实例各自独立（FR-COOK-04）', () {
    test('三个表各起各的目标戳，暂停其中一个不碰另外两个', () {
      final list = [
        start(id: 'a', sec: 300),
        start(id: 'b', sec: 600),
        start(id: 'c', sec: 900),
      ];
      final paused = [
        for (final t in list) if (t.id == 'a') timerPause(t, nowMs: at(100)) else t,
      ];
      expect(paused[0].running, isFalse);
      expect(paused[1].running, isTrue);
      expect(paused[2].running, isTrue);
      expect(paused[1].remainingAt(at(100)), closeTo(500, 0.001));
      expect(paused[2].remainingAt(at(100)), closeTo(800, 0.001));
    });

    test('提醒只对跨过零点的那一个发，其余不重复报', () {
      final list = [
        start(id: 'a', sec: 60),
        start(id: 'b', sec: 120),
      ];
      final r1 = timerTick(list, nowMs: at(90));
      expect(r1.fired.map((t) => t.id), ['a']);
      // 第二次 tick 不能再把 a 报一遍（否则会连响）
      final r2 = timerTick(r1.timers, nowMs: at(100));
      expect(r2.fired, isEmpty);
      final r3 = timerTick(r2.timers, nowMs: at(130));
      expect(r3.fired.map((t) => t.id), ['b']);
    });

    test('≥3 并行时各自进度互不干扰', () {
      final list = [
        start(id: 'a', sec: 100),
        start(id: 'b', sec: 200),
        start(id: 'c', sec: 400),
      ];
      final now = at(100);
      expect(timerProgress(list[0], nowMs: now), closeTo(1.0, 0.001));
      expect(timerProgress(list[1], nowMs: now), closeTo(0.5, 0.001));
      expect(timerProgress(list[2], nowMs: now), closeTo(0.25, 0.001));
    });
  });

  group('显示口径', () {
    test('mm:ss 向上取整：剩 0.4 秒显示 00:01，不是 00:00', () {
      expect(timerClockLabel(0.4), '00:01');
      expect(timerClockLabel(0), '00:00');
      expect(timerClockLabel(300), '05:00');
      expect(timerClockLabel(3599.5), '60:00');
    });

    test('总时长为 0 时进度返回 0，不出现 NaN', () {
      final t = KitchenTimer(
        id: 'z',
        label: '怪数据',
        totalSeconds: 0,
        endAtMs: at(0),
        leftSeconds: 0,
        running: true,
      );
      expect(timerProgress(t, nowMs: at(0)), 0);
    });
  });
}
