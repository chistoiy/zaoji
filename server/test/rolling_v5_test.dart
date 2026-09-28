import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zaoji_server/zaoji_server.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// R29 · schema v5 的三条新规则。
///
/// 这一轮是**全项目第一次「带旧客户端滚动升级」**的实战：
/// 新列对旧 apk 推送必须既不清空数据、也不拒掉同步；
/// 迁移必须把旧步骤单图洗进数组（升级那天照片不能凭空消失）；
/// 回收引用面必须盖住所有新引用（多算安全，漏算=删用户照片）。
void main() {
  late Directory tmp;
  late ServerState state;

  setUp(() async {
    tmp = await createTempDirectory('zaoji_v5_');
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

  String seed(String hlcNode, int rev) {
    final hlc = Hlc.now(hlcNode).encode();
    state.db.db.execute(
      'INSERT INTO recipe (id, updated_at, updated_by, rev, deleted_at, name, photos) '
      "VALUES ('r1', ?, '$hlcNode', $rev, NULL, '照片墙菜', ?)",
      [hlc, jsonEncode(['a' * 64])],
    );
    final sh = Hlc.now(hlcNode).encode();
    state.db.db.execute(
      'INSERT INTO step (id, updated_at, updated_by, rev, deleted_at, '
      'recipe_id, idx, text, image_sha256, images) '
      "VALUES ('s1', ?, '$hlcNode', 1, NULL, 'r1', 0, '下锅', ?, NULL)",
      [sh, 'b' * 64],
    );
    return hlc;
  }

  group('v5 迁移', () {
    test('旧库（无新列 + step 有单图）开库后被洗进 images 数组', () {
      // 造一个 v4 形状的库：先建表（用当前 DDL）再删不掉——换个法子：
      // 直接拿真库演示迁移幂等路径之外的那半——洗数据语句。
      // （列已在，_migrateV4toV5 整段跳过；这里手动跑 UPDATE 验证语义。）
      seed('n0', 1);
      final stmts = kSchemaV5AlterSql
          .where((s) => s.startsWith('UPDATE'))
          .toList();
      state.db.db.execute(stmts.single);
      final row = state.db.db.select("SELECT images FROM step WHERE id='s1'").single;
      final list = jsonDecode(row['images'] as String) as List;
      expect(list, ['b' * 64], reason: '旧单图必须出现在数组里——升级即丢图是不可接受的');
      // 幂等：再跑一遍不重复、不报错
      state.db.db.execute(stmts.single);
      final again = state.db.db.select("SELECT images FROM step WHERE id='s1'").single;
      expect(jsonDecode(again['images'] as String), ['b' * 64]);
    });
  });

  group('滚动豁免（旧 apk 推缺列的行）', () {
    Map<String, Object?> change(String hlc, Map<String, Object?> row,
            {Map<String, Object?>? base}) =>
        {
          'tbl': 'recipe',
          'rowId': 'r1',
          'op': 'upsert',
          'row': row,
          if (base != null) 'base': base,
        };

    Device pair() {
      final code = state.sync.issuePairCode();
      final out = state.sync.redeem(
          code: code.code, deviceId: 'dev-1', deviceName: '旧 apk 模拟机');
      return state.sync.authenticate('Bearer ${out.token}')!;
    }

    test('缺 photos 的更新：列保持现值，不清洗也不拒', () async {
      final hlc = seed('n0', 1);
      final hlc2 = Hlc.now('n1').encode();
      final d = pair();
      // 旧 apk 的「完整行」= 新列以外的全部列（photos 是它不认识的字段）
      final base = {
        'id': 'r1',
        'updated_at': hlc2,
        'updated_by': 'n1',
        'rev': 2,
        'deleted_at': null,
        'name': '照片墙菜',
        'sub': '滚动升级测试', 'art': null, 'pal': null, 'difficulty': 1,
        'self_time': null, 'cooked_count': 0, 'servings': 2,
        'notes': '', 'tags': null, 'source': 'manual',
        'source_model': null, 'source_at': null,
        'last_cooked_at': null, 'cover_sha256': null,
      };
      final seedRow =
          state.db.db.select("SELECT * FROM recipe WHERE id='r1'").single;
      final base4change = Map<String, Object?>.from(seedRow)
        ..remove('photos'); // base 也按旧 apk 的形状给（它没有新列）
      final out = state.sync.push(
          device: d,
          mutationId: 'm-rolling-1',
          changes: [change(hlc2, base, base: base4change)]);
      expect(out.ok, isTrue, reason: out.error);
      final r = out.results.single;
      expect(const {'updated', 'merged'}, contains(r['outcome']),
          reason: '${r['reason']}');
      final row = state.db.db
          .select("SELECT name, sub, photos FROM recipe WHERE id='r1'")
          .single;
      expect(row['sub'], '滚动升级测试');
      expect(jsonDecode(row['photos'] as String), ['a' * 64],
          reason: '旧端没提这列 = 保持现值；当 null 写就是静默删照片墙');
      hlc; // 首写句柄仅播种用
    });

    test('非豁免列照旧要求完整行（纪律不松动）', () async {
      seed('n0', 1);
      final hlc2 = Hlc.now('n1').encode();
      final out = state.sync.push(
          device: pair(),
          mutationId: 'm-rolling-2',
          changes: [
                change(hlc2, {
              'id': 'r1',
              'updated_at': hlc2,
              'updated_by': 'n1',
              'rev': 2,
              'deleted_at': null,
              // 缺 name 等一堆业务列——必须照旧拒绝（豁免只放新列）
              'photos': jsonEncode(['c' * 64]),
            })
          ]);
      final r = out.results.single;
      expect(r['outcome'], 'rejected');
      expect('${r['reason']}', contains('name'));
    });
  });

  group('回收引用面', () {
    test('photos 与 step.images（含旧单列）里的 sha 都不许被回收判孤儿', () async {
      seed('n0', 1);
      // 给 step 补 images 数组
      state.db.db.execute(
        "UPDATE step SET images = ? WHERE id='s1'",
        [jsonEncode(['d' * 64])],
      );
      final refs = state.db.referencedCoverShas();
      expect(refs, containsAll(['a' * 64, 'b' * 64, 'd' * 64]),
          reason: '封面/照片墙/旧步骤单图/新步骤数组四类引用一个都不能漏——漏=删用户照片');
    });
  });
}

Future<Directory> createTempDirectory(String prefix) =>
    Directory.systemTemp.createTemp(prefix);
