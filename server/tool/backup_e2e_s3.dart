// R30：缤纷云 S3 真云备份往返 E2E。凭据从环境读取（.secrets/externals.local.env），不落仓库。
// 跑法（server/ 目录）：source ../.secrets/externals.local.env && dart run tool/backup_e2e_s3.dart
import 'dart:io';

import 'package:zaoji_server/zaoji_server.dart';

Future<void> main() async {
  final ep = Platform.environment['BITIFUL_S3_ENDPOINT'];
  final bucket = Platform.environment['BITIFUL_S3_BUCKET'];
  final ak = Platform.environment['BITIFUL_S3_AK'];
  final sk = Platform.environment['BITIFUL_S3_SK'];
  if (ep == null || bucket == null || ak == null || sk == null) {
    stderr.writeln('缺 BITIFUL_S3_* 环境');
    exit(64);
  }
  final tmp = await Directory.systemTemp.createTemp('zaoji_bk_s3_');
  final state = await ServerState.boot(ServerConfig(
    host: '127.0.0.1',
    port: 1,
    tlsPort: 2,
    dataDir: Directory('${tmp.path}/data'),
    certDir: Directory('${tmp.path}/certs'),
  ));
  var bad = 0;
  void check(bool ok, String what) {
    stdout.writeln('${ok ? '✓' : '✗'} $what');
    if (!ok) bad++;
  }
  final target = S3Target(
    endpoint: Uri.parse(ep),
    bucket: bucket,
    region: 'auto',
    ak: ak,
    sk: sk,
    prefix: 'zaoji-backups/',
  );
  try {
    // 只开 S3、不开 WebDAV：证明第二通道能独立工作
    final cfg = BackupConfig(
        s3Endpoint: ep,
        s3Bucket: bucket,
        s3Region: 'auto',
        s3Ak: ak,
        s3Sk: sk,
        remoteKeep: 3);
    final r = await state.backup.runOnce(config: cfg);
    check(r.ok && r.uploadedS3 && !r.uploaded,
        'runOnce 只经 S3 上传：${r.fileName} ${(r.bytes ?? 0) ~/ 1024} KB（${r.error ?? '无错误'}）');
    final names = await target.list();
    check(names.contains(r.fileName), '真云 list 能列出本次备份（共 ${names.length} 份）');
    await target.delete(r.fileName!);
    final left = await target.list();
    check(!left.contains(r.fileName), '删除后清单里不再有它');
  } finally {
    target.close();
    await state.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }
  if (bad > 0) {
    stderr.writeln('S3 E2E 失败 $bad 项');
    exit(1);
  }
  stdout.writeln('缤纷云 S3 备份通道真云往返全过');
}
