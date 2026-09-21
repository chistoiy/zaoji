import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/sync/conflict_box.dart';
import 'package:zaoji/data/sync/sync_engine.dart';
import 'package:zaoji/data/sync/sync_prefs.dart';
import 'package:zaoji/data/sync/sync_transport.dart';
import 'package:zaoji/data/zaoji_db.dart';

import 'fake_sync_server.dart';

/// R22 · 冲突箱客户端（store 查询 / 引擎提交）。
///
/// 与 sync_access_test 同一立场：走真 HTTP + 假服务端，引擎零 mock。
/// ★ 本文件刻意不放 testWidgets：binding 一旦被初始化，flutter_test 会把
///   HttpClient 换成回 400 的全局 mock，纯 test() 里的真 HTTP 就全瞎了
///   （页面测试在 conflict_box_page_test.dart，那边用 allowRealHttp 撤掉）。
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
      onDataApplied: () => store.reload(),
    );
    await prefs.setServerUrl(server.url);
    server.reset();
  });

  tearDown(() async {
    engine.dispose();
    await store.dbOrNull!.close();
    store.dispose();
  });

  /// 往本地库直接塞一条 conflict_item（模拟"同步已经把它拉回来了"）。
  Future<void> seedConflict(
    ZaojiDb db, {
    required String id,
    required String tbl,
    required String rowId,
    required String field,
    Object? localValue,
    Object? remoteValue,
    String? resolvedAt,
  }) => db.customInsert(
    'INSERT INTO conflict_item (id, updated_at, updated_by, rev, tbl, row_id, '
    'field, local_value, remote_value, local_hlc, remote_hlc, local_by, '
    'remote_by, resolved_at) '
    "VALUES (?, 'h-1', 'server', 1, ?, ?, ?, ?, ?, 'h-1', 'h-1', 'dev-a', 'dev-b', ?)",
    variables: [
      Variable<String>(id),
      Variable<String>(tbl),
      Variable<String>(rowId),
      Variable<String>(field),
      Variable<String>(localValue == null ? null : '$localValue'),
      Variable<String>(remoteValue == null ? null : '$remoteValue'),
      Variable<String>(resolvedAt),
    ],
  );

  group('store.conflictGroups', () {
    test('按行分组、标题翻译到菜名、已裁决的不出现', () async {
      final db = store.dbOrNull!;
      final recipe = store.recipes.first;
      await seedConflict(db,
          id: 'c1', tbl: 'recipe', rowId: recipe.id, field: 'name',
          localValue: 'A', remoteValue: 'B');
      await seedConflict(db,
          id: 'c2', tbl: 'recipe', rowId: recipe.id, field: 'notes',
          localValue: 'x', remoteValue: 'y');
      await seedConflict(db,
          id: 'c3', tbl: 'recipe', rowId: recipe.id, field: 'difficulty',
          localValue: 1, remoteValue: 3, resolvedAt: 'h-9');

      final groups = await store.conflictGroups();
      expect(groups, hasLength(1), reason: '同一行两条冲突 = 一张卡');
      expect(groups.single.title, recipe.name);
      expect(groups.single.fields.map((f) => f.field), ['name', 'notes']);
      expect(await store.openConflictCount(), 1);
    });

    test('子表行找到归属的菜；行已不在时退化为 id 片段而不是抛错', () async {
      final db = store.dbOrNull!;
      final stepRow = await db
          .customSelect('SELECT id, recipe_id FROM step LIMIT 1')
          .getSingle();
      final owner = store.recipeById('${stepRow.data['recipe_id']}')!;
      await seedConflict(db,
          id: 's1', tbl: 'step', rowId: '${stepRow.data['id']}',
          field: 'text', localValue: 'a', remoteValue: 'b');
      await seedConflict(db,
          id: 'g1', tbl: 'recipe', rowId: 'gone-recipe',
          field: 'name', localValue: 'a', remoteValue: 'b');

      final groups = await store.conflictGroups();
      // ORDER BY tbl, row_id：recipe/gone-… 在前，step/… 在后
      expect(groups.first.title, startsWith('记录 '),
          reason: '找不到归属也要能显示（墓碑场景冲突照样要能裁决）');
      expect(groups.last.title, owner.name,
          reason: '步骤冲突也要说清是哪道菜的——只有 id 用户读不懂');
    });

    test('标签翻译：认得出的列给中文，认不出的原样列名', () {
      expect(fieldLabel('recipe', 'name'), '菜名');
      expect(fieldLabel('step', 'text'), '步骤内容');
      expect(fieldLabel('recipe', 'deleted_at'), '删除状态');
      expect(fieldLabel('recipe', 'mystery_col'), 'mystery_col',
          reason: '宁可看见英文列名，也不要显示一个错的名字');
    });
  });

  group('engine.resolveConflicts', () {
    test('★ 全链路：拉到冲突 → 提交裁决 → 本地行定稿、卡片消失', () async {
      server.accessMode = 'open';
      server.injectRecipe(id: 'cf-r', name: 'A 版');
      server.injectConflict(
          rowId: 'cf-r', field: 'name', localValue: 'A 版', remoteValue: 'B 版');
      await engine.syncIfPaired();
      final groups = await store.conflictGroups();
      expect(groups, hasLength(1));

      final results = await engine.resolveConflicts([
        {'conflictId': groups.single.fields.single.id, 'choice': 'remote'},
      ]);

      expect(results.single['outcome'], 'applied');
      expect(store.recipeById('cf-r')!.name, 'B 版',
          reason: 'resolve 内部紧跟一轮 sync——拉回服务端盖的章才算定稿');
      expect(await store.openConflictCount(), 0);
    });

    test('未接入服务端：不发请求，lastError 说清下一步', () async {
      // 全新库、从没填过地址的设备（unpair 刻意保留地址，测不出这条分支）
      final s2 = RecipeStore(executor: NativeDatabase.memory());
      await s2.ready();
      final p2 = SyncPrefs(s2.dbOrNull!);
      final e2 = SyncEngine(db: s2.dbOrNull!, prefs: p2);
      final results = await e2.resolveConflicts([
        {'conflictId': 'whatever', 'choice': 'local'},
      ]);
      expect(results, isEmpty);
      expect(e2.lastError, contains('尚未接入'));
      e2.dispose();
      await s2.dbOrNull!.close();
      s2.dispose();
    });

    test('服务端逐条结果原样透出（部分成功不假装全成）', () async {
      server.accessMode = 'open';
      server.injectRecipe(id: 'cf-r', name: 'A 版');
      final cid = server.injectConflict(
          rowId: 'cf-r', field: 'name', localValue: 'A', remoteValue: 'B');
      await engine.syncIfPaired();

      final results = await engine.resolveConflicts([
        {'conflictId': 'no-such-id-000000000000000000', 'choice': 'local'},
        {'conflictId': cid, 'choice': 'merged', 'mergedValue': '合稿'},
      ]);
      expect(results.map((r) => r['outcome']), ['not_found', 'applied']);
      expect(store.recipeById('cf-r')!.name, '合稿');
    });
  });

}
