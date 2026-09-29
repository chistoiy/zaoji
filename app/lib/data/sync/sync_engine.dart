import 'dart:async';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
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
  }) : _db = db,
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

  // ── R21 · 准入三态（服务端设定，本机只是读）──
  SyncAccessMode? _accessMode;
  bool _visitorManualSync = false;

  /// 服务端当前准入模式；null = 还没成功读到（UI 回退到配对码版式）。
  SyncAccessMode? get accessMode => _accessMode;

  /// 服务端是否要求来访者手动点「立即同步」。只对**没有 token 的设备**生效。
  bool get visitorManualSync => _visitorManualSync;

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

  /// 自动重试的闸门：连续失败 8 次封顶，超过后只等人工「立即同步」。
  /// 供触发接线（main.dart）判断要不要排下一次退避重试——
  /// 不判断的话，365 天的 backoffDelay 会被排成一个永远挂着的 Timer。
  bool get shouldAutoRetry => _consecutiveFails < 8;

  Future<bool> isPaired() => _prefs.isPaired();

  /// 同步策略（FR-DATA-05，本机偏好、**不参与同步**——和备菜板同一条立场：
  /// 每台设备离网络的远近不一样，手机可以「仅下载」省流量，平板不必跟着变）。
  ///
  /// 三个词按**实际行为**说：仅上传=只把本机改动推上去（不拉），
  /// 仅下载=只拉服务端更新（本机没推的改动继续留在水位线之后，等切回双向）。
  /// 需求原文里「以某端为准覆盖另一端」那种**强制覆盖语义这里刻意没有**：
  /// 它要绕过冲突箱直接抹掉一端的改动，与 FR-DATA-06「冲突不静默覆盖」正面冲突。
  Future<void> loadSyncMode() async {
    _syncMode = SyncMode.parse(await _prefs.syncMode());
  }

  /// 改策略：落库 + 通知（UI 的选中态跟着走）。
  Future<void> setSyncMode(SyncMode m) async {
    if (m == _syncMode) return;
    _syncMode = m;
    await _prefs.setSyncMode(m.wire);
    notifyListeners();
  }

  /// 当前策略（`loadSyncMode` 之前是默认的双向）。
  SyncMode get syncMode => _syncMode;

  SyncMode _syncMode = SyncMode.bidir;

  /// 冷启动/回前台/防抖共用的自动入口（R21 起语义从「已配对才同步」扩展为
  /// 「**被允许自动同步**就同步」）：
  ///
  /// - 有 token：任何模式都自动同步（已配对设备永远自动，见三态设计）；
  /// - 无 token：只有服务端处于 **open** 且没要求手动，才以免配对身份同步；
  ///   其余情况安静停在 neverPaired——这不是错误，是「还没接入」。
  Future<void> syncIfPaired() async {
    await loadSyncMode();
    // 网页端首次：没存过地址就拿当前访问 origin 当地址。
    // 用户从服务器上看到的就是这台服务器——没有第二个答案值得让他手输。
    if (kIsWeb && await _prefs.serverUrl() == null) {
      final origin = Uri.base.origin;
      if (origin.startsWith('http')) await _prefs.setServerUrl(origin);
    }

    if (!await _prefs.isPaired()) {
      if (await _prefs.serverUrl() == null) {
        _phase = SyncPhase.neverPaired;
        notifyListeners();
        return;
      }
      await refreshAccessConfig();
      if (_accessMode != SyncAccessMode.open || _visitorManualSync) {
        _phase = SyncPhase.neverPaired;
        notifyListeners();
        return;
      }
    }
    await sync();
  }

  /// 读服务端的准入配置（免鉴权）。失败**不抛也不记 error**——
  /// 模式保持"未知"，UI 回退到配对码版式即可；自动同步照旧安静停摆。
  ///
  /// 带超时：半死的服务器不该把「我的」页钉在加载态。
  ///
  /// [urlOverride]：**用界面上正在输入的地址去探**，不是只认已保存的那份。
  /// 这是 R21 版式判定的一处真空：未配对的 Android 设备偏好里还没有地址，
  /// 于是探不到模式 → 永远回退成配对码版式，而服务端其实开着免配对——
  /// 用户看到的就是「服务端没开配对码，App 却逼我输配对码」。
  /// Web 端不出这问题只是因为 origin 恰好被预填进了偏好。
  Future<void> refreshAccessConfig({String? urlOverride}) async {
    final url = urlOverride != null && urlOverride.trim().isNotEmpty
        ? _normalizeUrl(urlOverride)
        : await _prefs.serverUrl();
    if (url == null) return;
    final fromBox = urlOverride != null && urlOverride.trim().isNotEmpty;
    try {
      final res = await (await _transportOf(url))
          .get('/api/sync/config')
          .timeout(const Duration(seconds: 5));
      _accessMode = SyncAccessMode.parse('${res['accessMode']}');
      _visitorManualSync = res['visitorManualSync'] == true;
      // 谈上了话就把这台服务器记住——但只补空，绝不覆盖已保存的地址。
      // 不写这一笔的病灶（R38 真机可见）：未配对设备的偏好里没有 serverUrl，
      // 界面却按框里的地址显示「免配对 + 上传改动」，一点就走进
      // `_doSync` 的 `serverUrl == null` 分支直接判成 neverPaired，
      // 用户看到的就是"按钮点了毫无反应"。
      // 只补空是因为：已配对设备的 token 属于原服务器，探测到另一台就改地址
      // 等于把这台设备悄悄迁回家。
      if (fromBox && await _prefs.serverUrl() == null) {
        await _prefs.setServerUrl(url);
      }
    } catch (_) {/* 连不上/超时都是"未知"，等下次触发再试 */}
  }

  /// 口令接入（R21）：固定口令换本机专属 token。
  ///
  /// 与 [pair] 同构：成功即存凭证并立刻跑一轮同步；失败原话透出（403/429/503）。
  Future<void> join({
    required String serverUrl,
    required String passcode,
    String? deviceName,
  }) async {
    final url = _normalizeUrl(serverUrl);
    if (url == null) {
      _fail('地址不对：要形如 http://192.168.31.141:8666');
      return;
    }
    if (passcode.trim().isEmpty) {
      _fail('请输入连接口令');
      return;
    }

    final nodeId = await _prefs.nodeId();
    final name = (deviceName == null || deviceName.trim().isEmpty)
        ? defaultDeviceName()
        : deviceName.trim();

    final transport = HttpSyncTransport(Uri.parse(url), nodeId: nodeId);
    try {
      final res = await transport.post('/api/join', {
        'passcode': passcode.trim(),
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
      _fail(e.message);
    } on SyncNetworkException catch (e) {
      transport.close();
      _fail('连不上服务端：${e.message}');
    }
  }

  /// R43 · 永久删除回收站里的东西（FR-DATA-13）。
  ///
  /// **顺序是刻意的：先问服务端，服务端认了才删本机。**
  /// 反过来做会留一条复活路径——别台设备的回收站里那条还在、还能点「恢复」，
  /// 一推就回到你这台机器上，而用户已经看见"已永久删除"了。
  /// 这种"删了又回来"比不删更伤信任，所以宁可多一次往返。
  ///
  /// 返回 null = 成功；否则是给人看的失败原因。不抛（与 [resolveConflicts] 同一口径：
  /// 这是用户点一下就要看到结果的动作，不能靠上层 try/catch 兜）。
  Future<String?> purgeRecipePermanently(String recipeId) async {
    final serverUrl = await _prefs.serverUrl();
    if (serverUrl == null) {
      _fail('还没接入服务端，无法永久删除');
      return '这台设备还没接入服务端，先完成接入再永久删除（回收站里的东西本身不受影响）';
    }
    final token = await _prefs.token();
    final List<Map<String, Object?>> results;
    try {
      final res = await (await _transportOf(serverUrl)).post('/api/purge', {
        'rows': [
          {'tbl': 'recipe', 'id': recipeId}
        ]
      }, token: token);
      results = (res['results'] as List? ?? const [])
          .cast<Map>()
          .map((r) => r.map((k, v) => MapEntry('$k', v)))
          .toList();
    } on SyncTransportException catch (e) {
      // 404 在这条调用上只有一个意思：**对面那台服务端还没有 /api/purge 这个路由**
      // （v0.14.3 及更早的 exe 就是这种状态）。这时给人看"连不上"是误导——
      // 连得上，只是它不认识这件事。本机照样一行不动。
      if (e.statusCode == 404) {
        _fail('服务端不认识 /api/purge（HTTP 404）');
        return '这台服务端还不认识永久删除（服务端版本偏旧），'
            '本机数据一行没动；把服务端的 exe 换到 v0.15.0 及以后就能用';
      }
      _fail(e.message);
      return e.message;
    } on SyncNetworkException catch (e) {
      _fail('连不上服务端：${e.message}');
      return '连不上服务端，这笔永久删除没有执行（本机数据一行没动）';
    }
    final bad = results.where((r) => r['outcome'] == 'rejected').toList();
    if (bad.isNotEmpty) {
      _fail('${bad.first['reason']}');
      return '${bad.first['reason']}';
    }
    // 服务端已经收下并广播 purge，本机立刻物理清掉，不等下一轮拉取——
    // 用户点完就该从回收站里消失，"等下次同步再不见"是骗人的。
    await _purgeLocalRecipe(recipeId);
    await _onDataApplied?.call();
    _lastError = null;
    notifyListeners();
    return null;
  }

  /// 本机这一侧的永久删除：菜谱连同它的食材行与步骤行一起清。
  ///
  /// 这里级联是**本地体验**的级联（回收站只列菜谱，子行留着就是幽灵数据）；
  /// 别的设备靠服务端广播的那几条子行 purge 变更各自清，两条路互不依赖。
  Future<void> _purgeLocalRecipe(String recipeId) async {
    final db = _db;
    await db.transaction(() async {
      await db.customUpdate('DELETE FROM ingredient WHERE recipe_id = ?',
          variables: [Variable(recipeId)]);
      await db.customUpdate('DELETE FROM step WHERE recipe_id = ?',
          variables: [Variable(recipeId)]);
      await db.customUpdate('DELETE FROM recipe WHERE id = ?',
          variables: [Variable(recipeId)]);
    });
  }

  /// 提交冲突裁决（R22），返回服务端的逐条结果。
  ///
  /// **裁决为什么走服务端而不是本地改行再推**：推上去的行不带 base 快照，
  /// 「把值改回旧的那个」会被冲突判定认成新一轮真冲突——冲突箱越裁决越多。
  /// 服务端盖 HLC 后所有设备一次拉取即收敛，所以成功后**立刻跑一轮 [sync]**
  /// 把盖章结果拉回本机（冲突卡消失、行值变定稿）。
  ///
  /// 失败不抛：结果里逐条给 outcome，网络/鉴权错误记进 [lastError] 并原样返回空表。
  Future<List<Map<String, Object?>>> resolveConflicts(
    List<Map<String, Object?>> items,
  ) async {
    final serverUrl = await _prefs.serverUrl();
    if (serverUrl == null) {
      _fail('尚未接入服务端，无法提交裁决');
      return const [];
    }
    final token = await _prefs.token();
    try {
      final res = await (await _transportOf(serverUrl)).post(
        '/api/conflicts/resolve',
        {'items': items},
        token: token,
      );
      _lastError = null;
      final results = (res['results'] as List? ?? const [])
          .cast<Map>()
          .map((r) => r.map((k, v) => MapEntry('$k', v)))
          .toList();
      await sync();
      return results;
    } on SyncTransportException catch (e) {
      _fail(e.message);
      return const [];
    } on SyncNetworkException catch (e) {
      _fail('连不上服务端：${e.message}');
      return const [];
    }
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

    final transport = HttpSyncTransport(Uri.parse(url), nodeId: nodeId);
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

  /// 「我的」页地址框的默认值：存过的地址优先；网页端没有地址时
  /// 用当前访问 origin——**从服务器上看到的就是这台服务器**，
  /// 不该让来访者手动再抄一遍浏览器地址栏。
  Future<String?> serverUrlOrWebOrigin() async {
    final saved = await _prefs.serverUrl();
    if (saved != null) return saved;
    if (!kIsWeb) return null;
    final origin = Uri.base.origin;
    return origin.startsWith('http') ? origin : null;
  }

  /// 一轮完整同步。并发调用直接合并成「等正在跑的那轮」。
  ///
  /// [direction] 只影响**这一轮**（手动「上传改动」/「拉取更新」按一次走一次），
  /// 不改动用户设的常驻策略；不传就用常驻策略。
  Future<void> sync({SyncMode? direction}) {
    if (_busy) return _running ?? Future.value();
    _busy = true;
    _running = _doSync(direction).whenComplete(() {
      _busy = false;
      _running = null;
      notifyListeners();
    });
    return _running!;
  }

  /// 手动「上传改动」：只推不拉，一轮次性动作。
  Future<void> pushNow() => sync(direction: SyncMode.upload);

  /// 手动「拉取更新」：只拉不推，一轮次性动作。
  Future<void> pullNow() => sync(direction: SyncMode.download);

  Future<void>? _running;

  Future<void> _doSync(SyncMode? direction) async {
    final token = await _prefs.token();
    final serverUrl = await _prefs.serverUrl();
    final pairedServerId = await _prefs.serverId();
    if (serverUrl == null) {
      _phase = SyncPhase.neverPaired;
      notifyListeners();
      return;
    }
    // R21：没有 token 也允许走到这里——但必须是开放模式（syncIfPaired
    // 已把过关；手动「立即同步」的按钮也可能由开放模式来访者按下）。
    final hasToken = token != null && token.isNotEmpty;
    if (!hasToken) {
      await refreshAccessConfig();
      if (_accessMode != SyncAccessMode.open) {
        _phase = SyncPhase.neverPaired;
        notifyListeners();
        return;
      }
    }

    _phase = SyncPhase.syncing;
    _lastError = null;
    _setProgress(const SyncProgress(SyncStage.connecting));
    notifyListeners();

    try {
      final transport = await _transportOf(serverUrl);

      // ① ping：地址可达 + 还是同一台服务器
      final ping = await transport.get('/api/ping');
      final serverId = '${ping['serverId'] ?? ''}';
      if (pairedServerId != null &&
          pairedServerId.isNotEmpty &&
          serverId != pairedServerId) {
        throw SyncServerChangedException(
          '服务端身份变了（$pairedServerId → $serverId）。可能是连到了别的服务器，或服务端数据被清过。请重新配对。',
        );
      }
      // 来访者的第一次同步：把这台服务器的身份记下来。
      // 之后换服务器就是同步事故而不是"静默连错家"——与配对设备同一条铁律。
      if (!hasToken && serverId.isNotEmpty) {
        await _prefs.setServerId(serverId);
      }

      // 方向闸门（FR-DATA-05）：本轮走常驻策略，还是被手动按钮指定成单向。
      final mode = direction ?? _syncMode;
      var pushed = 0;
      var applied = 0;
      if (mode != SyncMode.download) {
        pushed = await _pushPending(transport, hasToken ? token : null);
      }
      if (mode != SyncMode.upload) {
        applied = await _pullAll(transport, hasToken ? token : null);
      }

      _lastSyncAt = _now();
      _consecutiveFails = 0;
      _phase = SyncPhase.idle;
      if (pushed > 0 || applied > 0) {
        await _onDataApplied?.call();
      }
      // 差异刷新**不在这里做**：算待拉数要真的发一次 `/api/changes`，
      // 每轮同步后自动补一发会把服务端的拉取计数与幂等日志都搅浑
      // （测试与真服务端都是同一套账）。要新数字请走 [computeDiff]——
      // 界面上的动作入口（`_act`）与进页面探测（`_probe`）都各自调它。
    } on SyncServerChangedException catch (e) {
      _fail(e.message);
    } on SyncTransportException catch (e) {
      _consecutiveFails++;
      if (e.statusCode == 409) {
        _fail(
          '同步协议版本不一致（服务端 ${e.payload['serverProtocolVersion']}）。请升级 App 或服务端。',
        );
      } else if (e.statusCode == 401) {
        // 来访者没有 token，"重新配对"对它是一句听不懂的话——按身份说事
        _fail(hasToken ? 'token 已失效，请重新配对。' : '服务端已不再接受免配对访问，请到「我的」页完成接入。');
      } else {
        _fail('服务端返回 ${e.statusCode}：${e.message}');
      }
    } on SyncNetworkException catch (e) {
      _consecutiveFails++;
      _fail(
        '网络问题：${e.message}（已失败 $_consecutiveFails 次，${backoffDelay().inSeconds}s 后可自动重试）',
      );
    } catch (e) {
      _consecutiveFails++;
      _fail('同步出错：$e');
    } finally {
      // 成功、失败、被拒——任何出口都不该把进度条留在屏幕上。
      _progress = null;
    }
  }

  Future<SyncTransport> _transportOf(String serverUrl) async {
    if (_transport != null) return _transport!;
    // 自建的生产 transport 必须带 nodeId：开放模式的匿名请求靠它登记伪设备
    final t = HttpSyncTransport(
      Uri.parse(serverUrl),
      nodeId: await _prefs.nodeId(),
    );
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
  Future<int> _pushPending(SyncTransport transport, String? token) async {
    final watermark = await _prefs.pushWatermark();
    final pendingMutation = await _prefs.pendingMutationId();

    // 按 applyOrder 收集（父表在前，服务端有外键）。
    // 列名严格取自同步白名单——多一列服务端都会整条拒绝。
    final changes = <Map<String, Object?>>[];
    for (final table in ZaojiDb.syncedTablesSorted) {
      final cols = syncWhitelist[table.name]!;
      final rows = await _db
          .customSelect(
            'SELECT ${cols.join(', ')} FROM ${table.name} '
            "WHERE updated_at > ? ORDER BY updated_at",
            variables: [Variable(watermark)],
          )
          .get();
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
    final batches = (changes.length / pushBatchSize).ceil();
    for (var i = 0; i < changes.length; i += pushBatchSize) {
      _setProgress(SyncProgress(SyncStage.pushing, done: i ~/ pushBatchSize + 1, total: batches));
      final batch = changes.sublist(i, min(i + pushBatchSize, changes.length));
      // 重试复用同一个 mutationId（服务端 applied_mutation 靠它幂等）。
      // 拿不到确认就停在这里：水位线与 mutationId 都不动，下轮原样重推。
      final mutationId = pendingMutation ?? Ulid.generate();
      if (pendingMutation == null) {
        await _prefs.setPendingMutationId(mutationId);
      }

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
          if (const {
            'inserted',
            'updated',
            'merged',
          }.contains('${r['outcome']}')) {
            pushedCount++;
          } else if ('${r['outcome']}' == 'rejected') {
            // 服务端点名拒绝（未知列/类型/NOT NULL）：这行本地也修不了，
            // 记进日志让人能查——**不能让一条坏行卡死整个水位线**，
            // 所以照样前进（见下），坏行留待「数据体检」（M5）处理。
            debugPrint(
              'sync: rejected ${r['tbl']}/${r['rowId']}: ${r['reason']}',
            );
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
  Future<int> _pullAll(SyncTransport transport, String? token) async {
    var cursor = await _prefs.pullCursor();
    var appliedTotal = 0;

    for (var page = 0; page < maxPullPages; page++) {
      _setProgress(SyncProgress(SyncStage.pulling, done: page + 1));
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
  ///
  /// ★ 但 `purge` 必须**排在所有写入之后、且按表序倒过来**（先子后父）。
  ///   客户端开着 `PRAGMA foreign_keys = ON`（与服务端同一立场，见 zaoji_db 的
  ///   beforeOpen），一行 `DELETE FROM recipe` 排在它的 ingredient/step 之前，
  ///   整页应用就会以 FOREIGN KEY constraint failed 失败——R43 的 B 设备测试
  ///   就是这么抓出来的：永久删除一道菜，会让别的设备**整轮同步报错**。
  ///   同表内仍按 seq 升序（LWW 靠 updated_at，不靠这里的顺序，但稳定序让日志可读）。
  List<Map<String, Object?>> _sortedByApplyOrder(List<Map> changes) {
    int orderOf(Object? tbl) {
      final i = ZaojiDb.syncedTablesSorted.indexWhere((t) => t.name == '$tbl');
      return i < 0 ? 1 << 30 : i;
    }

    bool isPurge(Map c) => '${c['op']}' == 'purge';

    final list = changes.map((c) => c.map((k, v) => MapEntry('$k', v))).toList()
      ..sort((a, b) {
        final pa = isPurge(a), pb = isPurge(b);
        if (pa != pb) return pa ? 1 : -1;
        final byTable = pa
            ? orderOf(b['tbl']).compareTo(orderOf(a['tbl']))
            : orderOf(a['tbl']).compareTo(orderOf(b['tbl']));
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

    // ★ R43 · `purge` 是「永久删除」，与 delete 不是一档：这里**物理删**，不打墓碑。
    //   子行（ingredient/step）由服务端级联成一条条独立的 purge 变更送过来，
    //   所以本机逐条照办就行，不需要在这里猜"这道菜的子行有哪些"。
    //   老服务端不会发这个 op（它没有 /api/purge），所以这条分支只可能来自新服务端。
    if ('${change['op']}' == 'purge') {
      // 删不到也算应用过（本机可能早就没有这一行），但不虚报计数。
      final had = await _selectRow(tbl, allowed, rowId);
      if (had == null) return 0;
      await _db.customUpdate(
        'DELETE FROM $tbl WHERE id = ?',
        variables: [Variable(rowId)],
      );
      return 1;
    }

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

    final sets = [
      for (final c in allowed)
        if (c != 'id') '$c = ?',
    ].join(', ');
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
    String tbl,
    List<String> cols,
    String rowId,
  ) async {
    final rows = await _db
        .customSelect(
          'SELECT ${cols.join(', ')} FROM $tbl WHERE id = ?',
          variables: [Variable(rowId)],
        )
        .get();
    return rows.isEmpty ? null : rows.first.data;
  }

  // ───────────────────────── AI 代理（R27） ─────────────────────────

  /// `/api/ai/*` 的统一直达通道：鉴权与同步走同一个 token，
  /// 失败原样抛（`SyncTransportException` 带服务端的 error/message，
  /// UI 按 kind 分支：off=去开开关、auth=Key 被拒、timeout=去设置页…）。
  ///
  /// 服务端返回非 2xx 也走异常；缓存状态留在 [aiStatusCache] 供入口徽标同步读。
  Future<Map<String, Object?>> aiCall(String path,
      [Map<String, Object?>? body]) async {
    final token = await _prefs.token();
    final serverUrl = await _prefs.serverUrl();
    if (serverUrl == null) {
      throw StateError('还没有可用的服务端地址，无法使用 AI 能力');
    }
    final t = await _transportOf(serverUrl);
    final res = body == null
        ? await t.get(path, token: token)
        : await t.post(path, body, token: token);
    if (path == '/api/ai/status') aiStatusCache = res;
    return res;
  }

  /// 最近一次 `/api/ai/status` 的响应。null = 本会话还没读到。
  /// 入口徽标（FR-AI-10「未配置」）读它——**读不到按未配置渲染**，
  /// 布局照旧占位，绝不因「还没查」而把入口抹掉。
  Map<String, Object?>? aiStatusCache;

  bool get aiLooksConfigured => aiStatusCache?['configured'] == true;

  // ───────────────────────── 媒体（R16 / R17） ─────────────────────────

  /// 已拉取的媒体字节缓存。内容寻址 = 同一个 `(sha256, 档位)` 永远是同一份字节，
  /// 所以缓存不需要失效逻辑，只需限容量。
  ///
  /// 容量按「条」算，而不是按「张」：同一个 sha 现在会占两格
  /// （列表的 card 档 + 详情的 detail 档），所以给了 96 而不是原先的 64。
  final Map<String, Uint8List> _mediaCache = {};
  static const int _mediaCacheCap = 96;

  static String _mediaKey(String sha, int? width) =>
      width == null ? '$sha@full' : '$sha@$width';

  /// 上传图片字节：客户端算 sha256 → `PUT /api/media/<sha>`。
  ///
  /// 哈希在**本地**算好当 URL 用——服务端会重算比对，不一致就拒绝，
  /// 所以这里传错了也传不进去。返回内容哈希，给 `recipe.cover_sha256` 引用。
  /// 未配对 / 网络失败原样抛（编辑页决定怎么降级：提示后继续保存无封面）。
  Future<String> uploadMedia(Uint8List bytes) async {
    final token = await _prefs.token();
    final serverUrl = await _prefs.serverUrl();
    if (serverUrl == null) {
      throw StateError('还没有可用的服务端地址，无法上传图片');
    }
    final sha = crypto.sha256.convert(bytes).toString();
    // R21：token 可选——开放模式的来访者也能传图（服务端按 X-Node-Id 认它）。
    await (await _transportOf(
      serverUrl,
    )).putBytes('/api/media/$sha', bytes, token: token);
    return sha;
  }

  /// 按内容哈希拉取图片字节（带内存缓存，见 [_mediaCacheCap]）。
  ///
  /// [width] 为 null → **原图**（客户端压过的 1600px/q82）；
  /// 传档位 → 该档**缩略图**，字节由服务端按需派生并缓存。
  /// 只有 [MediaWidth] 里那两档有效——服务端是白名单，别的宽度一律 400
  /// （刻意不做「不认识就回原图」的静默降级）。
  ///
  /// 未配对 / 404 / 网络失败都返回 null：显示端降级为封面插画，
  /// 把「没有封面」当常态处理，而不是当错误弹窗。
  Future<Uint8List?> fetchMediaCached(String sha, {int? width}) async {
    final key = _mediaKey(sha, width);
    final hit = _mediaCache[key];
    if (hit != null) return hit;

    final token = await _prefs.token();
    final serverUrl = await _prefs.serverUrl();
    if (serverUrl == null) return null;
    try {
      final path =
          width == null ? '/api/media/$sha' : '/api/media/$sha?w=$width';
      final bytes = await (await _transportOf(
        serverUrl,
      )).getBytes(path, token: token);
      if (_mediaCache.length >= _mediaCacheCap) {
        _mediaCache.remove(_mediaCache.keys.first);
      }
      _mediaCache[key] = bytes;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  // ───────────────────── R38 · 存活 / 差异 / 进度 ─────────────────────
  //
  // 三条都是同一件事的三面：**同步不能是暗箱**。之前手机上点了「上传改动」
  // 界面毫无反应（引擎在跑，但没人告诉 UI 跑到哪、有没有东西可跑），
  // 也不知道那台电脑到底活着没有——只能等超时后弹一条错误。

  ServerPing? _serverPing;

  /// 最近一次存活探测的结果；null = 这次启动还没探过。
  ServerPing? get serverPing => _serverPing;

  SyncDiff? _diff;

  /// 最近一次算出的两端差异；null = 还没算过。
  SyncDiff? get diff => _diff;

  SyncProgress? _progress;

  /// 正在跑的那轮同步走到哪了；null = 空闲。
  SyncProgress? get progress => _progress;

  /// 探活：打 `/api/ping` 并量往返延迟。
  ///
  /// **不抛异常**——探不到就是一种结果（[ServerPing.ok] = false + 原话），
  /// 界面上要能显示「连不上这台电脑」而不是一片转圈。
  /// [urlOverride] 同 [refreshAccessConfig]：认界面上正在输入的地址。
  Future<ServerPing> pingServer({String? urlOverride}) async {
    final url = urlOverride != null && urlOverride.trim().isNotEmpty
        ? _normalizeUrl(urlOverride)
        : await _prefs.serverUrl();
    if (url == null) {
      return _serverPing = const ServerPing(ok: false, error: '还没填服务端地址');
    }
    final sw = Stopwatch()..start();
    try {
      final res = await (await _transportOf(url))
          .get('/api/ping')
          .timeout(const Duration(seconds: 5));
      sw.stop();
      _serverPing = ServerPing(
        ok: true,
        serverId: '${res['serverId'] ?? ''}',
        latencyMs: sw.elapsedMilliseconds,
      );
    } on SyncTransportException catch (e) {
      sw.stop();
      _serverPing = ServerPing(
        ok: false,
        latencyMs: sw.elapsedMilliseconds,
        error: e.statusCode == 0 ? '连不上（地址不通或服务没起）' : '服务端返回 ${e.statusCode}',
      );
    } catch (e) {
      sw.stop();
      _serverPing = ServerPing(ok: false, latencyMs: sw.elapsedMilliseconds, error: '$e');
    }
    notifyListeners();
    return _serverPing!;
  }

  /// 算两端差异：本机下一轮真会发多少行、服务端领先多少条变更。
  ///
  /// **待推的口径必须与 [_pushPending] 逐字同源**（`updated_at > 推水位线`），
  /// 不能自作聪明。试过一条"更聪明"的口径：把服务端盖过章的行
  /// （`updated_at` 的 HLC 节点 == serverId）排除掉，理由是"那些行服务端显然已经有了"。
  /// 真机上立刻翻车：手机停在「仅上传」模式时永远收不到回声，那 98 行的节点
  /// 还是 `seed`，于是它显示 0、按钮被禁用，而引擎其实还有东西要发——
  /// **一个会说谎的 0 比一个偏大的 N 危险得多**。
  ///
  /// 所以这里就是"下一轮会发多少行"：拉回别人改动后它可能暂时偏大
  /// （那些回声行会被下一轮空推一次，服务端判 skipped，然后归零），
  /// 但它永远不小于真实要发的量，也永远不在还有活计时显示 0。
  ///
  /// 待拉 = 服务端 `nowSeq - 本机游标`（change_log 的 seq 差，含被白名单跳过的条目，
  /// 所以它是"服务端领先多少"而不是"我会应用多少行"——够用来判断要不要点按钮）。
  /// 探不到服务端时 remotePending = -1（未知），界面上「未知」比假数字诚实。
  Future<SyncDiff?> computeDiff({String? urlOverride}) async {
    final watermark = await _prefs.pushWatermark();
    var local = 0;
    for (final table in ZaojiDb.syncedTables) {
      final rows = await _db
          .customSelect(
            'SELECT COUNT(*) AS c FROM ${table.name} WHERE updated_at > ?',
            variables: [Variable(watermark)],
          )
          .get();
      local += rows.first.read<int>('c');
    }
    // 半路没确认的那一批也算有差异（否则按钮被禁用，用户没法把它重试出去）。
    if (local == 0 && await _prefs.pendingMutationId() != null) local = 1;

    final url = urlOverride != null && urlOverride.trim().isNotEmpty
        ? _normalizeUrl(urlOverride)
        : await _prefs.serverUrl();
    if (url == null) {
      _diff = null;
      notifyListeners();
      return null;
    }
    final token = await _prefs.token();
    final hasToken = token != null && token.isNotEmpty;
    try {
      final cursor = await _prefs.pullCursor();
      final res = await (await _transportOf(url))
          .get('/api/changes?since=$cursor&limit=1', token: hasToken ? token : null)
          .timeout(const Duration(seconds: 5));
      final nowSeq = (res['nowSeq'] as num?)?.toInt() ?? cursor;
      _diff = SyncDiff(localPending: local, remotePending: (nowSeq - cursor).clamp(0, 1 << 30));
    } catch (_) {
      _diff = SyncDiff(localPending: local, remotePending: -1); // -1 = 服务端那边不知道
    }
    notifyListeners();
    return _diff;
  }

  void _setProgress(SyncProgress? p) {
    _progress = p;
    notifyListeners();
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

/// 同步策略（FR-DATA-05）。`wire` 是落进 local_pref 的字符串，别改名——
/// 老设备上存过的值要能被新包读回来。
enum SyncMode {
  bidir('bidir', '双向合并'),
  upload('upload', '仅上传'),
  download('download', '仅下载');

  const SyncMode(this.wire, this.label);

  /// 落库值。
  final String wire;

  /// 界面上的词。
  final String label;

  static SyncMode parse(String? raw) =>
      SyncMode.values.firstWhere((m) => m.wire == raw, orElse: () => bidir);
}

/// 服务端存活探测的结果（R38）。
class ServerPing {
  const ServerPing({
    required this.ok,
    this.serverId = '',
    this.latencyMs = 0,
    this.error,
  });

  final bool ok;
  final String serverId;

  /// 往返毫秒。探不通时是"花多久才断定不通"。
  final int latencyMs;
  final String? error;

  String get label => ok ? '连接正常 · $latencyMs ms' : (error ?? '连不上');
}

/// 两端差异（R38）。`remotePending < 0` = 服务端那边问不到（未知，不是 0）。
class SyncDiff {
  const SyncDiff({required this.localPending, required this.remotePending});

  /// 本机还没推上去的行数。
  final int localPending;

  /// 服务端领先本机游标多少条变更。
  final int remotePending;

  bool get remoteKnown => remotePending >= 0;
  bool get nothingToPush => localPending == 0;
  bool get nothingToPull => remotePending == 0;
}

/// 一轮同步走到哪了（R38）。`total == 0` 表示总数未知 → 界面走不确定态进度条。
class SyncProgress {
  const SyncProgress(this.stage, {this.done = 0, this.total = 0});

  final SyncStage stage;
  final int done;
  final int total;

  double? get ratio => total <= 0 ? null : (done / total).clamp(0.0, 1.0);

  String get label => switch (stage) {
        SyncStage.connecting => '正在连接服务端…',
        SyncStage.pushing => total <= 0 ? '正在上传…' : '正在上传 $done/$total 批',
        SyncStage.pulling => total <= 0 ? '正在下载…' : '正在下载 $done/$total 页',
      };
}

enum SyncStage { connecting, pushing, pulling }

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

/// 图片档位——**必须与服务端 `MediaStore.thumbWidths` 逐值对齐**。
///
/// 服务端只认这两档（白名单，认不出的一律 400，**不做「不认识的宽度就回原图」的静默降级**）：
/// 派生结果要落盘成 `<sha>-<w>.jpg`，接受任意 w 就等于给了一条
/// `?w=1`、`?w=2` … 把家里那台笔记本磁盘写满的路径。
///
/// 两档的取值理由（按手机端实际显示尺寸反推）：
/// - [card]：列表 390 逻辑像素宽两列，卡片约 173 逻辑像素 × 3 DPR ≈ 519 物理像素 → 640 够。
/// - [detail]：详情满宽 390 逻辑像素 × 3 DPR ≈ 1170 → 1280 够。
///
/// **为什么列表必须走缩略图**：原图是客户端压过的 1600px/q82（约 200~500 KB），
/// 一屏 6 张卡片就是 1.5~3 MB。局域网不慢，但手机为它付出的解码时间与常驻内存是真的，
/// 而列表里根本看不出 1600px 与 640px 的区别。
class MediaWidth {
  const MediaWidth._();

  /// 列表卡片缩略图。
  static const int card = 640;

  /// 详情大图。
  static const int detail = 1280;
}
