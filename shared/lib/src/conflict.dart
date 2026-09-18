/// 同步冲突判定。
///
/// **铁律：不允许静默 LWW（最后写入胜）。**
///
/// 菜谱是用户一道道手工攒起来的东西。「我明明改了，怎么又被改回去了」
/// 是这类产品最伤信任的失败方式——而且用户往往无法复现、无法申诉。
///
/// 所以这个模块的职责**不是**"选一个赢家"，而是先判断
/// **这到底算不算冲突**：
///
/// | 情况 | 处理 |
/// |---|---|
/// | 两边一模一样 | 无需动作 |
/// | 只有一边改过 | 直接用改过的那边 |
/// | 两边改的**字段不重叠** | 字段级自动合并，**不打扰用户** |
/// | 两边改了**同一字段且值不同** | 真冲突 → 写入冲突箱，让用户选 |
///
/// 第二行那个「字段级合并」是关键：A 改了耗时、B 改了步骤图，
/// 这是协作而不是冲突，弹窗问用户是骚扰。
library;

import 'dart:convert';

enum ConflictKind {
  /// 两边完全一致
  identical,

  /// 只有本地改过
  takeLocal,

  /// 只有远端改过
  takeRemote,

  /// 双方改的字段不重叠，已自动合并
  autoMerged,

  /// 真冲突，需要用户裁决
  manual,
}

class RecordSnapshot {
  final String id;

  /// 编码后的 HLC 字符串。字典序 == 时间序，可直接比较。
  final String hlc;

  /// 修订号。用于快速判断「有没有变过」，也是冲突箱里的展示信息。
  final int rev;

  final String updatedBy;

  /// 业务字段（**不含** id / updated_at / rev / updated_by / deleted_at 这五列）
  final Map<String, Object?> fields;

  const RecordSnapshot({
    required this.id,
    required this.hlc,
    required this.rev,
    required this.updatedBy,
    required this.fields,
  });

  RecordSnapshot copyWith({Map<String, Object?>? fields}) => RecordSnapshot(
        id: id,
        hlc: hlc,
        rev: rev,
        updatedBy: updatedBy,
        fields: fields ?? this.fields,
      );

  @override
  String toString() => 'Snapshot($id rev=$rev by=$updatedBy @$hlc)';
}

class ConflictResolution {
  final ConflictKind kind;

  /// 可安全落库的字段。`manual` 时这里给的是**已经合好的非冲突部分**
  /// （冲突字段暂时填较新一方的值），这样即使冲突没裁决，其余修改也不会丢。
  final Map<String, Object?>? fields;

  /// 需要用户裁决的字段名。
  final List<String> conflictingFields;

  /// 建议优先展示哪一方（较新的一方）。仅用于冲突箱的默认选中项。
  final String? preferredSide;

  const ConflictResolution({
    required this.kind,
    this.fields,
    this.conflictingFields = const [],
    this.preferredSide,
  });

  bool get needsUserDecision => kind == ConflictKind.manual;

  @override
  String toString() => 'ConflictResolution(${kind.name}'
      '${conflictingFields.isEmpty ? '' : ' fields=${conflictingFields.join(",")}'})';
}

/// 判定一次双边变更。
///
/// [base] 是双方共同祖先的版本。**强烈建议传入**：
/// 同步协议里带上 `base_rev`，服务端保存上一版，成本很低，
/// 但没有它就无法区分"字段被删除"和"字段从未存在过"。
ConflictResolution resolveConflict({
  required RecordSnapshot local,
  required RecordSnapshot remote,
  RecordSnapshot? base,
}) {
  if (local.hlc == remote.hlc) {
    return ConflictResolution(kind: ConflictKind.identical, fields: local.fields);
  }

  final allKeys = <String>{
    ...local.fields.keys,
    ...remote.fields.keys,
    ...?base?.fields.keys,
  };

  final Set<String> changedLocal;
  final Set<String> changedRemote;

  if (base != null) {
    changedLocal = <String>{
      for (final k in allKeys)
        if (!_equal(local.fields[k], base.fields[k])) k,
    };
    changedRemote = <String>{
      for (final k in allKeys)
        if (!_equal(remote.fields[k], base.fields[k])) k,
    };
  } else {
    // 没有基线时只能保守：凡是两边不一致的字段，都当作"双方都动过"。
    // 这会让一些本可自动合并的情况退化成人工裁决，但**不会错误地丢数据**。
    final diff = <String>{
      for (final k in allKeys)
        if (!_equal(local.fields[k], remote.fields[k])) k,
    };
    changedLocal = diff;
    changedRemote = diff;
  }

  if (changedRemote.isEmpty) {
    return ConflictResolution(kind: ConflictKind.takeLocal, fields: local.fields);
  }
  if (changedLocal.isEmpty) {
    return ConflictResolution(kind: ConflictKind.takeRemote, fields: remote.fields);
  }

  // 交集里"值也不一样"的才是真冲突。
  // 两人都改成同一个值（比如都把耗时改成 15 分钟）不算冲突。
  final conflicting = <String>[];
  for (final k in changedLocal) {
    if (!changedRemote.contains(k)) continue;
    if (!_equal(local.fields[k], remote.fields[k])) conflicting.add(k);
  }
  conflicting.sort();

  // 无论是否冲突，先把能合的合掉——用户改的每个字段都不该因为
  // 另一个字段有争议而被一起搁置。
  final merged = <String, Object?>{};
  if (base != null) merged.addAll(base.fields);
  for (final k in changedLocal) {
    if (conflicting.contains(k)) continue;
    merged[k] = local.fields[k];
  }
  for (final k in changedRemote) {
    if (conflicting.contains(k)) continue;
    merged[k] = remote.fields[k];
  }

  final remoteIsNewer = remote.hlc.compareTo(local.hlc) > 0;
  for (final k in conflicting) {
    merged[k] = remoteIsNewer ? remote.fields[k] : local.fields[k];
  }

  if (conflicting.isEmpty) {
    return ConflictResolution(kind: ConflictKind.autoMerged, fields: merged);
  }

  return ConflictResolution(
    kind: ConflictKind.manual,
    fields: merged,
    conflictingFields: conflicting,
    preferredSide: remoteIsNewer ? 'remote' : 'local',
  );
}

/// 深比较。用规范化 JSON 字符串比较，避免 Map/List 的引用比较踩坑。
bool _equal(Object? a, Object? b) => _canonical(a) == _canonical(b);

String _canonical(Object? v) {
  if (v == null) return 'null';
  if (v is Map) {
    final keys = v.keys.map((e) => e.toString()).toList()..sort();
    final buf = StringBuffer('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) buf.write(',');
      buf.write(jsonEncode(keys[i]));
      buf.write(':');
      buf.write(_canonical(v[keys[i]]));
    }
    return (buf..write('}')).toString();
  }
  if (v is List) {
    return '[${v.map(_canonical).join(',')}]';
  }
  return jsonEncode(v);
}

/// 写入冲突箱的一条记录。服务端 `conflict_box` 表按它建表。
class ConflictTicket {
  final String table;
  final String recordId;
  final JsonMap local;
  final JsonMap remote;
  final JsonMap? base;
  final List<String> conflictingFields;
  final String detectedAt;
  final String? preferredSide;

  const ConflictTicket({
    required this.table,
    required this.recordId,
    required this.local,
    required this.remote,
    this.base,
    required this.conflictingFields,
    required this.detectedAt,
    this.preferredSide,
  });

  factory ConflictTicket.from({
    required String table,
    required RecordSnapshot local,
    required RecordSnapshot remote,
    RecordSnapshot? base,
    required ConflictResolution resolution,
    required String detectedAt,
  }) =>
      ConflictTicket(
        table: table,
        recordId: local.id,
        local: _toJsonMap(local),
        remote: _toJsonMap(remote),
        base: base == null ? null : _toJsonMap(base),
        conflictingFields: resolution.conflictingFields,
        detectedAt: detectedAt,
        preferredSide: resolution.preferredSide,
      );

  static JsonMap _toJsonMap(RecordSnapshot s) => <String, Object?>{
        'id': s.id,
        'hlc': s.hlc,
        'rev': s.rev,
        'updatedBy': s.updatedBy,
        'fields': s.fields,
      };

  JsonMap toJson() => <String, Object?>{
        'table': table,
        'recordId': recordId,
        'local': local,
        'remote': remote,
        if (base != null) 'base': base,
        'conflictingFields': conflictingFields,
        'detectedAt': detectedAt,
        if (preferredSide != null) 'preferredSide': preferredSide,
      };
}

typedef JsonMap = Map<String, Object?>;
