import 'dart:io';

import 'package:test/test.dart';
import 'package:zaoji_server/zaoji_server.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// R44 · schema v8 的三条规则。
///
/// v8 是纯增表轮（ai_prompts / ai_runs 都是 serverOnly）
/// **外加一例改列**（localOnly 的 ai_usage 补 run_ref/summary）。
/// 钉死三件容易做错的事：
///   1. 两张新表是服务端基建，客户端不该建、也不同步（scope 决定，见 schema_test）；
///   2. ai_usage 的改列走逐字共用的 ALTER 脚本，判据先看列在不在；
///   3. 旧库升级 + 再开一次都幂等。
void main() {
  late Directory tmp;
  late ServerState state;

  Future<ServerState> boot() => ServerState.boot(ServerConfig(
        host: '127.0.0.1',
        port: 1,
        tlsPort: 2,
        dataDir: Directory('${tmp.path}/data'),
        certDir: Directory('${tmp.path}/certs'),
      ));

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zaoji_v8_');
    state = await boot();
  });
  tearDown(() async {
    await state.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('新库形状', () {
    test('ai_prompts / ai_runs 由 createSql 直接建出，无需 ALTER', () {
      final names = state.db.db
          .select("SELECT name FROM sqlite_master WHERE type = 'table'")
          .map((r) => '${r['name']}')
          .toSet();
      expect(names, containsAll(['ai_prompts', 'ai_runs']));
    });

    test('ai_usage 建库即带 run_ref / summary', () {
      final cols = state.db.db
          .select('PRAGMA table_info(ai_usage)')
          .map((r) => '${r['name']}')
          .toSet();
      expect(cols, containsAll(['run_ref', 'summary']));
    });

    test('ai_runs 有 at / feature 索引', () {
      final idx = state.db.db
          .select("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'ai_runs'")
          .map((r) => '${r['name']}')
          .toSet();
      expect(idx, containsAll(['idx_ai_runs_at', 'idx_ai_runs_feature']));
    });

    test('meta 记的版本 == kSchemaVersion == 8', () {
      expect(
        state.db.db.select("SELECT v FROM meta WHERE k = 'schema_version'").single['v'],
        '$kSchemaVersion',
      );
      expect(kSchemaVersion, 8);
    });
  });

  group('真·旧库升级（把 ai_usage 两列拆掉、版本写回 7 再开一次）', () {
    test('开库即补列；再开一次不出事（幂等）', () async {
      final db = state.db.db;
      db.execute('ALTER TABLE ai_usage DROP COLUMN run_ref');
      db.execute('ALTER TABLE ai_usage DROP COLUMN summary');
      db.execute("UPDATE meta SET v = '7' WHERE k = 'schema_version'");
      expect(
        db.select('PRAGMA table_info(ai_usage)').any((r) => r['name'] == 'run_ref'),
        isFalse,
        reason: '先确认这确实是个 v7 形状的库',
      );

      final reopened = await boot();
      addTearDown(reopened.close);
      expect(
        reopened.db.db
            .select('PRAGMA table_info(ai_usage)')
            .map((r) => '${r['name']}')
            .toSet(),
        containsAll(['run_ref', 'summary']),
      );
      expect(reopened.db.db.select("SELECT v FROM meta WHERE k = 'schema_version'").single['v'],
          '8');

      // 已升过的库再开一次不该出事（迁移中途被杀后重进走的就是这条路）
      final third = await boot();
      addTearDown(third.close);
      expect(
        third.db.db
            .select('PRAGMA table_info(ai_usage)')
            .any((r) => r['name'] == 'run_ref'),
        isTrue,
      );
    });
  });

  group('ALTER 段幂等判据', () {
    test('列已在时整段跳过；真跑 ALTER 会报 duplicate column', () {
      final hasRunRef = state.db.db
          .select('PRAGMA table_info(ai_usage)')
          .any((r) => r['name'] == 'run_ref');
      expect(hasRunRef, isTrue);
      expect(() => state.db.db.execute(kSchemaV8AlterSql.first), throwsA(anything));
    });

    test('v8 脚本不碰任何同步表（本轮没有业务改列，apk 不是硬约束）', () {
      for (final s in kSchemaV8AlterSql) {
        expect(s, contains('ai_usage'),
            reason: 'v8 只改 ai_usage，出现别的表说明有人误加了业务改列：$s');
      }
    });
  });
}
