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

  /// R43 · `/api/purge` 被调了几次、每次收了什么（断言"没接入就不该打到服务端"用得上）。
  int purgeCount = 0;
  final purgeBodies = <Map<String, Object?>>[];
  Map<String, String>? lastPullQuery;
  int? protocolVersionOverride;

  /// R43 · 关掉它就演**老服务端**：`/api/purge` 这条路由不存在，回 HTML 404。
  /// （家里那台现在跑的就是 v0.14.3，这条组合一定会被踩到，不能只在文档里假设。）
  bool supportsPurge = true;

  /// 每个请求回包前故意慢这么久。测「进行中」的 UI（进度条、按钮禁用态）时
  /// 用它把中间态钉住——本机 localhost 往返时快时慢，不设延迟的断言会偶发。
  Duration latency = Duration.zero;

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

  // ── R27 AI（镜像真服务端 /api/ai/* 的形状）──
  // 状态是**可编程的**：配置写进来即翻成 configured/enabled，
  // 热量与补全的回复可整体替换（测失败分支不用碰真网络）。
  bool aiConfigured = false;
  bool aiEnabled = false;
  String aiModel = 'deepseek-flash';
  final aiConfigWrites = <Map<String, Object?>>[];
  int aiCaloriesCalls = 0;
  int aiFillCalls = 0;
  Map<String, Object?>? aiCaloriesReply;
  Map<String, Object?>? aiFillReply;
  Map<String, Object?>? aiRecommendReply;
  int aiRecommendCalls = 0;
  String? aiFailWith; // 'off' | 'auth'：非 null 时能力端点直接回该错误

  // ── R44 · AI 执行记录（镜像真服务端 /api/ai/runs 的形状）──
  //
  // 每次能力调用都往这张表推一行摘要，并把它的 id 当 runId 回给客户端——
  // 这样「发起 → 出现在列表 → 标本机」这条端到端链路能在假服务端上跑通。
  final aiRuns = <Map<String, Object?>>[];
  int _aiRunSeq = 0;
  int aiRunsListCalls = 0;
  int aiRunsDeleteCalls = 0;
  int aiRunsClearCalls = 0;

  /// 推一行执行记录，返回它的 id（回给客户端当 runId）。
  int _pushRun(String feature,
      {bool ok = true,
      String? errorKind,
      bool cached = false,
      int inTok = 100,
      int outTok = 50,
      String? summary}) {
    final id = ++_aiRunSeq;
    aiRuns.insert(0, {
      'id': id,
      'at': DateTime.now().millisecondsSinceEpoch,
      'feature': feature,
      'model': aiModel,
      'ok': ok,
      'errorKind': errorKind,
      'cached': cached,
      'inTok': ok && !cached ? inTok : 0,
      'outTok': ok && !cached ? outTok : 0,
      'durationMs': ok ? 120 : 0,
      'source': 'AI 测试机',
      'promptExcerpt': summary ?? '',
      'outputExcerpt': ok ? (summary ?? '结果') : (errorKind ?? '失败'),
    });
    return id;
  }

  /// 记本机 ai_usage 的 run_ref 用哪台设备名做「本机」比对（列表 source 字段）。
  static const aiSourceLabel = 'AI 测试机';

  // ── R44 · 提示词管理（镜像真服务端 /api/ai/prompts）──
  // 三能力的内置默认（假数据，形状与真服务端一致即可）+ 覆盖表。
  static const _promptDefaults = {
    'calories': '你是家庭菜谱的热量估算器',
    'recipe_fill': '你是中式家常菜菜谱写手',
    'recommend': '你是家庭厨师',
  };
  final aiPromptOverrides = <String, Map<String, String>>{};
  final aiPromptSaves = <Map<String, Object?>>[];
  int aiPromptResets = 0;
  bool aiPromptReject = false; // true → POST 一律回 bad_placeholder

  static Map<String, Object?> _promptPlaceholders(String f) => switch (f) {
        'calories' => {
            'required': ['{{name}}', '{{servings}}', '{{ingredients}}'],
            'optional': <String>[]
          },
        'recipe_fill' => {
            'required': ['{{name}}'],
            'optional': ['{{hint}}']
          },
        _ => {
            'required': ['{{pantry}}', '{{existing}}', '{{want}}'],
            'optional': <String>[]
          },
      };

  List<Map<String, Object?>> _promptViews() => [
        for (final f in _promptDefaults.keys)
          {
            'feature': f,
            'system': aiPromptOverrides[f]?['system'] ?? _promptDefaults[f],
            'user': aiPromptOverrides[f]?['user'] ?? '菜名：{{name}}',
            'defaultSystem': _promptDefaults[f],
            'defaultUser': '菜名：{{name}}',
            'modified': aiPromptOverrides.containsKey(f),
            'placeholders': _promptPlaceholders(f),
          },
      ];

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
    purgeCount = 0;
    purgeBodies.clear();
    supportsPurge = true;
    pullCount = 0;
    lastPullQuery = null;
    latency = Duration.zero;
    mediaPaths.clear();
    accessMode = 'pairCode';
    passcode = null;
    visitorManualSync = false;
    visitorNodes.clear();
    aiConfigured = false;
    aiEnabled = false;
    aiModel = 'deepseek-flash';
    aiConfigWrites.clear();
    aiCaloriesCalls = 0;
    aiFillCalls = 0;
    aiCaloriesReply = null;
    aiFillReply = null;
    aiRecommendReply = null;
    aiRecommendCalls = 0;
    aiFailWith = null;
    aiRuns.clear();
    _aiRunSeq = 0;
    aiRunsListCalls = 0;
    aiRunsDeleteCalls = 0;
    aiRunsClearCalls = 0;
    aiPromptOverrides.clear();
    aiPromptSaves.clear();
    aiPromptResets = 0;
    aiPromptReject = false;
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
    if (latency > Duration.zero) await Future<void>.delayed(latency);
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
      } else if (req.uri.path == '/api/purge') {
        // R43 · 永久删除。鉴权同数据接口，语义镜像真服务端（见 _purge）。
        //
        // **老服务端的形状**：v0.14.3 及更早的 exe 没有这条路由，shelf 兜底回的是
        // **HTML 404**（不是 JSON）。这台假服务端要能演这一出，
        // 否则"新前端 + 旧服务端"这条真会撞上的组合就只在文档里存在过。
        if (!supportsPurge) {
          req.response.statusCode = 404;
          req.response.headers.contentType = ContentType.html;
          req.response.write('<html><body>404 not found</body></html>');
          await req.response.close();
          return;
        }
        if (_deviceIdOf(req) == null && !_allowAnonymous(req)) {
          req.response.statusCode = 401;
          req.response.write(jsonEncode({'error': 'unauthorized'}));
          await req.response.close();
          return;
        }
        (status, res) = _purge(json);
      } else if (req.uri.path == '/api/conflicts/resolve') {
        // R22：鉴权与数据接口同一套（token 优先，开放模式认 X-Node-Id）
        if (_deviceIdOf(req) == null && !_allowAnonymous(req)) {
          req.response.statusCode = 401;
          req.response.write(jsonEncode({'error': 'unauthorized'}));
          await req.response.close();
          return;
        }
        (status, res) = _resolve(json);
      } else if (req.uri.path.startsWith('/api/ai/')) {
        final handled = await _ai(req, json);
        if (handled) return;
        status = 404;
        res = {'error': 'not_found'};
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

  /// R27 AI 端点。返回 true = 已应答并关闭响应。
  /// 鉴权门与 /api/changes 同一形状（token 或开放模式 X-Node-Id）。
  Future<bool> _ai(HttpRequest req, Map<String, Object?> json) async {
    if (_deviceIdOf(req) == null && !_allowAnonymous(req)) {
      req.response.statusCode = 401;
      req.response.write(jsonEncode({'error': 'unauthorized'}));
      await req.response.close();
      return true;
    }
    final path = req.uri.path;
    Map<String, Object?> res;
    var status = 200;
    if (path == '/api/ai/status' && req.method == 'GET') {
      res = {
        'ok': true,
        'enabled': aiEnabled,
        'provider': 'deepseek',
        'baseUrl': 'https://api.deepseek.com/v1',
        'model': aiModel,
        'keyMasked': aiConfigured ? '••••abcd' : '',
        'configured': aiConfigured,
        'flags': {'nutrition': true, 'recipe': true, 'recommend': true},
        'usage': {'calls': aiCaloriesCalls + aiFillCalls, 'inTok': 0, 'outTok': 0},
        'providers': [
          {'k': 'deepseek', 'n': 'DeepSeek', 'url': 'https://api.deepseek.com/v1',
            'model': 'deepseek-flash', 'note': '默认'},
          {'k': 'ollama', 'n': 'Ollama', 'url': 'http://127.0.0.1:11434/v1',
            'model': 'qwen2.5:7b', 'note': '零外发'},
        ],
      };
    } else if (path == '/api/ai/config' && req.method == 'POST') {
      aiConfigWrites.add(json);
      if (json['key'] != null && '${json['key']}'.isNotEmpty &&
          !'${json['key']}'.startsWith('••••')) {
        aiConfigured = true;
      }
      if (json['enabled'] is bool) aiEnabled = json['enabled'] as bool;
      if (json['model'] != null) aiModel = '${json['model']}';
      res = {'ok': true, 'configured': aiConfigured,
        'keyMasked': aiConfigured ? '••••abcd' : ''};
    } else if (path == '/api/ai/test' && req.method == 'POST') {
      res = {'ok': true, 'message': '连通正常'};
    } else if (path == '/api/ai/calories' && req.method == 'POST') {
      aiCaloriesCalls++;
      if (aiFailWith != null) {
        _pushRun('calories', ok: false, errorKind: aiFailWith);
        status = aiFailWith == 'off' ? 409 : 502;
        res = {'ok': false, 'error': aiFailWith, 'message': 'mock $aiFailWith'};
      } else {
        final rid = _pushRun('calories', summary: '${json['name']}');
        res = {
          'ok': true,
          'model': aiModel,
          'runId': rid,
          'usage': {'prompt_tokens': 100, 'completion_tokens': 50},
          'result': aiCaloriesReply ?? {
            'kcal_per_serving': 250, 'total_kcal': 500,
            'protein_g': 22, 'fat_g': 30, 'carb_g': 20,
            'per_ingredient': [
              {'name': '番茄', 'kcal': 54},
              {'name': '鸡蛋', 'kcal': 257},
            ],
            'confidence': 'medium',
            'note': '按常见营养数据估算',
          },
        };
      }
    } else if (path == '/api/ai/recommend' && req.method == 'POST') {
      aiRecommendCalls++;
      if (aiFailWith != null) {
        _pushRun('recommend', ok: false, errorKind: aiFailWith);
        status = aiFailWith == 'off' ? 409 : 502;
        res = {'ok': false, 'error': aiFailWith, 'message': 'mock $aiFailWith'};
      } else {
        final rid = _pushRun('recommend', summary: '推荐');
        res = {
          'ok': true,
          'model': aiModel,
          'runId': rid,
          'usage': {'prompt_tokens': 200, 'completion_tokens': 120},
          'result': aiRecommendReply ?? {
            'dishes': [
              {
                'name': '蒜香豆腐煲',
                'sub': '豆腐的新做法',
                'difficulty': 1,
                'self_time': 25,
                'servings': 2,
                'ingredients': [
                  {'name': '豆腐', 'amount': '1盒'},
                  {'name': '蒜', 'amount': '3瓣'}
                ],
                'steps': ['蒜末爆香 2 分钟', '豆腐下锅焖 15 分钟'],
                'reason': '用上了家里的豆腐',
                'extra_needed': ['蒜']
              }
            ]
          },
        };
      }
    } else if (path == '/api/ai/recipe-fill' && req.method == 'POST') {
      aiFillCalls++;
      if (aiFailWith != null) {
        _pushRun('recipe_fill', ok: false, errorKind: aiFailWith);
        status = aiFailWith == 'off' ? 409 : 502;
        res = {'ok': false, 'error': aiFailWith, 'message': 'mock $aiFailWith'};
      } else {
        final rid = _pushRun('recipe_fill', summary: '${json['name']}');
        res = {
          'ok': true,
          'model': aiModel,
          'runId': rid,
          'usage': {'prompt_tokens': 150, 'completion_tokens': 300},
          'result': aiFillReply ?? {
            'sub': '酸甜开胃的经典下饭菜',
            'difficulty': 2,
            'self_time': 20,
            'servings': 2,
            'tags': ['家常'],
            'ingredients': [
              {'name': '番茄', 'amount': '2个', 'kind': 'main'},
              {'name': '鸡蛋', 'amount': '3个', 'kind': 'main'},
            ],
            'steps': [
              {'text': '鸡蛋打散，加盐搅匀，静置 5 分钟', 'minutes': 5},
              {'text': '热油下蛋液，大火炒 2 分钟至凝固'},
              {'text': '下番茄块，转中小火焖 8 分钟'},
              {'text': '回锅鸡蛋翻匀，收汁 2 分钟出锅'},
            ],
            'notes': '糖按口味取舍',
          },
        };
      }
    } else if (path == '/api/ai/prompts' && req.method == 'GET') {
      res = {'ok': true, 'prompts': _promptViews()};
    } else if (path == '/api/ai/prompts' && req.method == 'POST') {
      aiPromptSaves.add(json);
      if (aiPromptReject) {
        status = 400;
        res = {
          'ok': false,
          'error': 'bad_placeholder',
          'message': 'calories 缺少必填占位符：{{ingredients}}'
        };
      } else {
        final f = '${json['feature']}';
        aiPromptOverrides[f] = {
          'system': '${json['system']}',
          'user': '${json['user']}',
        };
        res = {'ok': true, 'feature': f, 'cacheCleared': true};
      }
    } else if (path == '/api/ai/prompts/reset' && req.method == 'POST') {
      aiPromptResets++;
      aiPromptOverrides.remove('${json['feature']}');
      res = {'ok': true, 'cacheCleared': true};
    } else if (path == '/api/ai/runs' && req.method == 'GET') {
      aiRunsListCalls++;
      res = _aiRunsFiltered(req.uri.queryParameters);
    } else if (path == '/api/ai/runs' && req.method == 'DELETE') {
      aiRunsClearCalls++;
      final f = req.uri.queryParameters['feature'];
      final before = aiRuns.length;
      aiRuns.removeWhere((r) => f == null || r['feature'] == f);
      res = {'ok': true, 'deleted': before - aiRuns.length};
    } else if (path.startsWith('/api/ai/runs/')) {
      final id = int.tryParse(path.substring('/api/ai/runs/'.length));
      if (req.method == 'GET') {
        final match = aiRuns.where((r) => r['id'] == id);
        if (match.isEmpty) {
          status = 404;
          res = {'ok': false, 'error': 'not_found'};
        } else {
          res = {
            'ok': true,
            'run': {...match.first,
              // 详情比摘要多全文几列（镜像真服务端 full 视图）
              'promptSystem': '你是……',
              'promptUser': '${match.first['promptExcerpt']}',
              'inputJson': '{}',
              'output': '${match.first['outputExcerpt']}',
            }..remove('promptExcerpt')..remove('outputExcerpt'),
          };
        }
      } else if (req.method == 'DELETE') {
        aiRunsDeleteCalls++;
        final before = aiRuns.length;
        aiRuns.removeWhere((r) => r['id'] == id);
        res = {'ok': true, 'deleted': before - aiRuns.length};
      } else {
        return false;
      }
    } else {
      return false;
    }
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(res));
    await req.response.close();
    return true;
  }

  /// 按 feature / ok / q / limit / offset 过滤，返回 {ok,total,runs}。
  Map<String, Object?> _aiRunsFiltered(Map<String, String> q) {
    Iterable<Map<String, Object?>> rows = aiRuns;
    final feature = q['feature'];
    if (feature != null) rows = rows.where((r) => r['feature'] == feature);
    final okq = q['ok'];
    if (okq != null) rows = rows.where((r) => ('${r['ok']}' == 'true') == (okq == '1'));
    final query = q['q'];
    if (query != null && query.isNotEmpty) {
      rows = rows.where((r) =>
          '${r['promptExcerpt']}'.contains(query) ||
          '${r['outputExcerpt']}'.contains(query));
    }
    final list = rows.toList();
    final offset = int.tryParse(q['offset'] ?? '') ?? 0;
    final limit = int.tryParse(q['limit'] ?? '') ?? list.length;
    return {
      'ok': true,
      'total': list.length,
      'limit': limit,
      'offset': offset,
      'runs': list.skip(offset).take(limit).toList(),
    };
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

  /// R43 · 永久删除。**镜像真服务端 SyncService.purge 的四条语义**，不是简化版：
  /// ① 只认同步白名单里的表；② 只删已经在回收站里的行；
  /// ③ `recipe` 级联 `ingredient` / `step`；④ 每条物理删各写一条 `op:'purge'` 变更。
  /// 第 ④ 条是这个假件最容易偷懒漏掉的地方——漏了它，客户端测试就测不出
  /// "对端设备留着一条还能恢复的墓碑"这个真问题。
  (int, Map<String, Object?>) _purge(Map<String, Object?> body) {
    purgeCount++;
    purgeBodies.add(body);
    final items = body['rows'];
    if (items is! List || items.isEmpty || items.length > 200) {
      return (
        400,
        {'error': 'bad_request', 'message': 'rows 必须是 1..200 个 {tbl, id}'}
      );
    }
    final out = <Map<String, Object?>>[];
    for (final raw in items) {
      final e = (raw as Map).cast<String, Object?>();
      final tbl = '${e['tbl']}';
      final rowId = '${e['id'] ?? e['rowId'] ?? ''}';
      if (!syncWhitelist.containsKey(tbl)) {
        out.add({
          'tbl': tbl,
          'rowId': rowId,
          'outcome': 'rejected',
          'reason': '未知或不允许同步的表：$tbl'
        });
        continue;
      }
      if (rowId.isEmpty) {
        out.add({
          'tbl': tbl,
          'rowId': rowId,
          'outcome': 'rejected',
          'reason': '缺少 id'
        });
        continue;
      }
      final row = (rows[tbl] ?? const {})[rowId];
      if (row == null) {
        out.add({
          'tbl': tbl,
          'rowId': rowId,
          'outcome': 'skipped',
          'reason': '服务端没有这一行（可能已经永久删除过了）'
        });
        continue;
      }
      if (row['deleted_at'] == null) {
        out.add({
          'tbl': tbl,
          'rowId': rowId,
          'outcome': 'rejected',
          'reason': '这一行还没进回收站，不能直接永久删除'
        });
        continue;
      }
      _purgeOne(tbl, rowId);
      out.add({'tbl': tbl, 'rowId': rowId, 'outcome': 'purged'});
    }
    return (200, {'ok': true, 'results': out});
  }

  void _purgeOne(String tbl, String rowId) {
    final stamp = _stamp();
    if (tbl == 'recipe') {
      for (final child in const ['ingredient', 'step']) {
        final t = rows[child];
        if (t == null) continue;
        final kids = t.entries
            .where((en) => '${en.value['recipe_id']}' == rowId)
            .map((en) => en.key)
            .toList();
        for (final kid in kids) {
          t.remove(kid);
          changeLog.add({
            'seq': ++seq,
            'tbl': child,
            'rowId': kid,
            'op': 'purge',
            'updatedAt': stamp,
            'updatedBy': 'device',
          });
        }
      }
    }
    rows[tbl]!.remove(rowId);
    changeLog.add({
      'seq': ++seq,
      'tbl': tbl,
      'rowId': rowId,
      'op': 'purge',
      'updatedAt': stamp,
      'updatedBy': 'device',
    });
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
