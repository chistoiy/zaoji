import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/data/sync/sync_engine.dart';
import 'package:zaoji/data/sync/sync_prefs.dart';
import 'package:zaoji/data/sync/sync_scope.dart';
import 'package:zaoji/data/sync/sync_transport.dart';
import 'package:zaoji/ui/conflict_box_page.dart';

import 'fake_sync_server.dart';

/// R22 · 冲突箱页面走通。
///
/// 测试姿势沿用 me_page_access_test 的三件套：binding 初始化后撤 400 mock
/// （allowRealHttp）、轮询谓词代替固定 sleep（localhost 真往返 ~1.4s）、
/// 引擎在 **test body 内** dispose（keep-alive 定时器会挂进 FakeAsync 区）。
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
    FakeSyncServer.allowRealHttp();
    engine = SyncEngine(
      db: store.dbOrNull!,
      prefs: prefs,
      transport: HttpSyncTransport(Uri.parse(server.url), nodeId: nodeId),
      onDataApplied: () => store.reload(),
    );
    await prefs.setServerUrl(server.url);
    server.reset();
  });

  tearDown(() async {
    await store.dbOrNull!.close();
    store.dispose();
  });

  Future<void> settleReal(
    WidgetTester tester, {
    required bool Function() done,
    int seconds = 10,
  }) async {
    final until = DateTime.now().add(Duration(seconds: seconds));
    while (!done() && DateTime.now().isBefore(until)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
  }

  /// 服务端放一条真冲突，客户端同步一轮后打开冲突箱页。
  Future<void> pumpWithConflict(WidgetTester tester) async {
    server.accessMode = 'open';
    // 菜名刻意与两版取值不同——同名会让「分组标题」与「选项值」两个 Text 撞车，
    // 断言分不清找的是哪个（第一版就栽在这）。
    server.injectRecipe(id: 'cf-r', name: '茄汁蛋');
    server.injectConflict(
        rowId: 'cf-r', field: 'name', localValue: 'A 版', remoteValue: 'B 版');
    await tester.runAsync(() => engine.syncIfPaired());

    tester.view.physicalSize = const Size(414, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: StoreScope(
        store: store,
        child: SyncScope(
          engine: engine,
          child: const ConflictBoxPage(),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('两版并排 + 选 B 应用 → 空态；本地行随之定稿', (tester) async {
    await pumpWithConflict(tester);

    expect(find.text('1 处待裁决 · 逐字段选保留哪版'), findsOneWidget);
    expect(find.text('菜名'), findsOneWidget);
    expect(find.text('A 版'), findsOneWidget);
    expect(find.text('B 版'), findsOneWidget);
    expect(find.textContaining('改动 B'), findsOneWidget);

    await tester.tap(find.text('B 版'));
    await tester.pump();
    await tester.tap(find.text('应用这一组的裁决'));
    await settleReal(
      tester,
      done: () => find.text('没有待裁决的冲突').evaluate().isNotEmpty,
    );

    expect(store.recipeById('cf-r')!.name, 'B 版');
    // 卡片消失靠的是拉回 resolved 标记——不是本地偷偷藏起来
    expect(await store.openConflictCount(), 0);
    engine.dispose();
  });

  testWidgets('自己填：mergedValue 进请求体，落库的是手填值', (tester) async {
    await pumpWithConflict(tester);

    await tester.tap(find.text('都不是，自己填'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '合稿版');
    await tester.tap(find.text('应用这一组的裁决'));
    await settleReal(
      tester,
      done: () => store.recipeById('cf-r')?.name == '合稿版',
    );

    expect(store.recipeById('cf-r')!.name, '合稿版');
    engine.dispose();
  });

  testWidgets('一条冲突都没有：给空态而不是空白', (tester) async {
    server.accessMode = 'open';
    tester.view.physicalSize = const Size(414, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: StoreScope(
        store: store,
        child: SyncScope(
          engine: engine,
          child: const ConflictBoxPage(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('没有待裁决的冲突'), findsOneWidget);
    engine.dispose();
  });
}
