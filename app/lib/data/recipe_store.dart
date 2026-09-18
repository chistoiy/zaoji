import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'art_registry.dart';
import 'seed.dart';
import 'zaoji_db.dart';
import '../models.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// 客户端数据仓库：本地库的读写 + 内存态（收藏这类本机偏好）。
///
/// **实例通过 `StoreScope` 注入组件树**（见 store_scope.dart 的注释：
/// 全局单例 + widget 测试 = zone 陷阱）。生产路径在 `ZaojiApp` 里
/// `RecipeStore(executor: null)` → 按平台打开真实库。
///
/// ## 现在为什么还是「全量载入内存」
///
/// 9 道菜的家庭菜谱，全量读进内存毫无压力；列表页、详情页、深链都从
/// [recipes] 取，简单且不会有一致性问题。等数据量真的上来（几百道 + 图片），
/// 再把列表页改成 Drift 的流式查询——那时候改的是这一层，页面不动。
///
/// ## 收藏为什么不在业务表里，但必须落库
///
/// 收藏是**本机偏好**（原型 `S.fav`，不同步）：schema 的 recipe 表没有也不该有
/// 这一列——它是偏好不是业务数据。但「内存态」在 R12 之前是个真 bug：
/// 重启后用户取消过的种子收藏会**被重新灌回来**，最典型的信任破坏。
///
/// 现在收藏落在 `local_pref`（shared schema 里的本机偏好键值表，永不外发）：
/// 首次启动以种子标记为初始值，之后完全以用户操作为准。悬浮按钮位置、
/// 排序档这些偏好将来也走这张表。
///
/// ## 写路径（R14 新增）
///
/// 用户写入走五列规范 + HLC 盖章 + 同事务：
/// ```
/// recipe + ingredient(×N) + step(×N) → 一个事务
///   每行盖 Hlc.now(nodeId).tick(nodeId) 的章
///   新行 INSERT / 改行 UPDATE rev+1 / 删除打墓碑(UPDATE deleted_at)
/// ```
///
/// 写完调 [onLocalWrite] 让 App 层排防抖同步（Store 不直接持有 SyncEngine，
/// 避免循环依赖）。
class RecipeStore extends ChangeNotifier {
  RecipeStore({QueryExecutor? executor}) : _executorOverride = executor;

  /// 测试注入。生产路径为 null → [ZaojiDb.open] 按平台选实现。
  final QueryExecutor? _executorOverride;

  ZaojiDb? _db;
  Future<void>? _ready;
  bool get isReady => _ready != null;

  List<Recipe> recipes = const [];

  /// id → Recipe 索引。`recipeById` 原来是线性扫描，深链每次进入全表扫一遍；
  /// 现在建表后 O(1)。随 [recipes] 一起在 [_reindex] 里维护。
  final Map<String, Recipe> _byId = {};

  /// 本机收藏（菜谱 id）。首次启动以种子标记为初始值，之后以用户操作为准。
  final Set<String> favs = {};

  // ── R14 写路径需要的外部依赖（回调，避免循环依赖）──

  /// 获取本设备 nodeId（写 HLC 的 `updated_by` 列用）。
  /// 由 `_ZaojiAppState._ensureSync()` 赋值：从 SyncPrefs.nodeId() 取。
  Future<String> Function()? nodeIdGetter;

  /// 本地写入后触发。由 `_ZaojiAppState` 接上「3 秒防抖 sync」。
  /// Store 不直接持有 SyncEngine——引擎依赖 db，store 也持有 db，
  /// 两边互指就是循环依赖。回调是干净的单向通道。
  VoidCallback? onLocalWrite;

  /// 幂等。**先到先得**——第二次调用直接返回第一次的 future。
  Future<void> init() => _ready ??= _doInit(_executorOverride);

  /// 与 [init] 等价，可在 UI 里当 Future 用（FutureBuilder）。
  Future<void> ready() => init();

  Future<void> _doInit(QueryExecutor? executor) async {
    final db = _db = executor != null ? ZaojiDb(executor) : ZaojiDb.open();

    // ★ 检查与灌种必须在同一个事务里。
    //   之前是「先 COUNT、再逐条 INSERT」：灌到一半进程被杀，下次启动
    //   COUNT > 0 → 跳过灌种 → **永久缺菜且不报错**；Web 端双标签共享
    //   同一个 worker 连接时也可能一个标签灌到一半、另一个读到"非空"。
    //   事务保证种子要么全在、要么全不在。
    await db.transaction(() async {
      final count = await db
          .customSelect('SELECT COUNT(*) AS c FROM recipe')
          .getSingle();
      if ((count.data['c'] as int) == 0) {
        await _seed(db);
      }
    });
    recipes = await _loadAll(db);
    await _loadFavs(db);
    _reindex();
    notifyListeners();
  }

  /// 首次启动灌种子。
  ///
  /// **写入也走五列规范**：id / updated_at(HLC) / updated_by / rev / deleted_at。
  /// 这批数据的 updated_by 是 `seed` 节点——同步引擎上线后，
  /// 它们和用户手写的记录在协议层面没有任何区别。
  Future<void> _seed(ZaojiDb db) async {
    var hlc = Hlc.now(kSeedNodeId);
    String nextHlc() => (hlc = hlc.tick(kSeedNodeId)).encode();

    for (final r in kSeedRecipes) {
      await _insert(db, kRecipeTable, {
        'id': r.id,
        'updated_at': nextHlc(),
        'updated_by': kSeedNodeId,
        'rev': 1,
        'deleted_at': null,
        'name': r.name,
        'sub': r.sub,
        'art': artCodeOf(r.art),
        'pal': paletteCodeOf(r.palette),
        'difficulty': r.difficulty,
        'self_time': r.selfTime,
        'cooked_count': r.cookedCount,
        'servings': r.servings,
        'notes': r.notes,
        'tags': jsonEncode(r.tags),
        'source': r.source.name,
        'source_model': r.sourceModel,
        'source_at': null,
        'last_cooked_at': r.lastCooked.isEmpty ? null : r.lastCooked,
        'cover_sha256': null,
      });
      for (var i = 0; i < r.ingredients.length; i++) {
        final ing = r.ingredients[i];
        await _insert(db, kIngredientTable, {
          'id': '${r.id}-i$i',
          'updated_at': nextHlc(),
          'updated_by': kSeedNodeId,
          'rev': 1,
          'deleted_at': null,
          'recipe_id': r.id,
          'sort': i,
          'name': ing.name,
          'qty_text': ing.qty,
          'qty_value': null,
          'qty_unit': null,
          'is_main': ing.isMain ? 1 : 0,
          'alias_key': null,
        });
      }
      for (var i = 0; i < r.steps.length; i++) {
        await _insert(db, kStepTable, {
          'id': '${r.id}-s$i',
          'updated_at': nextHlc(),
          'updated_by': kSeedNodeId,
          'rev': 1,
          'deleted_at': null,
          'recipe_id': r.id,
          'idx': i,
          'text': r.steps[i].text,
          'art': null,
          'image_sha256': null,
        });
      }
    }
  }

  Future<void> _insert(ZaojiDb db, TableSpec table, Map<String, Object?> row) {
    final cols = table.columnNames;
    return db.customInsert(
      'INSERT INTO ${table.name} '
      '(${cols.join(', ')}) VALUES (${List.filled(cols.length, '?').join(', ')})',
      variables: [for (final c in cols) Variable(row[c])],
    );
  }

  Future<List<Recipe>> _loadAll(ZaojiDb db) async {
    final recipeRows = await db
        .customSelect('SELECT * FROM recipe WHERE deleted_at IS NULL')
        .get();
    final ingRows = await db
        .customSelect(
          'SELECT * FROM ingredient WHERE deleted_at IS NULL ORDER BY sort',
        )
        .get();
    final stepRows = await db
        .customSelect(
          'SELECT * FROM step WHERE deleted_at IS NULL ORDER BY idx',
        )
        .get();

    final ingsByRecipe = <String, List<Map<String, Object?>>>{};
    for (final row in ingRows) {
      ingsByRecipe
          .putIfAbsent('${row.data['recipe_id']}', () => [])
          .add(row.data);
    }
    final stepsByRecipe = <String, List<Map<String, Object?>>>{};
    for (final row in stepRows) {
      stepsByRecipe
          .putIfAbsent('${row.data['recipe_id']}', () => [])
          .add(row.data);
    }

    final out = <Recipe>[];
    for (final row in recipeRows) {
      final id = '${row.data['id']}';
      out.add(
        _recipeFromRow(
          row.data,
          ingsByRecipe[id] ?? const [],
          stepsByRecipe[id] ?? const [],
        ),
      );
    }
    return out;
  }

  Recipe _recipeFromRow(
    Map<String, Object?> row,
    List<Map<String, Object?>> ingredientRows,
    List<Map<String, Object?>> stepRows,
  ) {
    final tagsRaw = row['tags'] as String?;
    final tags = <String, List<String>>{};
    if (tagsRaw != null && tagsRaw.isNotEmpty) {
      final decoded = jsonDecode(tagsRaw) as Map<String, Object?>;
      for (final e in decoded.entries) {
        tags[e.key] = (e.value as List).cast<String>();
      }
    }

    return Recipe(
      id: '${row['id']}',
      name: '${row['name']}',
      sub: '${row['sub'] ?? ''}',
      difficulty: (row['difficulty'] as int?) ?? 1,
      selfTime: (row['self_time'] as int?) ?? 0,
      servings: (row['servings'] as int?) ?? 2,
      notes: '${row['notes'] ?? ''}',
      source:
          RecipeSource.values.asNameMap()['${row['source'] ?? 'manual'}'] ??
          RecipeSource.manual,
      sourceModel: row['source_model'] as String?,
      cookedCount: (row['cooked_count'] as int?) ?? 0,
      lastCooked: '${row['last_cooked_at'] ?? ''}',
      isFav: false, // 库里没有这列；收藏是本机偏好，见 [favs]
      art: dishArtOfCode(row['art'] as int?),
      palette: paletteOfCode(row['pal'] as int?),
      tags: tags,
      ingredients: [
        for (final r in ingredientRows)
          Ingredient(
            '${r['name']}',
            '${r['qty_text'] ?? ''}',
            isMain: (r['is_main'] as int? ?? 0) == 1,
          ),
      ],
      steps: [for (final r in stepRows) Step('${r['text']}')],
    );
  }

  Recipe? recipeById(String id) => _byId[id];

  void _reindex() {
    _byId
      ..clear()
      ..addEntries(recipes.map((r) => MapEntry(r.id, r)));
  }

  /// ★ 测试专用：直接访问底层库（验证 DDL 建表、五列规范、软删除语义）。
  /// 页面代码不要碰它——页面只读 [recipes] / [favs]。
  ZaojiDb? get dbForTest => _db;

  /// 底层库。给同步引擎用（同一连接：引擎写完调 [reload]，内存缓存跟着刷新）。
  /// init 未完成时为 null。
  ZaojiDb? get dbOrNull => _db;

  /// 从库里重新加载全部菜谱到内存缓存。同步引擎拉到新数据后调用。
  /// 页面经 ListenableBuilder 消费 store，刷新自动可见。
  Future<void> reload() => reloadForTest();

  /// ★ 测试专用：绕过内存缓存重新从库里读一遍。
  Future<List<Recipe>> reloadForTest() async {
    final db = _db!;
    final out = await _loadAll(db);
    recipes = out;
    _reindex();
    notifyListeners();
    return out;
  }

  // ── 本机偏好（local_pref 表）──

  /// 收藏在本机偏好表里的键。值是 JSON 字符串数组。
  static const _favKey = 'fav_recipe_ids';

  Future<void> _loadFavs(ZaojiDb db) async {
    final rows = await db
        .customSelect(
          'SELECT pref_value FROM ${kLocalPrefTable.name} '
          'WHERE ${kLocalPrefTable.columnNames[0]} = ?',
          variables: [Variable(_favKey)],
        )
        .get();
    if (rows.isEmpty) {
      // 首次启动：以种子里标记的收藏为初始值，并立即落库——
      // 从此用户「取消收藏」才真正生效，重启不会被灌回来。
      favs.addAll(kSeedRecipes.where((r) => r.isFav).map((r) => r.id));
      await _persistFavs(db);
      return;
    }
    try {
      final decoded = jsonDecode('${rows.first.data['pref_value']}');
      if (decoded is List) favs.addAll(decoded.map((e) => '$e'));
    } catch (_) {
      // 偏好存坏了就当没有收藏，别让 App 打不开——
      // 损失几个收藏可接受，启动失败不可接受。
    }
  }

  Future<void> _persistFavs(ZaojiDb db) {
    final cols = kLocalPrefTable.columnNames;
    return db.customInsert(
      'INSERT INTO ${kLocalPrefTable.name} (${cols.join(', ')}) '
      'VALUES (?, ?) ON CONFLICT(${cols[0]}) DO UPDATE SET ${cols[1]} = excluded.${cols[1]}',
      variables: [Variable(_favKey), Variable(jsonEncode(favs.toList()))],
    );
  }

  /// 收藏切换：内存态立即可见，落库异步进行。
  ///
  /// 落库失败不打断 UI（丢一个收藏可接受），但留下日志线索——
  /// 静默失败的东西连查都没法查。
  void toggleFav(String id) {
    if (!favs.remove(id)) favs.add(id);
    notifyListeners();
    final db = _db;
    if (db == null) return;
    unawaited(
      _persistFavs(
        db,
      ).then((_) {}, onError: (Object e) => debugPrint('收藏写库失败：$e')),
    );
  }

  bool isFav(String id) => favs.contains(id);

  // ─────────────── R14 写路径 ───────────────
  //
  // 所有写入走五列规范 + HLC 盖章 + 同事务。
  // ingredient/step 的旧行用「全量墓碑」策略（把该 recipe 下所有旧行
  // 打墓碑，然后新列表原样 INSERT）——比做增量 diff 更简单且安全，
  // 同步引擎看到墓碑就删远端、看到新行就加，端上流量多一点但语义正确。

  /// 新建菜谱。生成新 ULID，recipe + ingredients + steps 同事务落库。
  Future<Recipe> createRecipe(RecipeDraft draft) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final now = DateTime.now();
    final hlc0 = Hlc.now(nodeId, wallMs: now.millisecondsSinceEpoch);

    final Recipe recipe = await db.transaction<Recipe>(() async {
      var hlc = hlc0;
      String next() =>
          (hlc = hlc.tick(nodeId, wallMs: now.millisecondsSinceEpoch)).encode();

      final recipeId = Ulid.generate();
      await _insert(db, kRecipeTable, {
        'id': recipeId,
        'updated_at': next(),
        'updated_by': nodeId,
        'rev': 1,
        'deleted_at': null,
        'name': draft.name,
        'sub': draft.sub,
        'art': artCodeOf(draft.art),
        'pal': paletteCodeOf(draft.palette),
        'difficulty': draft.difficulty,
        'self_time': draft.selfTime,
        'cooked_count': 0,
        'servings': draft.servings,
        'notes': draft.notes,
        'tags': jsonEncode(draft.tags),
        'source': 'manual',
        'source_model': null,
        'source_at': null,
        'last_cooked_at': null,
        'cover_sha256': null,
      });

      for (var i = 0; i < draft.ingredients.length; i++) {
        final ing = draft.ingredients[i];
        await _insert(db, kIngredientTable, {
          'id': '$recipeId-i${Ulid.generate()}',
          'updated_at': next(),
          'updated_by': nodeId,
          'rev': 1,
          'deleted_at': null,
          'recipe_id': recipeId,
          'sort': i,
          'name': ing.name,
          'qty_text': ing.qty,
          'qty_value': null,
          'qty_unit': null,
          'is_main': ing.isMain ? 1 : 0,
          'alias_key': null,
        });
      }

      for (var i = 0; i < draft.steps.length; i++) {
        await _insert(db, kStepTable, {
          'id': '$recipeId-s${Ulid.generate()}',
          'updated_at': next(),
          'updated_by': nodeId,
          'rev': 1,
          'deleted_at': null,
          'recipe_id': recipeId,
          'idx': i,
          'text': draft.steps[i],
          'art': null,
          'image_sha256': null,
        });
      }

      final recipe = Recipe(
        id: recipeId,
        name: draft.name,
        sub: draft.sub,
        difficulty: draft.difficulty,
        selfTime: draft.selfTime,
        servings: draft.servings,
        notes: draft.notes,
        ingredients: draft.ingredients
            .map((i) => Ingredient(i.name, i.qty, isMain: i.isMain))
            .toList(),
        steps: draft.steps.map((t) => Step(t)).toList(),
        source: RecipeSource.manual,
        cookedCount: 0,
        art: draft.art,
        palette: draft.palette,
        tags: draft.tags,
      );

      // 内存态追加 + 索引 + 通知，**放到事务外**（见下方 createRecipe 尾注）
      return recipe;
    });

    // ★ 内存态与通知必须在事务关闭之后。留在事务回调里的话，监听者
    //   （以及 _fireLocalWrite 排下的 3 秒防抖 Timer）会继承 drift 事务的
    //   zone——Timer 3 秒后一发，事务早关了，isPaired 的查询直接
    //   「transaction used after closed」（R15 widget 测试 pump(4s) 实测；
    //   生产上的表象 = 保存后的自动同步永远不触发 + 一个未捕获异常）。
    //   先提交、后广播：监听者看到的永远是已提交的状态。
    recipes = [...recipes, recipe];
    _reindex();
    notifyListeners();
    _fireLocalWrite();
    return recipe;
  }

  /// 编辑菜谱。recipe 行 UPDATE rev+1 + HLC 新章；
  /// 旧 ingredient/step 全打墓碑，新列表原样 INSERT。
  Future<Recipe?> updateRecipe(String recipeId, RecipeDraft draft) async {
    final db = _db!;
    final existing = _byId[recipeId];
    if (existing == null) return null;

    final nodeId = await _resolveNodeId();
    final now = DateTime.now();
    final hlc0 = Hlc.now(nodeId, wallMs: now.millisecondsSinceEpoch);

    final List<Recipe>
    freshRecipes = await db.transaction<List<Recipe>>(() async {
      var hlc = hlc0;
      String next() =>
          (hlc = hlc.tick(nodeId, wallMs: now.millisecondsSinceEpoch)).encode();

      final recipeHlc = next();

      // recipe 行 UPDATE（rev+1）
      await db.customUpdate(
        'UPDATE recipe SET name = ?, sub = ?, art = ?, pal = ?, difficulty = ?, '
        'self_time = ?, servings = ?, notes = ?, tags = ?, updated_at = ?, '
        'updated_by = ?, rev = rev + 1 WHERE id = ? AND deleted_at IS NULL',
        variables: [
          Variable(draft.name),
          Variable(draft.sub),
          Variable(artCodeOf(draft.art)),
          Variable(paletteCodeOf(draft.palette)),
          Variable(draft.difficulty),
          Variable(draft.selfTime),
          Variable(draft.servings),
          Variable(draft.notes),
          Variable(jsonEncode(draft.tags)),
          Variable(recipeHlc),
          Variable(nodeId),
          Variable(recipeId),
        ],
      );

      // 旧 ingredient/step 全打墓碑（同 HLC 章）
      await db.customUpdate(
        'UPDATE ingredient SET deleted_at = ?, updated_at = ?, updated_by = ?, rev = rev + 1 '
        'WHERE recipe_id = ? AND deleted_at IS NULL',
        variables: [
          Variable(recipeHlc),
          Variable(recipeHlc),
          Variable(nodeId),
          Variable(recipeId),
        ],
      );
      await db.customUpdate(
        'UPDATE step SET deleted_at = ?, updated_at = ?, updated_by = ?, rev = rev + 1 '
        'WHERE recipe_id = ? AND deleted_at IS NULL',
        variables: [
          Variable(recipeHlc),
          Variable(recipeHlc),
          Variable(nodeId),
          Variable(recipeId),
        ],
      );

      // 新列表 INSERT
      for (var i = 0; i < draft.ingredients.length; i++) {
        final ing = draft.ingredients[i];
        await _insert(db, kIngredientTable, {
          'id': '$recipeId-i${Ulid.generate()}',
          'updated_at': next(),
          'updated_by': nodeId,
          'rev': 1,
          'deleted_at': null,
          'recipe_id': recipeId,
          'sort': i,
          'name': ing.name,
          'qty_text': ing.qty,
          'qty_value': null,
          'qty_unit': null,
          'is_main': ing.isMain ? 1 : 0,
          'alias_key': null,
        });
      }
      for (var i = 0; i < draft.steps.length; i++) {
        await _insert(db, kStepTable, {
          'id': '$recipeId-s${Ulid.generate()}',
          'updated_at': next(),
          'updated_by': nodeId,
          'rev': 1,
          'deleted_at': null,
          'recipe_id': recipeId,
          'idx': i,
          'text': draft.steps[i],
          'art': null,
          'image_sha256': null,
        });
      }

      // 重新从库里读（包含新 ingredient/step 的完整列表），而不是靠传入 draft 组装——
      // draft 里没有 ULID id，重建的 Recipe 丢了 id 会导致 sync 推送混乱
      return _loadAll(db);
    });

    // ★ 先提交、后广播（同 createRecipe 尾注）：notifyListeners /
    //   _fireLocalWrite 留在事务回调里，监听者与防抖 Timer 会继承事务
    //   zone，3 秒后一发就撞「transaction used after closed」。
    recipes = freshRecipes;
    _reindex();
    notifyListeners();
    _fireLocalWrite();
    return _byId[recipeId];
  }

  /// 软删除菜谱：recipe + 所有 ingredient + step 打墓碑。
  /// 同事务、同 HLC 章——同步引擎会把整组墓碑一起推上去。
  Future<bool> softDeleteRecipe(String recipeId) async {
    final db = _db!;
    final existing = _byId[recipeId];
    if (existing == null) return false;

    final nodeId = await _resolveNodeId();
    final hlc = Hlc.now(nodeId).tick(nodeId);
    final hlcStr = hlc.encode();

    await db.transaction(() async {
      await db.customUpdate(
        'UPDATE recipe SET deleted_at = ?, updated_at = ?, updated_by = ?, rev = rev + 1 '
        'WHERE id = ? AND deleted_at IS NULL',
        variables: [
          Variable(hlcStr),
          Variable(hlcStr),
          Variable(nodeId),
          Variable(recipeId),
        ],
      );
      // 连带删除 ingredient/step——主菜没了，子行单独活着没意义
      await db.customUpdate(
        'UPDATE ingredient SET deleted_at = ?, updated_at = ?, updated_by = ?, rev = rev + 1 '
        'WHERE recipe_id = ? AND deleted_at IS NULL',
        variables: [
          Variable(hlcStr),
          Variable(hlcStr),
          Variable(nodeId),
          Variable(recipeId),
        ],
      );
      await db.customUpdate(
        'UPDATE step SET deleted_at = ?, updated_at = ?, updated_by = ?, rev = rev + 1 '
        'WHERE recipe_id = ? AND deleted_at IS NULL',
        variables: [
          Variable(hlcStr),
          Variable(hlcStr),
          Variable(nodeId),
          Variable(recipeId),
        ],
      );
    });

    // ★ 先提交、后广播（同 createRecipe 尾注）
    recipes = recipes.where((r) => r.id != recipeId).toList();
    _reindex();
    notifyListeners();
    _fireLocalWrite();
    return true;
  }

  /// 从回收站恢复：清掉 deleted_at 墓碑。
  ///
  /// 恢复也走五列规范（新 HLC + rev+1）——因为「恢复」是一次真实写入，
  /// 同步引擎需要看到它。
  Future<bool> restoreRecipe(String recipeId) async {
    final db = _db!;

    final nodeId = await _resolveNodeId();
    final hlc = Hlc.now(nodeId).tick(nodeId);
    final hlcStr = hlc.encode();

    final List<Recipe>
    freshRecipes = await db.transaction<List<Recipe>>(() async {
      await db.customUpdate(
        'UPDATE recipe SET deleted_at = NULL, updated_at = ?, updated_by = ?, rev = rev + 1 '
        'WHERE id = ? AND deleted_at IS NOT NULL',
        variables: [Variable(hlcStr), Variable(nodeId), Variable(recipeId)],
      );
      await db.customUpdate(
        'UPDATE ingredient SET deleted_at = NULL, updated_at = ?, updated_by = ?, rev = rev + 1 '
        'WHERE recipe_id = ? AND deleted_at IS NOT NULL',
        variables: [Variable(hlcStr), Variable(nodeId), Variable(recipeId)],
      );
      await db.customUpdate(
        'UPDATE step SET deleted_at = NULL, updated_at = ?, updated_by = ?, rev = rev + 1 '
        'WHERE recipe_id = ? AND deleted_at IS NOT NULL',
        variables: [Variable(hlcStr), Variable(nodeId), Variable(recipeId)],
      );

      return _loadAll(db);
    });

    // ★ 先提交、后广播（同 createRecipe 尾注）
    recipes = freshRecipes;
    _reindex();
    notifyListeners();
    _fireLocalWrite();
    return _byId[recipeId] != null;
  }

  /// 列出回收站里的菜谱（deleted_at IS NOT NULL）。
  /// 只读操作，不触发同步。
  Future<List<Recipe>> listDeleted() async {
    final db = _db!;
    final rows = await db
        .customSelect(
          'SELECT * FROM recipe WHERE deleted_at IS NOT NULL ORDER BY updated_at DESC',
        )
        .get();
    final ingsByRecipe = <String, List<Map<String, Object?>>>{};
    final ingRows = await db
        .customSelect('SELECT * FROM ingredient WHERE deleted_at IS NOT NULL')
        .get();
    for (final r in ingRows) {
      ingsByRecipe.putIfAbsent('${r.data['recipe_id']}', () => []).add(r.data);
    }
    final stepsByRecipe = <String, List<Map<String, Object?>>>{};
    final stepRows = await db
        .customSelect('SELECT * FROM step WHERE deleted_at IS NOT NULL')
        .get();
    for (final r in stepRows) {
      stepsByRecipe.putIfAbsent('${r.data['recipe_id']}', () => []).add(r.data);
    }
    return [
      for (final row in rows)
        _recipeFromRow(
          row.data,
          ingsByRecipe['${row.data['id']}'] ?? const [],
          stepsByRecipe['${row.data['id']}'] ?? const [],
        ),
    ];
  }

  // ── 内部助手 ──

  Future<String> _resolveNodeId() async {
    final g = nodeIdGetter;
    if (g != null) {
      try {
        return await g();
      } catch (_) {}
    }
    // 回退：没有 nodeIdGetter 时用临时值（测试或 store 独立使用场景）
    return 'local';
  }

  void _fireLocalWrite() {
    try {
      onLocalWrite?.call();
    } catch (_) {
      // 回调抛异常不应该打断 store 写入——数据已落库
    }
  }

  @override
  void dispose() {
    _db?.close();
    super.dispose();
  }
}

/// 菜谱编辑表单的数据对象。Store 的写路径（create / update）都吃这个。
class RecipeDraft {
  final String name;
  final String sub;
  final int difficulty;
  final int selfTime;
  final int servings;
  final String notes;
  final List<IngredientDraft> ingredients;
  final List<String> steps;
  final DishArtKind art;
  final List<String> palette;
  final Map<String, List<String>> tags;

  const RecipeDraft({
    required this.name,
    this.sub = '',
    this.difficulty = 1,
    this.selfTime = 0,
    this.servings = 2,
    this.notes = '',
    this.ingredients = const [],
    this.steps = const [],
    this.art = DishArtKind.plate,
    this.palette = const [],
    this.tags = const {},
  });

  RecipeDraft copyWith({
    String? name,
    String? sub,
    int? difficulty,
    int? selfTime,
    int? servings,
    String? notes,
    List<IngredientDraft>? ingredients,
    List<String>? steps,
    DishArtKind? art,
    List<String>? palette,
    Map<String, List<String>>? tags,
  }) {
    return RecipeDraft(
      name: name ?? this.name,
      sub: sub ?? this.sub,
      difficulty: difficulty ?? this.difficulty,
      selfTime: selfTime ?? this.selfTime,
      servings: servings ?? this.servings,
      notes: notes ?? this.notes,
      ingredients: ingredients ?? this.ingredients,
      steps: steps ?? this.steps,
      art: art ?? this.art,
      palette: palette ?? this.palette,
      tags: tags ?? this.tags,
    );
  }

  /// 从 Recipe 模型反向构造 Draft（编辑页初始化用）。
  factory RecipeDraft.fromRecipe(Recipe r) => RecipeDraft(
    name: r.name,
    sub: r.sub,
    difficulty: r.difficulty,
    selfTime: r.selfTime,
    servings: r.servings,
    notes: r.notes,
    ingredients: r.ingredients
        .map((i) => IngredientDraft(name: i.name, qty: i.qty, isMain: i.isMain))
        .toList(),
    steps: r.steps.map((s) => s.text).toList(),
    art: r.art,
    palette: r.palette,
    tags: r.tags,
  );
}

class IngredientDraft {
  final String name;
  final String qty;
  final bool isMain;

  const IngredientDraft({
    required this.name,
    required this.qty,
    this.isMain = false,
  });
}

// 注：Ulid 已通过 zaoji_shared 导出，无需额外 import

/// 种子数据的节点 id。出现在这批行的 `updated_by` 里，
/// 将来同步引擎的「数据体检」可以据此告诉用户哪些行来自内置演示数据。
const String kSeedNodeId = 'seed';

// ── 表引用（来自 shared 的 schema，客户端不另写列清单）──
final TableSpec kRecipeTable = kTables.firstWhere((t) => t.name == 'recipe');
final TableSpec kIngredientTable = kTables.firstWhere(
  (t) => t.name == 'ingredient',
);
final TableSpec kStepTable = kTables.firstWhere((t) => t.name == 'step');
final TableSpec kLocalPrefTable = kTables.firstWhere(
  (t) => t.name == 'local_pref',
);
