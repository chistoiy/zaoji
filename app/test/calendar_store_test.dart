import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/models.dart';

/// R24 · 日历页的数据层：月标记 + 当日做菜记录。
///
/// 关键事实：`cook_session.started_at / finished_at` 是 **ISO8601 业务时间戳**
/// （R20 定样，HLC 只在 updated_at 当同步元数据）——日历折算日期直接截串，
/// 不去解 HLC。进行中（finished_at IS NULL）的会话**不算做过**。
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

  /// 直接造一条会话行：日期要能摆到过去，真 startCooking 只会写「现在」。
  Future<void> seedSession(
    String id,
    String recipeId,
    String startedIso,
    String? finishedIso, {
    bool deleted = false,
  }) {
    // drift 的 Variable 不接受 null，删除态与「未完成」直接把 NULL 内联进 SQL。
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

  Future<Recipe> makeRecipe(String name) =>
      store.createRecipe(RecipeDraft(name: name));

  group('monthMarks', () {
    test('★ 完成的会话按 finished 日期点 cook 点；进行中/软删/跨月都不算', () async {
      final r = await makeRecipe('葱油拌面');
      await seedSession('c1', r.id, '2026-09-14T18:05:00', '2026-09-14T18:19:00');
      await seedSession('c2', r.id, '2026-09-16T07:00:00', null); // 进行中
      await seedSession('c3', r.id, '2026-08-30T18:00:00', '2026-08-30T18:30:00'); // 上月
      await seedSession('c4', r.id, '2026-09-14T20:00:00', '2026-09-14T20:10:00',
          deleted: true);
      final m = await store.monthMarks(2026, 9);
      expect(m.cookDays, {'2026-09-14'});
      expect(m.cookCount, 1);
    });

    test('menu 标记取 menu.day，软删的餐次不算', () async {
      final m1 = await store.createMenu(day: '2026-09-15', meal: '晚餐');
      await store.createMenu(day: '2026-09-16', meal: '早餐');
      await store.deleteMenu(m1.id);
      final marks = await store.monthMarks(2026, 9);
      expect(marks.menuDays, {'2026-09-16'});
    });

    test('空月两面全空而不是 null/抛', () async {
      final m = await store.monthMarks(2030, 2);
      expect(m.cookDays, isEmpty);
      expect(m.menuDays, isEmpty);
      expect(m.cookCount, 0);
    });
  });

  group('cookEventsOn', () {
    test('★ 当日完成记录：菜名、时刻取 finished、耗时 = start→finish', () async {
      final a = await makeRecipe('番茄炒蛋');
      final b = await makeRecipe('蚝油生菜');
      await seedSession('e1', b.id, '2026-09-14T19:40:00', '2026-09-14T19:47:00');
      await seedSession('e2', a.id, '2026-09-14T18:05:00', '2026-09-14T18:19:00');
      await seedSession('e3', a.id, '2026-09-15T18:00:00', '2026-09-15T18:10:00');
      final evs = await store.cookEventsOn('2026-09-14');
      expect(evs.map((e) => e.recipeName), ['番茄炒蛋', '蚝油生菜'],
          reason: '按完成时刻升序——还原那晚的下锅顺序');
      expect(evs.first.time, '18:19');
      expect(evs.first.minutes, 14);
    });

    test('菜被删了记录还在（日历是历史），名字给退化文案', () async {
      final r = await makeRecipe('告别菜');
      await seedSession('d1', r.id, '2026-09-14T12:00:00', '2026-09-14T12:30:00');
      await store.softDeleteRecipe(r.id);
      final evs = await store.cookEventsOn('2026-09-14');
      expect(evs, hasLength(1));
      expect(evs.single.recipeName, contains('已删除'));
      expect(evs.single.recipeId, r.id);
    });

    test('没记录的日期回空列表', () async {
      expect(await store.cookEventsOn('2026-09-11'), isEmpty);
    });
  });
}
