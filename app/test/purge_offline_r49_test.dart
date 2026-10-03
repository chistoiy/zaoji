import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/sync/sync_engine.dart';
import 'package:zaoji/data/sync/sync_prefs.dart';
import 'package:zaoji/data/sync/sync_transport.dart';

import 'fake_sync_server.dart';

/// R49 · 永久删除单机放行（设计 §6）。
///
/// 旧口径「先问服务端再删本机」在**纯单机手机**上变成"回收站永远清不掉"，
/// 离线时也把删除整个卡死。新口径三分支：
/// 未接入 → 直删不入队；服务端认 → R43 原序；连不上/超时/老服务端 404 →
/// 直删 + `pending_purge` 补账（连子行一起入队——否则别端改了子行，
/// 拉回来撞外键炸整轮），同步成功后 [_drainLocalQueues] 逐条补广播；
/// 在账期间拉取跳过该行 upsert **防复活**。
///
/// ★ 「连不上」的演法：transport 在引擎里是**缓存的**（改 prefs 里的地址
/// 不换已建的 transport），所以离线 = 用指向死端口的 transport **重建引擎**，
/// db/prefs 原封——这正对应真机上"配对过、现在出了门"的形态。
void main() {
  late FakeSyncServer server;
  late RecipeStore store;
  late SyncPrefs prefs;
  late SyncEngine engine;

  SyncEngine makeEngine(Uri url) => SyncEngine(
        db: store.dbOrNull!,
        prefs: prefs,
        transport: HttpSyncTransport(url, nodeId: 'n1'),
        onDataApplied: store.reload,
      );

  final deadUri = Uri.parse('http://127.0.0.1:9'); // discard 端口：秒拒

  setUpAll(() async {
    server = await FakeSyncServer.start();
  });
  tearDownAll(() async => server.close());

  setUp(() async {
    server.reset();
    FakeSyncServer.allowRealHttp();
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
    prefs = SyncPrefs(store.dbOrNull!);
    engine = makeEngine(Uri.parse(server.url));
  });
  tearDown(() async {
    engine.dispose();
    await store.dbOrNull!.close();
    store.dispose();
  });

  Future<void> paired() => engine.pair(serverUrl: server.url, code: 'TEST24');

  /// 进回收站并把墓碑推上服务端（真机上删除后总会先同步过一轮）。
  Future<void> trash(String id) async {
    await store.softDeleteRecipe(id);
    await engine.sync();
  }

  Future<int> count(String sql) async {
    final r = await store.dbOrNull!.customSelect(sql).getSingle();
    return r.read<int>('c');
  }

  Future<Set<String>> queueRows() async {
    final rows = await store.dbOrNull!
        .customSelect('SELECT tbl, row_id FROM pending_purge')
        .get();
    return rows
        .map((r) => '${r.read<String>('tbl')}/${r.read<String>('row_id')}')
        .toSet();
  }

  group('永久删除三分支', () {
    test('未接入（无 serverUrl）：直删，不入队', () async {
      await trash('r1'); // 未配对的 sync 是安静 no-op，墓碑只在本机
      expect(await engine.purgeRecipePermanently('r1'), isNull);
      expect(await count("SELECT COUNT(*) AS c FROM recipe WHERE id='r1'"), 0);
      expect(await queueRows(), isEmpty, reason: '单机没有"别的设备"要通知');
      expect(server.purgeCount, 0);
    });

    test('已接入但连不上：直删 + 入队（含子行）；恢复后补删出队', () async {
      await paired();
      await trash('r1');

      engine.dispose();
      engine = makeEngine(deadUri); // 出门实况：同一个库，transport 敲不开
      expect(await engine.purgeRecipePermanently('r1'), isNull);
      expect(await count("SELECT COUNT(*) AS c FROM recipe WHERE id='r1'"), 0);
      final q = await queueRows();
      expect(q, contains('recipe/r1'));
      expect(q.any((e) => e.startsWith('ingredient/')), isTrue,
          reason: '子行不入队，别端改了子行拉回来会撞外键炸整轮');
      expect(q.any((e) => e.startsWith('step/')), isTrue);
      expect(server.rows['recipe']!['r1'], isNotNull, reason: '服务端还不知道');

      engine.dispose();
      engine = makeEngine(Uri.parse(server.url)); // 回家
      await engine.sync();
      expect(await queueRows(), isEmpty, reason: '补删成功即出队');
      expect(server.rows['recipe']!['r1'], isNull, reason: '服务端物理没了');
      expect(await count("SELECT COUNT(*) AS c FROM recipe WHERE id='r1'"), 0);
    });

    test('★ 防复活：在账期间服务端推该行 upsert，本机不诈尸', () async {
      await paired();
      await trash('r1');
      engine.dispose();
      engine = makeEngine(deadUri);
      expect(await engine.purgeRecipePermanently('r1'), isNull);

      // 离线期间 B 设备在服务端把这道菜改了（走假服务端的落库+盖章+记日志）
      server.injectRecipe(id: 'r1', name: 'B 改过的番茄炒蛋');

      engine.dispose();
      engine = makeEngine(Uri.parse(server.url));
      await engine.sync(); // 拉取撞上账 → 跳过
      expect(
          await count("SELECT COUNT(*) AS c FROM recipe WHERE id='r1'"), 0,
          reason: '欠账未销的行不能被服务端旧数据复活');
      await engine.sync(); // 再一轮（补广播的 purge 变更也走一遍）
      expect(await count("SELECT COUNT(*) AS c FROM recipe WHERE id='r1'"), 0);
    });

    test('老服务端 404：直删 + 入队；换新版 exe 后自动补上', () async {
      await paired();
      await trash('r1');
      server.supportsPurge = false; // 演 v0.14.3 及更早：路由都没有

      expect(await engine.purgeRecipePermanently('r1'), isNull);
      expect(await count("SELECT COUNT(*) AS c FROM recipe WHERE id='r1'"), 0);
      expect(await queueRows(), contains('recipe/r1'));
      expect(server.purgeCount, 0);

      server.supportsPurge = true; // 家里换了新 exe
      await engine.sync();
      expect(await queueRows(), isEmpty);
      expect(server.rows['recipe']!['r1'], isNull);
    });
  });

  group('本机图片回收', () {
    test('永久删除清掉不再被引用的 blob；两道菜共用同一张不误删', () async {
      final bytes = Uint8List.fromList([8, 6, 7, 5, 3, 0, 9]);
      final sha = crypto.sha256.convert(bytes).toString();
      await engine.putMediaLocal(bytes);

      final a = await store.createRecipe(RecipeDraft(
        name: '共用图甲',
        ingredients: const [],
        steps: const [],
        coverSha256: sha,
      ));
      final b = await store.createRecipe(RecipeDraft(
        name: '共用图乙',
        ingredients: const [],
        steps: const [],
        coverSha256: sha,
      ));

      Future<int> blobCount() => count(
          "SELECT COUNT(*) AS c FROM media_blob WHERE sha = '$sha'");

      await store.softDeleteRecipe(a.id);
      expect(await engine.purgeRecipePermanently(a.id), isNull);
      expect(await blobCount(), 1, reason: '乙还引用着同一张——不能删');

      await store.softDeleteRecipe(b.id);
      expect(await engine.purgeRecipePermanently(b.id), isNull);
      expect(await blobCount(), 0, reason: '最后一个引用没了，字节随手回收');
    });
  });
}
