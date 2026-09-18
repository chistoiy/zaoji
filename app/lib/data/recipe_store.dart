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

  @override
  void dispose() {
    _db?.close();
    super.dispose();
  }
}

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
