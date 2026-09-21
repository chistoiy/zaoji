import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:zaoji_server/zaoji_server.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// R22 · 冲突裁决（POST /api/conflicts/resolve）。
///
/// 裁决**放在服务端**是这一轮的关键决策：客户端改行再推上去时不带 base 快照，
/// 「把值改回旧的那个」会被冲突判定认成**新一轮真冲突**——冲突箱越裁决越多。
/// 服务端裁决则天然拿到 local/remote 两份值、由它盖 HLC（R6 决策④），
/// 所有设备一次拉取就收敛。
///
/// 断言的重心：
/// ① 选定值真的写进了业务行，且是**服务端盖的新 HLC**；
/// ② conflict_item 的 resolved 标记本身也要进 change_log——别的设备才知道冲突没了；
/// ③ 字段名必须过白名单：conflict_item 是拉回来的数据，field 列被人塞个
///    'updated_at' 就能借裁决改五列，这扇门必须焊死；
/// ④ 重复裁决、未知 id、缺值一律拒绝且**不动数据**。
void main() {
  late Directory tmp;
  late ServerState state;
  late Handler handler;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zaoji_resolve_');
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
          {Object? body, String? token, String? nodeId}) =>
      Future.value(handler(Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: {
          if (token != null) 'authorization': 'Bearer $token',
          if (nodeId != null) kNodeIdHeader: nodeId,
          if (body != null) 'content-type': 'application/json',
        },
        body: body == null ? null : jsonEncode(body),
      )));

  Future<Map<String, dynamic>> jsonOf(Response res) async =>
      (jsonDecode(await res.readAsString()) as Map).cast<String, dynamic>();

  /// 配对一台设备，返回它的 token（裁决接口和数据接口同一套鉴权）。
  String pairDevice({String id = 'phone-1'}) {
    final code = state.sync.issuePairCode();
    final out = state.sync.redeem(
        code: code.code, deviceId: id, deviceName: '我的手机');
    expect(out.ok, isTrue, reason: out.failure?.message);
    return out.token!;
  }

  Map<String, Object?> recipeRow({
    required String id,
    required String name,
    String hlc = 'h-1',
    String by = 'phone-1',
    String? notes,
    int difficulty = 1,
  }) =>
      {
        'id': id,
        'updated_at': hlc,
        'updated_by': by,
        'rev': 1,
        'deleted_at': null,
        'name': name,
        'sub': null,
        'art': null,
        'pal': null,
        'difficulty': difficulty,
        'self_time': null,
        'cooked_count': 0,
        'servings': 2,
        'notes': notes,
        'tags': null,
        'source': 'manual',
        'source_model': null,
        'source_at': null,
        'last_cooked_at': null,
        'cover_sha256': null,
      };

  /// 推一条真冲突（两端都改了 name），返回 conflict_item 的 id。
  /// 姿势与 sync_test 的「两边改同一字段」同款：先插服务端版，再推带 base 的客户端版。
  /// ★ 必须复用调用方已配对的 token：同一 deviceId 再 redeem 会换发新 token，
  ///   手里那份当场作废（第一版测试就栽在拿旧 token 去请求 → 401）。
  String openNameConflict({
    required String token,
    String rowId = 'r1',
    String serverName = '服务端改的',
    String clientName = '客户端改的',
    String notes = '原始注意',
  }) {
    final device = state.sync.authenticate('Bearer $token')!;
    state.sync.push(device: device, mutationId: 'm-1', changes: [
      {
        'tbl': 'recipe',
        'rowId': rowId,
        'op': 'upsert',
        'row': recipeRow(id: rowId, name: serverName, notes: notes, hlc: 'h-2'),
      }
    ]);
    final r = state.sync.push(device: device, mutationId: 'm-2', changes: [
      {
        'tbl': 'recipe',
        'rowId': rowId,
        'op': 'upsert',
        'row': recipeRow(id: rowId, name: clientName, notes: notes, hlc: 'h-3'),
        'base': recipeRow(id: rowId, name: '原本的', notes: notes, hlc: 'h-1'),
      }
    ]);
    expect(r.results.single['outcome'], 'conflict',
        reason: '前置条件没立起来：没产生真冲突');
    final tickets = state.db.db
        .select('SELECT id FROM conflict_item WHERE row_id = ? AND field = ?',
            [rowId, 'name']);
    expect(tickets, hasLength(1));
    return '${tickets.first['id']}';
  }

  Future<Response> resolve(String token, List<Map<String, Object?>> items) =>
      call('POST', '/api/conflicts/resolve',
          body: {'items': items}, token: token);

  Map<String, Object?>? rowOf(String id) {
    final rs = state.db.db.select('SELECT * FROM recipe WHERE id = ?', [id]);
    return rs.isEmpty ? null : rs.first;
  }

  Map<String, Object?> ticketOf(String conflictId) {
    final rs = state.db.db
        .select('SELECT * FROM conflict_item WHERE id = ?', [conflictId]);
    expect(rs, hasLength(1));
    return rs.first;
  }

  group('裁决的基本面', () {
    test('★ choice=remote：选定值写进业务行，服务端盖新 HLC，冲突标记归档', () async {
      final token = pairDevice();
      final cid = openNameConflict(token: token);
      final before = rowOf('r1')!;

      final res = await jsonOf(await resolve(token, [
        {'conflictId': cid, 'choice': 'remote'}
      ]));
      expect(res['ok'], isTrue);
      expect((res['results'] as List).cast<Map<String, dynamic>>().single['outcome'], 'applied');

      final after = rowOf('r1')!;
      expect(after['name'], '客户端改的', reason: 'remote = 推来的那份（客户端改的）');
      expect('${after['updated_at']}'.compareTo('${before['updated_at']}'), greaterThan(0),
          reason: '新 HLC 由服务端盖——所有端才能收敛到同一结论');
      expect(after['rev'], (before['rev'] as int) + 1);

      final t = ticketOf(cid);
      expect(t['resolved_at'], isNotNull);
      expect(t['resolution'], 'remote');
    });

    test('choice=local：保留服务端现存那份', () async {
      final token = pairDevice();
      final cid = openNameConflict(token: token);
      await resolve(token, [
        {'conflictId': cid, 'choice': 'local'}
      ]);
      expect(rowOf('r1')!['name'], '服务端改的');
      expect(ticketOf(cid)['resolution'], 'local');
    });

    test('choice=merged：用户手填的值原样落库', () async {
      final token = pairDevice();
      final cid = openNameConflict(token: token);
      await resolve(token, [
        {'conflictId': cid, 'choice': 'merged', 'mergedValue': '茄汁番茄蛋'}
      ]);
      expect(rowOf('r1')!['name'], '茄汁番茄蛋');
      expect(ticketOf(cid)['resolution'], 'merged');
    });

    test('★ 裁决结果要能被其它设备拉到：业务行与冲突标记都进了 change_log', () async {
      final token = pairDevice();
      final cid = openNameConflict(token: token);
      final seqBefore = state.db.maxSeq;
      await resolve(token, [
        {'conflictId': cid, 'choice': 'remote'}
      ]);
      final pull = state.sync.pull(since: seqBefore);
      final tbls = pull.changes.map((c) => c['tbl']).toSet();
      expect(tbls, containsAll(['recipe', 'conflict_item']),
          reason: '冲突行不广播的话，别的设备的冲突箱永远挂着一张已经裁完的卡');
    });

    test('★ 冲突刚开出来就要进 change_log：别的设备的冲突箱看得见这张票', () async {
      // 裁决标记进日志只解决「已裁的别再挂着」；
      // 若开票本身不广播，票从生到死都只有服务端知道——客户端冲突箱永远空。
      // （真链路冒烟抓出来的：单测都直接 SELECT conflict_item 拿 id，绕过了 pull。）
      final token = pairDevice();
      final seqBefore = state.db.maxSeq;
      final cid = openNameConflict(token: token);

      final pull = state.sync.pull(since: seqBefore);
      final hits = pull.changes
          .where((c) => c['tbl'] == 'conflict_item' && c['rowId'] == cid)
          .toList();
      expect(hits, hasLength(1), reason: '开票没记变更：新设备拉不到待裁决的票');
      final row = (hits.single['row'] as Map).cast<String, dynamic>();
      expect(row['field'], 'name');
      expect(row['local_value'], '服务端改的');
      expect(row['remote_value'], '客户端改的');
      expect(row['resolved_at'], isNull, reason: '拉到的就该是未裁决状态');
    });

    test('INTEGER 列裁决后类型不漂（值以 TEXT 存进冲突箱，写回时要按原列型转）', () async {
      final d = pairDevice();
      final device = state.sync.authenticate('Bearer $d')!;
      // 三段式：插基线 → 服务端改难度 → 客户端基于基线也改难度（真冲突）。
      // 只有两段的话，「服务端没动过」会被 changedLocal=∅ 判成 takeRemote，压根不冲突。
      state.sync.push(device: device, mutationId: 'a', changes: [
        {'tbl': 'recipe', 'rowId': 'r1', 'op': 'upsert',
         'row': recipeRow(id: 'r1', name: '菜', difficulty: 1, hlc: 'h-1')}
      ]);
      state.sync.push(device: device, mutationId: 'b', changes: [
        {'tbl': 'recipe', 'rowId': 'r1', 'op': 'upsert',
         'row': recipeRow(id: 'r1', name: '菜', difficulty: 2, hlc: 'h-2'),
         'base': recipeRow(id: 'r1', name: '菜', difficulty: 1, hlc: 'h-1')}
      ]);
      final rc = state.sync.push(device: device, mutationId: 'c', changes: [
        {'tbl': 'recipe', 'rowId': 'r1', 'op': 'upsert',
         'row': recipeRow(id: 'r1', name: '菜', difficulty: 3, hlc: 'h-3'),
         'base': recipeRow(id: 'r1', name: '菜', difficulty: 1, hlc: 'h-1')}
      ]);
      expect(rc.results.single['outcome'], 'conflict');
      final cid = '${state.db.db.select("SELECT id FROM conflict_item WHERE field = ?", ['difficulty']).first['id']}';

      await resolve(d, [{'conflictId': cid, 'choice': 'remote'}]);
      final typed = state.db.db
          .select("SELECT typeof(difficulty) AS t, difficulty AS v FROM recipe WHERE id='r1'");
      expect(typed.first['t'], 'integer',
          reason: '写成 "3"（文本）的话，客户端按 int 读的地方全炸');
      expect(typed.first['v'], 3);
    });

    test('null 参与冲突时存真 NULL，裁决回 null 也写回 NULL（不是字符串 "null"）', () async {
      final d = pairDevice();
      final device = state.sync.authenticate('Bearer $d')!;
      // 服务端把 notes 清空、客户端基于旧版补了 notes → local_value 该是 NULL
      state.sync.push(device: device, mutationId: 'a', changes: [
        {'tbl': 'recipe', 'rowId': 'r1', 'op': 'upsert',
         'row': recipeRow(id: 'r1', name: '菜', notes: '原注意', hlc: 'h-1')}
      ]);
      state.sync.push(device: device, mutationId: 'b', changes: [
        {'tbl': 'recipe', 'rowId': 'r1', 'op': 'upsert',
         'row': recipeRow(id: 'r1', name: '菜', notes: null, hlc: 'h-2'),
         'base': recipeRow(id: 'r1', name: '菜', notes: '原注意', hlc: 'h-1')}
      ]);
      final rc = state.sync.push(device: device, mutationId: 'c', changes: [
        {'tbl': 'recipe', 'rowId': 'r1', 'op': 'upsert',
         'row': recipeRow(id: 'r1', name: '菜', notes: '客户端补的', hlc: 'h-3'),
         'base': recipeRow(id: 'r1', name: '菜', notes: '原注意', hlc: 'h-1')}
      ]);
      expect(rc.results.single['outcome'], 'conflict');
      final t = state.db.db
          .select("SELECT id, local_value FROM conflict_item WHERE field='notes'")
          .first;
      expect(t['local_value'], isNull,
          reason: 'R22 修形：_openConflict 不再把 null 字符串化');

      // 选 local = 把 notes 改回 NULL
      await resolve(d, [{'conflictId': '${t['id']}', 'choice': 'local'}]);
      expect(rowOf('r1')!['notes'], isNull);
    });
  });

  group('拒绝与不伤害', () {
    test('merged 不带值 → rejected，冲突保持待裁决', () async {
      final token = pairDevice();
      final cid = openNameConflict(token: token);
      final res = await jsonOf(await resolve(token, [
        {'conflictId': cid, 'choice': 'merged'}
      ]));
      expect((res['results'] as List).cast<Map<String, dynamic>>().single['outcome'], 'rejected');
      expect(ticketOf(cid)['resolved_at'], isNull);
      expect(rowOf('r1')!['name'], '客户端改的',
          reason: '判冲突时服务端已按暂定 LWW 盖过章；rejected 的裁决不能再动这个值');
    });

    test('choice 不是三选一 → rejected', () async {
      final token = pairDevice();
      final cid = openNameConflict(token: token);
      final res = await jsonOf(await resolve(token, [
        {'conflictId': cid, 'choice': 'newer'}
      ]));
      expect((res['results'] as List).cast<Map<String, dynamic>>().single['outcome'], 'rejected');
      expect(ticketOf(cid)['resolved_at'], isNull);
    });

    test('未知 conflictId → not_found，不伤其它条目', () async {
      final token = pairDevice();
      final cid = openNameConflict(token: token);
      final res = await jsonOf(await resolve(token, [
        {'conflictId': 'NOPE000000000000000000NO', 'choice': 'local'},
        {'conflictId': cid, 'choice': 'remote'},
      ]));
      final outcomes =
          (res['results'] as List).cast<Map<String, dynamic>>().map((r) => r['outcome']).toList();
      expect(outcomes, ['not_found', 'applied']);
    });

    test('重复裁决 → 第二次 already_resolved，行不二次盖章', () async {
      final token = pairDevice();
      final cid = openNameConflict(token: token);
      await resolve(token, [
        {'conflictId': cid, 'choice': 'remote'}
      ]);
      final rev = rowOf('r1')!['rev'];
      final res = await jsonOf(await resolve(token, [
        {'conflictId': cid, 'choice': 'local'}
      ]));
      expect((res['results'] as List).cast<Map<String, dynamic>>().single['outcome'],
          'already_resolved');
      expect(rowOf('r1')!['rev'], rev, reason: '已归档的冲突再点不能把数据改回去');
      expect(rowOf('r1')!['name'], '客户端改的');
    });

    test('★ 业务行被裁没了（row_missing）→ 拒绝标记，冲突留在箱里可见', () async {
      final token = pairDevice();
      final cid = openNameConflict(token: token);
      state.db.db.execute("DELETE FROM recipe WHERE id='r1'");
      final res = await jsonOf(await resolve(token, [
        {'conflictId': cid, 'choice': 'remote'}
      ]));
      expect((res['results'] as List).cast<Map<String, dynamic>>().single['outcome'], 'row_missing');
      expect(ticketOf(cid)['resolved_at'], isNull);
    });

    test('★ field 被塞成五列（借裁决改 updated_at）→ rejected，一列都不动', () async {
      final token = pairDevice();
      final cid = openNameConflict(token: token);
      state.db.db.execute(
        "UPDATE conflict_item SET field='updated_at' WHERE id=?", [cid]);
      final before = rowOf('r1')!;
      final res = await jsonOf(await resolve(token, [
        {'conflictId': cid, 'choice': 'remote'}
      ]));
      expect((res['results'] as List).cast<Map<String, dynamic>>().single['outcome'], 'rejected');
      expect(rowOf('r1')!['updated_at'], before['updated_at']);
    });

    test('field 不在该表白名单（未知列）→ rejected', () async {
      final token = pairDevice();
      final cid = openNameConflict(token: token);
      state.db.db.execute(
        "UPDATE conflict_item SET field='secret_key' WHERE id=?", [cid]);
      final res = await jsonOf(await resolve(token, [
        {'conflictId': cid, 'choice': 'remote'}
      ]));
      expect((res['results'] as List).cast<Map<String, dynamic>>().single['outcome'], 'rejected');
    });
  });

  group('接口纪律', () {
    test('同一行的两个字段一次提交：都写进、都归档', () async {
      final d = pairDevice();
      final device = state.sync.authenticate('Bearer $d')!;
      state.sync.push(device: device, mutationId: 'a', changes: [
        {'tbl': 'recipe', 'rowId': 'r1', 'op': 'upsert',
         'row': recipeRow(id: 'r1', name: '服务端', notes: '服务端注意', hlc: 'h-2')}
      ]);
      state.sync.push(device: device, mutationId: 'b', changes: [
        {'tbl': 'recipe', 'rowId': 'r1', 'op': 'upsert',
         'row': recipeRow(id: 'r1', name: '客户端', notes: '客户端注意', hlc: 'h-3'),
         'base': recipeRow(id: 'r1', name: '原本', notes: '原注意', hlc: 'h-1')}
      ]);
      final ids = state.db.db
          .select("SELECT id FROM conflict_item WHERE row_id='r1' ORDER BY field")
          .map((r) => '${r['id']}')
          .toList();
      expect(ids, hasLength(2));

      final res = await jsonOf(await resolve(d, [
        {'conflictId': ids[0], 'choice': 'remote'},
        {'conflictId': ids[1], 'choice': 'remote'},
      ]));
      expect((res['results'] as List).cast<Map<String, dynamic>>(), hasLength(2));
      final row = rowOf('r1')!;
      expect(row['name'], '客户端');
      expect(row['notes'], '客户端注意');
    });

    test('pairCode 模式无 token → 401；open 模式来访者带 nodeId 可裁决', () async {
      state.sync.accessMode = SyncAccessMode.pairCode;
      var res = await call('POST', '/api/conflicts/resolve',
          body: {
            'items': [
              {'conflictId': 'x', 'choice': 'local'}
            ]
          });
      expect(res.statusCode, 401);

      state.sync.accessMode = SyncAccessMode.open;
      final tk = pairDevice();
      final cid = openNameConflict(token: tk); // 服务层直连，与准入模式无关
      res = await call('POST', '/api/conflicts/resolve',
          body: {
            'items': [
              {'conflictId': cid, 'choice': 'remote'}
            ]
          },
          nodeId: 'visitor00000001');
      expect(res.statusCode, 200);
      expect(ticketOf(cid)['resolved_at'], isNotNull,
          reason: '来访者本来就能推数据，裁决不比推数据更危险');
    });

    test('items 为空或形状不对 → 400', () async {
      final token = pairDevice();
      expect((await call('POST', '/api/conflicts/resolve',
              body: {'items': []}, token: token)).statusCode, 400);
      expect((await call('POST', '/api/conflicts/resolve',
              body: {'items': 'nope'}, token: token)).statusCode, 400);
      expect((await call('POST', '/api/conflicts/resolve',
              body: {}, token: token)).statusCode, 400);
    });

    test('★ 裁决后的回声重推不能再开一条冲突（R22 客户端测试挖出的真 bug）', () async {
      // 水位线设计的已知副作用：拉回来的行会被"再推一遍"。R21 之前这无害
      // （内容一致 → skipped），但裁决把服务端行改成了定稿值——客户端手里
      // 那份旧回声内容不再一致 + 无 base → 保守判定会把刚裁完的冲突**再开一遍**。
      final token = pairDevice();
      final cid = openNameConflict(token: token);
      final dev = state.sync.authenticate('Bearer $token')!;
      // 客户端此刻持有的版本（裁决前的服务端盖章行）
      final echoed = Map<String, Object?>.from(rowOf('r1')!);

      await resolve(token, [
        {'conflictId': cid, 'choice': 'remote'}
      ]);

      final r = state.sync.push(device: dev, mutationId: 'echo', changes: [
        {'tbl': 'recipe', 'rowId': 'r1', 'op': 'upsert', 'row': echoed}
      ]);
      expect(r.results.single['outcome'], 'skipped',
          reason: 'updated_at 是本服务端盖的章且不更新 → 回声，不进冲突判定');
      expect(
          state.db.db.select(
              "SELECT id FROM conflict_item WHERE row_id='r1' AND resolved_at IS NULL"),
          isEmpty,
          reason: '裁决成果不能被回声顶回冲突箱');
      expect(rowOf('r1')!['name'], '客户端改的');
    });
  });
}
