import 'package:drift/drift.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import '../zaoji_db.dart';
import 'token_vault.dart';

/// 同步引擎的本机状态，全部落在 `local_pref`（本机偏好键值表，永不外发）。
///
/// ## 这里存什么、为什么
///
/// | 键 | 内容 | 铁律出处 |
/// |---|---|---|
/// | `sync_node_id` | 本设备的 ULID。HLC 的 nodeId，也是配对时的 deviceId | 首次生成后**永不更改**——改了等于换了台设备 |
/// | `sync_server_url` | 服务端地址（http://IP:端口） | 计划书 §5.6：用户手填 |
/// | `sync_device_token` | 配对换来的 Bearer token | **只存本机**。R13 存 local_pref；**R19④ 起 Android 走 [TokenVault]（Keystore）并一次性迁移掉老明文**；Web 维持 local_pref（浏览器沙箱没有更强落点，见 token_vault.dart 注释） |
/// | `sync_server_id` | 配对时服务端的 serverId | 同步前 ping 比对——不一致 = 连到了别的服务器，**拒绝同步并要求重新配对**，而不是把数据推给陌生人 |
/// | `sync_pull_cursor` | 拉取游标（change_log 的 seq） | ★ **拉取游标在客户端**（交接文档 §8.2）：服务端那台 device 表只是对账显示。客户端清库重配对时这里会一并清零 |
/// | `sync_push_watermark` | 已推送水位线（本机行的最大 HLC） | HLC 定长编码**字典序 == 时间序**，`WHERE updated_at > ?` 直接就是"找出没推过的行"。它就是推送队列——不需要单独的队列表 |
/// | `sync_pending_mutation` | 推送中还没收到确认的 mutationId | 重试必须带**同一个** mutationId（服务端幂等靠它）；确认后清掉 |
///
/// ## 为什么推送队列是「水位线」而不是一张队列表
///
/// 每次本地写入都会走五列规范、盖一个新的 HLC（`Hlc.tick`），所以
/// 「`updated_at` 大于水位线的行」**恰好就是**「还没推上去的行」——
/// 包括后来又被改过第二遍的行（它们只需推最新版）、以及墓碑行（op=delete）。
/// 一条 kv 记录替代一张队列表，且崩溃/重启天然安全：
/// 水位线只在服务端确认后前进，没确认的行下次自动重推。
class SyncPrefs {
  SyncPrefs(this._db, {TokenVault? vault}) : _vault = vault;

  final ZaojiDb _db;

  /// token 的可替换落点（R19④）。null = 沿用 local_pref（Web / 测试路径）。
  final TokenVault? _vault;

  static const _kNodeId = 'sync_node_id';
  static const _kServerUrl = 'sync_server_url';
  static const _kToken = 'sync_device_token';
  static const _kServerId = 'sync_server_id';
  static const _kPullCursor = 'sync_pull_cursor';
  static const _kPushWatermark = 'sync_push_watermark';
  static const _kPendingMutation = 'sync_pending_mutation';
  static const _kDeviceName = 'sync_device_name';

  static const _tbl = 'local_pref';
  static const _colKey = 'pref_key';
  static const _colVal = 'pref_value';

  Future<String?> _read(String key) async {
    final rows = await _db
        .customSelect(
          'SELECT $_colVal FROM $_tbl WHERE $_colKey = ?',
          variables: [Variable(key)],
        )
        .get();
    if (rows.isEmpty) return null;
    final v = rows.first.data[_colVal];
    return v == null ? null : '$v';
  }

  Future<void> _write(String key, String value) {
    return _db.customInsert(
      'INSERT INTO $_tbl ($_colKey, $_colVal) VALUES (?, ?) '
      'ON CONFLICT($_colKey) DO UPDATE SET $_colVal = excluded.$_colVal',
      variables: [Variable(key), Variable(value)],
    );
  }

  Future<void> _remove(String key) {
    return _db.customInsert(
      'DELETE FROM $_tbl WHERE $_colKey = ?',
      variables: [Variable(key)],
    );
  }

  /// 本设备 nodeId。首次调用生成 ULID 并落盘，之后永远返回同一个。
  Future<String> nodeId() async {
    final existing = await _read(_kNodeId);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = Ulid.generate();
    await _write(_kNodeId, id);
    return id;
  }

  Future<String?> serverUrl() => _read(_kServerUrl);
  Future<void> setServerUrl(String v) => _write(_kServerUrl, v);

  /// 读 token。有 vault 时顺带完成**一次性迁移**：
  /// R13~R18 时代 token 躺在 local_pref 明文里，升级后第一次读到就搬进 vault
  /// 并立即删除明文——搬完不拆旧房子等于没加固。迁移失败（vault 写不进去）
  /// 时保持原样，下次再试，**绝不先把明文删了**。
  Future<String?> token() async {
    final vault = _vault;
    if (vault == null) return _read(_kToken);
    final v = await vault.read();
    if (v != null && v.isNotEmpty) {
      // vault 已有值：若还残留老明文（比如崩溃在 setToken 两步之间），顺手清掉。
      if (await _read(_kToken) != null) await _remove(_kToken);
      return v;
    }
    final legacy = await _read(_kToken);
    if (legacy == null || legacy.isEmpty) return null;
    await vault.write(legacy);
    await _remove(_kToken);
    return legacy;
  }

  Future<void> setToken(String v) async {
    final vault = _vault;
    if (vault == null) return _write(_kToken, v);
    await vault.write(v);
    // 覆盖写入时连同老明文一并清掉——local_pref 从此不留 token 键。
    await _remove(_kToken);
  }

  Future<String?> serverId() => _read(_kServerId);
  Future<void> setServerId(String v) => _write(_kServerId, v);

  Future<String?> deviceName() => _read(_kDeviceName);
  Future<void> setDeviceName(String v) => _write(_kDeviceName, v);

  Future<int> pullCursor() async =>
      int.tryParse(await _read(_kPullCursor) ?? '') ?? 0;

  /// ★ 游标更新必须与行应用**在同一个事务里调用**（由 SyncEngine 保证）——
  /// 否则「行应用了、游标没走」会造成重复拉取（无害但浪费），
  /// 「游标走了、行没应用」会**永久漏掉变更**（致命）。
  Future<void> setPullCursor(int v) => _write(_kPullCursor, '$v');

  Future<String> pushWatermark() async => await _read(_kPushWatermark) ?? '';

  /// 只在推送批次被服务端确认后前进（由 SyncEngine 保证）。
  Future<void> setPushWatermark(String v) => _write(_kPushWatermark, v);

  Future<String?> pendingMutationId() => _read(_kPendingMutation);
  Future<void> setPendingMutationId(String? v) =>
      v == null ? _remove(_kPendingMutation) : _write(_kPendingMutation, v);

  /// 解除配对：清掉凭证与同步进度，**保留 nodeId**（设备身份不变）。
  ///
  /// 游标必须清零：铁律「拉取游标在客户端」——重新配对（哪怕还是同一台服务器）
  /// 都要从 0 重新拉全量，否则本地新库永远缺旧数据且无人报错。
  Future<void> unpair() async {
    await _vault?.delete();
    await _remove(_kToken); // 有 vault 时也清：可能留着迁移没跑完的老明文
    await _remove(_kServerId);
    await _remove(_kPullCursor);
    await _remove(_kPushWatermark);
    await _remove(_kPendingMutation);
  }

  /// 是否已配对（有 token 即视为已配对）。走 [token]——有 vault 时以 vault 为准。
  Future<bool> isPaired() async => (await token())?.isNotEmpty ?? false;
}
