import 'package:test/test.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// 数据模型规格的测试。
///
/// 这里**不连数据库**——DDL 能不能真跑由服务端的集成测试负责。
/// 这里管的是「规格本身有没有自相矛盾」，那些错误一旦漏到大半夜的同步里，
/// 表现是「某列不存在」，而根因在两周前的某次改动。
void main() {
  group('五列铁律', () {
    test('每个业务表都以统一五列开头', () {
      const five = ['id', 'updated_at', 'updated_by', 'rev', 'deleted_at'];
      for (final t in kTables.where((t) => t.isSynced)) {
        expect(
          t.columnNames.take(5).toList(),
          five,
          reason: '${t.name} 的前五列必须是 $five',
        );
      }
    });

    test('updated_at / deleted_at 必须是 TEXT', () {
      for (final t in kTables.where((t) => t.isSynced)) {
        expect(t.column('updated_at')!.type, 'TEXT', reason: '${t.name}.updated_at');
        expect(t.column('deleted_at')!.type, 'TEXT', reason: '${t.name}.deleted_at');
      }
    });

    test('id 是主键；deleted_at 可为空（NULL = 活着）；updated_at 非空', () {
      for (final t in kTables.where((t) => t.isSynced)) {
        expect(t.column('id')!.primaryKey, isTrue, reason: '${t.name}.id');
        expect(t.column('deleted_at')!.notNull, isFalse, reason: '${t.name}.deleted_at');
        expect(t.column('updated_at')!.notNull, isTrue, reason: '${t.name}.updated_at');
        expect(t.column('rev')!.defaultSql, '1', reason: '${t.name}.rev');
      }
    });
  });

  group('表结构自洽', () {
    test('表名不重复', () {
      final names = kTables.map((t) => t.name).toList();
      expect(names.toSet().length, names.length, reason: '有重名表：$names');
    });

    test('同一张表里列名不重复', () {
      for (final t in kTables) {
        final cols = t.columnNames;
        expect(cols.toSet().length, cols.length, reason: '${t.name} 有重名列：$cols');
      }
    });

    test('生成的 DDL 不出现 `,)` 这种多余逗号', () {
      // 手写 DDL 最容易犯的错；这里在不需要数据库的前提下把它挡住
      for (final t in kTables) {
        final sql = t.createSql();
        expect(sql, isNot(matches(RegExp(r',\s*\)'))), reason: '${t.name} 的 DDL 有尾逗号');
        expect(sql, contains('CREATE TABLE IF NOT EXISTS ${t.name}'));
      }
    });

    test('带注释的列不会把注释吞掉最后一列的逗号处理搞乱', () {
      // recipe 最后一列有注释（cover_sha256），专门挑这类表验证
      final t = kTables.firstWhere((x) => x.name == 'recipe');
      final sql = t.createSql();
      expect(sql.trimRight().endsWith(');'), isTrue);
      expect(sql, contains('cover_sha256 TEXT'));
    });

    test('表和列都不要用 SQLite 关键字（踩过：conflict / cursor）', () {
      for (final t in kTables) {
        expect(kSqliteKeywords.contains(t.name.toLowerCase()), isFalse,
            reason: '表名 ${t.name} 是 SQLite 关键字');
        for (final c in t.columnNames) {
          expect(kSqliteKeywords.contains(c.toLowerCase()), isFalse,
              reason: '${t.name}.$c 是 SQLite 关键字');
        }
      }
    });
  });

  group('同步边界（结构上做不到，而不是靠人记住）', () {
    test('白名单里的表全部是业务表', () {
      final synced = kTables.where((t) => t.isSynced).map((t) => t.name).toSet();
      expect(syncWhitelist.keys.toSet(), synced);
    });

    test('★ ai_* 三张表不可能出现在同步白名单里', () {
      for (final t in ['ai_config', 'ai_usage', 'ai_cache']) {
        expect(syncWhitelist.containsKey(t), isFalse, reason: '$t 竟然能被同步');
        expect(localOnlyTables, contains(t));
      }
      // API Key 所在的这张表，连列名都不该出现在任何同步相关的地方
      expect(syncWhitelist.values.expand((c) => c).contains('api_key_enc'), isFalse);
    });

    test('服务端基础设施也不参与同步', () {
      for (final t in ['change_log', 'device', 'pair_code', 'meta']) {
        expect(syncWhitelist.containsKey(t), isFalse, reason: '$t 不该被同步');
      }
    });

    test('★ 本机偏好表 local_pref 永不参与同步（收藏是偏好吗？是。同步吗？不同步）', () {
      expect(syncWhitelist.containsKey('local_pref'), isFalse,
          reason: 'local_pref 是本机偏好，不该出现在同步白名单里');
      expect(localOnlyTables, contains('local_pref'));
    });

    test('三类 scope 加起来覆盖所有表（没有表漏分类）', () {
      final byScope = <TableScope, int>{};
      for (final t in kTables) {
        byScope[t.scope] = (byScope[t.scope] ?? 0) + 1;
      }
      expect(byScope.values.reduce((a, b) => a + b), kTables.length);
      for (final s in TableScope.values) {
        expect(byScope[s], isNotNull, reason: 'scope $s 一张表都没有');
      }
    });
  });

  group('变更日志', () {
    test('★ seq 必须是 INTEGER PRIMARY KEY AUTOINCREMENT', () {
      final cl = kTables.firstWhere((t) => t.name == 'change_log');
      final seq = cl.column('seq')!;

      expect(seq.type, 'INTEGER');
      expect(seq.primaryKey, isTrue);
      expect(seq.autoIncrement, isTrue,
          reason: '没有 AUTOINCREMENT，删掉最大的行后 seq 会被复用，'
              '游标正好停在那个号的客户端会永久漏掉一条变更');
      expect(cl.createSql(), contains('AUTOINCREMENT'));
    });

    test('change_log 不参与同步', () {
      expect(kTables.firstWhere((t) => t.name == 'change_log').isSynced, isFalse);
    });

    test('记录了行自己的 HLC 与写入者（排障与冲突箱要用）', () {
      final cl = kTables.firstWhere((t) => t.name == 'change_log');
      expect(cl.columnNames, containsAll(['row_updated_at', 'row_updated_by', 'logged_at']));
    });
  });

  group('落库顺序与索引', () {
    test('所有业务表都在 applyOrder 里', () {
      final synced = kTables.where((t) => t.isSynced).map((t) => t.name).toSet();
      expect(applyOrder.toSet().containsAll(synced), isTrue,
          reason: '漏了：${synced.difference(applyOrder.toSet())}');
    });

    test('★ applyOrder 里父表在子表之前（外键才不会挡）', () {
      for (final t in kTables) {
        for (final c in t.constraints) {
          final m = RegExp(r'REFERENCES\s+(\w+)').firstMatch(c);
          if (m == null) continue;
          final parent = m.group(1)!;
          if (!applyOrder.contains(parent) || !applyOrder.contains(t.name)) continue;
          expect(applyOrder.indexOf(parent), lessThan(applyOrder.indexOf(t.name)),
              reason: '${t.name} 引用了 $parent，但写入顺序里它在父表前面');
        }
      }
    });

    test('每个业务表都有 updated_at 与 deleted_at 的索引', () {
      final ddl = schemaDdl().join('\n');
      for (final t in kTables.where((t) => t.isSynced)) {
        expect(ddl, contains('idx_${t.name}_updated'), reason: '${t.name} 缺 updated 索引');
        expect(ddl, contains('idx_${t.name}_alive'), reason: '${t.name} 缺 alive 索引');
      }
    });

    test('每张表都有建表语句，且 DDL 可重复执行（IF NOT EXISTS）', () {
      final ddl = schemaDdl();
      for (final t in kTables) {
        expect(ddl.where((s) => s.contains('CREATE TABLE') && s.contains(' ${t.name} (')),
            isNotEmpty, reason: '${t.name} 没有建表语句');
      }
      expect(ddl.where((s) => s.startsWith('CREATE INDEX')).every((s) => s.contains('IF NOT EXISTS')),
          isTrue);
    });

    test('schema 版本是正整数（迁移要拿它比大小）', () {
      expect(kSchemaVersion, greaterThan(0));
    });
  });
}

/// SQLite 关键字。用错会被解析器拒绝，或者更糟——被当成别的东西。
const Set<String> kSqliteKeywords = {
  'abort', 'action', 'add', 'after', 'all', 'alter', 'always', 'analyze', 'and', 'as',
  'asc', 'attach', 'autoincrement', 'before', 'begin', 'between', 'by', 'cascade',
  'case', 'cast', 'check', 'collate', 'column', 'commit', 'conflict', 'constraint',
  'create', 'cross', 'current', 'cursor', 'database', 'default', 'deferrable',
  'deferred', 'delete', 'desc', 'detach', 'distinct', 'do', 'drop', 'each', 'else',
  'end', 'escape', 'except', 'exclude', 'exclusive', 'exists', 'explain', 'fail',
  'filter', 'first', 'following', 'for', 'foreign', 'from', 'full', 'generated',
  'glob', 'group', 'groups', 'having', 'if', 'ignore', 'immediate', 'in', 'index',
  'indexed', 'initially', 'inner', 'insert', 'instead', 'intersect', 'into', 'is',
  'isnull', 'join', 'key', 'last', 'left', 'like', 'limit', 'match', 'materialized',
  'natural', 'no', 'not', 'nothing', 'notnull', 'null', 'nulls', 'of', 'offset',
  'on', 'or', 'order', 'others', 'outer', 'over', 'partition', 'plan', 'pragma',
  'preceding', 'primary', 'query', 'raise', 'range', 'recursive', 'references',
  'regexp', 'reindex', 'release', 'rename', 'replace', 'restrict', 'returning',
  'right', 'rollback', 'row', 'rows', 'savepoint', 'select', 'set', 'table',
  'temp', 'temporary', 'then', 'ties', 'to', 'transaction', 'trigger', 'unbounded',
  'union', 'unique', 'update', 'using', 'vacuum', 'values', 'view', 'virtual',
  'when', 'where', 'window', 'with', 'without',
};
