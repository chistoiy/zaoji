import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'dart:io';

import 'package:zaoji_shared/zaoji_shared.dart';

/// 测试内 HTTP 模拟服务端（真 HTTP + 真协议形状）。
/// R21 起从 sync_engine_test 搬来这里共享：三态准入的客户端测试也要用它。

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

  // ── R21 三态准入（镜像真服务端语义）──
  // 默认 pairCode：既有的引擎测试都从 /api/pair 起步，别拿新默认折腾它们；
  // 三态本身的测试各自显式设定。
  String accessMode = 'pairCode';
  String? passcode;
  bool visitorManualSync = false;

  /// 匿名（无 token）请求带来过的 X-Node-Id，测试断言"每一台各自登记"用。
  final visitorNodes = <String>[];

  /// 媒体请求的完整路径（含 query）。用来钉死「列表拉的是 640 档而不是原图」——
  /// 这类退化不会报错，只会让手机白白多解一张 1600px 的图。
  final mediaPaths = <String>[];

  static const serverId = 'fake-server';
  static const goodCode = 'TEST24';

  String get url => 'http://127.0.0.1:${_server.port}';

  /// flutter_test 初始化 binding 时把 `HttpOverrides.global` 换成一律回 400 的
  /// mock（`_binding_io.dart` 的 setupHttpOverrides）。真 HTTP 引擎的测试必须
  /// 在 **binding 初始化之后**（即 testWidgets 体内）撤掉它，否则请求全部拿到
  /// 空 400——设置发生在 binding 之前会被重新覆盖，这就是踩坑点。
  static void allowRealHttp() {
    HttpOverrides.global = null;
  }

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
    accessMode = 'pairCode';
    passcode = null;
    visitorManualSync = false;
    visitorNodes.clear();
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

  /// R22 · 在「服务端」放一条真冲突（conflict_item 业务行），
  /// 客户端会像真服务端一样把它同步下来。返回 conflict_item.id。
  String injectConflict({
    required String rowId,
    required String field,
    Object? localValue,
    Object? remoteValue,
    String tbl = 'recipe',
  }) {
    final id = 'cf-$tbl-$rowId-$field';
    final stamp = _stamp();
    (rows['conflict_item'] ??= {})[id] = <String, Object?>{
      'id': id,
      'updated_at': stamp,
      'updated_by': 'server',
      'rev': 1,
      'deleted_at': null,
      'tbl': tbl,
      'row_id': rowId,
      'field': field,
      'local_value': localValue,
      'remote_value': remoteValue,
      'local_hlc': stamp,
      'remote_hlc': stamp,
      'local_by': 'device-a',
      'remote_by': 'device-b',
      'resolved_at': null,
      'resolution': null,
    };
    changeLog.add({
      'seq': ++seq,
      'tbl': 'conflict_item',
      'rowId': id,
      'op': 'upsert',
      'updatedAt': stamp,
      'updatedBy': 'server',
    });
    return id;
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
      } else if (req.uri.path == '/api/sync/config') {
        // 免鉴权；与真服务端同款——绝不回口令本身
        res = {
          'ok': true,
          'accessMode': accessMode,
          'visitorManualSync': visitorManualSync,
          'protocolVersion': kSyncProtocolVersion,
          'serverId': serverId,
        };
      } else if (req.uri.path == '/api/join') {
        (status, res) = _join(json);
      } else if (req.uri.path == '/api/pair') {
        if (accessMode != 'pairCode') {
          (status, res) = (
            409,
            {'error': 'mode_mismatch', 'message': '当前不是配对码模式'},
          );
        } else {
          (status, res) = _pair(json);
        }
      } else if (req.uri.path == '/api/changes') {
        // 与真服务端同款：token 必过；开放模式下匿名请求按 X-Node-Id 放行
        if (_deviceIdOf(req) == null && !_allowAnonymous(req)) {
          req.response.statusCode = 401;
          req.response.write(jsonEncode({'error': 'unauthorized'}));
          await req.response.close();
          return;
        }
        (status, res) = req.method == 'POST'
            ? _push(json)
            : (200, _pull(req.uri.queryParameters));
      } else if (req.uri.path == '/api/conflicts/resolve') {
        // R22：鉴权与数据接口同一套（token 优先，开放模式认 X-Node-Id）
        if (_deviceIdOf(req) == null && !_allowAnonymous(req)) {
          req.response.statusCode = 401;
          req.response.write(jsonEncode({'error': 'unauthorized'}));
          await req.response.close();
          return;
        }
        (status, res) = _resolve(json);
      } else if (req.uri.path.startsWith('/api/media/')) {
        // 媒体接口：与真服务端同款三道语义——要 token（或开放模式匿名）、档位白名单、原图/缩略图
        if (_deviceIdOf(req) == null && !_allowAnonymous(req)) {
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

  /// 开放模式的匿名放行判定（与真服务端同一规则：合法 X-Node-Id 才算设备）。
  bool _allowAnonymous(HttpRequest req) {
    if (accessMode != 'open') return false;
    final n = req.headers.value('x-node-id') ?? '';
    if (!kNodeIdPattern.hasMatch(n)) return false;
    if (!visitorNodes.contains(n)) visitorNodes.add(n);
    return true;
  }

  (int, Map<String, Object?>) _join(Map<String, Object?> body) {
    if (accessMode != 'passcode') {
      return (409, {'error': 'mode_mismatch', 'message': '当前不是口令模式'});
    }
    if (passcode == null) {
      return (503, {'error': 'passcodeNotSet', 'message': '服务端还没设定口令'});
    }
    final p = '${body['passcode'] ?? ''}'.trim();
    if (p.isEmpty) {
      return (400, {'error': 'emptyPasscode', 'message': '请输入连接口令'});
    }
    if (p != passcode) {
      return (403, {'error': 'wrongPasscode', 'message': '口令不对，问家里管服务器的人'});
    }
    final deviceId = '${body['deviceId'] ?? ''}';
    if (deviceId.isEmpty) {
      return (400, {'error': 'missingDeviceId', 'message': '缺少设备标识'});
    }
    final token = 'vtok-$deviceId-${Random().nextInt(1 << 32)}';
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
      } else if (_isStaleEcho(existing, incoming)) {
        // R22 同款「过期回声」守卫：裁决后内容不再一致，只靠上面那条会漏。
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

  /// R22 · 与真服务端同款的「过期回声」判定：updated_at 是本模拟器盖的章
  /// 且不比现存新 → 客户端重推拉回来的旧版本，吞掉而不是制造差异。
  bool _isStaleEcho(
      Map<String, Object?> existing, Map<String, Object?> incoming) {
    final stamp = '${incoming['updated_at'] ?? ''}';
    final decoded = Hlc.tryDecode(stamp);
    if (decoded == null || decoded.nodeId != serverId) return false;
    return stamp.compareTo('${existing['updated_at'] ?? ''}') <= 0;
  }

  /// R22 · 裁决端点（镜像真服务端语义：选定值写业务行 + 盖新章 + 归档冲突，
  /// 两者都进 change_log）。状态与结果形状逐字段对齐 resolve_test。
  (int, Map<String, Object?>) _resolve(Map<String, Object?> body) {
    final items = body['items'];
    if (items is! List || items.isEmpty || items.length > 200) {
      return (
        400,
        {'error': 'bad_request', 'message': 'items 必须是 1..200 个对象的数组'},
      );
    }
    final results = <Map<String, Object?>>[];
    for (final raw in items.cast<Map>()) {
      final it = raw.cast<String, Object?>();
      final cid = '${it['conflictId'] ?? ''}';
      final choice = '${it['choice'] ?? ''}';
      final t = rows['conflict_item']?[cid];
      if (t == null) {
        results.add({'conflictId': cid, 'outcome': 'not_found'});
        continue;
      }
      if (t['resolved_at'] != null) {
        results.add({'conflictId': cid, 'outcome': 'already_resolved'});
        continue;
      }
      if (!const {'local', 'remote', 'merged'}.contains(choice)) {
        results.add({
          'conflictId': cid,
          'outcome': 'rejected',
          'reason': 'choice 只接受 local / remote / merged',
        });
        continue;
      }
      Object? value = switch (choice) {
        'local' => t['local_value'],
        'remote' => t['remote_value'],
        _ => it['mergedValue'],
      };
      if (choice == 'merged' && (value is! String || value.trim().isEmpty)) {
        results.add({
          'conflictId': cid,
          'outcome': 'rejected',
          'reason': 'merged 必须带 mergedValue',
        });
        continue;
      }
      final tbl = '${t['tbl']}';
      final rowId = '${t['row_id']}';
      final row = rows[tbl]?[rowId];
      if (row == null) {
        results.add({'conflictId': cid, 'outcome': 'row_missing'});
        continue;
      }
      final stamp = _stamp();
      row['${t['field']}'] = value;
      row['updated_at'] = stamp;
      changeLog.add({
        'seq': ++seq,
        'tbl': tbl,
        'rowId': rowId,
        'op': 'upsert',
        'updatedAt': stamp,
        'updatedBy': 'resolver',
      });
      final mstamp = _stamp();
      t['resolved_at'] = mstamp;
      t['resolution'] = choice;
      t['updated_at'] = mstamp;
      changeLog.add({
        'seq': ++seq,
        'tbl': 'conflict_item',
        'rowId': cid,
        'op': 'upsert',
        'updatedAt': mstamp,
        'updatedBy': 'resolver',
      });
      results.add({
        'conflictId': cid,
        'outcome': 'applied',
        'tbl': tbl,
        'rowId': rowId,
        'field': '${t['field']}',
        'seq': seq,
      });
    }
    return (200, {'ok': true, 'results': results});
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
