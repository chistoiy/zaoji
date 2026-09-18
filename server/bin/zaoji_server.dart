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
    stderr.writeln('数据库打不开：');
    stderr.writeln('  ${e.message}');
    stderr.writeln('');
    stderr.writeln('数据目录：${config.dataDir.path}');
    exit(74); // EX_IOERR
  } on SqliteLoadException catch (e) {
    stderr.writeln('SQLite 动态库不可用：');
    stderr.writeln('  ${e.message}');
    exit(74);
  } on SocketException catch (e) {
    // 端口被占用是最常见的启动失败。直接把原因和怎么办说清楚，
    // 而不是抛一串栈让人猜。
    stderr.writeln('启动失败：${e.message}');
    if (e.osError?.errorCode == 10048 || e.osError?.errorCode == 98) {
      stderr.writeln('');
      stderr.writeln('端口 ${config.port} 已被占用。可能是：');
      stderr.writeln('  · 灶记服务已经在跑了（先看看任务栏/浏览器里那个地址还通不通）');
      stderr.writeln('  · 被别的程序占着（换个端口试试：-p 8667）');
    }
    exit(69); // EX_UNAVAILABLE
  }

  _printBanner(server);

  // 必须显式 flush。
  // stdout 被重定向到文件（或注册成服务、根本没有控制台）时是**块缓冲**的，
  // 进程被强杀时缓冲区里的启动横幅会一起消失——排查启动问题时会以为"它什么都没输出"。
  // 踩过：用 Start-Process 重定向日志，日志文件是空的，而服务其实正常起来了。
  await stdout.flush();

  _installShutdownHandlers(server);
}

void _printBanner(ZaojiServer server) {
  final st = server.state;
  final w = stdout;

  w.writeln('');
  w.writeln('  灶记 ZAOJI · 服务已启动');
  w.writeln('  ──────────────────────────────────────────────');
  w.writeln('  版本        v${ServerConfig.version}');
  w.writeln('  Server ID   ${st.serverId}');
  w.writeln('  数据目录    ${st.config.dataDir.path}');
  w.writeln('  证书目录    ${st.config.certDirPath}');

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
  w.writeln('');
}

void _installShutdownHandlers(ZaojiServer server) {
  Future<void> shutdown() async {
    stdout.writeln('');
    stdout.writeln('  正在关闭灶记服务…');
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
