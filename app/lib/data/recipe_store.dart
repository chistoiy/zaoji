import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'art_registry.dart';
import 'seed.dart';
import 'sync/conflict_box.dart';
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
    await _loadMenus(db);
    await _loadPrepBoards(db);
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
      coverSha256: row['cover_sha256'] as String?,
    );
  }

  Recipe? recipeById(String id) => _byId[id];

  // ───────────────────────── 冲突箱（R22） ─────────────────────────

  /// 未裁决的冲突，按 (表, 行) 分组。
  ///
  /// 数据是同步引擎拉回来的普通业务行（conflict_item 在白名单里），
  /// 这里只负责分组与「这行属于哪道菜」的翻译——墓碑行找不到菜名时退化成 id 片段。
  Future<List<ConflictGroup>> conflictGroups() async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db
        .customSelect(
          'SELECT * FROM conflict_item WHERE resolved_at IS NULL '
          'ORDER BY tbl, row_id, field',
        )
        .get();

    final groups = <String, ConflictGroup>{};
    final order = <String>[];
    for (final r in rows) {
      final d = r.data;
      final tbl = '${d['tbl']}';
      final rowId = '${d['row_id']}';
      final key = '$tbl/$rowId';
      if (!order.contains(key)) {
        order.add(key);
        groups[key] = ConflictGroup(
          tbl: tbl,
          rowId: rowId,
          title: await _conflictTitle(tbl, rowId),
          fields: const [],
        );
      }
      // ConflictGroup 是不可变的，边收边拼要可变列表——先攒 map 再定稿。
      final g = groups[key]!;
      groups[key] = ConflictGroup(
        tbl: tbl,
        rowId: rowId,
        title: g.title,
        fields: [
          ...g.fields,
          ConflictField(
            id: '${d['id']}',
            field: '${d['field']}',
            localValue: d['local_value'],
            remoteValue: d['remote_value'],
            localBy: '${d['local_by'] ?? ''}',
            remoteBy: '${d['remote_by'] ?? ''}',
            localHlc: '${d['local_hlc'] ?? ''}',
            remoteHlc: '${d['remote_hlc'] ?? ''}',
          ),
        ],
      );
    }
    return [for (final k in order) groups[k]!];
  }

  Future<int> openConflictCount() async =>
      (await conflictGroups()).length;

  Future<String> _conflictTitle(String tbl, String rowId) async {
    final recipe = recipeById(rowId);
    if (recipe != null) return recipe.name;
    final db = _db!;
    // 子表行：顺着 recipe_id 找到它属于的菜。找不到也别报错——
    // 冲突恰恰可能发生在「一端删了菜」的场景里。
    final parentTable = const {'step', 'ingredient', 'nutrition'};
    if (parentTable.contains(tbl)) {
      final rows = await db
          .customSelect(
            'SELECT recipe_id FROM $tbl WHERE id = ?',
            variables: [Variable(rowId)],
          )
          .get();
      if (rows.isNotEmpty) {
        final owner = recipeById('${rows.first.data['recipe_id']}');
        if (owner != null) return owner.name;
      }
    }
    return rowId.length > 8 ? '记录 ${rowId.substring(0, 8)}…' : '记录 $rowId';
  }

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
    // R23：同步引擎拉回的可能就是别人排的菜单——menus/备菜板跟着一起重载。
    await _loadMenus(db);
    await _loadPrepBoards(db);
    _reindex();
    notifyListeners();
    return out;
  }

  // ── 本机偏好（local_pref 表）──

  /// 收藏在本机偏好表里的键。值是 JSON 字符串数组。
  static const _favKey = 'fav_recipe_ids';

  /// 单调 ULID 工厂：同毫秒创建的行**字典序必须递增**——
  /// 「取自己最新一条」这类 `ORDER BY ... , id DESC` 的定序全靠它。
  /// 之前用 `_ulids.next()`（纯随机后缀），同毫秒谁新谁旧是掷硬币，
  /// cooking_test 的 flake（R22 抓到，3 连跑红 1 次）就是这个。
  static final UlidFactory _ulids = UlidFactory();

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

      final recipeId = _ulids.next();
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
        'cover_sha256': draft.coverSha256,
      });

      for (var i = 0; i < draft.ingredients.length; i++) {
        final ing = draft.ingredients[i];
        await _insert(db, kIngredientTable, {
          'id': '$recipeId-i${_ulids.next()}',
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
          'id': '$recipeId-s${_ulids.next()}',
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
        coverSha256: draft.coverSha256,
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
        'self_time = ?, servings = ?, notes = ?, tags = ?, cover_sha256 = ?, '
        'updated_at = ?, updated_by = ?, rev = rev + 1 WHERE id = ? AND deleted_at IS NULL',
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
          Variable(draft.coverSha256),
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
          'id': '$recipeId-i${_ulids.next()}',
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
          'id': '$recipeId-s${_ulids.next()}',
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

  // ─────────────── R20 做菜模式 ───────────────
  //
  // 一次做菜 = 一台设备的一条 cook_session 行（schema 的原意：
  // 「被叫走再回来」的进度就该在会话行里）。
  // - 进行中 = finished_at IS NULL；续做**只认自己设备的**未完成会话
  //   （updated_by == 本机 nodeId）——老婆在平板上做到第 4 步，
  //   不该在手机上弹出「继续做菜」；
  // - 完成 = 写 finished_at + recipe 的 cooked_count/last_cooked_at，
  //   同事务、一次广播。记录是业务行、随同步走，FR-REC-13 的「历次」跨设备可见。

  /// 开火：建一条未完成会话，返回会话 id。
  Future<String> startCooking(String recipeId) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final now = DateTime.now();
    final id = _ulids.next();
    await _insert(db, kCookSessionTable, {
      'id': id,
      'updated_at': Hlc.now(nodeId, wallMs: now.millisecondsSinceEpoch).encode(),
      'updated_by': nodeId,
      'rev': 1,
      'deleted_at': null,
      'recipe_id': recipeId,
      'started_at': now.toIso8601String(),
      'finished_at': null,
      'current_step': 0,
      'servings_used': null,
      'state': null,
    });
    _fireLocalWrite();
    return id;
  }

  /// 翻页：推进当前步骤（state 可顺带存勾选等本机进度）。
  Future<void> saveCookingStep(String sessionId, int step,
      {String? state}) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.customUpdate(
      'UPDATE cook_session SET current_step = ?, '
      'state = COALESCE(?, state), updated_at = ?, updated_by = ?, rev = rev + 1 '
      'WHERE id = ? AND deleted_at IS NULL',
      variables: [
        Variable(step),
        Variable<String>(state),
        Variable(Hlc.now(nodeId, wallMs: now).encode()),
        Variable(nodeId),
        Variable(sessionId),
      ],
    );
    _fireLocalWrite();
  }

  /// 本机进行中的会话（取最新一条）。没有则 null。
  Future<CookSession?> activeCookingSession(String recipeId) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final rows = await db.customSelect(
      'SELECT * FROM cook_session WHERE recipe_id = ? AND updated_by = ? '
      'AND finished_at IS NULL AND deleted_at IS NULL '
      // id 兜底：同一毫秒开两次火时 started_at 相同，ULID 字典序 == 创建序
      'ORDER BY started_at DESC, id DESC LIMIT 1',
      variables: [Variable(recipeId), Variable(nodeId)],
    ).get();
    if (rows.isEmpty) return null;
    return _sessionFromRow(rows.first.data, nodeId);
  }

  /// 完成：会话封口 + 计数与时间戳，同事务一次广播。
  Future<void> finishCooking(String sessionId) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final now = DateTime.now();

    final List<Recipe> freshRecipes = await db.transaction<List<Recipe>>(() async {
      final rows = await db.customSelect(
        'SELECT recipe_id FROM cook_session WHERE id = ? AND deleted_at IS NULL',
        variables: [Variable(sessionId)],
      ).get();
      final recipeId = '${rows.single.data['recipe_id']}';
      final hlc = Hlc.now(nodeId, wallMs: now.millisecondsSinceEpoch).encode();

      await db.customUpdate(
        'UPDATE cook_session SET finished_at = ?, '
        'updated_at = ?, updated_by = ?, rev = rev + 1 WHERE id = ?',
        variables: [
          Variable(now.toIso8601String()),
          Variable(hlc),
          Variable(nodeId),
          Variable(sessionId),
        ],
      );
      await db.customUpdate(
        'UPDATE recipe SET cooked_count = cooked_count + 1, last_cooked_at = ?, '
        'updated_at = ?, updated_by = ?, rev = rev + 1 '
        'WHERE id = ? AND deleted_at IS NULL',
        variables: [
          Variable(now.toIso8601String()),
          Variable(hlc),
          Variable(nodeId),
          Variable(recipeId),
        ],
      );
      return _loadAll(db);
    });

    // ★ 先提交、后广播（同 createRecipe 尾注）
    recipes = freshRecipes;
    _reindex();
    notifyListeners();
    _fireLocalWrite();
  }

  /// 彻底放弃这次做菜：软删除会话，不留僵尸行。
  Future<void> discardCooking(String sessionId) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final hlc = Hlc.now(nodeId).tick(nodeId).encode();
    await db.customUpdate(
      'UPDATE cook_session SET deleted_at = ?, updated_at = ?, updated_by = ?, '
      'rev = rev + 1 WHERE id = ? AND deleted_at IS NULL',
      variables: [Variable(hlc), Variable(hlc), Variable(nodeId), Variable(sessionId)],
    );
    _fireLocalWrite();
  }

  /// 历次已完成的做菜（含别的设备的），完成时间倒序——详情页「做过 N 次」。
  Future<List<CookSession>> cookSessions(String recipeId) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final rows = await db.customSelect(
      'SELECT * FROM cook_session WHERE recipe_id = ? AND finished_at IS NOT NULL '
      'AND deleted_at IS NULL ORDER BY finished_at DESC',
      variables: [Variable(recipeId)],
    ).get();
    return [for (final r in rows) _sessionFromRow(r.data, nodeId)];
  }

  CookSession _sessionFromRow(Map<String, Object?> d, String nodeId) =>
      CookSession(
        id: '${d['id']}',
        recipeId: '${d['recipe_id']}',
        startedAt:
            DateTime.tryParse('${d['started_at']}') ?? DateTime.fromMillisecondsSinceEpoch(0),
        finishedAt: d['finished_at'] == null
            ? null
            : DateTime.tryParse('${d['finished_at']}'),
        currentStep: (d['current_step'] as int?) ?? 0,
        state: d['state'] as String?,
        mine: '${d['updated_by']}' == nodeId,
      );

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

  // ═══════════════════ R23 · 菜单 + 一键备菜 ═══════════════════
  //
  // menu / menu_item 是业务表：五列 + HLC + 「先提交后广播」，和菜谱同款，
  // 同步引擎零新增代码把它们带上天。备菜清单**不落库**——它是几道菜的
  // 食材合并出来的纯派生视图（shared 的 mergeIngredients），落库只会造出
  // 第二份真相。唯一落的是「备菜板」：勾选/排除/手动项，进 local_pref
  // （本机偏好，永不外发）——谁买菜谁勾，不该顶掉别人屏幕上的勾。

  /// 菜单内存态，按（日期, 开饭时间）序。随 [reload] 一起刷新。
  List<MenuPlan> menus = const [];

  /// menuId → 备菜板。启动时整批载入（家庭量级最多几十行）。
  final Map<String, PrepBoard> _prepBoards = {};

  static const _prepKeyPrefix = 'prep_board_';

  Future<void> _loadMenus(ZaojiDb db) async {
    final rows = await db.customSelect(
      'SELECT * FROM menu WHERE deleted_at IS NULL '
      'ORDER BY day, COALESCE(serve_at, \'24:00\'), id',
    ).get();
    final itemRows = await db.customSelect(
      'SELECT menu_id, recipe_id FROM menu_item WHERE deleted_at IS NULL '
      'ORDER BY sort, id',
    ).get();
    final dishesByMenu = <String, List<String>>{};
    for (final r in itemRows) {
      dishesByMenu
          .putIfAbsent('${r.data['menu_id']}', () => [])
          .add('${r.data['recipe_id']}');
    }
    menus = [
      for (final row in rows)
        MenuPlan(
          id: '${row.data['id']}',
          day: '${row.data['day']}',
          meal: '${row.data['meal']}',
          serveAt: '${row.data['serve_at'] ?? ''}',
          note: '${row.data['note'] ?? ''}',
          recipeIds: dishesByMenu['${row.data['id']}'] ?? const [],
        ),
    ];
  }

  Future<void> _loadPrepBoards(ZaojiDb db) async {
    _prepBoards.clear();
    final rows = await db.customSelect(
      'SELECT pref_key, pref_value FROM local_pref '
      'WHERE pref_key LIKE ?',
      variables: [Variable('$_prepKeyPrefix%')],
    ).get();
    for (final r in rows) {
      final id = '${r.data['pref_key']}'.substring(_prepKeyPrefix.length);
      _prepBoards[id] = PrepBoard.parse('${r.data['pref_value']}');
    }
  }

  MenuPlan? menuById(String id) {
    for (final m in menus) {
      if (m.id == id) return m;
    }
    return null;
  }

  Future<MenuPlan> createMenu({
    required String day,
    required String meal,
    String serveAt = '',
    String note = '',
  }) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final now = DateTime.now();
    var hlc = Hlc.now(nodeId, wallMs: now.millisecondsSinceEpoch);
    String next() =>
        (hlc = hlc.tick(nodeId, wallMs: now.millisecondsSinceEpoch)).encode();

    final id = _ulids.next();
    await _insert(db, kMenuTable, {
      'id': id,
      'updated_at': next(),
      'updated_by': nodeId,
      'rev': 1,
      'deleted_at': null,
      'day': day,
      'meal': meal,
      'serve_at': serveAt.trim().isEmpty ? null : serveAt.trim(),
      'note': note,
    });
    await _loadMenus(db);
    notifyListeners();
    _fireLocalWrite();
    return menuById(id)!;
  }

  Future<void> updateMenu(
    String id, {
    String? day,
    String? meal,
    String? serveAt,
    String? note,
  }) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final hlc = Hlc.now(nodeId).tick(nodeId).encode();

    final sets = <String>[];
    final vals = <Object?>[];
    if (day != null) {
      sets.add('day = ?');
      vals.add(day);
    }
    if (meal != null) {
      sets.add('meal = ?');
      vals.add(meal);
    }
    if (serveAt != null) {
      sets.add('serve_at = ?');
      vals.add(serveAt.trim().isEmpty ? null : serveAt.trim());
    }
    if (note != null) {
      sets.add('note = ?');
      vals.add(note);
    }
    if (sets.isEmpty) return;
    sets.add('updated_at = ?');
    vals.add(hlc);
    sets.add('updated_by = ?');
    vals.add(nodeId);
    sets.add('rev = rev + 1');
    vals.add(id);
    await db.customStatement(
      'UPDATE menu SET ${sets.join(', ')} '
      'WHERE id = ? AND deleted_at IS NULL',
      vals,
    );
    await _loadMenus(db);
    notifyListeners();
    _fireLocalWrite();
  }

  /// 加入菜品。**幂等**：同一道菜重复加入只留一条——「加入菜单」按钮
  /// 连点两下是常态，不该长出两个菜单行。
  Future<void> addDish(String menuId, String recipeId) async {
    final db = _db!;
    final existing = await db.customSelect(
      'SELECT id FROM menu_item WHERE menu_id = ? AND recipe_id = ? '
      'AND deleted_at IS NULL',
      variables: [Variable(menuId), Variable(recipeId)],
    ).get();
    if (existing.isNotEmpty) return;

    final nodeId = await _resolveNodeId();
    final now = DateTime.now();
    var hlc = Hlc.now(nodeId, wallMs: now.millisecondsSinceEpoch);
    String next() =>
        (hlc = hlc.tick(nodeId, wallMs: now.millisecondsSinceEpoch)).encode();

    final sortRow = await db.customSelect(
      'SELECT COALESCE(MAX(sort) + 1, 0) AS s FROM menu_item '
      'WHERE menu_id = ? AND deleted_at IS NULL',
      variables: [Variable(menuId)],
    ).getSingle();

    await _insert(db, kMenuItemTable, {
      'id': '$menuId-m${_ulids.next()}',
      'updated_at': next(),
      'updated_by': nodeId,
      'rev': 1,
      'deleted_at': null,
      'menu_id': menuId,
      'recipe_id': recipeId,
      'sort': sortRow.data['s'] as int,
    });
    await _loadMenus(db);
    notifyListeners();
    _fireLocalWrite();
  }

  Future<void> removeDish(String menuId, String recipeId) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final hlc = Hlc.now(nodeId).tick(nodeId).encode();
    await db.customUpdate(
      'UPDATE menu_item SET deleted_at = ?, updated_at = ?, updated_by = ?, '
      'rev = rev + 1 WHERE menu_id = ? AND recipe_id = ? AND deleted_at IS NULL',
      variables: [
        Variable(hlc),
        Variable(hlc),
        Variable(nodeId),
        Variable(menuId),
        Variable(recipeId),
      ],
    );
    await _loadMenus(db);
    notifyListeners();
    _fireLocalWrite();
  }

  /// 软删菜单，**连坐**它的菜品行——只埋头不留身子，别的设备会拉到
  /// 一个"还在但点不开"的菜单。
  Future<void> deleteMenu(String id) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final now = DateTime.now();
    var hlc = Hlc.now(nodeId, wallMs: now.millisecondsSinceEpoch);
    String next() =>
        (hlc = hlc.tick(nodeId, wallMs: now.millisecondsSinceEpoch)).encode();

    await db.transaction(() async {
      final h = next();
      await db.customUpdate(
        'UPDATE menu SET deleted_at = ?, updated_at = ?, updated_by = ?, rev = rev + 1 '
        'WHERE id = ? AND deleted_at IS NULL',
        variables: [Variable(h), Variable(h), Variable(nodeId), Variable(id)],
      );
      final h2 = next();
      await db.customUpdate(
        'UPDATE menu_item SET deleted_at = ?, updated_at = ?, updated_by = ?, rev = rev + 1 '
        'WHERE menu_id = ? AND deleted_at IS NULL',
        variables: [Variable(h2), Variable(h2), Variable(nodeId), Variable(id)],
      );
    });

    await _loadMenus(db);
    notifyListeners();
    _fireLocalWrite();
  }

  /// ★ 一键备菜的合并视图（R23）。
  ///
  /// 词表 = **全库食材名**（含种子），别名 = 内置同义词表（`kDefaultAliases`）。
  /// 合并是纯派生计算，不落库——落库只会造出第二份真相。
  List<MergedLine> mergeForPrep(List<String> recipeIds) {
    final batches = <List<IngredientRef>>[];
    final names = <String>[];
    for (final id in recipeIds) {
      final r = _byId[id];
      if (r == null) continue; // 菜被删了就静默跳过——清单不该为一行坏数据炸掉
      batches.add([
        for (final i in r.ingredients)
          IngredientRef(name: i.name, qty: i.qty, isMain: i.isMain),
      ]);
      names.add(r.name);
    }
    final known = {
      for (final r in recipes)
        for (final i in r.ingredients) i.name,
    };
    final resolver =
        PantryAliasResolver(known, explicit: kDefaultAliases);
    return mergeIngredients(batches,
        sourceNames: names, resolver: resolver.resolve);
  }

  /// 某菜单的备菜板（内存态，恒有——没勾过就是空板）。
  PrepBoard prepBoardOf(String menuId) =>
      _prepBoards.putIfAbsent(menuId, PrepBoard.new);

  Future<void> _persistPrepBoard(String menuId) async {
    final db = _db;
    if (db == null) return;
    final cols = kLocalPrefTable.columnNames;
    await db.customInsert(
      'INSERT INTO ${kLocalPrefTable.name} (${cols.join(', ')}) '
      'VALUES (?, ?) ON CONFLICT(${cols[0]}) DO UPDATE SET ${cols[1]} = excluded.${cols[1]}',
      variables: [
        Variable('$_prepKeyPrefix$menuId'),
        Variable(jsonEncode(prepBoardOf(menuId).toJson())),
      ],
    );
  }

  Future<void> setPrepDone(String menuId, String key, bool on) async {
    final b = prepBoardOf(menuId);
    if (on) {
      b.done.add(key);
    } else {
      b.done.remove(key);
    }
    await _persistPrepBoard(menuId);
    notifyListeners();
  }

  Future<void> setPrepExcluded(String menuId, String key, bool on) async {
    final b = prepBoardOf(menuId);
    if (on) {
      b.excluded.add(key);
    } else {
      b.excluded.remove(key);
    }
    await _persistPrepBoard(menuId);
    notifyListeners();
  }

  Future<void> addPrepExtra(String menuId, String name, String qty) async {
    final t = name.trim();
    if (t.isEmpty) return;
    prepBoardOf(menuId).extra[t] = qty.trim();
    await _persistPrepBoard(menuId);
    notifyListeners();
  }

  Future<void> removePrepExtra(String menuId, String name) async {
    prepBoardOf(menuId).extra.remove(name);
    await _persistPrepBoard(menuId);
    notifyListeners();
  }

  // ═══════════════════ R24 · 日历（做过什么 / 排了什么） ═══════════════════
  //
  // cook_session 的 started_at / finished_at 是 ISO8601 **业务时间戳**
  // （R20 定样——HLC 只当同步元数据用），所以日历折算日期直接截串，
  // 不需要也不应该去解 HLC。跨设备的记录都算：日历是全家的账本。

  /// 某一月的点标记：哪几天做过菜 / 排了菜单，以及本月开火总场次。
  Future<MonthMarks> monthMarks(int year, int month) async {
    final db = _db;
    if (db == null) return const MonthMarks.empty();
    final prefix = '${year.toString().padLeft(4, '0')}-'
        '${month.toString().padLeft(2, '0')}';
    final cookRows = await db.customSelect(
      "SELECT finished_at FROM cook_session WHERE finished_at LIKE ? "
      "AND deleted_at IS NULL",
      variables: [Variable<String>('$prefix%')],
    ).get();
    final menuRows = await db.customSelect(
      'SELECT day FROM menu WHERE day LIKE ? AND deleted_at IS NULL',
      variables: [Variable<String>('$prefix%')],
    ).get();
    return MonthMarks(
      cookDays: {for (final r in cookRows) '${r.data['finished_at']}'.substring(0, 10)},
      menuDays: {for (final r in menuRows) '${r.data['day']}'},
      cookCount: cookRows.length,
    );
  }

  /// 某一天的做菜记录（按完成时刻升序还原那天的顺序）。
  Future<List<CookEvent>> cookEventsOn(String day) async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db.customSelect(
      'SELECT recipe_id, started_at, finished_at FROM cook_session '
      'WHERE finished_at LIKE ? AND deleted_at IS NULL ORDER BY finished_at',
      variables: [Variable<String>('$day%')],
    ).get();
    return [
      for (final r in rows)
        CookEvent(
          recipeId: '${r.data['recipe_id']}',
          recipeName:
              _byId['${r.data['recipe_id']}']?.name ?? '（已删除的菜）',
          time: '${r.data['finished_at']}'.substring(11, 16),
          minutes: _minutesBetween(
              '${r.data['started_at']}', '${r.data['finished_at']}'),
        ),
    ];
  }

  static int _minutesBetween(String startedIso, String finishedIso) {
    final s = DateTime.tryParse(startedIso);
    final f = DateTime.tryParse(finishedIso);
    if (s == null || f == null) return 0;
    final m = f.difference(s).inMinutes;
    return m < 0 ? 0 : m;
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

  /// 封面照片的内容哈希。null = 无封面（编辑时也传现有值以保持不变）。
  final String? coverSha256;

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
    this.coverSha256,
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
    String? coverSha256,
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
      coverSha256: coverSha256 ?? this.coverSha256,
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
final TableSpec kCookSessionTable = kTables.firstWhere(
    (t) => t.name == 'cook_session');
final TableSpec kIngredientTable = kTables.firstWhere(
  (t) => t.name == 'ingredient',
);
final TableSpec kStepTable = kTables.firstWhere((t) => t.name == 'step');
final TableSpec kLocalPrefTable = kTables.firstWhere(
  (t) => t.name == 'local_pref',
);
final TableSpec kMenuTable = kTables.firstWhere((t) => t.name == 'menu');
final TableSpec kMenuItemTable =
    kTables.firstWhere((t) => t.name == 'menu_item');

/// R23 · 内置同义词表（备菜归一用）。
///
/// 值必须是**库里可能出现的写法**；同义词是产品知识不是算法，
/// 宁少勿错——合并错一道菜的用量，用户会买错东西（见 shared 加工形态黑名单）。
const Map<String, String> kDefaultAliases = {
  '西红柿': '番茄',
  '马铃薯': '土豆',
  '洋芋': '土豆',
  '包菜': '卷心菜',
  '圆白菜': '卷心菜',
};

/// 一顿饭的安排（menu 行的内存态）。
class MenuPlan {
  final String id;

  /// YYYY-MM-DD。列名刻意不叫 date（schema 注：省得跟类型名混淆）。
  final String day;
  final String meal;

  /// HH:MM，''= 没定开饭时间。
  final String serveAt;
  final String note;

  /// 这一餐的菜（按 sort 序，只含未删的）。
  final List<String> recipeIds;

  const MenuPlan({
    required this.id,
    required this.day,
    required this.meal,
    this.serveAt = '',
    this.note = '',
    this.recipeIds = const [],
  });
}

/// 某菜单的备菜板：勾选/排除/手动项。
///
/// **本机偏好，不同步**（local_pref 一行 JSON）——和 R20 做菜进度同一立场：
/// 谁买菜谁勾，另一台设备不该被这些勾顶掉屏幕。
class PrepBoard {
  final Set<String> done = {};
  final Set<String> excluded = {};

  /// 手动项：名称 → 分量文本。
  final Map<String, String> extra = {};

  PrepBoard();

  Map<String, Object?> toJson() => {
        'done': done.toList(),
        'excluded': excluded.toList(),
        'extra': extra,
      };

  /// 坏 JSON 按空板处理——偏好存坏了不能挡启动（与收藏同一立场）。
  static PrepBoard parse(String raw) {    final b = PrepBoard();
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return b;
      final d = j['done'];
      if (d is List) b.done.addAll(d.map((e) => '$e'));
      final x = j['excluded'];
      if (x is List) b.excluded.addAll(x.map((e) => '$e'));
      final e = j['extra'];
      if (e is Map) {
        for (final entry in e.entries) {
          b.extra['${entry.key}'] = '${entry.value}';
        }
      }
    } catch (_) {}
    return b;
  }
}

/// 某月的日历点标记（R24）。
class MonthMarks {
  /// 有做菜完成的日期集合（YYYY-MM-DD）。
  final Set<String> cookDays;

  /// 有菜单安排的日期集合。
  final Set<String> menuDays;

  /// 本月开火场次（按会话计数，一天做两道算两次）。
  final int cookCount;

  const MonthMarks({
    required this.cookDays,
    required this.menuDays,
    required this.cookCount,
  });

  const MonthMarks.empty()
      : cookDays = const {},
        menuDays = const {},
        cookCount = 0;
}

/// 日历里的一条做菜记录（R24）。
class CookEvent {
  final String recipeId;
  final String recipeName;

  /// HH:MM，完成时刻。
  final String time;

  /// 开始→完成的分钟数；解析不出来是 0。
  final int minutes;

  const CookEvent({
    required this.recipeId,
    required this.recipeName,
    required this.time,
    required this.minutes,
  });
}
