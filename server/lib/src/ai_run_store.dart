import 'db.dart';

/// R44 · AI 执行记录的存储层。
///
/// 记录落在服务端自己的 `ai_runs`（serverOnly）——**AI 是代理单模架构，
/// 只有这里拿得到渲染后的完整 prompt 与上游原始输出**，所以权威留痕
/// 只能在服务端，不在任何客户端。客户端的 localOnly `ai_usage` 只是
/// 本机视角的对账副本（run_ref 指回这里的 id）。
///
/// 三条纪律：
/// ① 记录**永不参与同步**（serverOnly 结构性保证，同 change_log/device）；
/// ② Key 与配置值不写进任何列——调用方只传 prompt 文本与结果；
/// ③ 记录失败绝不许炸掉 AI 调用本身（[AiService] 侧全部 try/catch）。

/// 一条执行记录。列与 `ai_runs` 表一一对应。
class AiRunRow {
  /// 服务端自增 id；插入后回写，响应体带它给客户端对账（run_ref）。
  int? id;

  /// 毫秒时间戳。保留窗口修剪与列表排序都按它（不认客户端时钟）。
  late int at;
  String feature; // calories / recipe_fill / recommend / test
  String? model;
  String? promptSystem; // 输入留痕①：渲染后的最终 system
  String? promptUser; // 输入留痕②：渲染后的最终 user
  String? inputJson; // 客户端传来的原始参数（喂了什么数据）
  String? output; // 成功 = 结果 JSON 原文；失败 = 错误文案
  bool ok;
  String? errorKind; // off/auth/timeout/model/http/network/parse
  bool cached; // 命中结果缓存：没走上游，用量列不计数
  int inTok;
  int outTok;
  int durationMs;
  String? source; // android / web / server-test

  AiRunRow({
    int? at,
    required this.feature,
    this.model,
    this.promptSystem,
    this.promptUser,
    this.inputJson,
    this.output,
    this.ok = true,
    this.errorKind,
    this.cached = false,
    this.inTok = 0,
    this.outTok = 0,
    this.durationMs = 0,
    this.source,
  }) : at = at ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, Object?> toJson({bool full = true}) => {
        'id': id,
        'at': at,
        'feature': feature,
        'model': model,
        'ok': ok,
        'errorKind': errorKind,
        'cached': cached,
        'inTok': inTok,
        'outTok': outTok,
        'durationMs': durationMs,
        'source': source,
        // 列表只给摘要：全文留在详情，翻页载荷不跟着 prompt 体积涨
        if (full) ...{
          'promptSystem': promptSystem,
          'promptUser': promptUser,
          'inputJson': inputJson,
          'output': output,
        } else ...{
          'promptExcerpt': _clip(promptUser, 120),
          'outputExcerpt': _clip(output, 120),
        },
      };

  static String _clip(String? s, int n) {
    final t = (s ?? '').replaceAll('\n', ' ');
    return t.length <= n ? t : '${t.substring(0, n)}…';
  }
}

/// 列表查询的筛选条件。空值 = 不限。
class RunFilter {
  final String? feature;
  final bool? ok;
  final String? q; // 关键词：prompt 与输出里 LIKE
  final int? sinceMs;
  final int? beforeMs;
  final int limit;
  final int offset;

  const RunFilter({
    this.feature,
    this.ok,
    this.q,
    this.sinceMs,
    this.beforeMs,
    this.limit = 50,
    this.offset = 0,
  });

  static int? parseMs(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    // 同时收毫秒数与 ISO 串：手机传哪样都不至于静默失效
    final i = int.tryParse('$v');
    if (i != null) return i;
    return DateTime.tryParse('$v')?.millisecondsSinceEpoch;
  }

  RunFilter fromQuery(Map<String, String> g) => RunFilter(
        feature: g['feature'],
        ok: g['ok'] == null ? null : g['ok'] == '1' || g['ok'] == 'true',
        q: (g['q'] ?? '').trim().isEmpty ? null : g['q']!.trim(),
        sinceMs: parseMs(g['since']),
        beforeMs: parseMs(g['before']),
        limit: (int.tryParse(g['limit'] ?? '') ?? 50).clamp(1, 200),
        offset: int.tryParse(g['offset'] ?? '') ?? 0,
      );
}

/// 窄接口（与 [SettingStore] 同一立场：测试可以拿内存版跑，不碰 sqlite）。
abstract class RunStore {
  /// 插入并回写 row.id，返回 id。
  int insert(AiRunRow row);

  /// 按筛选取列表 + 命中的总条数（分页要用总数）。
  ({List<AiRunRow> rows, int total}) query(RunFilter f);

  AiRunRow? get(int id);

  /// 返回删除条数。
  int deleteOne(int id);

  /// 按筛选清空（全空 = 不带筛选）。返回删除条数。
  int deleteWhere(RunFilter f);

  /// 修剪：先删过期（keepMs 之前），再把超容量的旧行砍到 cap。返回删除条数。
  int prune({required int keepMs, required int cap});

  int count();

  /// 聚合某时刻（含）之后的**真实上游成功调用**用量（FR-AI-68）。
  /// 只数 ok=1 且 cached=0 的行——失败与缓存命中都不该计次、不计费。
  ({int calls, int inTok, int outTok}) aggregate({required int sinceMs});
}

/// `ai_runs` 的 sqlite 实现。
class DbRunStore implements RunStore {
  final ZaojiDb db;
  DbRunStore(this.db);

  static const _cols =
      'id, at, feature, model, prompt_system, prompt_user, input_json, output, '
      'ok, error_kind, cached, in_tok, out_tok, duration_ms, source';

  static AiRunRow _row(Object? r) {
    final m = (r as Map).cast<String, Object?>();
    int n(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;
    return AiRunRow(
      at: n(m['at']),
      feature: '${m['feature']}',
      model: m['model'] == null ? null : '${m['model']}',
      promptSystem: m['prompt_system'] == null ? null : '${m['prompt_system']}',
      promptUser: m['prompt_user'] == null ? null : '${m['prompt_user']}',
      inputJson: m['input_json'] == null ? null : '${m['input_json']}',
      output: m['output'] == null ? null : '${m['output']}',
      ok: m['ok'] == 1 || m['ok'] == true,
      errorKind: m['error_kind'] == null ? null : '${m['error_kind']}',
      cached: m['cached'] == 1 || m['cached'] == true,
      inTok: n(m['in_tok']),
      outTok: n(m['out_tok']),
      durationMs: n(m['duration_ms']),
      source: m['source'] == null ? null : '${m['source']}',
    )..id = n(m['id']);
  }

  @override
  int insert(AiRunRow row) {
    db.db.execute(
      'INSERT INTO ai_runs (at, feature, model, prompt_system, prompt_user, '
      'input_json, output, ok, error_kind, cached, in_tok, out_tok, duration_ms, source) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        row.at,
        row.feature,
        row.model,
        row.promptSystem,
        row.promptUser,
        row.inputJson,
        row.output,
        row.ok ? 1 : 0,
        row.errorKind,
        row.cached ? 1 : 0,
        row.inTok,
        row.outTok,
        row.durationMs,
        row.source,
      ],
    );
    final id = db.db.lastInsertRowId;
    row.id = id;
    return id;
  }

  /// WHERE 片段 + 参数。查询与「按条件清空」共用一份——
  /// 两处各写一遍迟早漂移成「筛出来的条数和删掉的条数不一样」。
  ({String sql, List<Object?> args}) _where(RunFilter f) {
    final parts = <String>[];
    final args = <Object?>[];
    if (f.feature != null) {
      parts.add('feature = ?');
      args.add(f.feature);
    }
    if (f.ok != null) {
      parts.add('ok = ?');
      args.add(f.ok! ? 1 : 0);
    }
    if (f.sinceMs != null) {
      parts.add('at >= ?');
      args.add(f.sinceMs);
    }
    if (f.beforeMs != null) {
      parts.add('at <= ?');
      args.add(f.beforeMs);
    }
    if (f.q != null) {
      // 关键词搜索用 instr() 做**纯字面子串**匹配：
      // LIKE 的通配符（% _）与 ESCAPE 反斜杠在 SQLite 字符串里处理很绕，
      // 用户搜「100%」「A_B」会意外变成通配——instr 没有这套语义，天然安全。
      final cols = ['prompt_user', 'prompt_system', 'output', 'model'];
      parts.add('(${cols.map((c) => 'instr($c, ?) > 0').join(' OR ')})');
      for (var i = 0; i < cols.length; i++) {
        args.add(f.q);
      }
    }
    return (sql: parts.isEmpty ? '' : 'WHERE ${parts.join(' AND ')}', args: args);
  }

  @override
  ({List<AiRunRow> rows, int total}) query(RunFilter f) {
    final w = _where(f);
    final total = db
        .db
        .select('SELECT COUNT(*) AS c FROM ai_runs ${w.sql}', w.args)
        .first['c'] as int;
    final rs = db.db.select(
      'SELECT $_cols FROM ai_runs ${w.sql} ORDER BY at DESC, id DESC LIMIT ? OFFSET ?',
      [...w.args, f.limit, f.offset],
    );
    return (rows: rs.map(_row).toList(), total: total);
  }

  @override
  AiRunRow? get(int id) {
    final rs = db.db.select('SELECT $_cols FROM ai_runs WHERE id = ?', [id]);
    return rs.isEmpty ? null : _row(rs.first);
  }

  @override
  int deleteOne(int id) {
    final before = count();
    db.db.execute('DELETE FROM ai_runs WHERE id = ?', [id]);
    return before - count();
  }

  @override
  int deleteWhere(RunFilter f) {
    final w = _where(f);
    final before = count();
    db.db.execute('DELETE FROM ai_runs ${w.sql}', w.args);
    return before - count();
  }

  @override
  int prune({required int keepMs, required int cap}) {
    var deleted = 0;
    if (keepMs > 0) {
      final cutoff = DateTime.now().millisecondsSinceEpoch - keepMs;
      final before = count();
      db.db.execute('DELETE FROM ai_runs WHERE at < ?', [cutoff]);
      deleted += before - count();
    }
    final n = count();
    if (cap > 0 && n > cap) {
      // 按 (at, id) 升序砍最老的：与列表的倒序判据一致，不会出现
      // 「刚被修剪掉的正是下一页要给的」
      final before = count();
      db.db.execute(
        'DELETE FROM ai_runs WHERE id IN ('
        'SELECT id FROM ai_runs ORDER BY at ASC, id ASC LIMIT ?)',
        [n - cap],
      );
      deleted += before - count();
    }
    return deleted;
  }

  @override
  int count() => db.db.select('SELECT COUNT(*) AS c FROM ai_runs').first['c'] as int;

  @override
  ({int calls, int inTok, int outTok}) aggregate({required int sinceMs}) {
    final r = db.db.select(
      'SELECT COUNT(*) AS calls, '
      'COALESCE(SUM(in_tok), 0) AS in_tok, '
      'COALESCE(SUM(out_tok), 0) AS out_tok '
      'FROM ai_runs WHERE ok = 1 AND cached = 0 AND at >= ?',
      [sinceMs],
    ).first;
    int n(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;
    return (calls: n(r['calls']), inTok: n(r['in_tok']), outTok: n(r['out_tok']));
  }
}
