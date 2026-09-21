import 'dart:io';

import 'package:test/test.dart';
import 'package:zaoji_server/src/db.dart';
import 'package:zaoji_server/src/sqlite_loader.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// 数据库层测试。
///
/// 全部用**真实的临时文件库**，不用内存库——WAL、外键、AUTOINCREMENT 这些
/// 恰恰是内存库上行为不同或测不出来的地方，而它们正是同步正确性的地基。
void main() {
  setUpAll(loadSqlite);

  late Directory tmp;
  late String dbPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zaoji_db');
    dbPath = '${tmp.path}${Platform.pathSeparator}zaoji.db';
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ZaojiDb openDb() {
    final d = ZaojiDb.open(dbPath);
    addTearDown(d.close);
    return d;
  }

  group('建库', () {
    test('所有表都建出来了，且 schema 版本写入 meta', () {
      final d = openDb();

      final tables = d.db
          .select("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
          .map((r) => r['name'] as String)
          .toSet();

      for (final t in kTables) {
        expect(tables, contains(t.name), reason: '缺表 ${t.name}');
      }
      expect(d.schemaVersionInDb, kSchemaVersion);
    });

    test('重复打开是幂等的，也不会报「表已存在」', () {
      // 第一次：建库（用 try 确保即使断言失败也会关上，否则文件句柄会拖住临时目录）
      final a = ZaojiDb.open(dbPath);
      expect(a.schemaVersionInDb, kSchemaVersion);
      a.close();

      // 第二次：对着已有库再走一遍，不应抛「table already exists」
      final b = ZaojiDb.open(dbPath);
      addTearDown(b.close);
      expect(b.schemaVersionInDb, kSchemaVersion);

      // 表也没被重复建：数一下 recipe 的出现次数（sqlite_master 里唯一）
      final n = b.db
          .select("SELECT COUNT(*) AS c FROM sqlite_master WHERE name = 'recipe'")
          .first['c'];
      expect(n, 1);
    });

    test('★ 库版本比程序新时拒绝打开（而不是静默降级丢数据）', () {
      final d = ZaojiDb.open(dbPath);
      d.db.execute("UPDATE meta SET v = '99' WHERE k = 'schema_version'");
      d.close();

      expect(() => ZaojiDb.open(dbPath), throwsA(isA<DatabaseException>()));
      try {
        ZaojiDb.open(dbPath);
      } on DatabaseException catch (e) {
        expect(e.message, contains('99'));
      }
    });

    test('★ R22 数据修形：旧库把 null 字符串化成 "null" 的冲突值被清成 NULL', () {
      final d = openDb();
      // 模拟旧 _openConflict 的产物（真库里就有一条 cover_sha256 撞了这个）
      d.db.execute(
        'INSERT INTO conflict_item (id, updated_at, updated_by, rev, tbl, row_id, '
        'field, local_value, remote_value, local_hlc, remote_hlc, local_by, remote_by) '
        "VALUES ('cf-x', 'h-1', 's', 1, 'recipe', 'r1', 'cover_sha256', "
        "'null', 'abc', 'h-1', 'h-1', 'a', 'b')",
      );
      d.close();

      final again = ZaojiDb.open(dbPath);
      addTearDown(again.close);
      final row = again.db.select(
          "SELECT local_value, remote_value FROM conflict_item WHERE id='cf-x'").single;
      expect(row['local_value'], isNull,
          reason: '裁决选它会把文本 "null" 写进哈希列——必须是真 NULL');
      expect(row['remote_value'], 'abc', reason: '正常值不能被误伤');
    });

    test('数据目录会被自动创建（部署时没人会记得先 mkdir）', () {
      final nested = '${tmp.path}${Platform.pathSeparator}a'
          '${Platform.pathSeparator}b${Platform.pathSeparator}zaoji.db';
      final d = ZaojiDb.open(nested);
      addTearDown(d.close);
      expect(File(nested).existsSync(), isTrue);
    });
  });

  group('PRAGMA', () {
    test('WAL 已启用（读不挡写：做菜页轮询与同步并存）', () {
      final d = openDb();
      final mode = d.db.select('PRAGMA journal_mode').first.values.first;
      expect('$mode'.toLowerCase(), 'wal');
    });

    test('★ 外键是打开的（SQLite 默认关闭，不显式开等于没写）', () {
      final d = openDb();
      expect(d.db.select('PRAGMA foreign_keys').first.values.first, 1);
    });

    test('busy_timeout 与 synchronous 已设置', () {
      final d = openDb();
      expect(d.db.select('PRAGMA busy_timeout').first.values.first, 5000);
      final sync = d.db.select('PRAGMA synchronous').first.values.first;
      expect(sync, 1, reason: '1 = NORMAL，WAL 下的推荐值');
    });

    test('外键真的会挡住孤儿行（不是只设了开关）', () {
      final d = openDb();
      final stmt = d.db.prepare(
        'INSERT INTO ingredient (id, updated_at, updated_by, recipe_id, name) '
        'VALUES (?, ?, ?, ?, ?)',
      );
      addTearDown(stmt.dispose);
      expect(
        () => stmt.execute(['i1', 'h', 'dev', '不存在的菜谱', '番茄']),
        throwsA(anything),
      );
    });
  });

  group('change_log 与游标', () {
    test('★ seq 单调递增', () {
      final d = openDb();
      final seqs = [
        for (var i = 0; i < 5; i++)
          d.logChange(
            tbl: 'recipe',
            rowId: 'r$i',
            op: 'upsert',
            rowUpdatedAt: '0000000000001-0000-dev',
            rowUpdatedBy: 'dev',
          ),
      ];
      expect(seqs, [1, 2, 3, 4, 5]);
      expect(d.maxSeq, 5);
    });

    test('★★ 删掉最大行后，seq 不会被复用', () {
      // 这条是整条同步链路的命门：
      // 如果没有 AUTOINCREMENT，SQLite 会复用 rowid，
      // 于是客户端游标停在 3 的设备会**永远看不到**新写入的第 4 条。
      final d = openDb();
      for (var i = 0; i < 3; i++) {
        d.logChange(
          tbl: 'recipe', rowId: 'r$i', op: 'upsert',
          rowUpdatedAt: 'h', rowUpdatedBy: 'dev',
        );
      }
      final cursor = d.maxSeq; // 客户端同步到这里
      expect(cursor, 3);

      d.db.execute('DELETE FROM change_log WHERE seq = 3'); // 清理最老的变更

      final next = d.logChange(
        tbl: 'recipe', rowId: 'r-new', op: 'upsert',
        rowUpdatedAt: 'h', rowUpdatedBy: 'dev',
      );
      expect(next, greaterThan(cursor),
          reason: '新变更的 seq 必须大于客户端游标，否则那条变更永远同步不过去');
    });

    test('按游标拉取：只拿 cursor 之后的，且能分页', () {
      final d = openDb();
      for (var i = 0; i < 7; i++) {
        d.logChange(
          tbl: 'recipe', rowId: 'r$i', op: 'upsert',
          rowUpdatedAt: 'h$i', rowUpdatedBy: 'dev',
        );
      }
      final first = d.changesSince(0, limit: 3);
      expect(first.map((e) => e.seq), [1, 2, 3]);

      final second = d.changesSince(first.last.seq, limit: 3);
      expect(second.map((e) => e.seq), [4, 5, 6]);

      expect(d.changesSince(d.maxSeq), isEmpty);
    });

    test('行数据带上了 HLC 与写入者（冲突箱与排障要用）', () {
      final d = openDb();
      d.logChange(
        tbl: 'step', rowId: 's1', op: 'delete',
        rowUpdatedAt: '0000000000abc-0001-phone', rowUpdatedBy: 'phone',
      );
      final e = d.changesSince(0).single;
      expect(e.tbl, 'step');
      expect(e.rowId, 's1');
      expect(e.op, 'delete');
      expect(e.rowUpdatedBy, 'phone');
      expect(e.loggedAt, isNotEmpty);
      expect(e.toJson()['updatedAt'], '0000000000abc-0001-phone');
    });

    test('空库时 maxSeq 是 0 而不是 null', () {
      expect(openDb().maxSeq, 0);
    });
  });

  group('同步边界（用真实库验证，不只是测规格）', () {
    test('★ ai_* 表在库里存在，但不在同步白名单里', () {
      final d = openDb();
      final tables = d.db
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((r) => r['name'] as String)
          .toSet();

      // 表存在——本机确实要存 Key 与缓存
      for (final t in localOnlyTables) {
        expect(tables, contains(t), reason: '$t 应该存在（本机要用）');
        // 但同步接口永远看不到它
        expect(syncWhitelist.containsKey(t), isFalse, reason: '$t 不能出现在同步白名单');
      }
      expect(localOnlyTables, containsAll(['ai_config', 'ai_usage', 'ai_cache']));
    });

    test('白名单里的每一张表都真的有对应的库表', () {
      final d = openDb();
      final tables = d.db
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((r) => r['name'] as String)
          .toSet();
      for (final t in syncWhitelist.keys) {
        expect(tables, contains(t), reason: '白名单里有 $t，但库里没有这张表');
      }
    });

    test('白名单里的每一列都真的存在于那张表', () {
      final d = openDb();
      for (final entry in syncWhitelist.entries) {
        final actual = d.db
            .select('PRAGMA table_info(${entry.key})')
            .map((r) => r['name'] as String)
            .toSet();
        for (final col in entry.value) {
          expect(actual, contains(col), reason: '${entry.key}.$col 在白名单里但库里没有');
        }
      }
    });

    test('rowCounts 覆盖所有业务表且初始为 0', () {
      final d = openDb();
      final counts = d.rowCounts();
      expect(counts.keys.toSet(), syncWhitelist.keys.toSet());
      expect(counts.values.every((v) => v == 0), isTrue);
    });
  });

  group('health', () {
    test('报告 SQLite 版本、schema 版本、文件大小与变更序号', () {
      final d = openDb();
      d.logChange(
        tbl: 'recipe', rowId: 'r1', op: 'upsert',
        rowUpdatedAt: 'h', rowUpdatedBy: 'dev',
      );

      final h = d.healthPayload();
      expect(h['sqliteVersion'], isNotNull);
      expect(h['schemaVersion'], kSchemaVersion);
      expect(h['schemaVersionInDb'], kSchemaVersion);
      expect(h['maxSeq'], 1);
      expect(h['sizeBytes'], isA<int>());
      expect((h['rowCounts'] as Map).length, syncWhitelist.length);
    });
  });
}
