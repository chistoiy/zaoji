import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
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
      // 目前所有迁移都是纯增表；哪天出现「改列」级别的迁移，
      // 必须在这里按版本号写针对性脚本，不能靠 IF NOT EXISTS。
      for (final t in clientTables) {
        await customStatement(t.createSql());
      }
    },
    beforeOpen: (details) async {
      // 外键与服务端同一立场：schema 里 ingredient/step 都挂着
      // FOREIGN KEY (recipe_id)，关掉它等于少一道数据完整性防线。
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
