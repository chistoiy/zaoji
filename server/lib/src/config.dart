import 'dart:io';

import 'package:args/args.dart';

/// 服务端启动配置。
///
/// **默认绑定 `0.0.0.0`，这是本项目的部署形态决定的**：
/// 服务跑在家里那台常年开机的笔记本上，Android 手机（数据同步）、
/// iPhone、平板、老婆的电脑都要通过局域网连它。
/// 只绑 `127.0.0.1` 的话除了本机谁也连不上，等于没部署。
///
/// 安全边界**不靠绑定地址**，而靠三层：
/// ① 只在家庭局域网内可达，路由器 NAT 之外无法直达；
/// ② `/api/sync` 与 `/api/media` 需要配对 token（M1 落地）；
/// ③ 静态资源只读，不提供任何文件写入接口。
class ServerConfig {
  final String host;
  final int port;

  /// HTTPS 端口。
  ///
  /// **这不是可选项，是 iOS 能用的前提**：Safari 只把 `https://`、`localhost`、
  /// `file://` 当作安全上下文，`http://192.168.x.x` 不是。
  /// 后果是 WakeLock（做菜时常亮）、Notification（计时提醒）、
  /// Service Worker（PWA 离线）、getUserMedia（调相机）全部失效——
  /// 而这四样恰好全是 iOS 端最需要的。
  final int tlsPort;

  /// 数据目录：SQLite 库、图片、备份快照都放这里。
  final Directory dataDir;

  /// Flutter Web 产物目录（可选）。存在就托管，不存在就给一个提示页。
  final Directory? webRoot;

  /// 证书目录。放 `ca.crt` / `server.crt` / `server.key`
  /// （由 `tool/make-cert.ps1` 生成）。
  /// 两个文件都在，服务端就会自动额外监听 HTTPS。
  final Directory certDir;

  /// 日志目录（R19③）。null = 不写文件日志，只往控制台打（单元测试的常态）。
  /// 由 [parse] 默认解析为 baseDir 下的 `logs/`——注册成服务后没有控制台，
  /// 这份文件日志就是唯一的痕（见 R5 坑 6：stdout 重定向是块缓冲）。
  final Directory? logsDir;

  const ServerConfig({
    required this.host,
    required this.port,
    required this.tlsPort,
    required this.dataDir,
    required this.certDir,
    this.webRoot,
    this.logsDir,
  });

  static const String defaultHost = '0.0.0.0';
  static const int defaultPort = 8666;
  static const int defaultTlsPort = 8667;

  /// 版本号。`/api/ping` 会返回它，客户端据此判断是否需要提示升级。
  ///
  /// 0.3.0：数据底座就位（SQLite + 统一五列 + change_log）。
  /// 0.4.0：同步接口就位（配对鉴权 / 增量拉取 / 幂等推送 / 冲突箱）。
  /// 0.5.0：媒体接口就位（图片内容寻址上传 / 按需拉取）。
  /// 0.6.0：派生缩略图（`GET /api/media/<sha>?w=`，白名单档位 + 落盘缓存 + 上传预热）。
  /// 0.7.0：孤儿媒体回收（`POST /api/admin/media-gc`，默认 dry-run，仅本机可触发）+ 状态页媒体占用。
  /// 0.8.0：带轮转的文件日志（logs/zaoji.log，控制台与文件双写；health 报 logPath/logBytes）。
  /// 0.9.0：来访者同步准入三态（open/passcode/pairCode，schema v4）+ `/api/sync/config`、
  ///   `/api/join`、`/api/admin/settings`（仅本机）。
  static const String version = '0.9.0';

  bool get bindAllInterfaces => host == '0.0.0.0' || host == '::';

  /// 相对路径的基准目录。
  ///
  /// **这个函数存在的唯一理由，是避免注册成 Windows 服务后静默跑偏。**
  /// 服务管理器启动进程时的工作目录是 `C:\Windows\System32`，如果还按 CWD 找
  /// `data` 与 `certs`，后果是三件事同时发生且都不报错：
  /// ① 在系统目录下新建一个空数据库；② 生成一个新的 serverId（客户端会以为换了服务器）；
  /// ③ 找不到证书 → 悄悄不监听 HTTPS → iOS 端四样能力全部失效。
  ///
  /// 所以：以 AOT exe 运行时看 exe 所在目录；`dart run` 开发期仍按当前工作目录。
  static Directory baseDir() {
    try {
      final exe = File(Platform.resolvedExecutable);
      final name = exe.uri.pathSegments.isEmpty
          ? ''
          : exe.uri.pathSegments.last.toLowerCase();
      // dart / dart.exe → 说明是开发期，按 CWD
      if (name.startsWith('dart')) return Directory.current;
      final parent = exe.parent;
      return parent.existsSync() ? parent : Directory.current;
    } catch (_) {
      return Directory.current;
    }
  }

  static bool _isAbsolute(String p) =>
      p.startsWith('/') ||
      p.startsWith('\\') ||
      RegExp(r'^[a-zA-Z]:').hasMatch(p);

  /// 选项没给就用默认值；给了相对路径就挂到 [base] 下。
  static Directory resolveDir(String? option, String fallback, Directory base) {
    final raw =
        (option == null || option.trim().isEmpty) ? fallback : option.trim();
    if (_isAbsolute(raw)) return Directory(raw);
    return Directory('${base.path}${Platform.pathSeparator}$raw');
  }

  String get certPath => '$certDirPath${Platform.pathSeparator}server.crt';
  String get keyPath => '$certDirPath${Platform.pathSeparator}server.key';
  String get caPath => '$certDirPath${Platform.pathSeparator}ca.crt';

  /// 归一化后的证书目录路径（去掉末尾分隔符，避免拼出 `certs\\server.crt` 这种双斜杠）
  String get certDirPath {
    var p = certDir.path;
    while (p.length > 1 && (p.endsWith('/') || p.endsWith('\\'))) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  static ServerConfig parse(List<String> args) {
    final parser = ArgParser()
      ..addOption('host',
          abbr: 'H',
          defaultsTo: defaultHost,
          help: '绑定地址。0.0.0.0 = 局域网内任意设备可访问（默认）')
      ..addOption('port',
          abbr: 'p', defaultsTo: '$defaultPort', help: 'HTTP 端口')
      ..addOption('tls-port',
          defaultsTo: '$defaultTlsPort', help: 'HTTPS 端口（iOS 必须走这个）')
      ..addOption('data', abbr: 'd', help: '数据目录（默认 ./data）')
      ..addOption('web', abbr: 'w', help: 'Flutter Web 产物目录（可选）')
      ..addOption('certs', abbr: 'c', help: '证书目录（默认 ./certs）')
      ..addOption('log', help: '日志目录（默认 ./logs；带轮转，见状态页）')
      ..addFlag('help', abbr: 'h', negatable: false, help: '显示帮助');

    final ArgResults r;
    try {
      r = parser.parse(args);
    } on FormatException catch (e) {
      stderr.writeln('参数错误：${e.message}');
      stderr.writeln();
      stderr.write(usage(parser));
      exit(64); // EX_USAGE
    }

    if (r.flag('help')) {
      stdout.write(usage(parser));
      exit(0);
    }

    final port = _parsePort(r.option('port'), defaultPort, 'HTTP');
    final tlsPort = _parsePort(r.option('tls-port'), defaultTlsPort, 'HTTPS');
    if (port == tlsPort) {
      stderr.writeln('HTTP 与 HTTPS 不能共用同一个端口（都是 $port）');
      exit(64);
    }

    final webPath = r.option('web');

    // 相对路径一律挂到 baseDir() 下，避免被「工作目录」牵着走（见 baseDir 注释）
    final base = baseDir();

    return ServerConfig(
      host: r.option('host') ?? defaultHost,
      port: port,
      tlsPort: tlsPort,
      dataDir: resolveDir(r.option('data'), 'data', base),
      certDir: resolveDir(r.option('certs'), 'certs', base),
      webRoot: webPath == null ? null : resolveDir(webPath, webPath, base),
      logsDir: resolveDir(r.option('log'), 'logs', base),
    );
  }

  static int _parsePort(String? text, int fallback, String label) {
    final v = int.tryParse(text ?? '$fallback');
    if (v == null || v < 1 || v > 65535) {
      stderr.writeln('$label 端口不合法：${text ?? fallback}（应为 1–65535）');
      exit(64);
    }
    return v;
  }

  static String usage(ArgParser parser) => '''
灶记 ZAOJI 服务端 v$version

用法：zaoji_server [选项]

${parser.usage}

示例：
  zaoji_server                                  # 默认 0.0.0.0:8666(http) + 8667(https)
  zaoji_server -p 8666 -d D:\\zaoji\\data        # 指定端口与数据目录
  zaoji_server -w D:\\zaoji\\web                # 额外托管 Flutter Web 产物
  zaoji_server -H 127.0.0.1                     # 只监听本机（调试用）

HTTPS 说明：
  证书放在 certs\\ 目录（server.crt + server.key）。存在就会自动开启 HTTPS。
  生成证书：powershell -ExecutionPolicy Bypass -File tool\\make-cert.ps1
  iOS 端必须走 HTTPS —— http://192.168.x.x 不是安全上下文，
  屏幕常亮、计时通知、PWA 离线、调相机四样能力都会失效。
''';
}
