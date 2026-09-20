import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/sync/sync_engine.dart';
import 'package:zaoji/data/sync/sync_prefs.dart';
import 'package:zaoji/data/sync/sync_transport.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import 'fake_sync_server.dart';

/// R21 · 客户端的三态准入：免配对来访者、口令接入、自动同步策略。
///
/// 与 sync_engine_test 同一立场：走真 HTTP + 假服务端，引擎零 mock。
void main() {
  late FakeSyncServer server;
  late RecipeStore store;
  late SyncEngine engine;
  late SyncPrefs prefs;
  String nodeId = '';

  setUpAll(() async {
    server = await FakeSyncServer.start();
  });

  tearDownAll(() async {
    await server.close();
  });

  setUp(() async {
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
    prefs = SyncPrefs(store.dbOrNull!);
    nodeId = await prefs.nodeId();
    engine = SyncEngine(
      db: store.dbOrNull!,
      prefs: prefs,
      transport: HttpSyncTransport(Uri.parse(server.url), nodeId: nodeId),
      // 拉到的行要进 store 的内存缓存才看得到（与 main.dart 生产接线一致）
      onDataApplied: () => store.reload(),
    );
    // 来访者的第一步总是"知道地址"：网页端由 origin 预填，
    // 测试里等价地直接写进 prefs。
    await prefs.setServerUrl(server.url);
    server.reset();
  });

  tearDown(() async {
    engine.dispose();
    await store.dbOrNull!.close();
    store.dispose();
  });

  group('开放模式的免配对来访者', () {
    test('★ syncIfPaired 不再要求配对：open 模式下自动拉下服务端数据', () async {
      server.accessMode = 'open';
      server.injectRecipe(id: 'from-b', name: '别人家的红烧肉');

      await engine.syncIfPaired();

      expect(store.recipes.any((r) => r.id == 'from-b'), isTrue,
          reason: '没配过对、没点过按钮，数据就该在路上——这是模式一的整个卖点');
      expect(await prefs.isPaired(), isFalse, reason: '自动同步不等于偷偷配对');
      expect(server.visitorNodes, contains(nodeId));
    });

    test('本地写入也会被自动推上去（水位线机制对来访者同样成立）', () async {
      server.accessMode = 'open';
      await store.createRecipe(const RecipeDraft(name: '来访者的菜'));

      await engine.syncIfPaired();

      expect(server.rows['recipe']?.values.any(
        (r) => r['name'] == '来访者的菜',
      ), isTrue);
    });

    test('缺 nodeId 头的匿名请求被假服务端拒 → 引擎安静停在 neverPaired', () async {
      server.accessMode = 'open';
      // 换一个不带 nodeId 的 transport（模拟旧客户端/异常）
      engine.dispose();
      engine = SyncEngine(
        db: store.dbOrNull!,
        prefs: prefs,
        transport: HttpSyncTransport(Uri.parse(server.url)),
      );
      await engine.syncIfPaired();
      expect(engine.phase, isNot(SyncPhase.idle));
    });
  });

  group('口令模式', () {
    test('未接入时 syncIfPaired 不做无谓请求也不报错；join 后同步恢复', () async {
      server.accessMode = 'passcode';
      server.passcode = 'mama-2026';
      server.injectRecipe(id: 'p-1', name: '口令后的菜');

      await engine.syncIfPaired();
      expect(store.recipes.any((r) => r.id == 'p-1'), isFalse);
      expect(engine.lastError, isNull, reason: '没接入不是错误，是状态');

      await engine.join(serverUrl: server.url, passcode: 'mama-2026');
      expect(await prefs.isPaired(), isTrue);
      expect(engine.lastError, isNull);
      expect(store.recipes.any((r) => r.id == 'p-1'), isTrue);
    });

    test('口令错 → lastError 给出服务端的原话，token 不落库', () async {
      server.accessMode = 'passcode';
      server.passcode = 'mama-2026';
      await engine.join(serverUrl: server.url, passcode: '错的');
      expect(engine.lastError, contains('口令'));
      expect(await prefs.isPaired(), isFalse);
    });

    test('解除接入 = unpair 同一条路：token 清掉，回到未接入', () async {
      server.accessMode = 'passcode';
      server.passcode = 'ok';
      await engine.join(serverUrl: server.url, passcode: 'ok');
      await engine.unpair();
      expect(await prefs.isPaired(), isFalse);
    });
  });

  group('自动同步策略（visitorManualSync）', () {
    test('★ 服务端要求手动时：来访者的自动触发全部停摆，手动 sync() 仍可用', () async {
      server.accessMode = 'open';
      server.visitorManualSync = true;
      server.injectRecipe(id: 'manual-1', name: '只手动才来');

      await engine.syncIfPaired();
      expect(store.recipes.any((r) => r.id == 'manual-1'), isFalse);

      await engine.sync();
      expect(store.recipes.any((r) => r.id == 'manual-1'), isTrue,
          reason: '策略关的是自动，不是同步本身');
    });

    test('已持有 token 的设备不受该开关影响', () async {
      // 先在口令模式接入拿到 token，再把服务端切回"开放 + 要求手动"——
      // 这正是设计承诺的场景：门换了，已进来的设备照常自动同步。
      server.accessMode = 'passcode';
      server.passcode = 'x';
      await engine.join(serverUrl: server.url, passcode: 'x');
      server.accessMode = 'open';
      server.visitorManualSync = true;
      server.injectRecipe(id: 'auto-2', name: '配对机自动拿');

      await engine.syncIfPaired();
      expect(store.recipes.any((r) => r.id == 'auto-2'), isTrue);
    });
  });

  group('准入配置读取', () {
    test('refreshAccessConfig 缓存模式与开关，供「我的」页决定渲染哪套接入 UI', () async {
      server.accessMode = 'passcode';
      server.visitorManualSync = true;
      await engine.refreshAccessConfig();
      expect(engine.accessMode, SyncAccessMode.passcode);
      expect(engine.visitorManualSync, isTrue);
    });

    test('连不上服务器时不炸：模式保持未知（null），UI 回退到既有配对码块', () async {
      engine.dispose();
      engine = SyncEngine(
        db: store.dbOrNull!,
        prefs: prefs,
        transport: HttpSyncTransport(Uri.parse('http://127.0.0.1:9'), nodeId: 'node-x'),
      );
      await engine.refreshAccessConfig();
      expect(engine.accessMode, isNull);
    });
  });
}
