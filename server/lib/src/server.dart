import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import 'config.dart';
import 'file_log.dart';
import 'media.dart';
import 'media_gc.dart';
import 'server_state.dart';
import 'sync.dart';
import 'web_pages.dart';

/// 灶记服务端。
///
/// 当前进度：骨架 + HTTPS + 数据底座（M1）+ 同步接口（配对 / 拉取 / 推送）。
/// 图片管线与 AI 代理还没做（见 [kEndpoints] 里的 planned 项）。
class ZaojiServer {
  final ServerState state;
  final HttpServer _http;

  /// HTTPS 监听。证书不存在时为 null —— 那时 http 仍可用，
  /// 但 iOS 端的屏幕常亮 / 计时通知 / PWA 离线 / 调相机四样能力都会失效。
  final HttpServer? _https;

  final List<String> localIps;

  ZaojiServer._(this.state, this._http, this._https, this.localIps);

  int get port => _http.port;
  int get tlsPort => _https?.port ?? state.config.tlsPort;

  /// HTTPS 是否真的起来了。启动横幅与状态页都据此显示不同文案。
  bool get tlsReady => _https != null;

  Uri get localUri => Uri.parse('http://127.0.0.1:$port/');
  Uri? get localTlsUri =>
      tlsReady ? Uri.parse('https://127.0.0.1:$tlsPort/') : null;

  List<Uri> get lanUris => localIps
      .map((ip) => Uri.parse('http://$ip:$port/'))
      .toList(growable: false);

  List<Uri> get tlsLanUris => tlsReady
      ? localIps
          .map((ip) => Uri.parse('https://$ip:$tlsPort/'))
          .toList(growable: false)
      : const <Uri>[];

  static Future<ZaojiServer> start(ServerConfig config) async {
    final state = await ServerState.boot(config);
    final ips = await ServerState.localIPv4();
    final handler = buildHandler(state, ips);

    final http = await shelf_io.serve(
      handler,
      config.host,
      config.port,
      poweredByHeader: null, // 不暴露 Dart 版本，局域网里也没必要
    );
    http.autoCompress = true;

    final https = await _startTls(config, handler, state.log);
    state.tlsReady = https != null; // 回填给 /api/health 与状态页

    return ZaojiServer._(state, http, https, ips);
  }

  /// 证书在就开 HTTPS，不在就安静跳过。
  ///
  /// 但**不会默默降级**——启动横幅与状态页都会明确写出
  /// 「iOS 端会因此失去什么」，否则用户只会看到「Safari 说这不是安全连接」
  /// 然后一头雾水。
  static Future<HttpServer?> _startTls(
      ServerConfig config, Handler handler, FileLog log) async {
    final cert = File(config.certPath);
    final key = File(config.keyPath);
    if (!await cert.exists() || !await key.exists()) return null;

    try {
      final ctx = SecurityContext()
        ..useCertificateChain(config.certPath)
        ..usePrivateKey(config.keyPath);

      final server =
          await HttpServer.bindSecure(config.host, config.tlsPort, ctx);
      server.autoCompress = true;
      shelf_io.serveRequests(server, handler);
      return server;
    } catch (e) {
      await log.write('⚠️  HTTPS 启动失败：$e\n'
          '    http 仍可用，但 iOS 端的屏幕常亮 / 计时通知 / PWA 离线会失效。');
      return null;
    }
  }

  Future<void> stop() async {
    await _http.close(force: true);
    await _https?.close(force: true);
    // 关库放在最后：先把对外的门关上，再收内部资源。
    // 不关的话 Windows 上会留下 -wal/-shm 文件句柄，数据目录删不掉。
    await state.close();
  }

  /// 路由表。抽成静态方法，方便将来直接跑集成测试而不用真的监听端口。
  static Handler buildHandler(ServerState state, List<String> ips) {
    final router = Router()
      ..get('/api/ping', (Request req) => _json(state.pingPayload()))
      ..get('/api/health',
          (Request req) async => _json(await state.healthPayload()))
      ..get('/status',
          (Request req) async => _html(await statusPageHtml(
              state, ips, isAdmin: _isLocalRequest(req))))
      // 配对码只能从本机取——否则局域网里任何人都能自己配对
      ..get('/api/pair/code', (Request req) => _pairCode(state, req))
      ..post('/api/pair', (Request req) => _pair(state, req))
      // R21：准入模式查询（免鉴权，但**绝不回口令**）与口令接入
      ..get('/api/sync/config', (Request req) => _syncConfig(state, req))
      ..post('/api/join', (Request req) => _join(state, req))
      // 数据接口：token 必过；开放模式下匿名请求按 X-Node-Id 记来访者伪设备
      ..get('/api/changes', (Request req) => _pull(state, req))
      ..post('/api/changes', (Request req) => _push(state, req))
      // R22：冲突裁决。鉴权与数据接口同一套（token 优先、开放模式认来访者）。
      ..post('/api/conflicts/resolve',
          (Request req) => _resolveConflicts(state, req))
      // 媒体接口（R16）：同样要 token。GET 是显示端按需拉取，PUT 是上传。
      ..put('/api/media/<sha>',
          (Request req) => _mediaPut(state, req, req.params['sha']!))
      ..get('/api/media/<sha>',
          (Request req) => _mediaGet(state, req, req.params['sha']!))
      // 运维接口（R18）：孤儿媒体回收。**只允许从服务端本机触发**——
      // 删除不可逆，不该让局域网里任何一台设备有机会碰到它。
      ..post('/api/admin/media-gc', (Request req) => _mediaGc(state, req))
      // R21：准入设置（模式/口令/手动同步策略）。同样**仅本机**——
      // 把准入门开关交给局域网里任何设备，等于没有门。
      ..get('/api/admin/settings', (Request req) => _adminSettings(state, req))
      ..post('/api/admin/settings',
          (Request req) => _adminSettings(state, req));

    /// 首页：如果托管了 Flutter Web 产物，让位给它——
    /// 否则用户打开地址看到的永远是状态页，而不是他要的 App。
    router.get('/', (Request req) async {
      final web = state.config.webRoot;
      if (web != null && await web.exists()) {
        final index = await _tryStatic('index.html', web,
            acceptEncoding: req.headers['accept-encoding']);
        if (index != null) return index;
      }
      return _html(await statusPageHtml(state, ips));
    });

    final routerHandler = router.call;

    /// 兜底：先试静态文件（Flutter Web 的 assets 走这里），
    /// 再试 SPA 回退，最后才是 404。
    Future<Response> resolve(Request req) async {
      final res = await routerHandler(req);
      if (res.statusCode != 404) return res;

      final web = state.config.webRoot;
      if (web != null && await web.exists()) {
        final rel = req.url.path.isEmpty ? 'index.html' : req.url.path;
        final staticRes = await _tryStatic(rel, web,
            acceptEncoding: req.headers['accept-encoding']);
        if (staticRes != null) return staticRes;

        // SPA 回退：Flutter Web 的路由不在文件系统里，
        // 刷新深层路径时必须回 index.html，否则一刷新就 404。
        if (req.method == 'GET' && !rel.startsWith('api/')) {
          final index = await _tryStatic('index.html', web,
              acceptEncoding: req.headers['accept-encoding']);
          if (index != null) return index;
        }
      }

      if (req.method == 'GET') {
        return _html(notFoundHtml('/${req.url.path}'), status: 404);
      }
      return _json(
        {'ok': false, 'code': 'NOT_FOUND', 'message': '这个接口还没有实现'},
        status: 404,
      );
    }

    // ⚠️ **日志中间件必须包在最外层。**
    //
    // 它原来只包住 `router`，于是 Flutter Web 的静态资源在日志里**全部记成 404**：
    // 路由确实返回了 404（它不认识 `/main.dart.js`），但紧接着外层把文件取出来
    // 给了客户端 200。**日志于是与客户端看到的事实完全相反**——
    // 排查「资源加载不了」时会一路往错的方向查（我 2026-09-18 就被它骗了一次：
    // 看到满屏 404，差点判定静态托管坏了，而截图里应用是完整渲染的）。
    //
    // 日志的价值在于「它记录的是最终发生的事」。放错位置时，它记的是**内部中间状态**，
    // 比没有日志更危险。
    return const Pipeline()
        .addMiddleware(_logRequests(state))
        .addHandler(resolve);
  }

  // ── 同步接口 ──

  /// 发一个配对码。
  ///
  /// **只允许从服务端那台电脑上取。** 否则局域网里任何人打开
  /// `http://192.168.x.x:8666/api/pair/code` 就能给自己发一个码、然后配对成功，
  /// 配对码就白设了。
  ///
  /// 测试环境里没有连接信息（没真的监听端口），按本机处理。
  /// 真实监听时 `shelf_io` 一定会放进来，所以这不是漏洞。
  /// 唯一的例外是前面挂了反向代理——那种部署下 remoteAddress 会是 127.0.0.1。
  /// 本项目是局域网直连，不存在这个前提。
  static Response _pairCode(ServerState state, Request req) {
    if (!_isLocalRequest(req)) {
      return _json({
        'error': 'forbidden',
        'message': '配对码只能在服务端那台电脑上获取。'
            '请在电脑的浏览器里打开 http://127.0.0.1:${state.config.port}/api/pair/code',
      }, status: 403);
    }
    final gate = _requireMode(state, SyncAccessMode.pairCode);
    if (gate != null) return gate;
    final c = state.sync.issuePairCode();
    return _json({
      ...c.toJson(),
      'serverId': state.serverId,
      'protocolVersion': kSyncProtocolVersion,
    });
  }

  /// 三态互斥的闸门：模式不对就 409，**不悄悄兼容另一种接入方式**。
  /// 悄悄兼容的结局是管理员以为口令保护住了数据，实际配对码门还开着。
  static Response? _requireMode(ServerState state, SyncAccessMode want) {
    if (state.sync.accessMode == want) return null;
    return _json({
      'error': 'mode_mismatch',
      'message': '当前准入模式是「${state.sync.accessMode.label}」，'
          '这个接口只在「${want.label}」模式下可用。'
          '服务端这台电脑的浏览器打开 /status 可以切换。',
      'accessMode': state.sync.accessMode.wire,
    }, status: 409);
  }

  static bool _isLocalRequest(Request req) {
    final info = req.context['shelf.io.connection_info'];
    // 值是 dart:io 的 HttpConnectionInfo（由 shelf_io 放进 context）
    if (info is! HttpConnectionInfo) return isLocalAddress(null);
    return isLocalAddress(info.remoteAddress.address);
  }

  /// 本机地址判定。抽成公开的纯函数，是为了让它**可被单测覆盖**——
  /// 塞在一个只看 `Request` 的私有方法里，就只能靠真起一个局域网连接来验，
  /// 而那条路在测试里走不通（拿不到非回环的 remoteAddress）。
  ///
  /// `null`（没有连接信息，即测试环境）按本机处理，与 [HttpConnectionInfo] 缺位时一致。
  static bool isLocalAddress(String? address) {
    if (address == null) return true;
    return address == '127.0.0.1' || address == '::1' || address == 'localhost';
  }

  /// 用配对码换 token。
  ///
  /// **有失败限流**（R12）：配对码空间 31^6 ≈ 8.9×10⁸、TTL 5 分钟，
  /// 不限流的话局域网里的攻击者可以高速枚举。窗口内失败满
  /// [SyncService.maxPairFailsPerWindow] 次就 429；**成功配对清空记录**
  /// （不惩罚手滑）。参数残缺（400 类）不计入失败——那是客户端 bug，不是猜测。
  static Future<Response> _pair(ServerState state, Request req) async {
    final gate = _requireMode(state, SyncAccessMode.pairCode);
    if (gate != null) return gate;

    final peer = _peerKey(req);
    if (state.sync.pairBlocked(peer)) {
      return _json(
          {
            'error': 'too_many_attempts',
            'message': '配对失败次数过多，请 1 分钟后再试',
          },
          status: 429,
          headers: const {'retry-after': '60'});
    }

    final Map<String, Object?>? body;
    try {
      body = await _readJson(req);
    } on _BodyTooLarge {
      return _payloadTooLarge();
    }
    if (body == null) {
      return _json({'error': 'bad_request', 'message': '请求体必须是 JSON'},
          status: 400);
    }

    final code = '${body['code'] ?? ''}';
    final deviceId = '${body['deviceId'] ?? ''}';
    final deviceName = '${body['deviceName'] ?? ''}';
    // 超长字段直接 400：配对码 6 位、设备名给人看，没有合法的超长输入
    if (code.length > 32 || deviceId.length > 64 || deviceName.length > 128) {
      return _json({
        'error': 'bad_request',
        'message': '字段超长（code≤32 / deviceId≤64 / deviceName≤128）'
      }, status: 400);
    }

    final outcome = state.sync.redeem(
      code: code,
      deviceId: deviceId,
      deviceName: deviceName,
    );

    if (outcome.ok) {
      state.sync.clearPairFails(peer);
      return _json(outcome.toJson());
    }

    // 码不对 / 过期 / 用过 → 403；参数缺失 → 400。
    // 分开是刻意的：客户端要能把"再试一次"和"重新获取码"区分开。
    final isBadRequest = outcome.failure == PairFailure.emptyCode ||
        outcome.failure == PairFailure.missingDeviceId;
    if (!isBadRequest) state.sync.recordPairFail(peer);
    return _json(outcome.toJson(), status: isBadRequest ? 400 : 403);
  }

  /// 请求来源标识（限流用）。测试环境没有连接信息，按本机处理。
  static String _peerKey(Request req) {
    final info = req.context['shelf.io.connection_info'];
    if (info is! HttpConnectionInfo) return 'local';
    return info.remoteAddress.address;
  }

  // ───────────────── R21 · 准入：config / join / admin settings ─────────────────

  /// 免鉴权的准入查询：客户端进「我的」页先看这个，决定渲染哪套接入 UI。
  ///
  /// **绝不回口令本身**——回口令的话，开放模式关掉之前所有人已经把口令存下了；
  /// 而且这接口谁都能调，等于把口令贴在门上。
  static Response _syncConfig(ServerState state, Request req) => _json({
        'ok': true,
        'accessMode': state.sync.accessMode.wire,
        'visitorManualSync': state.sync.visitorManualSync,
        'protocolVersion': kSyncProtocolVersion,
        'serverId': state.serverId,
      });

  /// 口令模式：固定口令换本机专属 token。
  ///
  /// 限流与配对码共用一套窗口逻辑，但**分开计数**（键加 `join#` 前缀）——
  /// 否则攻击者可以一半额度试配对、一半试口令，两边各自都没触发限流。
  static Future<Response> _join(ServerState state, Request req) async {
    final gate = _requireMode(state, SyncAccessMode.passcode);
    if (gate != null) return gate;

    final peer = 'join#${_peerKey(req)}';
    if (state.sync.pairBlocked(peer)) {
      return _json({
        'error': 'too_many_attempts',
        'message': '口令错误次数过多，请 1 分钟后再试',
      }, status: 429, headers: const {'retry-after': '60'});
    }

    final Map<String, Object?>? body;
    try {
      body = await _readJson(req);
    } on _BodyTooLarge {
      return _payloadTooLarge();
    }
    if (body == null) {
      return _json({'error': 'bad_request', 'message': '请求体必须是 JSON'},
          status: 400);
    }

    final passcode = '${body['passcode'] ?? ''}';
    final deviceId = '${body['deviceId'] ?? ''}';
    final deviceName = '${body['deviceName'] ?? ''}';
    if (passcode.length > 64 || deviceId.length > 64 || deviceName.length > 128) {
      return _json({
        'error': 'bad_request',
        'message': '字段超长（passcode≤64 / deviceId≤64 / deviceName≤128）'
      }, status: 400);
    }

    final outcome = state.sync.joinWithPasscode(
      passcode: passcode,
      deviceId: deviceId,
      deviceName: deviceName,
    );
    if (outcome.ok) {
      state.sync.clearPairFails(peer);
      // 谁进来了要留痕（口令是共享的，事后追溯只能靠设备登记）
      await state.log.write('[access] 口令接入成功：设备 ${body['deviceId']}');
      return _json(outcome.toJson());
    }

    // 只有「口令不对」才是真实的猜测；参数残缺与服务端未配置不该罚提问者
    if (outcome.failure == PairFailure.wrongPasscode) {
      state.sync.recordPairFail(peer);
      return _json(outcome.toJson(), status: 403);
    }
    if (outcome.failure == PairFailure.passcodeNotSet) {
      return _json(outcome.toJson(), status: 503);
    }
    return _json(outcome.toJson(), status: 400);
  }

  /// 准入设置。**仅本机**（与配对码/媒体回收同一条理由）。
  ///
  /// 口令写入后**不回显**（只回 `hasPasscode`）：状态页会被截屏、会被贴进群里，
  /// 口令出现在 HTML 里就再也收不回来。要改口令，重新设一个就是。
  static Future<Response> _adminSettings(ServerState state, Request req) async {
    if (!_isLocalRequest(req)) {
      return _json({
        'error': 'forbidden',
        'message': '准入设置只能在服务端那台电脑上修改（/status 状态页）',
      }, status: 403);
    }

    if (req.method == 'GET') return _json(_accessSummary(state));

    final Map<String, Object?>? body;
    try {
      body = await _readJson(req);
    } on _BodyTooLarge {
      return _payloadTooLarge();
    }
    if (body == null) {
      return _json({'error': 'bad_request', 'message': '请求体必须是 JSON'},
          status: 400);
    }

    final changes = <String>[];
    if (body.containsKey('accessMode')) {
      final m = SyncAccessMode.parse('${body['accessMode']}');
      // 解析失败绝不能回落到默认模式——那等于配置打错字时把门打开
      if (m == null) {
        return _json({
          'error': 'bad_request',
          'message': 'accessMode 只接受 open / passcode / pairCode，'
              '收到 "${body['accessMode']}"',
        }, status: 400);
      }
      if (m != state.sync.accessMode) {
        state.sync.accessMode = m;
        changes.add('模式→${m.label}');
      }
    }
    if (body.containsKey('passcode')) {
      final p = '${body['passcode'] ?? ''}'.trim();
      if (p.length > 64) {
        return _json({'error': 'bad_request', 'message': '口令最长 64 字符'},
            status: 400);
      }
      state.sync.setPasscode(p.isEmpty ? null : p);
      changes.add(p.isEmpty ? '口令已清除' : '口令已更新');
    }
    if (body.containsKey('visitorManualSync')) {
      final v = body['visitorManualSync'];
      if (v is! bool) {
        return _json({
          'error': 'bad_request',
          'message': 'visitorManualSync 必须是布尔',
        }, status: 400);
      }
      state.sync.visitorManualSync = v;
      changes.add('来访者手动同步→${v ? '开' : '关'}');
    }

    // 准入策略的每一次变化都必须留痕：日后「数据怎么被人改了」全靠这行
    if (changes.isNotEmpty) {
      await state.log.write('[access] 准入设置变更：${changes.join('，')}');
    }
    return _json(_accessSummary(state));
  }

  static Map<String, Object?> _accessSummary(ServerState state) => {
        'ok': true,
        'accessMode': state.sync.accessMode.wire,
        'hasPasscode': (state.sync.passcode ?? '').isNotEmpty,
        'visitorManualSync': state.sync.visitorManualSync,
      };

  /// 数据/媒体接口的统一鉴权入口（替换原来裸的 `authenticate`）。
  ///
  /// 顺序刻意是「先 token、后模式」：合法 token 在**任何模式下都直接通过**——
  /// 这是三态设计里对用户最重要的承诺：切模式不会把已经配好的设备关在门外。
  static Device? _resolveDevice(ServerState state, Request req) {
    final byToken = state.sync.authenticate(req.headers['authorization']);
    if (byToken != null) return byToken;
    if (state.sync.accessMode == SyncAccessMode.open) {
      return state.sync.visitorDevice(req.headers[kNodeIdHeader]);
    }
    return null;
  }

  /// 增量拉取。
  static Future<Response> _pull(ServerState state, Request req) async {
    final device = _resolveDevice(state, req);
    if (device == null) return _unauthorized(state);

    final q = req.url.queryParameters;
    final since = int.tryParse(q['since'] ?? '0');
    if (since == null || since < 0) {
      return _json({'error': 'bad_request', 'message': 'since 必须是非负整数'},
          status: 400);
    }
    var limit = int.tryParse(q['limit'] ?? '500') ?? 500;
    if (limit < 1) limit = 1;
    if (limit > 1000) limit = 1000; // 一次拉太多，手机端会卡在解析上

    final result = state.sync.pull(since: since, limit: limit);
    // 只作对账用：记下"这台设备报到哪儿了"，不参与下次拉取的判断
    state.sync.noteCursor(device.id, result.lastSeq);
    return _json(result.toJson());
  }

  /// 增量推送。幂等：同一个 mutationId 重试会拿到上次的结果。
  static Future<Response> _push(ServerState state, Request req) async {
    final device = _resolveDevice(state, req);
    if (device == null) return _unauthorized(state);

    final Map<String, Object?>? body;
    try {
      body = await _readJson(req);
    } on _BodyTooLarge {
      return _payloadTooLarge();
    }
    if (body == null) {
      return _json({'error': 'bad_request', 'message': '请求体必须是 JSON'},
          status: 400);
    }

    // 协议版本不一致就拒绝，不要猜。
    // 猜错的后果是"某一端的字段永远同步不上，且两边都不报错"。
    final pv = body['protocolVersion'];
    if (pv != null && pv is int && pv != kSyncProtocolVersion) {
      return _json({
        'error': 'protocol_mismatch',
        'message': '协议版本不一致：服务端 $kSyncProtocolVersion，客户端 $pv。请先升级。',
        'serverProtocolVersion': kSyncProtocolVersion,
      }, status: 409);
    }

    final mutationId = '${body['mutationId'] ?? ''}';
    // mutationId 是幂等表的主键，给它上限挡住"用超长串把幂等表灌爆"
    if (mutationId.length > 128) {
      return _json({'error': 'bad_request', 'message': 'mutationId 超长（≤128）'},
          status: 400);
    }

    final raw = body['changes'];
    if (raw is! List) {
      return _json({'error': 'bad_request', 'message': 'changes 必须是数组'},
          status: 400);
    }
    // 一批的条数上限：合法的批量同步（几十条）远用不到 500，
    // 上限挡的是把服务端时间打在逐条校验上的恶意大批次。
    if (raw.length > 500) {
      return _json({
        'error': 'bad_request',
        'message': '一批最多 500 条变更（收到 ${raw.length} 条）'
      }, status: 400);
    }
    final changes = <Map<String, Object?>>[];
    for (final c in raw) {
      if (c is! Map) {
        return _json({'error': 'bad_request', 'message': 'changes 里每一项都必须是对象'},
            status: 400);
      }
      changes.add(c.map((k, v) => MapEntry('$k', v)));
    }

    final result = state.sync.push(
      device: device,
      mutationId: mutationId,
      changes: changes,
    );
    return _json(result.toJson(), status: result.ok ? 200 : 400);
  }

  /// R22 · 冲突裁决。逐条结果、整批事务（见 SyncService.resolveConflicts）。
  static Future<Response> _resolveConflicts(
      ServerState state, Request req) async {
    final device = _resolveDevice(state, req);
    if (device == null) return _unauthorized(state);

    final Map<String, Object?>? body;
    try {
      body = await _readJson(req);
    } on _BodyTooLarge {
      return _payloadTooLarge();
    }
    final items = body?['items'];
    if (items is! List || items.isEmpty || items.length > 200 ||
        !items.every((e) => e is Map)) {
      return _json({
        'error': 'bad_request',
        'message': 'items 必须是 1..200 个对象的数组',
      }, status: 400);
    }

    final results = state.sync.resolveConflicts(
      device: device,
      items: [
        for (final e in items) (e as Map).map((k, v) => MapEntry('$k', v)),
      ],
    );
    await state.log.write(
        '[conflict] ${device.name} 裁决 ${results.where((r) => r['outcome'] == 'applied').length} 条'
        '（收到 ${items.length}）');
    return _json({'ok': true, 'results': results});
  }

  static Response _unauthorized(ServerState state) {
    // 提示要按**当前模式**说：口令模式下让用户去输口令，
    // 别再让人家满世界找已经不该存在的配对码。
    final mode = state.sync.accessMode;
    final hint = switch (mode) {
      SyncAccessMode.open =>
        '开放模式下请求需带 X-Node-Id（本机设备标识，App/页面会自动带上）',
      SyncAccessMode.passcode => '请先在「我的」页输入连接口令完成接入',
      SyncAccessMode.pairCode => '请先在 App 里完成配对',
    };
    return _json({
      'error': 'unauthorized',
      'message': '缺少或无效的设备凭证。$hint。',
      'accessMode': mode.wire,
    }, status: 401);
  }

  // ── 媒体接口（R16）──

  /// 图片上传上限。客户端压到 1600px/q82 后通常 ≤ 500 KB，
  /// 10 MB 挡的是异常大图与恶意请求，不是正常业务。
  static const int _maxMediaBytes = 10 * 1024 * 1024;

  /// 读原始字节体（媒体上传用）。超 [_maxMediaBytes] 抛 [_BodyTooLarge]。
  /// 与 [_readJson] 同一条纪律：不信 Content-Length，逐块计数。
  static Future<Uint8List> _readBodyBytes(Request req) async {
    final declared = int.tryParse(req.headers['content-length'] ?? '') ?? 0;
    if (declared > _maxMediaBytes) throw const _BodyTooLarge();

    final builder = BytesBuilder(copy: false);
    await for (final chunk in req.read()) {
      builder.add(chunk);
      if (builder.length > _maxMediaBytes) throw const _BodyTooLarge();
    }
    return builder.takeBytes();
  }

  static Response _mediaBad(String message, {int status = 400}) =>
      _json({'error': 'bad_request', 'message': message}, status: status);

  /// 上传图片：PUT /api/media/<sha256>，请求体为原始字节。
  ///
  /// 四道闸门缺一不可：鉴权 → sha256 格式（挡路径穿越）→ 大小上限 →
  /// 哈希与格式校验。哈希不匹配必须拒绝——**哈希即内容契约**，
  /// 收下错图等于让显示端永久引用一张对不上的图。
  static Future<Response> _mediaPut(
      ServerState state, Request req, String sha) async {
    final device = _resolveDevice(state, req);
    if (device == null) return _unauthorized(state);

    if (!MediaStore.isValidSha(sha)) {
      return _mediaBad('sha256 必须是 64 位小写十六进制');
    }

    final Uint8List bytes;
    try {
      bytes = await _readBodyBytes(req);
    } on _BodyTooLarge {
      return _payloadTooLarge('图片超过上限（10 MB）');
    }
    if (bytes.isEmpty) return _mediaBad('请求体为空');

    final type = MediaStore.sniffImageType(bytes);
    if (type == null) {
      return _mediaBad('只接受 JPEG / PNG / WebP 图片', status: 415);
    }

    final actual = MediaStore.sha256Hex(bytes);
    if (actual != sha) {
      return _json({
        'error': 'hash_mismatch',
        'message': '内容哈希与 URL 不一致（URL: $sha，实际: $actual）',
      }, status: 400);
    }

    final r = await state.media.put(sha, bytes);

    // 顺手把两档缩略图派生好（best-effort，失败不影响这次上传的结果）：
    // 用户刚选完封面回到列表就应该看到图，而不是在列表里等第一次派生。
    await state.media.warmThumbs(sha);

    return _json({
      'ok': true,
      'sha256': r.sha,
      'size': r.size,
      'type': r.type,
      'duplicated': r.duplicated,
      'thumbs': MediaStore.thumbWidths
          .where((w) => state.media.thumbExists(sha, w))
          .toList(growable: false),
    });
  }

  /// 拉取图片：`GET /api/media/<sha256>`，可选 `?w=640|1280`。
  ///
  /// - 不带 `w` → **原图**（客户端压缩后的 1600px/q82）。
  /// - 带 `w` → 该档**缩略图**，首次访问时派生并落盘，之后直接读文件。
  ///
  /// 内容寻址 = 内容永不变更，因此可以放心让客户端**长缓存**；
  /// 缩略图同理——它是 `(sha, width)` 的纯函数，同样永不改变。
  static Future<Response> _mediaGet(
      ServerState state, Request req, String sha) async {
    final device = _resolveDevice(state, req);
    if (device == null) return _unauthorized(state);

    if (!MediaStore.isValidSha(sha)) {
      return _mediaBad('sha256 必须是 64 位小写十六进制');
    }

    final rawW = req.url.queryParameters['w'];
    if (rawW != null) {
      final w = int.tryParse(rawW);
      if (w == null || !MediaStore.isValidThumbWidth(w)) {
        // **不做「宽度不认识就回原图」的静默降级**：客户端把档位写错时，
        // 它应该立刻拿到一个明确的错误，而不是收到几 MB 原图、
        // 把问题藏成「怎么还是这么慢」——那种问题没人查得出来。
        return _mediaBad(
            '缩略图宽度只支持 ${MediaStore.thumbWidths.join(' / ')}（像素），收到 "$rawW"');
      }
      return _mediaThumb(state, sha, w);
    }

    final f = state.media.fileFor(sha);
    if (!await f.exists()) {
      return _json({'error': 'not_found', 'message': '没有这张图片'}, status: 404);
    }

    final bytes = await f.readAsBytes();
    final type = MediaStore.sniffImageType(bytes) ?? 'application/octet-stream';
    return Response.ok(bytes, headers: {
      'content-type': type,
      // 私有长缓存：图片带 token 才能拉（不应被共享代理缓存），但内容永不变
      'cache-control': 'private, max-age=31536000, immutable',
    });
  }

  /// 缩略图分支。原图不存在照样 404（派生源都没有，没什么好派的）。
  static Future<Response> _mediaThumb(
      ServerState state, String sha, int width) async {
    if (!state.media.exists(sha)) {
      return _json({'error': 'not_found', 'message': '没有这张图片'}, status: 404);
    }

    final Uint8List bytes;
    try {
      bytes = await state.media.readOrDeriveThumb(sha, width);
    } on FormatException {
      // 魔数过了但解不开（截断 / 伪造的文件头）。这是**这个文件**的问题，
      // 不是请求的问题——所以是 415 而不是 400/500。
      return _mediaBad('这张图片无法解码，派生不了缩略图', status: 415);
    }

    return Response.ok(bytes, headers: {
      // 一律 JPEG（统一格式，客户端不用按档位猜）
      'content-type': 'image/jpeg',
      'cache-control': 'private, max-age=31536000, immutable',
    });
  }

  // ── 运维接口（R18）──

  /// 孤儿媒体回收：`POST /api/admin/media-gc[?dry=0]`。
  ///
  /// **默认 dry-run**：不带参数只报告「打算删什么」，一个文件都不动；
  /// 要真删必须显式 `?dry=0`。删除不可逆，所以默认值必须是最安全的那个。
  ///
  /// **只允许从服务端本机触发**（与配对码同一条理由）：不该让局域网里
  /// 任何一台设备有机会碰到这个接口。
  ///
  /// 返回体里的 `danglingRefs`（库里有引用、盘上没文件）**只报告不修复**——
  /// 那是异常信号，自动「修」它只会把线索一起抹掉。
  static Future<Response> _mediaGc(ServerState state, Request req) async {
    if (!_isLocalRequest(req)) {
      return _json({
        'error': 'forbidden',
        'message': '媒体回收只能在服务端那台电脑上触发：'
            'curl.exe --noproxy "*" -X POST '
            'http://127.0.0.1:${state.config.port}/api/admin/media-gc',
      }, status: 403);
    }

    final dry = req.url.queryParameters['dry'] != '0';
    final r = await MediaGc.run(
      media: state.media,
      referenced: state.db.referencedCoverShas(),
      dryRun: dry,
    );

    // 不可逆的动作必须留痕。R19③ 之前只能靠 stdout（注册成服务后没有控制台），
    // 现在文件日志兜住了这一行；明细同时放进响应体，让触发的人当场看到删了什么。
    if (!r.dryRun) {
      await state.log.write('[gc] 回收 ${r.deletedFiles} 个文件 / '
          '${(r.freedBytes / 1024).toStringAsFixed(1)} KB'
          '${r.failures.isEmpty ? '' : '，失败 ${r.failures.length} 条'}'
          '${r.plan.orphanShas.isEmpty && r.plan.orphanThumbs.isEmpty ? '' : '，明细：${r.plan.orphanShas.map((s) => s.substring(0, 8)).join(",")}'}');
    }

    return _json({
      ...r.toJson(),
      'graceHours': MediaGc.defaultGrace.inHours,
      'hint': dry
          ? '这是预演（dry-run），一个文件都没删。确认无误后加 ?dry=0 真正执行。'
          : '已执行真实回收。',
    });
  }

  /// 读 JSON 请求体。解析失败返回 null（调用方给 400），不要抛；
  /// 体积超 [_maxBodyBytes] 抛 [_BodyTooLarge]（调用方给 413）。
  ///
  /// **必须限体积**：服务端口开在局域网上，`readAsString()` 无界读入内存，
  /// 一个恶意或异常的客户端一帧就能把家里那台笔记本打爆。
  /// 声明的 Content-Length 超限直接拒；没声明（chunked）就读一个字节算一个，
  /// 超过上限立刻断——不能信客户端自己报的数。
  static const int _maxBodyBytes = 5 * 1024 * 1024;

  static Future<Map<String, Object?>?> _readJson(Request req) async {
    try {
      final declared = int.tryParse(req.headers['content-length'] ?? '') ?? 0;
      if (declared > _maxBodyBytes) throw const _BodyTooLarge();

      final builder = BytesBuilder(copy: false);
      await for (final chunk in req.read()) {
        builder.add(chunk);
        if (builder.length > _maxBodyBytes) throw const _BodyTooLarge();
      }
      final text = utf8.decode(builder.takeBytes());
      if (text.trim().isEmpty) return null;
      final v = jsonDecode(text);
      if (v is! Map) return null;
      return v.map((k, val) => MapEntry('$k', val));
    } on _BodyTooLarge {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  static Response _payloadTooLarge([String? detail]) => _json({
        'error': 'payload_too_large',
        'message': detail ?? '请求体超过上限（5 MB）',
      }, status: 413);

  // ── 静态文件 ──

  /// 文本级可压缩的静态扩展名白名单（R25）。woff2/png/jpg 不在列——
  /// 它们已经自己压过，再压是白烧家里笔记本的 CPU。
  static const _gzippableExts = {
    'js', 'mjs', 'json', 'map', 'html', 'css', 'svg', 'wasm', 'txt'
  };

  /// gzip 结果的内存缓存：键 = 文件绝对路径，值带 mtime——
  /// 文件一改（发新版 Web 产物）缓存自然失效。
  /// 不缓存的话，每次请求现压 6.8 MB 的 canvaskit.wasm 要一两百毫秒，
  /// 等于把慢从网线上挪到了 CPU 上。
  static final _gzCache = <String, _GzEntry>{};
  static int _gzCacheBytes = 0;
  static const _gzCacheMaxBytes = 32 * 1024 * 1024;

  static Future<Response?> _tryStatic(String rel, Directory webRoot,
      {String? acceptEncoding}) async {
    // 目录穿越防护：这条必须在拼接路径之前。
    // 服务端口在局域网上是开放的，`/../../` 能读到什么谁也不好说。
    if (rel.contains('..')) return null;

    var path = rel;
    if (path.isEmpty || path.endsWith('/')) path = '${path}index.html';

    final f = File(
      '${webRoot.path}${Platform.pathSeparator}'
      '${path.replaceAll('/', Platform.pathSeparator)}',
    );
    if (!await f.exists()) return null;

    final bytes = await f.readAsBytes();
    final fileName = path.split('/').last;
    final headers = <String, String>{
      'content-type': mimeOf(fileName),
      // index.html 绝不能缓存：Flutter 发新版本后，
      // 缓存住的旧 index 会去拉已经不存在的旧 assets，页面直接白屏。
      'cache-control': fileName == 'index.html'
          ? 'no-cache, no-store, must-revalidate'
          : 'public, max-age=604800',
    };

    final dot = fileName.lastIndexOf('.');
    final ext = dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
    final wantGzip = (acceptEncoding ?? '').split(',').any(
        (t) => t.trim().toLowerCase() == 'gzip' || t.trim().startsWith('gzip;'));
    if (!wantGzip || !_gzippableExts.contains(ext) || bytes.length <= 1024) {
      return Response.ok(bytes, headers: headers);
    }

    final key = f.path;
    final mtime = await f.lastModified();
    final mtimeMs = mtime.millisecondsSinceEpoch;
    var entry = _gzCache[key];
    if (entry == null || entry.mtimeMs != mtimeMs) {
      final gz = gzip.encode(bytes);
      entry = _GzEntry(mtimeMs, gz);
      // 家用场景文件就几十个，简单粗暴的整体清空比 LRU 更不容易出怪事
      if (_gzCacheBytes + gz.length > _gzCacheMaxBytes) {
        _gzCache.clear();
        _gzCacheBytes = 0;
      }
      _gzCache[key] = entry;
      _gzCacheBytes += gz.length;
    }
    return Response.ok(entry.bytes, headers: {
      ...headers,
      'content-encoding': 'gzip',
      'vary': 'Accept-Encoding',
    });
  }

  static String mimeOf(String fileName) {
    final i = fileName.lastIndexOf('.');
    final ext = i < 0 ? '' : fileName.substring(i + 1).toLowerCase();
    switch (ext) {
      case 'html':
        return 'text/html; charset=utf-8';
      case 'js':
      case 'mjs':
        return 'text/javascript; charset=utf-8';
      case 'css':
        return 'text/css; charset=utf-8';
      case 'json':
      case 'map':
        return 'application/json; charset=utf-8';
      case 'wasm':
        return 'application/wasm';
      case 'svg':
        return 'image/svg+xml';
      case 'png':
        return 'image/png';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'webp':
        return 'image/webp';
      case 'ico':
        return 'image/x-icon';
      case 'woff2':
        return 'font/woff2';
      case 'woff':
        return 'font/woff';
      case 'ttf':
        return 'font/ttf';
      case 'txt':
        return 'text/plain; charset=utf-8';
      default:
        return 'application/octet-stream';
    }
  }

  // ── 响应构造 ──

  /// JSON 刻意带缩进：调试时人会在浏览器里直接打开 `/api/ping` 看，
  /// 一行挤在一起的 JSON 是没法看的。
  static Response _json(Map<String, Object?> body,
          {int status = 200, Map<String, String> headers = const {}}) =>
      Response(
        status,
        body: const JsonEncoder.withIndent('  ').convert(body),
        headers: {
          'content-type': 'application/json; charset=utf-8',
          'cache-control': 'no-store',
          ...headers,
        },
      );

  static Response _html(String body, {int status = 200}) => Response(
        status,
        body: body,
        headers: {'content-type': 'text/html; charset=utf-8'},
      );

  /// 请求日志。开发期必备——否则"手机连不上"时完全没有线索。
  ///
  /// ★ 这条中间件**必须包在整个管线的最外层**（R9 教训）：静态资源与 SPA 回退
  /// 发生在 router 之外，包住 router 会记成「router 说了什么」而不是「客户端拿到了什么」——
  /// 当时静态资源全被记成 404 而实际返回 200。`file_log_test` 里有断言钉住这件事。
  static Middleware _logRequests(ServerState state) =>
      (Handler inner) => (Request req) async {
            final sw = Stopwatch()..start();
            final res = await inner(req);
            await state.log.write(
              '${req.method.padRight(4)} /${req.url.path} '
              '→ ${res.statusCode}  ${sw.elapsedMilliseconds}ms',
            );
            return res;
          };
}

/// 请求体超过上限。只在 [_readJson] 与它的调用方之间传递。
class _BodyTooLarge {
  const _BodyTooLarge();
}

/// 静态文件 gzip 缓存条目：压缩结果 + 压缩时文件的 mtime（R25）。
class _GzEntry {
  const _GzEntry(this.mtimeMs, this.bytes);
  final int mtimeMs;
  final List<int> bytes;
}
