import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/seed.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// 客户端本地库 + 仓库层的测试。
///
/// **全部用真实文件/内存 SQLite，不用 mock**——要验证的恰恰是
/// 「shared 的 DDL 在 Drift 的连接上真的能建出来、种子真的能灌进去」，
/// mock 掉就什么都没验到。
void main() {
  // sqlite3 3.x 改用 build hooks 加载原生库（不再有 open.overrideFor）。
  // 宿主机上能不能直接加载，本身就是这一组测试的前提——跑不过就是答案。

  test('shared 的 DDL 能在 Drift 连接上建出来，种子能灌进去', () async {
    final store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();

    expect(store.recipes, hasLength(kSeedRecipes.length), reason: '种子菜谱应当全部入库');

    final r1 = store.recipeById('r1');
    expect(r1, isNotNull);
    expect(r1!.name, '番茄炒蛋');
    expect(r1.ingredients, hasLength(6));
    expect(r1.steps, hasLength(5));
    expect(r1.ingredients.first.name, '番茄');
    expect(r1.ingredients.first.qty, '2 个', reason: '分量展示用原文，不做单位换算');
    expect(r1.ingredients.first.isMain, isTrue);
    // 封面编号经过「枚举 → int → 枚举」的往返后必须还原
    expect(r1.art, kSeedRecipes[0].art);
    expect(r1.palette, kSeedRecipes[0].palette);
    // 标签 JSON 往返
    expect(r1.tags['method'], ['爆炒']);
    // AI 来源与 HLC 落库
    final ai = store.recipeById('r9');
    expect(ai!.source, RecipeSource.ai);
    expect(ai.sourceModel, 'deepseek-v4-flash');
  });

  test('五列规范：种子的 updated_at 是合法 HLC，且全表递增', () async {
    final store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();

    final db = store.dbForTest!;
    final rows = await db
        .customSelect('SELECT updated_at FROM recipe ORDER BY updated_at')
        .get();

    expect(rows, isNotEmpty);
    Hlc? prev;
    for (final row in rows) {
      final hlc = Hlc.decode('${row.data['updated_at']}');
      if (prev != null) {
        expect(
          hlc.compareTo(prev),
          greaterThan(0),
          reason: '同一节点上 HLC 必须单调递增（$prev → $hlc）',
        );
      }
      prev = hlc;
    }
    expect(prev!.nodeId, 'seed');
  });

  test('init 是幂等的：重复调用不会把种子灌两遍', () async {
    final store = RecipeStore(executor: NativeDatabase.memory());
    await store.init();
    await store.init();
    await store.ready();

    expect(store.recipes, hasLength(kSeedRecipes.length));
    final db = store.dbForTest!;
    final c = await db
        .customSelect('SELECT COUNT(*) AS c FROM recipe')
        .getSingle();
    expect(c.data['c'], kSeedRecipes.length, reason: '第二次 init 不应再灌一遍种子');
  });

  test('收藏初始 4 道，可切换', () async {
    final store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();

    expect(store.favs, hasLength(4), reason: '种子里收藏了 4 道');
    expect(store.isFav('r1'), isTrue);
    expect(store.isFav('r3'), isFalse, reason: '蒜蓉粉丝蒸虾没收藏');

    store.toggleFav('r3');
    expect(store.isFav('r3'), isTrue);
    store.toggleFav('r3');
    expect(store.isFav('r3'), isFalse);
  });

  test('★ 收藏重启后不丢：落在 local_pref，且种子不会把它灌回来', () async {
    // R12 之前收藏是内存态：重启后用户取消过的种子收藏被重新灌回来，
    // 这是产品里最典型的信任破坏。现在必须用真实文件库验证跨重启。
    final dir = await Directory.systemTemp.createTemp('zaoji_fav_test_');
    addTearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final path = '${dir.path}${Platform.pathSeparator}zaoji.db';

    // 第一次启动：取消一个种子收藏（r1），收藏一个没收藏的（r3）
    final first = RecipeStore(executor: NativeDatabase(File(path)));
    await first.ready();
    first.toggleFav('r1'); // 种子收藏 → 取消
    first.toggleFav('r3'); // 没收藏 → 收藏
    await first.dbForTest!.customSelect('SELECT 1').get(); // 排空写队列
    // 先关库（drift 的 close 幂等，可重复调用），再拆 ChangeNotifier
    await first.dbForTest!.close();
    first.dispose();

    // 第二次启动：以库为准，种子无权再发表意见
    final second = RecipeStore(executor: NativeDatabase(File(path)));
    await second.ready();

    expect(second.isFav('r1'), isFalse, reason: '用户取消过的收藏不能被种子复活');
    expect(second.isFav('r3'), isTrue, reason: '用户新加的收藏不能丢');
    expect(second.favs, hasLength(4), reason: '4 - 1 + 1 = 4');
    await second.dbForTest!.close();
    second.dispose();
  });

  test('local_pref 表存在且不参与同步（收藏的落库前提）', () async {
    final store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();

    final db = store.dbForTest!;
    // 客户端只建 business + localOnly 表，local_pref 属于后者，必须建出来
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'table' "
          "AND name = 'local_pref'",
        )
        .get();
    expect(rows, hasLength(1), reason: 'local_pref 表必须被建出来');
    expect(
      syncWhitelist.containsKey('local_pref'),
      isFalse,
      reason: '本机偏好永不外发',
    );
  });

  test('软删除的行不会出现在列表里（墓碑语义从第一天就成立）', () async {
    final store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();

    final db = store.dbForTest!;
    await db.customStatement(
      "UPDATE recipe SET deleted_at = '2026-09-18T00:00:00' WHERE id = 'r5'",
    );

    final loaded = await store.reloadForTest();
    expect(
      loaded.map((r) => r.id),
      isNot(contains('r5')),
      reason: 'deleted_at 非 NULL = 已删除，列表不可见',
    );
  });
}
