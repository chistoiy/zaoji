import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/models.dart';

/// R32 · 烹饪统计（FR-LOG-05）的数据层：本月会话明细。
///
/// 口径与 R24 日历完全一致：**只有 finished_at 非空且未软删的会话算做过**
/// （进行中=还没做成，不進账）。统计页剩下的三块（最常做/热度分布）
/// 都从 store.recipes 的 cooked_count / last_cooked_at 现算，不新增查询。
void main() {
  late RecipeStore store;

  setUp(() async {
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
  });

  tearDown(() async {
    await store.dbOrNull!.close();
    store.dispose();
  });

  /// 直造会话行：日期要摆到过去，真 startCooking 只会写「现在」。
  Future<void> seedSession(
    String id,
    String recipeId,
    String startedIso,
    String? finishedIso, {
    bool deleted = false,
  }) {
    final delSql = deleted ? "'2026-09-20T00:00:00'" : 'NULL';
    final finSql = finishedIso == null ? 'NULL' : '?';
    final vars = <drift.Variable<Object>>[
      drift.Variable<String>(id),
      drift.Variable<String>(recipeId),
      drift.Variable<String>(startedIso),
      if (finishedIso != null) drift.Variable<String>(finishedIso),
    ];
    return store.dbOrNull!.customInsert(
      'INSERT INTO cook_session (id, updated_at, updated_by, rev, deleted_at, '
      'recipe_id, started_at, finished_at, current_step, servings_used, state) '
      "VALUES (?, '000000000000-0000-node', 'node', 1, $delSql, ?, ?, $finSql, 0, NULL, NULL)",
      variables: vars,
    );
  }

  Future<Recipe> makeRecipe(String name, {int selfTime = 0}) =>
      store.createRecipe(RecipeDraft(name: name, selfTime: selfTime));

  group('monthSessions', () {
    test('★ 本月完成会话全量返回：菜 id、完成日、耗时分钟', () async {
      final a = await makeRecipe('番茄炒蛋');
      final b = await makeRecipe('红烧肉');
      await seedSession('m1', a.id, '2026-09-14T18:05:00', '2026-09-14T18:19:00');
      await seedSession('m2', b.id, '2026-09-14T11:00:00', '2026-09-14T12:30:00');
      final ss = await store.monthSessions(2026, 9);
      expect(ss, hasLength(2));
      final byRecipe = {for (final s in ss) s.recipeId: s};
      expect(byRecipe[a.id]!.day, '2026-09-14');
      expect(byRecipe[a.id]!.minutes, 14);
      expect(byRecipe[b.id]!.minutes, 90);
    });

    test('进行中 / 软删 / 跨月都不进账', () async {
      final r = await makeRecipe('葱油拌面');
      await seedSession('x1', r.id, '2026-09-16T07:00:00', null); // 进行中
      await seedSession('x2', r.id, '2026-08-30T18:00:00', '2026-08-30T18:30:00'); // 上月
      await seedSession('x3', r.id, '2026-09-14T20:00:00', '2026-09-14T20:10:00',
          deleted: true);
      expect(await store.monthSessions(2026, 9), isEmpty);
    });

    test('耗时解析不出来记 0 而不是抛（脏行不拖垮整页）', () async {
      final r = await makeRecipe('薛定谔菜');
      await seedSession('z1', r.id, 'not-a-date', '2026-09-14T12:00:00');
      final ss = await store.monthSessions(2026, 9);
      expect(ss.single.minutes, 0);
    });
  });

  group('统计页口径（现算于 recipes，不新增查询）', () {
    test('最常做榜：cooked_count 降序、只做过的上榜', () async {
      final a = await makeRecipe('番茄炒蛋');
      final b = await makeRecipe('红烧肉');
      // 走真实完成路径加计数太绕，直接 UPDATE（cooked_count 是业务列，同步会带走）。
      Future<void> bump(String id, int n) => store.dbOrNull!.customInsert(
            'UPDATE recipe SET cooked_count = ? WHERE id = ?',
            variables: [drift.Variable<int>(n), drift.Variable<String>(id)],
          );
      await bump(a.id, 3);
      await bump(b.id, 7);
      await store.reloadForTest();
      // 库里还有 9 道种子菜也带着 cooked_count，只取本次造的两道比排序。
      final ids = {a.id, b.id};
      final ranked = store.recipes
          .where((r) => ids.contains(r.id) && r.cookedCount > 0)
          .toList()
        ..sort((x, y) => y.cookedCount.compareTo(x.cookedCount));
      expect(ranked.map((r) => r.name), ['红烧肉', '番茄炒蛋']);
      expect(ranked.first.cookedCount, 7);
    });

    test('校准对照：本月同菜多次取均值，自报 0 不参与', () async {
      final a = await makeRecipe('番茄炒蛋', selfTime: 10);
      final b = await makeRecipe('随缘菜'); // self_time=0
      await seedSession('k1', a.id, '2026-09-01T18:00:00', '2026-09-01T18:16:00');
      await seedSession('k2', a.id, '2026-09-08T18:00:00', '2026-09-08T18:18:00');
      await seedSession('k3', b.id, '2026-09-02T18:00:00', '2026-09-02T18:40:00');
      final ss = await store.monthSessions(2026, 9);
      final byRecipe = <String, List<int>>{};
      for (final s in ss) {
        byRecipe.putIfAbsent(s.recipeId, () => []).add(s.minutes);
      }
      final avgA =
          byRecipe[a.id]!.reduce((x, y) => x + y) / byRecipe[a.id]!.length;
      expect(avgA, 17.0, reason: '两次 16/18 分钟 → 均值 17，自报 10 差 7 → 校准卡');
      expect(byRecipe.containsKey(b.id), isTrue,
          reason: '自报 0 的会话照样进明细，页面侧按 selfTime>0 过滤即可');
    });
  });
}
