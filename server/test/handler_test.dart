import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:zaoji_server/zaoji_server.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// 路由层测试。
///
/// 刻意**不监听端口**——`ZaojiServer.buildHandler` 就是为这件事抽出来的：
/// 直接把 `Request` 喂给 handler，断言 `Response`。
/// 这样测试毫秒级完成，也不会因为端口被占用而随机失败。
void main() {
  late Directory tmp;
  late ServerState state;
  late Handler handler;

  ServerConfig configWith({Directory? webRoot}) => ServerConfig(
        host: '127.0.0.1',
        port: 18666,
        tlsPort: 18667,
        dataDir: Directory('${tmp.path}${Platform.pathSeparator}data'),
        certDir: Directory('${tmp.path}${Platform.pathSeparator}certs'),
        webRoot: webRoot,
      );

  /// 本测试文件里 boot 出来的所有 state。**每一个都必须关** ——
  /// state 里拿着 SQLite 句柄（含 -wal/-shm），漏关一个，
  /// Windows 上临时目录就删不掉，报「另一个程序正在使用此文件」。
  /// 之前就踩过：有几处测试自己多 boot 了一个 state 没关。
  final booted = <ServerState>[];

  Future<ServerState> bootState(ServerConfig cfg) async {
    final s = await ServerState.boot(cfg);
    booted.add(s);
    return s;
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zaoji_srv_test_');
    state = await bootState(configWith());
    handler = ZaojiServer.buildHandler(state, const ['192.168.1.10']);
  });

  tearDown(() async {
    for (final s in booted) {
      await s.close(); // close() 可重复调用
    }
    booted.clear();
    if (await tmp.exists()) {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {
        // 删不掉也不是测试失败：临时目录由系统清理。
        // 但如果是句柄泄漏，上面那条注释会提醒下一个人去哪儿找。
      }
    }
  });

  Future<Response> hit(String method, String path) => Future.value(
      handler(Request(method, Uri.parse('http://localhost$path'))));

  Future<Map<String, dynamic>> jsonOf(Response res) async =>
      (jsonDecode(await res.readAsString()) as Map).cast<String, dynamic>();

  group('GET /api/ping', () {
    test('返回服务标识、版本、serverId 与时间', () async {
      final res = await hit('GET', '/api/ping');
      expect(res.statusCode, 200);

      final body = await jsonOf(res);
      expect(body['ok'], isTrue);
      expect(body['service'], 'zaoji');
      expect(body['version'], ServerConfig.version);
      expect(body['serverId'], state.serverId);

      // App 端拿 epochMs 做时钟校正，必须是数字且接近现在
      final epochMs = body['epochMs'] as int;
      expect((DateTime.now().millisecondsSinceEpoch - epochMs).abs(),
          lessThan(60000));
    });

    test('JSON 带缩进（因为人会在浏览器里直接看它）', () async {
      final res = await hit('GET', '/api/ping');
      final text = await res.readAsString();
      expect(text.contains('\n'), isTrue);
    });
  });

  group('GET /api/health', () {
    test('报告磁盘可写、运行时长与端点清单', () async {
      final res = await hit('GET', '/api/health');
      expect(res.statusCode, 200);

      final body = await jsonOf(res);
      expect(body['ok'], isTrue);
      expect(body['dataDirWritable'], isTrue);
      expect(body['uptimeMs'], isA<int>());
      expect(body['tlsReady'], isFalse); // 测试环境没有证书
      final endpoints = body['endpoints'] as List;
      expect(endpoints, isNotEmpty);
    });
  });

  group('状态页', () {
    test('GET /status 返回 HTML', () async {
      final res = await hit('GET', '/status');
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], contains('text/html'));
      final html = await res.readAsString();
      expect(html, contains('灶记 ZAOJI'));
      expect(html, contains(state.serverId));
    });

    test('未提供 Web 产物时，/ 回落到状态页', () async {
      final res = await hit('GET', '/');
      expect(res.statusCode, 200);
      expect(await res.readAsString(), contains('服务正在运行'));
    });

    test('状态页会写出局域网地址', () async {
      final res = await hit('GET', '/status');
      final html = await res.readAsString();
      expect(html, contains('192.168.1.10'));
    });

    test('未启用 HTTPS 时给出明确警告（而不是默默降级）', () async {
      final res = await hit('GET', '/status');
      final html = await res.readAsString();
      expect(html, contains('未启用 HTTPS'));
      expect(html, contains('屏幕常亮'));
    });
  });

  group('数据底座', () {
    test('★ /api/health 报告数据库状态（版本、schema、路径、行数）', () async {
      final res = await hit('GET', '/api/health');
      final body = await jsonOf(res);
      final db = (body['db'] as Map).cast<String, dynamic>();

      expect('${db['sqliteVersion']}', isNotEmpty, reason: '要知道用的是哪个 SQLite');
      expect(db['schemaVersion'], kSchemaVersion);
      expect(db['schemaVersionInDb'], kSchemaVersion);
      expect('${db['path']}', endsWith('zaoji.db'));
      expect(db['maxSeq'], 0, reason: '全新的库还没有任何变更');
      expect((db['rowCounts'] as Map).keys, contains('recipe'));
    });

    test('★ 状态页会列出数据表，并显示 SQLite 版本', () async {
      final res = await hit('GET', '/status');
      final html = await res.readAsString();

      expect(html, contains('recipe'));
      expect(html, contains('冲突箱'));
      expect(html, contains('SQLite'));
      expect(html, contains('schema v'));
    });

    test('★★ 状态页绝不出现本机私有的 ai_* 表（API Key 就在那里）', () async {
      // rowCounts 只统计业务表，所以 ai_config 不该出现在页面上。
      // 这条断言把「Key 不会从状态页漏出去」这个保证钉住。
      final res = await hit('GET', '/status');
      final html = await res.readAsString();

      expect(html, isNot(contains('ai_config')));
      expect(html, isNot(contains('ai_cache')));
      expect(html, isNot(contains('api_key')));
    });

    test('health 里也不列出本机私有表', () async {
      final res = await hit('GET', '/api/health');
      final body = await jsonOf(res);
      final counts = (body['db'] as Map)['rowCounts'] as Map;

      for (final t in localOnlyTables) {
        expect(counts.keys, isNot(contains(t)), reason: '$t 不该出现在健康检查里');
      }
    });
  });

  group('404', () {
    test('未知 GET 返回 HTML 404', () async {
      final res = await hit('GET', '/nope');
      expect(res.statusCode, 404);
      expect(res.headers['content-type'], contains('text/html'));
    });

    test('未知 API 返回 JSON 404（客户端要能解析）', () async {
      final res = await hit('POST', '/api/nope');
      expect(res.statusCode, 404);
      final body = await jsonOf(res);
      expect(body['ok'], isFalse);
      expect(body['code'], 'NOT_FOUND');
    });
  });

  group('托管 Flutter Web 产物', () {
    late Directory webRoot;

    setUp(() async {
      webRoot = Directory('${tmp.path}${Platform.pathSeparator}web')
        ..createSync(recursive: true);
      File('${webRoot.path}${Platform.pathSeparator}index.html')
          .writeAsStringSync('<html><body>FLUTTER_WEB_INDEX</body></html>');
      Directory('${webRoot.path}${Platform.pathSeparator}assets')
          .createSync(recursive: true);
      File('${webRoot.path}${Platform.pathSeparator}assets'
              '${Platform.pathSeparator}main.dart.js')
          .writeAsStringSync('console.log(1)');

      state = await bootState(configWith(webRoot: webRoot));
      handler = ZaojiServer.buildHandler(state, const ['192.168.1.10']);
    });

    test('/ 返回 Web 产物而不是状态页', () async {
      final res = await hit('GET', '/');
      expect(await res.readAsString(), contains('FLUTTER_WEB_INDEX'));
    });

    test('assets 能取到，且带长缓存', () async {
      final res = await hit('GET', '/assets/main.dart.js');
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], contains('javascript'));
      expect(res.headers['cache-control'], contains('max-age'));
    });

    test('★ index.html 必须不缓存', () async {
      // 这条不在就会出大事故：发新版本后，缓存住的旧 index
      // 会去拉已经不存在的旧 assets，页面直接白屏。
      final res = await hit('GET', '/');
      expect(res.headers['cache-control'], contains('no-cache'));
    });

    test('★ SPA 回退：深层路径刷新要回 index.html', () async {
      final res = await hit('GET', '/recipe/detail/r1');
      expect(res.statusCode, 200);
      expect(await res.readAsString(), contains('FLUTTER_WEB_INDEX'));
    });

    test('★ 目录穿越拿不到数据目录里的文件', () async {
      final res = await hit('GET', '/../data/server_id');
      expect(res.statusCode, anyOf(200, 404));
      final body = await res.readAsString();
      expect(body, isNot(contains(state.serverId)),
          reason: '绝不能把 server_id 通过静态文件路径泄露出去');
    });

    test('API 路径不会走 SPA 回退', () async {
      final res = await hit('GET', '/api/nope');
      expect(res.statusCode, 404);
    });
  });

  group('serverId 持久化', () {
    test('同一数据目录重启后 id 不变（客户端靠它识别是不是同一台服务器）', () async {
      final cfg = configWith();
      final a = await bootState(cfg);
      final b = await bootState(cfg);
      expect(b.serverId, a.serverId);
    });

    test('不同数据目录是不同 id', () async {
      final a = await bootState(configWith());
      final other = Directory('${tmp.path}${Platform.pathSeparator}other')
        ..createSync(recursive: true);
      final b = await bootState(ServerConfig(
        host: '127.0.0.1',
        port: 1,
        tlsPort: 2,
        dataDir: other,
        certDir: Directory('${tmp.path}${Platform.pathSeparator}certs'),
      ));
      expect(b.serverId, isNot(a.serverId));
    });
  });

  // ══════════════════════ 同步接口（HTTP 层）══════════════════════

  group('同步接口', () {
    // R21 起默认模式是 open，这一组测的全部是「配对码」路径的既有契约——
    // 先把准入切回 pairCode，别外组的新语义混进来。
    setUp(() {
      state.sync.accessMode = SyncAccessMode.pairCode;
    });

    /// 带 body / token 的请求。测试里没有真实连接信息，
    /// 所以 `_isLocalRequest` 会按本机处理（见 server.dart 里的说明）。
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

    /// 走一遍配对，拿到能用的 token。
    Future<String> pairUp({String deviceId = 'phone-1'}) async {
      final codeRes = await call('GET', '/api/pair/code');
      expect(codeRes.statusCode, 200);
      final code = (await jsonOf(codeRes))['code'] as String;

      final pairRes = await call('POST', '/api/pair', body: {
        'code': code,
        'deviceId': deviceId,
        'deviceName': '测试手机',
      });
      expect(pairRes.statusCode, 200);
      return (await jsonOf(pairRes))['token'] as String;
    }

    /// 一份**完整的** recipe 行。
    ///
    /// 协议要求 upsert 带完整行（缺列会被拒，因为"缺"与"改成 null"分不清），
    /// 所以测试也得发完整的——真实客户端从自己表里读出来本来就是全的。
    Map<String, Object?> fullRecipe({
      required String id,
      String name = '番茄炒蛋',
      String hlc = 'h-1',
    }) =>
        {
          'id': id,
          'updated_at': hlc,
          'updated_by': 'phone-1',
          'rev': 1,
          'deleted_at': null,
          'name': name,
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

    test('GET /api/pair/code 给出码与过期时间', () async {
      final res = await call('GET', '/api/pair/code');
      expect(res.statusCode, 200);
      final body = await jsonOf(res);

      expect(body['code'], hasLength(6));
      expect(body['ttlSeconds'], SyncService.pairCodeTtl.inSeconds);
      expect(body['serverId'], state.serverId);
      expect(body['protocolVersion'], kSyncProtocolVersion);
      expect(DateTime.tryParse('${body['expiresAt']}'), isNotNull);
    });

    test('POST /api/pair 用码换到 token', () async {
      final token = await pairUp();
      expect(token, isNotEmpty);
    });

    test('码错 → 403；缺参数 → 400', () async {
      var res = await call('POST', '/api/pair',
          body: {'code': 'ZZZZZZ', 'deviceId': 'd', 'deviceName': 'x'});
      expect(res.statusCode, 403);
      // 一个 Response 的 body 只能读一次，所以先读出来再断言两次
      final bad = await jsonOf(res);
      expect(bad['error'], PairFailure.unknownCode.name);
      expect('${bad['message']}', contains('配对码'));

      res = await call('POST', '/api/pair',
          body: {'deviceId': 'd', 'deviceName': 'x'});
      expect(res.statusCode, 400, reason: '参数缺失是客户端 bug，不是"码不对"');
      expect((await jsonOf(res))['error'], PairFailure.emptyCode.name);
    });

    test('配对请求体不是 JSON → 400', () async {
      final res = await Future.value(handler(Request(
        'POST',
        Uri.parse('http://localhost/api/pair'),
        body: '这不是 JSON',
      )));
      expect(res.statusCode, 400);
      expect((await jsonOf(res))['error'], 'bad_request');
    });

    test('★ 没 token 拉不到任何数据', () async {
      final res = await call('GET', '/api/changes');
      expect(res.statusCode, 401);
      final body = await jsonOf(res);
      expect(body['error'], 'unauthorized');
      expect(body['message'], contains('配对'));
    });

    test('★ 没 token 也推不进任何数据', () async {
      final res = await call('POST', '/api/changes',
          body: {'mutationId': 'm1', 'changes': []});
      expect(res.statusCode, 401);
      expect((await jsonOf(res))['error'], 'unauthorized');
    });

    test('错的 token 一样挡住', () async {
      final res = await call('GET', '/api/changes', token: '随便编一个');
      expect(res.statusCode, 401);
    });

    test('GET /api/changes 空库返回 0 条与游标', () async {
      final token = await pairUp();
      final res = await call('GET', '/api/changes?since=0', token: token);
      expect(res.statusCode, 200);

      final body = await jsonOf(res);
      expect(body['count'], 0);
      expect(body['nowSeq'], 0);
      expect(body['hasMore'], isFalse);
      expect(body['serverId'], state.serverId);
    });

    test('since 不是数字 → 400（而不是当成 0 悄悄全量拉一遍）', () async {
      final token = await pairUp();
      final res = await call('GET', '/api/changes?since=abc', token: token);
      expect(res.statusCode, 400);
    });

    test('limit 会被夹到合理范围', () async {
      final token = await pairUp();
      // 只是确认它不报错，且不会因为 limit 巨大而失控
      final res =
          await call('GET', '/api/changes?since=0&limit=99999', token: token);
      expect(res.statusCode, 200);
      final res2 =
          await call('GET', '/api/changes?since=0&limit=0', token: token);
      expect(res2.statusCode, 200);
    });

    test('★★ 完整来回：配对 → 推一条菜谱 → 另一端从 0 拉起', () async {
      final phone = await pairUp(deviceId: 'phone-1');
      final ipad = await pairUp(deviceId: 'ipad-1');

      final push = await call('POST', '/api/changes', token: phone, body: {
        'mutationId': 'm-001',
        'protocolVersion': kSyncProtocolVersion,
        'changes': [
          {
            'tbl': 'recipe',
            'rowId': 'r1',
            'op': 'upsert',
            'row': fullRecipe(id: 'r1')
          },
        ],
      });
      expect(push.statusCode, 200);
      final pushBody = await jsonOf(push);
      expect(pushBody['applied'], 1);
      expect(pushBody['replayed'], isFalse);

      final pull = await call('GET', '/api/changes?since=0', token: ipad);
      final pullBody = await jsonOf(pull);
      expect(pullBody['count'], 1);

      final change = (pullBody['changes'] as List).single as Map;
      expect(change['tbl'], 'recipe');
      expect(change['op'], 'upsert');
      final row = (change['row'] as Map).cast<String, dynamic>();
      expect(row['name'], '番茄炒蛋');
      expect(row['difficulty'], 2);
      // 载荷的列严格等于白名单 —— 这条在服务层也测了，这里确认 HTTP 传输没丢字段
      expect(row.keys.toSet(), syncWhitelist['recipe']!.toSet());
    });

    test('★★ 重放同一个 mutationId：HTTP 层也返回 replayed', () async {
      final token = await pairUp();
      final payload = {
        'mutationId': 'm-same',
        'changes': [
          {
            'tbl': 'recipe',
            'rowId': 'r1',
            'op': 'upsert',
            'row': fullRecipe(id: 'r1', name: 'X')
          },
        ],
      };

      final a = await jsonOf(
          await call('POST', '/api/changes', token: token, body: payload));
      final b = await jsonOf(
          await call('POST', '/api/changes', token: token, body: payload));

      expect(a['replayed'], isFalse);
      expect(b['replayed'], isTrue);
      expect(b['results'], a['results']);
    });

    test('★ 协议版本不一致 → 409，并且明确告诉客户端服务端是几版', () async {
      final token = await pairUp();
      final res = await call('POST', '/api/changes', token: token, body: {
        'mutationId': 'm',
        'protocolVersion': 999,
        'changes': [],
      });

      expect(res.statusCode, 409, reason: '猜错的后果是字段永远同步不上还不报错');
      final body = await jsonOf(res);
      expect(body['error'], 'protocol_mismatch');
      expect(body['serverProtocolVersion'], kSyncProtocolVersion);
    });

    test('changes 不是数组 / 元素不是对象 → 400', () async {
      final token = await pairUp();
      var res = await call('POST', '/api/changes',
          token: token, body: {'mutationId': 'm', 'changes': '不是数组'});
      expect(res.statusCode, 400);

      res = await call('POST', '/api/changes', token: token, body: {
        'mutationId': 'm',
        'changes': ['不是对象']
      });
      expect(res.statusCode, 400);
    });

    test('缺 mutationId → 400（没有它就没有幂等）', () async {
      final token = await pairUp();
      final res = await call('POST', '/api/changes',
          token: token, body: {'changes': []});
      expect(res.statusCode, 400);
      expect((await jsonOf(res))['message'], contains('mutationId'));
    });

    test('★ 未登记的表与未登记的列，都通过 HTTP 被拒', () async {
      final token = await pairUp();
      final res = await call('POST', '/api/changes', token: token, body: {
        'mutationId': 'm',
        'changes': [
          {
            'tbl': 'device',
            'rowId': 'd',
            'op': 'upsert',
            'row': {'id': 'd'}
          },
          {
            'tbl': 'recipe',
            'rowId': 'r1',
            'op': 'upsert',
            'row': {
              'id': 'r1',
              'updated_at': 'h',
              'updated_by': 'p',
              'api_key_enc': 'sk-leak'
            },
          },
        ],
      });

      expect(res.statusCode, 200, reason: '坏条目逐条报告，不让整批陪着失败');
      final results = (await jsonOf(res))['results'] as List;
      expect(results[0]['outcome'], 'rejected');
      expect(results[1]['outcome'], 'rejected');
      expect('${results[1]['reason']}', contains('api_key_enc'));
    });

    test('推送的响应里不含任何 token 或密钥', () async {
      final token = await pairUp();
      final res = await call('POST', '/api/changes', token: token, body: {
        'mutationId': 'm',
        'changes': [
          {
            'tbl': 'recipe',
            'rowId': 'r1',
            'op': 'upsert',
            'row': fullRecipe(id: 'r1', name: 'X')
          },
        ],
      });
      expect(res.statusCode, 200);
      final body = await jsonOf(res);
      expect(body['applied'], 1, reason: '先确认这条是真写进去了，否则等于没测');

      final text = jsonEncode(body);
      expect(text, isNot(contains(token)));
      expect(text, isNot(contains('token')));
    });

    test('★★ 状态页绝不显示配对码（这个页面在局域网里谁都能打开）', () async {
      final code =
          (await jsonOf(await call('GET', '/api/pair/code')))['code'] as String;

      final html = await (await hit('GET', '/status')).readAsString();
      expect(html, isNot(contains(code)));
      expect(html, contains('/api/pair/code'), reason: '但要告诉人去哪儿取');
    });

    test('配对之后状态页会列出设备', () async {
      await pairUp(deviceId: 'phone-1');

      final html = await (await hit('GET', '/status')).readAsString();
      expect(html, contains('测试手机'));
      expect(html, contains('phone-1'));
      expect(html, isNot(contains('还没有设备配对过')));
    });
    group('R12：安全加固（HTTP 层）', () {
      test('★ 请求体超过 5 MB → 413（流式读取中途截断，不信声明的头）', () async {
        final token = await pairUp();
        // 用真实字节流而不是伪造 Content-Length——不能信客户端自己报的数
        final huge = List<int>.filled(6 * 1024 * 1024, 0x61); // 6 MB of 'a'
        final res = await Future.value(handler(Request(
          'POST',
          Uri.parse('http://localhost/api/changes'),
          headers: {
            'authorization': 'Bearer $token',
            'content-type': 'application/json',
          },
          body: Stream<List<int>>.value(huge),
        )));

        expect(res.statusCode, 413);
        expect((await jsonOf(res))['error'], 'payload_too_large');
      });

      test('★ 一批超过 500 条变更 → 400', () async {
        final token = await pairUp();
        final res = await call('POST', '/api/changes', token: token, body: {
          'mutationId': 'm',
          'changes': List.generate(501, (_) => <String, Object?>{}),
        });

        expect(res.statusCode, 400);
        expect((await jsonOf(res))['message'], contains('500'));
      });

      test('★ 配对失败满 5 次 → 429（挡住局域网内的暴力枚举）', () async {
        for (var i = 0; i < 5; i++) {
          final res = await call('POST', '/api/pair',
              body: {'code': 'WRONG$i', 'deviceId': 'd', 'deviceName': 'x'});
          expect(res.statusCode, 403, reason: '前 5 次正常返回「码不对」');
        }

        final blocked = await call('POST', '/api/pair',
            body: {'code': 'WRONG5', 'deviceId': 'd', 'deviceName': 'x'});
        expect(blocked.statusCode, 429, reason: '码空间 8.9 亿，不限流就能在窗口内枚举完');
        final body = await jsonOf(blocked);
        expect(body['error'], 'too_many_attempts');
        expect(blocked.headers['retry-after'], '60');
      });

      test('参数残缺（400 类）不计入限流失败——那是客户端 bug，不是猜测', () async {
        for (var i = 0; i < 7; i++) {
          final res = await call('POST', '/api/pair', body: {'deviceId': 'd'});
          expect(res.statusCode, 400);
        }
        // 400 刷了 7 次之后，一次真实的码错仍是 403 而不是 429
        final res = await call('POST', '/api/pair',
            body: {'code': 'WRONG1', 'deviceId': 'd', 'deviceName': 'x'});
        expect(res.statusCode, 403);
      });

      test('mutationId 超长 → 400（它是幂等表的主键，不能被超长串灌爆）', () async {
        final token = await pairUp();
        final res = await call('POST', '/api/changes', token: token, body: {
          'mutationId': 'x' * 129,
          'changes': [],
        });
        expect(res.statusCode, 400);
        expect((await jsonOf(res))['message'], contains('mutationId'));
      });
    });
  });
}
