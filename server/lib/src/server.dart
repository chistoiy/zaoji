import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import 'config.dart';
import 'media.dart';
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

    final https = await _startTls(config, handler);
    state.tlsReady = https != null; // 回填给 /api/health 与状态页

    return ZaojiServer._(state, http, https, ips);
  }

  /// 证书在就开 HTTPS，不在就安静跳过。
  ///
  /// 但**不会默默降级**——启动横幅与状态页都会明确写出
  /// 「iOS 端会因此失去什么」，否则用户只会看到「Safari 说这不是安全连接」
  /// 然后一头雾水。
  static Future<HttpServer?> _startTls(
      ServerConfig config, Handler handler) async {
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
      stderr.writeln('⚠️  HTTPS 启动失败：$e');
      stderr.writeln('    http 仍可用，但 iOS 端的屏幕常亮 / 计时通知 / PWA 离线会失效。');
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
          (Request req) async => _html(await statusPageHtml(state, ips)))
      // 配对码只能从本机取——否则局域网里任何人都能自己配对
      ..get('/api/pair/code', (Request req) => _pairCode(state, req))
      ..post('/api/pair', (Request req) => _pair(state, req))
      // 数据接口一律要 token
      ..get('/api/changes', (Request req) => _pull(state, req))
      ..post('/api/changes', (Request req) => _push(state, req))
      // 媒体接口（R16）：同样要 token。GET 是显示端按需拉取，PUT 是上传。
      ..put('/api/media/<sha>',
          (Request req) => _mediaPut(state, req, req.params['sha']!))
      ..get('/api/media/<sha>',
          (Request req) => _mediaGet(state, req, req.params['sha']!));

    /// 首页：如果托管了 Flutter Web 产物，让位给它——
    /// 否则用户打开地址看到的永远是状态页，而不是他要的 App。
    router.get('/', (Request req) async {
      final web = state.config.webRoot;
      if (web != null && await web.exists()) {
        final index = await _tryStatic('index.html', web);
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
        final staticRes = await _tryStatic(rel, web);
        if (staticRes != null) return staticRes;

        // SPA 回退：Flutter Web 的路由不在文件系统里，
        // 刷新深层路径时必须回 index.html，否则一刷新就 404。
        if (req.method == 'GET' && !rel.startsWith('api/')) {
          final index = await _tryStatic('index.html', web);
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
    return const Pipeline().addMiddleware(_logRequests()).addHandler(resolve);
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
    final c = state.sync.issuePairCode();
    return _json({
      ...c.toJson(),
      'serverId': state.serverId,
      'protocolVersion': kSyncProtocolVersion,
    });
  }

  static bool _isLocalRequest(Request req) {
    final info = req.context['shelf.io.connection_info'];
    // 值是 dart:io 的 HttpConnectionInfo（由 shelf_io 放进 context）
    if (info is! HttpConnectionInfo) return true;
    final a = info.remoteAddress.address;
    return a == '127.0.0.1' || a == '::1' || a == 'localhost';
  }

  /// 用配对码换 token。
  ///
  /// **有失败限流**（R12）：配对码空间 31^6 ≈ 8.9×10⁸、TTL 5 分钟，
  /// 不限流的话局域网里的攻击者可以高速枚举。窗口内失败满
  /// [SyncService.maxPairFailsPerWindow] 次就 429；**成功配对清空记录**
  /// （不惩罚手滑）。参数残缺（400 类）不计入失败——那是客户端 bug，不是猜测。
  static Future<Response> _pair(ServerState state, Request req) async {
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

  /// 增量拉取。
  static Future<Response> _pull(ServerState state, Request req) async {
    final device = state.sync.authenticate(req.headers['authorization']);
    if (device == null) return _unauthorized();

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
    final device = state.sync.authenticate(req.headers['authorization']);
    if (device == null) return _unauthorized();

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

  static Response _unauthorized() => _json({
        'error': 'unauthorized',
        'message': '缺少或无效的设备 token。请先在 App 里完成配对。',
      }, status: 401);

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
    final device = state.sync.authenticate(req.headers['authorization']);
    if (device == null) return _unauthorized();

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
    return _json({
      'ok': true,
      'sha256': r.sha,
      'size': r.size,
      'type': r.type,
      'duplicated': r.duplicated,
    });
  }

  /// 拉取图片：GET /api/media/<sha256>。
  /// 内容寻址 = 内容永不变更，因此可以放心让客户端**长缓存**。
  static Future<Response> _mediaGet(
      ServerState state, Request req, String sha) async {
    final device = state.sync.authenticate(req.headers['authorization']);
    if (device == null) return _unauthorized();

    if (!MediaStore.isValidSha(sha)) {
      return _mediaBad('sha256 必须是 64 位小写十六进制');
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

  static Future<Response?> _tryStatic(String rel, Directory webRoot) async {
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
    return Response.ok(
      bytes,
      headers: {
        'content-type': mimeOf(fileName),
        // index.html 绝不能缓存：Flutter 发新版本后，
        // 缓存住的旧 index 会去拉已经不存在的旧 assets，页面直接白屏。
        'cache-control': fileName == 'index.html'
            ? 'no-cache, no-store, must-revalidate'
            : 'public, max-age=604800',
      },
    );
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
  static Middleware _logRequests() => (Handler inner) => (Request req) async {
        final sw = Stopwatch()..start();
        final res = await inner(req);
        stdout.writeln(
          '[${_time()}] ${req.method.padRight(4)} /${req.url.path} '
          '→ ${res.statusCode}  ${sw.elapsedMilliseconds}ms',
        );
        return res;
      };

  static String _time() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

/// 请求体超过上限。只在 [_readJson] 与它的调用方之间传递。
class _BodyTooLarge {
  const _BodyTooLarge();
}
