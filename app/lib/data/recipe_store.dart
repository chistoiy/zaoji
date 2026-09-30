import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';

import 'art_registry.dart';
import 'seed.dart';
import 'sync/conflict_box.dart';
import 'zaoji_db.dart';
import '../models.dart';
import '../theme.dart';
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

  /// 回收站里的菜谱（R43）。与 [recipes] 同源：`_loadAll` 统一刷一次，
  /// 就地改内存缓存的那几条快路径（[softDeleteRecipe]）自己补一笔。
  /// 页面读这个字段而不是自己去查库——再让每个页面各自记一遍
  /// "什么时候该重新查"就会有人漏（R40 的旧账）。
  List<Recipe> deletedItems = const [];

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
    await _loadTheme(db); // R39：主题只在启动时读一次（同步重载不该改这台设备的皮肤）
    // ★ R47：本机厨房偏好同样必须在 _doInit 里读，不能只挂在 reload()。
    //   R45 那个洞就是这么来的：冷启动没有增量 → 内存里的偏好全是默认值，
    //   用户昨天关掉的悬浮窗今天又冒出来。
    await _loadKitchenPrefs(db);
    // ★ R47：库存到期提醒的「本机已提醒日」也必须在 _doInit 读——
    //   它是这台设备的作息事实，冷启动后如果回落到空串，用户会一天里被提醒两次。
    await _loadExpiryStamp(db);
    // ★ 同一颗坑第三次：开饭前投待办的「今天已投过的餐次」也要在 _doInit 读。
    //   只挂在 reload() 的话，冷启动后戳是空的 → 同一天回前台一次就多投一次。
    await _loadMealStamps(db);
    await _loadMembers(db);
    await _loadAllergenPrefs(db);
    await _loadMenus(db);
    await _loadPrepBoards(db);
    // ★ R45：这三张表以前**只在 reload() 里被填**，而 reload() 生产路径上只有
    //   同步引擎在「本轮真有增量」时才调一次（sync_engine.dart 末尾那段）。
    //   于是冷启动后如果没有增量可同步，_nutritionByRecipe / pantryItems /
    //   shoppingItems 三张内存表恒空 → 详情页热量卡回落按钮态、列表徽标消失、
    //   厨房页库存与购物清单显示空态，**而 sqlite 与服务端的数据一行都没丢**。
    //   症状当时被报成「AI 白算一次」（R45），实际影响面是三条 UI。
    //   判据见 app/test/cold_start_load_r46_test.dart —— 必须真开第二个 store 实例，
    //   只断言「库里有行」会假绿（这条已反向验证：摘掉下面三行，测试立刻红）。
    await _loadNutrition(db);
    await _loadPantry(db);
    await _loadShopping(db);
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
    // ★ 回收站的列表也在这里一起刷新：所有写路径（新建/编辑/软删/恢复/永久删）
    //   都已经走 _loadAll，再加一处"记得顺便刷新回收站"迟早会漏（R40 的教训）。
    deletedItems = await _queryDeleted(db);
    return out;
  }

  /// JSON 文本数组 → `List<String>`；null/坏值一律回空（读路径不炸页面）。
  static List<String> _jsonShaList(Object? raw) {
    final t = '${raw ?? ''}';
    if (t.isEmpty) return const [];
    try {
      final v = jsonDecode(t);
      if (v is List) return [for (final e in v) if (e is String) e];
    } catch (_) {}
    return const [];
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
      createdAt: '${row['created_at'] ?? ''}', // v7：老行是 NULL → 空串 = 不知道
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
      steps: [
        for (final r in stepRows)
          Step('${r['text']}', images: _jsonShaList(r['images'])),
      ],
      coverSha256: row['cover_sha256'] as String?,
      photos: _jsonShaList(row['photos']),
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
    // R27：热量是菜谱的附属同步数据（FR-AI-51），跟菜谱一起重载。
    await _loadNutrition(db);
    // R28：库存同样随重载刷新（同步引擎拉回别人买的菜）。
    await _loadPantry(db);
    // R30：购物清单随重载刷新（另一台设备加购的缺项要现身）。
    await _loadShopping(db);
    // R40：成员与忌口同样随重载刷新——另一台设备上加的"小宝过敏鸡蛋"要立刻生效。
    await _loadMembers(db);
    // R23：同步引擎拉回的可能就是别人排的菜单——menus/备菜板跟着一起重载。
    await _loadMenus(db);
    await _loadPrepBoards(db);
    _reindex();
    notifyListeners();
    return out;
  }

  // ─────────────── R28 · 库存（pantry_item） ───────────────

  List<PantryItem> pantryItems = const [];

  Future<void> _loadPantry(ZaojiDb db) async {
    final rows = await db
        .customSelect('SELECT * FROM pantry_item WHERE deleted_at IS NULL')
        .get();
    pantryItems = [for (final r in rows) PantryItem.fromRow(r.data)];
  }

  /// 新增/更新一条库存（同名不重复建：**按 name 精确复用现有行**，
  /// 「添加牛奶」点了两次不该变两条——库存是清单不是流水）。
  ///
  /// v7 起带三态与存储位置。[have] 这个入参**故意留着**：调用点一片
  /// `have: true/false` 语义清楚，改成传枚举会让"加减到 0"这类调用读起来更绕。
  /// 两者都给时以 [status] 为准。
  Future<void> upsertPantry({
    String? id,
    required String name,
    String? category,
    double? qtyValue,
    String? qtyUnit,
    bool? have,
    PantryStock? status,
    String? expireAt,
    bool isStaple = false,
    Object? storage = _keep,
    Object? boughtAt = _keep,
    Object? note = _keep,
  }) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final now = DateTime.now();
    var hlc = Hlc.now(nodeId, wallMs: now.millisecondsSinceEpoch);
    String next() => hlc.tick(nodeId, wallMs: now.millisecondsSinceEpoch).encode();

    final existing = id != null
        ? pantryItems.where((p) => p.id == id).firstOrNull
        : pantryItems.where((p) => p.name == name).firstOrNull;

    final nextStatus = status ??
        (have != null
            ? (have ? PantryStock.have : PantryStock.none)
            : (existing?.status ?? PantryStock.have));
    // 「没提到」和「要清空」是两件事：默认值用 [_keep] 哨兵区分开，
    // 否则购物入库那条老调用路径会把用户填过的存储位置/备注顺手抹掉。
    String? keep(Object? v, String? Function() cur) =>
        identical(v, _keep) ? cur() : v as String?;
    final nextStorage =
        keep(storage, () => existing?.storage);
    final nextBought = keep(boughtAt, () => existing?.boughtAt);
    final nextNote = keep(note, () => existing?.note);

    final values = <String, Object?>{
      'name': name,
      'alias_key': PantryMatch.aliasKeyOf(name),
      'category': category,
      'qty_value': qtyValue,
      'qty_unit': qtyUnit,
      // ★ have 与 stock_status **成对写**：旧 apk 只认 have，
      //   不带着它走，那台设备上这条库存会永远停在旧值上。
      'have': nextStatus == PantryStock.none ? 0 : 1,
      'stock_status': nextStatus.code,
      'expire_at': expireAt,
      'is_staple': isStaple ? 1 : 0,
      'storage': nextStorage,
      'bought_at': nextBought,
      'note': nextNote,
    };
    late PantryItem stored;
    await db.transaction(() async {
      if (existing == null) {
        final newId = _ulids.next();
        await _insert(db, kPantryTable, {
          'id': newId,
          'updated_at': next(),
          'updated_by': nodeId,
          'rev': 1,
          'deleted_at': null,
          ...values,
        });
        stored = PantryItem(
            id: newId,
            name: name,
            aliasKey: values['alias_key'] as String?,
            category: category,
            qtyValue: qtyValue,
            qtyUnit: qtyUnit,
            status: nextStatus,
            expireAt: expireAt,
            isStaple: isStaple,
            storage: nextStorage,
            boughtAt: nextBought,
            note: nextNote);
      } else {
        await db.customUpdate(
          'UPDATE pantry_item SET updated_at = ?, updated_by = ?, rev = rev + 1, '
          'name = ?, alias_key = ?, category = ?, qty_value = ?, qty_unit = ?, '
          'have = ?, stock_status = ?, expire_at = ?, is_staple = ?, '
          'storage = ?, bought_at = ?, note = ? WHERE id = ?',
          variables: [
            Variable(next()),
            Variable(nodeId),
            for (final k in [
              'name', 'alias_key', 'category', 'qty_value', 'qty_unit',
              'have', 'stock_status', 'expire_at', 'is_staple',
              'storage', 'bought_at', 'note'
            ])
              Variable(values[k]),
            Variable(existing.id),
          ],
        );
        stored = PantryItem(
            id: existing.id,
            name: name,
            aliasKey: values['alias_key'] as String?,
            category: category,
            qtyValue: qtyValue,
            qtyUnit: qtyUnit,
            status: nextStatus,
            expireAt: expireAt,
            isStaple: isStaple,
            storage: nextStorage,
            boughtAt: nextBought,
            note: nextNote);
      }
    });
    pantryItems = [
      for (final p in pantryItems)
        if (p.id == (existing?.id ?? stored.id)) stored else p,
      if (existing == null) stored,
    ];
    notifyListeners();
    _fireLocalWrite();
  }

  /// 步进器：±1（无数值的模糊库存加一次变成 1，减到 0 翻成「没有」——
  /// 「没有」是库存状态不是删除，回收站那套语义不在这用）。
  ///
  /// 步进器**只碰 have/none 两端，不碰 low**：低是人的判断（看一眼瓶子），
  /// 不是数量算出来的结果——把 low 交给 ± 号会让用户没法解释自己为什么
  /// 昨天标的"快没了"今天又变回"充足"了。
  Future<void> adjustPantry(String id, int delta) async {
    final p = pantryItems.where((x) => x.id == id).firstOrNull;
    if (p == null) return;
    final v = (p.qtyValue ?? 0) + delta;
    await upsertPantry(
        id: id,
        name: p.name,
        category: p.category,
        qtyValue: v <= 0 ? 0 : v.toDouble(),
        qtyUnit: p.qtyUnit,
        status: v <= 0 ? PantryStock.none : PantryStock.have,
        expireAt: p.expireAt,
        isStaple: p.isStaple,
        storage: p.storage,
        boughtAt: p.boughtAt,
        note: p.note);
  }

  /// 删除库存行（软删：这条数据参与同步，别的端要看到它消失）。
  Future<void> deletePantry(String id) async {
    final db = _db!;
    final p = pantryItems.where((x) => x.id == id).firstOrNull;
    if (p == null) return;
    final nodeId = await _resolveNodeId();
    final now = DateTime.now();
    final hlc = Hlc.now(nodeId, wallMs: now.millisecondsSinceEpoch);
    await db.transaction(() async {
      await db.customUpdate(
        'UPDATE pantry_item SET updated_at = ?, updated_by = ?, rev = rev + 1, '
        'deleted_at = ? WHERE id = ?',
        variables: [
          Variable(hlc.tick(nodeId, wallMs: now.millisecondsSinceEpoch).encode()),
          Variable(nodeId),
          Variable(hlc.tick(nodeId, wallMs: now.millisecondsSinceEpoch).encode()),
          Variable(id),
        ],
      );
    });
    pantryItems = pantryItems.where((x) => x.id != id).toList();
    notifyListeners();
    _fireLocalWrite();
  }

  // ─────────────── R30 · 购物清单（shopping_item） ───────────────

  List<ShoppingItem> shoppingItems = const [];

  Future<void> _loadShopping(ZaojiDb db) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM shopping_item WHERE deleted_at IS NULL',
        )
        .get();
    shoppingItems = [for (final r in rows) ShoppingItem.fromRow(r.data)];
  }

  /// 批量加购。**同名（活行）跳过**——清单是集合不是流水（撞名口径同库存）。
  /// 返回真正新增的条数，UI 用它报「加了 N 样」。
  Future<int> addShoppingItems(
      List<({String name, String? qtyText, String? recipeId})> items,
      {String source = 'manual'}) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final now = DateTime.now();
    var hlc = Hlc.now(nodeId, wallMs: now.millisecondsSinceEpoch);
    String next() =>
        hlc.tick(nodeId, wallMs: now.millisecondsSinceEpoch).encode();
    var added = 0;
    final fresh = <ShoppingItem>[];
    await db.transaction(() async {
      for (final it in items) {
        final name = it.name.trim();
        if (name.isEmpty) continue;
        final dup = shoppingItems.any((x) => x.name == name) ||
            fresh.any((x) => x.name == name);
        if (dup) continue;
        final id = _ulids.next();
        await _insert(db, kShoppingTable, {
          'id': id,
          'updated_at': next(),
          'updated_by': nodeId,
          'rev': 1,
          'deleted_at': null,
          'name': name,
          'qty_text': it.qtyText,
          'source': source,
          'recipe_id': it.recipeId,
          'bought': 0,
        });
        fresh.add(ShoppingItem(
            id: id,
            name: name,
            qtyText: it.qtyText,
            source: source,
            recipeId: it.recipeId));
        added++;
      }
    });
    if (fresh.isNotEmpty) {
      shoppingItems = [...shoppingItems, ...fresh];
      notifyListeners();
      _fireLocalWrite();
    }
    return added;
  }

  Future<void> toggleShoppingBought(String id, bool bought) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final now = DateTime.now();
    final hlc = Hlc.now(nodeId, wallMs: now.millisecondsSinceEpoch);
    await db.customUpdate(
      'UPDATE shopping_item SET bought = ?, updated_at = ?, updated_by = ?, '
      'rev = rev + 1 WHERE id = ? AND deleted_at IS NULL',
      variables: [
        Variable(bought ? 1 : 0),
        Variable(hlc.tick(nodeId, wallMs: now.millisecondsSinceEpoch).encode()),
        Variable(nodeId),
        Variable(id),
      ],
    );
    shoppingItems = [
      for (final x in shoppingItems)
        if (x.id == id)
          ShoppingItem(
              id: x.id,
              name: x.name,
              qtyText: x.qtyText,
              source: x.source,
              recipeId: x.recipeId,
              bought: bought)
        else
          x,
    ];
    notifyListeners();
    _fireLocalWrite();
  }

  Future<void> removeShopping(String id) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final now = DateTime.now();
    var hlc = Hlc.now(nodeId, wallMs: now.millisecondsSinceEpoch);
    String next() =>
        hlc.tick(nodeId, wallMs: now.millisecondsSinceEpoch).encode();
    await db.customUpdate(
      'UPDATE shopping_item SET deleted_at = ?, updated_at = ?, updated_by = ?, '
      'rev = rev + 1 WHERE id = ? AND deleted_at IS NULL',
      variables: [Variable(next()), Variable(next()), Variable(nodeId), Variable(id)],
    );
    shoppingItems = shoppingItems.where((x) => x.id != id).toList();
    notifyListeners();
    _fireLocalWrite();
  }

  /// 购物入库（FR-PAN-08）：已勾的条目逐样进库存（同名复用库存原行），
  /// 进完把清单行删掉（软删上墓碑）。返回入库样数。
  Future<int> stockInBoughtShopping() async {
    final bought = shoppingItems.where((x) => x.bought).toList();
    if (bought.isEmpty) return 0;
    for (final b in bought) {
      final q = _parseQty(b.qtyText);
      await upsertPantry(
          name: b.name, qtyValue: q?.$1, qtyUnit: q?.$2, have: true);
      await removeShopping(b.id);
    }
    return bought.length;
  }

  /// 「500g」「2个」→ (500.0, 'g')；「适量」等模糊量 → null（只记有）。
  static (double, String?)? _parseQty(String? text) {
    final t = (text ?? '').trim();
    final m = RegExp(r'^(\d+(?:\.\d+)?)\s*([一-龥a-zA-Z]*)').firstMatch(t);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!);
    if (v == null) return null;
    final unit = m.group(2) ?? '';
    return (v, unit.isEmpty ? null : unit);
  }

  /// 清空冰箱的推荐结果（FR-RECO-01~04 本地匹配部分）。
  /// 派生不落库——和备菜清单同一条立场（R23）。
  Map<String, Object?> recommendByPantry() {
    return PantryMatch.recommend(
      recipes: [
        for (final r in recipes)
          {
            'id': r.id,
            'name': r.name,
            'ingredients': [
              for (final i in r.ingredients)
                {
                  'name': i.name,
                  'qtyText': i.qty,
                  'isMain': i.isMain,
                  'aliasKey': i.aliasKey,
                  // 库存里被标了常备的同名食材，这道菜里也按豁免算
                  'isStaple': pantryItems
                      .any((p) => p.isStaple && (p.name == i.name ||
                          p.aliasKey == (i.aliasKey ?? ''))),
                }
            ],
          }
      ],
      pantry: [
        for (final p in pantryItems)
          {
            'name': p.name,
            'aliasKey': p.aliasKey,
            'have': p.have ? 1 : 0,
            'qtyValue': p.qtyValue,
            'isStaple': p.isStaple,
          }
      ],
    );
  }

  // ─────────────── R27 · 热量（nutrition 表，与菜谱一对一） ───────────────

  final Map<String, Nutrition> _nutritionByRecipe = {};

  /// 这道菜的热量估算；null = 没算过。
  ///
  /// **显示只看有没有数据，不看本机配没配 AI**（FR-REC-23）——
  /// 数据是同步来的普通业务数据，在 Android 上算的，iOS 打开就该看到。
  Nutrition? nutritionFor(String recipeId) => _nutritionByRecipe[recipeId];

  Future<void> _loadNutrition(ZaojiDb db) async {
    _nutritionByRecipe.clear();
    final rows = await db
        .customSelect(
          'SELECT * FROM nutrition WHERE deleted_at IS NULL',
        )
        .get();
    for (final row in rows) {
      final n = Nutrition.fromRow(row.data);
      _nutritionByRecipe[n.recipeId] = n;
    }
  }

  /// 写入/覆盖一道菜的热量（一对一：已有活行则 UPDATE rev+1，否则 INSERT）。
  /// 与 createRecipe 同一条纪律：五列规范 + HLC 盖章 + 事务，
  /// 内存态与防抖通知放在事务提交之后（R15 的 zone 教训）。
  Future<void> saveNutrition(String recipeId, NutritionDraft draft) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final now = DateTime.now();
    final existing = _nutritionByRecipe[recipeId];

    late Nutrition stored;
    await db.transaction(() async {
      var hlc = Hlc.now(nodeId, wallMs: now.millisecondsSinceEpoch);
      String next() => hlc.tick(nodeId, wallMs: now.millisecondsSinceEpoch).encode();
      final values = <String, Object?>{
        'recipe_id': recipeId,
        'per_serving_kcal': draft.perServingKcal,
        'total_kcal': draft.totalKcal,
        'protein_g': draft.proteinG,
        'fat_g': draft.fatG,
        'carb_g': draft.carbG,
        'basis': draft.basisJson,
        'confidence': draft.confidence,
        'source': draft.source,
        'model': draft.model,
        'servings_basis': draft.servingsBasis,
      };
      if (existing == null) {
        final id = _ulids.next();
        await _insert(db, kNutritionTable, {
          'id': id,
          'updated_at': next(),
          'updated_by': nodeId,
          'rev': 1,
          'deleted_at': null,
          ...values,
        });
        stored = Nutrition(
          id: id,
          recipeId: recipeId,
          perServingKcal: draft.perServingKcal,
          totalKcal: draft.totalKcal,
          proteinG: draft.proteinG,
          fatG: draft.fatG,
          carbG: draft.carbG,
          basisJson: draft.basisJson,
          confidence: draft.confidence,
          source: draft.source,
          model: draft.model,
          servingsBasis: draft.servingsBasis,
        );
      } else {
        await db.customUpdate(
          'UPDATE nutrition SET updated_at = ?, updated_by = ?, rev = rev + 1, '
          'per_serving_kcal = ?, total_kcal = ?, protein_g = ?, fat_g = ?, '
          'carb_g = ?, basis = ?, confidence = ?, source = ?, model = ?, '
          'servings_basis = ? WHERE id = ?',
          variables: [
            Variable(next()),
            Variable(nodeId),
            for (final k in [
              'per_serving_kcal', 'total_kcal', 'protein_g', 'fat_g', 'carb_g',
              'basis', 'confidence', 'source', 'model', 'servings_basis'
            ])
              Variable(values[k]),
            Variable(existing.id),
          ],
        );
        stored = Nutrition(
          id: existing.id,
          recipeId: recipeId,
          perServingKcal: draft.perServingKcal,
          totalKcal: draft.totalKcal,
          proteinG: draft.proteinG,
          fatG: draft.fatG,
          carbG: draft.carbG,
          basisJson: draft.basisJson,
          confidence: draft.confidence,
          source: draft.source,
          model: draft.model,
          servingsBasis: draft.servingsBasis,
        );
      }
    });

    _nutritionByRecipe[recipeId] = stored;
    notifyListeners();
    _fireLocalWrite();
  }

  // ── 本机偏好（local_pref 表）──

  /// 收藏在本机偏好表里的键。值是 JSON 字符串数组。
  static const _favKey = 'fav_recipe_ids';

  /// 「这个参数调用方没提」的哨兵——null 是有意义的值（清空），不能拿它当默认。
  static const Object _keep = Object();

  /// ── R39 · 主题 ──────────────────────────────────────────────
  ///
  /// 主题 id 存在 local_pref，**不进同步流**：客厅的平板想亮一点、灶台边的
  /// 手机夜里想暗一点，是两台设备各自的采光问题，互相覆盖只会打架
  /// （同 R23 备菜板、R37 同步策略的立场）。
  static const _themeKey = 'theme';

  /// 当前主题 id。默认那套 = [ZaojiTokens.fallback]，读库前也能安全取。
  String themeId = ZaojiTokens.fallback.id;

  /// R47 · 厨房现场偏好（FR-SET-01/02/03）：开饭前提醒与提前量、悬浮窗、震动/声音。
  /// 与主题同一条立场——**只在启动时读一次**，同步增量不该改这台设备的开关。
  KitchenPrefs kitchenPrefs = const KitchenPrefs();

  /// 提前量（已夹到合法档）。设置页与开饭前的待办投递都读这个。
  int get mealLeadMinutes => kitchenPrefs.leadMinutesClamped;

  /// 页面取色一律走这个（`StoreScope.of(context).tokens` / `context.zj`）。
  ///
  /// 认不出来的 id 落回默认那套而不是崩：这一列是用户可写的偏好，
  /// 手改过、或来自更新版本的旧包，都不该让 App 打不开。
  ZaojiTokens get tokens => ZaojiTokens.all
      .firstWhere((t) => t.id == themeId, orElse: () => ZaojiTokens.fallback);

  Future<void> _loadTheme(ZaojiDb db) async {
    final cols = kLocalPrefTable.columnNames;
    final rows = await db
        .customSelect(
          'SELECT ${cols[1]} FROM ${kLocalPrefTable.name} WHERE ${cols[0]} = ?',
          variables: [Variable(_themeKey)],
        )
        .get();
    if (rows.isEmpty) return;
    themeId = _decodePrefString(rows.first.data[cols[1]]) ?? themeId;
  }

  /// local_pref 的值按约定是 JSON，但历史上也有直接塞裸串的地方——
  /// 两种都认，解不出来返回 null 让调用方保持原值（不猜）。
  static String? _decodePrefString(Object? raw) {
    final s = raw == null ? null : (raw as String).trim();
    if (s == null || s.isEmpty) return null;
    try {
      final d = jsonDecode(s);
      return d is String ? d : null;
    } catch (_) {
      return s;
    }
  }

  /// 换主题：内存态立即生效并通知（UI 一帧内翻新），落库异步。
  ///
  /// 与收藏同款处理：偏好写失败不打断操作——最坏结果是下次启动回到旧值，
  /// 而"点了没反应"是用户当场就能感觉到的。
  void setTheme(String id) {
    if (!ZaojiTokens.all.any((t) => t.id == id)) return;
    if (themeId == id) return;
    themeId = id;
    notifyListeners();
    final db = _db;
    if (db == null) return;
    unawaited(_persistTheme(db).then((_) {},
        onError: (Object e) => debugPrint('主题偏好写库失败：$e')));
  }

  Future<void> _persistTheme(ZaojiDb db) {
    final cols = kLocalPrefTable.columnNames;
    return db.customInsert(
      'INSERT INTO ${kLocalPrefTable.name} (${cols.join(', ')}) '
      'VALUES (?, ?) ON CONFLICT(${cols[0]}) DO UPDATE SET ${cols[1]} = excluded.${cols[1]}',
      variables: [Variable(_themeKey), Variable(jsonEncode(themeId))],
    );
  }

  // ── R47 · 厨房现场偏好（FR-SET-01/02/03）──────────────────────────────
  //
  // 与主题、备菜板同一条立场：**本机偏好、不同步**。
  // 「这台设备的屏幕该不该亮、该不该震」是两台机器各自的采光与音量环境，
  // 客厅平板不该把灶台手机的开关顶掉。

  static const _kitchenPrefsKey = 'kitchen_prefs';

  Future<void> _loadKitchenPrefs(ZaojiDb db) async {
    final cols = kLocalPrefTable.columnNames;
    final rows = await db
        .customSelect(
          'SELECT ${cols[1]} FROM ${kLocalPrefTable.name} WHERE ${cols[0]} = ?',
          variables: [Variable(_kitchenPrefsKey)],
        )
        .get();
    if (rows.isEmpty) return;
    kitchenPrefs = KitchenPrefs.decode(rows.first.data[cols[1]]) ?? kitchenPrefs;
  }

  /// 改厨房偏好：内存态立即生效并通知（开关要有当场反馈），落库异步。
  ///
  /// 写库失败静默——最坏是下次启动回到旧值；而「拨了没反应」是当场就能感觉到的。
  void setKitchenPrefs(KitchenPrefs next) {
    if (next == kitchenPrefs) return;
    kitchenPrefs = next;
    notifyListeners();
    final db = _db;
    if (db == null) return;
    unawaited(_persistKitchenPrefs(db).then((_) {},
        onError: (Object e) => debugPrint('厨房偏好写库失败：$e')));
  }

  /// 只改其中一路的便捷入口（设置页每行一个开关）。
  void updateKitchenPrefs(KitchenPrefs Function(KitchenPrefs) change) =>
      setKitchenPrefs(change(kitchenPrefs));

  Future<void> _persistKitchenPrefs(ZaojiDb db) {
    final cols = kLocalPrefTable.columnNames;
    return db.customInsert(
      'INSERT INTO ${kLocalPrefTable.name} (${cols.join(', ')}) '
      'VALUES (?, ?) ON CONFLICT(${cols[0]}) DO UPDATE SET ${cols[1]} = excluded.${cols[1]}',
      variables: [
        Variable(_kitchenPrefsKey),
        Variable(jsonEncode(kitchenPrefs.toJson())),
      ],
    );
  }

  // ── R47 · 库存到期提醒的本机去重戳（FR-PAN-04）──────────────────
  //
  // 存的是「这台设备上一次为过期/临期发通知是哪天」（YYYY-MM-DD）。
  // 为什么算本机事实：提醒的作息是每根设备自己的（平板在客厅、手机在灶台边），
  // 同步过去只会让一台的打开动作把另一台的提醒机会吃掉——
  // 与主题、悬浮窗、备菜板同一条立场：落 local_pref、不进同步流。
  static const _expiryStampKey = 'pantry_expiry_notified_day';

  /// 已提醒日。空串 = 这台设备还没提醒过（新装、或清过数据）。
  String expiryNotifiedDay = '';

  Future<void> _loadExpiryStamp(ZaojiDb db) async {
    final cols = kLocalPrefTable.columnNames;
    final rows = await db
        .customSelect(
          'SELECT ${cols[1]} FROM ${kLocalPrefTable.name} WHERE ${cols[0]} = ?',
          variables: [Variable(_expiryStampKey)],
        )
        .get();
    if (rows.isEmpty) return;
    // 只认形如 YYYY-MM-DD 的值：手改过或旧包塞了别的东西时保持空（不猜）。
    final s = '${rows.first.data[cols[1]]}'.trim();
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) expiryNotifiedDay = s;
  }

  /// 记「这天已经提醒过了」。写失败静默——最坏是明天多提醒一次，
  /// 而把 App 启动动线挂住是不可接受的（与收藏/主题同款处理）。
  Future<void> markExpiryNotified(String day) async {
    expiryNotifiedDay = day;
    final db = _db;
    if (db == null) return;
    final cols = kLocalPrefTable.columnNames;
    try {
      await db.customInsert(
        'INSERT INTO ${kLocalPrefTable.name} (${cols.join(', ')}) '
        'VALUES (?, ?) ON CONFLICT(${cols[0]}) DO UPDATE SET ${cols[1]} = excluded.${cols[1]}',
        variables: [Variable(_expiryStampKey), Variable(day)],
      );
    } catch (_) {
      // 本机去重只是「少打扰一次」，不是数据正确性；写不进去就不写。
    }
  }

  // ── R47 · 开饭前投待办的本机去重戳（FR-PLAN-09 + FR-SET-01）──────────
  //
  // 存的是「这台设备今天为哪几餐投过待办了」，形如 `2026-09-30#晚餐` 的一组键。
  // 为什么按「餐次」而不是按「天」（与上面那枚库存戳唯一的差别）：
  // 一天有早中晚三餐，只记一天的话，提醒完早餐就把晚餐的机会也吃掉了。
  // 为什么仍是本机事实、不进同步流：投不投得出去取决于**这台设备什么时候被打开**，
  // 与主题、悬浮窗、库存戳同一条立场。
  static const _mealStampKey = 'meal_reminder_notified';

  /// 只认 `YYYY-MM-DD#非空餐名`：脏值（手改过、旧包写过别的形状）当没有，不猜。
  static final RegExp _mealStampRe = RegExp(r'^\d{4}-\d{2}-\d{2}#.+$');

  /// 形状对还要**日期真存在**：`2026-13-99#晚餐` 是手改坏的特征，
  /// 认下来就是往集合里塞一个永远不会再匹配的垃圾键——它不会造成误投，
  /// 但会把「这台设备到底投过什么」这份取证读数弄脏。
  /// ★ 不能交给 `DateTime.tryParse`：Dart 的解析器**会把越界分量归一**
  ///   （`2026-13-99` → 2027-04-09，实测），它不是校验器。所以这里自己按月卡天数。
  static bool _mealStampValid(String key) {
    if (!_mealStampRe.hasMatch(key)) return false;
    final mo = int.parse(key.substring(5, 7));
    final d = int.parse(key.substring(8, 10));
    if (mo < 1 || mo > 12 || d < 1) return false;
    // 「下个月 0 号」= 本月最后一天，让 DateTime 自己去算闰年与大小月。
    return d <= DateTime(int.parse(key.substring(0, 4)), mo + 1, 0).day;
  }

  /// 今天已投过的餐次键。空集 = 这台设备还没投过。
  Set<String> mealReminderNotifiedKeys = {};

  Future<void> _loadMealStamps(ZaojiDb db) async {
    final cols = kLocalPrefTable.columnNames;
    final rows = await db
        .customSelect(
          'SELECT ${cols[1]} FROM ${kLocalPrefTable.name} WHERE ${cols[0]} = ?',
          variables: [Variable(_mealStampKey)],
        )
        .get();
    if (rows.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode('${rows.first.data[cols[1]]}');
    } catch (_) {
      return; // 解不开就当没投过（宁可多提醒一次，不要永久静音）
    }
    if (decoded is! List) return;
    mealReminderNotifiedKeys = {
      for (final e in decoded.map((x) => '$x'))
        if (_mealStampValid(e)) e,
    };
  }

  /// 这一餐今天已经投过了吗。键里带着日期，所以昨天的戳天然不会挡住今天。
  bool mealReminderNotified(String key) => mealReminderNotifiedKeys.contains(key);

  /// 记「这一餐今天投过了」。
  ///
  /// 每次写都只保留与**新键同一天**的旧键：过期的戳留着没有意义，
  /// 而这样就不用在这里读时钟（日期已经在键里了），也不会一天一天无限涨。
  /// 写失败静默——本机去重只是「少打扰一次」，不是数据正确性（与库存戳同款处理）。
  Future<void> markMealReminderNotified(String key) async {
    if (!_mealStampValid(key)) return;
    final day = key.substring(0, 10);
    mealReminderNotifiedKeys = {
      for (final k in mealReminderNotifiedKeys)
        if (k.startsWith(day)) k,
      key,
    };
    final db = _db;
    if (db == null) return;
    final cols = kLocalPrefTable.columnNames;
    try {
      await db.customInsert(
        'INSERT INTO ${kLocalPrefTable.name} (${cols.join(', ')}) '
        'VALUES (?, ?) ON CONFLICT(${cols[0]}) DO UPDATE SET ${cols[1]} = excluded.${cols[1]}',
        variables: [
          Variable(_mealStampKey),
          Variable(jsonEncode(mealReminderNotifiedKeys.toList())),
        ],
      );
    } catch (_) {
      // 落不下去最坏是同一餐多投一次；把 App 的提醒动线挂住才是真问题。
    }
  }

  // ── R44 · AI 执行记录的本机视角（localOnly ai_usage，不走同步）────────
  //
  // 权威留痕在服务端 ai_runs（那里才有完整 prompt 与上游原始输出）。
  // 这里只记「这台设备发起过什么、结果如何」，run_ref 指回服务端行做对账，
  // 记录页据此在条目上叠「本机发起」标记。**单条自动提交的写**——
  // 套事务反而踩 R41 那条 Web 落盘坑，而这里本来就只有一行、要的就是原子自提交。

  /// 记一条本机 AI 调用。写失败静默（留痕不该挡住 AI 结果本身）。
  Future<void> logAiRun({
    required String feature,
    required bool ok,
    String? model,
    int promptTokens = 0,
    int completionTokens = 0,
    String? runRef,
    String? summary,
  }) async {
    final db = _db;
    if (db == null) return;
    final cols = kAiUsageTable.columnNames; // id,at,feature,model,...,run_ref,summary
    try {
      await db.customInsert(
        'INSERT INTO ${kAiUsageTable.name} (${cols.join(', ')}) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        variables: [
          Variable<String>(_ulids.next()),
          Variable<String>(DateTime.now().toUtc().toIso8601String()),
          Variable<String>(feature),
          Variable<String>(model),
          Variable<int>(promptTokens),
          Variable<int>(completionTokens),
          Variable<double>(0), // cost_est：本轮不算钱，列留着
          Variable<int>(ok ? 1 : 0),
          Variable<String>(runRef),
          Variable<String>(summary),
        ],
      );
    } catch (e) {
      debugPrint('本机 AI 记录写入失败（忽略）：$e');
    }
  }

  /// 本机发起过的服务端记录 id 集合（记录页标「本机发起」用）。
  Future<Set<String>> localAiRunRefs() async {
    final db = _db;
    if (db == null) return const {};
    try {
      final rows = await db
          .customSelect(
            'SELECT run_ref FROM ${kAiUsageTable.name} WHERE run_ref IS NOT NULL',
          )
          .get();
      return {for (final r in rows) r.read<String>('run_ref')};
    } catch (_) {
      return const {};
    }
  }

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
        // R27：来源不再写死——AI 补全的菜谱带 'ai' + 模型名 + 生成时间（FR-REC-35）
        'source': draft.source,
        'source_model': draft.sourceModel,
        'source_at': draft.source == 'ai'
            ? now.toIso8601String()
            : null,
        'last_cooked_at': null,
        'cover_sha256': draft.coverSha256,
        // R29：照片墙（sha256 JSON 数组）。空列表存 null 不存 '[]'——
        // 与 cover 的「没有就是 NULL」口径一致，回收/查询少一种要特判的形状
        'photos': draft.photos.isEmpty ? null : jsonEncode(draft.photos),
        // v7（FR-LOG-01）：入册时刻。业务时间戳用 ISO8601（与 cook_session 同口径，
        // R20 定样：HLC 只当同步元数据），日历直接截前 10 位当日期。
        // ★ 只在**新建**时写；updateRecipe 的列清单里没有它，改一万次也不会动。
        'created_at': now.toIso8601String(),
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
          // v5：步骤实拍（≤4 张由 UI 保证；这里只保证「有就存数组」）
          'images': (i < draft.stepImages.length && draft.stepImages[i].isNotEmpty)
              ? jsonEncode(draft.stepImages[i])
              : null,
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
        steps: [
          for (var i = 0; i < draft.steps.length; i++)
            Step(draft.steps[i],
                images: i < draft.stepImages.length ? draft.stepImages[i] : const []),
        ],
        photos: draft.photos,
        source: RecipeSource.values.asNameMap()[draft.source] ??
            RecipeSource.manual,
        sourceModel: draft.sourceModel,
        cookedCount: 0,
        art: draft.art,
        palette: draft.palette,
        tags: draft.tags,
        coverSha256: draft.coverSha256,
        // 与刚落库那一列同源：同一个 `now`，不是"再取一次当前时间"
        createdAt: now.toIso8601String(),
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
        'self_time = ?, servings = ?, notes = ?, tags = ?, cover_sha256 = ?, photos = ?, '
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
          Variable(draft.photos.isEmpty ? null : jsonEncode(draft.photos)),
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
          // v5：步骤实拍（≤4 张由 UI 保证；这里只保证「有就存数组」）
          'images': (i < draft.stepImages.length && draft.stepImages[i].isNotEmpty)
              ? jsonEncode(draft.stepImages[i])
              : null,
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
    // 回收站列表跟着长一条：softDelete 是就地改内存缓存、不走 _loadAll 的那几条路径之一，
    // 漏掉这里，回收站页（只读 deletedItems）就要等下一次同步重载才看得见。
    // 放在最前，与 _queryDeleted 的 ORDER BY updated_at DESC 同序。
    deletedItems = [
      existing,
      ...deletedItems.where((r) => r.id != recipeId),
    ];
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
  ///
  /// 页面**不要**在 initState 里 await 它：这条查询走真库，Widget 测试的 FakeAsync
  /// 不会把 isolate 的回复送进来（回收站页第一版就卡在加载圈里出不来）。
  /// 结果同时缓存在 [deletedItems]，页面读那个字段 + 挂 ListenableBuilder。
  Future<List<Recipe>> listDeleted() => _queryDeleted(_db!);

  Future<List<Recipe>> _queryDeleted(ZaojiDb db) async {
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
        PantryAliasResolver(known, explicit: _aliasTable);
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

  // ═══════════════════ R40 · 家庭成员与过敏原（FR-SET-04/05） ═══════════════════
  //
  // 三件事分开看：**成员表是全家共享的业务数据（走同步）**，
  // 而"要不要显示警示 / 加菜单时拦不拦"是本机偏好（不走同步）——
  // 前者是事实，后者是各台设备的显示选择。混在一列里，
  // 就会出现"平板上关掉了提示，灶台手机也跟着看不见过敏警告"这种事故。

  List<Member> members = const [];

  /// 警示开关（本机偏好）。默认全开：一个默认关闭的安全提示等于没有提示。
  bool allergenWarnInRecipes = true;
  bool allergenConfirmOnMenu = true;

  /// 同义词表要不要生效（R42 · 原型「警示设置 · 食材别名归一」那一行）。
  ///
  /// **一处开关管两处**：备菜合并的归一 + 过敏原判定的别名展开。
  /// 理由与 R40「控件只有一份」同源——番茄=西红柿这件事要么两头都认，
  /// 要么两头都不认；分成两个开关，迟早出现"合并把它算一样、
  /// 警示把它算两样"这种没人能解释的界面。
  /// 默认开：关掉它的后果是**漏报**（少一条提示），而不是少一次麻烦。
  bool ingredientAliasOn = true;

  Future<void> _loadMembers(ZaojiDb db) async {
    final rows = await db
        .customSelect('SELECT * FROM member WHERE deleted_at IS NULL ORDER BY id')
        .get();
    members = [for (final r in rows) Member.fromRow(r.data)];
  }

  /// 成员名查重（活行）。同名家人在语义上就是同一个人——
  /// 两个"爸爸"会让同一道菜的警告重复刷屏，且用户分不清哪条该删。
  bool memberNameTaken(String name, {String? exceptId}) {
    final n = name.trim();
    return members.any((m) => m.name == n && m.id != exceptId);
  }

  Future<Member> createMember({
    required String name,
    List<String> allergens = const [],
    List<String> dislikes = const [],
    int avatar = 0,
  }) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final now = DateTime.now();
    var hlc = Hlc.now(nodeId, wallMs: now.millisecondsSinceEpoch);
    String next() => hlc.tick(nodeId, wallMs: now.millisecondsSinceEpoch).encode();
    final id = _ulids.next();
    final clean = _cleanWords([allergens, dislikes]);
    // 单条语句本身就是原子的，不套 db.transaction：
    // Web 端实测"套了 void 事务的这条写入活不过刷新"（见交接文档 §六 的丢写窗口），
    // 少一层包装既省一次 BEGIN/COMMIT，也避开那条路径。
    await _insert(db, kMemberTable, {
      'id': id,
      'updated_at': next(),
      'updated_by': nodeId,
      'rev': 1,
      'deleted_at': null,
      'name': name.trim(),
      'avatar': avatar,
      'allergens': jsonEncode(clean.$1),
      'dislikes': jsonEncode(clean.$2),
    });
    final m = Member(
      id: id,
      name: name.trim(),
      avatar: avatar,
      allergens: clean.$1,
      dislikes: clean.$2,
    );
    members = [...members, m];
    notifyListeners();
    _fireLocalWrite();
    return m;
  }

  /// 整行覆盖式更新（表单是"改完再存"，不是逐字段自动保存）。
  Future<void> updateMember(
    String id, {
    required String name,
    required List<String> allergens,
    required List<String> dislikes,
    int? avatar,
  }) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final now = DateTime.now();
    var hlc = Hlc.now(nodeId, wallMs: now.millisecondsSinceEpoch);
    String next() => hlc.tick(nodeId, wallMs: now.millisecondsSinceEpoch).encode();
    final existing = members.firstWhere((m) => m.id == id);
    final clean = _cleanWords([allergens, dislikes]);
    // 同 createMember：单条 UPDATE 不再套 void 事务（Web 端实测那种写法会丢，
    // 见交接文档 §六「Web 端写完立刻刷新会丢」）
    await db.customUpdate(
      'UPDATE member SET updated_at = ?, updated_by = ?, rev = rev + 1, '
      'name = ?, avatar = ?, allergens = ?, dislikes = ? WHERE id = ?',
      variables: [
        Variable(next()),
        Variable(nodeId),
        Variable(name.trim()),
        Variable(avatar ?? existing.avatar),
        Variable(jsonEncode(clean.$1)),
        Variable(jsonEncode(clean.$2)),
        Variable(id),
      ],
    );
    final m = Member(
      id: id,
      name: name.trim(),
      avatar: avatar ?? existing.avatar,
      allergens: clean.$1,
      dislikes: clean.$2,
    );
    members = [for (final x in members) x.id == id ? m : x];
    notifyListeners();
    _fireLocalWrite();
  }

  /// 软删（成员表参与同步，别的端要看到这个人消失）。
  /// 删成员**不动任何菜谱**：警告是派生出来的，人没了警告自然没了。
  Future<void> deleteMember(String id) async {
    final db = _db!;
    final nodeId = await _resolveNodeId();
    final now = DateTime.now();
    final hlc = Hlc.now(nodeId, wallMs: now.millisecondsSinceEpoch);
    final stamp = hlc.tick(nodeId, wallMs: now.millisecondsSinceEpoch).encode();
    await db.customUpdate(
      'UPDATE member SET updated_at = ?, updated_by = ?, rev = rev + 1, '
      'deleted_at = ? WHERE id = ?',
      variables: [Variable(stamp), Variable(nodeId), Variable(stamp), Variable(id)],
    );
    members = members.where((m) => m.id != id).toList();
    notifyListeners();
    _fireLocalWrite();
  }

  /// 去空白、去重、保持用户输入顺序（顺序就是他在弹层里加词的顺序，不重排）。
  static (List<String>, List<String>) _cleanWords(List<List<String>> groups) {
    List<String> one(List<String> src) {
      final out = <String>[];
      for (final w in src) {
        final t = w.trim();
        if (t.isNotEmpty && !out.contains(t)) out.add(t);
      }
      return out;
    }

    return (one(groups[0]), one(groups[1]));
  }

  /// 一道菜命中了谁（FR-SET-05 的判定入口，四处 UI 共用这一个）。
  ///
  /// 比的是**双方各自归一后的原文**（`AllergenMatch.norm` 剥空白与单位尾），
  /// 外加双向包含 + 类名展开 + **同义词表**（R42：成员填「番茄」、菜里写「西红柿」
  /// 必须命中——那是漏报方向）。同义词表就是备菜合并用的那一张，
  /// 受同一个本机开关 [ingredientAliasOn] 管（原型「警示设置 · 食材别名归一」那一行）。
  List<AllergenHit> allergenHitsFor(Recipe recipe) =>
      AllergenMatch.matchRecipe(
        ingredients: [for (final i in recipe.ingredients) i.name],
        members: [
          for (final m in members)
            {
              'id': m.id,
              'name': m.name,
              'allergens': m.allergens,
              'dislikes': m.dislikes,
            }
        ],
        aliases: _aliasTable,
      );

  /// 某样食材命中了谁（详情页食材行那条条纹标注用）。
  List<AllergenHit> allergenHitsForIngredient(String name) =>
      AllergenMatch.matchRecipe(
        ingredients: [name],
        members: [
          for (final m in members)
            {
              'id': m.id,
              'name': m.name,
              'allergens': m.allergens,
              'dislikes': m.dislikes,
            }
        ],
        aliases: _aliasTable,
      );

  /// 判定与合并共用的那张同义词表；开关关掉就是不给表（`hit` 退回逐字比）。
  Map<String, String> get _aliasTable =>
      ingredientAliasOn ? kDefaultAliases : const {};

  /// 全库有多少道菜和这位家人**过敏**冲突（成员页顶部那条汇总）。
  ///
  /// 只数 allergy 不数 dislike：忌口是"能吃但不爱吃"，把它算进"冲突"
  /// 会让数字虚高，而这条汇总的意义是"有几道菜真不能给家里人吃"。
  int conflictingRecipeCount({String? memberId}) {
    final ids = <String>{};
    for (final r in recipes) {
      final hits = allergenHitsFor(r);
      if (!hits.any((h) => h.isAllergy)) continue;
      if (memberId == null ||
          hits.any((h) => h.memberId == memberId && h.isAllergy)) {
        ids.add(r.id);
      }
    }
    return ids.length;
  }

  /// 有过敏冲突的菜名（成员页那条汇总里"→ 红烧肉、蒜蓉虾"这一段）。
  List<String> conflictingRecipeNames(String memberId) => [
        for (final r in recipes)
          if (allergenHitsFor(r).any((h) => h.memberId == memberId && h.isAllergy))
            r.name,
      ];

  /// 警示开关落库（本机偏好，不进同步流）。
  void setAllergenWarnInRecipes(bool on) {
    if (allergenWarnInRecipes == on) return;
    allergenWarnInRecipes = on;
    notifyListeners();
    final db = _db;
    if (db != null) {
      unawaited(_persistPref(_prefAllergenWarn, jsonEncode(on))
          .catchError((Object e) => debugPrint('过敏警示偏好写库失败：$e')));
    }
  }

  void setAllergenConfirmOnMenu(bool on) {
    if (allergenConfirmOnMenu == on) return;
    allergenConfirmOnMenu = on;
    notifyListeners();
    final db = _db;
    if (db != null) {
      unawaited(_persistPref(_prefAllergenConfirm, jsonEncode(on))
          .catchError((Object e) => debugPrint('加菜单拦截偏好写库失败：$e')));
    }
  }

  static const _prefAllergenWarn = 'allergen_warn_in_recipes';
  static const _prefAllergenConfirm = 'allergen_confirm_on_menu';

  /// R42 · 同义词表开关（判定 + 合并共用），与上面两个同属本机偏好。
  static const _prefIngredientAlias = 'ingredient_alias_on';

  void setIngredientAlias(bool on) {
    if (ingredientAliasOn == on) return;
    ingredientAliasOn = on;
    notifyListeners();
    final db = _db;
    if (db != null) {
      unawaited(_persistPref(_prefIngredientAlias, jsonEncode(on))
          .catchError((Object e) => debugPrint('别名归一偏好写库失败：$e')));
    }
  }

  Future<void> _persistPref(String key, String value) async {
    final db = _db;
    if (db == null) return;
    final cols = kLocalPrefTable.columnNames;
    await db.customInsert(
      'INSERT INTO ${kLocalPrefTable.name} (${cols.join(', ')}) '
      'VALUES (?, ?) ON CONFLICT(${cols[0]}) DO UPDATE SET ${cols[1]} = excluded.${cols[1]}',
      variables: [Variable(key), Variable(value)],
    );
  }

  Future<void> _loadAllergenPrefs(ZaojiDb db) async {
    final cols = kLocalPrefTable.columnNames;
    final rows = await db
        .customSelect(
          'SELECT ${cols[0]}, ${cols[1]} FROM ${kLocalPrefTable.name} '
          'WHERE ${cols[0]} IN (?, ?, ?)',
          variables: [
            Variable(_prefAllergenWarn),
            Variable(_prefAllergenConfirm),
            Variable(_prefIngredientAlias),
          ],
        )
        .get();
    for (final r in rows) {
      final on = '${r.data[cols[1]]}' == 'true';
      if (r.data[cols[0]] == _prefAllergenWarn) allergenWarnInRecipes = on;
      if (r.data[cols[0]] == _prefAllergenConfirm) allergenConfirmOnMenu = on;
      if (r.data[cols[0]] == _prefIngredientAlias) ingredientAliasOn = on;
    }
  }

  // ═══════════════════ R24 · 日历（做过什么 / 排了什么） ═══════════════════
  //
  // cook_session 的 started_at / finished_at 是 ISO8601 **业务时间戳**
  // （R20 定样——HLC 只当同步元数据用），所以日历折算日期直接截串，
  // 不需要也不应该去解 HLC。跨设备的记录都算：日历是全家的账本。

  /// 某一月的点标记：哪几天做过菜 / 排了菜单 / 入了新菜，以及本月开火总场次。
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
    // v7（FR-LOG-01）：第三种点。created_at 为 NULL 的老行**天然不进来**——
    // 那不是"那天没做菜"，是"不知道哪天入的册"，两者在 UI 上必须同一种表现。
    final addedRows = await db.customSelect(
      'SELECT created_at FROM recipe WHERE created_at LIKE ? AND deleted_at IS NULL',
      variables: [Variable<String>('$prefix%')],
    ).get();
    return MonthMarks(
      cookDays: {for (final r in cookRows) '${r.data['finished_at']}'.substring(0, 10)},
      menuDays: {for (final r in menuRows) '${r.data['day']}'},
      addedDays: {
        for (final r in addedRows) '${r.data['created_at']}'.substring(0, 10),
      },
      cookCount: cookRows.length,
    );
  }

  /// 某一天入册的菜谱（v7 · FR-LOG-01 的第三种点）。按入册时刻升序。
  Future<List<AddedRecipe>> addedRecipesOn(String day) async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db.customSelect(
      'SELECT id, name, created_at FROM recipe '
      'WHERE created_at LIKE ? AND deleted_at IS NULL ORDER BY created_at',
      variables: [Variable<String>('$day%')],
    ).get();
    return [
      for (final r in rows)
        AddedRecipe(
          recipeId: '${r.data['id']}',
          recipeName: '${r.data['name']}',
          time: '${r.data['created_at']}'.length >= 16
              ? '${r.data['created_at']}'.substring(11, 16)
              : '',
        ),
    ];
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

  /// 某一月的全部完成会话明细（R32 · 烹饪统计）。
  ///
  /// 口径与 [monthMarks] 一致：只有 finished_at 非空且未软删的算做过。
  /// 页面要的「开火 N 次 / 做了 M 道 / 累计 X 分钟 / 校准对照」全从这一份
  /// 明细现算——家庭规模一个月几十行，不值得为每种聚合各写一条 SQL。
  Future<List<MonthSession>> monthSessions(int year, int month) async {
    final db = _db;
    if (db == null) return const [];
    final prefix = '${year.toString().padLeft(4, '0')}-'
        '${month.toString().padLeft(2, '0')}';
    final rows = await db.customSelect(
      'SELECT recipe_id, started_at, finished_at FROM cook_session '
      'WHERE finished_at LIKE ? AND deleted_at IS NULL',
      variables: [Variable<String>('$prefix%')],
    ).get();
    return [
      for (final r in rows)
        MonthSession(
          recipeId: '${r.data['recipe_id']}',
          day: '${r.data['finished_at']}'.substring(0, 10),
          minutes: _minutesBetween(
              '${r.data['started_at']}', '${r.data['finished_at']}'),
        ),
    ];
  }

  // ═══════════════════ R33 · 数据体检的两份原始料 ═══════════════════

  /// 全设备、全家的**未完成**会话（体检页拿去配菜谱名）。
  ///
  /// 续做入口（R20）只认本设备的，账本可不能只查自己——
  /// 挂在灶上的可能是全家任何一台手机。
  Future<List<({String recipeId, String startedAt})>> openCookSessions() async {
    final db = _db;
    if (db == null) return const [];
    final rows = await db.customSelect(
      'SELECT recipe_id, started_at FROM cook_session '
      'WHERE finished_at IS NULL AND deleted_at IS NULL '
      'ORDER BY started_at',
    ).get();
    return [
      for (final r in rows)
        (recipeId: '${r.data['recipe_id']}', startedAt: '${r.data['started_at']}'),
    ];
  }

  /// 清单项 id → 最近一次写入的**物理时刻**。
  ///
  /// shopping_item 没有业务时间列（R30 定样：清单是短命账，值当为它加列），
  /// 体检要「挂了多久」只能退而求其次读 updated_at 的 HLC 物理段——
  /// 语义上是「至少挂了这么久」，勾过一次的项以勾选时刻起算，够用且不撒谎。
  Future<Map<String, DateTime>> shoppingItemAges() async {
    final db = _db;
    if (db == null) return const {};
    final rows = await db.customSelect(
      'SELECT id, updated_at FROM shopping_item WHERE deleted_at IS NULL',
    ).get();
    final out = <String, DateTime>{};
    for (final r in rows) {
      final h = Hlc.tryDecode('${r.data['updated_at']}');
      if (h != null) {
        out['${r.data['id']}'] =
            DateTime.fromMillisecondsSinceEpoch(h.physicalMs);
      }
    }
    return out;
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

  /// R27：来源标记（FR-REC-21/35）。AI 补全后保存 = 'ai' + 模型名；
  /// 默认 'manual'——不传就和以前完全一样。
  final String source;
  final String? sourceModel;

  /// R29：照片墙的 sha 列表 + 每步的实拍列表（与 steps 下标对齐）。
  final List<String> photos;
  final List<List<String>> stepImages;

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
    this.source = 'manual',
    this.sourceModel,
    this.photos = const [],
    this.stepImages = const [],
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
final TableSpec kNutritionTable =
    kTables.firstWhere((t) => t.name == 'nutrition');
final TableSpec kShoppingTable =
    kTables.firstWhere((t) => t.name == 'shopping_item');
final TableSpec kPantryTable =
    kTables.firstWhere((t) => t.name == 'pantry_item');
final TableSpec kMemberTable = kTables.firstWhere((t) => t.name == 'member');
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

/// R44：本机视角的 AI 调用记录。localOnly —— **不走同步、不上服务端**。
final TableSpec kAiUsageTable = kTables.firstWhere((t) => t.name == 'ai_usage');

/// R23 · 内置同义词表（备菜归一 + R42 起过敏原判定共用）。
///
/// **表本身在 `shared` 的 [kIngredientAliases]**——判定与合并必须吃同一张表，
/// 两边各写一份迟早会漂（R40 就漂过一次：库存认「西红柿」，过敏判定不认）。
/// 这里留一个名字是给备菜那条调用路径的，别再往回加条目。
const Map<String, String> kDefaultAliases = kIngredientAliases;

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

  /// v7（FR-LOG-01）：有菜谱入册的日期集合。
  ///
  /// 只包含 `created_at` 非空的行——v6 及更早建的菜**没有这个事实**，
  /// 那天不画点，而不是画一个猜出来的点。
  final Set<String> addedDays;

  /// 本月开火场次（按会话计数，一天做两道算两次）。
  final int cookCount;

  const MonthMarks({
    required this.cookDays,
    required this.menuDays,
    this.addedDays = const {},
    required this.cookCount,
  });

  const MonthMarks.empty()
      : cookDays = const {},
        menuDays = const {},
        addedDays = const {},
        cookCount = 0;
}

/// 日历里的一条「新增菜品」记录（v7 · FR-LOG-01）。
///
/// 与 [CookEvent] 分开放：两者字段不同（做菜记录有耗时，入册记录没有），
/// 硬塞进一个类会让"耗时"这一栏在入册那行显示成 0 分钟——那是假数据。
class AddedRecipe {
  final String recipeId;
  final String recipeName;

  /// HH:MM，入册时刻。
  final String time;

  const AddedRecipe({
    required this.recipeId,
    required this.recipeName,
    required this.time,
  });
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

/// 统计页用的一条完成会话（R32）。
class MonthSession {
  final String recipeId;

  /// yyyy-MM-dd，取 finished_at 的日期部分。
  final String day;

  /// 开始→完成的分钟数；解析不出来是 0。
  final int minutes;

  const MonthSession({
    required this.recipeId,
    required this.day,
    required this.minutes,
  });
}
