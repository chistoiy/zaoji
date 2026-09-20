/// 同步准入三态（R21）。
///
/// 放在 `shared` 的理由只有一条：这个值**由服务端设定、由客户端解读**，
/// 两端对同一个字符串的理解必须逐字节一致——写在两边就是两份真相。
///
/// | 模式 | 来访者怎么接入 | 匿名请求（无 token）|
/// |---|---|---|
/// | [SyncAccessMode.open] | 不用接入，打开就同步 | 放行（按 X-Node-Id 记伪设备）|
/// | [SyncAccessMode.passcode] | 在「我的」页输一次服务端设定的固定口令 | 拒绝，提示输口令 |
/// | [SyncAccessMode.pairCode] | 现有流程：本机取 6 位一次性码配对 | 拒绝，提示配对 |
///
/// 三种**互斥单选**；已持有合法 token 的设备在任何模式下都不受影响。
enum SyncAccessMode {
  open('open', '免配对开放'),
  passcode('passcode', '固定口令'),
  pairCode('pairCode', '配对码');

  const SyncAccessMode(this.wire, this.label);

  /// 接口与 server_setting 里流转的稳定字符串。**只增不改。**
  final String wire;

  /// 给人看的名字（状态页与 App 共用一份措辞）。
  final String label;

  /// 解析不了的字符串返回 null——调用方必须给 400，**绝不能悄悄回落到某个默认模式**：
  /// 把「开放」错当成默认，等于配置写错时把自己家的门打开。
  static SyncAccessMode? parse(String? s) {
    for (final m in values) {
      if (m.wire == s) return m;
    }
    return null;
  }
}

/// 来访者设备自报身份用的请求头。
/// 值是客户端自己的 nodeId（ULID）——开放模式下服务端按它维护各自的同步游标。
const String kNodeIdHeader = 'x-node-id';

/// nodeId 合法性：8~64 位的字母/数字/下划线/连字符。
/// 太短的不可能是 ULID，太长的是拿这个字段灌库。
final RegExp kNodeIdPattern = RegExp(r'^[0-9A-Za-z_-]{8,64}$');
