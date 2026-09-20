import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart'; // setUp 已 boot 过 state，加载器就绪
import 'package:test/test.dart';
import 'package:zaoji_server/zaoji_server.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// R21 · 来访者同步准入三态（open / passcode / pairCode）。
///
/// 断言的重心是**那扇门**：
/// ① 默认必须是开放（产品的「打开就能用」立场）；
/// ② 切模式不能把已持有 token 的设备关在门外；
/// ③ 模式不匹配的入口一律 409，**绝不悄悄兼容**；
/// ④ 口令只进不出——任何接口的响应里都不许出现口令本身。
void main() {
  late Directory tmp;
  late ServerState state;
  late Handler handler;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zaoji_access_');
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
      } catch (_) {/* Windows 句柄未放开的兜底，见 handler_test 的注释 */}
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

  Map<String, Object?> fullRecipe({required String id, String by = 'node-v'}) =>
      {
        'id': id,
        'updated_at': 'hlc-$id',
        'updated_by': by,
        'rev': 1,
        'deleted_at': null,
        'name': '口令测试菜',
        'sub': null,
        'art': null,
        'pal': null,
        'difficulty': 2,
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
      };

  group('默认与查询', () {
    test('★ 默认模式是 open（免配对），且新库的开关处于出厂态', () {
      expect(state.sync.accessMode, SyncAccessMode.open);
      expect(state.sync.visitorManualSync, isFalse);
      expect(state.sync.passcode, isNull);
    });

    test('GET /api/sync/config 免鉴权可查，但响应里绝不含口令', () async {
      state.sync.setPasscode('kitchen-2026');
      final res = await call('GET', '/api/sync/config');
      expect(res.statusCode, 200);
      final body = await jsonOf(res);
      expect(body['accessMode'], 'open');
      expect(body['visitorManualSync'], isFalse);
      expect(body['serverId'], state.serverId);
      expect(jsonEncode(body), isNot(contains('kitchen-2026')));
    });
  });

  group('open 模式的匿名来访者', () {
    test('带合法 X-Node-Id 的匿名 pull 能拿到数据，并自动登记来访者设备', () async {
      final res = await call('GET', '/api/changes', nodeId: '01VISITOR001');
      expect(res.statusCode, 200);
      final body = await jsonOf(res);
      expect(body['serverId'], state.serverId);

      final d = state.sync.devices().firstWhere((x) => x.id == '01VISITOR001');
      expect(d.visitor, isTrue, reason: '状态页要能区分这是来访者不是配对设备');
    });

    test('匿名 push 落库；同一 nodeId 重连不清游标不清名', () async {
      final push = await call('POST', '/api/changes', nodeId: '01VISITOR002', body: {
        'protocolVersion': kSyncProtocolVersion,
        'mutationId': 'm-open-1',
        'changes': [
          {
            'tbl': 'recipe',
            'rowId': 'rx1',
            'op': 'upsert',
            'row': fullRecipe(id: 'rx1', by: '01VISITOR002')
          }
        ],
      });
      expect(push.statusCode, 200);
      final pb = await jsonOf(push);
      expect(pb['results'], isList);

      // 重连：第一次请求登记的游标/名字不能被后面的 visitorDevice 复建覆盖
      state.sync.noteCursor('01VISITOR002', 42);
      final again = await call('GET', '/api/changes', nodeId: '01VISITOR002');
      expect(again.statusCode, 200);
      final d = state.sync.devices().firstWhere((x) => x.id == '01VISITOR002');
      expect(d.syncCursor, 42, reason: '伪设备复用既有游标机制，重连必须原样');
    });

    test('缺 X-Node-Id 或格式不对 → 401，且提示说的是开放模式', () async {
      var res = await call('GET', '/api/changes');
      expect(res.statusCode, 401);
      expect((await jsonOf(res))['accessMode'], 'open');

      res = await call('GET', '/api/changes', nodeId: '短');
      expect(res.statusCode, 401);

      res = await call('GET', '/api/changes', nodeId: 'a' * 65);
      expect(res.statusCode, 401, reason: '超长 id 是灌库向量，不是设备标识');
    });

    test('匿名 media GET 走的也是同一扇门：不再是 401 而是按业务答 404', () async {
      final sha = 'a' * 64;
      final res = await call('GET', '/api/media/$sha', nodeId: '01VISITOR003');
      expect(res.statusCode, 404);
    });
  });

  group('模式闸门（三态互斥）', () {
    test('open 模式下配对码入口 409——悄悄兼容等于口令白设', () async {
      final res = await call('GET', '/api/pair/code');
      expect(res.statusCode, 409);
      expect((await jsonOf(res))['error'], 'mode_mismatch');

      final pair = await call('POST', '/api/pair',
          body: {'code': 'ABC234', 'deviceId': 'd1', 'deviceName': 'x'});
      expect(pair.statusCode, 409);
    });

    test('切到 pairCode 后原有配对全流程恢复可用', () async {
      state.sync.accessMode = SyncAccessMode.pairCode;
      final codeRes = await call('GET', '/api/pair/code');
      expect(codeRes.statusCode, 200);
      final code = (await jsonOf(codeRes))['code'] as String;

      final res = await call('POST', '/api/pair',
          body: {'code': code, 'deviceId': 'd1', 'deviceName': '配对机'});
      expect(res.statusCode, 200);
      expect(state.sync.devices().first.name, '配对机');
    });

    test('非口令模式下 /api/join 409；口令模式下才受理', () async {
      final gate = await call('POST', '/api/join',
          body: {'passcode': 'x', 'deviceId': '01VISITOR00A'});
      expect(gate.statusCode, 409);
    });
  });

  group('passcode 模式', () {
    setUp(() {
      state.sync.accessMode = SyncAccessMode.passcode;
      state.sync.setPasscode('mama-2026');
    });

    test('匿名请求 401，提示让人去输口令', () async {
      final res = await call('GET', '/api/changes', nodeId: '01VISITOR004');
      expect(res.statusCode, 401);
      final body = await jsonOf(res);
      expect(body['message'], contains('口令'));
      expect(body['accessMode'], 'passcode');
    });

    test('口令对 → 拿到本机专属 token，之后同步走 token 通道', () async {
      final res = await call('POST', '/api/join', body: {
        'passcode': 'mama-2026',
        'deviceId': '01VISITOR005',
        'deviceName': '厨房平板',
      });
      expect(res.statusCode, 200);
      final body = await jsonOf(res);
      final token = body['token'] as String;
      expect(token, isNotEmpty);
      expect(jsonEncode(body), isNot(contains('mama-2026')),
          reason: 'join 响应也不该把口令再吐一遍');

      final pull = await call('GET', '/api/changes', token: token);
      expect(pull.statusCode, 200);
      final d = state.sync.devices().firstWhere((x) => x.id == '01VISITOR005');
      expect(d.visitor, isTrue);
      expect(d.name, '厨房平板');
    });

    test('口令错 → 403；连错 5 次第 6 次 → 429（与配对码分开计额度）', () async {
      for (var i = 0; i < SyncService.maxPairFailsPerWindow; i++) {
        final res = await call('POST', '/api/join', body: {
          'passcode': 'wrong-$i',
          'deviceId': '01VISITOR006',
        });
        expect(res.statusCode, 403);
      }
      final blocked = await call('POST', '/api/join',
          body: {'passcode': 'mama-2026', 'deviceId': '01VISITOR006'});
      expect(blocked.statusCode, 429);
    });

    test('参数残缺 400 不占失败额度（那是客户端 bug 不是猜测）', () async {
      for (var i = 0; i < 6; i++) {
        final res = await call('POST', '/api/join', body: {'deviceId': 'x'});
        expect(res.statusCode, 400);
      }
      final ok = await call('POST', '/api/join',
          body: {'passcode': 'mama-2026', 'deviceId': '01VISITOR007'});
      expect(ok.statusCode, 200);
    });

    test('服务端没设口令 → 503，话说清楚是服务端的事', () async {
      state.sync.setPasscode(null);
      final res = await call('POST', '/api/join',
          body: {'passcode': 'any', 'deviceId': '01VISITOR008'});
      expect(res.statusCode, 503);
      expect((await jsonOf(res))['error'], PairFailure.passcodeNotSet.name);
    });
  });

  group('已配对设备与模式切换', () {
    test('★ token 在任何模式下都不受影响：open→passcode→pairCode 一路 200', () async {
      // 用服务层直接配一台（绕开模式闸门，模拟"历史上配过对"）
      final code = state.sync.issuePairCode();
      final outcome = state.sync.redeem(
          code: code.code, deviceId: 'phone-old', deviceName: '老配对机');
      final token = outcome.token!;

      for (final m in SyncAccessMode.values) {
        state.sync.accessMode = m;
        final res = await call('GET', '/api/changes', token: token);
        expect(res.statusCode, 200, reason: '$m 模式下不该把老设备关在门外');
      }
    });
  });

  group('admin settings（仅本机）', () {
    test('GET 只回摘要；POST 改模式/开关；口令只进不出', () async {
      final g = await jsonOf(await call('GET', '/api/admin/settings'));
      expect(g['accessMode'], 'open');
      expect(g['hasPasscode'], isFalse);

      final p = await call('POST', '/api/admin/settings', body: {
        'accessMode': 'passcode',
        'passcode': 'hello-family',
        'visitorManualSync': true,
      });
      expect(p.statusCode, 200);
      final body = await jsonOf(p);
      expect(body['accessMode'], 'passcode');
      expect(body['hasPasscode'], isTrue);
      expect(body['visitorManualSync'], isTrue);
      expect(jsonEncode(body), isNot(contains('hello-family')),
          reason: '响应里出现口令 = 状态页截屏泄露');
      expect(state.sync.accessMode, SyncAccessMode.passcode);
    });

    test('★ 认不出的 accessMode → 400 且模式原样不动（打错字不能变成"门开了"）', () async {
      state.sync.accessMode = SyncAccessMode.passcode;
      final res = await call('POST', '/api/admin/settings',
          body: {'accessMode': 'opne'}); // 手滑打错
      expect(res.statusCode, 400);
      expect(state.sync.accessMode, SyncAccessMode.passcode);
    });

    test('/api/health 报准入摘要，不含口令', () async {
      state.sync.setPasscode('s3cr3t-code');
      final h = await jsonOf(await call('GET', '/api/health'));
      expect(h['access']['mode'], 'open');
      expect(h['access']['hasPasscode'], isTrue);
      expect(jsonEncode(h), isNot(contains('s3cr3t-code')));
    });
  });

  group('状态页', () {
    test('来访者视角：只读摘要，没有编辑控件；设备区区分类型', () async {
      final html = await statusPageHtml(state, const ['192.168.31.9']);
      expect(html, contains('免配对开放'));
      expect(html, isNot(contains('saveAccess')),
          reason: '非本机请求渲染出编辑控件是 UI 层面先泄露了门的存在');
    });

    test('本机视角：出现编辑控件', () async {
      final html =
          await statusPageHtml(state, const ['192.168.31.9'], isAdmin: true);
      expect(html, contains('saveAccess'));
      expect(html, contains('来访者必须手动同步'));
    });
  });

  group('迁移', () {
    test('★ v3 旧库（device 没有 visitor 列）开新版本程序 → 补列 + 新表可用', () {
      final oldFile =
          '${tmp.path}${Platform.pathSeparator}legacy_v3.db';
      // 手工造一张"上一版形状"的 device 表 + 老版本号
      final raw = sqlite3.open(oldFile);
      raw.execute('CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
      raw.execute("INSERT INTO meta VALUES ('schema_version', '3')");
      raw.execute('CREATE TABLE device ('
          'id TEXT PRIMARY KEY, name TEXT NOT NULL, token_hash TEXT NOT NULL, '
          'sync_cursor INTEGER NOT NULL DEFAULT 0, paired_at TEXT NOT NULL, '
          'last_seen_at TEXT, revoked_at TEXT)');
      raw.execute('INSERT INTO device '
          '(id, name, token_hash, sync_cursor, paired_at, last_seen_at, revoked_at) '
          "VALUES ('old-1', '老设备', 'x', 7, '昨天', NULL, NULL)");
      raw.dispose();

      final db = ZaojiDb.open(oldFile);
      try {
        expect(db.schemaVersionInDb, kSchemaVersion);
        final rows = db.db
            .select('SELECT id, visitor, sync_cursor FROM device WHERE id = ?',
                ['old-1']);
        expect(rows.single['visitor'], 0, reason: '老设备默认不是来访者');
        expect(rows.single['sync_cursor'], 7, reason: '迁移不许动游标');
        expect(
            db.db
                .select(
                    "SELECT 1 FROM sqlite_master WHERE name = 'server_setting'")
                .isNotEmpty,
            isTrue);
      } finally {
        db.close();
      }
    });
  });
}
