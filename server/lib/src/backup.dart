import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import 'config.dart';
import 'file_log.dart';
import 'media.dart';

/// 备份能力（R26）。
///
/// **为什么需要一个专门的备份**：这台服务端是家里常年开机的笔记本，
/// 全家的菜谱、照片、菜单、做菜记录只有这一份。磁盘坏了 = 全部消失。
/// 此前的轮次都在管「运行期」（日志、孤儿回收），没有人管「整包带走」。
///
/// 三条设计立在这里，先说清楚：
///
/// 1. **包是自描述的**：`manifest.json` 记录 serverId、schema 版本、
///    每个文件的 sha256 与大小。解包时逐文件校验，**哈希不符就拒绝恢复**——
///    半坏的备份比没有备份更糟（用户以为保险在，其实内容是坏的）。
/// 2. **缩略图不进包**：它是 `(sha, width)` 的纯派生函数（R17 的立论），
///    恢复后第一次访问就重新派生。进包只是让包变大、校验面变大。
/// 3. **凭据绝不进包**：备份配置存在 `data/backup_config.json`——
///    **故意不放进数据库**。数据库会被打进包里、包会传到云端；
///    WebDAV 密码若跟着库走，等于把钥匙和保险箱寄到同一个地方。
///
/// 命名 `zaoji-backup-<UTC时间>-<4位随机>.zip` 是刻意让**字典序 = 时间序**：
/// 保留策略靠排序裁剪，不需要任何额外的元数据查询。
const String kBackupFilePrefix = 'zaoji-backup-';
final RegExp _backupNamePattern =
    RegExp(r'^zaoji-backup-\d{8}-\d{6}-[0-9a-f]{4}\.zip$');

String _sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// 校验失败（哈希不符 / 清单缺失 / 混入未登记文件）抛这个。
/// 恢复路径上**宁可失败也不要静默凑合**。
class BackupIntegrityException implements Exception {
  final String message;
  const BackupIntegrityException(this.message);
  @override
  String toString() => 'BackupIntegrityException: $message';
}

// ───────────────────────────── 配置 ─────────────────────────────

/// 备份配置。持久化在 `data/backup_config.json`（不进库、不进包、不进 git）。
class BackupConfig {
  /// 总开关。关掉后定时器与开机补跑都不做，手动触发仍可用。
  bool enabled;

  /// 两次备份之间的最小间隔（小时）。
  int intervalHours;

  /// 是否把照片原图打进包。关掉就是只备数据。
  bool includeMedia;

  /// 远端保留份数（超出按时间序删最老）。
  int remoteKeep;

  /// 本地（data/backups/）保留份数。
  int localKeep;

  String? webdavUrl;
  String? webdavUser;
  String? webdavPass;

  BackupConfig({
    this.enabled = true,
    this.intervalHours = 24,
    this.includeMedia = true,
    this.remoteKeep = 7,
    this.localKeep = 5,
    this.webdavUrl,
    this.webdavUser,
    this.webdavPass,
  });

  /// 远端三件套齐了才算「配好了上传目标」。
  bool get hasRemote =>
      (webdavUrl ?? '').trim().isNotEmpty &&
      (webdavUser ?? '').trim().isNotEmpty &&
      (webdavPass ?? '').trim().isNotEmpty;

  /// 展示用的占位符：口令**只进不出**（与 R21 准入口令同一条纪律）。
  static const String redacted = '••••••';

  Map<String, Object?> toJson({bool withSecrets = false}) => {
        'enabled': enabled,
        'intervalHours': intervalHours,
        'includeMedia': includeMedia,
        'remoteKeep': remoteKeep,
        'localKeep': localKeep,
        'webdavUrl': webdavUrl,
        'webdavUser': webdavUser,
        if (withSecrets) 'webdavPass': webdavPass,
      };

  /// 校验。返回 null = 通过；否则是人话说明。
  /// 宁可在保存配置时就拒绝，也不要等半夜备份失败才发现——那时没人看。
  String? validate() {
    if (intervalHours < 1 || intervalHours > 720) {
      return '间隔小时数应在 1–720 之间，收到 $intervalHours';
    }
    if (remoteKeep < 1 || remoteKeep > 60) return '远端保留份数应在 1–60 之间';
    if (localKeep < 1 || localKeep > 60) return '本地保留份数应在 1–60 之间';
    final u = (webdavUrl ?? '').trim();
    if (u.isNotEmpty) {
      final uri = Uri.tryParse(u);
      if (uri == null ||
          (uri.scheme != 'https' && uri.scheme != 'http') ||
          uri.host.isEmpty) {
        return 'WebDAV 地址应形如 https://dav.example.com/dav/备份目录/，收到 "$u"';
      }
      if (!u.endsWith('/')) return 'WebDAV 地址请以 / 结尾（指到目录，不是文件）';
      if ((webdavUser ?? '').trim().isEmpty ||
          (webdavPass ?? '').trim().isEmpty) {
        return '配了地址就必须同时配用户名和应用密码';
      }
    }
    return null;
  }

  static File fileFor(Directory dataDir) => File(
      '${dataDir.path}${Platform.pathSeparator}backup_config.json');

  /// 读配置。文件不存在 / 读不懂 / 字段坏了全部回默认值——
  /// 「配置被手改坏」不该让服务端起不来，状态页会显示默认值让人重存。
  static BackupConfig load(Directory dataDir) {
    final f = fileFor(dataDir);
    try {
      if (f.existsSync()) {
        final j = jsonDecode(f.readAsStringSync());
        if (j is Map<String, Object?>) return BackupConfig.fromJson(j);
      }
    } catch (_) {}
    return BackupConfig();
  }

  factory BackupConfig.fromJson(Map<String, Object?> j) => BackupConfig(
        enabled: j['enabled'] is bool ? j['enabled'] as bool : true,
        intervalHours:
            j['intervalHours'] is int ? j['intervalHours'] as int : 24,
        includeMedia:
            j['includeMedia'] is bool ? j['includeMedia'] as bool : true,
        remoteKeep: j['remoteKeep'] is int ? j['remoteKeep'] as int : 7,
        localKeep: j['localKeep'] is int ? j['localKeep'] as int : 5,
        webdavUrl: j['webdavUrl'] as String?,
        webdavUser: j['webdavUser'] as String?,
        webdavPass: j['webdavPass'] as String?,
      );

  Future<void> save(Directory dataDir) async {
    final f = fileFor(dataDir);
    await f.parent.create(recursive: true);
    // 与 server_id / media 同一条纪律：临时文件 + rename，写一半被杀不留坏文件
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(toJson(withSecrets: true)),
        flush: true);
    await tmp.rename(f.path);
  }

  /// 用请求体里的字段覆盖已有配置（**没出现的键保持原值**）。
  /// webdavPass 等于掩码 [redacted] 或空串 = 不改——状态页回显的就是掩码，
  /// 整份表单提交回来时不能把掩码当新密码存进去
  /// （R21「配置打错字绝不能把门打开」的同族教训）。
  static BackupConfig merge(BackupConfig old, Map<String, Object?> body) =>
      BackupConfig(
        enabled:
            body['enabled'] is bool ? body['enabled'] as bool : old.enabled,
        intervalHours: body['intervalHours'] is int
            ? body['intervalHours'] as int
            : old.intervalHours,
        includeMedia: body['includeMedia'] is bool
            ? body['includeMedia'] as bool
            : old.includeMedia,
        remoteKeep: body['remoteKeep'] is int
            ? body['remoteKeep'] as int
            : old.remoteKeep,
        localKeep:
            body['localKeep'] is int ? body['localKeep'] as int : old.localKeep,
        webdavUrl: body.containsKey('webdavUrl')
            ? '${body['webdavUrl'] ?? ''}'.trim()
            : old.webdavUrl,
        webdavUser: body.containsKey('webdavUser')
            ? '${body['webdavUser'] ?? ''}'.trim()
            : old.webdavUser,
        webdavPass: body.containsKey('webdavPass') &&
                body['webdavPass'] != redacted &&
                '${body['webdavPass'] ?? ''}'.isNotEmpty
            ? '${body['webdavPass']}'.trim()
            : old.webdavPass,
      );
}

// ───────────────────────────── 结果 ─────────────────────────────

class BackupRunResult {
  final DateTime at;

  /// 本地快照是否成功（本地成功是底线：远端挂了，家里也留了一份新的）。
  final bool ok;
  final String? fileName;
  final int? bytes;
  final bool uploaded;

  /// 失败原因 / 上传失败原因（ok=true 但 uploaded=false 时放后者）。
  final String? error;
  final int mediaCount;

  BackupRunResult({
    required this.at,
    required this.ok,
    this.fileName,
    this.bytes,
    this.uploaded = false,
    this.error,
    this.mediaCount = 0,
  });

  Map<String, Object?> toJson() => {
        'at': at.toIso8601String(),
        'ok': ok,
        'fileName': fileName,
        'bytes': bytes,
        'uploaded': uploaded,
        'error': error,
        'mediaCount': mediaCount,
      };

  static BackupRunResult? fromJson(Object? j) {
    if (j is! Map) return null;
    final m = j.cast<String, Object?>();
    return BackupRunResult(
      at: DateTime.tryParse('${m['at']}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      ok: m['ok'] == true,
      fileName: m['fileName'] as String?,
      bytes: m['bytes'] as int?,
      uploaded: m['uploaded'] == true,
      error: m['error'] as String?,
      mediaCount: m['mediaCount'] as int? ?? 0,
    );
  }
}

// ──────────────────────────── 远端目标 ────────────────────────────

/// 上传目标抽象。缤纷云 S3 的密钥核对通过后，加一个 S3Target 实现即可——
/// ensure/list/upload/delete 四件事就是备份对存储后端的全部需求。
abstract class BackupTarget {
  /// 确保目标目录存在（幂等；已存在的报错吞掉——有的服务 PUT 会自动建父目录）。
  Future<void> ensure();

  /// 列出现有备份文件名（升序 = 时间序）。
  Future<List<String>> list();

  /// 上传一个文件。content 用流，不把整包读进内存。
  Future<void> upload(String name, Stream<List<int>> content, int length);

  Future<void> delete(String name);
}

/// WebDAV（坚果云实测可用，见《外部服务验证记录》）。
///
/// 只用四个方法：MKCOL（建目录，容忍已存在）、PUT、PROPFIND Depth:1（列表）、
/// DELETE。坚果云对**空目录删除**返回 403——所以保留策略只删文件，绝不删目录。
class WebDavTarget implements BackupTarget {
  /// 目录地址，必须以 / 结尾。
  final Uri base;
  final String user;
  final String pass;
  final HttpClient _client;
  final bool _ownClient;

  WebDavTarget(this.base, this.user, this.pass, {HttpClient? client})
      : assert(base.path.endsWith('/'), 'WebDAV 地址必须指到目录（以 / 结尾）'),
        _client = client ?? HttpClient(),
        _ownClient = client == null;

  String get _authHeader =>
      'Basic ${base64Encode(utf8.encode('$user:$pass'))}';

  Uri _resolve(String name) => Uri.parse('$base$name');

  Future<int> _send(HttpClientRequest req, {Stream<List<int>>? body}) async {
    req.headers.set(HttpHeaders.authorizationHeader, _authHeader);
    final res = body == null
        ? await req.close()
        : await req.addStream(body).then((_) => req.close());
    await res.drain<void>();
    return res.statusCode;
  }

  @override
  Future<void> ensure() async {
    // 逐级 MKCOL。已存在返回 405/403，全当没事——没有更可靠的探测写法，
    // 而且失败会在随后的 PUT 上以真实错误冒出来，不会静默。
    final segments =
        base.pathSegments.where((s) => s.isNotEmpty).toList(growable: false);
    for (var i = 1; i <= segments.length; i++) {
      final url = Uri(
        scheme: base.scheme,
        host: base.host,
        port: base.hasPort ? base.port : null,
        path: '/${segments.take(i).join('/')}/',
      );
      try {
        final req = await _client.openUrl('MKCOL', url);
        await _send(req);
      } catch (_) {}
    }
  }

  @override
  Future<List<String>> list() async {
    final req = await _client.openUrl('PROPFIND', base);
    req.headers.set('Depth', '1');
    req.headers.set(HttpHeaders.authorizationHeader, _authHeader);
    final res = await req.close();
    final xml = await res.transform(utf8.decoder).join();
    if (res.statusCode != 207) {
      throw StateError('PROPFIND 返回 HTTP ${res.statusCode}，拿不到目录清单');
    }
    // 不引 XML 库：只取 <href> 的最后一节，且只要符合备份命名的。
    // href 可能被 URL 编码（坚果云就是），解回来才能和本地文件名对上。
    final out = <String>[];
    for (final m
        in RegExp(r'<(?:[A-Za-z0-9]+:)?href>([^<]+)</').allMatches(xml)) {
      try {
        final href = Uri.decodeComponent(m.group(1)!);
        if (href.endsWith('/')) continue; // 目录自身
        final name = href.split('/').last;
        if (_backupNamePattern.hasMatch(name)) out.add(name);
      } catch (_) {}
    }
    out.sort();
    return out;
  }

  @override
  Future<void> upload(String name, Stream<List<int>> content, int length) async {
    final req = await _client.openUrl('PUT', _resolve(name));
    req.contentLength = length;
    final code = await _send(req, body: content);
    if (code != 200 && code != 201 && code != 204) {
      throw StateError('WebDAV 上传失败：HTTP $code（$name）');
    }
  }

  @override
  Future<void> delete(String name) async {
    final req = await _client.openUrl('DELETE', _resolve(name));
    final code = await _send(req);
    if (code != 200 && code != 204 && code != 404) {
      throw StateError('WebDAV 删除失败：HTTP $code（$name）');
    }
  }

  void close() {
    if (_ownClient) _client.close(force: true);
  }
}

// ───────────────────────────── 服务本体 ─────────────────────────────

/// 备份服务：打包（在线快照 + 清单 + 校验和）、上传、保留裁剪、恢复。
class BackupService {
  final Directory dataDir;

  /// 正在运行的库。在线备份 API 从它读页面，WAL 下也能拿到一致视图。
  final Database source;
  final MediaStore media;
  final FileLog log;
  final String serverId;
  final Random _rng = Random();

  BackupService({
    required this.dataDir,
    required this.source,
    required this.media,
    required this.log,
    required this.serverId,
  });

  bool _running = false;
  bool get running => _running;

  /// 上传目标工厂（配置换了，下一次 runOnce 自动用新目标）。
  BackupTarget? targetOf(BackupConfig cfg) => cfg.hasRemote
      ? WebDavTarget(Uri.parse(cfg.webdavUrl!.trim()), cfg.webdavUser!.trim(),
          cfg.webdavPass!.trim())
      : null;

  File get _lastFile =>
      File('${dataDir.path}${Platform.pathSeparator}backup_last.json');

  /// 上次备份结果（读不出来 = null，不抛：状态页要能在任何配置状态下渲染）。
  BackupRunResult? get last {
    try {
      if (!_lastFile.existsSync()) return null;
      return BackupRunResult.fromJson(jsonDecode(_lastFile.readAsStringSync()));
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeLast(BackupRunResult r) async {
    try {
      await _lastFile.writeAsString(jsonEncode(r.toJson()), flush: true);
    } catch (_) {}
  }

  Directory get backupsDir =>
      Directory('${dataDir.path}${Platform.pathSeparator}backups');

  String _newName() {
    final t = DateTime.now().toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
    final rnd = _rng.nextInt(0x10000).toRadixString(16).padLeft(4, '0');
    return '$kBackupFilePrefix$stamp-$rnd.zip';
  }

  /// 跑一次备份。**不抛异常**（失败也进 last 记录——
  /// 「半夜备份挂了没人知道」正是要消灭的事），返回结果对象。
  Future<BackupRunResult> runOnce({BackupConfig? config}) async {
    if (_running) throw StateError('已经有一次备份在跑');
    _running = true;
    final at = DateTime.now().toUtc();
    final name = _newName();
    Directory? tmpDir;
    try {
      final cfg = config ?? BackupConfig.load(dataDir);
      final integrityErr = cfg.validate();
      if (integrityErr != null) {
        final r = BackupRunResult(
            at: at, ok: false, error: '配置无效：$integrityErr');
        await _writeLast(r);
        await log.write('[backup] 配置无效，未执行：$integrityErr');
        return r;
      }

      tmpDir = await Directory.systemTemp.createTemp('zaoji_backup_');
      final snapFile =
          File('${tmpDir.path}${Platform.pathSeparator}db.sqlite3');

      // ① 在线快照。WAL 下直接 copy 主文件会缺 -wal 里的内容，
      //    sqlite3 的在线备份 API 按页复制，正在被写的库也能拿到一致视图。
      final dst = sqlite3.open(snapFile.path);
      try {
        await source.backup(dst).drain<void>();
      } finally {
        dst.dispose();
      }

      // ② 清单：先算齐所有进包文件的哈希，再一次性编码。
      //    （分两步写会出「manifest 描述了没算完的集合」这种洞。）
      final files = <String, Map<String, Object?>>{};
      final dbBytes = snapFile.readAsBytesSync();
      files['db.sqlite3'] = {
        'size': dbBytes.length,
        'sha256': _sha256Hex(dbBytes),
      };
      final mediaFiles = <(String, File)>[];
      if (cfg.includeMedia) {
        for (final sha in media.listOriginals()) {
          final f = media.fileFor(sha);
          if (!f.existsSync()) continue;
          final bytes = f.readAsBytesSync();
          files['media/$sha'] = {
            'size': bytes.length,
            'sha256': _sha256Hex(bytes),
          };
          mediaFiles.add((sha, f));
        }
      }
      final manifestJson = jsonEncode({
        'format': 'zaoji-backup',
        'formatVersion': 1,
        'createdAt': at.toIso8601String(),
        'serverId': serverId,
        'schemaVersion': kSchemaVersion,
        'serverVersion': ServerConfig.version,
        'includeMedia': cfg.includeMedia,
        'files': files,
        'counts': {'media': mediaFiles.length},
      });

      // ③ 打包。db 用 deflate；照片已经是压缩格式，store 裸存省 CPU。
      final zipFile = File('${tmpDir.path}${Platform.pathSeparator}$name');
      final enc = ZipFileEncoder();
      enc.create(zipFile.path);
      final mBytes = Uint8List.fromList(utf8.encode(manifestJson));
      enc.addArchiveFile(ArchiveFile('manifest.json', mBytes.length, mBytes)
        ..compress = false);
      await enc.addFile(snapFile, 'db.sqlite3', ZipFileEncoder.GZIP);
      for (final e in mediaFiles) {
        await enc.addFile(e.$2, 'media/${e.$1}', ZipFileEncoder.STORE);
      }
      await enc.close();
      final zipBytes = zipFile.lengthSync();

      // ④ 本地永远先落一份（data/backups/），远端只是副本。
      await backupsDir.create(recursive: true);
      await zipFile
          .copy('${backupsDir.path}${Platform.pathSeparator}$name');
      final localPruned = _pruneLocal(cfg.localKeep);

      // ⑤ 远端上传 + 保留裁剪
      String? error;
      var uploaded = false;
      var remotePruned = 0;
      final target = targetOf(cfg);
      if (target != null) {
        try {
          await target.ensure();
          await target.upload(name, zipFile.openRead(), zipBytes);
          uploaded = true;
          remotePruned = await _pruneRemote(target, cfg.remoteKeep);
        } catch (e) {
          error = '上传失败：$e';
        } finally {
          if (target is WebDavTarget) target.close();
        }
      }

      final r = BackupRunResult(
        at: at,
        ok: true,
        fileName: name,
        bytes: zipBytes,
        uploaded: uploaded,
        error: error,
        mediaCount: mediaFiles.length,
      );
      await _writeLast(r);
      await log.write('[backup] ${uploaded ? '已上传' : '本地快照'} $name '
          '${(zipBytes / 1024 / 1024).toStringAsFixed(1)} MB，'
          '照片 ${mediaFiles.length} 张'
          '${error != null ? '（$error）' : ''}'
          '${localPruned + remotePruned > 0 ? '，裁剪旧备份 ${localPruned + remotePruned} 份' : ''}');
      return r;
    } catch (e, st) {
      final r = BackupRunResult(at: at, ok: false, error: '$e');
      await _writeLast(r);
      await log.write('[backup] 失败：$e\n$st');
      return r;
    } finally {
      _running = false;
      try {
        if (tmpDir != null) await tmpDir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 本地裁剪。返回删掉几份。同步实现（都是本盘小文件操作），
  /// 调用点不在请求路径的热区。
  int _pruneLocal(int keep) {
    if (!backupsDir.existsSync()) return 0;
    final names = backupsDir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => _backupNamePattern.hasMatch(n))
        .toList()
      ..sort();
    var deleted = 0;
    while (names.length - deleted > keep) {
      try {
        File('${backupsDir.path}${Platform.pathSeparator}${names[deleted]}')
            .deleteSync();
        deleted++;
      } catch (_) {
        break; // 文件被占用？本轮就此打住，不做危险重试
      }
    }
    return deleted;
  }

  Future<int> _pruneRemote(BackupTarget target, int keep) async {
    try {
      final names = await target.list();
      var deleted = 0;
      while (names.length - deleted > keep) {
        await target.delete(names[deleted]);
        deleted++;
      }
      return deleted;
    } catch (e) {
      // 裁剪失败不影响本次备份结果——多留一份旧备份的成本是空间，
      // 而误删的成本是用户数据；这两件事严重不对等。
      await log.write('[backup] 远端保留裁剪失败（不影响本次备份）：$e');
      return 0;
    }
  }

  /// 远端连通性测试：建目录 → PUT 小文件 → 删掉。
  /// 返回 null = 通；否则是人话错误。**探测留下的东西必须自己清干净。**
  Future<String?> testRemote(BackupConfig cfg) async {
    final t = targetOf(cfg);
    if (t == null) return '还没有配置 WebDAV 目标（地址/用户名/密码三件套）';
    try {
      final bytes =
          Uint8List.fromList(utf8.encode('zaoji backup connectivity probe'));
      await t.ensure();
      await t.upload('_probe.txt', Stream.value(bytes), bytes.length);
      await t.delete('_probe.txt');
      return null;
    } catch (e) {
      return '$e';
    } finally {
      if (t is WebDavTarget) t.close();
    }
  }

  // ───────────────────────────── 恢复 ─────────────────────────────

  /// 把一个备份包恢复到 [targetDataDir]（新目录）。
  ///
  /// 逐文件校验 manifest 哈希后才写盘；**任何一个文件哈希不符就整个中止**，
  /// 绝不允许「恢复了 99%」。目标目录里已有 zaoji.db 时需要 force=true，
  /// 防止手滑覆盖还活着的库。
  ///
  /// 实现上整包读进内存（家庭规模几十 MB 到几百 MB，一次性操作可接受；
  /// 将来照片攒到 GB 级再换流式解包）。
  static Future<Map<String, Object?>> restore(
    String zipPath,
    Directory targetDataDir, {
    bool force = false,
  }) async {
    final zip = File(zipPath);
    if (!zip.existsSync()) {
      throw BackupIntegrityException('找不到备份包：$zipPath');
    }
    final archive = ZipDecoder().decodeBytes(zip.readAsBytesSync());
    final entryOf = <String, ArchiveFile>{
      for (final e in archive.files) e.name: e,
    };
    final manifestEntry = entryOf['manifest.json'];
    if (manifestEntry == null) {
      throw const BackupIntegrityException(
          '包里就没有 manifest.json，这不是灶记的备份包');
    }
    final manifest =
        jsonDecode(utf8.decode(manifestEntry.content as List<int>))
            as Map<String, Object?>;
    if (manifest['format'] != 'zaoji-backup' ||
        manifest['formatVersion'] != 1) {
      throw const BackupIntegrityException(
          '格式或版本不认识（要的是 zaoji-backup v1）');
    }
    final files = (manifest['files'] as Map)
        .cast<String, Object?>()
        .map((k, v) => MapEntry(k, (v as Map).cast<String, Object?>()));

    // 包里的东西必须**恰好**是清单登记的（manifest.json 除外）。
    // 混入未登记文件说明包被动过——宁可停下让人看。
    for (final name in entryOf.keys) {
      if (name == 'manifest.json') continue;
      if (!files.containsKey(name)) {
        throw BackupIntegrityException('包里混入了清单之外的文件：$name');
      }
    }

    final dbTarget =
        File('${targetDataDir.path}${Platform.pathSeparator}zaoji.db');
    if (await dbTarget.exists() && !force) {
      throw BackupIntegrityException('目标目录里已经有一个 zaoji.db（${dbTarget.path}）。\n'
          '确认要覆盖它再加 --force。');
    }

    await targetDataDir.create(recursive: true);
    final mediaDir =
        Directory('${targetDataDir.path}${Platform.pathSeparator}media');
    await mediaDir.create(recursive: true);

    var restoredFiles = 0;
    var restoredBytes = 0;
    for (final e in files.entries) {
      final name = e.key;
      final want = e.value;
      final entry = entryOf[name];
      if (entry == null) {
        throw BackupIntegrityException('清单里登记了 $name，包里却没有');
      }
      final bytes = Uint8List.fromList(entry.content as List<int>);
      final got = _sha256Hex(bytes);
      if (got != want['sha256']) {
        throw BackupIntegrityException(
            '$name 哈希不符（清单 ${want['sha256']}，实际 $got）——包是坏的，中止恢复');
      }
      final File out;
      if (name == 'db.sqlite3') {
        out = dbTarget;
      } else if (name.startsWith('media/')) {
        out = File('${mediaDir.path}${Platform.pathSeparator}'
            '${name.substring('media/'.length)}');
      } else {
        throw BackupIntegrityException('清单里出现了不知道放哪的文件：$name');
      }
      final tmp = File('${out.path}.restoring');
      await tmp.writeAsBytes(bytes, flush: true);
      if (await out.exists()) await out.delete();
      await tmp.rename(out.path);
      restoredFiles++;
      restoredBytes += bytes.length;
    }

    return {
      'ok': true,
      'from': zip.path,
      'into': targetDataDir.path,
      'sourceServerId': manifest['serverId'],
      'sourceSchemaVersion': manifest['schemaVersion'],
      'createdAt': manifest['createdAt'],
      'restoredFiles': restoredFiles,
      'restoredBytes': restoredBytes,
    };
  }
}

// ───────────────────────────── 定时调度 ─────────────────────────────

/// 备份定时器。
///
/// R5 的旧决策是「不做后台定时器」（少一个关不掉的定时器就少一类问题），
/// 但备份和配对码过期不是一回事：服务端可能几周不重启，
/// 「只在启动时补跑」等于没有定期备份。所以这里做**一个**定时器，
/// 并且刻意做成「每 30 分钟看一眼是否到期」而不是「按 intervalHours 精确排班」——
/// 配置改了立刻生效，不需要重建定时器，也不会在睡眠唤醒后堆积补跑。
class BackupScheduler {
  final Directory dataDir;
  final BackupService service;

  /// 到检查点了。生产是 30 分钟；测试注入秒级以覆盖「到期→执行」的路径。
  final Duration checkEvery;

  Timer? _timer;
  BackupScheduler({
    required this.dataDir,
    required this.service,
    this.checkEvery = const Duration(minutes: 30),
  });

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(checkEvery, (_) => tick());
    // 开机补跑：服务刚起来 20 秒后就检查一次（远端不通也不拖慢启动——不等它）。
    Timer(const Duration(seconds: 20), tick);
  }

  void stop() => _timer?.cancel();

  /// 一次检查。所有异常在 runOnce 内部已被吸收成结果，这里只判断「该不该跑」。
  Future<void> tick() async {
    final cfg = BackupConfig.load(dataDir);
    if (!cfg.enabled || !cfg.hasRemote || service.running) return;
    final last = service.last;
    final due = last == null ||
        last.at
            .isBefore(DateTime.now().toUtc().subtract(
                Duration(hours: cfg.intervalHours)));
    if (!due) return;
    await service.runOnce(config: cfg);
  }
}
