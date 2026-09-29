import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/data/sync/sync_engine.dart';
import 'package:zaoji/data/sync/sync_prefs.dart';
import 'package:zaoji/data/sync/sync_scope.dart';
import 'package:zaoji/data/sync/sync_transport.dart';
import 'package:zaoji/ui/ai_runs_page.dart';

import 'fake_sync_server.dart';

/// R44 · AI 执行记录页（客户端侧）。
///
/// 钉的是**读端接线 + 删查动作真打到服务端**：
/// ① 列表从 /api/ai/runs 取（摘要卡 + 状态徽标 + 本机标记）；
/// ② 能力筛选把 feature 编进查询串再拉；
/// ③ 单删走 `DELETE /api/ai/runs/<id>`、清空走 `DELETE /api/ai/runs`，删完列表跟着少；
/// ④ 详情拉全文；⑤ 取消不发 DELETE。
/// 假服务端与真服务端同形状；上游回复全是固定的，不碰网络。
void main() {
  late FakeSyncServer server;
  late RecipeStore store;
  late SyncPrefs prefs;

  setUpAll(() async => server = await FakeSyncServer.start());
  tearDownAll(() async => server.close());

  setUp(() async {
    server.reset();
    server.accessMode = 'open';
    server.aiConfigured = true;
    server.aiEnabled = true;
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
    prefs = SyncPrefs(store.dbOrNull!);
    await prefs.setServerUrl(server.url);
  });

  tearDown(() async {
    await store.dbOrNull!.close();
    store.dispose();
  });

  SyncEngine makeEngine() => SyncEngine(
        db: store.dbOrNull!,
        prefs: prefs,
        transport:
            HttpSyncTransport(Uri.parse(server.url), nodeId: 'testnode01'),
      );

  Future<SyncEngine> pumpPage(WidgetTester tester, Widget page) async {
    FakeSyncServer.allowRealHttp();
    final engine = makeEngine();
    await tester.binding.setSurfaceSize(const Size(414, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Scope 抬到 Navigator 之上（builder 里）——与真机 main.dart 一致，
    // 否则 push 出去的详情页在 Scope 外，取不到 engine/store。
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => SyncScope(
        engine: engine,
        child: StoreScope(store: store, child: child!),
      ),
      home: page,
    ));
    return engine;
  }

  /// FakeAsync 里等真网络：轮询到 done() 或超时。
  Future<void> settle(WidgetTester tester,
      {required bool Function() done, int seconds = 10}) async {
    final until = DateTime.now().add(Duration(seconds: seconds));
    while (!done() && DateTime.now().isBefore(until)) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
  }

  /// 等一次「点了之后又要打服务端、再刷 UI」的往返（删/清/详情）：
  /// runAsync 放行真网络 → pump 让新状态上屏，直到 [done] 或超时。
  Future<void> waitUntil(WidgetTester tester, bool Function() done,
      {int seconds = 8}) async {
    final until = DateTime.now().add(Duration(seconds: seconds));
    while (!done() && DateTime.now().isBefore(until)) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// 用一次真实能力调用往假服务端塞执行记录（会带 runId）。
  /// 真网络必须跑在 [WidgetTester.runAsync] 里——FakeAsync 的时钟不放行真 I/O。
  Future<void> seedRun(WidgetTester tester, {String feature = 'calories'}) async {
    FakeSyncServer.allowRealHttp();
    final engine = makeEngine();
    await tester.runAsync(() async {
      // 演失败场景（aiFailWith）时 aiCall 会抛 SyncTransportException(502) ——
      // 记录此时已在服务端落好，异常照吞，只留下那条留痕。
      try {
        switch (feature) {
          case 'calories':
            await engine.aiCall('/api/ai/calories', {
              'name': '番茄炒蛋',
              'servings': 2,
              'ingredients': [
                {'name': '番茄', 'amount': '2个', 'kind': 'main'}
              ]
            });
          case 'recommend':
            await engine.aiCall('/api/ai/recommend', {
              'pantry': [
                {'name': '豆腐'}
              ],
              'existing': <String>[],
            });
          default:
            await engine.aiCall('/api/ai/recipe-fill', {'name': '红烧肉'});
        }
      } catch (_) {}
    });
    engine.dispose();
  }

  testWidgets('列表渲染：摘要卡 + 成功/失败徽标各就各位', (tester) async {
    await seedRun(tester, feature: 'calories');
    server.aiFailWith = 'auth'; // 再塞一条失败的
    await seedRun(tester, feature: 'recommend');
    server.aiFailWith = null;

    final engine = await pumpPage(tester, const AiRunsPage());
    await settle(tester, done: () => server.aiRunsListCalls >= 1);

    expect(find.byKey(const ValueKey('run-card-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-card-2')), findsOneWidget);
    expect(find.text('成功'), findsOneWidget);
    expect(find.text('失败'), findsOneWidget);
    // 能力名既出现在筛选 chip 也出现在卡片标题 → 用 findsWidgets
    expect(find.text('热量估算'), findsWidgets);
    expect(find.text('菜品推荐'), findsWidgets);
    engine.dispose();
  });

  testWidgets('能力筛选把 feature 编进查询串再拉', (tester) async {
    await seedRun(tester, feature: 'calories');
    await seedRun(tester, feature: 'recommend');

    final engine = await pumpPage(tester, const AiRunsPage());
    await settle(tester, done: () => server.aiRunsListCalls >= 1);
    server.aiRunsListCalls = 0;

    await tester.tap(find.byKey(const ValueKey('chip-0-菜品推荐')));
    await settle(tester, done: () => server.aiRunsListCalls >= 1);

    expect(find.byKey(const ValueKey('run-card-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('run-card-1')), findsNothing);
    engine.dispose();
  });

  testWidgets('单删：确认后打 DELETE /api/ai/runs/<id>，卡片消失', (tester) async {
    await seedRun(tester);

    final engine = await pumpPage(tester, const AiRunsPage());
    await settle(tester, done: () => server.aiRunsListCalls >= 1);
    expect(find.byKey(const ValueKey('run-card-1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('run-del-1')));
    await settle(tester, done: () => true, seconds: 0);
    await tester.tap(find.byKey(const ValueKey('run-del-confirm')));
    // 删是「打服务端 → 成功后才从列表摘卡」，要 runAsync 放行这次 DELETE
    await waitUntil(tester,
        () => find.byKey(const ValueKey('run-card-1')).evaluate().isEmpty);
    expect(server.aiRunsDeleteCalls, 1);
    expect(find.text('还没有执行记录'), findsOneWidget);
    engine.dispose();
  });

  testWidgets('取消删除：不发 DELETE', (tester) async {
    await seedRun(tester);

    final engine = await pumpPage(tester, const AiRunsPage());
    await settle(tester, done: () => server.aiRunsListCalls >= 1);
    await tester.tap(find.byKey(const ValueKey('run-del-1')));
    await settle(tester, done: () => true, seconds: 0);
    await tester.tap(find.byKey(const ValueKey('run-del-cancel')));
    await settle(tester, done: () => true, seconds: 0);

    expect(server.aiRunsDeleteCalls, 0);
    expect(find.byKey(const ValueKey('run-card-1')), findsOneWidget);
    engine.dispose();
  });

  testWidgets('清空：确认后打 DELETE /api/ai/runs 并回到空态', (tester) async {
    await seedRun(tester);
    await seedRun(tester, feature: 'recommend');

    final engine = await pumpPage(tester, const AiRunsPage());
    await settle(tester, done: () => server.aiRunsListCalls >= 1);
    expect(find.byKey(const ValueKey('ai-runs-clear')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('ai-runs-clear')));
    await settle(tester, done: () => true, seconds: 0);
    await tester.tap(find.byKey(const ValueKey('run-clear-confirm')));
    // 清空后 _clearAll 触发一次 reset 重载，等它把空态拉回来
    await waitUntil(tester,
        () => find.text('还没有执行记录').evaluate().isNotEmpty);
    expect(server.aiRunsClearCalls, 1);
    expect(find.text('还没有执行记录'), findsOneWidget);
    engine.dispose();
  });

  testWidgets('本机发起的条目叠「本机」标记（run_ref 对账）', (tester) async {
    await seedRun(tester); // 服务端有 id=1 的记录
    // 本机记一条指向 run 1 的 ai_usage（模拟当初是从这台设备发的）
    await store.logAiRun(
        feature: 'calories', ok: true, runRef: '1', summary: '番茄炒蛋');

    final engine = await pumpPage(tester, const AiRunsPage());
    await settle(tester, done: () => server.aiRunsListCalls >= 1);
    expect(find.text('本机'), findsOneWidget);
    engine.dispose();
  });

  testWidgets('点卡片进详情：拉全文并展示输入/输出', (tester) async {
    await seedRun(tester);

    final engine = await pumpPage(tester, const AiRunsPage());
    await settle(tester, done: () => server.aiRunsListCalls >= 1);

    await tester.tap(find.byKey(const ValueKey('run-card-1')));
    await waitUntil(tester,
        () => find.text('输入 · System').evaluate().isNotEmpty);
    expect(find.text('输入 · System'), findsOneWidget);
    expect(find.text('输入 · User'), findsOneWidget);
    expect(find.text('输出'), findsOneWidget);
    engine.dispose();
  });

  testWidgets('无记录 → 空态文案（不教学）', (tester) async {
    final engine = await pumpPage(tester, const AiRunsPage());
    await settle(tester, done: () => server.aiRunsListCalls >= 1);
    expect(find.text('还没有执行记录'), findsOneWidget);
    engine.dispose();
  });
}
