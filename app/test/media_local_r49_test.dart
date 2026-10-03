import 'dart:convert';
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

/// R49 · 照片本机层（设计 §3/§4）。
///
/// 钉的是**权威搬回本机**这条口径：保存必落 `media_blob` 且零网络请求；
/// 读取本机优先，本机没有才拉**原图**一份并落盘——缩略档由显示端解码期
/// 缩放，不再按档位打服务端。旧 R17 的「两档分别拉」口径随本批作废
/// （见 sync_engine_test 同批改写）。
void main() {
  late FakeSyncServer server;
  late RecipeStore store;
  late SyncEngine engine;

  setUpAll(() async {
    server = await FakeSyncServer.start();
  });
  tearDownAll(() async {
    await server.close();
  });
  setUp(() async {
    server.reset();
    // AI/媒体同一道门：open 模式 + 合法 X-Node-Id 放行匿名。
    server.accessMode = 'open';
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
    final prefs = SyncPrefs(store.dbOrNull!);
    await prefs.setServerUrl(server.url);
    // ★ transport 在 allowRealHttp **之后**建（binding 的 400 mock 坑，同 ai_feature_test）。
    FakeSyncServer.allowRealHttp();
    engine = SyncEngine(
      db: store.dbOrNull!,
      prefs: prefs,
      transport: HttpSyncTransport(
        Uri.parse(server.url),
        nodeId: 'testnode01',
      ),
    );
  });
  tearDown(() async {
    engine.dispose();
    await store.dbOrNull!.close();
    store.dispose();
  });

  Future<Map<String, Object?>?> blobRow(String sha) async {
    final rows = await store.dbOrNull!
        .customSelect(
          'SELECT sha, size, uploaded FROM media_blob WHERE sha = ?',
          variables: [Variable(sha)],
        )
        .get();
    return rows.isEmpty ? null : rows.first.data;
  }

  final bytes3 = Uint8List.fromList([1, 2, 3]);
  String shaOf(Uint8List b) => crypto.sha256.convert(b).toString();

  test('putMediaLocal 落本机即回 sha：零 HTTP、待传数 +1', () async {
    final sha = shaOf(bytes3);
    expect(await engine.putMediaLocal(bytes3), sha);
    expect(server.mediaPaths, isEmpty); // 没碰网络

    final row = await blobRow(sha);
    expect(row, isNotNull);
    expect(row!['uploaded'], 0); // 在欠账上
    expect(row['size'], 3);
    expect(engine.pendingMediaCount, 1);

    // 本机优先：缩略档也不打服务端（旧口径按 w= 拉两档，随 R49 作废）
    expect(await engine.fetchMediaCached(sha, width: MediaWidth.card), bytes3);
    expect(server.mediaPaths, isEmpty);
  });

  test('本机没有才拉原图一份，拉回必落盘 uploaded=1', () async {
    final sha = 'a' * 64; // 假服务端预置有这张
    final got = await engine.fetchMediaCached(sha, width: MediaWidth.card);
    expect(utf8.decode(got!), 'full:$sha'); // 拿回的是原图，不是 w640 派生
    expect(server.mediaPaths, ['/api/media/$sha']); // 原图档，不带 w

    final row = await blobRow(sha);
    expect(row, isNotNull, reason: '拉过即落盘：这张图从此离线可看');
    expect(row!['uploaded'], 1); // 服务端已有，不欠账

    server.mediaPaths.clear();
    expect(
      await engine.fetchMediaCached(sha, width: MediaWidth.detail),
      utf8.encode('full:$sha'),
    );
    expect(server.mediaPaths, isEmpty); // 任何档位都从本机/缓存出
  });

  test('同字节重复 putMediaLocal 不倒退：传过的仍算已传', () async {
    final sha = await engine.putMediaLocal(bytes3);
    // 演「这张已经补传成功」：直接翻标记（真实路径是 drain 干的，Task 4 钉）。
    await store.dbOrNull!.customUpdate(
      'UPDATE media_blob SET uploaded = 1 WHERE sha = ?',
      variables: [Variable(sha)],
    );
    await engine.refreshPendingMediaCount();
    expect(engine.pendingMediaCount, 0);
    expect(await engine.putMediaLocal(bytes3), sha);
    expect((await blobRow(sha))!['uploaded'], 1,
        reason: 'INSERT OR IGNORE 不重写——已上传的图不能被倒退回待传');
    expect(engine.pendingMediaCount, 0);
  });

  test('未配对（无 serverUrl）：本机层照常可写可读', () async {
    final lonely = RecipeStore(executor: NativeDatabase.memory());
    await lonely.ready();
    addTearDown(() async {
      await lonely.dbOrNull!.close();
      lonely.dispose();
    });
    final p = SyncPrefs(lonely.dbOrNull!);
    // 不 setServerUrl——纯单机
    final e2 = SyncEngine(
      db: lonely.dbOrNull!,
      prefs: p,
      transport: HttpSyncTransport(
        Uri.parse(server.url),
        nodeId: 'testnode01',
      ),
    );
    addTearDown(e2.dispose);
    final sha = shaOf(bytes3);
    expect(await e2.putMediaLocal(bytes3), sha);
    expect(await e2.fetchMediaCached(sha), bytes3); // 没网络也读得到
  });

  // ── R49·T3 工装自证：假服务端收得下 PUT、存得回字节、点得死一张 ──

  test('★ 工装自证：PUT 上传入账，GET 回同一字节；failMediaPutSha 一次性', () async {
    final bytes = Uint8List.fromList([5, 4, 4, 3, 3, 3]);
    final sha = shaOf(bytes);
    final t = HttpSyncTransport(Uri.parse(server.url), nodeId: 'testnode01');
    addTearDown(t.close);

    await t.putBytes('/api/media/$sha', bytes); // open 模式匿名可传（同真服务端）
    expect(server.putMedia[sha], bytes, reason: '上传必须真的存进假服务端');
    expect(await t.getBytes('/api/media/$sha'), bytes,
        reason: 'GET 优先回存过的真字节，不是预置假载荷');

    server.failMediaPutSha = sha;
    await expectLater(
      t.putBytes('/api/media/$sha', Uint8List.fromList([0])),
      throwsA(isA<SyncTransportException>()
          .having((e) => e.statusCode, 'status', 500)),
    );
    expect(server.failMediaPutSha, isNull, reason: '开关是一次性的');
  });
}
