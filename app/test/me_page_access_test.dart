import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/alert_scope.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/data/timer_alert.dart';
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

  /// 同 settleReal，但**不** pumpAndSettle：进度条的中间态是不确定动画，
  /// pumpAndSettle 会一直等不到"稳定帧"而超时。测进行中就靠它。
  Future<void> waitReal(WidgetTester tester,
      {required bool Function() done, int seconds = 25}) async {
    final until = DateTime.now().add(Duration(seconds: seconds));
    while (!done() && DateTime.now().isBefore(until)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
    }
  }

  Future<void> pumpMe(WidgetTester tester,
      {String? transportUrl,
      bool saveServerUrl = true,
      String? presetUrl}) async {
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
    if (saveServerUrl) await prefs.setServerUrl(server.url);
    await tester.pumpWidget(
      MaterialApp(
        home: SyncScope(
          engine: engine,
          // R22：MePage 多了冲突数徽标（读 store），入口版式要两个 scope 都在。
          // R47 又多一枚「计时结束通知」开关（读 AlertScope），三个 scope 都得在场——
          // 少挂一个是响亮报错，不是静默不生效（这条口径见 §7.10）。
          child: StoreScope(
            store: store,
            child: AlertScope(
              alert: TimerAlert(sender: (_) async {}),
              child: MePage(defaultServerUrl: presetUrl ?? kDefaultServerUrl),
            ),
          ),
        ),
      ),
    );
    // runAsync 里用真实时间让 _loadPaired 的 HTTP 完成并 setState。
    await settleReal(
      tester,
      done: () => find.text('服务端地址').evaluate().isNotEmpty,
      seconds: 25,
    );
    // R49（aiCall 超时闸门）：MePage 的 AI 入口卡会 fire-and-forget 一发
    // /api/ai/status，闸门在它身上挂一枚 10s 假定时器——用例收尾时回包还没落
    // 就会被 binding 判 Pending timers。这里补一个真实时间窗让它跑完往返：
    // 成功会填 aiStatusCache（谓词即中），401/异常同样完成、定时器随手取消
    // （谓词等不满就吃完窗口，localhost 往返 ~1.4s，6s 富余）。
    await settleReal(
      tester,
      done: () => engine.aiStatusCache != null,
      seconds: 6,
    );
  }

  testWidgets('★ 首启（偏好里没地址）：预置地址直接填进框里，并按它的真实模式排版', (tester) async {
    // 回归用户 2026-09-28 报的那条：服务端开着免配对，App 却逼着输配对码。
    // 病灶是准入模式只认**已保存**的地址，而首启的 Android 什么都还没存。
    server.accessMode = 'open';
    await pumpMe(tester, saveServerUrl: false, presetUrl: server.url);

    final box = tester.widget<TextField>(
        find.widgetWithText(TextField, server.url));
    expect(box.controller!.text, server.url,
        reason: '示例值就是初始值：用户不必把提示再手打一遍');
    expect(find.text('免配对接入'), findsOneWidget);
    expect(find.text('配对码（5 分钟有效，一次性）'), findsNothing);
    engine.dispose();
  });

  testWidgets('★ 地址一改就重探：换成口令服务端，版式跟着从免配对变口令框', (tester) async {
    server.accessMode = 'open';
    await pumpMe(tester, saveServerUrl: false, presetUrl: server.url);
    expect(find.text('免配对接入'), findsOneWidget);

    // 服务端那边改成口令（模拟家里改了准入设置），再碰一下地址框触发防抖重探。
    server.accessMode = 'passcode';
    server.passcode = 'mama-2026';
    await tester.enterText(find.widgetWithText(TextField, server.url), '${server.url}/');
    await tester.pump(const Duration(milliseconds: 600));
    await settleReal(
        tester, done: () => find.text('连接口令').evaluate().isNotEmpty, seconds: 25);

    expect(find.text('连接口令'), findsOneWidget);
    expect(find.text('免配对接入'), findsNothing);
    engine.dispose();
  });

  testWidgets('★ 进页面就自己探活并算差异：按钮上带真实条数（R38）', (tester) async {
    // 用户报的：手机端没检测服务端是否存活，点了上传/下载也毫无反应。
    // 现在进页面（含改地址后）自动 ping + computeDiff，界面直接给答案。
    server.accessMode = 'open';
    await pumpMe(tester, saveServerUrl: false, presetUrl: server.url);

    expect(find.textContaining('连接正常'), findsOneWidget);
    expect(find.text('连不上：'), findsNothing);
    expect(find.byKey(const ValueKey('conn-test')), findsOneWidget);
    // 首轮同步留下的回声行就是"真会再发一次 POST"的行数——按钮照实报。
    expect(find.textContaining('上传改动 · '), findsOneWidget);
    expect(find.textContaining('拉取更新'), findsOneWidget);
    engine.dispose();
  });

  testWidgets('探不到服务端时徽标说实话，不假装正常', (tester) async {
    server.accessMode = 'open';
    await pumpMe(tester,
        saveServerUrl: false,
        presetUrl: server.url,
        transportUrl: 'http://127.0.0.1:9');

    expect(find.textContaining('连不上'), findsOneWidget);
    expect(find.textContaining('连接正常'), findsNothing);
    engine.dispose();
  });

  testWidgets('★ 点方向按钮立刻出进度条与阶段文案（不再"点了没反应"）', (tester) async {
    server.accessMode = 'open';
    // 偏好里故意不存地址：免配对模式下框里预置的地址就该被认成家里那台。
    await pumpMe(tester, saveServerUrl: false, presetUrl: server.url);
    expect(find.byKey(const ValueKey('sync-progress')), findsNothing);

    // 把服务端回包放慢：本机 localhost 往返时快时慢，一轮同步可能在一次
    // pump 里就跑完，中间态就没了（进度条正是这条断言要盯的东西）。
    server.latency = const Duration(milliseconds: 250);
    await tester.tap(find.byKey(const ValueKey('sync-push')));
    await waitReal(tester, done: () => engine.progress != null || !engine.isBusy);
    await tester.pump();

    expect(engine.isBusy, isTrue);
    expect(find.byKey(const ValueKey('sync-progress')), findsOneWidget);
    expect(find.textContaining('正在'), findsWidgets);

    await waitReal(tester, done: () => !engine.isBusy);
    await tester.pump();
    expect(find.byKey(const ValueKey('sync-progress')), findsNothing,
        reason: '跑完必须收起，不能把进度条钉在屏上');
    server.latency = Duration.zero;
    // 按钮收尾还挂着一趟「刷新差异」的请求（_act 里那条）。等它回包并让
    // 假时钟跨过它的 5 秒超时，否则测试结束时树里留着 pending timer。
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 900)));
    await tester.pump(const Duration(seconds: 6));

    // 探到了就得把这台服务器记住：否则下一次 sync 因为偏好里没有 serverUrl
    // 直接判成 neverPaired——用户看到的正是"点了没反应"。
    expect(await prefs.serverUrl(), server.url);
    engine.dispose();
  });

  testWidgets('★ 免配对模式下也有上传/下载入口与同步策略（FR-DATA-05）', (tester) async {
    // 用户报的：配好地址之后界面上只有一个「自动同步」徽标，没有任何可点的方向。
    server.accessMode = 'open';
    await pumpMe(tester, saveServerUrl: false, presetUrl: server.url);

    expect(find.byKey(const ValueKey('sync-push')), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-pull')), findsOneWidget);
    for (final m in ['bidir', 'upload', 'download']) {
      expect(find.byKey(ValueKey('sync-mode-$m')), findsOneWidget);
    }

    // 选「仅上传」：选中态立刻跟上，并且落进本机偏好
    await tester.tap(find.byKey(const ValueKey('sync-mode-upload')));
    await settleReal(tester, done: () => engine.syncMode == SyncMode.upload);
    expect(engine.syncMode, SyncMode.upload);
    expect(prefs.syncMode(), completes);
    expect(await prefs.syncMode(), 'upload');
    final chip = tester.widget<FilterChip>(
        find.byKey(const ValueKey('sync-mode-upload')));
    expect(chip.selected, isTrue);
    engine.dispose();
  });

  testWidgets('未接入（配对码模式）时不给方向按钮——点了只会报错', (tester) async {
    server.accessMode = 'pairCode';
    await pumpMe(tester, saveServerUrl: false, presetUrl: 'http://127.0.0.1:9');

    expect(find.text('配对码（5 分钟有效，一次性）'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-push')), findsNothing);
    expect(find.byKey(const ValueKey('sync-mode-bidir')), findsNothing);
    engine.dispose();
  });

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

  testWidgets('R49：同步卡「N 张照片待上传」行，补传成功后消失', (tester) async {
    // 走配对（带 token）而不是 open 匿名：pumpMe 的 transport 没有 nodeId，
    // 匿名打 /api/media 必 401，drain 根本轮不到跑。
    await pumpMe(tester);
    expect(find.byKey(const ValueKey('sync-pending-media')), findsNothing);

    await tester.runAsync(
        () => engine.pair(serverUrl: server.url, code: 'TEST24'));
    await tester.pump();
    await tester.runAsync(() async {
      await engine.putMediaLocal(Uint8List.fromList([1]));
      await engine.putMediaLocal(Uint8List.fromList([2]));
    });
    await tester.pump();
    expect(find.text('2 张照片待上传'), findsOneWidget);

    await tester.runAsync(() => engine.sync());
    await tester.pump();
    expect(find.byKey(const ValueKey('sync-pending-media')), findsNothing,
        reason: 'drain 补传完，账归零，这行就该走');
    engine.dispose();
  });

  testWidgets('R49 补：策略 chip 的选中态一眼可辨且会迁移', (tester) async {
    // chip 区只在「已接入 / 免配对」下摆出来（未接入点了只会报错）——
    // 用 open 模式进这个态，同 FR-DATA-05 那条用例的搭法。
    server.accessMode = 'open';
    await pumpMe(tester, saveServerUrl: false, presetUrl: server.url);
    FilterChip chip(String wire) => tester.widget<FilterChip>(
        find.byKey(ValueKey('sync-mode-$wire')));
    // 默认双向合并就是选中态——用户点它"没反应"是因为它**已经是它**；
    // 前提是这份选中必须看得见。
    expect(chip('bidir').selected, isTrue);
    expect(chip('upload').selected, isFalse);
    final bidirLabel = tester.widget<Text>(
        find.descendant(
            of: find.byKey(const ValueKey('sync-mode-bidir')),
            matching: find.byType(Text)));
    expect(bidirLabel.style?.fontWeight, FontWeight.w700,
        reason: '选中那颗加粗——色板差异之外要有机可断的视觉差');

    await tester.tap(find.byKey(const ValueKey('sync-mode-upload')));
    await settleReal(tester, done: () => engine.syncMode == SyncMode.upload);
    expect(chip('upload').selected, isTrue, reason: '点一下，高亮必须搬家');
    expect(chip('bidir').selected, isFalse);
    engine.dispose();
  });
}
