import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import 'db.dart';

/// 同步服务：配对、鉴权、增量拉取、增量推送。
///
/// ## 这一层最容易做错的三件事
///
/// **① 白名单必须是"取"出来的，不是"判"出来的。**
/// 下发一行数据时，`SELECT` 的列名直接来自 [syncWhitelist]，
/// 而不是 `SELECT *` 之后再删字段。两者的区别在出事时才会显现：
/// 前者**不可能**漏出没登记过的列，后者要靠每一处记得删。
///
/// **② 拉取的游标在客户端，不在服务端。**
/// `device.sync_cursor` 只是服务端记的"这台设备上次报到哪儿"，
/// 用来在界面上显示，**不作为拉取依据**。
/// 让服务端持有游标会引入一整类 bug：客户端清了本地库、游标却还在服务端，
/// 于是它永远同步不到旧数据，而且服务端认为一切正常。
///
/// **③ 推送必须幂等，且幂等要靠"记住做过"而不是"结果碰巧一样"。**
/// 客户端在网络超时后会重试同一个 `mutationId`。
/// 行写入本身是 UPSERT、重复执行无害，但**冲突箱会收到两条**、
/// 返回值也会不一致。所以有一个 `applied_mutation` 表记住批次结果。
class SyncService {
  final ZaojiDb db;
  final String serverId;

  /// 注入时间，便于测试配对码过期。
  final DateTime Function() now;

  SyncService(this.db, this.serverId, {DateTime Function()? now})
      : now = now ?? DateTime.now;

  static const Duration pairCodeTtl = Duration(minutes: 5);

  /// 配对码字母表：去掉 0/O/1/I/L 这些抄下来会认错的字符。
  /// 用户要拿着手机照着电脑屏幕输，一次认错就得重来。
  static const String _codeAlphabet = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
  static const int _codeLength = 6;

  // ───────────────────────── 配对限流 ─────────────────────────
  // R12 新增。配对码空间 31^6 ≈ 8.9×10⁸、有效期 5 分钟——不限流的话，
  // 局域网里的攻击者可以在窗口内高速枚举。这里按来源记失败次数：
  // 窗口内失败满 N 次就暂时拒绝，**成功配对会清空记录**（不惩罚手滑）。

  /// 一个窗口内允许的失败次数。第 6 次起拒绝。
  static const int maxPairFailsPerWindow = 5;

  /// 失败计数的滑动窗口。
  static const Duration pairFailWindow = Duration(minutes: 1);

  final Map<String, List<DateTime>> _pairFails = {};

  /// 这个来源当前是否因连续失败而被暂时拒绝。
  bool pairBlocked(String peer) {
    final fails = _pairFails[peer];
    if (fails == null) return false;
    final cut = now().subtract(pairFailWindow);
    fails.removeWhere((t) => t.isBefore(cut));
    if (fails.isEmpty) {
      _pairFails.remove(peer);
      return false;
    }
    return fails.length >= maxPairFailsPerWindow;
  }

  /// 记一次配对失败。**只记真实的猜测**（码错/过期/用过），
  /// 参数残缺（400 类）不算——那是客户端 bug，不是暴力枚举。
  void recordPairFail(String peer) {
    final cut = now().subtract(pairFailWindow);
    final fails = _pairFails.putIfAbsent(peer, () => []);
    fails.removeWhere((t) => t.isBefore(cut));
    fails.add(now());
  }

  /// 配对成功后调用：清空这个来源的失败记录。
  void clearPairFails(String peer) => _pairFails.remove(peer);

  // ───────────────────────── 数据清理 ─────────────────────────

  /// 清理过期数据，返回删除的行数（用于日志）。
  ///
  /// | 表 | 策略 | 为什么 |
  /// |---|---|---|
  /// | `pair_code` | 过期 24h 后删 | 过期码已经没用了；留 24h 是为了让"过期了"的错误提示仍能给出 |
  /// | `applied_mutation` | 保留 7 天 | 幂等重试只发生在秒/分钟级；7 天前的重放会重新执行一次（行 UPSERT 无害，只是冲突箱可能多一条），可接受 |
  ///
  /// **`change_log` 刻意不在这里清**：裁剪它必须先有「快照拉取」——
  /// 新设备配对后从 seq 0 开始拉，裁掉的变更它就永远拿不到了。
  /// change_log 每行只有几十字节（不含载荷，载荷是拉取时按行取的），
  /// 家庭规模下一年也就几 MB，不值得为省这点空间引入快照协议。
  /// 磁盘增长的大头本来就是 applied_mutation（存整批结果 JSON）。
  int cleanup({
    Duration pairCodeRetention = const Duration(hours: 24),
    Duration mutationRetention = const Duration(days: 7),
  }) {
    final t = now();
    var deleted = 0;
    db.db.execute('BEGIN');
    try {
      db.db.execute('DELETE FROM pair_code WHERE expires_at < ?',
          [t.subtract(pairCodeRetention).toIso8601String()]);
      deleted += _changesCount();
      db.db.execute('DELETE FROM applied_mutation WHERE applied_at < ?',
          [t.subtract(mutationRetention).toIso8601String()]);
      deleted += _changesCount();
      db.db.execute('COMMIT');
    } catch (_) {
      db.db.execute('ROLLBACK');
      rethrow;
    }
    return deleted;
  }

  int _changesCount() =>
      db.db.select('SELECT changes() AS c').first['c'] as int;

  // ───────────────────────── 配对 ─────────────────────────

  /// 生成一个新的配对码。旧码不主动作废（可能同时在多台设备上输），
  /// 但每个码是一次性的。
  PairCode issuePairCode() {
    final rnd = Random.secure();
    String code;
    // 撞码概率极低，但"极低"不等于不会——库里有主键，撞了就重来
    do {
      code = List.generate(
        _codeLength,
        (_) => _codeAlphabet[rnd.nextInt(_codeAlphabet.length)],
      ).join();
    } while (_findPairCode(code) != null);

    final createdAt = now();
    final expiresAt = createdAt.add(pairCodeTtl);
    db.db.execute(
      'INSERT INTO pair_code (code, created_at, expires_at) VALUES (?, ?, ?)',
      [code, createdAt.toIso8601String(), expiresAt.toIso8601String()],
    );
    return PairCode(code: code, createdAt: createdAt, expiresAt: expiresAt);
  }

  /// 用配对码换 token。
  ///
  /// 失败时**返回原因而不是 null** —— 用户必须能区分"码输了"与"码过期了"，
  /// 否则他只会一遍遍重输同一个码。
  PairOutcome redeem({
    required String code,
    required String deviceId,
    required String deviceName,
  }) {
    final normalized = code.trim().toUpperCase();
    if (normalized.isEmpty) {
      return const PairOutcome.failure(PairFailure.emptyCode);
    }
    if (deviceId.trim().isEmpty) {
      return const PairOutcome.failure(PairFailure.missingDeviceId);
    }

    final row = _findPairCode(normalized);
    if (row == null) {
      return const PairOutcome.failure(PairFailure.unknownCode);
    }
    if (row['used_at'] != null) {
      return const PairOutcome.failure(PairFailure.codeAlreadyUsed);
    }
    final expiresAt = DateTime.tryParse('${row['expires_at']}');
    if (expiresAt == null || now().isAfter(expiresAt)) {
      return const PairOutcome.failure(PairFailure.codeExpired);
    }

    final token = _newToken();
    db.db.execute(
      'INSERT INTO device (id, name, token_hash, sync_cursor, paired_at) '
      'VALUES (?, ?, ?, 0, ?) '
      'ON CONFLICT(id) DO UPDATE SET name = excluded.name, '
      'token_hash = excluded.token_hash, revoked_at = NULL',
      [
        deviceId,
        deviceName.trim().isEmpty ? '未命名设备' : deviceName.trim(),
        hashToken(token),
        now().toIso8601String()
      ],
    );
    db.db.execute(
      'UPDATE pair_code SET used_at = ? WHERE code = ?',
      [now().toIso8601String(), normalized],
    );

    return PairOutcome.success(
      token: token,
      deviceId: deviceId,
      serverId: serverId,
      protocolVersion: kSyncProtocolVersion,
    );
  }

  /// 从 `Authorization: Bearer <token>` 解析设备。认不出返回 null。
  Device? authenticate(String? authorizationHeader) {
    final token = _bearerToken(authorizationHeader);
    if (token == null) return null;

    final rs = db.db.select(
      'SELECT id, name, sync_cursor, paired_at, last_seen_at, revoked_at '
      'FROM device WHERE token_hash = ?',
      [hashToken(token)],
    );
    if (rs.isEmpty) return null;

    final d = _deviceOf(rs.first);
    if (d.revokedAt != null) return null;

    db.db.execute(
      'UPDATE device SET last_seen_at = ? WHERE id = ?',
      [now().toIso8601String(), d.id],
    );
    return d;
  }

  static String? _bearerToken(String? header) {
    if (header == null) return null;
    final v = header.trim();
    const prefix = 'Bearer ';
    if (v.length <= prefix.length) return null;
    if (v.substring(0, prefix.length).toLowerCase() != prefix.toLowerCase()) {
      return null;
    }
    final token = v.substring(prefix.length).trim();
    return token.isEmpty ? null : token;
  }

  /// token 只存哈希。库被人看到也换不回 token。
  static String hashToken(String token) =>
      sha256.convert(utf8.encode(token)).toString();

  static String _newToken() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(32, (_) => rnd.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  // ───────────────────────── 拉取 ─────────────────────────

  /// 自 `since` 之后的变更，带上每一行的**完整载荷**。
  ///
  /// 为什么载荷要跟着变更一起返回，而不是让客户端再逐条去取：
  /// 一次同步可能要拉几百条，逐条取就是几百个请求——
  /// 在家里那台笔记本上这不是性能问题，是"手机切后台就断"的问题。
  ///
  /// 如果某条变更对应的行已经不在了（理论上不该发生，因为我们只软删除），
  /// 就只返回 `op: delete` 而不带载荷——宁可让客户端记一个墓碑，
  /// 也不要让它以为拿到了数据。
  PullResult pull({required int since, int limit = 500}) {
    final entries = db.changesSince(since, limit: limit);
    final maxSeq = db.maxSeq;

    final changes = <Map<String, Object?>>[];
    for (final e in entries) {
      // ★ 非白名单表**整条不下发**，而不是"下发但不给载荷"。
      // 差别在于：后者会告诉客户端"这里有个你不认识的表变了"，
      // 前者让客户端**根本不知道它存在**。对 ai_config 这种本机私有表，
      // 前者才是我们想要的保证。
      if (!syncWhitelist.containsKey(e.tbl)) continue;

      final row = _rowPayload(e.tbl, e.rowId);
      changes.add({
        'seq': e.seq,
        'tbl': e.tbl,
        'rowId': e.rowId,
        'op': row == null ? 'delete' : e.op,
        'updatedAt': e.rowUpdatedAt,
        'updatedBy': e.rowUpdatedBy,
        if (row != null) 'row': row,
      });
    }

    // 游标要按**未过滤的**原始页来推进：跳过的那几条也得算进去，
    // 否则客户端每次都会重新拉一遍同一批被跳过的条目，卡在那里不动。
    final lastSeq = entries.isEmpty ? since : entries.last.seq;
    return PullResult(
      serverId: serverId,
      protocolVersion: kSyncProtocolVersion,
      fromSeq: since,
      lastSeq: lastSeq,
      nowSeq: maxSeq,
      hasMore: lastSeq < maxSeq,
      changes: changes,
    );
  }

  /// 取一行的载荷。**列名来自白名单，不是 `SELECT *`。**
  ///
  /// 不在同步白名单里的表返回 null —— 注意这不只是"过滤"，
  /// 而是让 `ai_config` 之类的表**在物理上无法**从这里漏出去。
  Map<String, Object?>? _rowPayload(String tbl, String rowId) {
    final cols = syncWhitelist[tbl];
    if (cols == null) return null;

    // cols 来自我们自己代码里的常量，不是用户输入，拼进 SQL 是安全的
    final rs = db.db.select(
      'SELECT ${cols.join(', ')} FROM $tbl WHERE id = ?',
      [rowId],
    );
    if (rs.isEmpty) return null;
    return {for (final c in cols) c: rs.first[c]};
  }

  /// 记下"这台设备报到哪儿了"。**只是账面对账，不用作拉取依据。**
  void noteCursor(String deviceId, int seq) {
    db.db.execute(
      'UPDATE device SET sync_cursor = ? WHERE id = ? AND sync_cursor < ?',
      [seq, deviceId, seq],
    );
  }

  // ───────────────────────── 推送 ─────────────────────────

  /// 应用一批客户端变更。
  ///
  /// 幂等：同一个 `mutationId` 重复到达时，直接返回上次的结果，不重做。
  PushResult push({
    required Device device,
    required String mutationId,
    required List<Map<String, Object?>> changes,
  }) {
    if (mutationId.trim().isEmpty) {
      return const PushResult.rejected('mutationId 不能为空');
    }

    final cached = _loadMutation(mutationId);
    if (cached != null) {
      return PushResult(
        mutationId: mutationId,
        results: cached.results,
        replayed: true,
      );
    }

    // 整批一个事务：要么全成，要么全不成。
    // 半途失败又不回滚，会让客户端拿到"部分成功"的结果而无法重试
    // ——因为重试会被幂等表挡住。
    final results = <Map<String, Object?>>[];
    db.db.execute('BEGIN');
    try {
      for (final c in changes) {
        // 逐条兜住数据库层的拒绝（NOT NULL、外键等）。
        // SQLite 里一条语句失败不会让整个事务失效，所以其余条目可以照常应用——
        // 这正是我们要的：客户端有一条脏数据，不该让整批永远推不上去。
        try {
          results.add(_applyOne(device, c));
        } on SqliteException catch (e) {
          results.add({
            'tbl': '${c['tbl']}',
            'rowId': '${c['rowId']}',
            'outcome': 'rejected',
            'reason': '数据库拒绝：${e.message}',
          });
        }
      }
      _saveMutation(mutationId, device.id, results);
      db.db.execute('COMMIT');
    } catch (_) {
      db.db.execute('ROLLBACK');
      rethrow;
    }

    return PushResult(
        mutationId: mutationId, results: results, replayed: false);
  }

  Map<String, Object?> _applyOne(Device device, Map<String, Object?> change) {
    final tbl = change['tbl'];
    if (tbl is! String || !syncWhitelist.containsKey(tbl)) {
      // 不在白名单的表直接拒绝。
      // 这条分支可能因为客户端版本旧（加了新表而服务端没升）而触发，
      // 所以要明确告诉它"我这儿没这张表"，而不是静默丢掉。
      return {
        'tbl': '$tbl',
        'rowId': '${change['rowId']}',
        'outcome': 'rejected',
        'reason': '未知或不允许同步的表：$tbl',
      };
    }

    final allowed = syncWhitelist[tbl]!;
    final row = change['row'];
    if (row is! Map) {
      return {
        'tbl': tbl,
        'rowId': '${change['rowId']}',
        'outcome': 'rejected',
        'reason': 'upsert 必须带 row',
      };
    }
    final incoming = row.map((k, v) => MapEntry('$k', v));

    // ★ 白名单在这里真正起作用：多出来的列一律拒绝。
    // 这挡住的是"某个版本不小心把不该同步的字段塞进了请求体"。
    final unknown = incoming.keys.where((k) => !allowed.contains(k)).toList()
      ..sort();
    if (unknown.isNotEmpty) {
      return {
        'tbl': tbl,
        'rowId': '${change['rowId']}',
        'outcome': 'rejected',
        'reason': '包含不允许同步的列：${unknown.join(', ')}',
      };
    }

    final rowId = '${change['rowId'] ?? incoming['id'] ?? ''}';
    if (rowId.isEmpty) {
      return {
        'tbl': tbl,
        'rowId': '',
        'outcome': 'rejected',
        'reason': '缺少 id'
      };
    }

    final op = '${change['op'] ?? 'upsert'}';
    final existing = _existingRow(tbl, rowId, allowed);

    if (op == 'delete') {
      if (existing == null) {
        return {
          'tbl': tbl,
          'rowId': rowId,
          'outcome': 'skipped',
          'reason': '要删的行不存在（可能已经删过了）'
        };
      }
      if (existing['deleted_at'] != null) {
        return {
          'tbl': tbl,
          'rowId': rowId,
          'outcome': 'skipped',
          'reason': '已经是删除态'
        };
      }
      final hlc = _mintHlc();
      db.db.execute(
        'UPDATE $tbl SET deleted_at = ?, updated_at = ?, updated_by = ?, rev = ? WHERE id = ?',
        [now().toIso8601String(), hlc, device.id, _revOf(existing) + 1, rowId],
      );
      return {
        'tbl': tbl,
        'rowId': rowId,
        'outcome': 'deleted',
        'seq': _log(tbl, rowId, 'delete', hlc, device.id),
      };
    }

    // ★ upsert 必须是**完整行**。
    //
    // 为什么不能容忍缺列（"缺的当 null 写"）：那会让两件事同时出错。
    // ① 更新时把客户端没提到的字段**清成 null** —— 静默丢数据；
    // ② 冲突判定里"未提供"和"改成 null"长得一模一样，
    //    于是字段级合并会误判出一堆假冲突（conflict.dart 开头就警告过这件事：
    //    没有基线时无法区分"字段被删除"和"字段从未存在过"）。
    // 客户端从自己的表里读出来本来就是完整的，所以这个要求不增加任何负担。
    final missing = allowed.where((c) => !incoming.containsKey(c)).toList();
    if (missing.isNotEmpty) {
      return {
        'tbl': tbl,
        'rowId': rowId,
        'outcome': 'rejected',
        'reason': 'upsert 必须带完整行，缺少这些列：${missing.join(', ')}',
      };
    }

    // ★ 值类型必须能进 SQLite。
    //   jsonDecode 能产出 bool / List / Map，而这些类型绑定参数时会抛
    //   ArgumentError——它**不是** SqliteException，上面的逐条兜底接不住，
    //   会把整批变成 500 + 回滚（R6 修过一次「一条坏数据带走整批」，
    //   这是同一个教训的另一种形态）。所以在绑定之前把这类条目拒掉。
    final badTyped = incoming.entries
        .where((e) =>
            e.value != null &&
            e.value is! String &&
            e.value is! int &&
            e.value is! double)
        .map((e) => e.key)
        .toList()
      ..sort();
    if (badTyped.isNotEmpty) {
      return {
        'tbl': tbl,
        'rowId': rowId,
        'outcome': 'rejected',
        'reason': '这些列的值类型不能入库（只接受文本/数字/null）：${badTyped.join(', ')}',
      };
    }

    // 完整行已保证，直接按白名单取列即可
    final merged = <String, Object?>{
      for (final c in allowed)
        if (c != 'id') c: incoming[c],
    };

    if (existing == null) {
      final hlc = _mintHlc();
      _writeRow(tbl, allowed, rowId, merged, hlc, device.id, 1);
      return {
        'tbl': tbl,
        'rowId': rowId,
        'outcome': 'inserted',
        'seq': _log(tbl, rowId, 'upsert', hlc, device.id),
      };
    }

    // ── 已存在：交给 shared 的冲突判定，不自己写一套 ──
    final base = _snapshotOf(change['base'], allowed);
    final resolution = resolveConflict(
      local: _snapshotOf(existing, allowed)!, // local = 服务端现存
      remote: _snapshotOf(incoming, allowed)!, // remote = 客户端推来的
      base: base,
    );

    if (resolution.kind == ConflictKind.identical) {
      return {
        'tbl': tbl,
        'rowId': rowId,
        'outcome': 'skipped',
        'reason': '两边一致'
      };
    }
    if (resolution.kind == ConflictKind.takeLocal) {
      // 客户端这份没有带来任何变化（可能只是重放了旧包）
      return {
        'tbl': tbl,
        'rowId': rowId,
        'outcome': 'skipped',
        'reason': '没有新变化'
      };
    }

    final hlc = _mintHlc();
    final nextRev = _revOf(existing) + 1;
    final fieldPatch = resolution.fields ?? incoming;
    for (final c in allowed) {
      if (c == 'id' || c == 'updated_at' || c == 'updated_by' || c == 'rev')
        continue;
      if (c == 'deleted_at') continue; // 删除只走上面的 delete 分支
      if (fieldPatch.containsKey(c))
        merged[c] = fieldPatch[c];
      else if (incoming.containsKey(c)) merged[c] = incoming[c];
    }
    _writeRow(tbl, allowed, rowId, merged, hlc, device.id, nextRev);

    final seq = _log(tbl, rowId, 'upsert', hlc, device.id);

    if (resolution.kind == ConflictKind.manual) {
      _openConflict(
        device: device,
        tbl: tbl,
        rowId: rowId,
        fields: resolution.conflictingFields,
        existing: existing,
        incoming: incoming,
        resolution: resolution,
      );
      return {
        'tbl': tbl,
        'rowId': rowId,
        'outcome': 'conflict',
        'conflictingFields': resolution.conflictingFields,
        'preferredSide': resolution.preferredSide,
        'seq': seq,
      };
    }

    return {
      'tbl': tbl,
      'rowId': rowId,
      'outcome':
          resolution.kind == ConflictKind.autoMerged ? 'merged' : 'updated',
      'seq': seq,
    };
  }

  /// 服务端自己盖一个 HLC。
  ///
  /// 为什么不沿用客户端的时间戳：合并结果（尤其是自动合并）是**服务端产生的
  /// 新状态**，不同客户端可能对同一行给出不同判断；由服务端盖章才能让所有端
  /// 收敛到同一个结论。`updated_by` 仍然记推送的设备——那是"谁促成的"。
  String _mintHlc() => Hlc.now(serverId).encode();

  int _revOf(Map<String, Object?> row) {
    final v = row['rev'];
    if (v is int) return v;
    return int.tryParse('$v') ?? 0;
  }

  Map<String, Object?>? _existingRow(
      String tbl, String rowId, List<String> cols) {
    final rs = db.db.select(
      'SELECT ${cols.join(', ')} FROM $tbl WHERE id = ?',
      [rowId],
    );
    if (rs.isEmpty) return null;
    return {for (final c in cols) c: rs.first[c]};
  }

  void _writeRow(
    String tbl,
    List<String> cols,
    String rowId,
    Map<String, Object?> values,
    String hlc,
    String updatedBy,
    int rev,
  ) {
    final all = <String, Object?>{
      ...values,
      'id': rowId,
      'updated_at': hlc,
      'updated_by': updatedBy,
      'rev': rev,
    };
    final use = cols.where(all.containsKey).toList();
    final placeholders = List.filled(use.length, '?').join(', ');
    final updates =
        use.where((c) => c != 'id').map((c) => '$c = excluded.$c').join(', ');
    db.db.execute(
      'INSERT INTO $tbl (${use.join(', ')}) VALUES ($placeholders) '
      'ON CONFLICT(id) DO UPDATE SET $updates',
      [for (final c in use) all[c]],
    );
  }

  /// 把一行转成冲突判定要的形态。业务字段**不含那五列**。
  RecordSnapshot? _snapshotOf(Object? row, List<String> cols) {
    if (row is! Map) return null;
    final m = row.map((k, v) => MapEntry('$k', v));
    final id = '${m['id'] ?? ''}';
    if (id.isEmpty) return null;
    const five = {'id', 'updated_at', 'updated_by', 'rev', 'deleted_at'};
    return RecordSnapshot(
      id: id,
      hlc: '${m['updated_at'] ?? ''}',
      rev: _revOf(m),
      updatedBy: '${m['updated_by'] ?? ''}',
      fields: {
        for (final c in cols)
          if (!five.contains(c)) c: m[c],
      },
    );
  }

  int _log(String tbl, String rowId, String op, String hlc, String by) =>
      db.logChange(
          tbl: tbl, rowId: rowId, op: op, rowUpdatedAt: hlc, rowUpdatedBy: by);

  /// 真冲突 → 写入冲突箱。**绝不静默 LWW。**
  void _openConflict({
    required Device device,
    required String tbl,
    required String rowId,
    required List<String> fields,
    required Map<String, Object?> existing,
    required Map<String, Object?> incoming,
    required ConflictResolution resolution,
  }) {
    // 一行一字段一条记录：用户要能逐字段裁决，
    // 而不是面对"整行选 A 还是选 B"。
    for (final f in fields) {
      db.db.execute(
        'INSERT INTO conflict_item (id, updated_at, updated_by, rev, '
        'tbl, row_id, field, local_value, remote_value, local_hlc, remote_hlc, '
        'local_by, remote_by) '
        'VALUES (?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          Ulid.generate(),
          _mintHlc(),
          device.id,
          tbl,
          rowId,
          f,
          '${existing[f]}',
          '${incoming[f]}',
          '${existing['updated_at']}',
          '${incoming['updated_at']}',
          '${existing['updated_by']}',
          '${incoming['updated_by']}',
        ],
      );
    }
  }

  // ── 幂等表 ──

  _CachedMutation? _loadMutation(String mutationId) {
    final rs = db.db.select(
      'SELECT result FROM applied_mutation WHERE mutation_id = ?',
      [mutationId],
    );
    if (rs.isEmpty) return null;
    final raw = '${rs.first['result']}';
    final list = (jsonDecode(raw) as List).cast<Map<String, Object?>>();
    return _CachedMutation(list);
  }

  void _saveMutation(
      String mutationId, String deviceId, List<Map<String, Object?>> results) {
    db.db.execute(
      'INSERT INTO applied_mutation (mutation_id, device_id, applied_at, result) '
      'VALUES (?, ?, ?, ?)',
      [mutationId, deviceId, now().toIso8601String(), jsonEncode(results)],
    );
  }

  Map<String, Object?>? _findPairCode(String code) {
    final rs = db.db.select(
      'SELECT code, created_at, expires_at, used_at FROM pair_code WHERE code = ?',
      [code],
    );
    return rs.isEmpty ? null : rs.first;
  }

  Device _deviceOf(Row r) => Device(
        id: '${r['id']}',
        name: '${r['name']}',
        syncCursor: (r['sync_cursor'] as int?) ?? 0,
        pairedAt: '${r['paired_at']}',
        lastSeenAt: r['last_seen_at'] == null ? null : '${r['last_seen_at']}',
        revokedAt: r['revoked_at'] == null ? null : '${r['revoked_at']}',
      );

  /// 已配对设备列表。给状态页显示"谁连过我"。
  List<Device> devices() {
    final rs = db.db.select(
      'SELECT id, name, sync_cursor, paired_at, last_seen_at, revoked_at '
      'FROM device ORDER BY paired_at',
    );
    return rs.map(_deviceOf).toList();
  }
}

class _CachedMutation {
  final List<Map<String, Object?>> results;
  const _CachedMutation(this.results);
}

class PairCode {
  final String code;
  final DateTime createdAt;
  final DateTime expiresAt;
  const PairCode(
      {required this.code, required this.createdAt, required this.expiresAt});

  bool isExpiredAt(DateTime t) => t.isAfter(expiresAt);

  Map<String, Object?> toJson() => {
        'code': code,
        'createdAt': createdAt.toIso8601String(),
        'expiresAt': expiresAt.toIso8601String(),
        'ttlSeconds': SyncService.pairCodeTtl.inSeconds,
      };
}

enum PairFailure {
  emptyCode,
  missingDeviceId,
  unknownCode,
  codeExpired,
  codeAlreadyUsed;

  /// 给用户看的话。**要能区分"输错了"和"过期了"**，
  /// 否则用户只会一遍遍重输同一个码。
  String get message => switch (this) {
        PairFailure.emptyCode => '请输入配对码',
        PairFailure.missingDeviceId => '缺少设备标识',
        PairFailure.unknownCode => '配对码不对，请在电脑上重新获取',
        PairFailure.codeExpired => '配对码已过期（有效期 5 分钟），请重新获取',
        PairFailure.codeAlreadyUsed => '这个配对码已经用过了，请重新获取',
      };
}

class PairOutcome {
  final PairFailure? failure;
  final String? token;
  final String? deviceId;
  final String? serverId;
  final int? protocolVersion;

  const PairOutcome._(
      {this.failure,
      this.token,
      this.deviceId,
      this.serverId,
      this.protocolVersion});

  const PairOutcome.failure(PairFailure f) : this._(failure: f);

  const PairOutcome.success({
    required String token,
    required String deviceId,
    required String serverId,
    required int protocolVersion,
  }) : this._(
          token: token,
          deviceId: deviceId,
          serverId: serverId,
          protocolVersion: protocolVersion,
        );

  bool get ok => failure == null;

  Map<String, Object?> toJson() => ok
      ? {
          'token': token,
          'deviceId': deviceId,
          'serverId': serverId,
          'protocolVersion': protocolVersion,
        }
      : {
          'error': failure!.name,
          'message': failure!.message,
        };
}

class Device {
  final String id;
  final String name;
  final int syncCursor;
  final String pairedAt;
  final String? lastSeenAt;
  final String? revokedAt;

  const Device({
    required this.id,
    required this.name,
    required this.syncCursor,
    required this.pairedAt,
    this.lastSeenAt,
    this.revokedAt,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'syncCursor': syncCursor,
        'pairedAt': pairedAt,
        if (lastSeenAt != null) 'lastSeenAt': lastSeenAt,
        if (revokedAt != null) 'revokedAt': revokedAt,
      };
}

class PullResult {
  final String serverId;
  final int protocolVersion;
  final int fromSeq;
  final int lastSeq;
  final int nowSeq;
  final bool hasMore;
  final List<Map<String, Object?>> changes;

  const PullResult({
    required this.serverId,
    required this.protocolVersion,
    required this.fromSeq,
    required this.lastSeq,
    required this.nowSeq,
    required this.hasMore,
    required this.changes,
  });

  Map<String, Object?> toJson() => {
        'serverId': serverId,
        'protocolVersion': protocolVersion,
        'fromSeq': fromSeq,
        'lastSeq': lastSeq,
        'nowSeq': nowSeq,
        'hasMore': hasMore,
        'count': changes.length,
        'changes': changes,
      };
}

class PushResult {
  final String? error;
  final String mutationId;
  final List<Map<String, Object?>> results;

  /// 是不是重放（同一个 mutationId 第二次到达）。客户端据此知道"上次其实成功了"。
  final bool replayed;

  const PushResult({
    required this.mutationId,
    required this.results,
    required this.replayed,
  }) : error = null;

  const PushResult.rejected(String reason)
      : error = reason,
        mutationId = '',
        results = const [],
        replayed = false;

  bool get ok => error == null;

  int get appliedCount => results
      .where((r) => const {'inserted', 'updated', 'merged', 'deleted'}
          .contains('${r['outcome']}'))
      .length;

  Map<String, Object?> toJson() => ok
      ? {
          'mutationId': mutationId,
          'replayed': replayed,
          'applied': appliedCount,
          'results': results,
        }
      : {'error': 'bad_request', 'message': error};
}
