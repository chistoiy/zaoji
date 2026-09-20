import 'dart:io';

import 'package:zaoji_server/zaoji_server.dart';

/// 灶记服务端入口。
///
/// 开发期：`dart run bin/zaoji_server.dart`
/// 部署期：`dart compile exe bin/zaoji_server.dart -o zaoji_server.exe`
Future<void> main(List<String> args) async {
  final config = ServerConfig.parse(args);

  final ZaojiServer server;
  try {
    server = await ZaojiServer.start(config);
  } on DatabaseException catch (e) {
    // 数据库打不开是「开机就该失败」的事，绝不该拖到用户第一次保存菜谱。
    await _emergencyLog(config, '数据库打不开：${e.message} 数据目录：${config.dataDir.path}');
    stderr.writeln('数据库打不开：');
    stderr.writeln('  ${e.message}');
    stderr.writeln('');
    stderr.writeln('数据目录：${config.dataDir.path}');
    exit(74); // EX_IOERR
  } on SqliteLoadException catch (e) {
    await _emergencyLog(config, 'SQLite 动态库不可用：${e.message}');
    stderr.writeln('SQLite 动态库不可用：');
    stderr.writeln('  ${e.message}');
    exit(74);
  } on SocketException catch (e) {
    // 端口被占用是最常见的启动失败。直接把原因和怎么办说清楚，
    // 而不是抛一串栈让人猜。
    await _emergencyLog(config, '启动失败：${e.message}'
        '${e.osError?.errorCode == 10048 || e.osError?.errorCode == 98 ? '（端口 ${config.port} 被占用——服务已在跑？还是被别的程序占着）' : ''}');
    stderr.writeln('启动失败：${e.message}');
    if (e.osError?.errorCode == 10048 || e.osError?.errorCode == 98) {
      stderr.writeln('');
      stderr.writeln('端口 ${config.port} 已被占用。可能是：');
      stderr.writeln('  · 灶记服务已经在跑了（先看看任务栏/浏览器里那个地址还通不通）');
      stderr.writeln('  · 被别的程序占着（换个端口试试：-p 8667）');
    }
    exit(69); // EX_UNAVAILABLE
  }

  await _logBanner(server);

  _installShutdownHandlers(server);
}

/// 启动失败时的最后手段留痕（R19③）。
///
/// 这类失败发生在 ServerState.boot 前后——那时**没有可用的 state.log**。
/// 而注册成服务后没有控制台，stderr 落进虚空；不留痕就等于「它半夜没起来，
/// 没人知道为什么」。写不进也无所谓——那正是「目录都不可写」的自证。
Future<void> _emergencyLog(ServerConfig config, String message) async {
  try {
    await FileLog(config.logsDir).write(message);
  } catch (_) {}
}

/// 启动横幅：构造为文本，经 `state.log` **控制台与文件双写同一份**。
/// 以前只往 stdout 打——注册成服务后那份最重要的诊断信息落进了虚空。
Future<void> _logBanner(ZaojiServer server) async {
  final w = StringBuffer();
  final st = server.state;

  w.writeln('');
  w.writeln('  灶记 ZAOJI · 服务已启动');
  w.writeln('  ──────────────────────────────────────────────');
  w.writeln('  版本        v${ServerConfig.version}');
  w.writeln('  Server ID   ${st.serverId}');
  w.writeln('  数据目录    ${st.config.dataDir.path}');
  w.writeln('  证书目录    ${st.config.certDirPath}');
  w.writeln('  日志        ${st.log.path ?? '（未配置文件日志，仅控制台）'}');

  final dbInfo = st.db.healthPayload();
  final sizeKb = dbInfo['sizeBytes'] as int?;
  w.writeln('  数据库      zaoji.db · SQLite ${dbInfo['sqliteVersion']} · '
      'schema v${dbInfo['schemaVersion']}'
      '${sizeKb == null ? '' : '　${(sizeKb / 1024).toStringAsFixed(0)} KB'}');
  // 已有数据一眼可见：免得对着一个空库怀疑「我的菜谱去哪儿了」
  final counts = (dbInfo['rowCounts'] as Map).cast<String, int>();
  final filled = counts.entries.where((e) => e.value > 0).toList();
  w.writeln('  已有数据    ${filled.isEmpty ? '空库（还没有任何菜谱）' : filled.map((e) => '${e.key} ${e.value}').join(' · ')}');
  w.writeln('  监听        ${st.config.host}:${server.port} (http)'
      '${server.tlsReady ? '  ${st.config.host}:${server.tlsPort} (https)' : ''}');

  final web = st.config.webRoot;
  w.writeln('  Web 产物    ${web == null ? "未提供（-w 参数可指定）" : web.path}');

  if (server.tlsReady) {
    w.writeln('');
    w.writeln('  【局域网 · HTTPS — iPhone / iPad 请用这些】');
    for (final u in server.tlsLanUris) {
      w.writeln('    ${u.toString()}');
    }
    w.writeln('    ↑ iPhone 首次访问前要先装并信任 certs\\ca.crt（只做一次）');
    w.writeln('');
    w.writeln('  【局域网 · HTTP — Android App 同步用这个】');
  } else {
    w.writeln('');
    w.writeln('  【局域网地址 — 手机 / 平板 / 其他电脑用这些】');
  }

  final lan = server.lanUris;
  if (lan.isEmpty) {
    w.writeln('    （没探测到局域网地址，可能网卡没连上）');
  } else {
    for (final u in lan) {
      w.writeln('    ${u.toString()}');
    }
  }

  if (!server.tlsReady) {
    w.writeln('');
    w.writeln('  ⚠️  未启用 HTTPS（没找到 ${st.config.certPath}）');
    w.writeln('     后果：iPhone / iPad 上会失去屏幕常亮、计时通知、PWA 离线、调相机。');
    w.writeln('     生成证书：powershell -ExecutionPolicy Bypass -File tool\\make-cert.ps1');
  }

  w.writeln('');
  w.writeln('  【本机地址】');
  w.writeln('    ${server.localUri.toString()}');
  final localTls = server.localTlsUri;
  if (localTls != null) {
    w.writeln('    ${localTls.toString()}');
  }

  w.writeln('');
  w.writeln('  【接口】');
  w.writeln('    GET  /api/ping      连通性 + 服务端时间（App 里"测试连接"就打它）');
  w.writeln('    GET  /api/health    健康检查（磁盘可写、运行时长）');
  w.writeln('    GET  /status        服务状态页');
  w.writeln('');
  w.writeln('  连不上的话，九成是 Windows 防火墙：');
  w.writeln('  首次运行弹出的「允许访问」要勾上「专用网络」，否则手机过不来。');
  w.writeln('');
  w.writeln('  按 Ctrl+C 停止服务');

  // FileLog 逐行 echo 到 stdout 并 flush（每行即写即 flush），
  // 所以旧代码里那句手动的 stdout.flush() 不再需要。
  await st.log.write(w.toString());
}

void _installShutdownHandlers(ZaojiServer server) {
  Future<void> shutdown() async {
    await server.state.log.write('正在关闭灶记服务…');
    await server.stop();
    stdout.writeln('  已停止。');
    await stdout.flush();
    exit(0);
  }

  ProcessSignal.sigint.watch().listen((_) => shutdown());

  // Windows 上不支持 SIGTERM（注册会抛异常），只在类 Unix 上挂
  if (!Platform.isWindows) {
    ProcessSignal.sigterm.watch().listen((_) => shutdown());
  }
}
