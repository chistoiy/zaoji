import 'db.dart';

/// R44 · 可编辑提示词的存储层（`ai_prompts`，serverOnly）。
///
/// 一行一能力。列值为 NULL = 该能力这一侧用内置默认；
/// **恢复默认 = 删掉整行**，不做「默认值也存一份」的双份存储——
/// 内置默认的唯一权威在 [AiService] 的能力方法里（见 ai.dart 的 kDefaultPrompts）。
///
/// 为什么覆盖存在服务端而不是 server_setting kv：kv 是一整坨 JSON，
/// 逐能力改/查/删都要读改写整坨、并发下容易互相踩；`ai_prompts` 一行一能力，
/// 单条 UPDATE 就是原子的，且天然是「三能力 × system/user」这张矩阵的形状。

abstract class PromptStore {
  /// 该能力的覆盖；null = 没覆盖（回落默认）。
  ({String? system, String? user})? get(String feature);

  /// 全部覆盖行（GET /api/ai/prompts 用）。
  List<({String feature, String? system, String? user, int updatedAt})> all();

  /// 写入覆盖。system/user 传 null 表示这一侧回落默认。
  void put(String feature, {String? system, String? user});

  /// 删覆盖 = 恢复默认。返回删除条数。
  int reset(String feature);
}

class DbPromptStore implements PromptStore {
  final ZaojiDb db;
  DbPromptStore(this.db);

  @override
  ({String? system, String? user})? get(String feature) {
    final rs = db.db.select(
      'SELECT system_tpl, user_tpl FROM ai_prompts WHERE feature = ?',
      [feature],
    );
    if (rs.isEmpty) return null;
    final r = rs.first;
    return (
      system: r['system_tpl'] == null ? null : '${r['system_tpl']}',
      user: r['user_tpl'] == null ? null : '${r['user_tpl']}',
    );
  }

  @override
  List<({String feature, String? system, String? user, int updatedAt})> all() {
    final rs = db.db.select(
      'SELECT feature, system_tpl, user_tpl, updated_at FROM ai_prompts ORDER BY feature',
    );
    return [
      for (final r in rs)
        (
          feature: '${r['feature']}',
          system: r['system_tpl'] == null ? null : '${r['system_tpl']}',
          user: r['user_tpl'] == null ? null : '${r['user_tpl']}',
          updatedAt: r['updated_at'] as int,
        ),
    ];
  }

  @override
  void put(String feature, {String? system, String? user}) {
    db.db.execute(
      'INSERT INTO ai_prompts (feature, system_tpl, user_tpl, updated_at) '
      'VALUES (?, ?, ?, ?) '
      'ON CONFLICT(feature) DO UPDATE SET system_tpl = excluded.system_tpl, '
      'user_tpl = excluded.user_tpl, updated_at = excluded.updated_at',
      [feature, system, user, DateTime.now().millisecondsSinceEpoch],
    );
  }

  @override
  int reset(String feature) {
    final before = db.db
        .select('SELECT 1 FROM ai_prompts WHERE feature = ?', [feature])
        .length;
    db.db.execute('DELETE FROM ai_prompts WHERE feature = ?', [feature]);
    return before;
  }
}
