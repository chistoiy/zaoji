import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/sync/sync_prefs.dart';
import 'package:zaoji/data/sync/token_vault.dart';

/// token 存储加固（R19④）。
///
/// 立场：**Android 上 token 进 Keystore（flutter_secure_storage），local_pref 不留明文**。
/// Web 端维持 local_pref——浏览器沙箱里没有 Keystore 等价物，换地方存只会制造假安全感，
/// 这个判断本身也要被测试文档化（vaultForPlatform(web-ish 默认 null) 即 Web 路径）。
///
/// 真 Keystore 在宿主测试里不可用（插件通道不存在），所以这里测的是
/// SyncPrefs 与 vault 的**协作语义**（读写路由 / 迁移 / 双清），用内存 vault 实现；
/// 真机验证路径 = 编译期保证 + 交接文档 §6 真机清单（如实记录，不假绿）。
class MemoryVault implements TokenVault {
  final Map<String, String> _store = {};
  String? get token => _store[TokenVault.keyToken];

  @override
  Future<String?> read() async => _store[TokenVault.keyToken];

  @override
  Future<void> write(String value) async =>
      _store[TokenVault.keyToken] = value;

  @override
  Future<void> delete() async => _store.remove(TokenVault.keyToken);
}

void main() {
  late RecipeStore store;

  setUp(() async {
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
  });

  tearDown(() async {
    final db = store.dbOrNull;
    if (db != null) await db.close();
    store.dispose();
  });

  /// 直接读写 local_pref——模拟「老版本把 token 存在偏好表里」的现场。
  Future<void> rawPrefWrite(String key, String value) async {
    await store.dbOrNull!.customInsert(
      'INSERT INTO local_pref (pref_key, pref_value) VALUES (?, ?) '
      'ON CONFLICT(pref_key) DO UPDATE SET pref_value = excluded.pref_value',
      variables: [Variable(key), Variable(value)],
    );
  }

  Future<String?> rawPrefRead(String key) async {
    final rows = await store.dbOrNull!.customSelect(
      'SELECT pref_value FROM local_pref WHERE pref_key = ?',
      variables: [Variable(key)],
    ).get();
    if (rows.isEmpty) return null;
    final v = rows.first.data['pref_value'];
    return v == null ? null : '$v';
  }

  const kTokenKey = 'sync_device_token';

  group('vault 存在时（Android 路径）', () {
    test('★ setToken 只进 vault，local_pref 不留明文', () async {
      final vault = MemoryVault();
      final prefs = SyncPrefs(store.dbOrNull!, vault: vault);
      await prefs.setToken('tok-abc');
      expect(vault.token, 'tok-abc');
      expect(await rawPrefRead(kTokenKey), isNull,
          reason: '明文行是加固要消灭的东西——写进去哪怕一行都不行');
    });

    test('token 从 vault 读', () async {
      final vault = MemoryVault();
      final prefs = SyncPrefs(store.dbOrNull!, vault: vault);
      await prefs.setToken('tok-xyz');
      expect(await prefs.token(), 'tok-xyz');
    });

    test('★ 一次性迁移：老明文 → vault，且明文随即被删除', () async {
      // 现场：R13~R18 时代装的 App，token 还躺在 local_pref
      await rawPrefWrite(kTokenKey, 'legacy-token');
      final vault = MemoryVault();
      final prefs = SyncPrefs(store.dbOrNull!, vault: vault);

      expect(await prefs.token(), 'legacy-token', reason: '迁移不能把用户的配对弄丢');
      expect(vault.token, 'legacy-token');
      expect(await rawPrefRead(kTokenKey), isNull,
          reason: '搬完必须拆旧房子——留着明文等于没加固');
    });

    test('迁移幂等：再读一次不报错、值不变', () async {
      await rawPrefWrite(kTokenKey, 'legacy-2');
      final vault = MemoryVault();
      final prefs = SyncPrefs(store.dbOrNull!, vault: vault);
      expect(await prefs.token(), 'legacy-2');
      expect(await prefs.token(), 'legacy-2');
      expect(await rawPrefRead(kTokenKey), isNull);
    });

    test('vault 与明文并存（崩溃在两步之间）→ 以 vault 为准并清明文', () async {
      await rawPrefWrite(kTokenKey, 'stale-plain');
      final vault = MemoryVault();
      final prefs = SyncPrefs(store.dbOrNull!, vault: vault);
      await prefs.setToken('fresh-vault');
      expect(await rawPrefRead(kTokenKey), isNull); // setToken 时顺手清了遗留
      expect(await prefs.token(), 'fresh-vault');
    });

    test('unpair 双清：vault 与任何明文遗留都归零，nodeId 保留', () async {
      await rawPrefWrite(kTokenKey, 'leftover');
      final vault = MemoryVault();
      final prefs = SyncPrefs(store.dbOrNull!, vault: vault);
      final nodeId = await prefs.nodeId();
      await prefs.setToken('tok');

      await prefs.unpair();
      expect(vault.token, isNull);
      expect(await rawPrefRead(kTokenKey), isNull);
      expect(await prefs.isPaired(), isFalse);
      expect(await prefs.nodeId(), nodeId, reason: '设备身份永不因解除配对而变（R13 铁律）');
    });

    test('isPaired 以 vault 判定', () async {
      final vault = MemoryVault();
      final prefs = SyncPrefs(store.dbOrNull!, vault: vault);
      expect(await prefs.isPaired(), isFalse);
      await prefs.setToken('t');
      expect(await prefs.isPaired(), isTrue);
    });
  });

  group('无 vault（Web / 宿主测试路径，行为与 R13 以来完全一致）', () {
    test('token 存进 local_pref（现状回归防护）', () async {
      final prefs = SyncPrefs(store.dbOrNull!);
      await prefs.setToken('web-tok');
      expect(await prefs.token(), 'web-tok');
      expect(await rawPrefRead(kTokenKey), 'web-tok');
      await prefs.unpair();
      expect(await rawPrefRead(kTokenKey), isNull);
    });
  });
}
