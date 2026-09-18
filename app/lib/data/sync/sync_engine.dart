import 'dart:async';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import '../zaoji_db.dart';
import 'sync_prefs.dart';
import 'sync_transport.dart';

/// 客户端同步引擎（R13）。
///
/// ## 一轮同步做什么
///
/// ```
/// sync() =
///   ① ping：确认地址可达 + serverId 没变（连到别的服务器要立刻停下，而不是把数据推过去）
///   ② push：把「updated_at > 水位线」的行（含墓碑）按 applyOrder 分批推上去，
///           每批一个 mutationId（重试复用，服务端幂等），确认后水位线才前进
///   ③ pull：从客户端游标起增量拉（载荷跟变更一起回来），在事务里按 applyOrder
///           落库 + 游标一起走（原子：要么都成要么都不成）
/// ```
///
/// ## 三个刻意的设计（出处：计划书 §5.4–5.6 / 交接文档 §8.2）
///
/// **① 游标在客户端。** 服务端那张 device 表只是对账显示。本引擎把游标存进
/// local_pref，并且**与应用行的写操作同事务**——「游标走了、行没应用」是永久漏数据的致命错误。
///
/// **② 推送队列 = HLC 水位线。** 见 SyncPrefs 的注释。副作用是拉回来的服务端盖章行
/// （HLC 比水位线新）会被"再推一遍"——内容与服务器一致，服务端判定 skipped，
/// 不产生假冲突，只多一次空转。家庭规模下可以接受，换来的是**零队列表、崩溃安全**。
///
/// **③ 应用拉到的行用 LWW（比 HLC），不重新盖章。** 本地保留的 updated_at 就是服务端
/// 盖的章——谁的新用谁的；本地比服务端新（离线期间的改动还没推）就保留本地，
/// 它会在下一轮 push 里上去，由服务端再做一次真正的冲突判定。
/// 同字段真冲突不会在这里被静默处理：服务端把它们写进 conflict_item，
/// 作为业务行被拉回来存进本地库，冲突箱 UI（M2+）逐条裁决。
///
/// ## R13 的边界（刻意收窄）
///
/// 触发时机只有两个：**App 启动后自动一次** + **设置页手动「立即同步」**。
/// 计划书 §5.4 的其余触发（回前台 / 3 秒防抖写入后 / 15 分钟兜底）等有本地写路径
/// （R14：新建/编辑）再接——现在客户端除种子外没有写入，防抖无从谈起。
/// 退避参数（1s→2s→4s→8s→30s，上限 8 次）已实现为 [backoffDelay]，
/// 供自动重试接线时使用。
class SyncEngine extends ChangeNotifier {
  SyncEngine({
    required ZaojiDb db,
    required SyncPrefs prefs,
    SyncTransport? transport,
    DateTime Function()? now,
    Future<void> Function()? onDataApplied,
  })  : _db = db,
        _prefs = prefs,
        _transport = transport,
        _now = now ?? DateTime.now,
        _onDataApplied = onDataApplied;

  final ZaojiDb _db;
  final SyncPrefs _prefs;
  final DateTime Function() _now;
  final Future<void> Function()? _onDataApplied;

  /// 生产路径由 [pair] 创建；测试注入 fake transport。
  SyncTransport? _transport;

  static const protocolVersion = kSyncProtocolVersion;
  static const pushBatchSize = 200; // 服务端上限 500，留余量
  static const pullPageSize = 500;
  static const maxPullPages = 1000; // 防御：游标异常时不至于死循环

  SyncPhase _phase = SyncPhase.neverPaired;
  String? _lastError;
  DateTime? _lastSyncAt;
  bool _busy = false;
  int _consecutiveFails = 0;

  SyncPhase get phase => _phase;
  String? get lastError => _lastError;
  DateTime? get lastSyncAt => _lastSyncAt;
  bool get isBusy => _busy;

  /// 计划书 §5.5：1s→2s→4s→8s→30s 封顶，8 次后不再自动重试
  ///（数据还在水位线之后，人工「立即同步」永远可用）。
  Duration backoffDelay() {
    final n = min(_consecutiveFails, 8);
    if (n == 0) return Duration.zero;
    if (n >= 8) return const Duration(days: 365);
    final secs = [1, 2, 4, 8, 15, 30, 30, 30][n - 1];
    return Duration(seconds: secs);
  }

  Future<bool> isPaired() => _prefs.isPaired();

  /// 冷启动入口。未配对时安静返回（设置页会引导配对），
  /// 失败不抛——启动流程不该被网络问题打断。
  Future<void> syncIfPaired() async {
    if (!await _prefs.isPaired()) {
      _phase = SyncPhase.neverPaired;
      notifyListeners();
      return;
    }
    await sync();
  }

  /// 配对：服务端地址 + 6 位配对码 → 长期 token。
  ///
  /// 成功后立刻跑一轮 [sync]（把本地数据首推上去），失败时凭证已保存、
  /// 状态置 error——用户点「立即同步」即可重试。
  Future<void> pair({
    required String serverUrl,
    required String code,
    String? deviceName,
  }) async {
    final url = _normalizeUrl(serverUrl);
    if (url == null) {
      _fail('地址不对：要形如 http://192.168.31.141:8666');
      return;
    }
    if (code.trim().length != 6) {
      _fail('配对码是 6 位');
      return;
    }

    final nodeId = await _prefs.nodeId();
    final name = (deviceName == null || deviceName.trim().isEmpty)
        ? defaultDeviceName()
        : deviceName.trim();

    final transport = HttpSyncTransport(Uri.parse(url));
    try {
      final res = await transport.post('/api/pair', {
        'code': code.trim().toUpperCase(),
        'deviceId': nodeId,
        'deviceName': name,
      });
      final token = '${res['token'] ?? ''}';
      final serverId = '${res['serverId'] ?? ''}';
      if (token.isEmpty || serverId.isEmpty) {
        _fail('服务端响应缺少 token/serverId');
        return;
      }
      await _prefs.setServerUrl(url);
      await _prefs.setToken(token);
      await _prefs.setServerId(serverId);
      await _prefs.setDeviceName(name);
      _transport?.close();
      _transport = transport;
      _lastError = null;
      _phase = SyncPhase.idle;
      notifyListeners();
      await sync();
    } on SyncTransportException catch (e) {
      transport.close();
      // 429 / 403 原样透出：配对码错与被限流是两种不同的下一步
      _fail(e.message);
    } on SyncNetworkException catch (e) {
      transport.close();
      _fail('连不上服务端：${e.message}');
    }
  }

  /// 解除配对。本地数据保留，只清同步进度与凭证（见 SyncPrefs.unpair）。
  Future<void> unpair() async {
    await _prefs.unpair();
    _transport?.close();
    _transport = null;
    _phase = SyncPhase.neverPaired;
    _lastError = null;
    _consecutiveFails = 0;
    notifyListeners();
  }

  Future<String?> pairedServerUrl() => _prefs.serverUrl();
  Future<String?> pairedServerId() => _prefs.serverId();
  Future<String?> pairedDeviceName() => _prefs.deviceName();
  Future<String> nodeId() => _prefs.nodeId();

  /// 一轮完整同步。并发调用直接合并成「等正在跑的那轮」。
  Future<void> sync() {
    if (_busy) return _running ?? Future.value();
    _busy = true;
    _running = _doSync().whenComplete(() {
      _busy = false;
      _running = null;
      notifyListeners();
    });
    return _running!;
  }

  Future<void>? _running;

  Future<void> _doSync() async {
    final token = await _prefs.token();
    final serverUrl = await _prefs.serverUrl();
    final pairedServerId = await _prefs.serverId();
    if (token == null || serverUrl == null) {
      _phase = SyncPhase.neverPaired;
      notifyListeners();
      return;
    }

    _phase = SyncPhase.syncing;
    _lastError = null;
    notifyListeners();

    try {
      final transport = _transportOf(serverUrl);

      // ① ping：地址可达 + 还是同一台服务器
      final ping = await transport.get('/api/ping');
      final serverId = '${ping['serverId'] ?? ''}';
      if (pairedServerId != null && pairedServerId.isNotEmpty && serverId != pairedServerId) {
        throw SyncServerChangedException(
            '服务端身份变了（$pairedServerId → $serverId）。可能是连到了别的服务器，或服务端数据被清过。请重新配对。');
      }

      var pushed = await _pushPending(transport, token);
      var applied = await _pullAll(transport, token);

      _lastSyncAt = _now();
      _consecutiveFails = 0;
      _phase = SyncPhase.idle;
      if (pushed > 0 || applied > 0) {
        await _onDataApplied?.call();
      }
    } on SyncServerChangedException catch (e) {
      _fail(e.message);
    } on SyncTransportException catch (e) {
      _consecutiveFails++;
      if (e.statusCode == 409) {
        _fail('同步协议版本不一致（服务端 ${e.payload['serverProtocolVersion']}）。请升级 App 或服务端。');
      } else if (e.statusCode == 401) {
        _fail('token 已失效，请重新配对。');
      } else {
        _fail('服务端返回 ${e.statusCode}：${e.message}');
      }
    } on SyncNetworkException catch (e) {
      _consecutiveFails++;
      _fail('网络问题：${e.message}（已失败 $_consecutiveFails 次，${backoffDelay().inSeconds}s 后可自动重试）');
    } catch (e) {
      _consecutiveFails++;
      _fail('同步出错：$e');
    }
  }

  SyncTransport _transportOf(String serverUrl) {
    if (_transport != null) return _transport!;
    final t = HttpSyncTransport(Uri.parse(serverUrl));
    _transport = t;
    return t;
  }

  /// 宽容解析用户手填的地址：补协议头、去末尾斜杠。解析不出主机名返回 null。
  String? _normalizeUrl(String raw) {
    var v = raw.trim();
    if (v.isEmpty) return null;
    if (!v.startsWith('http://') && !v.startsWith('https://')) {
      v = 'http://$v';
    }
    final u = Uri.tryParse(v);
    if (u == null || u.host.isEmpty) return null;
    return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
  }

  // ───────────────────────── 推送 ─────────────────────────

  /// 把水位线之后的行分批推上去。返回推上去的行数。
  Future<int> _pushPending(SyncTransport transport, String token) async {
    final watermark = await _prefs.pushWatermark();
    final pendingMutation = await _prefs.pendingMutationId();

    // 按 applyOrder 收集（父表在前，服务端有外键）。
    // 列名严格取自同步白名单——多一列服务端都会整条拒绝。
    final changes = <Map<String, Object?>>[];
    for (final table in ZaojiDb.syncedTablesSorted) {
      final cols = syncWhitelist[table.name]!;
      final rows = await _db.customSelect(
        'SELECT ${cols.join(', ')} FROM ${table.name} '
        "WHERE updated_at > ? ORDER BY updated_at",
        variables: [Variable(watermark)],
      ).get();
      for (final r in rows) {
        final row = r.data;
        // 墓碑必须用 op=delete：服务端的 upsert 分支刻意不处理 deleted_at
        //（R6 的设计：删除只走 delete 分支），推 upsert 会让删除永远到不了别的设备。
        final isTombstone = row['deleted_at'] != null;
        changes.add({
          'tbl': table.name,
          'rowId': '${row['id']}',
          'op': isTombstone ? 'delete' : 'upsert',
          'row': row,
        });
      }
    }

    if (changes.isEmpty && pendingMutation == null) return 0;

    var pushedCount = 0;
    var newWatermark = watermark;
    for (var i = 0; i < changes.length; i += pushBatchSize) {
      final batch = changes.sublist(i, min(i + pushBatchSize, changes.length));
      // 重试复用同一个 mutationId（服务端 applied_mutation 靠它幂等）。
      // 拿不到确认就停在这里：水位线与 mutationId 都不动，下轮原样重推。
      final mutationId = pendingMutation ?? Ulid.generate();
      if (pendingMutation == null) await _prefs.setPendingMutationId(mutationId);

      final res = await transport.post('/api/changes', {
        'mutationId': mutationId,
        'protocolVersion': protocolVersion,
        'changes': batch,
      }, token: token);
      if (res['replayed'] == true) {
        // 上次其实成功了（响应丢失）：批次已完成，直接确认
      } else {
        final results = (res['results'] as List? ?? const []).cast<Map>();
        for (final r in results) {
          if (const {'inserted', 'updated', 'merged'}.contains('${r['outcome']}')) {
            pushedCount++;
          } else if ('${r['outcome']}' == 'rejected') {
            // 服务端点名拒绝（未知列/类型/NOT NULL）：这行本地也修不了，
            // 记进日志让人能查——**不能让一条坏行卡死整个水位线**，
            // 所以照样前进（见下），坏行留待「数据体检」（M5）处理。
            debugPrint('sync: rejected ${r['tbl']}/${r['rowId']}: ${r['reason']}');
          }
        }
      }

      // 确认本批：水位线前进到本批最大的 HLC。
      // 水位线必须**跨批单调**——下一批的行只会更新。
      for (final c in batch) {
        final hlc = '${(c['row'] as Map)['updated_at']}';
        if (hlc.compareTo(newWatermark) > 0) newWatermark = hlc;
      }
      await _prefs.setPushWatermark(newWatermark);
      await _prefs.setPendingMutationId(null);
    }
    return pushedCount;
  }

  // ───────────────────────── 拉取 ─────────────────────────

  /// 从客户端游标起拉全量增量。返回应用的变更条数。
  Future<int> _pullAll(SyncTransport transport, String token) async {
    var cursor = await _prefs.pullCursor();
    var appliedTotal = 0;

    for (var page = 0; page < maxPullPages; page++) {
      final res = await transport.get(
        '/api/changes?since=$cursor&limit=$pullPageSize',
        token: token,
      );
      final changes = (res['changes'] as List? ?? const []).cast<Map>();
      final lastSeq = (res['lastSeq'] as num?)?.toInt() ?? cursor;

      if (changes.isNotEmpty) {
        // ★ 行应用与游标推进在同一个事务里（见 SyncPrefs.setPullCursor）。
        appliedTotal += await _db.transaction(() async {
          var n = 0;
          for (final c in _sortedByApplyOrder(changes)) {
            n += await _applyPulled(c);
          }
          await _prefs.setPullCursor(lastSeq);
          return n;
        });
      } else if (lastSeq > cursor) {
        // 空页也要推进游标（跳过的非白名单条目不会出现在 changes 里）
        await _prefs.setPullCursor(lastSeq);
      }
      cursor = lastSeq;

      if (res['hasMore'] != true) break;
    }
    return appliedTotal;
  }

  /// 拉回的变更按 applyOrder 排（父表在前），同表内按 seq 稳定排序。
  List<Map<String, Object?>> _sortedByApplyOrder(List<Map> changes) {
    int orderOf(Object? tbl) {
      final i = ZaojiDb.syncedTablesSorted.indexWhere((t) => t.name == '$tbl');
      return i < 0 ? 1 << 30 : i;
    }

    final list = changes
        .map((c) => c.map((k, v) => MapEntry('$k', v)))
        .toList()
      ..sort((a, b) {
        final byTable = orderOf(a['tbl']).compareTo(orderOf(b['tbl']));
        if (byTable != 0) return byTable;
        return ((a['seq'] as num?) ?? 0).compareTo((b['seq'] as num?) ?? 0);
      });
    return list;
  }

  /// 应用一条拉到的变更（LWW：比 HLC，谁新用谁；不重新盖章）。
  Future<int> _applyPulled(Map<String, Object?> change) async {
    final tbl = '${change['tbl']}';
    final allowed = syncWhitelist[tbl];
    if (allowed == null) return 0; // 非白名单表：物理上到不了这里，防御一下

    final rowId = '${change['rowId'] ?? ''}';
    if (rowId.isEmpty) return 0;

    final pulledHlc = '${change['updatedAt'] ?? ''}';
    final row = change['row'];

    if (row is! Map) {
      // 无载荷的 delete：服务端说这行已经不在了。给本地打墓碑（LWW 保护）。
      final existing = await _selectRow(tbl, allowed, rowId);
      if (existing == null) return 0;
      if ('${existing['updated_at']}'.compareTo(pulledHlc) >= 0) return 0;
      await _db.customUpdate(
        'UPDATE $tbl SET deleted_at = ?, updated_at = ?, updated_by = ?, rev = rev + 1 '
        'WHERE id = ?',
        variables: [
          Variable(pulledHlc),
          Variable(pulledHlc),
          Variable('${change['updatedBy'] ?? 'server'}'),
          Variable(rowId),
        ],
      );
      return 1;
    }

    final incoming = row.map((k, v) => MapEntry('$k', v));
    final existing = await _selectRow(tbl, allowed, rowId);

    if (existing == null) {
      // 新行：原样落库，保留服务端盖的 HLC 章——它就是这行的最新事实。
      final cols = allowed;
      await _db.customInsert(
        'INSERT INTO $tbl (${cols.join(', ')}) '
        'VALUES (${List.filled(cols.length, '?').join(', ')})',
        variables: [for (final c in cols) Variable(incoming[c])],
      );
      return 1;
    }

    final localHlc = '${existing['updated_at']}';
    if (pulledHlc.compareTo(localHlc) <= 0) {
      return 0; // 本地相同或更新（可能是还没推上去的离线改动），保留本地
    }

    final sets = [for (final c in allowed) if (c != 'id') '$c = ?'].join(', ');
    await _db.customUpdate(
      'UPDATE $tbl SET $sets WHERE id = ?',
      variables: [
        for (final c in allowed)
          if (c != 'id') Variable(incoming[c]),
        Variable(rowId),
      ],
    );
    return 1;
  }

  Future<Map<String, Object?>?> _selectRow(
      String tbl, List<String> cols, String rowId) async {
    final rows = await _db.customSelect(
      'SELECT ${cols.join(', ')} FROM $tbl WHERE id = ?',
      variables: [Variable(rowId)],
    ).get();
    return rows.isEmpty ? null : rows.first.data;
  }

  // ───────────────────────── 状态与错误 ─────────────────────────

  void _fail(String message) {
    _lastError = message;
    _phase = SyncPhase.error;
    notifyListeners();
  }

  String defaultDeviceName() {
    if (kIsWeb) return '网页端';
    if (defaultTargetPlatform == TargetPlatform.android) return 'Android 设备';
    if (defaultTargetPlatform == TargetPlatform.iOS) return 'iOS 设备';
    return '桌面端';
  }

  @override
  void dispose() {
    _transport?.close();
    super.dispose();
  }
}

enum SyncPhase {
  /// 从未配对（设置页引导配对）
  neverPaired,

  /// 空闲（已配对，无正在进行的同步）
  idle,

  /// 正在同步
  syncing,

  /// 上一次同步失败（lastError 有内容）
  error,
}

/// 服务端身份校验失败（serverId 变了）。
///
/// 这不是网络错误，是「连错了服务器」：继续同步的后果是把家菜谱推到别人服务器、
/// 或把别人数据拉进家里——必须硬停并要求重新配对。
class SyncServerChangedException implements Exception {
  const SyncServerChangedException(this.message);
  final String message;

  @override
  String toString() => message;
}
