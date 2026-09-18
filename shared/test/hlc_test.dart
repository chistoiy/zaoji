import 'package:test/test.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

void main() {
  group('Hlc · 编解码', () {
    test('往返一致', () {
      const a = Hlc(1790000000123, 7, 'phone-01');
      final b = Hlc.decode(a.encode());
      expect(b, a);
    });

    test('编码定长（字典序可比的前提）', () {
      final parts = Hlc(1, 0, 'x').encode().split('-');
      expect(parts, hasLength(3));
      expect(parts[0].length, 13);
      expect(parts[1].length, 4);
    });

    test('★ 字典序 == 时间序', () {
      // 这条不成立的话，服务端就不能用 ORDER BY updated_at 排序，
      // 而必须把每一行解析出来在内存里排 —— 那是灾难性的。
      final list = <Hlc>[
        const Hlc(1000, 0, 'a'),
        const Hlc(1000, 1, 'a'),
        const Hlc(1001, 0, 'a'),
        const Hlc(999, 5, 'z'),
        const Hlc(1000, 0, 'b'),
      ];

      final byStruct = [...list]..sort((x, y) => x.compareTo(y));
      final byString = [...list]
        ..sort((x, y) => x.encode().compareTo(y.encode()));

      expect(
        byString.map((e) => e.encode()).toList(),
        byStruct.map((e) => e.encode()).toList(),
      );
    });

    test('脏数据返回 null 而不是抛异常（不能打断同步循环）', () {
      expect(Hlc.tryDecode('garbage'), isNull);
      expect(Hlc.tryDecode(''), isNull);
      expect(Hlc.tryDecode('zzzz-0000-x'), isNull);
    });
  });

  group('Hlc · 单调性', () {
    test('tick 严格递增', () {
      var t = const Hlc(5000, 0, 'a');
      final seen = <Hlc>[t];
      for (var i = 0; i < 5; i++) {
        t = t.tick('a', wallMs: 5000);
        expect(t.compareTo(seen.last), greaterThan(0));
        seen.add(t);
      }
    });

    test('★ 时钟回拨时不回退', () {
      const t0 = Hlc(5000, 0, 'a');
      // 用户把系统时间从 5000 调回 1000
      final t1 = t0.tick('a', wallMs: 1000);

      expect(t1.compareTo(t0), greaterThan(0), reason: '排序必须仍然正确');
      expect(t1.physicalMs, 5000, reason: '物理时间不回退');
      expect(t1.counter, 1, reason: '靠 counter 维持单调');
    });

    test('物理时间推进后 counter 归零', () {
      const t0 = Hlc(5000, 42, 'a');
      final t1 = t0.tick('a', wallMs: 6000);
      expect(t1.physicalMs, 6000);
      expect(t1.counter, 0);
    });

    test('counter 溢出时进位到下一毫秒，而不是回绕', () {
      const t0 = Hlc(5000, Hlc.counterMax, 'a');
      final t1 = t0.tick('a', wallMs: 5000);
      expect(t1.compareTo(t0), greaterThan(0));
      expect(t1.counter, 0);
      expect(t1.physicalMs, 5001);
    });
  });

  group('Hlc · merge（收到远端后推进）', () {
    test('★ 推进后一定大于双方', () {
      const local = Hlc(5000, 3, 'phone');
      const remote = Hlc(4000, 9, 'server');

      final merged = local.merge(remote, 'phone', wallMs: 4500);
      expect(merged.compareTo(local), greaterThan(0));
      expect(merged.compareTo(remote), greaterThan(0));
    });

    test('远端物理时间更大时以远端为基准', () {
      const local = Hlc(1000, 3, 'phone');
      const remote = Hlc(9000, 4, 'server');

      final merged = local.merge(remote, 'phone', wallMs: 1500);
      expect(merged.physicalMs, 9000);
      expect(merged.counter, 5);
    });

    test('本机时间超前于双方时采用本机时间', () {
      const local = Hlc(1000, 0, 'phone');
      const remote = Hlc(1100, 0, 'server');

      final merged = local.merge(remote, 'phone', wallMs: 9000);
      expect(merged.physicalMs, 9000);
      expect(merged.counter, 0);
    });
  });

  group('Hlc · 回拨检测与工具', () {
    test('isClockRollback', () {
      const t = Hlc(9000, 0, 'a');
      expect(Hlc.isClockRollback(t, 8000), isTrue);
      expect(Hlc.isClockRollback(t, 9000), isFalse);
      expect(Hlc.isClockRollback(t, 9500), isFalse);
    });

    test('physicalGap', () {
      const a = Hlc(9000, 0, 'a');
      const b = Hlc(8000, 0, 'b');
      expect(a.physicalGap(b).inMilliseconds, 1000);
      expect(b.physicalGap(a).inMilliseconds, -1000);
    });

    test('now 使用传入的墙钟（便于测试）', () {
      final t = Hlc.now('a', wallMs: 12345);
      expect(t.physicalMs, 12345);
      expect(t.counter, 0);
    });
  });
}
