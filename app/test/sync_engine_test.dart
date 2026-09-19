import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/sync/sync_engine.dart';
import 'package:zaoji/data/sync/sync_prefs.dart';
import 'package:zaoji/data/sync/sync_transport.dart';
import 'package:zaoji/data/seed.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// 同步引擎测试。
///
/// ⚠️ **为什么不用真服务端**：zaoji_server 锁 sqlite3 ^2.x（sqlite_loader 依赖
/// 已被 3.x 移除的 open.overrideFor），app 需要 ^3.x，版本解算冲突（R11 已知事项）。
/// 所以这里起一个**测试内的 HTTP 模拟服务端**（dart:io HttpServer），
/// 走**真 HTTP + 真协议形状**（配对 / 鉴权 / 幂等 / seq 游标 / 载荷跟随），
/// 引擎代码零 mock。服务端的正确性由 server 自己的 138 个测试保证；
/// 「真 exe + 真 Web 产物」的两端 E2E 用人工链路验证（交接文档 R13）。
void main() {
  late Directory tmp;
  late RecipeStore store;
  late FakeSyncServer server;
  late SyncEngine engine;
  bool dataApplied = false;

  setUpAll(() async {
    server = await FakeSyncServer.start();
  });

  tearDownAll(() async {
    await server.close();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zaoji_sync_test_');
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
    dataApplied = false;
    engine = SyncEngine(
      db: store.dbOrNull!,
      prefs: SyncPrefs(store.dbOrNull!),
      transport: HttpSyncTransport(Uri.parse(server.url)),
      onDataApplied: () async => dataApplied = true,
    );
    server.reset();
  });

  tearDown(() async {
    engine.dispose();
    await store.dbOrNull!.close();
    store.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> paired() => engine.pair(serverUrl: server.url, code: 'TEST24');

  test('配对成功 → 首轮同步把种子推上服务端，并拉回服务端盖章的回声', () async {
    await paired();

    expect(engine.phase, SyncPhase.idle, reason: engine.lastError);
    expect(engine.lastError, isNull);
    // 服务端收到了全部种子行
    expect(server.rows['recipe']!.length, kSeedRecipes.length);
    expect(server.rows['ingredient']!.length, greaterThan(0));
    expect(server.rows['step']!.length, greaterThan(0));
    // 回声已应用：本地行的 updated_at 变成服务端盖的章（nodeId = fake-server）
    final db = store.dbOrNull!;
    final r1 = await db
        .customSelect("SELECT updated_at FROM recipe WHERE id = 'r1'")
        .getSingle();
    expect(Hlc.tryDecode('${r1.data['updated_at']}')!.nodeId, 'fake-server');
    // 拉到了东西 → onDataApplied 回调应被触发
    expect(dataApplied, isTrue);
    // 游标推进到服务端当前 seq
    final prefs = SyncPrefs(store.dbOrNull!);
    expect(await prefs.pullCursor(), server.seq);
    expect(await prefs.pushWatermark(), isNotEmpty);
  });

  test('第二轮把回声空推上去（服务端判 skipped，日志不增长）；第三轮是真 no-op', () async {
    await paired();
    final logAfterFirst = server.changeLog.length;
    final postsAfterFirst = server.pushCount;

    await engine.sync(); // 第二轮：回声重推
    expect(
      server.changeLog.length,
      logAfterFirst,
      reason: '内容一致的服务端必须判 skipped，不产生新变更',
    );
    expect(server.pushCount, postsAfterFirst + 1);

    await engine.sync(); // 第三轮：真正无事可做
    expect(server.pushCount, postsAfterFirst + 1, reason: '水位线已追上，不该再发推送请求');
  });

  test('另一台设备的改动会被拉下来，并触发数据刷新回调', () async {
    await paired();
    dataApplied = false;

    // 模拟设备 B 在服务端直接写了一行（走服务端的落库+盖章+记日志路径）
    server.injectRecipe(id: 'r-new', name: 'B 设备新加的菜');

    await engine.sync();

    final db = store.dbOrNull!;
    final row = await db
        .customSelect("SELECT name FROM recipe WHERE id = 'r-new'")
        .getSingle();
    expect('${row.data['name']}', 'B 设备新加的菜');
    expect(dataApplied, isTrue, reason: '拉到了新数据必须刷新 store，否则列表不变');
  });

  test('★ LWW：本地比服务端新的离线改动不会被旧数据覆盖', () async {
    await paired();

    // 本地离线改 r1（本机 HLC，比服务端刚盖的章更新）
    final db = store.dbOrNull!;
    final hlc = Hlc.now(await SyncPrefs(db).nodeId()).encode();
    await db.customUpdate(
      "UPDATE recipe SET name = '本机新名字', updated_at = ? WHERE id = 'r1'",
      variables: [Variable(hlc)],
    );

    // 服务端此时推来的还是旧内容（它手里只有老数据）
    await engine.sync();

    final row = await db
        .customSelect("SELECT name, updated_at FROM recipe WHERE id = 'r1'")
        .getSingle();
    expect('${row.data['name']}', '本机新名字', reason: '服务端的旧版本不能盖掉本地更新的改动');
    // 且它会在下一轮被推上去
    await engine.sync();
    expect('${server.rows['recipe']!['r1']!['name']}', '本机新名字');
  });

  test('软删除会以 op=delete 推上去（服务端 upsert 分支不处理墓碑）', () async {
    await paired();
    final db = store.dbOrNull!;
    final prefs = SyncPrefs(db);

    // 本地软删 r5：打墓碑 + 盖本机 HLC（这就是未来删除按钮要做的事）
    final hlc = Hlc.now(await prefs.nodeId()).encode();
    await db.customUpdate(
      "UPDATE recipe SET deleted_at = '2026-09-18T20:00:00', updated_at = ? "
      "WHERE id = 'r5'",
      variables: [Variable(hlc)],
    );

    await engine.sync();

    expect(
      '${server.rows['recipe']!['r5']!['deleted_at']}',
      isNotNull,
      reason: '墓碑必须到达服务端，否则其他设备的 r5 永远删不掉',
    );
  });

  test('★ serverId 变了：拒绝同步并要求重新配对，一个字节都不发', () async {
    await paired();
    // 改写本地记录的 serverId，模拟「下次连到的是另一台服务器」
    await SyncPrefs(store.dbOrNull!).setServerId('another-server');
    server.reset(); // 清空请求计数

    await engine.sync();

    expect(engine.phase, SyncPhase.error);
    expect(engine.lastError, contains('重新配对'));
    expect(server.pushCount, 0, reason: '身份校验失败后绝不能继续推数据');
    expect(server.pullCount, 0);
  });

  test('协议版本不一致（409）要明确告诉用户去升级', () async {
    server.protocolVersionOverride = 999;
    addTearDown(() => server.protocolVersionOverride = null); // 失败也不能泄漏到后续测试
    await paired();
    expect(engine.phase, SyncPhase.error);
    expect(engine.lastError, contains('协议版本'));
  });

  test('★ 游标持久化在客户端：重启引擎后从上次游标继续，而不是从 0 重拉', () async {
    await paired();
    final cursorAfterFirst = await SyncPrefs(store.dbOrNull!).pullCursor();
    expect(cursorAfterFirst, greaterThan(0));
    final pullsAfterFirst = server.pullCount;

    // 模拟 App 重启：新引擎实例、同一个库（同一份 prefs）
    final engine2 = SyncEngine(
      db: store.dbOrNull!,
      prefs: SyncPrefs(store.dbOrNull!),
      transport: HttpSyncTransport(Uri.parse(server.url)),
    );
    await engine2.sync();

    final q = server.lastPullQuery;
    expect(
      q!['since'],
      '$cursorAfterFirst',
      reason:
          '铁律：拉取游标在客户端。重启后必须从游标继续，'
          '从 0 重拉既是浪费，更会把离线改动覆盖回旧版',
    );
    expect(server.pullCount, pullsAfterFirst + 1);
    engine2.dispose();
  });

  test('限流/坏码等配对失败会透出服务端的话', () async {
    await engine.pair(serverUrl: server.url, code: 'WRONG1');
    expect(engine.phase, SyncPhase.error);
    expect(engine.lastError, contains('配对码'));
    expect(await SyncPrefs(store.dbOrNull!).isPaired(), isFalse);
  });

  group('图片分级拉取（R17）', () {
    test('★ 列表拉 640 档、详情拉 1280 档——都不去拉 1600px 原图', () async {
      await paired();
      final sha = 'a' * 64;

      final card = await engine.fetchMediaCached(sha, width: MediaWidth.card);
      final detail =
          await engine.fetchMediaCached(sha, width: MediaWidth.detail);

      expect(card, isNotNull);
      expect(detail, isNotNull);
      expect(utf8.decode(card!), 'w640:$sha');
      expect(utf8.decode(detail!), 'w1280:$sha');
      expect(server.mediaPaths,
          ['/api/media/$sha?w=640', '/api/media/$sha?w=1280']);
      expect(server.mediaPaths.any((p) => !p.contains('?w=')), isFalse,
          reason: '原图 200~500 KB，列表根本看不出与 640 档的差别——一屏 6 张就是几 MB');
    });

    test('★ 缓存按 (sha, 档位) 分格：重复 build 不再发请求，三档互不串味', () async {
      await paired();
      final sha = 'b' * 64;
      await engine.fetchMediaCached(sha, width: MediaWidth.card);
      await engine.fetchMediaCached(sha, width: MediaWidth.detail);
      final before = server.mediaPaths.length;

      await engine.fetchMediaCached(sha, width: MediaWidth.card);
      await engine.fetchMediaCached(sha, width: MediaWidth.detail);
      expect(server.mediaPaths.length, before, reason: '两档各自命中缓存');

      final full = await engine.fetchMediaCached(sha);
      expect(utf8.decode(full!), 'full:$sha',
          reason: '原图是第三格缓存，不能被缩略图顶掉（否则详情看到的是缩略图放大的糊图）');
      expect(server.mediaPaths.length, before + 1);
    });

    test('未配对 / 404 / 档位非法 → 一律 null，绝不把异常抛给 UI', () async {
      final sha = 'c' * 64;
      // ① 未配对：没有 token 就不该发请求
      expect(await engine.fetchMediaCached(sha, width: MediaWidth.card), isNull);
      expect(server.mediaPaths, isEmpty);

      await paired();
      // ② 服务端没有这张图
      expect(
          await engine.fetchMediaCached('d' * 64, width: MediaWidth.card), isNull);
      // ③ 档位不在白名单（服务端 400，不是"回原图"）
      expect(await engine.fetchMediaCached(sha, width: 333), isNull);
    });
  });
}

// ════════════════════════════════════════════════════════════════════

/// 测试内的同步协议模拟服务端。走**真 HTTP**（dart:io HttpServer），
/// 协议形状与 server/lib/src/sync.dart 对齐：配对码换 token、Bearer 鉴权、
/// mutationId 幂等（重放返回上次结果）、seq 游标分页、载荷跟随变更。
class FakeSyncServer {
  FakeSyncServer._(this._server);

  final HttpServer _server;
  final rows = <String, Map<String, Map<String, Object?>>>{};
  final changeLog = <Map<String, Object?>>[];
  final _mutations = <String, List<Map<String, Object?>>>{};
  final tokens = <String, String>{}; // token -> deviceId
  int seq = 0;
  int pushCount = 0;
  int pullCount = 0;
  Map<String, String>? lastPullQuery;
  int? protocolVersionOverride;

  /// 媒体请求的完整路径（含 query）。用来钉死「列表拉的是 640 档而不是原图」——
  /// 这类退化不会报错，只会让手机白白多解一张 1600px 的图。
  final mediaPaths = <String>[];

  static const serverId = 'fake-server';
  static const goodCode = 'TEST24';

  String get url => 'http://127.0.0.1:${_server.port}';

  static Future<FakeSyncServer> start() async {
    final s = await HttpServer.bind('127.0.0.1', 0);
    final fake = FakeSyncServer._(s);
    s.listen(fake._handle);
    return fake;
  }

  void reset() {
    rows.clear();
    changeLog.clear();
    _mutations.clear();
    tokens.clear();
    seq = 0;
    pushCount = 0;
    pullCount = 0;
    lastPullQuery = null;
    mediaPaths.clear();
  }

  var _hlc = Hlc.now(serverId);
  String _stamp() => (_hlc = _hlc.tick(serverId)).encode();

  /// 模拟另一台设备直接在服务端写入。
  void injectRecipe({required String id, required String name}) {
    final stamp = _stamp();
    final row = <String, Object?>{
      'id': id,
      'updated_at': stamp,
      'updated_by': 'device-b',
      'rev': 1,
      'deleted_at': null,
      'name': name,
      'sub': '',
      'art': null,
      'pal': null,
      'difficulty': 1,
      'self_time': 10,
      'cooked_count': 0,
      'servings': 2,
      'notes': '',
      'tags': null,
      'source': 'manual',
      'source_model': null,
      'source_at': null,
      'last_cooked_at': null,
      'cover_sha256': null,
    };
    (rows['recipe'] ??= {})[id] = row;
    changeLog.add({
      'seq': ++seq,
      'tbl': 'recipe',
      'rowId': id,
      'op': 'upsert',
      'updatedAt': stamp,
      'updatedBy': 'device-b',
    });
  }

  Future<void> close() async {
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final body = await utf8.decoder.bind(req).join();
      final json = body.isEmpty
          ? <String, Object?>{}
          : (jsonDecode(body) as Map).cast<String, Object?>();

      late int status = 200;
      late Map<String, Object?> res;
      if (req.uri.path == '/api/ping') {
        res = {'ok': true, 'serverId': serverId};
      } else if (req.uri.path == '/api/pair/code') {
        res = {'code': goodCode};
      } else if (req.uri.path == '/api/pair') {
        (status, res) = _pair(json);
      } else if (req.uri.path == '/api/changes') {
        // 与真服务端同款：数据接口一律要 token（引擎必须带上它）
        if (_deviceIdOf(req) == null) {
          req.response.statusCode = 401;
          req.response.write(jsonEncode({'error': 'unauthorized'}));
          await req.response.close();
          return;
        }
        (status, res) = req.method == 'POST'
            ? _push(json)
            : (200, _pull(req.uri.queryParameters));
      } else if (req.uri.path.startsWith('/api/media/')) {
        // 媒体接口：与真服务端同款三道语义——要 token、档位白名单、原图/缩略图
        if (_deviceIdOf(req) == null) {
          req.response.statusCode = 401;
          req.response.write(jsonEncode({'error': 'unauthorized'}));
          await req.response.close();
          return;
        }
        final sha = req.uri.pathSegments.last;
        final w = req.uri.queryParameters['w'];
        mediaPaths.add(w == null ? '/api/media/$sha' : '/api/media/$sha?w=$w');

        if (w != null && w != '640' && w != '1280') {
          // 白名单外一律 400，**不做「不认识就回原图」的静默降级**
          req.response.statusCode = 400;
          req.response.write(jsonEncode({'error': 'bad_request'}));
          await req.response.close();
          return;
        }
        if (sha != 'a' * 64 && sha != 'b' * 64 && sha != 'c' * 64) {
          req.response.statusCode = 404;
          req.response.write(jsonEncode({'error': 'not_found'}));
          await req.response.close();
          return;
        }
        // 载荷按档位区分，测试即可断言"拿回来的到底是哪一档"
        final payload = Uint8List.fromList(
            utf8.encode('${w == null ? 'full' : 'w$w'}:$sha'));
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType('image', 'jpeg');
        req.response.add(payload);
        await req.response.close();
        return;
      } else {
        status = 404;
        res = {'error': 'not_found'};
      }

      req.response.statusCode = status;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(res));
      await req.response.close();
    } catch (_) {
      req.response.statusCode = 500;
      await req.response.close();
    }
  }

  (int, Map<String, Object?>) _pair(Map<String, Object?> body) {
    final code = '${body['code'] ?? ''}';
    if (code != goodCode) {
      // 与真服务端同款：码错是 403，不是 200 带错误载荷——
      // 引擎靠状态码区分「码不对」与「网络问题」
      return (403, {'error': 'unknownCode', 'message': '配对码不对，请在电脑上重新获取'});
    }
    final deviceId = '${body['deviceId'] ?? ''}';
    final token = 'tok-$deviceId-${Random().nextInt(1 << 32)}';
    tokens[token] = deviceId;
    return (
      200,
      {
        'token': token,
        'deviceId': deviceId,
        'serverId': serverId,
        'protocolVersion': kSyncProtocolVersion,
      },
    );
  }

  String? _deviceIdOf(HttpRequest req) {
    final h = req.headers.value('authorization') ?? '';
    if (!h.startsWith('Bearer ')) return null;
    return tokens[h.substring(7)];
  }

  (int, Map<String, Object?>) _push(Map<String, Object?> body) {
    pushCount++;
    if (protocolVersionOverride != null) {
      // 模拟「服务端升级了协议」：引擎必须在推送前被 409 拦下
      return (
        409,
        {
          'error': 'protocol_mismatch',
          'serverProtocolVersion': protocolVersionOverride,
        },
      );
    }
    final pv = body['protocolVersion'];
    if (pv is int && pv != kSyncProtocolVersion) {
      return (
        409,
        {
          'error': 'protocol_mismatch',
          'serverProtocolVersion': kSyncProtocolVersion,
        },
      );
    }
    final mutationId = '${body['mutationId'] ?? ''}';
    if (_mutations.containsKey(mutationId)) {
      return (
        200,
        {
          'mutationId': mutationId,
          'replayed': true,
          'results': _mutations[mutationId],
        },
      );
    }

    final results = <Map<String, Object?>>[];
    final changes = (body['changes'] as List? ?? const []).cast<Map>();
    for (final c in changes) {
      final tbl = '${c['tbl']}';
      final rowId = '${c['rowId']}';
      final table = (rows[tbl] ??= {});
      final incoming = (c['row'] as Map? ?? {}).cast<String, Object?>();

      if ('${c['op']}' == 'delete') {
        final existing = table[rowId];
        if (existing == null) {
          results.add({'tbl': tbl, 'rowId': rowId, 'outcome': 'skipped'});
          continue;
        }
        final stamp = _stamp();
        existing['deleted_at'] = stamp;
        existing['updated_at'] = stamp;
        changeLog.add({
          'seq': ++seq,
          'tbl': tbl,
          'rowId': rowId,
          'op': 'delete',
          'updatedAt': stamp,
          'updatedBy': 'device',
        });
        results.add({
          'tbl': tbl,
          'rowId': rowId,
          'outcome': 'deleted',
          'seq': seq,
        });
        continue;
      }

      final existing = table[rowId];
      if (existing == null) {
        final stamp = _stamp();
        final stored = <String, Object?>{...incoming}
          ..['updated_at'] = stamp
          ..['rev'] = 1;
        table[rowId] = stored;
        changeLog.add({
          'seq': ++seq,
          'tbl': tbl,
          'rowId': rowId,
          'op': 'upsert',
          'updatedAt': stamp,
          'updatedBy': 'device',
        });
        results.add({
          'tbl': tbl,
          'rowId': rowId,
          'outcome': 'inserted',
          'seq': seq,
        });
      } else if (_sameBusinessFields(existing, incoming)) {
        // 与真服务端同款语义：业务字段一致 → skipped（不盖章、不记日志）。
        // 回声重推全靠这条分支吞掉，否则每轮同步都会虚增变更日志。
        results.add({'tbl': tbl, 'rowId': rowId, 'outcome': 'skipped'});
      } else {
        // 有差异：应用 incoming 的业务字段 + 盖章 + 记日志。
        // （真服务端此时还会按 base 情况写冲突箱/自动合并——模拟器从简，
        //   引擎对这些 outcome 一视同仁，不影响被测行为。）
        final stamp = _stamp();
        for (final e in incoming.entries) {
          if (const {'id', 'updated_at', 'updated_by', 'rev'}.contains(e.key)) {
            continue;
          }
          existing[e.key] = e.value;
        }
        existing['updated_at'] = stamp;
        changeLog.add({
          'seq': ++seq,
          'tbl': tbl,
          'rowId': rowId,
          'op': 'upsert',
          'updatedAt': stamp,
          'updatedBy': 'device',
        });
        results.add({
          'tbl': tbl,
          'rowId': rowId,
          'outcome': 'updated',
          'seq': seq,
        });
      }
    }
    _mutations[mutationId] = List.of(results);
    return (
      200,
      {'mutationId': mutationId, 'replayed': false, 'results': results},
    );
  }

  /// 业务字段（五列之外）是否完全一致。null 与缺失视为不同（与真实行为对齐：
  /// 完整行语义下不会出现缺列，正常路径两者键集合相同）。
  bool _sameBusinessFields(Map<String, Object?> a, Map<String, Object?> b) {
    const five = {'id', 'updated_at', 'updated_by', 'rev', 'deleted_at'};
    final keys = <String>{
      ...a.keys.where((k) => !five.contains(k)),
      ...b.keys.where((k) => !five.contains(k)),
    };
    for (final k in keys) {
      final va = a[k];
      final vb = b[k];
      if (va == null || vb == null ? va != vb : '$va' != '$vb') return false;
    }
    return true;
  }

  Map<String, Object?> _pull(Map<String, String> q) {
    pullCount++;
    lastPullQuery = q;
    final since = int.tryParse(q['since'] ?? '0') ?? 0;
    final limit = int.tryParse(q['limit'] ?? '500') ?? 500;

    final out = <Map<String, Object?>>[];
    for (final e in changeLog) {
      if ((e['seq'] as int) <= since) continue;
      if (out.length >= limit) break;
      final table = rows['${e['tbl']}']!;
      final row = table['${e['rowId']}'];
      out.add({...e, if (row != null) 'row': Map<String, Object?>.of(row)});
    }
    return {
      'serverId': serverId,
      'protocolVersion': protocolVersionOverride ?? kSyncProtocolVersion,
      'fromSeq': since,
      'lastSeq': seq,
      'nowSeq': seq,
      'hasMore': false,
      'changes': out,
    };
  }
}
