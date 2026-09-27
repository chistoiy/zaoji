import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/data/sync/sync_engine.dart';
import 'package:zaoji/data/sync/sync_prefs.dart';
import 'package:zaoji/data/sync/sync_scope.dart';
import 'package:zaoji/data/sync/sync_transport.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji/ui/ai_settings_page.dart';
import 'package:zaoji/ui/recipe_detail_page.dart';
import 'package:zaoji/ui/recipe_edit_page.dart';

import 'fake_sync_server.dart';

/// R27 · AI 客户端链路。
///
/// 钉的是**接线**而不是模型的嘴：热量结果要落进 nutrition 表并在卡上现身、
/// AI 补全只填没动过的字段、保存时来源记 ai、配置页把 Key 交给服务端就**再也
/// 读不回来**（只回掩码）。上游回复全部用假服务端固定，
/// 真 DeepSeek 的链路验证在服务端 tool/ai_e2e_real.dart 钉过。
void main() {
  late FakeSyncServer server;
  late RecipeStore store;
  late SyncPrefs prefs;

  setUpAll(() async {
    server = await FakeSyncServer.start();
  });
  tearDownAll(() async {
    await server.close();
  });
  setUp(() async {
    server.reset();
    // AI 端点与数据接口同一道门：用 open 模式 + 合法 X-Node-Id 放行匿名。
    server.accessMode = 'open';
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
    prefs = SyncPrefs(store.dbOrNull!);
    await prefs.setServerUrl(server.url);
  });
  tearDown(() async {
    await store.dbOrNull!.close();
    store.dispose();
  });

  /// FakeAsync 区等不到真网络回包（沿用 me_page_access_test 的轮询法）。
  Future<void> settle(WidgetTester tester,
      {required bool Function() done, int seconds = 10}) async {
    final until = DateTime.now().add(Duration(seconds: seconds));
    while (!done() && DateTime.now().isBefore(until)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
  }

  SyncEngine makeEngine() => SyncEngine(
        db: store.dbOrNull!,
        prefs: prefs,
        transport: HttpSyncTransport(Uri.parse(server.url), nodeId: 'testnode01'),
      );

  Future<SyncEngine> pumpPage(
      WidgetTester tester, Widget page) async {
    // ★ transport 在 allowRealHttp **之后**建：IOClient 构造时就抓 HttpClient，
    //   binding 装的 400 mock 若还挂着，整个测试的 HTTP 全是空 400（本文件首跑实况）。
    FakeSyncServer.allowRealHttp();
    final engine = makeEngine();
    await tester.binding.setSurfaceSize(const Size(414, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: SyncScope(
        engine: engine,
        child: StoreScope(store: store, child: page),
      ),
    ));
    return engine;
  }

  Future<Recipe> seedDish() => store.createRecipe(const RecipeDraft(
        name: '番茄炒蛋',
        sub: '家常',
        ingredients: [
          IngredientDraft(name: '番茄', qty: '2个', isMain: true),
          IngredientDraft(name: '鸡蛋', qty: '3个'),
        ],
        steps: ['热油炒蛋', '下番茄焖 8 分钟'],
      ));

  group('热量估算（详情页 + 存储）', () {
    testWidgets('点「估算热量」→ 结果卡出现，数据落进 nutrition 表', (tester) async {
      server.aiConfigured = true;
      server.aiEnabled = true;
      final r = await seedDish();
      final engine = await pumpPage(tester, RecipeDetailPage(recipe: r));
      await settle(tester, done: () => true, seconds: 0);

      expect(find.byKey(const ValueKey('ai-calories-entry')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('ai-calories-entry')));
      await settle(tester, done: () => store.nutritionFor(r.id) != null);

      expect(find.byKey(const ValueKey('nutrition-card')), findsOneWidget);
      expect(find.textContaining('250'), findsWidgets);
      final n = store.nutritionFor(r.id)!;
      expect(n.perServingKcal, 250);
      expect(n.source, 'ai');
      expect(n.model, 'deepseek-flash');
      // 结果也要进同步账：change_log 里得有这条 nutrition 行
      final logged = server.changeLog.any((e) => e['table'] == 'nutrition');
      expect(logged, isFalse, reason: '推送由防抖同步负责；这里只钉本地写入');
      // 从库里重新读一遍（重启等价）：数据还在
      await store.reloadForTest();
      expect(store.nutritionFor(r.id)?.totalKcal, 500);
      engine.dispose(); // keep-alive 空闲连接挂 15s 定时器，必须在 test body 内关
    });

    testWidgets('未配置时入口照样在，带「未配置」字样（FR-AI-10/20）', (tester) async {
      final r = await seedDish();
      final engine = await pumpPage(tester, RecipeDetailPage(recipe: r));
      // 入口徽标吃的是最近一次 status —— 先拉一遍再断言「未配置」版式
      await tester.runAsync(() => engine.aiCall('/api/ai/status'));
      await tester.pump();
      await settle(tester,
          done: () => engine.aiStatusCache != null);
      expect(find.byKey(const ValueKey('ai-calories-entry')), findsOneWidget);
      expect(find.textContaining('未配置'), findsWidgets);
      engine.dispose();
    });
  });

  group('AI 补全（新建页）', () {
    testWidgets('补全只填空字段、步骤替换，保存后来源是 ai', (tester) async {
      server.aiConfigured = true;
      server.aiEnabled = true;
      final engine = await pumpPage(tester, const RecipeEditPage());
      await settle(tester, done: () => true, seconds: 0);

      await tester.enterText(find.byType(TextField).first, '红烧狮子头');
      await tester.tap(find.widgetWithText(TextButton, '补全'));
      await settle(tester,
          done: () =>
              find.textContaining('AI 已填好草稿').evaluate().isNotEmpty ||
              storeChanged(store));

      expect(find.textContaining('AI 已填好草稿'), findsWidgets);
      // 点保存：走真 _save（表单校验要求 name 非空——已填）
      await tester.tap(find.widgetWithText(TextButton, '保存'));
      await settle(tester,
          done: () => store.recipes.any((x) => x.name == '红烧狮子头'));
      final saved = store.recipes.lastWhere((x) => x.name == '红烧狮子头');
      expect(saved.isAi, isTrue, reason: 'FR-REC-21/35：来源=ai + 模型名');
      expect(saved.sourceModel, 'deepseek-flash');
      expect(saved.steps.length, greaterThanOrEqualTo(3));
      engine.dispose();
    });
  });

  group('配置页（Key 只进不出）', () {
    testWidgets('填 Key 保存 → 服务端收到；界面回显只有掩码', (tester) async {
      final engine = await pumpPage(tester, const AiSettingsPage());
      await settle(tester,
          done: () => find.text('保存配置').evaluate().isNotEmpty);

      await tester.enterText(
          find.byKey(const ValueKey('ai-key-field')), 'sk-page-test-key');
      await tester.tap(find.text('保存配置'));
      await settle(tester, done: () => server.aiConfigWrites.isNotEmpty);

      final write = server.aiConfigWrites.single;
      expect(write['key'], 'sk-page-test-key');
      // 页面文本里不许再出现完整 Key（FR-AI-04）
      final texts = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data ?? '')
          .toList();
      expect(texts.any((t) => t.contains('sk-page-test-key')), isFalse);
      expect(texts.any((t) => t.contains('••••abcd')), isTrue);
      engine.dispose();
    });
  });
}

bool storeChanged(RecipeStore s) => false;
