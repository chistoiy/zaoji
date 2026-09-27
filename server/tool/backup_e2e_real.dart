// R26 备份真链路 E2E（坚果云 WebDAV 真云往返）。
//
// backup_test 的假 WebDAV 验证了协议形状；这个脚本验证**真云的脾气**：
// 真实 TLS、真实 PROPFIND 返回、真实覆盖策略、真实删除。
// 凭据从环境读取（先 source .secrets/externals.local.env），不落盘、不进仓库。
//
// 跑法（在 server/ 目录）：
//   source ../.secrets/externals.local.env
//   dart run tool/backup_e2e_real.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:sqlite3/sqlite3.dart';
import 'package:zaoji_server/zaoji_server.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

Future<void> main() async {
  final root = Platform.environment['JIANGUO_DAV'] ?? '';
  final user = Platform.environment['JIANGUO_USER'];
  final pass = Platform.environment['JIANGUO_PASS'];
  if (root.isEmpty || user == null || pass == null) {
    stderr.writeln('缺少 JIANGUO_DAV/JIANGUO_USER/JIANGUO_PASS 环境');
    exit(64);
  }
  // 独立目录，验证完清文件留目录（坚果云删空目录 403，见验证记录）
  final url = '${root}zaoji-backup-e2e/';
  stdout.writeln('目标目录：$url');

  final tmp = await Directory.systemTemp.createTemp('zaoji_bk_e2e_');
  final state = await ServerState.boot(ServerConfig(
    host: '127.0.0.1',
    port: 1,
    tlsPort: 2,
    dataDir: Directory('${tmp.path}/data'),
    certDir: Directory('${tmp.path}/certs'),
  ));
  var failed = 0;
  void check(bool ok, String what) {
    stdout.writeln('${ok ? '✓' : '✗'} $what');
    if (!ok) failed++;
  }

  try {
    // 种真数据：一行菜谱 + 一张真 JPEG 进媒体库（备份要连照片一起走得动）
    final hlc = Hlc.now('e2e').toString();
    final id = Ulid.generate();
    state.db.db.execute(
      'INSERT INTO recipe (id, updated_at, updated_by, rev, deleted_at, name) '
      "VALUES (?, ?, 'e2e', 1, NULL, '备份E2E菜')",
      [id, hlc],
    );
    final jpg = Uint8List.fromList(
        img.encodeJpg(img.Image(width: 64, height: 48), quality: 80));
    await state.media.put(MediaStore.sha256Hex(jpg), jpg);

    final cfg = BackupConfig(
        enabled: true,
        intervalHours: 24,
        includeMedia: true,
        remoteKeep: 3,
        localKeep: 3,
        webdavUrl: url,
        webdavUser: user,
        webdavPass: pass);
    check(cfg.validate() == null, '配置校验：${cfg.validate() ?? 'ok'}');

    final probe = await state.backup.testRemote(cfg);
    check(probe == null, '远端连通探测：${probe ?? 'ok'}');

    final r1 = await state.backup.runOnce(config: cfg);
    check(r1.ok && r1.uploaded,
        '备份上传 ${r1.fileName} ${(r1.bytes ?? 0) ~/ 1024} KB（${r1.error ?? '无错误'}）');

    final target = state.backup.targetOf(cfg)!;
    final names = await target.list();
    check(names.contains(r1.fileName), '远端 PROPFIND 清单能列出本次备份（${names.length} 份）');

    // 下载回来 → restore（逐文件校验）→ 打开恢复库确认数据在
    final auth = 'Basic ${base64Encode(utf8.encode('$user:$pass'))}';
    final req = await HttpClient().openUrl('GET', Uri.parse('$url${r1.fileName}'));
    req.headers.set(HttpHeaders.authorizationHeader, auth);
    final res = await req.close();
    final dlFile = File('${tmp.path}/down.zip');
    final sink = dlFile.openWrite();
    await sink.addStream(res);
    await sink.close();
    check(res.statusCode == 200, '远端下载 HTTP ${res.statusCode}，'
        '${await dlFile.length()} 字节');
    final report =
        await BackupService.restore(dlFile.path, Directory('${tmp.path}/restored'));
    check(report['ok'] == true && report['restoredFiles'] == 2,
        '恢复校验通过：${report['restoredFiles']} 个文件（manifest 全哈希对上）');

    final rdb = sqlite3.open('${tmp.path}/restored/zaoji.db');
    final rows = rdb.select("SELECT id FROM recipe WHERE name='备份E2E菜'");
    rdb.dispose();
    check(rows.length == 1, '恢复出的库能查到备份前写入的菜');
    check(File('${tmp.path}/restored/media/${MediaStore.sha256Hex(jpg)}')
        .existsSync(), '恢复出的媒体文件在位');

    // 清理远端（备份包 + 目录里的东西全删掉；空目录删不掉是坚果云的脾气）
    for (final n in names) {
      await target.delete(n);
    }
    final left = await target.list();
    check(left.isEmpty, '远端清理干净（剩 ${left.length} 份）');
    if (target is WebDavTarget) target.close();
  } finally {
    await state.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }

  if (failed > 0) {
    stderr.writeln('E2E 失败 $failed 项');
    exit(1);
  }
  stdout.writeln('真链路 E2E 全过');
}
