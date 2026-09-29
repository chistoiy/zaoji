import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:zaoji_server/zaoji_server.dart';

/// R43 · 永久删除与墓碑清理（FR-DATA-13：回收站可查、可恢复、可永久删除；30 天后自动清理）。
///
/// 这一轮的四个立场，每条对着一条测试：
/// ① **`/api/purge` 不许删活行** —— 只认已经在回收站里的行。否则这个端点就成了
///    绕过回收站直接抹数据的后门，撤销窗口也没了；
/// ② **purge 必须写变更** —— 只删服务端这一份，别的设备回收站里那条还能「恢复」，
///    一推就复活，「永久删除」就不永久；
/// ③ **op 不能被拉取逻辑洗掉** —— 拉到 `purge` 与拉到 `delete` 是两件事：
///    前者物理删、后者打墓碑（旧 apk 没有前者，就安全退化成软删除，所以协议版本不动）；
/// ④ **30 天自动清理走同一套 purge** —— 清的是服务端的存储，但通知必须广播出去。
void main() {
  late Directory tmp;
  late ServerState state;
  late Handler handler;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zaoji_purge_');
    state = await ServerState.boot(ServerConfig(
      host: '127.0.0.1',
      port: 1,
      tlsPort: 2,
      dataDir: Directory('${tmp.path}${Platform.pathSeparator}data'),
      certDir: Directory('${tmp.path}${Platform.pathSeparator}certs'),
    ));
    handler = ZaojiServer.buildHandler(state, const ['192.168.1.10']);
  });

  tearDown(() async {
    await state.close();
    if (await tmp.exists()) {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {/* Windows 句柄兜底，见 handler_test 注释 */}
    }
  });

  Future<Response> call(String method, String path,
          {Object? body, String? token}) =>
      Future.value(handler(Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: {
          if (token != null) 'authorization': 'Bearer $token',
          if (body != null) 'content-type': 'application/json',
        },
        body: body == null ? null : jsonEncode(body),
      )));

  Future<Map<String, dynamic>> jsonOf(Response res) async =>
      (jsonDecode(await res.readAsString()) as Map).cast<String, dynamic>();

  /// 配一台设备并拿到它的 Device（同步层要的是设备，不是 token）。
  /// 走 authenticate 拿，与真实请求同一条鉴权路径——不给测试开后门。
  Device pair({String id = 'phone-1'}) {
    final code = state.sync.issuePairCode();
    final out = state.sync.redeem(code: code.code, deviceId: id, deviceName: '我的手机');
    expect(out.ok, isTrue, reason: out.failure?.message);
    final d = state.sync.authenticate('Bearer ${out.token}');
    expect(d, isNotNull);
    return d!;
  }

  // ── 完整行：推 upsert 缺列会被整条拒，所以这几个工厂就是"完整行"的样子 ──
  Map<String, Object?> recipeRow({required String id, String? deletedAt}) => {
        'id': id,
        'updated_at': 'h-$id',
        'updated_by': 'phone-1',
        'rev': 1,
        'deleted_at': deletedAt,
        'name': '西红柿炒蛋',
        'sub': null,
        'art': null,
        'pal': null,
        'difficulty': 1,
        'self_time': null,
        'cooked_count': 0,
        'servings': 2,
        'notes': null,
        'tags': null,
        'source': 'manual',
        'source_model': null,
        'source_at': null,
        'last_cooked_at': null,
        'cover_sha256': null,
        'photos': null,
        'created_at': null,
      };

  Map<String, Object?> ingredientRow(String id) => {
        'id': id,
        'updated_at': 'h-$id',
        'updated_by': 'phone-1',
        'rev': 1,
        'deleted_at': null,
        'recipe_id': 'r1',
        'sort': 1,
        'name': '番茄',
        'qty_text': '2 个',
        'qty_value': 2,
        'qty_unit': '个',
        'is_main': 1,
        'alias_key': null,
      };

  Map<String, Object?> stepRow(String id) => {
        'id': id,
        'updated_at': 'h-$id',
        'updated_by': 'phone-1',
        'rev': 1,
        'deleted_at': null,
        'recipe_id': 'r1',
        'idx': 1,
        'text': '炒三分钟',
        'art': null,
        'image_sha256': null,
        'images': null,
      };

  /// 种一道菜 + 两个子行（全走真推送路径，顺带证明 change_log 在动）。
  void seed(Device d) {
    final r = state.sync.push(device: d, mutationId: 'm-seed', changes: [
      {'tbl': 'recipe', 'rowId': 'r1', 'op': 'upsert', 'row': recipeRow(id: 'r1')},
      {'tbl': 'ingredient', 'rowId': 'i1', 'op': 'upsert', 'row': ingredientRow('i1')},
      {'tbl': 'step', 'rowId': 's1', 'op': 'upsert', 'row': stepRow('s1')},
    ]);
    expect(r.error, isNull, reason: '${r.error}');
    expect(r.results.map((e) => e['outcome']),
        everyElement(anyOf('inserted', 'updated')), reason: '${r.results}');
  }

  /// 软删（进回收站）——永久删除的前置状态。
  /// 删除也得带完整 row（服务端先校载荷再看 op，见 sync_test 同款姿势）。
  void trash(Device d) {
    final r = state.sync.push(device: d, mutationId: 'm-trash', changes: [
      {'tbl': 'recipe', 'rowId': 'r1', 'op': 'delete', 'row': recipeRow(id: 'r1')},
      {'tbl': 'ingredient', 'rowId': 'i1', 'op': 'delete', 'row': ingredientRow('i1')},
      {'tbl': 'step', 'rowId': 's1', 'op': 'delete', 'row': stepRow('s1')},
    ]);
    expect(r.results.where((e) => e['outcome'] == 'deleted').length, 3,
        reason: '${r.results}');
  }

  Map<String, Object?>? rowOf(String tbl, String id) {
    final rs = state.db.db.select('SELECT * FROM $tbl WHERE id = ?', [id]);
    return rs.isEmpty ? null : rs.first;
  }

  List<String> opsOf(String rowId) => [
        for (final r in state.db.db
            .select('SELECT op FROM change_log WHERE row_id = ? ORDER BY seq', [rowId]))
          '${r['op']}',
      ];

  int changeLogCount() =>
      state.db.db.select('SELECT COUNT(*) AS c FROM change_log').first['c'] as int;

  group('服务端 purge', () {
    test('活行不许直接永久删除：被拒，且数据一行没动', () {
      final d = pair();
      seed(d);
      final out = state.sync.purge(device: d, rows: [
        {'tbl': 'recipe', 'id': 'r1'}
      ]);
      expect(out.single['outcome'], 'rejected', reason: '$out');
      expect(out.single['reason'], contains('回收站'));
      expect(rowOf('recipe', 'r1'), isNotNull, reason: '拒绝必须是真的没动数据');
      expect(opsOf('r1'), isNot(contains('purge')));
    });

    test('进回收站之后永久删除：父行与子行都物理消失，各写一条 purge', () {
      final d = pair();
      seed(d);
      trash(d);
      final out = state.sync.purge(device: d, rows: [
        {'tbl': 'recipe', 'id': 'r1'}
      ]);
      expect(out.single['outcome'], 'purged', reason: '$out');
      expect(rowOf('recipe', 'r1'), isNull);
      // 级联：ingredient / step 没被点名，但父行没了它们就是孤儿，必须一起物理删
      expect(rowOf('ingredient', 'i1'), isNull,
          reason: 'recipe 的子行要跟着级联，不然库里留一堆没人认领的行');
      expect(rowOf('step', 's1'), isNull);
      expect(opsOf('i1'), contains('purge'),
          reason: '子行的物理删除也要广播，否则别的设备留着墓碑还能恢复');
      expect(opsOf('s1'), contains('purge'));
    });

    test('拉取：purge 变更不带载荷，且 op 保持 purge（不许被洗成 delete）', () {
      final d = pair();
      seed(d);
      trash(d);
      state.sync.purge(device: d, rows: [
        {'tbl': 'recipe', 'id': 'r1'}
      ]);

      final changes = state.sync.pull(since: 0).changes;
      Map<String, Object?>? find(String tbl, String id, String op) =>
          changes.cast<Map<String, Object?>?>().firstWhere(
                (c) => c!['tbl'] == tbl && c['rowId'] == id && c['op'] == op,
                orElse: () => null,
              );
      expect(find('recipe', 'r1', 'purge'), isNotNull,
          reason: '拉不到 purge，别的设备就永远不会物理删这一行');
      expect(find('recipe', 'r1', 'purge')!.containsKey('row'), isFalse,
          reason: '行都没了，不许给载荷');
      expect(find('ingredient', 'i1', 'purge'), isNotNull);
      expect(find('step', 's1', 'purge'), isNotNull);
      // delete 那几条也还在（顺序：先软删后永久删），两件事各记各的
      expect(find('recipe', 'r1', 'delete'), isNotNull);
    });

    test('重复永久删除幂等：第二次 skipped，也不再写第二条 purge', () {
      final d = pair();
      seed(d);
      trash(d);
      state.sync.purge(device: d, rows: [
        {'tbl': 'recipe', 'id': 'r1'}
      ]);
      final before = opsOf('r1').length;
      final again = state.sync.purge(device: d, rows: [
        {'tbl': 'recipe', 'id': 'r1'}
      ]);
      expect(again.single['outcome'], 'skipped', reason: '$again');
      expect(opsOf('r1').length, before, reason: '幂等不等于重复广播');
    });

    test('白名单外进不来：想借 purge 删本机私有表与服务端设施表，一律拒', () {
      final d = pair();
      final out = state.sync.purge(device: d, rows: [
        {'tbl': 'local_pref', 'id': 'x'},
        {'tbl': 'ai_config', 'id': 'y'},
        {'tbl': 'device', 'id': 'z'},
        {'tbl': 'recipe', 'id': ''},
      ]);
      expect(out.map((e) => e['outcome']), everyElement('rejected'), reason: '$out');
    });

    test('客户端不能自己推一条 purge（永久删除的口子只在回收站那侧）', () {
      final d = pair();
      seed(d);
      // 带完整 row：要过掉「必须带 row」那道检查，真正撞到的应该是 op 那道闸
      final r = state.sync.push(device: d, mutationId: 'm-sneaky', changes: [
        {'tbl': 'recipe', 'rowId': 'r1', 'op': 'purge', 'row': recipeRow(id: 'r1')},
      ]);
      expect(r.results.single['outcome'], 'rejected', reason: '${r.results}');
      expect(r.results.single['reason'], contains('upsert 或 delete'));
      expect(rowOf('recipe', 'r1'), isNotNull);
    });

    test('30 天自动清理：老墓碑物理删并广播 purge，年轻墓碑留着（子行跟着父行走）', () {
      final d = pair();
      seed(d);
      trash(d);
      final sql = state.db.db;
      final old =
          DateTime.now().subtract(const Duration(days: 40)).toIso8601String();
      final young =
          DateTime.now().subtract(const Duration(days: 3)).toIso8601String();
      sql.execute('UPDATE recipe SET deleted_at = ? WHERE id = ?', [old, 'r1']);
      // 另种一道只有 3 天的墓碑，它才是"不该被清"的那条。
      // （子行 i1/s1 只有 3 天也会被清掉——父行没了它们就是孤儿，级联优先于年龄，
      //  这条不对称是故意的：留着它们除了占库位没有别的用处。）
      sql.execute(
        'INSERT INTO recipe (id, updated_at, updated_by, rev, deleted_at, name) '
        "VALUES ('r2', 'h-r2', 'phone-1', 1, ?, '番茄蛋汤')",
        [young],
      );

      final cleaned = state.sync.cleanup();
      expect(cleaned, greaterThan(0), reason: '清理计数要把 purge 掉的行算进去');
      expect(rowOf('recipe', 'r1'), isNull, reason: '40 天的墓碑该物理清了');
      expect(opsOf('r1'), contains('purge'),
          reason: '服务端自己清也要广播，不然各台设备留着能恢复的墓碑');
      expect(rowOf('recipe', 'r2'), isNotNull, reason: '才 3 天的不该被清');
      expect(rowOf('ingredient', 'i1'), isNull, reason: '父行被清，子行跟着走（级联优先于年龄）');
      // 清理之后再拉一次：这台设备的客户端会把 r1/i1/s1 物理删掉
      final changes = state.sync.pull(since: 0).changes;
      expect(
          changes.any((c) => c['op'] == 'purge' && c['rowId'] == 'r1'), isTrue);
      expect(
          changes.any((c) => c['op'] == 'purge' && c['rowId'] == 'r2'), isFalse,
          reason: '没到龄的行不该收到 purge，否则回收站形同虚设');
    });

    test('★ 30 天这条账不靠重启来对：一次普通拉取就把过期墓碑清了，purge 还在同一页带回', () {
      // 家里那台笔记本一跑就是几个月，boot() 那一次 cleanup() 永远等不到第二次。
      // 这一条钉的是"触发点挪到了同步这一侧"——不是钉 cleanup 的语义（上一条已经钉过）。
      final d = pair();
      seed(d);
      trash(d);
      final old =
          DateTime.now().subtract(const Duration(days: 40)).toIso8601String();
      state.db.db.execute('UPDATE recipe SET deleted_at = ? WHERE id = ?', [old, 'r1']);
      // 把 boot() 那次留下的时间戳抹掉：本轮要验的是"拉取自己会触发"，
      // 不是"开机刚好清过"。
      state.db.db.execute('DELETE FROM server_setting WHERE k = ?',
          [SyncService.kLastCleanupAtKey]);

      final page = state.sync.pull(since: 0);
      expect(rowOf('recipe', 'r1'), isNull, reason: '拉一下就该把到龄的墓碑清掉');
      expect(page.changes.any((c) => c['op'] == 'purge' && c['rowId'] == 'r1'), isTrue,
          reason: '清理写出的 purge 要在**这一页**里带回，触发它的那台设备当场就抹掉回收站那条');
    });

    test('12 小时内不重复清理：第二次拉取不许再做一次全表扫', () {
      pair();
      // boot() 已经清过一次并落了戳记（cleanup() 自己写 kLastCleanupAtKey），
      // 所以这里天生走的是"间隔没到"那一支——正是这条要验的。
      final before = changeLogCount();
      state.db.db.execute(
        'INSERT INTO recipe (id, updated_at, updated_by, rev, deleted_at, name) '
        "VALUES ('rz', 'h-rz', 'phone-1', 1, ?, '到龄的汤')",
        [DateTime.now().subtract(const Duration(days: 40)).toIso8601String()],
      );
      expect(state.sync.cleanupIfStale(), 0, reason: '间隔没到就该直接返回，不该动手');
      expect(rowOf('recipe', 'rz'), isNotNull, reason: '同上：这一条本轮不该被清');
      expect(changeLogCount(), before,
          reason: '没动手就不许留任何变更，否则每次同步都白扫一遍全库');
      // 把间隔压到零：验的判据确实是"距上次多久"，而不是别的东西
      expect(state.sync.cleanupIfStale(interval: Duration.zero), greaterThan(0));
      expect(rowOf('recipe', 'rz'), isNull);
    });
  });

  group('HTTP 层', () {
    test('POST /api/purge 没凭证就是 401，不留半成品语义', () async {
      final res = await call('POST', '/api/purge', body: {
        'rows': [
          {'tbl': 'recipe', 'id': 'r1'}
        ]
      });
      expect(res.statusCode, 401);
    });

    test('请求体校验：空数组 / 非数组 / 超 200 条 / 缺 id，一律 400 且不动数据', () async {
      final code = state.sync.issuePairCode();
      final out = state.sync.redeem(code: code.code, deviceId: 'phone-8', deviceName: '平板');
      final d = state.sync.authenticate('Bearer ${out.token}')!;
      seed(d);

      for (final bad in [
        {'rows': []},
        {'rows': 'x'},
        {
          'rows': [
            for (var i = 0; i < 201; i++) {'tbl': 'recipe', 'id': 'r$i'}
          ]
        },
        {
          'rows': [
            {'tbl': 'recipe'} // 缺 id
          ]
        },
      ]) {
        final res = await call('POST', '/api/purge', body: bad, token: out.token);
        expect(res.statusCode, 400, reason: '$bad 竟然被接受了');
      }
      expect(rowOf('recipe', 'r1'), isNotNull, reason: '校验没过就不该碰数据');
    });

    test('真走一遍端点：回收站里的菜被永久删除，逐条回结果', () async {
      final code = state.sync.issuePairCode();
      final out = state.sync.redeem(code: code.code, deviceId: 'phone-9', deviceName: '手机');
      final d = state.sync.authenticate('Bearer ${out.token}')!;
      seed(d);
      trash(d);

      final res = await call('POST', '/api/purge', token: out.token, body: {
        'rows': [
          {'tbl': 'recipe', 'id': 'r1'}
        ]
      });
      expect(res.statusCode, 200);
      final body = await jsonOf(res);
      expect(body['ok'], isTrue);
      expect((body['results'] as List).single['outcome'], 'purged');
      expect(rowOf('recipe', 'r1'), isNull);
      expect(rowOf('ingredient', 'i1'), isNull);
    });
  });
}
