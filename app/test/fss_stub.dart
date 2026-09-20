import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// flutter_secure_storage 的 MethodChannel 名（9.x 单一通道）。
const _fssChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// 给 widget 测试里的 Keystore 通道挂一个「永远没有值」的 mock。
///
/// **为什么必须**：`flutter test` 的 `defaultTargetPlatform` 默认是 android，
/// 于是 `vaultForCurrentPlatform()` 在生产路径上给测试发起了真插件通道——
/// 测试环境没有 handler，`MethodChannel.invokeMethod` 的 future **永不完成**。
/// 这不是测试技巧而是纠偏：返回 null 恰好等价于「vault 里没有 token」，
/// 引擎会顺legacy路径回落 local_pref，与首次启动的真实行为一致。
///
/// 不修的话谁踩：任何 `await engine.isPaired()` / `token()` 的调用方
/// （R21 的 MePage 就是这么挂住的）——以前 syncIfPaired 是 fire-and-forget，
/// 挂起从未暴露，测试一直"绿"得很虚假。
void stubSecureStorageForTest() {
  WidgetsBinding widgetsBinding = TestWidgetsFlutterBinding.ensureInitialized();
  final binding = widgetsBinding as TestDefaultBinaryMessengerBinding;
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    _fssChannel,
    (call) async => null,
  );
}
