import 'dart:io';

import 'package:test/test.dart';
import 'package:zaoji_server/zaoji_server.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// R39 · schema v7（改列轮）的三条规则。
///
/// v7 是全项目第三例改列，也是第一次**一轮改两张表**
/// （recipe.created_at + pantry_item 的三态四列）——捆在一起只为了一件事：
/// 「改列 = 必须重发 apk」这笔硬账只付一次。
///
/// 这里钉的是三件最容易做错的事：
///   1. 洗数据不许猜（have=1 不能变成 low；老 recipe 不许有假创建时间）；
///   2. 旧客户端推来的行不能被拒（完整行纪律的滚动豁免要盖住全部新列）；
///   3. 豁免的语义是"保持库里现值"，不是"当 null 写"。
void main() {
  late Directory tmp;
  late ServerState state;

  setUp(() async {
    tmp = await createTempDirectory('zaoji_v7_');
    state = await ServerState.boot(ServerConfig(
      host: '127.0.0.1',
      port: 1,
      tlsPort: 2,
      dataDir: Directory('${tmp.path}/data'),
      certDir: Directory('${tmp.path}/certs'),
    ));
  });
  tearDown(() async {
    await state.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  void seedPantry(String id, int have) {
    final hlc = Hlc.now('n0').encode();
    state.db.db.execute(
      'INSERT INTO pantry_item (id, updated_at, updated_by, rev, deleted_at, name, have) '
      "VALUES (?, ?, 'n0', 1, NULL, '番茄', ?)",
      [id, hlc, have],
    );
  }

  group('v7 迁移的洗数据语义', () {
    test('have=0 洗成 none；have=1 保持 have —— 绝不猜成 low', () {
      seedPantry('p0', 0);
      seedPantry('p1', 1);
      final updates = kSchemaV7AlterSql
          .where((s) => s.startsWith('UPDATE'))
          .toList();
      expect(updates, hasLength(1), reason: '洗数据只该有一条，多一条就要重新审');
      for (final s in updates) {
        state.db.db.execute(s);
      }
      String statusOf(String id) =>
          '${state.db.db.select('SELECT stock_status FROM pantry_item WHERE id = ?', [id]).single['stock_status']}';
      expect(statusOf('p0'), 'none');
      expect(statusOf('p1'), 'have',
          reason: '"有"不等于"充足"，但更没有依据说它"快没了"——三态里只有这两档能从旧值确定');

      // 幂等：重跑不改变结果（迁移中途被杀后重进走的就是这条路）
      for (final s in updates) {
        state.db.db.execute(s);
      }
      expect(statusOf('p0'), 'none');
      expect(statusOf('p1'), 'have');
    });

    test('ALTER 段本身幂等：列已在时整段跳过（服务端与 App 共用判据）', () {
      final hasStatus = state.db.db
          .select('PRAGMA table_info(pantry_item)')
          .any((r) => r['name'] == 'stock_status');
      expect(hasStatus, isTrue, reason: '新库由 createSql 直接建出 v7 形状，不该再跑 ALTER');
      // 真跑一次 ALTER 会报 duplicate column —— 这条断言的意义是"判据必须先看列"
      expect(
        () => state.db.db.execute(kSchemaV7AlterSql.first),
        throwsA(anything),
      );
    });

    test('created_at 不回填：迁移脚本里没有任何碰它的语句', () {
      expect(
        kSchemaV7AlterSql.any((s) => s.startsWith('UPDATE') && s.contains('created_at')),
        isFalse,
        reason: '老行没有"入册时刻"这个事实。回填一个就是往日历上画一个没发生过的日子',
      );
    });
  });

  group('真·旧库升级（把 v7 那五列拆掉再开一次库）', () {
    /// 为什么这样造旧库：仓库里不能塞一份真实数据当 fixture（那是全家的账本），
    /// 而"手工备份一个旧库喂给测试"在家里这台机器之外永远跑不起来。
    /// DROP 掉本轮新增的五列、版本号写回 6，形状上就是升级前的库。
    test('开库即补列；created_at 不回填；have=0 洗成 none；再开一次不出事', () async {
      final db = state.db.db;
      for (final stmt in [
        'ALTER TABLE recipe DROP COLUMN created_at',
        'ALTER TABLE pantry_item DROP COLUMN storage',
        'ALTER TABLE pantry_item DROP COLUMN bought_at',
        'ALTER TABLE pantry_item DROP COLUMN note',
        'ALTER TABLE pantry_item DROP COLUMN stock_status',
        'INSERT INTO pantry_item (id, updated_at, updated_by, rev, deleted_at, name, have) '
            "VALUES ('p-out', 'h', 'n0', 1, NULL, '冰糖', 0)",
        'INSERT INTO recipe (id, updated_at, updated_by, rev, deleted_at, name) '
            "VALUES ('r-old', 'h', 'n0', 1, NULL, '升级前就有的菜')",
        "UPDATE meta SET v = '6' WHERE k = 'schema_version'",
      ]) {
        db.execute(stmt);
      }
      expect(
          db.select('PRAGMA table_info(pantry_item)')
              .any((r) => r['name'] == 'stock_status'),
          isFalse,
          reason: '先确认这确实是个 v6 形状的库');

      // 重新开一次库 = 走完整的 _migrate()，和生产上"换 exe 后第一次启动"同一条路
      final reopened = await ServerState.boot(ServerConfig(
        host: '127.0.0.1',
        port: 1,
        tlsPort: 2,
        dataDir: Directory('${tmp.path}/data'),
        certDir: Directory('${tmp.path}/certs'),
      ));
      addTearDown(reopened.close);
      final after = reopened.db.db;

      expect(after.select("SELECT v FROM meta WHERE k = 'schema_version'").single['v'],
          '7');
      expect(
          after.select('PRAGMA table_info(pantry_item)')
              .map((r) => '${r['name']}')
              .toSet(),
          containsAll(['storage', 'bought_at', 'note', 'stock_status']));
      expect(
          after.select('PRAGMA table_info(recipe)')
              .any((r) => r['name'] == 'created_at'),
          isTrue);

      final old = after
          .select("SELECT created_at FROM recipe WHERE id = 'r-old'")
          .single;
      expect(old['created_at'], isNull,
          reason: '升级前建的菜没有"入册时刻"这个事实，回填就是往日历上画假日子');
      expect(
          after
              .select("SELECT stock_status FROM pantry_item WHERE id = 'p-out'")
              .single['stock_status'],
          'none',
          reason: 'have=0 必须翻成「没有」');

      // 幂等：已经升过的库再开一次不该出事（迁移中途被杀后重进走的就是这条路）
      final third = await ServerState.boot(ServerConfig(
        host: '127.0.0.1',
        port: 1,
        tlsPort: 2,
        dataDir: Directory('${tmp.path}/data'),
        certDir: Directory('${tmp.path}/certs'),
      ));
      addTearDown(third.close);
      expect(
          third.db.db
              .select("SELECT COUNT(*) AS c FROM pantry_item WHERE stock_status = 'none'")
              .single['c'],
          1);
    });
  });

  group('v7 新列的滚动豁免（旧 apk 推来的行）', () {
    Device pair() {
      final code = state.sync.issuePairCode();
      final out = state.sync.redeem(
          code: code.code, deviceId: 'dev-old', deviceName: '旧 apk 模拟机');
      return state.sync.authenticate('Bearer ${out.token}')!;
    }

    String pushRow(Map<String, Object?> row, String mutationId,
        {Map<String, Object?>? base}) {
      final r = state.sync.push(
        device: pair(),
        mutationId: mutationId,
        changes: [
          {
            'tbl': 'recipe', 'rowId': row['id'], 'op': 'upsert', 'row': row,
            // 旧 apk 连 base 也是旧形状（没有新列）——与 rolling_v5_test 同款姿势，
            // 不给 base 的话服务端无法区分"客户端没改"和"客户端删了"，会开真冲突
            if (base != null) 'base': base,
          }
        ],
      );
      return '${r.results.single['outcome']}';
    }

    test('旧形状的行（没有 created_at）不被拒，且库里现值不被洗掉', () {
      final hlc = Hlc.now('n0').encode();
      // 先按 v7 全列建一行，created_at 有值
      state.db.db.execute(
        'INSERT INTO recipe (id, updated_at, updated_by, rev, deleted_at, name, created_at) '
        "VALUES ('r1', ?, 'n0', 1, NULL, '老菜单', '2026-09-01T08:00:00.000')",
        [hlc],
      );
      final oldRow = {
        'id': 'r1',
        'updated_at': Hlc.now('n1').encode(),
        'updated_by': 'n1',
        'rev': 2,
        'deleted_at': null,
        'name': '旧客户端改的名',
        'sub': null, 'art': null, 'pal': null, 'difficulty': 1,
        'self_time': null, 'cooked_count': 0, 'servings': 2, 'notes': null,
        'tags': null, 'source': 'manual', 'source_model': null,
        'source_at': null, 'last_cooked_at': null, 'cover_sha256': null,
        'photos': null, // ← 旧端连 v5 的列也没有
      };
      expect(
          const {'updated', 'merged'},
          contains(pushRow(oldRow, 'm-old',
              base: {...oldRow, 'name': '老菜单', 'rev': 1, 'updated_by': 'n0'})),
          reason: '缺新列就拒 = 那台 apk 从此同步不上（R29 已经踩过一次的形状）');      final kept = state.db.db
          .select("SELECT created_at FROM recipe WHERE id = 'r1'")
          .single['created_at'];
      expect('$kept', '2026-09-01T08:00:00.000',
          reason: '豁免的语义是"没提到 = 保持现值"，当 null 写就是把用户的入册时间洗掉');
    });

    test('白名单跟着表定义走：v7 的五个新列都在可同步列里', () {
      expect(syncWhitelist['recipe'], contains('created_at'));
      expect(syncWhitelist['pantry_item'],
          containsAll(['storage', 'bought_at', 'note', 'stock_status']));
    });
  });
}

/// 与 rolling_v5_test 同款：测试自己造临时目录，跑完随 tearDown 删掉。
Future<Directory> createTempDirectory(String prefix) =>
    Directory.systemTemp.createTemp(prefix);
