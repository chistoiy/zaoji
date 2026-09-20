import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 设备 token 的存储后端抽象（R19④）。
///
/// 为什么 token 要单独抽一层：它是**凭证**——拿到它就能以本设备身份读写全家的菜谱。
/// 其余同步状态（游标、水位线、nodeId…）丢了只是不方便，它丢了/被拿走是安全事故。
/// 所以它值得一个可替换的落点，而不是和偏好挤在同一张明文表里。
abstract class TokenVault {
  /// vault 内部的键名。与 local_pref 里的旧键**同名**是刻意的：
  /// 迁移时一眼能对上，测试里也是同一份语义。
  static const String keyToken = 'sync_device_token';

  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

/// Android Keystore 后端（flutter_secure_storage，AES 密钥托管在 Android Keystore）。
class SecureDeviceVault implements TokenVault {
  SecureDeviceVault([FlutterSecureStorage? storage])
      : _storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  final FlutterSecureStorage _storage;

  // 静态成员不随 implements 继承，必须显式走 TokenVault.keyToken。
  static const _key = TokenVault.keyToken;

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);

  @override
  Future<void> delete() => _storage.delete(key: _key);
}

/// 按当前平台决定用哪个 vault；null = 沿用 local_pref。
///
/// **Web 返回 null 是决策，不是偷懒**：浏览器沙箱里没有 Keystore 等价物
/// （WebCrypto + IndexedDB 自己加密的话，密钥还是存在同一个可读取的地方），
/// 换一种明文存放只是制造假安全感。Android App 才走这里；
/// iPhone 走的是 Web 端，加固路径不同（HTTPS + 沙箱）。
TokenVault? vaultForCurrentPlatform() {
  if (kIsWeb) return null;
  // dart:io 的 Platform 在 Web 编译期不可用，defaultTargetPlatform 两端都有值。
  if (defaultTargetPlatform == TargetPlatform.android) {
    return SecureDeviceVault();
  }
  return null;
}
