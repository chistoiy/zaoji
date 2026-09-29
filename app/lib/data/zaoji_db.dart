import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
import 'package:zaoji_shared/zaoji_shared.dart';

/// 客户端数据库。
///
/// ## 为什么不用 Drift 的表类 / codegen
///
/// 项目铁律（`shared/lib/src/schema.dart` 开头写得很重）：
/// **表结构只有一份，服务端与客户端都消费它，绝不各写一套 DDL。**
/// 如果在这里手写 Drift 的 `Table` 类，等于第二份 DDL——哪怕有测试盯着，
/// 也比「直接执行同一份定义」多一次漂移的机会。所以这里**不用 codegen**，
/// 建表语句逐条来自 `TableSpec.createSql()`。
///
/// Drift 在这个项目里的角色因此收窄为两件事，都是我们自己写会费劲的：
/// ① **跨平台连接管理**——Android 走原生 sqlite，Web 走 wasm + OPFS（iOS 就是 Web）；
/// ② 事务 / 连接生命周期管理。
/// 查询全部走 `customSelect` / `customStatement`，拿回来的就是
/// `Map<String, Object?>`——恰好就是同步协议里行的形态，一层翻译都不用做。
///
/// ## 建哪些表
///
/// **只建客户端需要的**：`business`（同步数据）+ `localOnly`（AI 配置等）。
/// `serverOnly`（change_log / device / pair_code / applied_mutation / meta）
/// 是服务端的基础设施——客户端建了也永远不会有正确的数据，
/// 反而给人「客户端也有游标」的错觉（游标铁律：**拉取游标在客户端**，
/// 但那是同步引擎自己的存储，不是这张服务端表）。
class ZaojiDb extends GeneratedDatabase {
  ZaojiDb(super.executor);

  /// 连接构造：Web 与原生共用（drift_flutter 会按平台选实现）。
  ///
  /// Web 需要两个资产放在 `web/` 下：`sqlite3.wasm` 与 `drift_worker.js`
  /// （来源与校验见 `app/tool/build_web.ps1`）。
  factory ZaojiDb.open() {
    return ZaojiDb.connect(
      driftDatabase(
        name: 'zaoji',
        web: DriftWebOptions(
          sqlite3Wasm: Uri.parse('sqlite3.wasm'),
          driftWorker: Uri.parse('drift_worker.js'),
        ),
      ),
    );
  }

  /// 测试注入内存库用的连接构造。
  ZaojiDb.connect(super.connection);

  // ── v0.14.4 补丁 · Web 端「事务写完活不过刷新」──────────────────────
  //
  // Web 上没有原生 sqlite 文件，drift 的 `WasmDatabase` 要在浏览器里**模拟一个文件系统**。
  // 本机 Chromium 因为缺 `sharedArrayBuffer` 与 `dedicatedWorkersInSharedWorkers`，
  // 拿到的实现是 `WasmStorageImplementation.sharedIndexedDb`（IndexedDB 里按 4096B 分块的
  // files/blocks 两张 store，跑在 SharedWorker 里）。取证与读数见仓库 `tool/web_write_loss_probe.cjs`
  // 文件头，一句话结论：
  //
  // - **自动提交的单条写**（收藏、`local_pref` 直写）：写下去那一刻 IDB 的块就变了，刷新后还在；
  // - **`db.transaction(...)` 提交的写**（建菜谱、库存、购物清单、软删、同步落库……）：
  //   界面立刻看得到（共 9 道 → 10 道），但 IDB 的块**六秒内一格没动**，
  //   刷新、乃至整个浏览器关掉再开都回到 9 道 —— 那一笔从来没落过盘。
  // - 事务之后再补一记单条写，事务攒着的那些块**跟着一起下盘**了。
  //
  // 所以修法是在**连接层的一个收口**上：最外层事务提交完，紧跟一记自动提交的写入，逼它冲一次盘。
  // 不改那 10 处 `db.transaction` 调用点：多语句写入的原子性是真需求（`finishCooking`
  // 结会话 + 计数 +1 少一半就是脏账），摘掉事务是把 A 问题换成 B 问题。
  // 心跳键挑 `local_pref`：它是 `TableScope.localOnly`，不进同步流、永不上服务端，
  // 现有读取全按具体键走，多一个键不碰任何人。
  // 只在 Web 上做：Android 走原生 sqlite，落盘由 SQLite 自己管，加这条纯属白写。
  //
  // 残留风险如实说：浏览器在 COMMIT 之后、这条补写之前被杀，那一笔还是会丢——
  // 这条补丁把「必然丢」变成「极窄窗口才丢」，不是把窗口焊死。

  /// 测试用：在 VM（非 Web）上也要走一遍这条冲盘路径。
  @visibleForTesting
  static bool forceFlushAfterTransaction = false;

  /// 当前嵌套事务的深度。drift 的内层 `transaction()` 是直接跑在外层事务里的，
  /// 只有最外层那次提交才需要冲盘，内层再补既冲不下去也白写一行。
  int _txDepth = 0;
  int _flushTicks = 0;

  bool get _needsFlushAfterTransaction => kIsWeb || forceFlushAfterTransaction;

  @override
  Future<T> transaction<T>(Future<T> Function() action,
      {bool requireNew = false}) async {
    final nested = _txDepth > 0;
    _txDepth++;
    try {
      return await super.transaction(action, requireNew: requireNew);
    } finally {
      _txDepth--;
      if (!nested && _needsFlushAfterTransaction) {
        await _flushWebStorage();
      }
    }
  }

  /// 一记自动提交的写：只为把 SharedWorker 里攒着的脏页冲回 IndexedDB。
  Future<void> _flushWebStorage() async {
    final cols = _localPrefTable.columnNames;
    _flushTicks++;
    await customStatement(
      'INSERT INTO ${_localPrefTable.name} (${cols.join(', ')}) '
      'VALUES (?, ?) ON CONFLICT(${cols[0]}) DO UPDATE SET ${cols[1]} = excluded.${cols[1]}',
      [kWebFlushTickKey, '"$_flushTicks"'],
    );
  }

  /// 冲盘心跳在 `local_pref` 里的键。**是基建不是偏好**，别拿它当业务数据读。
  static const kWebFlushTickKey = 'web_flush_tick';

  /// 客户端要建的表。顺序即建表顺序（父表在前，外键才不会挡）。
  static List<TableSpec> get clientTables =>
      kTables.where((t) => t.scope != TableScope.serverOnly).toList();

  /// 客户端参与同步的表（同步引擎推送/拉取都用它）。
  static List<TableSpec> get syncedTables =>
      kTables.where((t) => t.isSynced).toList();

  /// 参与同步的表，**按 applyOrder 排（父表在前）**。
  /// 推送时按这个顺序收集变更（服务端有外键），拉取落库也按它排。
  static List<TableSpec> get syncedTablesSorted {
    final order = applyOrder;
    final synced = kTables.where((t) => t.isSynced).toList()
      ..sort((a, b) => order.indexOf(a.name).compareTo(order.indexOf(b.name)));
    return synced;
  }

  @override
  int get schemaVersion => kSchemaVersion;

  // 没有 Drift 表类，实体列表为空——建表由 [migration] 里的 createSql 负责。
  @override
  Iterable<TableInfo> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      // 建表语句与**服务端用的是同一份**（同一份 schema.dart、同一份 createSql）。
      // IF NOT EXISTS 已在 createSql 里，重复执行无害。
      for (final t in clientTables) {
        await customStatement(t.createSql());
      }
    },
    onUpgrade: (m, from, to) async {
      // 升级同样执行全量 createSql：它自带 IF NOT EXISTS，对已存在的表是无害的
      // no-op，缺的表会被补出来（v2 → v3 补 local_pref 就是这条路径）。
      for (final t in clientTables) {
        await customStatement(t.createSql());
      }
      // v4 → v5（R29）改列迁移：createSql 救不了已存在的表，
      // ALTER 脚本与服务端**逐字共用 shared 的 kSchemaV5AlterSql**。
      // 判据用列在不在（幂等，半迁移重进也安全），与 R21 的 v4 同法。
      if (from < 5) {
        final hasPhotos =
            (await customSelect('PRAGMA table_info(recipe)').get())
            .any((r) => r.read<String>('name') == 'photos');
        if (!hasPhotos) {
          for (final stmt in kSchemaV5AlterSql) {
            await customStatement(stmt);
          }
        }
      }
    },
    beforeOpen: (details) async {
      // 外键与服务端同一立场：schema 里 ingredient/step 都挂着
      // FOREIGN KEY (recipe_id)，关掉它等于少一道数据完整性防线。
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}

/// v0.14.4 · 冲盘心跳写在哪张表：`local_pref`（`TableScope.localOnly`，不进同步流）。
final TableSpec _localPrefTable =
    kTables.firstWhere((t) => t.name == 'local_pref');
