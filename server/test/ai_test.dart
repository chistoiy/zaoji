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

  group('R44 · 执行记录留痕', () {
    List<Map<String, Object?>> runs() =>
        state.db.db.select('SELECT * FROM ai_runs ORDER BY id').toList();

    final calorieBody = {
      'name': '番茄炒蛋',
      'servings': 2,
      'ingredients': [
        {'name': '番茄', 'amount': '2个', 'kind': 'main'}
      ]
    };

    test('成功调用留一行：输入(system+user+原始参数)与输出全文齐备', () async {
      await hit('POST', '/api/ai/calories', calorieBody);
      final rows = runs();
      expect(rows, hasLength(1));
      final r = rows.single;
      expect(r['feature'], 'calories');
      expect(r['ok'], 1);
      expect(r['cached'], 0);
      expect('${r['prompt_system']}', contains('热量估算器'));
      expect('${r['prompt_user']}', contains('番茄炒蛋'));
      expect('${r['input_json']}', contains('番茄')); // 原始参数也留痕
      expect('${r['output']}', contains('kcal_per_serving')); // 输出全文
      expect(r['in_tok'], 100);
      expect(r['out_tok'], 50);
      expect(r['source'], 'AI 测试机'); // 认证到的设备名
    });

    test('响应带 runId，供客户端本机记录对账（run_ref）', () async {
      final res = await hit('POST', '/api/ai/calories', calorieBody);
      final j = jsonDecode(await res.readAsString()) as Map;
      final id = j['runId'];
      expect(id, isNotNull);
      expect(runs().single['id'], id);
    });

    test('上游失败也留痕：ok=0 + error_kind，输出记错误文案', () async {
      reply = 401; // Key 被拒
      final res = await hit('POST', '/api/ai/calories', calorieBody);
      expect(res.statusCode, 502);
      final r = runs().single;
      expect(r['ok'], 0);
      expect(r['error_kind'], 'auth');
      expect('${r['output']}', contains('Key'));
      // 失败不该污染用量（没有真实成功）
      expect(state.ai.usage()['calls'], 0);
    });

    test('能力关闭(off)也留一行，且不打上游', () async {
      final c = state.ai.config()..flagNutrition = false;
      await state.ai.saveConfig(c);
      await hit('POST', '/api/ai/calories', calorieBody);
      final r = runs().single;
      expect(r['ok'], 0);
      expect(r['error_kind'], 'off');
      expect(seen, isEmpty);
    });

    test('缓存命中仍留痕，标 cached 且不重复计用量', () async {
      await hit('POST', '/api/ai/calories', calorieBody); // 第一次走上游
      await hit('POST', '/api/ai/calories', calorieBody); // 命中缓存
      final rows = runs();
      expect(rows, hasLength(2), reason: '两次调用都要看得到');
      expect(rows.last['cached'], 1);
      expect(rows.last['in_tok'], 0, reason: '命中没走上游，用量不重复计');
      expect(seen.length, 1);
      // 月度 calls 只统计真实上游那次
      expect(state.ai.usage()['calls'], 1);
    });

    test('连通测试留 feature=test 行', () async {
      await hit('POST', '/api/ai/test', {'baseUrl': upstreamUrl(), 'key': 'sk-x'});
      final r = runs().single;
      expect(r['feature'], 'test');
      expect(r['ok'], 1);
    });

    test('记录里绝不出现 Key 明文（输入留痕不含鉴权头）', () async {
      await hit('POST', '/api/ai/calories', calorieBody);
      final all = runs().map((e) => e.values.join('|')).join('\n');
      expect(all, isNot(contains('sk-test-1234567890abcdEF')));
    });
  });

  group('R44 · 执行记录查/删端点', () {
    Future<void> seed3() async {
      // 三个不同能力 + 一次失败
      await hit('POST', '/api/ai/calories', {
        'name': '番茄炒蛋',
        'servings': 2,
        'ingredients': [
          {'name': '番茄', 'amount': '2个', 'kind': 'main'}
        ]
      });
      await hit('POST', '/api/ai/recipe-fill', {'name': '红烧肉'});
      await hit('POST', '/api/ai/recommend', {
        'pantry': [
          {'name': '豆腐'}
        ],
        'existing': <String>[]
      });
    }

    test('GET /api/ai/runs 列表带 total，摘要不含全文', () async {
      await seed3();
      final res = await hit('GET', '/api/ai/runs');
      final j = jsonDecode(await res.readAsString()) as Map<String, Object?>;
      expect(j['ok'], true);
      expect(j['total'], 3);
      expect(j['runs'] as List, hasLength(3));
      final first = (j['runs'] as List).first as Map;
      expect(first.containsKey('promptUser'), isFalse,
          reason: '列表只给摘要，全文留在详情');
      expect(first['feature'], isNotNull);
    });

    test('列表按 feature 与 ok 筛选', () async {
      await seed3();
      final f = await hit('GET', '/api/ai/runs?feature=recommend');
      expect((jsonDecode(await f.readAsString()) as Map)['total'], 1);
      // 造一行失败
      final c = state.ai.config()..flagNutrition = false;
      await state.ai.saveConfig(c);
      await hit('POST', '/api/ai/calories', {
        'name': 'x',
        'ingredients': [
          {'name': 'y'}
        ]
      });
      final bad = await hit('GET', '/api/ai/runs?ok=0');
      expect((jsonDecode(await bad.readAsString()) as Map)['total'], 1);
    });

    test('关键词搜索命中 prompt 文本；转义 % 不误伤全表', () async {
      await seed3();
      final hit1 = await hit('GET', '/api/ai/runs?q=红烧肉');
      expect((jsonDecode(await hit1.readAsString()) as Map)['total'], 1);
      final none = await hit('GET', '/api/ai/runs?q=%25'); // URL 编码的 "%"
      expect((jsonDecode(await none.readAsString()) as Map)['total'], 0,
          reason: '裸 "%" 当字面搜，不该匹配所有行');
    });

    test('GET /api/ai/runs/<id> 返回全文；未知 id 404', () async {
      await seed3();
      final list = jsonDecode(await (await hit('GET', '/api/ai/runs')).readAsString())
          as Map<String, Object?>;
      final id = (list['runs'] as List).first['id'];
      final res = await hit('GET', '/api/ai/runs/$id');
      final run = jsonDecode(await res.readAsString())['run'] as Map;
      expect(run.containsKey('promptSystem'), isTrue);
      expect(run['output'], isNotNull);
      final missing = await hit('GET', '/api/ai/runs/999999');
      expect(missing.statusCode, 404);
    });

    test('DELETE /api/ai/runs/<id> 单删；再删不存在返回 deleted=0', () async {
      await seed3();
      final id = (jsonDecode(await (await hit('GET', '/api/ai/runs')).readAsString())
          as Map)['runs'][0]['id'];
      final del = await hit('DELETE', '/api/ai/runs/$id');
      expect((jsonDecode(await del.readAsString()) as Map)['deleted'], 1);
      final again = await hit('DELETE', '/api/ai/runs/$id');
      expect((jsonDecode(await again.readAsString()) as Map)['deleted'], 0);
    });

    test('DELETE /api/ai/runs 清空：全清与按能力清各算条数', () async {
      await seed3();
      final one = await hit('DELETE', '/api/ai/runs?feature=recommend');
      expect((jsonDecode(await one.readAsString()) as Map)['deleted'], 1);
      final all = await hit('DELETE', '/api/ai/runs');
      expect((jsonDecode(await all.readAsString()) as Map)['deleted'], 2);
      final after = jsonDecode(await (await hit('GET', '/api/ai/runs')).readAsString())
          as Map;
      expect(after['total'], 0);
    });

    test('删查端点也要鉴权：没 token 401', () async {
      expect((await hit('GET', '/api/ai/runs', null, false)).statusCode, 401);
      expect((await hit('DELETE', '/api/ai/runs', null, false)).statusCode, 401);
    });
  });

  group('R44 · 保留窗口修剪', () {
    test('滚动 recordDays 到期自动修剪，写一条时顺带清（不挂定时器）', () async {
      final c = state.ai.config()..recordDays = 90;
      await state.ai.saveConfig(c);
      final day = 24 * 60 * 60 * 1000;
      // 手工塞一行 200 天前的（模拟历史遗留）+ 一次正常调用（触发修剪）
      state.db.db.execute(
        'INSERT INTO ai_runs (at, feature, ok) VALUES (?, ?, 1)',
        [DateTime.now().millisecondsSinceEpoch - 200 * day, 'calories'],
      );
      expect(state.db.db.select('SELECT COUNT(*) c FROM ai_runs').first['c'], 1);
      await hit('POST', '/api/ai/calories', {
        'name': 'n',
        'servings': 1,
        'ingredients': [
          {'name': 'i', 'amount': 'a', 'kind': 'main'}
        ]
      });
      // 触发一次写入后，超期的那行应被清掉，只剩这次的新行
      final left = state.db.db
          .select('SELECT at FROM ai_runs ORDER BY at')
          .map((r) => r['at'] as int)
          .toList();
      expect(left, hasLength(1));
      expect(DateTime.now().millisecondsSinceEpoch - left.single, lessThan(day));
    });

    test('recordDays=0 = 永久保留，只受条数封顶约束', () async {
      final c = state.ai.config()..recordDays = 0;
      await state.ai.saveConfig(c);
      final day = 24 * 60 * 60 * 1000;
      state.db.db.execute(
        'INSERT INTO ai_runs (at, feature, ok) VALUES (?, ?, 1)',
        [DateTime.now().millisecondsSinceEpoch - 5000 * day, 'calories'],
      );
      await hit('POST', '/api/ai/calories', {
        'name': 'n',
        'servings': 1,
        'ingredients': [
          {'name': 'i', 'amount': 'a', 'kind': 'main'}
        ]
      });
      final cnt = state.db.db.select('SELECT COUNT(*) c FROM ai_runs').first['c'];
      expect(cnt, 2, reason: '永久的旧行不该被时间修剪（封顶 2000 条还没到）');
    });
  });

  group('R44 · 提示词占位符校验（静态）', () {
    test('缺必填占位符 → 拒', () {
      expect(
        AiService.validatePrompt('calories', '随便', '菜名：{{name}}（{{servings}} 人份）'),
        contains('ingredients'),
        reason: '把食材段删了模型就没数据了，必须挡下',
      );
    });
    test('未知占位符 → 拒', () {
      expect(
        AiService.validatePrompt('calories', '{{foo}}', '{{name}}{{servings}}{{ingredients}}'),
        contains('foo'),
      );
    });
    test('必填齐 + 无未知 → 通过（可把必填挪进 system）', () {
      expect(
        AiService.validatePrompt(
            'calories', '数据：{{ingredients}}', '{{name}} {{servings}}'),
        isNull,
      );
    });
    test('recipe_fill 的 {{hint}} 是可选的', () {
      expect(AiService.validatePrompt('recipe_fill', 'x', '菜名：{{name}}'), isNull);
    });
    test('render 替换全部占位符', () {
      expect(
        AiService.render('菜名：{{name}}（{{servings}}）',
            {'name': '番茄炒蛋', 'servings': '2'}),
        '菜名：番茄炒蛋（2）',
      );
    });
  });

  group('R44 · 提示词管理与端点', () {
    final calorieBody = {
      'name': '番茄炒蛋',
      'servings': 2,
      'ingredients': [
        {'name': '番茄', 'amount': '2个', 'kind': 'main'}
      ]
    };

    test('无覆盖时渲染与升级前逐字节一致（默认模板照抄原文）', () async {
      await hit('POST', '/api/ai/calories', calorieBody);
      final sent = jsonDecode(seen.single['body'] as String) as Map;
      final msgs = (sent['messages'] as List).cast<Map<String, Object?>>();
      final sys = msgs.firstWhere((m) => m['role'] == 'system')['content'] as String;
      final user = msgs.firstWhere((m) => m['role'] == 'user')['content'] as String;
      expect(sys, startsWith('你是家庭菜谱的热量估算器'));
      expect(user, '菜名：番茄炒蛋（2 人份）\n食材：\n主料：番茄 2个');
    });

    test('GET /api/ai/prompts 给三能力生效模板 + 默认 + 未改标记', () async {
      final res = await hit('GET', '/api/ai/prompts');
      final j = jsonDecode(await res.readAsString()) as Map<String, Object?>;
      final list = (j['prompts'] as List).cast<Map<String, Object?>>();
      expect(list, hasLength(3));
      final cal = list.firstWhere((e) => e['feature'] == 'calories');
      expect(cal['modified'], false);
      expect(cal['system'], cal['defaultSystem']);
      expect((cal['placeholders'] as Map)['required'],
          containsAll(['{{name}}', '{{servings}}', '{{ingredients}}']));
    });

    test('保存覆盖后立即对后续调用生效（FR-AI-53）', () async {
      final save = await hit('POST', '/api/ai/prompts', {
        'feature': 'calories',
        'system': '自定义热量系统：{{name}} 用了 {{ingredients}}，{{servings}} 人',
        'user': '估算 {{name}}',
      });
      expect((jsonDecode(await save.readAsString()) as Map)['ok'], true);
      await hit('POST', '/api/ai/calories', calorieBody);
      final sent = jsonDecode(seen.single['body'] as String) as Map;
      final sys = (sent['messages'] as List)
          .cast<Map<String, Object?>>()
          .firstWhere((m) => m['role'] == 'system')['content'] as String;
      expect(sys, startsWith('自定义热量系统：番茄炒蛋'));
      expect(sys, contains('番茄')); // {{ingredients}} 渲染进 system
      // 记录留痕的也是渲染后的最终文本
      final row = state.db.db
          .select("SELECT prompt_system FROM ai_runs WHERE feature='calories'")
          .first;
      expect('${row['prompt_system']}', startsWith('自定义热量系统'));
    });

    test('保存会清空结果缓存（改 prompt 不命中旧结果）', () async {
      await hit('POST', '/api/ai/calories', calorieBody); // 进缓存
      await hit('POST', '/api/ai/prompts', {
        'feature': 'calories',
        'system': '热量：{{name}} {{servings}} {{ingredients}}',
        'user': '{{name}}',
      });
      seen.clear();
      await hit('POST', '/api/ai/calories', calorieBody);
      expect(seen, isNotEmpty, reason: 'prompt 改了还命中旧缓存 = 改了没生效');
    });

    test('缺必填占位符 → 400 bad_placeholder，不写库', () async {
      final res = await hit('POST', '/api/ai/prompts', {
        'feature': 'calories',
        'system': '热量 {{name}}', // 缺 servings/ingredients
        'user': '{{name}}',
      });
      expect(res.statusCode, 400);
      final j = jsonDecode(await res.readAsString()) as Map;
      expect(j['error'], 'bad_placeholder');
      expect(state.db.db.select('SELECT 1 FROM ai_prompts').length, 0);
    });

    test('reset 回落默认', () async {
      await hit('POST', '/api/ai/prompts', {
        'feature': 'recipe_fill',
        'system': '覆盖 {{name}}',
        'user': '菜名：{{name}}',
      });
      expect(state.db.db.select("SELECT 1 FROM ai_prompts WHERE feature='recipe_fill'").length, 1);
      final r = await hit('POST', '/api/ai/prompts/reset', {'feature': 'recipe_fill'});
      expect((jsonDecode(await r.readAsString()) as Map)['ok'], true);
      expect(state.db.db.select("SELECT 1 FROM ai_prompts WHERE feature='recipe_fill'").length, 0);
      // 回落：下次调用用内置默认
      await hit('POST', '/api/ai/recipe-fill', {'name': '红烧肉'});
      final sys = (jsonDecode(seen.single['body'] as String)['messages'] as List)
          .cast<Map<String, Object?>>()
          .firstWhere((m) => m['role'] == 'system')['content'] as String;
      expect(sys, startsWith('你是中式家常菜菜谱写手'));
    });

    test('recipe_fill 无 hint 时 user 与旧代码逐字节一致', () async {
      await hit('POST', '/api/ai/recipe-fill', {'name': '红烧肉'});
      final user = (jsonDecode(seen.single['body'] as String)['messages'] as List)
          .cast<Map<String, Object?>>()
          .firstWhere((m) => m['role'] == 'user')['content'] as String;
      expect(user, '菜名：红烧肉');
    });

    test('prompts 端点也要鉴权', () async {
      expect((await hit('GET', '/api/ai/prompts', null, false)).statusCode, 401);
      expect((await hit('POST', '/api/ai/prompts', {'feature': 'calories'}, false)).statusCode, 401);
    });
  });
}
