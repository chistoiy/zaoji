/// R14 写路径验证：新建/编辑/删除/恢复的五列规范 + HLC 盖章 + 事务原子性。
///
/// 这批测试是 R14 的核心护栏——UI 可以偷懒、可以改版，但写路径的
/// 数据正确性（ULID / HLC / 墓碑 / 事务）绝不能出问题，否则同步
/// 引擎就会推错数据到别的设备。
library;

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';

drift.QueryExecutor _memExecutor() => NativeDatabase.memory();

void main() {
  group('R14 写路径：新建菜谱', () {
    late RecipeStore store;

    setUp(() async {
      store = RecipeStore(executor: _memExecutor());
      store.nodeIdGetter = () async => 'test-node';
      await store.init();
    });

    test('新建后内存态追加 + 索引可见', () async {
      final before = store.recipes.length;

      await store.createRecipe(
        const RecipeDraft(
          name: '测试新菜',
          sub: '五列规范验证',
          difficulty: 2,
          selfTime: 15,
          servings: 3,
          notes: '备注',
          ingredients: [
            IngredientDraft(name: '番茄', qty: '2 个', isMain: true),
            IngredientDraft(name: '鸡蛋', qty: '3 个'),
          ],
          steps: ['番茄切块', '鸡蛋打散', '热锅下油'],
        ),
      );

      expect(store.recipes.length, before + 1);
      final r = store.recipes.last;
      expect(r.name, '测试新菜');
      expect(r.ingredients.length, 2);
      expect(r.steps.length, 3);
      expect(store.recipeById(r.id), same(r));
    });

    test(
      '新建行五列完整：id(ULID)/updated_at(HLC)/updated_by/rev/deleted_at',
      () async {
        await store.createRecipe(
          const RecipeDraft(
            name: '五列检测',
            ingredients: [IngredientDraft(name: 'x', qty: '1')],
            steps: ['一步'],
          ),
        );

        final db = store.dbForTest!;
        final recipeRows = await db
            .customSelect(
              'SELECT * FROM recipe WHERE name = ?',
              variables: [drift.Variable('五列检测')],
            )
            .get();
        expect(recipeRows, hasLength(1));
        final row = recipeRows.first.data;

        // id 是有效的 ULID（26 字符 Crockford base32）
        final id = '${row['id']}';
        expect(id.length, 26);
        expect(
          RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$').hasMatch(id),
          isTrue,
          reason: 'id 必须是有效 ULID',
        );

        // updated_at 是有效 HLC（格式：hex-ms-13 + hex-counter-4 + - + nodeId）
        final hlc = '${row['updated_at']}';
        expect(
          RegExp(r'^[0-9a-f]{13}-[0-9a-f]{4}-[0-9A-Za-z_-]+$').hasMatch(hlc),
          isTrue,
          reason: 'updated_at 必须是有效 HLC',
        );

        expect(row['updated_by'], 'test-node');
        expect(row['rev'], 1);
        expect(row['deleted_at'], isNull);

        // 同事务：ingredient + step 也有五列
        final ingRows = await db
            .customSelect(
              'SELECT * FROM ingredient WHERE recipe_id = ?',
              variables: [drift.Variable(id)],
            )
            .get();
        expect(ingRows, hasLength(1));
        expect(ingRows.first.data['updated_by'], 'test-node');
        expect(ingRows.first.data['rev'], 1);
        expect(ingRows.first.data['deleted_at'], isNull);

        final stepRows = await db
            .customSelect(
              'SELECT * FROM step WHERE recipe_id = ?',
              variables: [drift.Variable(id)],
            )
            .get();
        expect(stepRows, hasLength(1));
        expect(stepRows.first.data['updated_by'], 'test-node');
        expect(stepRows.first.data['rev'], 1);
        expect(stepRows.first.data['deleted_at'], isNull);
      },
    );

    test('onLocalWrite 回调被调用', () async {
      var called = 0;
      store.onLocalWrite = () => called++;

      await store.createRecipe(const RecipeDraft(name: '回调测试'));

      expect(called, 1);
    });
  });

  group('R14 写路径：编辑菜谱', () {
    late RecipeStore store;
    late String recipeId;

    setUp(() async {
      store = RecipeStore(executor: _memExecutor());
      store.nodeIdGetter = () async => 'test-node';
      await store.init();

      final created = await store.createRecipe(
        const RecipeDraft(
          name: '原名',
          ingredients: [IngredientDraft(name: 'A', qty: '1')],
          steps: ['旧步骤'],
        ),
      );
      recipeId = created.id;
    });

    test('编辑后 recipe 行 rev+1 + updated_at 变新章', () async {
      final db = store.dbForTest!;
      final before =
          (await db
                  .customSelect(
                    'SELECT rev, updated_at FROM recipe WHERE id = ?',
                    variables: [drift.Variable(recipeId)],
                  )
                  .get())
              .first
              .data;

      await store.updateRecipe(
        recipeId,
        const RecipeDraft(
          name: '新名',
          ingredients: [IngredientDraft(name: 'A', qty: '1')],
          steps: ['旧步骤'],
        ),
      );

      final after =
          (await db
                  .customSelect(
                    'SELECT rev, updated_at FROM recipe WHERE id = ?',
                    variables: [drift.Variable(recipeId)],
                  )
                  .get())
              .first
              .data;

      expect(after['rev'], (before['rev'] as int) + 1);
      expect(
        '${after['updated_at']}'.compareTo('${before['updated_at']}') > 0,
        isTrue,
        reason: 'updated_at 字典序必须递增',
      );
    });

    test('编辑时旧 ingredient/step 被打墓碑（deleted_at 非空）', () async {
      final db = store.dbForTest!;

      await store.updateRecipe(
        recipeId,
        const RecipeDraft(
          name: '新名',
          ingredients: [IngredientDraft(name: 'B', qty: '2')],
          steps: ['新步骤'],
        ),
      );

      // 旧 ingredient：deleted_at 非空
      final deadIngs = await db
          .customSelect(
            'SELECT * FROM ingredient WHERE recipe_id = ? AND deleted_at IS NOT NULL',
            variables: [drift.Variable(recipeId)],
          )
          .get();
      expect(deadIngs, isNotEmpty, reason: '旧 ingredient 必须被打墓碑');
      for (final row in deadIngs) {
        expect(row.data['name'], 'A');
        expect(row.data['rev'], greaterThanOrEqualTo(2));
      }

      // 新 ingredient：deleted_at 为空
      final liveIngs = await db
          .customSelect(
            'SELECT * FROM ingredient WHERE recipe_id = ? AND deleted_at IS NULL',
            variables: [drift.Variable(recipeId)],
          )
          .get();
      expect(liveIngs, hasLength(1));
      expect(liveIngs.first.data['name'], 'B');
      expect(liveIngs.first.data['rev'], 1);
    });

    test('编辑后内存态刷新，recipeById 仍可见', () async {
      await store.updateRecipe(
        recipeId,
        const RecipeDraft(
          name: '改名后',
          ingredients: [IngredientDraft(name: '新食材', qty: '一份')],
          steps: ['新步骤'],
        ),
      );

      final r = store.recipeById(recipeId);
      expect(r, isNotNull);
      expect(r!.name, '改名后');
      expect(r.ingredients.single.name, '新食材');
    });

    test('编辑不存在的 id 返回 null', () async {
      final result = await store.updateRecipe(
        'nonexistent-id',
        const RecipeDraft(name: '随便'),
      );
      expect(result, isNull);
    });
  });

  group('R14 写路径：软删除 + 恢复', () {
    late RecipeStore store;
    late String recipeId;

    setUp(() async {
      store = RecipeStore(executor: _memExecutor());
      store.nodeIdGetter = () async => 'test-node';
      await store.init();

      final created = await store.createRecipe(
        const RecipeDraft(
          name: '要删的菜',
          ingredients: [IngredientDraft(name: 'X', qty: '1')],
          steps: ['步骤'],
        ),
      );
      recipeId = created.id;
    });

    test('软删除：recipe + ingredient + step 同事务打墓碑', () async {
      final db = store.dbForTest!;
      final beforeCount = store.recipes.length;

      await store.softDeleteRecipe(recipeId);

      // 内存态移除
      expect(store.recipes.length, beforeCount - 1);
      expect(store.recipeById(recipeId), isNull);

      // 库里 deleted_at 非空
      final recipeRow =
          (await db
                  .customSelect(
                    'SELECT deleted_at, updated_by FROM recipe WHERE id = ?',
                    variables: [drift.Variable(recipeId)],
                  )
                  .get())
              .first
              .data;
      expect(recipeRow['deleted_at'], isNotNull);
      expect(recipeRow['updated_by'], 'test-node');

      final ingRows = await db
          .customSelect(
            'SELECT * FROM ingredient WHERE recipe_id = ? AND deleted_at IS NOT NULL',
            variables: [drift.Variable(recipeId)],
          )
          .get();
      expect(ingRows, isNotEmpty);

      final stepRows = await db
          .customSelect(
            'SELECT * FROM step WHERE recipe_id = ? AND deleted_at IS NOT NULL',
            variables: [drift.Variable(recipeId)],
          )
          .get();
      expect(stepRows, isNotEmpty);
    });

    test('删除不存在的 id 返回 false', () async {
      final result = await store.softDeleteRecipe('nope');
      expect(result, isFalse);
    });

    test('恢复：清墓碑 + 内存态重新可见', () async {
      await store.softDeleteRecipe(recipeId);
      expect(store.recipeById(recipeId), isNull);

      final ok = await store.restoreRecipe(recipeId);
      expect(ok, isTrue);

      final r = store.recipeById(recipeId);
      expect(r, isNotNull);
      expect(r!.name, '要删的菜');

      final db = store.dbForTest!;
      final recipeRow =
          (await db
                  .customSelect(
                    'SELECT deleted_at FROM recipe WHERE id = ?',
                    variables: [drift.Variable(recipeId)],
                  )
                  .get())
              .first
              .data;
      expect(recipeRow['deleted_at'], isNull);
    });

    test('listDeleted 列出回收站菜谱', () async {
      await store.softDeleteRecipe(recipeId);

      final deleted = await store.listDeleted();
      expect(deleted, isNotEmpty);
      expect(deleted.any((r) => r.id == recipeId), isTrue);

      // 恢复后回收站应该没了
      await store.restoreRecipe(recipeId);
      final stillDeleted = await store.listDeleted();
      expect(stillDeleted.any((r) => r.id == recipeId), isFalse);
    });
  });

  group('R14 写路径：nodeIdGetter 回退', () {
    test('没有 nodeIdGetter 时用 "local" 作为回退值', () async {
      final store = RecipeStore(executor: _memExecutor());
      // 不设置 nodeIdGetter
      await store.init();

      final created = await store.createRecipe(const RecipeDraft(name: '回退测试'));

      final db = store.dbForTest!;
      final row =
          (await db
                  .customSelect(
                    'SELECT updated_by FROM recipe WHERE id = ?',
                    variables: [drift.Variable(created.id)],
                  )
                  .get())
              .first
              .data;
      expect(row['updated_by'], 'local');
    });
  });

  group('R16 封面引用（cover_sha256）', () {
    late RecipeStore store;

    setUp(() async {
      store = RecipeStore(executor: _memExecutor());
      store.nodeIdGetter = () async => 'test-node';
      await store.init();
    });

    test('新建带封面 → 落库 + 模型可见', () async {
      final sha = 'a' * 64;
      await store.createRecipe(RecipeDraft(name: '有封面的菜', coverSha256: sha));

      final r = store.recipes.last;
      expect(r.coverSha256, sha);

      final db = store.dbForTest!;
      final row =
          (await db
                  .customSelect(
                    'SELECT cover_sha256 FROM recipe WHERE id = ?',
                    variables: [drift.Variable(r.id)],
                  )
                  .get())
              .first
              .data;
      expect(row['cover_sha256'], sha);
    });

    test('编辑可更换封面引用，模型与库一致', () async {
      await store.createRecipe(
        RecipeDraft(name: '换封面的菜', coverSha256: 'a' * 64),
      );
      final created = store.recipes.last;

      await store.updateRecipe(
        created.id,
        RecipeDraft(name: '换封面的菜', coverSha256: 'b' * 64),
      );

      final updated = store.recipeById(created.id);
      expect(updated!.coverSha256, 'b' * 64);
    });

    test('编辑不传封面 → 引用清空（移除封面的落库语义）', () async {
      await store.createRecipe(
        RecipeDraft(name: '要移除封面的菜', coverSha256: 'c' * 64),
      );
      final created = store.recipes.last;

      await store.updateRecipe(created.id, const RecipeDraft(name: '要移除封面的菜'));

      expect(store.recipeById(created.id)!.coverSha256, isNull);
    });
  });
}
