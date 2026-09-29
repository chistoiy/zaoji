import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/data/sync/sync_engine.dart';
import 'package:zaoji/data/sync/sync_prefs.dart';
import 'package:zaoji/data/sync/sync_scope.dart';
import 'package:zaoji/data/sync/sync_transport.dart';
import 'package:zaoji/ui/recipe_detail_page.dart';
import 'package:zaoji/ui/trash_page.dart';
import 'fake_sync_server.dart';

/// R43 · 回收站的永久删除（FR-DATA-13）与删除后 5 秒撤销（FR-DATA-14）。
///
/// 引擎级断言的重心是那句**顺序**：先问服务端、服务端认了才删本机。
/// 反过来的话，另一台设备回收站里那条还能点「恢复」，一推就回到你这台机器上——
/// 用户已经看见"已永久删除"了，这种"删了又回来"比不删更伤信任。
///
/// 假服务端镜像的是真服务端 `_purge` 的四条语义（白名单 / 必须有墓碑 /
/// recipe 级联子行 / 每条物理删各写一条 purge 变更），
/// 所以这里过的用例不代表真 exe 行为——那部分由 server/test/purge_test.dart 钉。
void main() {
  late Directory tmp;
  late RecipeStore store;
  late FakeSyncServer server;
  late SyncEngine engine;

  setUpAll(() async {
    server = await FakeSyncServer.start();
  });
  tearDownAll(() async => server.close());

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zaoji_purge_');
    FakeSyncServer.allowRealHttp();
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
    engine = SyncEngine(
      db: store.dbOrNull!,
      prefs: SyncPrefs(store.dbOrNull!),
      transport: HttpSyncTransport(Uri.parse(server.url)),
      // ★ 与 main.dart 同一根线：引擎写完库要喊 store.reload，
      //   否则界面上"永久删除点了卡片还在"这种断裂在测试里就看不见。
      onDataApplied: store.reload,
    );
    server.reset();
  });

  tearDown(() async {
    engine.dispose();
    await store.dbOrNull!.close();
    store.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> paired() => engine.pair(serverUrl: server.url, code: 'TEST24');

  /// 等**真 I/O**落地的轮询：每一步都开一次 runAsync，让真 HTTP / drift isolate 的
  /// 回复有机会进来，再补一帧 pump 把回复反映到树上。
  /// 不能换 pumpAndSettle：FakeAsync 的静止时钟下真 I/O 永不返回，
  /// 而配对 / purge / 恢复走的都是真库真网络。
  /// 纯动画（弹层、条滑入）用 [pumpUi]，别把两者混成一坨。
  Future<void> settleReal(WidgetTester tester, {required bool Function() done, int seconds = 12}) async {
    final until = DateTime.now().add(Duration(seconds: seconds));
    while (!done() && DateTime.now().isBefore(until)) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)));
      await tester.pump();
    }
  }

  Future<int> countRows(RecipeStore s, String sql) async {
    final r = await s.dbOrNull!.customSelect(sql).getSingle();
    return r.read<int>('c');
  }

  /// 只推 UI 动画（弹层进出场、条滑入）：fake 时钟的小步 pump，不掺真 I/O。
  /// SnackBar 从屏幕下方滑进来约 250ms：条刚挂上的那一帧它中心还在 1600 之外，
  /// 这时 `tester.tap` 只会"找不到命中"留一条 warning 然后**点空**——
  /// 表现就是"按钮明明找到了，菜却没恢复"。
  Future<void> pumpUi(WidgetTester tester,
      {required bool Function() done, int steps = 12}) async {
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (done()) return;
    }
  }

  /// 把一道种子菜谱推进回收站（本机墓碑 + 同步上服务端）。
  Future<void> trash(String id) async {
    await store.softDeleteRecipe(id);
    await engine.sync();
  }

  group('永久删除', () {
    test('走通一次：服务端收下、本机三张表的行物理消失、回收站也空了', () async {
      await paired();
      await trash('r1');
      expect(server.rows['recipe']!['r1'], isNotNull, reason: '墓碑应当已经推上去');

      final err = await engine.purgeRecipePermanently('r1');
      expect(err, isNull, reason: '不该失败：$err');
      expect(server.purgeCount, 1);
      expect(server.rows['recipe']!['r1'], isNull, reason: '服务端这一行要物理没了');

      // 本机：不是墓碑，是没有这一行
      expect(await countRows(store, "SELECT COUNT(*) AS c FROM recipe WHERE id='r1'"), 0);
      expect(
          await countRows(
              store, "SELECT COUNT(*) AS c FROM ingredient WHERE recipe_id='r1'"),
          0,
          reason: '子行留着就是幽灵数据：回收站只列菜谱，它们谁也看不见');
      expect(
          await countRows(store, "SELECT COUNT(*) AS c FROM step WHERE recipe_id='r1'"),
          0);
      expect(store.recipes.map((e) => e.id), isNot(contains('r1')));
      expect((await store.listDeleted()).map((e) => e.id), isNot(contains('r1')));
    });

    test('没接入服务端：一次请求都不发，本机数据一行不动', () async {
      final before = await countRows(store, 'SELECT COUNT(*) AS c FROM recipe');
      final err = await engine.purgeRecipePermanently('r1');
      expect(err, isNotNull, reason: '没接入也要给人看的原话，不是静默失败');
      expect(server.purgeCount, 0, reason: '连地址都没有，不该打任何请求');
      expect(await countRows(store, 'SELECT COUNT(*) AS c FROM recipe'), before);
    });

    test('服务端说"这行还没进回收站"，本机就不许删（顺序是安全的一部分）', () async {
      await paired();
      final err = await engine.purgeRecipePermanently('r2');
      expect(err, contains('回收站'), reason: '要原样把服务端的理由给人看：$err');
      expect(await countRows(store, "SELECT COUNT(*) AS c FROM recipe WHERE id='r2'"), 1);
      expect(server.rows['recipe']!['r2'], isNotNull);
    });

    test('★ 另一台设备：收到 purge 是物理删，不是打一张还能恢复的墓碑', () async {
      // A 先配对并把种子推上服务端（否则 B 拉不到任何东西，下面的断言就是空的）
      await paired();
      // B 先同步一次：此时 r1 还活着，B 库里应当有它
      final storeB = RecipeStore(executor: NativeDatabase.memory());
      await storeB.ready();
      final engineB = SyncEngine(
        db: storeB.dbOrNull!,
        prefs: SyncPrefs(storeB.dbOrNull!),
        transport: HttpSyncTransport(Uri.parse(server.url)),
      );
      addTearDown(() async {
        engineB.dispose();
        await storeB.dbOrNull!.close();
        storeB.dispose();
      });
      await engineB.pair(serverUrl: server.url, code: 'TEST24');
      expect(await countRows(storeB, "SELECT COUNT(*) AS c FROM recipe WHERE id='r1'"),
          greaterThan(0),
          reason: '前提是 B 真的有这道菜，否则"物理删"这条断言等于没测');

      await trash('r1');
      await engine.purgeRecipePermanently('r1');
      await engineB.sync();

      expect(await countRows(storeB, "SELECT COUNT(*) AS c FROM recipe WHERE id='r1'"), 0,
          reason: 'B 那边也得真的没有这一行');
      expect(
          await countRows(storeB, "SELECT COUNT(*) AS c FROM ingredient WHERE recipe_id='r1'"),
          0);
      // 对照组：没被永久删除的菜在 B 上还在（排除"整库没同步上"这种假绿）
      expect(
          await countRows(storeB, "SELECT COUNT(*) AS c FROM recipe WHERE id='r2'"), 1);
    });

    test('★ 服务端太旧（没有 /api/purge 这条路由）：说清是版本问题，本机一行不动', () async {
      await paired();
      await trash('r1');
      // 家里那台现在跑的就是 v0.14.3：这条路由不存在，兜底页回的是 **HTML 404**。
      // 传输层旧写法把"响应不是 JSON"当网络错误抛出，状态码这条事实就丢了，
      // 于是话术变成"连不上服务端"——明明连得上，只是它不认识这件事。
      server.supportsPurge = false;

      final err = await engine.purgeRecipePermanently('r1');
      expect(err, contains('版本偏旧'), reason: '要给人一句能照着做下去的话：$err');
      expect(err, isNot(contains('连不上')), reason: '不是连不上：$err');
      expect(
          await countRows(store, "SELECT COUNT(*) AS c FROM recipe WHERE id='r1'"), 1,
          reason: '服务端没认，本机就不许删——这是"先问服务端"那条纪律的另一半');
      expect(
          await countRows(
              store, "SELECT COUNT(*) AS c FROM ingredient WHERE recipe_id='r1'"),
          greaterThan(0),
          reason: '子行也不许被顺手清掉');
      expect(store.deletedItems.map((e) => e.id), contains('r1'),
          reason: '回收站里那条还在：换了新 exe 之后可以再点一次');
    });

    test('重复点永久删除是幂等的：第二次不再广播', () async {
      await paired();
      await trash('r1');
      expect(await engine.purgeRecipePermanently('r1'), isNull);
      final logLen = server.changeLog.length;
      final again = await engine.purgeRecipePermanently('r1');
      expect(again, isNull, reason: '已经不在了不是错误：$again');
      expect(server.changeLog.length, logLen, reason: '幂等不等于再广播一条');
    });
  });

  group('回收站页（永久删除那一条按钮）', () {
    Future<void> pump(WidgetTester tester, Widget page) async {
      await tester.binding.setSurfaceSize(const Size(540, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // 回收站页不再自己查库（读 store.deletedItems），所以这里不需要等加载圈；
      // runAsync 仍留着——恢复/永久删除按下后要走真库与真 HTTP。
      await tester.runAsync(() async {
        await tester.pumpWidget(StoreScope(
          store: store,
          child: SyncScope(engine: engine, child: MaterialApp(home: page)),
        ));
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await tester.pump();
      });
    }

    testWidgets('卡片上有「永久删除」；点了先弹二次确认，取消就不打接口', (tester) async {
      await tester.runAsync(() => store.softDeleteRecipe('r1'));
      expect(store.deletedItems.map((e) => e.id), contains('r1'),
          reason: '前置：软删之后回收站数据源当场就得有它，不等下一轮同步');
      await pump(tester, const TrashPage());
      await pumpUi(tester,
          done: () => find.byKey(const ValueKey('trash-purge-r1')).evaluate().isNotEmpty);

      expect(find.byKey(const ValueKey('trash-purge-r1')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('trash-purge-r1')));
      await pumpUi(tester,
          done: () => find.byKey(const ValueKey('purge-confirm')).evaluate().isNotEmpty);
      expect(find.byKey(const ValueKey('purge-confirm')), findsOneWidget,
          reason: '不可逆动作先过一道二次确认');

      await tester.tap(find.byKey(const ValueKey('purge-cancel')));
      await pumpUi(tester,
          done: () => find.byKey(const ValueKey('purge-confirm')).evaluate().isEmpty);
      expect(server.purgeCount, 0, reason: '取消就是取消，不该发任何请求');
      expect(find.byKey(const ValueKey('trash-restore-r1')), findsOneWidget,
          reason: '取消之后这道菜仍留在回收站里');
    });

    testWidgets('确认后真的发出 /api/purge，卡片当场从回收站消失', (tester) async {
      await tester.runAsync(() async {
        await paired();
        await store.softDeleteRecipe('r1');
        await engine.sync();
      });
      await pump(tester, const TrashPage());
      await pumpUi(tester,
          done: () => find.byKey(const ValueKey('trash-purge-r1')).evaluate().isNotEmpty);

      await tester.tap(find.byKey(const ValueKey('trash-purge-r1')));
      await pumpUi(tester,
          done: () => find.byKey(const ValueKey('purge-confirm')).evaluate().isNotEmpty);

      // 确认之后就是真 I/O：发 /api/purge → 本机删行 → store.reload → 重绘。
      // ★ 整段留在 runAsync 里：HttpClient 的**保活连接会挂一只 15 秒定时器**，
      //   在 FakeAsync 区里发的请求就把这只定时器挂进了假时钟，
      //   测试收尾那句 "A Timer is still pending even after the widget tree was disposed"
      //   报的就是它（跟被测代码无关，纯粹是发请求所在的区不对）。
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('purge-confirm')));
        for (var i = 0; i < 40; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
          final landed =
              server.purgeCount > 0 &&
              find.byKey(const ValueKey('trash-purge-r1')).evaluate().isEmpty;
          if (landed) break;
        }
      });
      await pumpUi(
          tester, done: () => find.textContaining('已永久删除').evaluate().isNotEmpty);

      expect(server.purgeCount, 1, reason: '确认了就要真的发出去');
      expect(find.byKey(const ValueKey('trash-purge-r1')), findsNothing,
          reason: '点完还挂在回收站里，用户只会再点一次');
      expect(find.textContaining('已永久删除'), findsOneWidget);

      // 收尾把 HttpClient 的保活定时器走完：那只 15 秒空闲定时器是**发请求所在的区**
      // 的时钟记的（这里绕不开假时钟），不走完测试结尾就报 "A Timer is still pending"。
      await tester.pump(const Duration(seconds: 16));
    });
  });

  group('删除后 5 秒撤销（FR-DATA-14）', () {
    Future<void> pumpDetail(WidgetTester tester) async {
      final r = store.recipes.first;
      await tester.binding.setSurfaceSize(const Size(540, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        await tester.pumpWidget(StoreScope(
          store: store,
          child: MaterialApp(
            // ★ home 是一个真 Scaffold，详情页从它上面 push——照生产路径走。
            //   前一把详情页直接当 home，删完 Navigator.pop 把唯一的路由也弹掉了，
            //   SnackBar 没有 Scaffold 的槽位可落，只好待在 Overlay 的无约束布局里
            //   （实测撤销按钮被顶到 x=586，而屏幕只有 540 宽）：
            //   点在屏幕外→点空→菜没回来。真机永远是从列表进详情，撞不到这条路。
            home: Scaffold(
              body: Center(
                child: Builder(
                  builder: (ctx) => TextButton(
                    key: const ValueKey('open-detail'),
                    onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(
                        builder: (_) => RecipeDetailPage(recipe: r))),
                    child: const Text('打开'),
                  ),
                ),
              ),
            ),
          ),
        ));
        await Future<void>.delayed(const Duration(milliseconds: 120));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('open-detail')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      });
    }

    testWidgets('撤销按钮在 5 秒条上，点一下菜就回到列表', (tester) async {
      final id = store.recipes.first.id;
      await pumpDetail(tester);

      await tester.tap(find.byTooltip('删除'));
      await pumpUi(tester, done: () => find.text('删除这道菜？').evaluate().isNotEmpty);
      await tester.tap(find.text('删除'));
      // 删除本身是真库写入 → settleReal；条挂上后再等它真正落位
      await settleReal(tester,
          done: () => find.byKey(const ValueKey('delete-undo-bar')).evaluate().isNotEmpty);
      // ★ 两条"还没就位"混在转场里，点早了就是点空：
      //   ① 条是从屏幕下缘滑进来的，刚挂上时下沿还在 1600 之外
      //      （实测 bar=Rect.fromLTRB(0,1600,540,1600)）；判进来要看**下沿**，
      //      看中心点过线会第一帧就满足条件，点在动画中途；
      //   ② 详情页 pop 回列表那一小段，新旧两个 Scaffold 同时在场，
      //      同一条带 key 的 SnackBar 在两个槽位各挂一份实例（实测 count=2），
      //      getRect 直接报"ambiguously found multiple matching widgets"。
      await pumpUi(tester, steps: 20, done: () {
        final bar = find.byKey(const ValueKey('delete-undo-bar'));
        final n = bar.evaluate().length;
        return n == 1 && tester.getRect(bar.first).bottom <= 1600;
      });

      expect(find.byKey(const ValueKey('delete-undo-bar')), findsOneWidget);
      expect(find.byKey(const ValueKey('delete-undo')), findsOneWidget);
      expect(store.recipes.map((e) => e.id), isNot(contains(id)),
          reason: '撤销之前它确实已经进回收站了');

      await tester.tap(find.byKey(const ValueKey('delete-undo')));
      await settleReal(tester, done: () => store.recipes.any((e) => e.id == id));
      expect(store.recipes.map((e) => e.id), contains(id),
          reason: '撤销 = 把墓碑擦掉，走既有 restoreRecipe（重新盖 HLC 并广播）');
      // 「已恢复」这条要立刻看得见：撤销时先 removeCurrentSnackBar()，
      // 不然它得排队等「已删除」那条 5 秒超时才露脸——用户会以为没撤销成。
      await pumpUi(tester, done: () => find.textContaining('已恢复').evaluate().isNotEmpty);
      expect(find.textContaining('已恢复'), findsOneWidget);
      expect(find.byKey(const ValueKey('delete-undo-bar')), findsNothing,
          reason: '撤销成功了，"已删除"那条就不该还杵在列表上');
    });

    testWidgets('带 action 的条不会永挂：5 秒到点自己收（必须写 persist: false）',
        (tester) async {
      final id = store.recipes.first.id;
      await pumpDetail(tester);

      await tester.tap(find.byTooltip('删除'));
      await pumpUi(tester, done: () => find.text('删除这道菜？').evaluate().isNotEmpty);
      await tester.tap(find.text('删除'));
      await settleReal(tester,
          done: () => find.byKey(const ValueKey('delete-undo-bar')).evaluate().isNotEmpty);
      // 等转场结束、条只剩一份（同上一条用例的 ②），计时才是从"落到列表页那刻"起算
      await pumpUi(tester,
          steps: 20,
          done: () =>
              find.byKey(const ValueKey('delete-undo-bar')).evaluate().length <= 1);

      // ★ SnackBar 的关闭是定时器：大步 pumpAndSettle 不会让它退场（R22 那条经验），小步走。
      //   这条用例钉的是 `persist: false`：SnackBar 构造里
      //   `persist = persist ?? action != null`，带 action 就默认永挂，
      //   只写 duration 时假时钟推到 7.5 秒条还在（本轮实测），补 persist 才按点收。
      for (var i = 0; i < 26; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.byKey(const ValueKey('delete-undo-bar')), findsNothing);
      expect(store.recipes.map((e) => e.id), isNot(contains(id)),
          reason: '窗口过了只是失去便捷撤销，菜仍在回收站里——不是丢了');
      expect((await store.listDeleted()).map((e) => e.id), contains(id));
    });
  });
}
