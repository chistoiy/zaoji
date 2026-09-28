import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 发布产物的两条静态守护（都是真踩过坑之后钉死的）。
///
/// ① **INTERNET 必须在 main 清单里**：Flutter 模板只把它写进 debug/profile 清单，
///    于是桌面 `flutter run` 一切正常、**release 包装上真机后所有网络调用 DNS 全挂**
///    （`Failed host lookup ... errno = 7`，看着像地址写错）。本 App 同步/媒体/AI 全走网络。
/// ② **local.properties 不许钉着旧版本**：`flutter.versionName/versionCode` 一旦出现在
///    那台机器的 local.properties 里，就会**盖过 pubspec**——版本号改了、发出去的 APK 还是旧的。
///    这条对 CI 无感（那文件本就不进仓库），专门挡「本机重编」。
void main() {
  final mainManifest = File('android/app/src/main/AndroidManifest.xml');
  final pubspec = File('pubspec.yaml');

  test('★ main 清单含 INTERNET 权限（release APK 的网络硬门槛）', () {
    expect(mainManifest.existsSync(), isTrue,
        reason: 'flutter test 的工作目录应是 app/');
    final text = mainManifest.readAsStringSync();
    expect(text, contains('android.permission.INTERNET'));
  });

  test('★ local.properties 若钉版本，必须与 pubspec 完全一致', () {
    final local = File('android/local.properties');
    if (!local.existsSync()) return; // 别的机器上没这文件，正常
    final pins = <String, String>{};
    for (final line in local.readAsLinesSync()) {
      final m = RegExp(r'^flutter\.(versionName|versionCode)=(.+)$').firstMatch(line.trim());
      if (m != null) pins[m.group(1)!] = m.group(2)!.trim();
    }
    if (pins.isEmpty) return;

    // 不引 yaml 依赖（它只是 flutter_test 的传递依赖）：版本号是固定一行，正则够用。
    final version = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
        .firstMatch(pubspec.readAsStringSync())!
        .group(1)!; // 形如 0.14.0+7
    final parts = version.split('+');
    expect(pins['versionName'], parts.first,
        reason: 'local.properties 的 flutter.versionName 与 pubspec 不一致 = 发旧版本号包');
    if (pins.containsKey('versionCode') && parts.length > 1) {
      expect(pins['versionCode'], parts[1],
          reason: 'local.properties 的 flutter.versionCode 与 pubspec 的 +N 不一致');
    }
  });
}
