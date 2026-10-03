import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/sync/sync_engine.dart';
import 'package:zaoji/data/sync/sync_prefs.dart';
import 'package:zaoji/data/sync/sync_transport.dart';
import 'fake_sync_server.dart';
import 'package:zaoji/data/seed.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// 同步引擎测试。
///
/// 用**测试内的 dart:io HttpServer 模拟服务端**（FakeSyncServer），走真 HTTP +
/// 真协议形状（配对 / 鉴权 / 幂等 / seq 游标 / 载荷跟随），引擎代码零 mock。
/// 服务端的正确性由 server 自己的测试保证；「真 exe + 真 Web 产物」的两端 E2E
/// 用人工链路验证（交接文档 R13）。
///
/// 注：R11 时代这里写过「不能把 zaoji_server 拉进 dev_dependencies，因为
/// app 要 sqlite3 ^3.x 而服务端锁 ^2.x」——**那条前提已经不成立**：
/// R36 把 app 的 SQLite 栈退回 2.9.4（3.x 那代在 Android 上不带 libsqlite3.so），
/// 两端现在同版。留着真服务端依赖仍然没必要（进程内起服务反而更难控制），
/// 但别再拿"版本解算冲突"当理由。
void main() {
  late Directory tmp;
  late RecipeStore store;
  late FakeSyncServer server;
  late SyncEngine engine;
  bool dataApplied = false;

  setUpAll(() async {
    server = await FakeSyncServer.start();
  });

  tearDownAll(() async {
    await server.close();
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zaoji_sync_test_');
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
    dataApplied = false;
    engine = SyncEngine(
      db: store.dbOrNull!,
      prefs: SyncPrefs(store.dbOrNull!),
      transport: HttpSyncTransport(Uri.parse(server.url)),
      onDataApplied: () async => dataApplied = true,
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

  test('配对成功 → 首轮同步把种子推上服务端，并拉回服务端盖章的回声', () async {
    await paired();

    expect(engine.phase, SyncPhase.idle, reason: engine.lastError);
    expect(engine.lastError, isNull);
    // 服务端收到了全部种子行
    expect(server.rows['recipe']!.length, kSeedRecipes.length);
    expect(server.rows['ingredient']!.length, greaterThan(0));
    expect(server.rows['step']!.length, greaterThan(0));
    // 回声已应用：本地行的 updated_at 变成服务端盖的章（nodeId = fake-server）
    final db = store.dbOrNull!;
    final r1 = await db
        .customSelect("SELECT updated_at FROM recipe WHERE id = 'r1'")
        .getSingle();
    expect(Hlc.tryDecode('${r1.data['updated_at']}')!.nodeId, 'fake-server');
    // 拉到了东西 → onDataApplied 回调应被触发
    expect(dataApplied, isTrue);
    // 游标推进到服务端当前 seq
    final prefs = SyncPrefs(store.dbOrNull!);
    expect(await prefs.pullCursor(), server.seq);
    expect(await prefs.pushWatermark(), isNotEmpty);
  });

  test('第二轮把回声空推上去（服务端判 skipped，日志不增长）；第三轮是真 no-op', () async {
    await paired();
    final logAfterFirst = server.changeLog.length;
    final postsAfterFirst = server.pushCount;

    await engine.sync(); // 第二轮：回声重推
    expect(
      server.changeLog.length,
      logAfterFirst,
      reason: '内容一致的服务端必须判 skipped，不产生新变更',
    );
    expect(server.pushCount, postsAfterFirst + 1);

    await engine.sync(); // 第三轮：真正无事可做
    expect(server.pushCount, postsAfterFirst + 1, reason: '水位线已追上，不该再发推送请求');
  });

  test('另一台设备的改动会被拉下来，并触发数据刷新回调', () async {
    await paired();
    dataApplied = false;

    // 模拟设备 B 在服务端直接写了一行（走服务端的落库+盖章+记日志路径）
    server.injectRecipe(id: 'r-new', name: 'B 设备新加的菜');

    await engine.sync();

    final db = store.dbOrNull!;
    final row = await db
        .customSelect("SELECT name FROM recipe WHERE id = 'r-new'")
        .getSingle();
    expect('${row.data['name']}', 'B 设备新加的菜');
    expect(dataApplied, isTrue, reason: '拉到了新数据必须刷新 store，否则列表不变');
  });

  test('★ LWW：本地比服务端新的离线改动不会被旧数据覆盖', () async {
    await paired();

    // 本地离线改 r1（本机 HLC，比服务端刚盖的章更新）
    final db = store.dbOrNull!;
    final hlc = Hlc.now(await SyncPrefs(db).nodeId()).encode();
    await db.customUpdate(
      "UPDATE recipe SET name = '本机新名字', updated_at = ? WHERE id = 'r1'",
      variables: [Variable(hlc)],
    );

    // 服务端此时推来的还是旧内容（它手里只有老数据）
    await engine.sync();

    final row = await db
        .customSelect("SELECT name, updated_at FROM recipe WHERE id = 'r1'")
        .getSingle();
    expect('${row.data['name']}', '本机新名字', reason: '服务端的旧版本不能盖掉本地更新的改动');
    // 且它会在下一轮被推上去
    await engine.sync();
    expect('${server.rows['recipe']!['r1']!['name']}', '本机新名字');
  });

  test('软删除会以 op=delete 推上去（服务端 upsert 分支不处理墓碑）', () async {
    await paired();
    final db = store.dbOrNull!;
    final prefs = SyncPrefs(db);

    // 本地软删 r5：打墓碑 + 盖本机 HLC（这就是未来删除按钮要做的事）
    final hlc = Hlc.now(await prefs.nodeId()).encode();
    await db.customUpdate(
      "UPDATE recipe SET deleted_at = '2026-09-18T20:00:00', updated_at = ? "
      "WHERE id = 'r5'",
      variables: [Variable(hlc)],
    );

    await engine.sync();

    expect(
      '${server.rows['recipe']!['r5']!['deleted_at']}',
      isNotNull,
      reason: '墓碑必须到达服务端，否则其他设备的 r5 永远删不掉',
    );
  });

  test('★ serverId 变了：拒绝同步并要求重新配对，一个字节都不发', () async {
    await paired();
    // 改写本地记录的 serverId，模拟「下次连到的是另一台服务器」
    await SyncPrefs(store.dbOrNull!).setServerId('another-server');
    server.reset(); // 清空请求计数

    await engine.sync();

    expect(engine.phase, SyncPhase.error);
    expect(engine.lastError, contains('重新配对'));
    expect(server.pushCount, 0, reason: '身份校验失败后绝不能继续推数据');
    expect(server.pullCount, 0);
  });

  test('协议版本不一致（409）要明确告诉用户去升级', () async {
    server.protocolVersionOverride = 999;
    addTearDown(() => server.protocolVersionOverride = null); // 失败也不能泄漏到后续测试
    await paired();
    expect(engine.phase, SyncPhase.error);
    expect(engine.lastError, contains('协议版本'));
  });

  test('★ 游标持久化在客户端：重启引擎后从上次游标继续，而不是从 0 重拉', () async {
    await paired();
    final cursorAfterFirst = await SyncPrefs(store.dbOrNull!).pullCursor();
    expect(cursorAfterFirst, greaterThan(0));
    final pullsAfterFirst = server.pullCount;

    // 模拟 App 重启：新引擎实例、同一个库（同一份 prefs）
    final engine2 = SyncEngine(
      db: store.dbOrNull!,
      prefs: SyncPrefs(store.dbOrNull!),
      transport: HttpSyncTransport(Uri.parse(server.url)),
    );
    await engine2.sync();

    final q = server.lastPullQuery;
    expect(
      q!['since'],
      '$cursorAfterFirst',
      reason:
          '铁律：拉取游标在客户端。重启后必须从游标继续，'
          '从 0 重拉既是浪费，更会把离线改动覆盖回旧版',
    );
    expect(server.pullCount, pullsAfterFirst + 1);
    engine2.dispose();
  });

  test('限流/坏码等配对失败会透出服务端的话', () async {
    await engine.pair(serverUrl: server.url, code: 'WRONG1');
    expect(engine.phase, SyncPhase.error);
    expect(engine.lastError, contains('配对码'));
    expect(await SyncPrefs(store.dbOrNull!).isPaired(), isFalse);
  });

  group('图片本机优先（R49 改口径，原 R17 按档分级作废）', () {
    test('★ 首次取图只拉**原图**一份并落盘；任何档位再取零请求', () async {
      await paired();
      final sha = 'a' * 64;

      final card = await engine.fetchMediaCached(sha, width: MediaWidth.card);
      // 拿回的是原图字节——缩略显示由 CoverImage 解码期 cacheWidth 负责，
      // 不再按档位向服务端要派生图（本机有了，档位概念就退场了）。
      expect(utf8.decode(card!), 'full:$sha');
      expect(server.mediaPaths, ['/api/media/$sha'],
          reason: '不带 ?w=：一次拉齐，之后离线可看');

      final detail =
          await engine.fetchMediaCached(sha, width: MediaWidth.detail);
      expect(utf8.decode(detail!), 'full:$sha');
      expect(server.mediaPaths.length, 1,
          reason: '第二档必须从本机/内存出，不许按档位各打一发');
    });

    test('★ 本机命中优先于网络：库里有字节就一发请求都不发', () async {
      final bytes = Uint8List.fromList([9, 9]);
      final sha = crypto.sha256.convert(bytes).toString();
      await engine.putMediaLocal(bytes);
      // 没配对（无 serverUrl）也读得出——照片是本机资产，接入与否不影响看。
      expect(await engine.fetchMediaCached(sha), bytes);
      expect(server.mediaPaths, isEmpty);
    });

    test('未配对 / 服务端没有这张图 → 一律 null，绝不把异常抛给 UI', () async {
      final sha = 'c' * 64;
      // ① 未配对：没有地址就不该发请求
      expect(await engine.fetchMediaCached(sha, width: MediaWidth.card), isNull);
      expect(server.mediaPaths, isEmpty);

      await paired();
      // ② 服务端没有这张图（404）
      expect(
          await engine.fetchMediaCached('d' * 64, width: MediaWidth.card), isNull);
    });
  });

  // ── R37 · 同步策略（FR-DATA-05）：方向由用户说了算，不是只有双向一条路 ──

  group('同步策略', () {
    void zeroCounts() {
      server.pushCount = 0;
      server.pullCount = 0;
    }

    test('常驻「仅上传」：这一轮只 POST，不发拉取', () async {
      await paired();
      await engine.setSyncMode(SyncMode.upload);
      await store.createRecipe(RecipeDraft(name: '本机新菜'));
      zeroCounts();

      await engine.sync();
      expect(server.pushCount, greaterThan(0), reason: engine.lastError);
      expect(server.pullCount, 0);
    });

    test('★ 常驻「仅下载」：只拉，本机没推的改动留在原地不丢', () async {
      await paired();
      await engine.setSyncMode(SyncMode.download);
      await store.createRecipe(RecipeDraft(name: '本机新菜'));
      zeroCounts();

      await engine.sync();
      expect(server.pullCount, greaterThan(0), reason: engine.lastError);
      expect(server.pushCount, 0);

      // 切回双向：那条改动还在水位线之后，照样推得上去（策略不是丢弃开关）
      await engine.setSyncMode(SyncMode.bidir);
      zeroCounts();
      await engine.sync();
      expect(server.pushCount, greaterThan(0),
          reason: '仅下载期间攒下的改动不该被忘掉');
    });

    test('手动「上传改动 / 拉取更新」只作用一轮，不改常驻策略', () async {
      await paired();
      zeroCounts();
      await store.createRecipe(RecipeDraft(name: '本机新菜'));

      await engine.pushNow();
      expect(server.pushCount, greaterThan(0), reason: engine.lastError);
      expect(server.pullCount, 0);
      expect(engine.syncMode, SyncMode.bidir,
          reason: '一次性动作不留副作用，否则用户下次同步方向莫名其妙');

      zeroCounts();
      await engine.pullNow();
      expect(server.pullCount, greaterThan(0));
      expect(server.pushCount, 0);
      expect(engine.syncMode, SyncMode.bidir);
    });

    test('★ 策略是本机偏好：换引擎实例读得回来，且不进同步流', () async {
      await engine.setSyncMode(SyncMode.download);

      final again = SyncEngine(
        db: store.dbOrNull!,
        prefs: SyncPrefs(store.dbOrNull!),
        transport: HttpSyncTransport(Uri.parse(server.url)),
      );
      expect(again.syncMode, SyncMode.bidir,
          reason: '没 load 之前是默认值——UI 进页面要先 loadSyncMode');
      await again.loadSyncMode();
      expect(again.syncMode, SyncMode.download);
      again.dispose();

      // local_pref 不是同步表：手机设成「仅下载」不该把平板的策略一起改掉。
      expect(server.rows.containsKey('local_pref'), isFalse,
          reason: '策略一旦被推上服务端，就等于跨设备互相改写');
      expect(await SyncPrefs(store.dbOrNull!).syncMode(), 'download');
    });
  });

  // ── R38 · 存活探测 / 差异计数 / 进度 ──

  group('存活、差异与进度', () {
    test('pingServer 打得通给延迟；打不通不抛，给得出原话', () async {
      final up = await engine.pingServer(urlOverride: server.url);
      expect(up.ok, isTrue, reason: up.error);
      expect(up.serverId, isNotEmpty);
      expect(up.label, startsWith('连接正常'));

      // 探不通要另开一个引擎：注入的 transport 优先于地址（测试缝），
      // 拿 urlOverride 指到死端口是探不动的——这本身就是要记下来的行为。
      engine.dispose();
      engine = SyncEngine(
        db: store.dbOrNull!,
        prefs: SyncPrefs(store.dbOrNull!),
        transport: HttpSyncTransport(Uri.parse('http://127.0.0.1:9')),
      );
      final down = await engine.pingServer();
      expect(down.ok, isFalse);
      expect(down.error, isNotNull, reason: '「连不上」必须说得出为什么');
    });

    test('★ 待推数与引擎逐字同源：它说 N 行，下一轮就真发 N 行', () async {
      await paired();
      // 回声（服务端盖章后回传的行）会让这个数暂时偏大——那些行下一轮被空推一次，
      // 服务端判 skipped，然后归零。刻意不做"更聪明"的排除：
      // 手机停在「仅上传」时收不到回声，排除法会显示 0 并禁用按钮，
      // 而引擎其实还有活要干——**一个会说谎的 0 比一个偏大的 N 危险得多**。
      var d = await engine.computeDiff();
      expect(d!.localPending, greaterThan(0), reason: '回声行仍会被下一轮收集');

      await engine.sync();
      await settle();
      d = await engine.computeDiff();
      expect(d!.localPending, 0, reason: '空推过一轮后归零，此时才准禁用按钮');

      await store.createRecipe(RecipeDraft(name: '本机新增'));
      d = await engine.computeDiff();
      expect(d!.localPending, greaterThan(0), reason: '本机写的行（含食材步骤）待推');
    });

    test('另一端推上去的变更，会被算成待拉', () async {
      await paired();
      // 「另一端」必须真的另有一个库：同一个 store 上再造一个 SyncEngine
      // 会共用 local_pref 里的游标，那样算出来永远是 0 差异（假绿）。
      final otherStore = RecipeStore(executor: NativeDatabase.memory());
      await otherStore.ready();
      final other = SyncEngine(
        db: otherStore.dbOrNull!,
        prefs: SyncPrefs(otherStore.dbOrNull!),
        transport: HttpSyncTransport(
            Uri.parse(server.url), nodeId: 'other-device'),
      );
      await other.pair(serverUrl: server.url, code: 'TEST24');
      await otherStore.createRecipe(RecipeDraft(name: '平板上新增'));
      await other.sync();
      await settle();

      final d = await engine.computeDiff();
      expect(d!.remotePending, greaterThan(0),
          reason: '服务端 change_log 领先本机游标，就该提示有东西可拉');

      other.dispose();
      await otherStore.dbOrNull!.close();
      otherStore.dispose();
    });

    test('★ 半路失败：待推数不清零，重试不是重复操作', () async {
      await paired();
      await store.createRecipe(RecipeDraft(name: '推不出去的菜'));
      final before = await engine.computeDiff();
      expect(before!.localPending, greaterThan(0));

      // 换成连不上的地址：本轮失败，水位线不该动。
      engine.dispose();
      engine = SyncEngine(
        db: store.dbOrNull!,
        prefs: SyncPrefs(store.dbOrNull!),
        transport: HttpSyncTransport(Uri.parse('http://127.0.0.1:9')),
      );
      await engine.sync();
      expect(engine.phase, SyncPhase.error, reason: '连不上要报错，不能静默');

      final after = await engine.computeDiff();
      expect(after!.localPending, greaterThan(0),
          reason: '失败后差异还在，用户看得见「仍有 N 条待传」');
    });

    test('进度按阶段推进：连接 → 上传 → 下载，跑完清空', () async {
      final seen = <SyncStage>[];
      void listener() {
        final pr = engine.progress;
        if (pr != null && (seen.isEmpty || seen.last != pr.stage)) {
          seen.add(pr.stage);
        }
      }

      engine.addListener(listener);
      await paired();
      await store.createRecipe(RecipeDraft(name: '带进度的菜'));
      await engine.sync();
      await settle();
      engine.removeListener(listener);

      expect(seen, contains(SyncStage.connecting));
      expect(seen, contains(SyncStage.pulling));
      expect(engine.progress, isNull,
          reason: '跑完（或失败）都不能把进度条留在屏上');
    });
  });
}

/// 等真 HTTP 往返落地：这些测试跑在 FakeAsync 区里，真网络的完成不在虚拟时间上，
/// 只能按真实时间等一会（同 me_page_access_test 的 settleReal 手法）。
Future<void> settle({int ms = 1200}) =>
    Future<void>.delayed(Duration(milliseconds: ms));

// ════════════════════════════════════════════════════════════════════

/// 测试内的同步协议模拟服务端。走**真 HTTP**（dart:io HttpServer），
/// 协议形状与 server/lib/src/sync.dart 对齐：配对码换 token、Bearer 鉴权、
/// mutationId 幂等（重放返回上次结果）、seq 游标分页、载荷跟随变更。

