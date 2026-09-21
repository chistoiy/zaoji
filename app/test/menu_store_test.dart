import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/models.dart';

/// R23 · 菜单 + 一键备菜的数据层。
///
/// 立场与 cooking_test 同款：菜单/菜品行都走五列 + HLC + 「先提交后广播」，
/// 备菜清单是**派生视图**不落库，只有勾选/手动项进本机偏好（永不外发）。
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

  Future<Recipe> makeRecipe(String name, List<IngredientDraft> ings) =>
      store.createRecipe(RecipeDraft(name: name, ingredients: ings));

  Future<Map<String, Object?>> one(String sql, [List<drift.Variable> vars = const []]) async {
    final rows = await store.dbOrNull!.customSelect(sql, variables: vars).get();
    expect(rows, hasLength(1));
    return rows.first.data;
  }

  group('菜单 CRUD', () {
    test('createMenu 落五列并按（日期,开饭时间）排序在内存缓存里', () async {
      final dinner =
          await store.createMenu(day: '2026-09-18', meal: '晚餐', serveAt: '18:30');
      final breakfast =
          await store.createMenu(day: '2026-09-17', meal: '早餐', serveAt: '07:30');

      expect(store.menus.map((m) => m.id).toList(), [breakfast.id, dinner.id],
          reason: '按日期序，不是插入序');
      expect(store.menus.first.serveAt, '07:30');

      final row =
          await one('SELECT * FROM menu WHERE id = ?', [drift.Variable(dinner.id)]);
      expect(row['deleted_at'], isNull);
      expect('${row['updated_by']}'.isNotEmpty, isTrue);
      expect('${row['updated_at']}'.split('-').length, 3,
          reason: 'updated_at 是 HLC 编码（毫秒-计数-节点），不是裸时间戳');
    });

    test('updateMenu 改字段并 rev+1 重新盖章节点', () async {
      final m = await store.createMenu(day: '2026-09-17', meal: '午餐', serveAt: '12:00');
      await store.updateMenu(m.id, meal: '下午茶', note: '朋友来');
      final after = store.menus.firstWhere((x) => x.id == m.id);
      expect(after.meal, '下午茶');
      expect(after.note, '朋友来');
      final row = await one('SELECT rev FROM menu WHERE id = ?', [drift.Variable(m.id)]);
      expect(row['rev'], 2);
    });

    test('addDish 幂等：同一道菜重复加入只留一条', () async {
      final m = await store.createMenu(day: '2026-09-17', meal: '晚餐');
      final r = await makeRecipe('番茄炒蛋', const []);
      await store.addDish(m.id, r.id);
      await store.addDish(m.id, r.id);
      expect(store.menus.single.recipeIds, [r.id]);
      final c = await one('SELECT COUNT(*) AS c FROM menu_item');
      expect(c['c'], 1);
    });

    test('removeDish 打墓碑，列表干净但库里留痕', () async {
      final m = await store.createMenu(day: '2026-09-17', meal: '晚餐');
      final a = await makeRecipe('菜A', const []);
      final b = await makeRecipe('菜B', const []);
      await store.addDish(m.id, a.id);
      await store.addDish(m.id, b.id);
      await store.removeDish(m.id, a.id);
      expect(store.menus.single.recipeIds, [b.id]);
      final tomb = await one(
        'SELECT deleted_at FROM menu_item WHERE recipe_id = ?',
        [drift.Variable(a.id)],
      );
      expect(tomb['deleted_at'], isNotNull);
    });

    test('deleteMenu 连坐：菜单和它所有 menu_item 一起软删', () async {
      final m = await store.createMenu(day: '2026-09-17', meal: '晚餐');
      final r = await makeRecipe('蚝油生菜', const []);
      await store.addDish(m.id, r.id);
      await store.deleteMenu(m.id);
      expect(store.menus, isEmpty);
      final c = await one(
        'SELECT COUNT(*) AS c FROM menu_item WHERE deleted_at IS NULL');
      expect(c['c'], 0);
    });

    test('★ 重启（reload）后菜单与菜品顺序原样回来', () async {
      final m =
          await store.createMenu(day: '2026-09-17', meal: '晚餐', serveAt: '18:30');
      final a = await makeRecipe('菜A', const []);
      final b = await makeRecipe('菜B', const []);
      await store.addDish(m.id, a.id);
      await store.addDish(m.id, b.id);
      await store.reload();
      expect(store.menus.single.recipeIds, [a.id, b.id]);
    });
  });

  group('一键备菜合并（派生视图，不落库）', () {
    test('★ 200 g + 0.3 kg = 500 g，来源点名到菜', () async {
      final a = await makeRecipe('番茄炒蛋', const [
        IngredientDraft(name: '番茄', qty: '200 g'),
      ]);
      final b = await makeRecipe('番茄牛腩', const [
        IngredientDraft(name: '番茄', qty: '0.3 kg'),
      ]);
      final lines = store.mergeForPrep([a.id, b.id]);
      final tomato = lines.firstWhere((l) => l.name == '番茄');
      expect(tomato.qtyText, '500 g');
      expect(tomato.from, ['番茄炒蛋', '番茄牛腩']);
      expect(tomato.isMerged, isTrue);
    });

    test('「适量」不参与累加、只保留一次', () async {
      final a = await makeRecipe('菜A', const [
        IngredientDraft(name: '盐', qty: '适量'),
      ]);
      final b = await makeRecipe('菜B', const [
        IngredientDraft(name: '盐', qty: '少许'),
      ]);
      final salt =
          store.mergeForPrep([a.id, b.id]).singleWhere((l) => l.name == '盐');
      expect(salt.qtyText, contains('适量'));
      expect(salt.qtyText, contains('少许'));
      expect(salt.qtyText.split(RegExp(r'\+')).length, lessThanOrEqualTo(2),
          reason: '模糊量各留一次即可，不做数量乘法、也不并成一句');
    });

    test('别名归一：番茄/西红柿 合到一条（词表 = 全库食材名）', () async {
      final a = await makeRecipe('菜A', const [
        IngredientDraft(name: '番茄', qty: '2 个'),
      ]);
      final b = await makeRecipe('菜B', const [
        IngredientDraft(name: '西红柿', qty: '1 个'),
      ]);
      final lines = store.mergeForPrep([a.id, b.id]);
      final tomatoLines = lines.where((l) => l.from.length == 2).toList();
      expect(tomatoLines, hasLength(1),
          reason: '两道菜并进同一条时只应有一条合并行（别名归一生效）');
      expect(tomatoLines.single.qtyText, '3 个');
    });

    test('不存在的菜 id 静默跳过，不炸清单', () async {
      final a = await makeRecipe(
          '菜A', const [IngredientDraft(name: '油', qty: '10 ml')]);
      final lines = store.mergeForPrep([a.id, 'ghost']);
      expect(lines.map((l) => l.name), ['油']);
    });
  });

  group('备菜板（本机偏好，永不外发）', () {
    test('勾选/排除/手动项都活过 reload', () async {
      final m = await store.createMenu(day: '2026-09-17', meal: '晚餐');
      await store.addPrepExtra(m.id, '嫩豆腐', '2 块');
      await store.setPrepDone(m.id, '嫩豆腐', true);
      await store.setPrepExcluded(m.id, '番茄', true);

      await store.reload();
      final board = store.prepBoardOf(m.id);
      expect(board.extra['嫩豆腐'], '2 块');
      expect(board.done, contains('嫩豆腐'));
      expect(board.excluded, contains('番茄'));
    });

    test('取消勾选/取消排除/删手动项', () async {
      final m = await store.createMenu(day: '2026-09-17', meal: '晚餐');
      await store.addPrepExtra(m.id, '葱', '1 把');
      await store.setPrepDone(m.id, '葱', true);
      await store.setPrepDone(m.id, '葱', false);
      await store.setPrepExcluded(m.id, '姜', true);
      await store.setPrepExcluded(m.id, '姜', false);
      await store.removePrepExtra(m.id, '葱');
      final board = store.prepBoardOf(m.id);
      expect(board.extra, isEmpty);
      expect(board.done, isNot(contains('葱')));
      expect(board.excluded, isNot(contains('姜')));
    });

    test('★ 备菜板只写 local_pref：同步表里一个字节都不许有', () async {
      final m = await store.createMenu(day: '2026-09-17', meal: '晚餐');
      await store.addPrepExtra(m.id, '蒜', '3 瓣');
      final c = await one(
          "SELECT COUNT(*) AS c FROM menu_item WHERE menu_id LIKE 'prep_%'");
      expect(c['c'], 0);
      final raw = await one(
        'SELECT pref_value FROM local_pref WHERE pref_key = ?',
        [drift.Variable('prep_board_${m.id}')],
      );
      expect(
          jsonDecode('${raw['pref_value']}')['extra']['蒜'], '3 瓣');
    });

    test('坏 JSON 的备菜板按空板处理，不挡启动', () async {
      final m = await store.createMenu(day: '2026-09-17', meal: '晚餐');
      await store.dbOrNull!.customInsert(
        'INSERT INTO local_pref (pref_key, pref_value) VALUES (?, ?) '
        'ON CONFLICT(pref_key) DO UPDATE SET pref_value = excluded.pref_value',
        variables: [drift.Variable('prep_board_${m.id}'), drift.Variable('{坏的')],
      );
      await store.reload();
      expect(store.prepBoardOf(m.id).extra, isEmpty);
    });
  });
}
