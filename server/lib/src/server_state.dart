import 'dart:io';

import 'package:zaoji_shared/zaoji_shared.dart';

import 'config.dart';
import 'db.dart';
import 'file_log.dart';
import 'media.dart';
import 'sync.dart';

/// 服务端已实现与规划中的端点。
///
/// 提前把"规划中"的也列出来，是为了让打开首页的人一眼知道
/// 这个服务**现在能干什么、将来会有什么**——
/// 而不是面对一个只有 `{"ok":true}` 的地址发愣。
const List<Map<String, Object?>> kEndpoints = [
  {'path': '/', 'method': 'GET', 'title': '服务状态页', 'status': 'ready'},
  {
    'path': '/api/ping',
    'method': 'GET',
    'title': '连通性 + 服务端时间',
    'status': 'ready'
  },
  {
    'path': '/api/health',
    'method': 'GET',
    'title': '健康检查（磁盘、数据库、运行时长）',
    'status': 'ready'
  },
  {
    'path': '/api/pair/code',
    'method': 'GET',
    'title': '取配对码（只能从服务端本机取）',
    'status': 'ready'
  },
  {
    'path': '/api/pair',
    'method': 'POST',
    'title': '配对码换 token',
    'status': 'ready'
  },
  {
    'path': '/api/changes',
    'method': 'GET',
    'title': '增量拉取变更（带行载荷）',
    'status': 'ready'
  },
  {
    'path': '/api/changes',
    'method': 'POST',
    'title': '增量推送变更（幂等）',
    'status': 'ready'
  },
  {
    'path': '/api/media/{sha256}',
    'method': 'PUT',
    'title': '上传图片（内容寻址，哈希不符拒绝）',
    'status': 'ready'
  },
  {
    'path': '/api/media/{sha256}?w=640|1280',
    'method': 'GET',
    'title': '图片按需拉取（带 w 取缩略图，服务端派生）',
    'status': 'ready'
  },
  {
    'path': '/api/admin/media-gc',
    'method': 'POST',
    'title': '孤儿媒体回收（默认 dry-run，只能从本机触发）',
    'status': 'ready'
  },
  {
    'path': '/api/ai/{feature}',
    'method': 'POST',
    'title': '大模型代理（Web 端专用通道）',
    'status': 'planned'
  },
];

/// 服务端的运行时状态。
class ServerState {
  final ServerConfig config;

  /// 服务端唯一标识。首次启动时生成并落盘，之后一直复用。
  /// 客户端用它判断"我连的是不是同一台服务器"——
  /// 换了机器（或数据目录被清）就该提示重新配对。
  final String serverId;

  final DateTime startedAt;

  /// 数据库。启动时就打开并把 schema 落到最新版本——
  /// 宁可**开机即失败**，也不要等到用户第一次保存菜谱才发现库建不出来。
  final ZaojiDb db;

  /// HTTPS 是否已启用。由 [ZaojiServer] 在启动后回填——
  /// 证书检测是异步的（要读文件系统），而 health 是同步组装的。
  bool tlsReady = false;

  /// 同步服务（配对 / 拉取 / 推送）。延迟创建：它依赖 [db] 与 [serverId]，
  /// 而这两个在构造时已经就位。
  late final SyncService sync = SyncService(db, serverId);

  /// 内容寻址的图片存储（R16）：`data/media/<sha256>`。
  /// 图片不走 change_log，字节本体由显示端按 sha256 按需拉取。
  /// 缩略图（R17）派生到 `data/media/thumb/`，同样是内容寻址的纯派生数据。
  late final MediaStore media = MediaStore(
      Directory('${config.dataDir.path}${Platform.pathSeparator}media'));

  /// 文件日志（R19③）。控制台与文件双写同一份内容。
  /// `config.logsDir == null`（测试/未配置）时自动退化为纯控制台。
  late final FileLog log = FileLog(config.logsDir, echo: stdout.writeln);

  ServerState._(this.config, this.serverId, this.startedAt, this.db);

  Duration get uptime => DateTime.now().difference(startedAt);

  static Future<ServerState> boot(ServerConfig config) async {
    await _ensureDir(config.dataDir);
    final id = await _loadOrCreateServerId(config.dataDir);
    final db = ZaojiDb.open(
      '${config.dataDir.path}${Platform.pathSeparator}zaoji.db',
    );
    final state = ServerState._(config, id, DateTime.now(), db);
    // 启动时顺手清一次过期数据（过期的配对码、超过保留期的幂等记录）。
    // 只在启动时做，不做后台定时器——重启频率高于过期频率的场景不存在，
    // 而少一个常驻定时器就少一类「服务关不掉」的问题。
    final cleaned = state.sync.cleanup();
    if (cleaned > 0) {
      await state.log.write('  已清理过期数据 $cleaned 行（配对码 / 幂等记录）');
    }
    return state;
  }

  /// 关库。服务端停止时调用；测试也要调，否则 Windows 上临时目录删不掉。
  Future<void> close() async {
    db.close();
  }

  /// `/api/ping` —— 客户端拿它做三件事：
  /// ① 判断用户填的地址对不对；② 取服务端时间做时钟校正；③ 识别是不是同一台服务器。
  Map<String, Object?> pingPayload() {
    final now = DateTime.now();
    return {
      'ok': true,
      'service': 'zaoji',
      'version': ServerConfig.version,
      'serverId': serverId,
      'serverTime': now.toIso8601String(),
      'epochMs': now.millisecondsSinceEpoch,
    };
  }

  /// `/api/health` —— 打开就能知道这台机器"还活着吗、磁盘能写吗"。
  Future<Map<String, Object?>> healthPayload() async {
    final writable = await _probeWritable(config.dataDir);
    final web = config.webRoot;
    final webReady = web != null && await web.exists();

    return {
      'ok': writable,
      'service': 'zaoji',
      'version': ServerConfig.version,
      'serverId': serverId,
      'startedAt': startedAt.toIso8601String(),
      'uptimeMs': uptime.inMilliseconds,
      'host': config.host,
      'port': config.port,
      'tlsReady': tlsReady,
      'tlsPort': config.tlsPort,
      'dataDir': config.dataDir.path,
      'dataDirWritable': writable,
      'webRoot': web?.path,
      'webReady': webReady,
      'db': db.healthPayload(),
      // 盘上的真实占用（遍历文件算的，不是库里的引用）。数据库行数看不出
      // 「照片占了多少」，而不看这个就没法发现磁盘在只涨不跌。
      'media': media.stats().toJson(),
      // 日志只报路径与大小，**不报内容**：状态页在局域网里谁都能打开，
      // 日志里有绝对路径等环境信息。
      'logPath': log.path,
      'logBytes': log.bytes,
      'endpoints': kEndpoints,
      'checkedAt': DateTime.now().toIso8601String(),
    };
  }

  /// 列出本机所有非回环 IPv4 地址。
  ///
  /// 启动时打印出来 —— 免得用户还要自己去 `ipconfig` 里翻
  /// （而且翻出来一堆虚拟网卡、WSL、Docker 的地址，他也不知道该用哪个）。
  static Future<List<String>> localIPv4() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      final out = <String>[];
      for (final i in ifaces) {
        for (final a in i.addresses) {
          // 优先展示典型的家庭局域网网段，虚拟网卡排后面
          out.add(a.address);
        }
      }
      out.sort((a, b) => _rank(a).compareTo(_rank(b)));
      return out;
    } catch (_) {
      return const <String>[];
    }
  }

  /// 192.168 / 10. / 172.16-31 这些才是家里路由器的网段，
  /// Docker、WSL、Hyper-V 那些 172.17/172.2x 会混进来，排到后面去。
  static int _rank(String ip) {
    if (ip.startsWith('192.168.')) return 0;
    if (ip.startsWith('10.')) return 1;
    if (ip.startsWith('172.1') ||
        ip.startsWith('172.2') ||
        ip.startsWith('172.3')) return 2;
    return 3;
  }

  // ── 内部 ──

  static Future<void> _ensureDir(Directory d) async {
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
  }

  static Future<String> _loadOrCreateServerId(Directory dataDir) async {
    final f = File('${dataDir.path}${Platform.pathSeparator}server_id');
    if (await f.exists()) {
      final s = (await f.readAsString()).trim();
      // 文件被手改坏时不要崩，直接重新生成一个
      if (Ulid.isValid(s)) return s;
    }
    final id = Ulid.generate();
    await f.writeAsString(id, flush: true);
    return id;
  }

  /// 真的写一个文件、删掉它。比 `exists()` 靠谱得多 ——
  /// 目录存在但只读（UAC 保护、网络盘掉线）是最常见的坑。
  static Future<bool> _probeWritable(Directory d) async {
    try {
      if (!await d.exists()) await d.create(recursive: true);
      final probe = File('${d.path}${Platform.pathSeparator}.write-probe');
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }
}
