import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:zaoji_server/src/sqlite_loader.dart';

/// SQLite 动态库的解析与能力验证。
///
/// 为什么值得单独测：SQLite 是本项目唯一一个**不随代码走**的运行时依赖
/// （Windows 上来自系统自带的 `winsqlite3.dll`），
/// 「这台机器上到底能不能用、能不能用我们依赖的那几个语法」必须在启动前问清楚。
void main() {
  setUp(resetSqliteLoaderForTesting);

  group('解析', () {
    test('默认解析能拿到库，且版本满足最低要求', () {
      final info = loadSqlite();

      expect(info.version, isNotEmpty);
      expect(
        compareVersions(info.version, SqliteLibraryInfo.minimumVersion),
        greaterThanOrEqualTo(0),
        reason: '需要 >= ${SqliteLibraryInfo.minimumVersion}，实际 ${info.version}',
      );
      expect(info.isForced, isFalse);
      expect(info.summary, contains(info.version));
    });

    test('解析结果会被缓存（库只加载一次）', () {
      final a = loadSqlite();
      final b = loadSqlite();
      expect(identical(a, b), isTrue);
    });

    test('显式指定一个不存在的路径 → 直接抛错，不静默回落', () {
      // 这条是刻意的设计选择：用户既然显式指定，就有权知道它没生效。
      // 偷偷换成别的库，比直接报错更糟。
      expect(
        () => loadSqlite(explicitPath: r'C:\definitely\not\here\sqlite3.dll'),
        throwsA(isA<SqliteLoadException>()),
      );
    });

    test('抛错信息里要带上试过的路径（不能让人对着空指针猜）', () {
      try {
        loadSqlite(explicitPath: r'C:\definitely\not\here\sqlite3.dll');
        fail('应当抛错');
      } on SqliteLoadException catch (e) {
        expect(e.message, contains('definitely'));
        expect(e.toString(), contains('SqliteLoadException'));
      }
    });

    test('版本比较：缺省段按 0 处理', () {
      expect(compareVersions('3.24', '3.24.0'), 0);
      expect(compareVersions('3.24.1', '3.24.0'), 1);
      expect(compareVersions('3.9.0', '3.24.0'), -1);
      expect(compareVersions('3.51.1', '3.24.0'), 1);
      expect(compareVersions('4.0.0', '3.99.9'), 1);
    });
  });

  group('SQLite 能力（这些语法同步层要真的用）', () {
    late Database db;

    setUpAll(loadSqlite);

    setUp(() => db = sqlite3.openInMemory());
    tearDown(() => db.dispose());

    test('建表 / 带参数插入 / 查询 / rowid', () {
      db.execute('''
        CREATE TABLE t (
          id TEXT PRIMARY KEY,
          n  TEXT NOT NULL,
          rev INTEGER NOT NULL DEFAULT 1
        )
      ''');
      final stmt = db.prepare('INSERT INTO t (id, n) VALUES (?, ?)');
      stmt.execute(['a', '番茄']);
      stmt.execute(['b', '鸡蛋']);
      stmt.dispose();

      expect(db.select('SELECT COUNT(*) AS c FROM t').first['c'], 2);
      expect(db.select('SELECT n FROM t WHERE id = ?', ['a']).first['n'], '番茄');
      expect(db.lastInsertRowId, greaterThan(0));
    });

    test('★ UPSERT —— 同步的幂等写入靠它（需要 >= 3.24）', () {
      db.execute('CREATE TABLE t (id TEXT PRIMARY KEY, n TEXT, rev INTEGER)');
      db.execute("INSERT INTO t (id, n, rev) VALUES ('a', '旧', 1)");

      // 同一个 mutationId 重放时必须等价，而不是插出第二行
      final stmt = db.prepare('''
        INSERT INTO t (id, n, rev) VALUES (?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET n = excluded.n, rev = excluded.rev
      ''');
      stmt.execute(['a', '新', 2]);
      stmt.execute(['a', '新', 2]);
      stmt.dispose();

      final rows = db.select('SELECT id, n, rev FROM t');
      expect(rows, hasLength(1), reason: 'UPSERT 不能插出第二行');
      expect(rows.first['n'], '新');
      expect(rows.first['rev'], 2);
    });

    test('事务回滚后数据不留痕（同步一批要么全成要么全不成）', () {
      db.execute('CREATE TABLE t (id TEXT PRIMARY KEY)');
      try {
        db.execute('BEGIN');
        db.execute("INSERT INTO t (id) VALUES ('a')");
        db.execute("INSERT INTO t (id) VALUES ('a')"); // 主键冲突
        db.execute('COMMIT');
        fail('应当抛冲突');
      } catch (_) {
        db.execute('ROLLBACK');
      }
      expect(db.select('SELECT COUNT(*) AS c FROM t').first['c'], 0);
    });

    test('WAL 模式（本地文件库才支持）', () {
      final dir = Directory.systemTemp.createTempSync('zaoji_wal');
      addTearDown(() => dir.deleteSync(recursive: true));

      final fdb = sqlite3.open('${dir.path}${Platform.pathSeparator}t.db');
      addTearDown(fdb.dispose);

      final mode = fdb.select('PRAGMA journal_mode=WAL').first.values.first;
      expect('$mode'.toLowerCase(), 'wal');
    });

    test('外键约束可打开且真的生效', () {
      db.execute('PRAGMA foreign_keys = ON');
      expect(db.select('PRAGMA foreign_keys').first.values.first, 1);

      db.execute('''
        CREATE TABLE parent (id TEXT PRIMARY KEY);
        CREATE TABLE child (
          id TEXT PRIMARY KEY,
          pid TEXT NOT NULL REFERENCES parent(id) ON DELETE CASCADE
        );
      ''');
      expect(
        () => db.execute("INSERT INTO child (id, pid) VALUES ('c1', '不存在')"),
        throwsA(isA<SqliteException>()),
      );
    });

    test('索引与部分索引都支持（change_log 清理要靠它）', () {
      db.execute('CREATE TABLE cl (seq INTEGER PRIMARY KEY, tbl TEXT)');
      db.execute('CREATE INDEX idx_cl_tbl ON cl(tbl, seq)');
      db.execute('CREATE INDEX idx_cl_recent ON cl(seq) WHERE seq > 0');
      final names = db
          .select("SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name")
          .map((r) => r['name'])
          .toList();
      expect(names, containsAll(['idx_cl_tbl', 'idx_cl_recent']));
    });

    test('时间函数可用（按时间裁剪老数据要用）', () {
      final rs = db.select("SELECT strftime('%s', 'now') AS t, datetime('now') AS d");
      expect(int.parse('${rs.first['t']}'), greaterThan(0));
      expect('${rs.first['d']}', isNotEmpty);
    });

    test('布尔以外还有 NULL 排序与 COLLATE（同步游标比较要用）', () {
      db.execute('CREATE TABLE t (a TEXT COLLATE NOCASE, b INTEGER)');
      db.execute("INSERT INTO t VALUES ('Apple', NULL), ('banana', 2)");
      // NOCASE：'Apple' 能被 'apple' 找到
      expect(db.select("SELECT a FROM t WHERE a = 'apple'").length, 1);
      // NULLS LAST 需要 3.30+；这里只要求它不报语法错
      final rows = db.select('SELECT a FROM t ORDER BY b IS NULL, b');
      expect(rows.first['a'], 'banana');
    });
  });
}
