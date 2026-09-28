import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/health_models.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// R33 · 数据体检的判定逻辑（纯函数，不吃时钟也不查库）。
///
/// 「从没做过的冷灶菜」**有意不做**：recipe 没有创建时间列（R24 就记过这笔账，
/// 用 updated_at 猜会漂），等加列窗口再开。日期口径沿用 pantry 的
/// 「字符串比较不做 now 减法」（R28）：过期 = expireAt 的日期早于今天。
void main() {
  final now = DateTime.parse('2026-09-28T12:00:00');

  Recipe recipe(
    String id, {
    String name = '菜',
    int cookedCount = 0,
    List<Ingredient> ingredients = const [],
    List<Step> steps = const [],
  }) =>
      Recipe(
        id: id,
        name: name,
        sub: '',
        difficulty: 1,
        selfTime: 0,
        servings: 2,
        ingredients: ingredients,
        steps: steps,
        cookedCount: cookedCount,
      );

  PantryItem expired(String id, {String name = '酸奶'}) =>
      PantryItem(id: id, name: name, expireAt: '2026-09-20');
  PantryItem ok(String id) =>
      PantryItem(id: id, name: '鸡蛋', expireAt: '2026-10-20');
  ShoppingItem stale(String id, {String name = '葱'}) =>
      ShoppingItem(id: id, name: name);
  ShoppingItem bought(String id) =>
      ShoppingItem(id: id, name: '蒜', bought: true);

  ZombieSession zombie(String recipeId, String name, int hours) => ZombieSession(
      recipeId: recipeId,
      recipeName: name,
      startedAt: now.subtract(Duration(hours: hours)));

  List<HealthIssue> run({
    List<Recipe> recipes = const [],
    List<PantryItem> pantry = const [],
    List<ShoppingItem> shopping = const [],
    List<ZombieSession> zombies = const [],
    int staleDays = 14,
  }) =>
      healthIssues(
        recipes: recipes,
        pantry: pantry,
        shopping: shopping,
        zombies: zombies,
        // 清单业务时刻表：默认全部「刚好到龄」，由 staleDays 阈值控边界。
        shoppingAges: {for (final s in shopping) s.id: now},
        now: now,
        staleDays: staleDays,
      );

  List<HealthIssue> byKey(List<HealthIssue> issues, String key) =>
      issues.where((i) => i.key == key).toList();

  test('空库 = 零问题而不是 null/抛', () {
    expect(run(), isEmpty);
  });

  test('残缺菜谱：缺食材和缺步骤分开列，名字点名', () {
    final issues = run(recipes: [
      recipe('a', name: '无米菜', ingredients: [], steps: [Step('炒')]),
      recipe('b', name: '光有料', ingredients: [Ingredient('盐', '1 勺')], steps: []),
      recipe('c', name: '两头空'),
    ]);
    final noIng = byKey(issues, 'no-ingredients').single;
    final noStep = byKey(issues, 'no-steps').single;
    expect(noIng.count, 2, reason: '无米菜 + 两头空');
    expect(noIng.detail, contains('无米菜'));
    expect(noIng.detail, contains('两头空'));
    expect(noStep.count, 2, reason: '光有料 + 两头空');
    expect(noStep.detail, contains('光有料'));
  });

  test('过期库存点名计数；未过期不进账', () {
    final issues =
        run(pantry: [expired('p1'), ok('p2'), expired('p3', name: '牛奶')]);
    final e = byKey(issues, 'expired-pantry').single;
    expect(e.count, 2);
    expect(e.detail, contains('酸奶'));
    expect(e.detail, contains('牛奶'));
    expect(e.detail, isNot(contains('鸡蛋')));
  });

  test('★ 僵尸会话按小时点名，最久的排前面', () {
    final issues = run(zombies: [
      zombie('r1', '葱油拌面', 50),
      zombie('r2', '红烧肉', 120),
    ]);
    final z = byKey(issues, 'zombie-sessions').single;
    expect(z.count, 2);
    expect(z.detail.indexOf('红烧肉'), lessThan(z.detail.indexOf('葱油拌面')));
    expect(z.detail, contains('120 小时'));
  });

  test('久未采买：只数未购的，bought 的沉底不算积压', () {
    final issues = run(
        shopping: [stale('s1'), stale('s2', name: '姜'), bought('s3')],
        staleDays: 0);
    final s = byKey(issues, 'stale-shopping').single;
    expect(s.count, 2);
    expect(s.detail, contains('姜'));
    expect(s.detail, isNot(contains('蒜')));
  });

  test('问题顺序固定：残缺 → 库存 → 会话 → 清单', () {
    final issues = run(
      recipes: [recipe('c', name: '两头空')],
      pantry: [expired('p')],
      shopping: [stale('s')],
      zombies: [zombie('z', '挂着', 99)],
      staleDays: 0,
    );
    expect(issues.map((i) => i.key).toList(), [
      'no-ingredients',
      'no-steps',
      'expired-pantry',
      'zombie-sessions',
      'stale-shopping',
    ]);
  });

  test('每类问题各一条，条目为空则该组缺席（不是 count=0 的空条）', () {
    final issues = run(pantry: [ok('p1')]);
    expect(issues, isEmpty);
  });

  // ── store 供料：体检页的两份异步原始料 ──

  group('store 供料', () {
    late RecipeStore store;

    setUp(() async {
      store = RecipeStore(executor: NativeDatabase.memory());
      await store.ready();
    });

    tearDown(() async {
      await store.dbOrNull!.close();
      store.dispose();
    });

    Future<void> seedSession(String id, String recipeId,
        {String? finished, bool deleted = false}) {
      final delSql = deleted ? "'2026-09-20T00:00:00'" : 'NULL';
      final finSql = finished == null ? 'NULL' : '?';
      final vars = <drift.Variable<Object>>[
        drift.Variable<String>(id),
        drift.Variable<String>(recipeId),
        drift.Variable<String>('2026-09-26T18:00:00'),
        if (finished != null) drift.Variable<String>(finished),
      ];
      return store.dbOrNull!.customInsert(
        'INSERT INTO cook_session (id, updated_at, updated_by, rev, deleted_at, '
        'recipe_id, started_at, finished_at, current_step, servings_used, state) '
        "VALUES (?, '000000000000-0000-node', 'node', 1, $delSql, ?, ?, $finSql, 0, NULL, NULL)",
        variables: vars,
      );
    }

    test('openCookSessions：只回未完成未软删的，started_at 原样带出', () async {
      final r = await store.createRecipe(RecipeDraft(name: '挂着'));
      await seedSession('o1', r.id);
      await seedSession('o2', r.id, finished: '2026-09-26T19:00:00');
      await seedSession('o3', r.id, deleted: true);
      final opens = await store.openCookSessions();
      expect(opens, hasLength(1));
      expect(opens.single.recipeId, r.id);
      expect(opens.single.startedAt, '2026-09-26T18:00:00');
    });

    test('★ shoppingItemAges：updated_at 解的是 HLC 物理段；脏行跳过不拖垮整页', () async {
      final added = await store.addShoppingItems([
        (name: '葱', qtyText: null, recipeId: null),
        (name: '姜', qtyText: null, recipeId: null),
      ]);
      expect(added, 2);
      final byName = {for (final s in store.shoppingItems) s.name: s.id};
      final old = Hlc.now('node',
              wallMs: DateTime.parse('2026-09-01T08:00:00')
                  .millisecondsSinceEpoch)
          .encode();
      await store.dbOrNull!.customUpdate(
        'UPDATE shopping_item SET updated_at = ? WHERE id = ?',
        variables: [
          drift.Variable<String>(old),
          drift.Variable<String>(byName['葱']!),
        ],
      );
      await store.dbOrNull!.customUpdate(
        "UPDATE shopping_item SET updated_at = 'not-an-hlc' WHERE id = ?",
        variables: [drift.Variable<String>(byName['姜']!)],
      );
      final ages = await store.shoppingItemAges();
      expect(ages.containsKey(byName['葱']), isTrue);
      expect(ages[byName['葱']], DateTime.parse('2026-09-01T08:00:00'));
      expect(ages.containsKey(byName['姜']), isFalse,
          reason: '解不出物理时刻的行宁可不进账');
    });
  });
}
