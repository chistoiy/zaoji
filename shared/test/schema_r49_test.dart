import 'package:test/test.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// R49 · 照片本机优先 + 永久删除补账队列的两张 localOnly 表。
///
/// 口径见《灶记-R49-照片本机优先与永久删除单机放行-设计》§2：
/// 纯增表、客户端消费（服务端建表按 isSynced 过滤根本不建这两张），
/// 所以这里钉的是**规格本身**——列名与顺序是引擎 SQL 的字面依赖。
void main() {
  group('R49 schema v9', () {
    final byName = {for (final t in kTables) t.name: t};

    test('media_blob / pending_purge 存在且是 localOnly（永不进同步流）', () {
      for (final n in ['media_blob', 'pending_purge']) {
        expect(byName[n], isNotNull, reason: '$n 未定义');
        expect(
          byName[n]!.scope,
          TableScope.localOnly,
          reason: '$n 必须 localOnly：照片字节与补删账都不许外发',
        );
        expect(byName[n]!.isSynced, isFalse);
      }
      expect(
        byName['media_blob']!.columnNames,
        ['sha', 'bytes', 'size', 'created_at', 'uploaded'],
      );
      expect(
        byName['pending_purge']!.columnNames,
        ['tbl', 'row_id', 'requested_at'],
      );
    });

    test('版本升到 9，createSql 幂等且带 BLOB 列', () {
      expect(kSchemaVersion, 9);
      final sql = byName['media_blob']!.createSql();
      expect(sql, contains('IF NOT EXISTS'));
      expect(sql, contains('BLOB'));
      // 补删账是联合主键：同一笔欠账重复入队必须无害（INSERT OR IGNORE 依赖它）
      expect(
        byName['pending_purge']!.createSql(),
        contains('PRIMARY KEY (tbl, row_id)'),
      );
    });
  });
}
