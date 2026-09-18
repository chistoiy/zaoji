/// 灶记 ZAOJI · 数据模型
///
/// **这是全项目唯一一份表结构定义。** 服务端（`sqlite3`）与 Flutter 端（Drift）
/// 都从这里取，绝不允许各写一份——两端表结构一旦漂移，同步会在半夜以
/// 「某列不存在」的形式炸掉，而那时你已经想不起来两周前改过什么。
///
/// ## 三条铁律（改这个文件之前先读）
///
/// ### 一、业务表统一五列
///
/// | 列 | 类型 | 用途 |
/// |---|---|---|
/// | `id` | TEXT | ULID 主键。前 48 bit 是毫秒时间戳，所以**字典序 == 时间序** |
/// | `updated_at` | TEXT | HLC 混合逻辑时钟，定长编码，同样**字典序 == 时间序** |
/// | `updated_by` | TEXT | 最后写入的设备 id，冲突箱里要显示「谁改的」 |
/// | `rev` | INTEGER | 修订号 |
/// | `deleted_at` | TEXT | 软删除墓碑；`NULL` 表示活着。**永不物理删除** |
///
/// 两处「字典序 == 时间序」不是巧合，是刻意设计：这样服务端
/// `ORDER BY updated_at` 直接就是正确顺序，不需要解析、不需要额外索引。
///
/// ### 二、同步白名单由 [TableScope] 推导，不靠人记
///
/// 只有 `business` 范围的表参与同步。`ai_config` / `ai_usage` / `ai_cache`
/// 是 `localOnly`，所以**「API Key 会不会被同步上去」不是一条要记住的规矩，
/// 而是结构上做不到**——同步接口的白名单由 [syncWhitelist] 算出来。
///
/// ### 三、`change_log` 不是业务表
///
/// 它是服务端自己的变更日志（单调递增 `seq` + 设备游标），不参与同步。
library;

/// 表的作用范围。**这个枚举是同步安全边界的唯一来源。**
enum TableScope {
  /// 业务数据。参与同步，在各端之间来回复制。
  business,

  /// 只属于某一端，**永不外发**。AI 配置、用量、缓存都在这里。
  localOnly,

  /// 服务端基础设施（变更日志、设备游标、配对码）。客户端不需要也不该拿到。
  serverOnly,
}

/// 列定义。只覆盖 SQLite 的四种类型亲和性（TEXT / INTEGER / REAL / BLOB）。
class ColumnSpec {
  final String name;

  /// SQLite 类型亲和性名。
  final String type;

  final bool notNull;

  /// 默认值的 SQL 字面量（如 `'1'`、`"'{}'"`）。null 表示不写 DEFAULT。
  final String? defaultSql;

  final bool primaryKey;

  /// `INTEGER PRIMARY KEY AUTOINCREMENT`。
  ///
  /// `change_log.seq` 靠它保证**单调且永不复用**：没有 AUTOINCREMENT 时，
  /// 删掉最大的一行后下一个插入会复用那个序号，
  /// 而客户端游标正好停在这个序号上，于是**那一条变更会永远同步不过去**。
  final bool autoIncrement;

  /// 注释，会以 `--` 形式写在生成的 DDL 里，方便直接读库。
  final String? comment;

  const ColumnSpec(
    this.name,
    this.type, {
    this.notNull = false,
    this.defaultSql,
    this.primaryKey = false,
    this.autoIncrement = false,
    this.comment,
  });

  String toSql() {
    final b = StringBuffer(name)..write(' ');
    b.write(type);
    if (primaryKey) b.write(' PRIMARY KEY');
    if (autoIncrement) b.write(' AUTOINCREMENT');
    if (notNull) b.write(' NOT NULL');
    if (defaultSql != null) b.write(' DEFAULT $defaultSql');
    return b.toString();
  }
}

/// 表定义。
class TableSpec {
  final String name;
  final TableScope scope;
  final List<ColumnSpec> columns;

  /// 表级约束（外键、唯一约束等），原样拼到 DDL 末尾。
  final List<String> constraints;

  /// 表用途，写在 DDL 注释里。
  final String comment;

  const TableSpec({
    required this.name,
    required this.scope,
    required this.columns,
    this.constraints = const [],
    this.comment = '',
  });

  bool get isSynced => scope == TableScope.business;

  List<String> get columnNames => columns.map((c) => c.name).toList();

  ColumnSpec? column(String n) {
    for (final c in columns) {
      if (c.name == n) return c;
    }
    return null;
  }

  String createSql({bool ifNotExists = true}) {
    final body = <String>[];
    final total = columns.length + constraints.length;
    var i = 0;

    for (final c in columns) {
      i++;
      final line = '  ${c.toSql()}${i == total ? '' : ','}';
      body.add(c.comment == null ? line : '$line  -- ${c.comment}');
    }
    for (final c in constraints) {
      i++;
      body.add('  $c${i == total ? '' : ','}');
    }

    final head = 'CREATE TABLE ${ifNotExists ? 'IF NOT EXISTS ' : ''}$name (';
    final label = comment.isEmpty ? '' : '-- $comment\n';
    return '$label$head\n${body.join('\n')}\n);';
  }
}

/// 统一五列。所有业务表都必须以它开头——有测试盯着。
const List<ColumnSpec> kStandardColumns = [
  ColumnSpec('id', 'TEXT', primaryKey: true, comment: 'ULID，字典序 == 时间序'),
  ColumnSpec('updated_at', 'TEXT', notNull: true, comment: 'HLC，字典序 == 时间序'),
  ColumnSpec('updated_by', 'TEXT', notNull: true, comment: '最后写入的设备 id'),
  ColumnSpec('rev', 'INTEGER', notNull: true, defaultSql: '1'),
  ColumnSpec('deleted_at', 'TEXT', comment: '软删除墓碑；NULL = 活着'),
];

/// 全项目表定义。**新增表时请一并想清楚：它属于哪个 scope。**
///
/// 命名注意：`conflict` 与 `cursor` 都是 SQLite 关键字，所以这里用
/// `conflict_item` 与 `sync_cursor`。不要为了「好看」改回关键字。
const List<TableSpec> kTables = [
  // ───────────────── 菜谱 ─────────────────
  TableSpec(
    name: 'recipe',
    scope: TableScope.business,
    comment: '菜谱主表',
    columns: [
      ...kStandardColumns,
      ColumnSpec('name', 'TEXT', notNull: true),
      ColumnSpec('sub', 'TEXT', comment: '一句话描述，列表卡片上那行小字'),
      ColumnSpec('art', 'INTEGER', comment: '插画取景编号（离线封面，不存图片）'),
      ColumnSpec('pal', 'INTEGER', comment: '配色板编号'),
      ColumnSpec('difficulty', 'INTEGER',
          notNull: true, defaultSql: '1', comment: '1~3 档，对应辣椒刻度'),
      ColumnSpec('self_time', 'INTEGER', comment: '自报耗时（分钟）'),
      ColumnSpec('cooked_count', 'INTEGER', notNull: true, defaultSql: '0'),
      ColumnSpec('servings', 'INTEGER',
          notNull: true, defaultSql: '2', comment: '★ 分量缩放基数。建模期就要有，后补要改四处'),
      ColumnSpec('notes', 'TEXT', comment: '注意事项，多行'),
      ColumnSpec('tags', 'TEXT', comment: 'JSON 数组'),
      ColumnSpec('source', 'TEXT',
          notNull: true,
          defaultSql: "'manual'",
          comment: 'manual / import / ai'),
      ColumnSpec('source_model', 'TEXT', comment: 'source=ai 时记下模型名'),
      ColumnSpec('source_at', 'TEXT', comment: 'source=ai 时记下生成时间'),
      ColumnSpec('last_cooked_at', 'TEXT'),
      ColumnSpec('cover_sha256', 'TEXT', comment: '成品图，按 sha256 按需拉取'),
    ],
  ),
  TableSpec(
    name: 'ingredient',
    scope: TableScope.business,
    comment: '菜谱的食材行',
    constraints: ['FOREIGN KEY (recipe_id) REFERENCES recipe(id)'],
    columns: [
      ...kStandardColumns,
      ColumnSpec('recipe_id', 'TEXT', notNull: true),
      ColumnSpec('sort', 'INTEGER', notNull: true, defaultSql: '0'),
      ColumnSpec('name', 'TEXT', notNull: true, comment: '用户写的原名，永不改写'),
      ColumnSpec('qty_text', 'TEXT', comment: '原始分量文本（"半个"），展示用它'),
      ColumnSpec('qty_value', 'REAL', comment: '归一后的数值（0.5）'),
      ColumnSpec('qty_unit', 'TEXT', comment: '归一后的单位（g / ml / 个）'),
      ColumnSpec('is_main', 'INTEGER',
          notNull: true, defaultSql: '0', comment: '主食材。推荐算法里缺主食材要 ×0.5'),
      ColumnSpec('alias_key', 'TEXT', comment: '归一后的食材键，库存匹配用'),
    ],
  ),
  TableSpec(
    name: 'step',
    scope: TableScope.business,
    comment: '菜谱的做法步骤',
    constraints: ['FOREIGN KEY (recipe_id) REFERENCES recipe(id)'],
    columns: [
      ...kStandardColumns,
      ColumnSpec('recipe_id', 'TEXT', notNull: true),
      ColumnSpec('idx', 'INTEGER', notNull: true, comment: '第几步，从 0 起'),
      ColumnSpec('text', 'TEXT', notNull: true, comment: '原文。时间关键词是运行时解析的，不落库'),
      ColumnSpec('art', 'INTEGER', comment: '步骤插画编号'),
      ColumnSpec('image_sha256', 'TEXT', comment: '步骤实拍图'),
    ],
  ),

  // ───────────────── 家庭 ─────────────────
  TableSpec(
    name: 'member',
    scope: TableScope.business,
    comment: '家庭成员与忌口。★ 建模期就要有：后补要改菜谱/菜单/备菜/做菜四处 UI',
    columns: [
      ...kStandardColumns,
      ColumnSpec('name', 'TEXT', notNull: true),
      ColumnSpec('avatar', 'INTEGER'),
      ColumnSpec('allergens', 'TEXT',
          notNull: true, defaultSql: "'[]'", comment: 'JSON 数组，如 ["虾","花生"]'),
      ColumnSpec('dislikes', 'TEXT',
          notNull: true, defaultSql: "'[]'", comment: '不爱吃。区别于过敏：只提示，不警告'),
    ],
  ),

  // ───────────────── 计划 ─────────────────
  TableSpec(
    name: 'menu',
    scope: TableScope.business,
    comment: '某一餐的安排',
    columns: [
      ...kStandardColumns,
      ColumnSpec('day', 'TEXT',
          notNull: true, comment: 'YYYY-MM-DD（不叫 date，省得跟类型名混淆）'),
      ColumnSpec('meal', 'TEXT',
          notNull: true, comment: 'breakfast / lunch / dinner'),
      ColumnSpec('serve_at', 'TEXT', comment: '开饭时间 HH:MM，时间轴排程的输入'),
      ColumnSpec('note', 'TEXT'),
    ],
  ),
  TableSpec(
    name: 'menu_item',
    scope: TableScope.business,
    comment: '菜单里的菜',
    constraints: [
      'FOREIGN KEY (menu_id) REFERENCES menu(id)',
      'FOREIGN KEY (recipe_id) REFERENCES recipe(id)',
    ],
    columns: [
      ...kStandardColumns,
      ColumnSpec('menu_id', 'TEXT', notNull: true),
      ColumnSpec('recipe_id', 'TEXT', notNull: true),
      ColumnSpec('sort', 'INTEGER', notNull: true, defaultSql: '0'),
    ],
  ),

  // ───────────────── 做菜与库存 ─────────────────
  TableSpec(
    name: 'cook_session',
    scope: TableScope.business,
    comment: '★ 做菜模式的进度。建模期就要有，否则"被叫走再回来"接不上',
    constraints: ['FOREIGN KEY (recipe_id) REFERENCES recipe(id)'],
    columns: [
      ...kStandardColumns,
      ColumnSpec('recipe_id', 'TEXT', notNull: true),
      ColumnSpec('started_at', 'TEXT', notNull: true),
      ColumnSpec('finished_at', 'TEXT'),
      ColumnSpec('current_step', 'INTEGER', notNull: true, defaultSql: '0'),
      ColumnSpec('servings_used', 'INTEGER', comment: '这次实际做了几人份'),
      ColumnSpec('state', 'TEXT', comment: 'JSON：勾选状态、各计时器剩余秒数等'),
    ],
  ),
  TableSpec(
    name: 'pantry_item',
    scope: TableScope.business,
    comment: '食材库存。辅助决策，不是账本，允许只记有/没有',
    columns: [
      ...kStandardColumns,
      ColumnSpec('name', 'TEXT', notNull: true),
      ColumnSpec('alias_key', 'TEXT', comment: '归一键，与 ingredient.alias_key 对齐'),
      ColumnSpec('category', 'TEXT'),
      ColumnSpec('qty_value', 'REAL', comment: '可为空——允许只记"有"'),
      ColumnSpec('qty_unit', 'TEXT'),
      ColumnSpec('have', 'INTEGER',
          notNull: true, defaultSql: '1', comment: '0 / 1'),
      ColumnSpec('expire_at', 'TEXT', comment: 'YYYY-MM-DD，过期提醒用'),
      ColumnSpec('is_staple', 'INTEGER',
          notNull: true, defaultSql: '0', comment: '常备调料：不计入推荐算法的缺失'),
    ],
  ),

  // ───────────────── 热量 ─────────────────
  TableSpec(
    name: 'nutrition',
    scope: TableScope.business,
    comment: '热量估算，与 recipe 一对一。结果跨端同步，但"能不能算"各端独立',
    constraints: ['FOREIGN KEY (recipe_id) REFERENCES recipe(id)'],
    columns: [
      ...kStandardColumns,
      ColumnSpec('recipe_id', 'TEXT', notNull: true),
      ColumnSpec('per_serving_kcal', 'REAL'),
      ColumnSpec('total_kcal', 'REAL'),
      ColumnSpec('protein_g', 'REAL'),
      ColumnSpec('fat_g', 'REAL'),
      ColumnSpec('carb_g', 'REAL'),
      ColumnSpec('basis', 'TEXT', comment: 'JSON：逐食材贡献与所用分量'),
      ColumnSpec('confidence', 'REAL'),
      ColumnSpec('source', 'TEXT',
          notNull: true, defaultSql: "'ai'", comment: 'ai / manual'),
      ColumnSpec('model', 'TEXT'),
      ColumnSpec('servings_basis', 'INTEGER', comment: '按几人份算的'),
    ],
  ),

  // ───────────────── 冲突箱 ─────────────────
  TableSpec(
    name: 'conflict_item',
    scope: TableScope.business,
    comment: '冲突箱。绝不静默 LWW：同一字段两边改了不同值就必须让用户选',
    columns: [
      ...kStandardColumns,
      ColumnSpec('tbl', 'TEXT', notNull: true, comment: '哪个表'),
      ColumnSpec('row_id', 'TEXT', notNull: true, comment: '哪一行'),
      ColumnSpec('field', 'TEXT', notNull: true, comment: '哪个字段'),
      ColumnSpec('local_value', 'TEXT'),
      ColumnSpec('remote_value', 'TEXT'),
      ColumnSpec('local_hlc', 'TEXT'),
      ColumnSpec('remote_hlc', 'TEXT'),
      ColumnSpec('local_by', 'TEXT'),
      ColumnSpec('remote_by', 'TEXT'),
      ColumnSpec('resolved_at', 'TEXT', comment: 'NULL = 待用户处理'),
      ColumnSpec('resolution', 'TEXT', comment: 'local / remote / merged'),
    ],
  ),

  // ───────────────── 服务端基础设施（不参与同步）─────────────────
  TableSpec(
    name: 'change_log',
    scope: TableScope.serverOnly,
    comment: '变更日志。单调递增 seq + 设备游标 = 增量同步的全部机制',
    columns: [
      ColumnSpec('seq', 'INTEGER',
          primaryKey: true,
          autoIncrement: true,
          comment: '单调递增且永不复用（AUTOINCREMENT 保证）'),
      ColumnSpec('tbl', 'TEXT', notNull: true),
      ColumnSpec('row_id', 'TEXT', notNull: true),
      ColumnSpec('op', 'TEXT', notNull: true, comment: 'upsert / delete'),
      ColumnSpec('row_updated_at', 'TEXT', notNull: true, comment: '该行的 HLC'),
      ColumnSpec('row_updated_by', 'TEXT', notNull: true),
      ColumnSpec('logged_at', 'TEXT', notNull: true, comment: '服务端记录时间，排障用'),
    ],
  ),
  TableSpec(
    name: 'device',
    scope: TableScope.serverOnly,
    comment: '已配对的设备与它的同步游标',
    columns: [
      ColumnSpec('id', 'TEXT', primaryKey: true, comment: '设备 id（客户端生成）'),
      ColumnSpec('name', 'TEXT', notNull: true),
      ColumnSpec('token_hash', 'TEXT',
          notNull: true, comment: '只存哈希，不存明文 token'),
      ColumnSpec('sync_cursor', 'INTEGER',
          notNull: true,
          defaultSql: '0',
          comment: '已同步到 change_log 的哪个 seq（不叫 cursor，那是关键字）'),
      ColumnSpec('paired_at', 'TEXT', notNull: true),
      ColumnSpec('last_seen_at', 'TEXT'),
      ColumnSpec('revoked_at', 'TEXT'),
    ],
  ),
  TableSpec(
    name: 'pair_code',
    scope: TableScope.serverOnly,
    comment: '配对码。5 分钟有效、一次性',
    columns: [
      ColumnSpec('code', 'TEXT', primaryKey: true),
      ColumnSpec('created_at', 'TEXT', notNull: true),
      ColumnSpec('expires_at', 'TEXT', notNull: true),
      ColumnSpec('used_at', 'TEXT'),
    ],
  ),
  TableSpec(
    name: 'applied_mutation',
    scope: TableScope.serverOnly,
    comment: '已应用的推送批次。重试同一个 mutationId 必须返回同样的结果，而不是再做一遍',
    columns: [
      ColumnSpec('mutation_id', 'TEXT', primaryKey: true),
      ColumnSpec('device_id', 'TEXT', notNull: true),
      ColumnSpec('applied_at', 'TEXT', notNull: true),
      ColumnSpec('result', 'TEXT', notNull: true, comment: 'JSON：逐条变更的处理结果'),
    ],
  ),
  TableSpec(
    name: 'meta',
    scope: TableScope.serverOnly,
    comment: '键值对：schema 版本、服务端备注等',
    columns: [
      ColumnSpec('k', 'TEXT', primaryKey: true),
      ColumnSpec('v', 'TEXT', notNull: true),
    ],
  ),

  // ───────────────── 本机私有（永不外发）─────────────────
  TableSpec(
    name: 'ai_config',
    scope: TableScope.localOnly,
    comment: '★ AI 配置。单行表。API Key 只活在这里，同步接口看不见它',
    columns: [
      ColumnSpec('id', 'TEXT', primaryKey: true, comment: '固定为 "singleton"'),
      ColumnSpec('enabled', 'INTEGER', notNull: true, defaultSql: '0'),
      ColumnSpec('provider', 'TEXT'),
      ColumnSpec('base_url', 'TEXT'),
      ColumnSpec('model', 'TEXT'),
      ColumnSpec('api_key_enc', 'TEXT', comment: '加密存储；界面上永远只显示后 4 位'),
      ColumnSpec('key_hint', 'TEXT', comment: '仅用于展示的掩码，如 sk-••••3f7a'),
      ColumnSpec('monthly_limit', 'REAL'),
      ColumnSpec('flags', 'TEXT',
          notNull: true,
          defaultSql: "'{}'",
          comment: 'JSON：nutrition / recipe / recommend 三个开关'),
      ColumnSpec('saved_at', 'TEXT', notNull: true),
    ],
  ),
  TableSpec(
    name: 'ai_usage',
    scope: TableScope.localOnly,
    comment: 'AI 用量。只用来算钱，没有任何外发价值',
    columns: [
      ColumnSpec('id', 'TEXT', primaryKey: true),
      ColumnSpec('at', 'TEXT', notNull: true),
      ColumnSpec('feature', 'TEXT', notNull: true),
      ColumnSpec('model', 'TEXT'),
      ColumnSpec('prompt_tokens', 'INTEGER', notNull: true, defaultSql: '0'),
      ColumnSpec('completion_tokens', 'INTEGER',
          notNull: true, defaultSql: '0'),
      ColumnSpec('cost_est', 'REAL', notNull: true, defaultSql: '0'),
      ColumnSpec('ok', 'INTEGER', notNull: true, defaultSql: '1'),
    ],
  ),
  TableSpec(
    name: 'ai_cache',
    scope: TableScope.localOnly,
    comment: 'AI 结果缓存。相同输入不重复请求、不重复计费',
    columns: [
      ColumnSpec('cache_key', 'TEXT',
          primaryKey: true, comment: '输入内容的 sha256'),
      ColumnSpec('feature', 'TEXT', notNull: true),
      ColumnSpec('payload', 'TEXT', notNull: true, comment: 'JSON 结果原文'),
      ColumnSpec('model', 'TEXT'),
      ColumnSpec('created_at', 'TEXT', notNull: true),
    ],
  ),
  TableSpec(
    name: 'local_pref',
    scope: TableScope.localOnly,
    comment: '本机偏好键值对（收藏、悬浮按钮位置、排序档……）。'
        '是偏好不是业务数据，所以不进业务表、不走五列、永不外发',
    columns: [
      // key 是 SQLite 关键字（踩过：conflict / cursor 同类），所以叫 pref_key
      ColumnSpec('pref_key', 'TEXT', primaryKey: true),
      ColumnSpec('pref_value', 'TEXT', notNull: true, comment: 'JSON 值'),
    ],
  ),
];

/// 当前 schema 版本。**只增不减**。
///
/// v1 → v2：新增 `applied_mutation`（推送幂等）。
/// v2 → v3：新增 `local_pref`（本机偏好）。迁移仍是纯增表，
/// `CREATE TABLE IF NOT EXISTS` 天然幂等，所以不需要单独的迁移脚本。
const int kSchemaVersion = 3;

/// 同步协议的版本。客户端与服务端必须一致，否则拒绝同步而不是猜。
///
/// 它和 schema 版本是两件事：schema 描述**存什么**，协议描述**怎么聊**。
/// 两者都可能单独变化（比如协议加了字段但表没变）。
const int kSyncProtocolVersion = 1;

/// 参与同步的表 → 允许同步的列。
///
/// **它由 [kTables] 的 scope 算出来，不是手写清单。**
/// 于是 `ai_config` 不可能出现在这里——不是因为我们记得删掉它，
/// 而是因为它的 scope 不是 `business`。
Map<String, List<String>> get syncWhitelist => {
      for (final t in kTables)
        if (t.isSynced) t.name: t.columnNames,
    };

/// 本机私有表名。AI 相关的带 `ai_` 前缀；`local_pref` 是通用本机偏好。
List<String> get localOnlyTables => kTables
    .where((t) => t.scope == TableScope.localOnly)
    .map((t) => t.name)
    .toList();

/// 建表语句（含索引）。
List<String> schemaDdl() => [
      for (final t in kTables) t.createSql(),
      // 业务表索引：增量拉取按 updated_at，软删除过滤按 deleted_at
      for (final t in kTables)
        if (t.isSynced) ...[
          'CREATE INDEX IF NOT EXISTS idx_${t.name}_updated ON ${t.name}(updated_at);',
          'CREATE INDEX IF NOT EXISTS idx_${t.name}_alive ON ${t.name}(deleted_at);',
        ],
      // change_log 按表筛是热路径
      'CREATE INDEX IF NOT EXISTS idx_change_log_tbl ON change_log(tbl, seq);',
      'CREATE INDEX IF NOT EXISTS idx_device_token ON device(token_hash);',
    ];

/// 表之间的写入顺序（父表在前）。
///
/// 同步落库必须按它来，否则外键会挡住。
/// **新增表时请加进 `_declaredOrder`**；忘了加也不会被悄悄漏掉——
/// 未列出的表会被补在末尾，且有一条测试盯着「所有业务表都在顺序里且父表在前」。
List<String> get applyOrder {
  final names = kTables.map((t) => t.name).toSet();
  return [
    ..._declaredOrder.where(names.contains),
    ...names.difference(_declaredOrder.toSet()),
  ];
}

const List<String> _declaredOrder = [
  'recipe',
  'ingredient',
  'step',
  'member',
  'menu',
  'menu_item',
  'cook_session',
  'pantry_item',
  'nutrition',
  'conflict_item',
];
