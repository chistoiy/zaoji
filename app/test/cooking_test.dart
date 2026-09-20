import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/models.dart';

/// 做菜模式数据层（R20）。
///
/// 设计立场：**一次做菜 = 一台设备的一条 cook_session 行**（schema 原意，
/// 表注释就写着"被叫走再回来接不上"）。
/// - 进行中 = `finished_at IS NULL`，`current_step` 随翻页更新；
/// - 续做只查**自己设备**的未完成会话（updated_by == 本机 nodeId）——
///   老婆在平板上做到第 4 步，不该在手机弹出「继续做菜」；
/// - 完成时写 finished_at + recipe 的 cooked_count/last_cooked_at，
///   记录是业务行、随同步走，FR-REC-13 的「历次」因此跨设备可见。
void main() {
  late RecipeStore store;
  late Recipe recipe;
  int localWrites = 0;

  setUp(() async {
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
    store.nodeIdGetter = () async => 'nodeA';
    store.onLocalWrite = () => localWrites++;
    recipe = await store.createRecipe(
      RecipeDraft(
        name: '番茄炒蛋',
        ingredients: [IngredientDraft(name: '番茄', qty: '2 个')],
        steps: const ['打蛋', '炒番茄', '合炒', '装盘'],
      ),
    );
    localWrites = 0; // createRecipe 自身触发过一次，基线清零
  });

  tearDown(() async {
    final db = store.dbOrNull;
    if (db != null) await db.close();
    store.dispose();
  });

  Future<({String by, String? finished, int step, int rev})> rowOf(
      String sessionId) async {
    final r = await store.dbOrNull!.customSelect(
      'SELECT updated_by, finished_at, current_step, rev FROM cook_session WHERE id = ?',
      variables: [Variable(sessionId)],
    ).get();
    final d = r.single.data;
    return (
      by: '${d['updated_by']}',
      finished: d['finished_at'] as String?,
      step: d['current_step'] as int,
      rev: d['rev'] as int,
    );
  }

  group('开始与进度', () {
    test('startCooking 建未完成会话：五列齐全、step=0、盖本机章', () async {
      final id = await store.startCooking(recipe.id);
      final row = await rowOf(id);
      expect(row.finished, isNull);
      expect(row.step, 0);
      expect(row.rev, 1);
      expect(row.by, 'nodeA');
      expect(localWrites, 1, reason: '本地写入必须触发防抖同步回调');
    });

    test('saveCookingStep 推进 current_step 并 rev+1（HLC 重新盖章）', () async {
      final id = await store.startCooking(recipe.id);
      final before = await rowOf(id);
      await store.saveCookingStep(id, 2);
      final after = await rowOf(id);
      expect(after.step, 2);
      expect(after.rev, before.rev + 1);
    });

    test('★ 续做只认自己的未完成会话；别的设备的不算', () async {
      // 模拟另一台设备同步过来的进行中会话（updated_by 不是本机）
      await store.dbOrNull!.customInsert(
        'INSERT INTO cook_session (id, updated_at, updated_by, rev, deleted_at, '
        "recipe_id, started_at, finished_at, current_step) "
        "VALUES ('other-1', 'h-1', 'nodeB', 1, NULL, ?, '2026-09-20T10:00:00', NULL, 3)",
        variables: [Variable(recipe.id)],
      );
      expect(await store.activeCookingSession(recipe.id), isNull,
          reason: '老婆在平板上做到第 3 步，手机不该弹「继续做菜」');

      final mine = await store.startCooking(recipe.id);
      final active = await store.activeCookingSession(recipe.id);
      expect(active?.id, mine, reason: '自己的未完成会话必须被找到');
    });

    test('activeCookingSession 取自己最新一条（重复开火不串档）', () async {
      final first = await store.startCooking(recipe.id);
      await store.saveCookingStep(first, 1);
      final second = await store.startCooking(recipe.id);
      final active = await store.activeCookingSession(recipe.id);
      expect(active?.id, second);
    });
  });

  group('完成与放弃', () {
    test('★ finishCooking：会话封口 + cooked_count+1 + last_cooked_at，内存态同步更新',
        () async {
      final id = await store.startCooking(recipe.id);
      await store.saveCookingStep(id, 3);
      localWrites = 0;

      await store.finishCooking(id);

      final row = await rowOf(id);
      expect(row.finished, isNotNull);
      expect(localWrites, 1, reason: '完成 = 一次本地写入（会话 + recipe 同事务，一次广播）');

      final r = store.recipeById(recipe.id)!;
      expect(r.cookedCount, 1);
      expect(r.lastCooked.length, greaterThanOrEqualTo(10),
          reason: 'last_cooked_at 写 ISO 时间，列表「做过 N 次 · 09/20」靠它');
    });

    test('完成后再查 activeCookingSession 为空（下次开火是全新会话）', () async {
      final id = await store.startCooking(recipe.id);
      await store.finishCooking(id);
      expect(await store.activeCookingSession(recipe.id), isNull);
    });

    test('discardCooking 软删除会话（中途彻底放弃，不留僵尸行）', () async {
      final id = await store.startCooking(recipe.id);
      await store.discardCooking(id);
      expect(await store.activeCookingSession(recipe.id), isNull);
      final r = await store.dbOrNull!.customSelect(
        'SELECT deleted_at FROM cook_session WHERE id = ?',
        variables: [Variable(id)],
      ).get();
      expect(r.single.data['deleted_at'], isNotNull);
    });

    test('finishCooking 后实际耗时可算（FR-COOK-15：started→finished）', () async {
      final id = await store.startCooking(recipe.id);
      // 真做菜以分钟计；测试里同毫秒完成会让 ISO 时间戳相等（Windows 时钟粒度
      // 可到 16ms），垫 20ms 让「finished 晚于 started」成为稳定事实。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await store.finishCooking(id);
      final sessions = await store.cookSessions(recipe.id);
      final s = sessions.firstWhere((x) => x.id == id);
      expect(s.finishedAt!.isAfter(s.startedAt), isTrue);
    });
  });

  group('历次记录（FR-REC-13）', () {
    test('cookSessions 只回已完成的、含别的设备的、按完成时间倒序', () async {
      final a = await store.startCooking(recipe.id);
      await store.finishCooking(a);
      await store.dbOrNull!.customInsert(
        'INSERT INTO cook_session (id, updated_at, updated_by, rev, deleted_at, '
        "recipe_id, started_at, finished_at, current_step) "
        "VALUES ('other-2', 'h-2', 'nodeB', 1, NULL, ?, "
        "'2026-09-19T10:00:00', '2026-09-19T10:40:00', 3)",
        variables: [Variable(recipe.id)],
      );
      final b = await store.startCooking(recipe.id); // 进行中，不该出现

      final list = await store.cookSessions(recipe.id);
      expect(list.map((s) => s.id), containsAll(<String>[a, 'other-2']));
      expect(list.map((s) => s.id), isNot(contains(b)));
      expect(list.first.id, a, reason: '本机刚完成的排最前（finished 倒序）');
      expect(list.first.mine, isTrue);
      expect(list.last.mine, isFalse);
    });
  });
}
