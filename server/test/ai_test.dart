import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:zaoji_server/zaoji_server.dart';

/// R27 · AI 代理。
///
/// 断言重心：
/// ① Key 的生命周期——明文只存在于内存与 https 请求头，**库里存的是密文、
///    任何响应只回掩码、日志只写长度**；
/// ② 代理的门——鉴权与数据接口同一道；
/// ③ 失败必须分类（auth/model/network/timeout/off），不许糊成一句「失败了」。
void main() {
  late Directory tmp;
  late ServerState state;
  late Handler handler;
  late String token;

  /// 假上游：可编程应答 + 请求记账。
  HttpServer? upstream;
  final seen = <Map<String, Object?>>[];
  Object? reply; // Map → 200 JSON；int → 该状态码
  Future<void> setUpstream() async {
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream!.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      seen.add({
        'path': req.uri.path,
        'auth': req.headers.value('authorization'),
        'body': body,
      });
      req.response.headers.contentType = ContentType.json;
      if (reply is int) {
        req.response.statusCode = reply as int;
        req.response.write('{"error":{"message":"mocked failure about model"}}');
      } else {
        // 默认回复按请求内容分支：推荐要 dishes 形状，其余要热量形状——
        // 一份假上游同时喂两类测试，比复制两个 server 干净
        Map<String, Object?> auto() {
          final isReco = body.contains('家里现有食材');
          final content = isReco
              ? {
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
                }
              : {
                  'kcal_per_serving': 250,
                  'total_kcal': 500,
                  'protein_g': 22,
                  'fat_g': 30,
                  'carb_g': 20,
                  'per_ingredient': [
                    {'name': '番茄', 'kcal': 54}
                  ],
                  'confidence': 'medium',
                  'note': 'mock',
                };
          return {
            'choices': [
              {
                'message': {'content': jsonEncode(content)}
              }
            ],
            'model': 'deepseek-flash',
            'usage': {
              'prompt_tokens': 100,
              'completion_tokens': 50
            },
          };
        }
        req.response.write(jsonEncode(reply ?? auto()));
      }
      await req.response.close();
    });
  }

  String upstreamUrl() => 'http://127.0.0.1:${upstream!.port}';

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zaoji_ai_');
    state = await ServerState.boot(ServerConfig(
      host: '127.0.0.1',
      port: 1,
      tlsPort: 2,
      dataDir: Directory('${tmp.path}${Platform.pathSeparator}data'),
      certDir: Directory('${tmp.path}${Platform.pathSeparator}certs'),
    ));
    handler = ZaojiServer.buildHandler(state, const ['192.168.1.10']);
    seen.clear();
    reply = null;
    await setUpstream();
    // 配好默认：enabled + 指向假上游
    await state.ai.saveConfig(AiConfig(
        enabled: true,
        baseUrl: upstreamUrl(),
        model: 'deepseek-flash',
        key: 'sk-test-1234567890abcdEF'));
    // 造一台已配对设备拿 token
    final pc = state.sync.issuePairCode();
    final out = state.sync.redeem(
        code: pc.code, deviceId: 'dev-ai', deviceName: 'AI 测试机');
    token = out.token!;
  });

  tearDown(() async {
    await state.close();
    await upstream?.close(force: true);
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<Response> hit(String method, String path,
      [Object? body, bool withToken = true]) async {
    return await handler(Request(method, Uri.parse('http://x$path'),
        body: body == null ? null : jsonEncode(body),
        headers: {
          if (body != null) 'content-type': 'application/json',
          if (withToken) 'authorization': 'Bearer $token',
        }));
  }

  group('Key 的生命周期', () {
    test('round-trip：存进去的 Key 原样读得回', () async {
      final c = state.ai.config();
      expect(c.key, 'sk-test-1234567890abcdEF');
      expect(c.configured, isTrue);
    });

    test('server_setting 里的原始 JSON 不含明文 Key', () async {
      final raw =
          (state.db.db.select("SELECT v FROM server_setting WHERE k='ai_config'")
                  .first['v']) as String;
      expect(raw, isNot(contains('sk-test-1234567890abcdEF')));
      expect(raw, contains('key_enc'));
    });

    test('redacted 只露后 4 位；任何接口响应不含完整 Key', () async {
      final res = await hit('GET', '/api/ai/status');
      final text = await res.readAsString();
      expect(text, isNot(contains('sk-test-1234567890abcdEF')));
      final j = jsonDecode(text) as Map<String, Object?>;
      expect(j['keyMasked'], '••••cdEF');
      expect(j['configured'], true);
      expect(j['providers'], isList); // 预设表随状态一起给（FR-AI-02）
    });

    test('掩码提交 = 不覆盖真 Key；新 Key 才覆盖', () async {
      await hit('POST', '/api/ai/config', {'key': '••••cdEF'});
      expect(state.ai.config().key, 'sk-test-1234567890abcdEF');
      await hit('POST', '/api/ai/config', {'key': 'sk-new-key-9999'});
      expect(state.ai.config().key, 'sk-new-key-9999');
    });
  });

  group('代理与能力', () {
    test('没带 token 一律 401（门与数据接口同一道）', () async {
      for (final p in ['/api/ai/status', '/api/ai/calories']) {
        final m = p.endsWith('status') ? 'GET' : 'POST';
        final res = await hit(m, p, m == 'POST' ? {} : null, false);
        expect(res.statusCode, 401, reason: p);
      }
    });

    test('calories：转发带 Bearer 上游 Key，要求 JSON 输出，结果结构化返回',
        () async {
      final res = await hit('POST', '/api/ai/calories', {
        'name': '番茄炒蛋',
        'servings': 2,
        'ingredients': [
          {'name': '番茄', 'amount': '2个', 'kind': 'main'},
          {'name': '鸡蛋', 'amount': '3个', 'kind': 'main'},
        ]
      });
      final j = jsonDecode(await res.readAsString()) as Map<String, Object?>;
      expect(res.statusCode, 200);
      expect(j['ok'], true);
      expect((j['result'] as Map)['kcal_per_serving'], 250);
      expect(j['model'], 'deepseek-flash');
      expect(seen.single['auth'], 'Bearer sk-test-1234567890abcdEF');
      final sent = jsonDecode(seen.single['body'] as String) as Map;
      expect((sent['response_format'] as Map)['type'], 'json_object');
      // 用量记账（FR-AI-12 最小实现）
      final u = state.ai.usage();
      expect(u['calls'], 1);
      expect(u['inTok'], 100);
    });

    test('相同输入第二次不再打上游（FR-AI-14 缓存）', () async {
      final body = {
        'name': '番茄炒蛋',
        'servings': 2,
        'ingredients': [
          {'name': '番茄', 'amount': '2个', 'kind': 'main'}
        ]
      };
      await hit('POST', '/api/ai/calories', body);
      final second = await hit('POST', '/api/ai/calories', body);
      final j = jsonDecode(await second.readAsString());
      expect(j['cached'], true);
      expect(seen.length, 1);
    });

    test('能力开关关闭 → 409 off，不打上游', () async {
      final c = state.ai.config()..flagNutrition = false;
      await state.ai.saveConfig(c);
      final res = await hit('POST', '/api/ai/calories', {
        'name': 'x',
        'ingredients': [
          {'name': 'y'}
        ]
      });
      expect(res.statusCode, 409);
      final j = jsonDecode(await res.readAsString());
      expect(j['error'], 'off');
      expect(seen, isEmpty);
    });

    test('recommend：库存+已有菜谱名进 prompt，off 门与空库存各自分家', () async {
      final res = await hit('POST', '/api/ai/recommend', {
        'pantry': [
          {'name': '番茄', 'amount': '2个'},
          {'name': '鸡蛋'}
        ],
        'existing': ['番茄炒蛋'],
      });
      final j = jsonDecode(await res.readAsString()) as Map<String, Object?>;
      expect(res.statusCode, 200);
      final dishes = (j['result'] as Map)['dishes'] as List;
      expect(dishes, isNotEmpty);
      // 上游确实收到了库存与已有菜谱（不然推重样没法避免）
      expect(seen.single['body'], contains('番茄'));
      expect(seen.single['body'], contains('不要重复推荐'));

      // 空库存 → 400 人话（不浪费一次上游调用）
      final bad = await hit('POST', '/api/ai/recommend', {'pantry': []});
      expect(bad.statusCode, 400);

      // 能力开关关掉 → 409 off，不打上游
      final c = state.ai.config()..flagRecommend = false;
      await state.ai.saveConfig(c);
      final off = await hit('POST', '/api/ai/recommend', {
        'pantry': [
          {'name': '米'}
        ]
      });
      expect(off.statusCode, 409);
      expect(jsonDecode(await off.readAsString())['error'], 'off');
    });

    test('recommend 缓存：相同库存+相同已有清单，第二次不打上游', () async {
      final body = {
        'pantry': [
          {'name': '豆腐'}
        ],
        'existing': <String>[],
      };
      await hit('POST', '/api/ai/recommend', body);
      final second = await hit('POST', '/api/ai/recommend', body);
      expect(jsonDecode(await second.readAsString())['cached'], true);
      expect(seen.length, 1);
    });

    test('recipe_fill：菜名进、结构化菜谱出（步骤文本带时间关键词义务在 prompt 里）',
        () async {
      reply = {
        'choices': [
          {
            'message': {
              'content': jsonEncode({
                'sub': '酸甜开胃的经典下饭菜',
                'difficulty': 1,
                'self_time': 15,
                'servings': 2,
                'tags': ['家常', '快手'],
                'ingredients': [
                  {'name': '番茄', 'amount': '2个', 'kind': 'main'}
                ],
                'steps': [
                  {'text': '鸡蛋打散炒至凝固盛出，约 2 分钟', 'minutes': 2}
                ],
                'notes': '糖按口味'
              })
            }
          }
        ],
        'model': 'deepseek-flash',
        'usage': {'prompt_tokens': 30, 'completion_tokens': 120},
      };
      final res =
          await hit('POST', '/api/ai/recipe-fill', {'name': '番茄炒蛋'});
      final j = jsonDecode(await res.readAsString()) as Map<String, Object?>;
      expect(j['ok'], true);
      final r = j['result'] as Map;
      expect(r['sub'], '酸甜开胃的经典下饭菜');
      expect(r['steps'], isNotEmpty);
      // 上游确实收到了「步骤必须带时间」的约束
      expect(seen.single['body'], contains('时间'));
    });

    test('失败分类透传：401→auth、连不上→network', () async {
      reply = 401;
      var res = await hit('POST', '/api/ai/recipe-fill', {'name': 'x'});
      expect(res.statusCode, 502);
      expect(jsonDecode(await res.readAsString())['error'], 'auth');

      res = await hit('POST', '/api/ai/test', {
        'baseUrl': 'http://127.0.0.1:1/v1',
        'key': 'sk-x',
        'model': 'm',
      });
      expect(res.statusCode, 502);
      expect(jsonDecode(await res.readAsString())['error'], 'network');
    });

    test('test 接口用「待保存」的新参数验证，不要求先保存', () async {
      final res = await hit('POST', '/api/ai/test', {
        'baseUrl': upstreamUrl(),
        'key': 'sk-fresh-key',
        'model': 'deepseek-flash',
      });
      expect(res.statusCode, 200);
      expect(seen.single['auth'], 'Bearer sk-fresh-key');
      // 保存的旧 Key 没被动过
      expect(state.ai.config().key, 'sk-test-1234567890abcdEF');
    });
  });
}
