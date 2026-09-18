import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import 'sqlite_loader.dart';

/// 打不开数据库时抛这个。入口会把它变成一句人话，而不是一坨栈。
class DatabaseException implements Exception {
  final String message;
  const DatabaseException(this.message);

  @override
  String toString() => 'DatabaseException: $message';
}

/// 灶记的数据库。
///
/// 职责边界：**只负责「库本身」**——路径、PRAGMA、建表、迁移、变更日志。
/// 业务读写（菜谱、库存……）放在各自的仓储里，别都堆到这个文件。
///
/// 三个 PRAGMA 的选择理由：
///
/// | PRAGMA | 值 | 为什么 |
/// |---|---|---|
/// | `journal_mode` | WAL | 读不挡写。做菜页在轮询计时器的同时，另一端可能在同步 |
/// | `foreign_keys` | ON | 默认是**关**的，不显式打开外键约束等于没写 |
/// | `synchronous` | NORMAL | WAL 下的推荐值。掉电最多丢最后几个事务，不会坏库 |
/// | `busy_timeout` | 5000 | 家里那台笔记本同时被手机和平板连，撞锁时等一会而不是直接报错 |
class ZaojiDb {
  final Database db;

  /// 数据库文件路径；`:memory:` 表示内存库（测试用）。
  final String path;

  ZaojiDb._(this.db, this.path);

  /// 打开（必要时创建）数据库，并把 schema 落到最新版本。
  static ZaojiDb open(String path) {
    loadSqlite(); // 先确保动态库可用，失败信息比 FFI 原始错误好读得多

    final isMemory = path == ':memory:';
    if (!isMemory) {
      final parent = Directory(File(path).parent.path);
      if (!parent.existsSync()) {
        try {
          parent.createSync(recursive: true);
        } catch (e) {
          throw DatabaseException('数据目录建不出来：${parent.path}\n  $e');
        }
      }
    }

    final Database db;
    try {
      db = sqlite3.open(path);
    } catch (e) {
      throw DatabaseException('打开数据库失败：$path\n  $e');
    }

    final self = ZaojiDb._(db, path);
    try {
      self._applyPragmas(isMemory);
      self._migrate();
    } catch (_) {
      db.dispose();
      rethrow;
    }
    return self;
  }

  void _applyPragmas(bool isMemory) {
    if (!isMemory) {
      // 这行返回一行结果，必须用 select 而不是 execute
      final mode = db.select('PRAGMA journal_mode = WAL').first.values.first;
      if ('$mode'.toLowerCase() != 'wal') {
        // 网络盘 / 只读目录会落到 delete 模式。不是致命错误，但要让人知道。
        stderr.writeln('  ⚠️ 未能启用 WAL（当前 $mode），数据库可能放在网络盘或只读目录上');
      }
    }
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA synchronous = NORMAL');
    db.execute('PRAGMA busy_timeout = 5000');
  }

  /// 建表 + 版本检查。
  void _migrate() {
    final stored = schemaVersionInDb;

    if (stored != null && stored > kSchemaVersion) {
      // 用新版本程序写过的库，别用旧程序去碰——静默降级会丢数据
      throw DatabaseException(
        '数据库是更新的版本建的（库 $stored > 程序 $kSchemaVersion）。\n'
        '  说明你用了旧版服务端去开新版数据。请换回新版本，或换一个数据目录。',
      );
    }

    db.execute('BEGIN');
    try {
      for (final stmt in schemaDdl()) {
        db.execute(stmt);
      }
      db.execute(
        "INSERT INTO meta (k, v) VALUES ('schema_version', ?) "
        'ON CONFLICT(k) DO UPDATE SET v = excluded.v',
        ['$kSchemaVersion'],
      );
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 库里记录的 schema 版本；**全新的库返回 null**（那时连 meta 表都还没有）。
  int? get schemaVersionInDb {
    final hasMeta = db
        .select("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta'")
        .isNotEmpty;
    if (!hasMeta) return null;

    final rs = db.select("SELECT v FROM meta WHERE k = 'schema_version'");
    if (rs.isEmpty) return null;
    return int.tryParse('${rs.first['v']}');
  }

  /// 各个业务表的名字 → 行数。给状态页用，一眼看出数据到底在不在。
  Map<String, int> rowCounts() {
    final out = <String, int>{};
    for (final t in kTables.where((t) => t.isSynced)) {
      out[t.name] = db
          .select('SELECT COUNT(*) AS c FROM ${t.name} WHERE deleted_at IS NULL')
          .first['c'] as int;
    }
    return out;
  }

  /// 写入一条变更日志，返回它的 `seq`。
  ///
  /// **每一条业务写入都必须调用它** —— 漏掉一次，那次改动就永远不会同步到别的设备，
  /// 而且不会有任何报错。
  int logChange({
    required String tbl,
    required String rowId,
    required String op,
    required String rowUpdatedAt,
    required String rowUpdatedBy,
    DateTime? at,
  }) {
    final stmt = db.prepare('''
      INSERT INTO change_log (tbl, row_id, op, row_updated_at, row_updated_by, logged_at)
      VALUES (?, ?, ?, ?, ?, ?)
    ''');
    try {
      stmt.execute([tbl, rowId, op, rowUpdatedAt, rowUpdatedBy,
        (at ?? DateTime.now()).toUtc().toIso8601String()]);
    } finally {
      stmt.dispose();
    }
    return db.lastInsertRowId;
  }

  /// 当前最大的 `seq`（没有变更时为 0）。
  int get maxSeq =>
      db.select('SELECT COALESCE(MAX(seq), 0) AS m FROM change_log').first['m'] as int;

  /// 从 `cursor`（不含）之后拉变更。`limit` 防止一次拉爆。
  List<ChangeLogEntry> changesSince(int cursor, {int limit = 500}) {
    final rs = db.select(
      'SELECT seq, tbl, row_id, op, row_updated_at, row_updated_by, logged_at '
      'FROM change_log WHERE seq > ? ORDER BY seq LIMIT ?',
      [cursor, limit],
    );
    return rs
        .map((r) => ChangeLogEntry(
              seq: r['seq'] as int,
              tbl: r['tbl'] as String,
              rowId: r['row_id'] as String,
              op: r['op'] as String,
              rowUpdatedAt: r['row_updated_at'] as String,
              rowUpdatedBy: r['row_updated_by'] as String,
              loggedAt: r['logged_at'] as String,
            ))
        .toList();
  }

  Map<String, Object?> healthPayload() => {
        'sqliteVersion': sqliteLibraryInfo?.version,
        'sqliteLibrary': sqliteLibraryInfo?.library,
        'schemaVersion': kSchemaVersion,
        'schemaVersionInDb': schemaVersionInDb,
        'path': path,
        'sizeBytes': _fileSize(),
        'maxSeq': maxSeq,
        // change_log 刻意不做 GC（需要先有快照拉取，见 SyncService.cleanup 的注释），
        // 把行数暴露出来，增长异常时人能在状态页一眼看到
        'changeLogRows': _changeLogRows(),
        'rowCounts': rowCounts(),
      };

  int _changeLogRows() =>
      db.select('SELECT COUNT(*) AS c FROM change_log').first['c'] as int;

  int? _fileSize() {
    if (path == ':memory:') return null;
    final f = File(path);
    if (!f.existsSync()) return null;
    // WAL 模式下 .db 只是主文件，把 -wal 一起算进去才是真实占用
    var total = f.lengthSync();
    for (final suffix in ['-wal', '-shm']) {
      final sf = File('$path$suffix');
      if (sf.existsSync()) total += sf.lengthSync();
    }
    return total;
  }

  /// 关库。**可以重复调用**——测试里 tearDown 可能对同一个实例关两次，
  /// 而 `Database.dispose()` 第二次会抛，不该让这种小事把测试搞红。
  void close() {
    if (_closed) return;
    _closed = true;
    db.dispose();
  }

  bool _closed = false;

  bool get isClosed => _closed;
}

/// `change_log` 的一行。
class ChangeLogEntry {
  final int seq;
  final String tbl;
  final String rowId;

  /// `upsert` 或 `delete`。
  final String op;

  /// 该行的 HLC。客户端据此判断「这条我是不是已经有了 / 会不会更旧」。
  final String rowUpdatedAt;

  /// 谁改的。
  final String rowUpdatedBy;

  final String loggedAt;

  const ChangeLogEntry({
    required this.seq,
    required this.tbl,
    required this.rowId,
    required this.op,
    required this.rowUpdatedAt,
    required this.rowUpdatedBy,
    required this.loggedAt,
  });

  Map<String, Object?> toJson() => {
        'seq': seq,
        'tbl': tbl,
        'rowId': rowId,
        'op': op,
        'updatedAt': rowUpdatedAt,
        'updatedBy': rowUpdatedBy,
      };
}
