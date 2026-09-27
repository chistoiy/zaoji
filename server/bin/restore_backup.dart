import 'dart:io';

import 'package:zaoji_server/zaoji_server.dart';

/// 备份恢复工具（R26）的开发期入口。
///
/// 部署期用同一个 exe：`zaoji_server.exe restore <zip> <目录> [--force]`
/// （逻辑在 `lib/src/restore_cli.dart`，两个入口共用）。
///
/// **为什么是独立命令而不是接口**：恢复的前提就是「原来的服务已经不行了」，
/// 那时候没有接口可调——能用的只剩这个 exe 和一份下载回来的 zip。
/// 它也是唯一能验证「备份真的能救回来」的东西：没有恢复路径的备份是自嗨。
Future<void> main(List<String> args) async {
  exitCode = await restoreCliMain(args);
}
