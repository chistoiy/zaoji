import 'dart:math';

import 'package:test/test.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

void main() {
  group('Ulid · 格式', () {
    test('长度为 26 且字符合法', () {
      final id = Ulid.generate();
      expect(id.length, ulidLength);
      expect(id.length, 26);
      expect(Ulid.isValid(id), isTrue);
    });

    test('不含易混字符 I / L / O / U', () {
      // Crockford Base32 去掉这四个字的用意就是「能被人读出来、抄下来」
      for (var i = 0; i < 200; i++) {
        final id = Ulid.generate();
        for (final bad in ['I', 'L', 'O', 'U']) {
          expect(id.contains(bad), isFalse, reason: '$id 含易混字符 $bad');
        }
      }
    });

    test('小写非法（要求大写，避免两端大小写不一致）', () {
      expect(Ulid.isValid('01arz3ndektsv4rrffq69g5fav'), isFalse);
    });

    test('长度不对就非法', () {
      expect(Ulid.isValid(''), isFalse);
      expect(Ulid.isValid('01ARZ3NDEKTSV4RRFFQ69G5FA'), isFalse); // 25 位
      expect(Ulid.isValid('01ARZ3NDEKTSV4RRFFQ69G5FAV0'), isFalse); // 27 位
    });
  });

  group('Ulid · ★ 字典序 == 时间序', () {
    test('晚生成的一定排在后面', () {
      final early = Ulid.generate(at: DateTime.fromMillisecondsSinceEpoch(1000000));
      final late = Ulid.generate(at: DateTime.fromMillisecondsSinceEpoch(2000000));
      expect(early.compareTo(late), lessThan(0));
      expect(Ulid.compare(early, late), lessThan(0));
    });

    test('批量生成的排序与创建时间排序一致', () {
      // 这条不成立的话，用 ULID 当主键就没有意义了
      final pairs = <MapEntry<int, String>>[];
      for (var i = 0; i < 60; i++) {
        final ms = 1700000000000 + i * 137;
        pairs.add(MapEntry(ms, Ulid.generate(at: DateTime.fromMillisecondsSinceEpoch(ms))));
      }
      // 打乱后按 id 排序
      final shuffled = [...pairs]..shuffle(Random(7));
      final byId = [...shuffled]..sort((a, b) => a.value.compareTo(b.value));
      final byTime = [...shuffled]..sort((a, b) => a.key.compareTo(b.key));
      expect(
        byId.map((e) => e.key).toList(),
        byTime.map((e) => e.key).toList(),
      );
    });
  });

  group('Ulid · 时间戳可还原', () {
    test('往返一致', () {
      final at = DateTime.fromMillisecondsSinceEpoch(1790000000123);
      final id = Ulid.generate(at: at);
      final back = Ulid.timestampOf(id);
      expect(back, isNotNull);
      expect(back!.millisecondsSinceEpoch, at.millisecondsSinceEpoch);
    });

    test('非法输入返回 null 而不是抛异常', () {
      expect(Ulid.timestampOf('not-a-ulid'), isNull);
      expect(Ulid.timestampOf(''), isNull);
    });
  });

  group('Ulid · 唯一性', () {
    test('一万个不重复', () {
      final seen = <String>{};
      for (var i = 0; i < 10000; i++) {
        seen.add(Ulid.generate());
      }
      expect(seen.length, 10000);
    });

    test('同一毫秒内也不重复', () {
      final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final seen = <String>{};
      for (var i = 0; i < 500; i++) {
        seen.add(Ulid.generate(at: at));
      }
      expect(seen.length, 500);
    });
  });

  group('UlidFactory · 单调生成', () {
    test('同一毫秒内严格递增', () {
      // 批量导入 50 道菜时，如果同毫秒内的顺序是随机的，
      // 「按 id 排序」就会得到一个打乱的列表。
      final f = UlidFactory(random: Random(42));
      final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      var prev = '';
      for (var i = 0; i < 50; i++) {
        final id = f.next(at: at);
        expect(Ulid.isValid(id), isTrue);
        expect(id.compareTo(prev), greaterThan(0), reason: '第 $i 个 $id 没有大于 $prev');
        prev = id;
      }
    });

    test('跨毫秒也递增', () {
      final f = UlidFactory(random: Random(1));
      final a = f.next(at: DateTime.fromMillisecondsSinceEpoch(1700000000000));
      final b = f.next(at: DateTime.fromMillisecondsSinceEpoch(1700000000001));
      expect(b.compareTo(a), greaterThan(0));
    });

    test('时钟回拨时不回退', () {
      final f = UlidFactory(random: Random(2));
      final a = f.next(at: DateTime.fromMillisecondsSinceEpoch(1700000005000));
      // 用户把系统时间调回去了
      final b = f.next(at: DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(b.compareTo(a), greaterThan(0), reason: '与 HLC 同样的原则：只前进，不后退');
    });

    test('全部合法且不重复', () {
      final f = UlidFactory(random: Random(3));
      final ids = <String>{};
      for (var i = 0; i < 300; i++) {
        final id = f.next();
        expect(Ulid.isValid(id), isTrue);
        ids.add(id);
      }
      expect(ids.length, 300);
    });
  });
}
