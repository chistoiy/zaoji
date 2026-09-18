import 'package:test/test.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

String _h(int ms, int counter, [String node = 'dev1']) =>
    Hlc(ms, counter, node).encode();

RecordSnapshot _snap(
  Map<String, Object?> fields, {
  String? hlc,
  int rev = 1,
  String by = 'A',
  String id = 'r1',
}) =>
    RecordSnapshot(
      id: id,
      hlc: hlc ?? _h(1000, 0),
      rev: rev,
      updatedBy: by,
      fields: fields,
    );

void main() {
  group('resolveConflict · 基本判定', () {
    test('HLC 相同 → 无变化', () {
      final r = resolveConflict(
        local: _snap({'name': '番茄炒蛋'}, hlc: _h(1000, 0)),
        remote: _snap({'name': '番茄炒蛋'}, hlc: _h(1000, 0)),
      );
      expect(r.kind, ConflictKind.identical);
      expect(r.needsUserDecision, isFalse);
    });

    test('只有本地改过 → 取本地', () {
      final r = resolveConflict(
        base: _snap({'time': 10, 'note': 'x'}, hlc: _h(1000, 0)),
        local: _snap({'time': 15, 'note': 'x'}, hlc: _h(2000, 0)),
        remote: _snap({'time': 10, 'note': 'x'}, hlc: _h(1500, 0)),
      );
      expect(r.kind, ConflictKind.takeLocal);
      expect(r.fields!['time'], 15);
    });

    test('只有远端改过 → 取远端', () {
      final r = resolveConflict(
        base: _snap({'time': 10}, hlc: _h(1000, 0)),
        local: _snap({'time': 10}, hlc: _h(1500, 0)),
        remote: _snap({'time': 20}, hlc: _h(2000, 0)),
      );
      expect(r.kind, ConflictKind.takeRemote);
      expect(r.fields!['time'], 20);
    });
  });

  group('resolveConflict · 字段级自动合并（不打扰用户）', () {
    test('☆ 改的是不同字段 → 自动合并，两边改动都保留', () {
      final r = resolveConflict(
        base: _snap({'name': '番茄炒蛋', 'time': 10, 'steps': ['a']}, hlc: _h(1000, 0)),
        // 本地改了耗时
        local: _snap({'name': '番茄炒蛋', 'time': 15, 'steps': ['a']}, hlc: _h(2000, 0)),
        // 远端加了步骤
        remote: _snap({'name': '番茄炒蛋', 'time': 10, 'steps': ['a', 'b']}, hlc: _h(2500, 0)),
      );
      expect(r.kind, ConflictKind.autoMerged);
      expect(r.needsUserDecision, isFalse);
      expect(r.fields!['time'], 15);
      expect(r.fields!['steps'], ['a', 'b']);
    });

    test('☆ 两边改成了同一个值 → 不算冲突', () {
      final r = resolveConflict(
        base: _snap({'time': 10}, hlc: _h(1000, 0)),
        local: _snap({'time': 15}, hlc: _h(2000, 0)),
        remote: _snap({'time': 15}, hlc: _h(2500, 0)),
      );
      expect(r.kind, ConflictKind.autoMerged);
      expect(r.conflictingFields, isEmpty);
      expect(r.fields!['time'], 15);
    });
  });

  group('resolveConflict · 真冲突', () {
    test('☆ 同一字段不同值 → 进冲突箱', () {
      final r = resolveConflict(
        base: _snap({'time': 10}, hlc: _h(1000, 0)),
        local: _snap({'time': 15}, hlc: _h(2000, 0)),
        remote: _snap({'time': 20}, hlc: _h(2500, 0)),
      );
      expect(r.kind, ConflictKind.manual);
      expect(r.needsUserDecision, isTrue);
      expect(r.conflictingFields, ['time']);
    });

    test('☆ 冲突时其余字段也要落库，不能一起搁置', () {
      final r = resolveConflict(
        base: _snap({'time': 10, 'note': 'x'}, hlc: _h(1000, 0)),
        local: _snap({'time': 15, 'note': 'x'}, hlc: _h(2000, 0)),
        remote: _snap({'time': 20, 'note': 'y'}, hlc: _h(2500, 0)),
      );
      expect(r.kind, ConflictKind.manual);
      expect(r.conflictingFields, ['time']);
      // note 的修改没有争议，必须保留——否则用户「改了个备注结果没了」
      expect(r.fields!['note'], 'y');
      // 有争议的字段先填较新一方，等用户裁决
      expect(r.fields!['time'], 20);
    });

    test('建议优先展示较新的一方', () {
      final newer = resolveConflict(
        base: _snap({'time': 10}, hlc: _h(1000, 0)),
        local: _snap({'time': 15}, hlc: _h(2000, 0)),
        remote: _snap({'time': 20}, hlc: _h(2500, 0)),
      );
      expect(newer.preferredSide, 'remote');

      final older = resolveConflict(
        base: _snap({'time': 10}, hlc: _h(1000, 0)),
        local: _snap({'time': 15}, hlc: _h(9000, 0)),
        remote: _snap({'time': 20}, hlc: _h(2500, 0)),
      );
      expect(older.preferredSide, 'local');
    });

    test('多字段冲突全部列出且有序', () {
      final r = resolveConflict(
        base: _snap({'a': 1, 'b': 2, 'c': 3}, hlc: _h(1000, 0)),
        local: _snap({'a': 10, 'b': 20, 'c': 3}, hlc: _h(2000, 0)),
        remote: _snap({'a': 11, 'b': 21, 'c': 3}, hlc: _h(2500, 0)),
      );
      expect(r.conflictingFields, ['a', 'b']);
    });
  });

  group('resolveConflict · 深比较与边界', () {
    test('嵌套结构用值比较，不用引用比较', () {
      final r = resolveConflict(
        base: _snap({'steps': [{'t': 'a'}, {'t': 'b'}]}, hlc: _h(1000, 0)),
        local: _snap({'steps': [{'t': 'a'}, {'t': 'b'}]}, hlc: _h(1500, 0)),
        remote: _snap({'steps': [{'t': 'a'}, {'t': 'c'}]}, hlc: _h(2000, 0)),
      );
      expect(r.kind, ConflictKind.takeRemote);
      expect(r.fields!['steps'], [{'t': 'a'}, {'t': 'c'}]);
    });

    test('Map 键序不同不算差异（深比较走规范化 JSON）', () {
      final r = resolveConflict(
        base: _snap({
          'x': {'p': 1, 'q': 2}
        }, hlc: _h(1000, 0)),
        // 内容与 base 完全相同，只是键序不同 → local 应被判为「没改过」
        local: _snap({
          'x': {'q': 2, 'p': 1}
        }, hlc: _h(1500, 0)),
        remote: _snap({
          'x': {'p': 1, 'q': 2},
          'kcal': 186,
        }, hlc: _h(2000, 0)),
      );
      expect(r.kind, ConflictKind.takeRemote,
          reason: '键序不同不算差异时，local 就是未修改，应直接采用 remote');
      expect(r.fields!['kcal'], 186);
    });

    test('字段被置空也算一次真实修改', () {
      final r = resolveConflict(
        base: _snap({'cover': 'a.jpg'}, hlc: _h(1000, 0)),
        local: _snap({'cover': null}, hlc: _h(2000, 0)),
        remote: _snap({'cover': 'a.jpg'}, hlc: _h(1500, 0)),
      );
      expect(r.kind, ConflictKind.takeLocal);
      expect(r.fields!.containsKey('cover'), isTrue);
      expect(r.fields!['cover'], isNull);
    });

    test('新增字段被识别为修改', () {
      final r = resolveConflict(
        base: _snap({'name': 'x'}, hlc: _h(1000, 0)),
        local: _snap({'name': 'x', 'kcal': 186}, hlc: _h(2000, 0)),
        remote: _snap({'name': 'x'}, hlc: _h(1500, 0)),
      );
      expect(r.kind, ConflictKind.takeLocal);
      expect(r.fields!['kcal'], 186);
    });

    test('没有基线时保守判定为需要人工裁决', () {
      final r = resolveConflict(
        local: _snap({'time': 15}, hlc: _h(2000, 0)),
        remote: _snap({'time': 20}, hlc: _h(2500, 0)),
      );
      expect(r.kind, ConflictKind.manual);
      expect(r.conflictingFields, ['time']);
    });

    test('没有基线但两边值一致 → 无需裁决', () {
      final r = resolveConflict(
        local: _snap({'time': 15}, hlc: _h(2000, 0)),
        remote: _snap({'time': 15}, hlc: _h(2500, 0)),
      );
      // 没有基线时无法判断谁改过，但两边值一样，取谁都无害，不该打扰用户
      expect(r.kind, ConflictKind.takeLocal);
      expect(r.needsUserDecision, isFalse);
      expect(r.fields!['time'], 15);
    });
  });

  group('ConflictTicket', () {
    test('构造出可落库的冲突条目', () {
      final base = _snap({'time': 10}, hlc: _h(1000, 0), rev: 3);
      final local = _snap({'time': 15}, hlc: _h(2000, 0), rev: 4, by: 'phone');
      final remote = _snap({'time': 20}, hlc: _h(2500, 0), rev: 4, by: 'server');

      final resolution = resolveConflict(base: base, local: local, remote: remote);
      final ticket = ConflictTicket.from(
        table: 'recipe',
        local: local,
        remote: remote,
        base: base,
        resolution: resolution,
        detectedAt: '2026-09-17T22:00:00Z',
      );

      expect(ticket.table, 'recipe');
      expect(ticket.recordId, 'r1');
      expect(ticket.conflictingFields, ['time']);

      final json = ticket.toJson();
      expect(json['table'], 'recipe');
      expect((json['local']! as Map)['updatedBy'], 'phone');
      expect((json['remote']! as Map)['updatedBy'], 'server');
      expect(json['base'], isNotNull);
    });
  });
}
