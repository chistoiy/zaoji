import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/data/sync/sync_engine.dart';
import 'package:zaoji/data/sync/sync_prefs.dart';
import 'package:zaoji/data/sync/sync_scope.dart';
import 'package:zaoji/data/sync/sync_transport.dart';
import 'package:zaoji/ui/me_page.dart';

import 'fake_sync_server.dart';

/// R21「我的」页三态渲染测试。
///
/// 只 pump SyncScope + MePage（不 pump 整个 App）：这一页对全局的唯一依赖
/// 就是引擎，模式分支是纯 UI 判定，没必要为它拖起 store 注入的整棵树。
void main() {
  late FakeSyncServer server;
  late RecipeStore store;
  late SyncEngine engine;
  late SyncPrefs prefs;

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
    server.reset();
  });

  // ★ transport 必须在 **test body 内** 关：dart:io 的 keep-alive 空闲连接
  // 会在 FakeAsync 区挂一个 15 秒的定时器，tearDown 里再 close 已经晚了，
  // binding 收尾直接报「Pending timers」。
  tearDown(() async {
    await store.dbOrNull!.close();
    store.dispose();
  });

  /// FakeAsync 区等不到真网络的回包（R11 同一条坑），而且这台 Windows 的
  /// localhost 往返实测要 ~1.4s——固定时长会赌输。轮询到谓词成立再回虚拟时间。
  Future<void> settleReal(WidgetTester tester, {required bool Function() done, int seconds = 10}) async {
    final until = DateTime.now().add(Duration(seconds: seconds));
    while (!done() && DateTime.now().isBefore(until)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    }
    await tester.pumpAndSettle(const Duration(milliseconds: 200));
  }

  Future<void> pumpMe(WidgetTester tester, {String? transportUrl}) async {
    // binding 已在这之前初始化完（它把 HttpClient 换成回 400 的 mock），
    // 现在撤掉才拿得到真网络。见 FakeSyncServer.allowRealHttp 的注释。
    FakeSyncServer.allowRealHttp();
    tester.view.physicalSize = const Size(414, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    engine = SyncEngine(
      db: store.dbOrNull!,
      prefs: prefs,
      transport: HttpSyncTransport(Uri.parse(transportUrl ?? server.url)),
    );
    await prefs.setServerUrl(server.url);
    await tester.pumpWidget(
      MaterialApp(
        home: SyncScope(
          engine: engine,
          // R22：MePage 多了冲突数徽标（读 store），入口版式要两个 scope 都在。
          child: StoreScope(
            store: store,
            child: const MePage(),
          ),
        ),
      ),
    );
    // runAsync 里用真实时间让 _loadPaired 的 HTTP 完成并 setState。
    await settleReal(
      tester,
      done: () => find.text('服务端地址').evaluate().isNotEmpty,
    );
  }

  testWidgets('open 模式：免配对接入状态卡，没有配对码框', (tester) async {
    server.accessMode = 'open';
    await pumpMe(tester);

    expect(find.text('免配对接入'), findsOneWidget);
    expect(find.text('自动同步'), findsOneWidget);
    expect(find.text('配对码（5 分钟有效，一次性）'), findsNothing);
    expect(find.text('连接口令'), findsNothing);
    engine.dispose();
  });

  testWidgets('open + 要求手动：给「立即同步」按钮，不显示自动徽标', (tester) async {
    server.accessMode = 'open';
    server.visitorManualSync = true;
    await pumpMe(tester);

    expect(find.text('自动同步'), findsNothing);
    expect(find.text('立即同步'), findsOneWidget);
    engine.dispose();
  });

  testWidgets('passcode 模式：口令框 + 连接；连接成功后转成已接入视图', (tester) async {
    server.accessMode = 'passcode';
    server.passcode = 'mama-2026';
    await pumpMe(tester);

    expect(find.text('连接口令'), findsOneWidget);
    expect(find.text('免配对接入'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, '向家里管服务器的人要'), 'mama-2026');
    await tester.tap(find.text('连接'));
    await settleReal(
      tester,
      done: () => find.text('解除配对').evaluate().isNotEmpty,
    );

    // join 成功 = 存了 token，回到"服务端身份"已接入版式
    expect(find.text('解除配对'), findsOneWidget);
    expect(find.text('连接口令'), findsNothing);
    engine.dispose();
  });

  testWidgets('passcode 口令错：服务端原话上屏，仍停在口令框', (tester) async {
    server.accessMode = 'passcode';
    server.passcode = 'right';
    await pumpMe(tester);

    await tester.enterText(find.widgetWithText(TextField, '向家里管服务器的人要'), 'wrong');
    await tester.tap(find.text('连接'));
    await settleReal(
      tester,
      done: () => find.textContaining('口令不对').evaluate().isNotEmpty,
    );

    expect(find.textContaining('口令不对'), findsOneWidget);
    expect(find.text('连接口令'), findsOneWidget);
    engine.dispose();
  });

  testWidgets('pairCode 模式与"模式未知"都回退到既有配对码版式', (tester) async {
    server.accessMode = 'pairCode';
    await pumpMe(tester);
    expect(find.text('配对码（5 分钟有效，一次性）'), findsOneWidget);

    // transport 指向一个连不上的端口 → accessMode 读不到 → 同样给配对码版式
    // （保守回退）。注入的 transport 决定连哪，prefs 里的地址只是给人看的。
    engine.dispose();
    await pumpMe(tester, transportUrl: 'http://127.0.0.1:9');
    expect(engine.accessMode, isNull);
    expect(find.text('配对码（5 分钟有效，一次性）'), findsOneWidget);
    engine.dispose();
  });

  testWidgets('数据区：冲突箱入口带未裁决数徽标（R22）', (tester) async {
    // 冲突行是同步下来的普通业务行——本地库里有，入口就该报数。
    await store.dbOrNull!.customInsert(
      'INSERT INTO conflict_item (id, updated_at, updated_by, rev, tbl, '
      'row_id, field, local_value, remote_value, local_hlc, remote_hlc, '
      'local_by, remote_by) '
      "VALUES ('cf-x', 'h-1', 'server', 1, 'recipe', 'r-x', 'name', "
      "'A', 'B', 'h-1', 'h-1', 'dev-a', 'dev-b')",
    );
    await pumpMe(tester);

    expect(find.text('冲突箱'), findsOneWidget);
    expect(find.byKey(const ValueKey('conflict-badge')), findsOneWidget);
    engine.dispose();
  });
}
