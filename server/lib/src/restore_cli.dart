import 'dart:convert';
import 'dart:io';

import 'backup.dart';

/// `zaoji_server restore <zip> <目标 data 目录> [--force]` 的实现。
///
/// 独立成 lib 文件是为了两个入口共用同一份码：开发期
/// `dart run bin/restore_backup.dart`，部署期 `zaoji_server.exe restore`。
/// 复制两遍的 CLI 一定会漂移——漂移的第一次现场就是「恢复时才发现两个说法不一样」。
Future<int> restoreCliMain(List<String> args) async {
  final rest =
      (args.isNotEmpty && args.first == 'restore') ? args.sublist(1) : args;
  final force = rest.contains('--force');
  final positional = rest.where((a) => !a.startsWith('--')).toList();

  if (positional.length != 2) {
    stderr.writeln('用法：zaoji_server restore <备份包.zip> <目标 data 目录> [--force]');
    stderr.writeln('例：  zaoji_server restore zaoji-backup-20260928-031500-a1b2.zip D:\\zaoji\\data');
    return 64;
  }

  final zipPath = positional[0];
  final target = Directory(positional[1]);
  stdout.writeln('正在校验并恢复 $zipPath → ${target.path}');
  try {
    final report = await BackupService.restore(zipPath, target, force: force);
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
    stdout.writeln('完成。用这份数据启动服务端：zaoji_server -d "${target.path}"');
    stdout.writeln('注意：serverId 在库里，随包一起回来——设备不用重新配对；');
    stdout.writeln('      但打包之后发生的改动不在这份数据里——恢复即回滚到打包时刻。');
    return 0;
  } on BackupIntegrityException catch (e) {
    stderr.writeln('恢复失败：${e.message}');
    return 65;
  } catch (e) {
    stderr.writeln('恢复失败：$e');
    return 70;
  }
}
