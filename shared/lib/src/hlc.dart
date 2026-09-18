/// 混合逻辑时钟（Hybrid Logical Clock）。
///
/// **为什么不用墙钟**：手机时间可能不准、用户可能手动回拨、可能跨时区。
/// 纯墙钟排序会把「后发生的变更」排到前面，同步结果就会回退——
/// 用户会说「我明明改了，怎么又变回去了」，而且无法复现。
///
/// HLC 同时保证三件事：
/// ① 与物理时间足够接近（不会像 Lamport 时钟那样飘走）；
/// ② 严格单调递增（同一节点上绝不回退）；
/// ③ 全局全序可比（不同节点之间也有确定的先后）。
///
/// **序列化格式刻意设计成「字典序 == 时间序」**：
/// ```
/// [13 位十六进制物理毫秒]-[4 位十六进制计数]-[节点 ID]
/// ```
/// 这样服务端 `ORDER BY updated_at` 得到的就是正确时间序，
/// 不需要在 SQL 里解析字符串，也能直接用 B-Tree 索引。
library;

class Hlc implements Comparable<Hlc> {
  /// 计数上限。同一毫秒内变更超过 65536 次才可能触顶，
  /// 现实中不会发生，但必须显式处理——静默回绕会破坏单调性。
  static const int counterMax = 0xFFFF;

  /// 物理毫秒位宽（13 位十六进制 = 52 bit ≈ 公元 14 万年），
  /// 定长是「字典序 == 时间序」的前提。
  static const int _hexWidth = 13;

  final int physicalMs;
  final int counter;
  final String nodeId;

  const Hlc(this.physicalMs, this.counter, this.nodeId);

  /// 设备初始化时的首个时间戳。
  factory Hlc.now(String nodeId, {int? wallMs}) {
    final ms = wallMs ?? DateTime.now().millisecondsSinceEpoch;
    return Hlc(ms, 0, nodeId);
  }

  /// 本地事件 / 发送前推进。
  ///
  /// **时钟回拨时不回退**：保留较大的 physicalMs，只递增 counter。
  /// 这正是 HLC 相对墙钟的核心价值——用户怎么调系统时间，排序都不乱。
  Hlc tick(String nodeId, {int? wallMs}) {
    final ms = wallMs ?? DateTime.now().millisecondsSinceEpoch;
    if (ms > physicalMs) return Hlc(ms, 0, nodeId);
    return _bump(physicalMs, counter + 1, nodeId);
  }

  /// 收到远端时间戳后推进本地时钟。
  Hlc merge(Hlc remote, String nodeId, {int? wallMs}) {
    final ms = wallMs ?? DateTime.now().millisecondsSinceEpoch;
    final maxMs = [physicalMs, remote.physicalMs, ms].reduce((a, b) => a > b ? a : b);

    final int next;
    if (maxMs == physicalMs && maxMs == remote.physicalMs) {
      next = (counter > remote.counter ? counter : remote.counter) + 1;
    } else if (maxMs == physicalMs) {
      next = counter + 1;
    } else if (maxMs == remote.physicalMs) {
      next = remote.counter + 1;
    } else {
      next = 0;
    }
    return _bump(maxMs, next, nodeId);
  }

  /// 计数溢出时进位到下一毫秒，宁可让物理时间多 1ms，也不破坏单调性。
  static Hlc _bump(int ms, int c, String nodeId) =>
      c > counterMax ? Hlc(ms + 1, 0, nodeId) : Hlc(ms, c, nodeId);

  /// 本地时钟是否被回拨过。用于「数据体检」里提示用户，
  /// 而不是悄悄修正——用户有权知道自己调过时间。
  static bool isClockRollback(Hlc local, int wallMs) => wallMs < local.physicalMs;

  /// 两个时间戳的物理时间差（毫秒，可正可负）。
  Duration physicalGap(Hlc other) =>
      Duration(milliseconds: physicalMs - other.physicalMs);

  String encode() =>
      '${physicalMs.toRadixString(16).padLeft(_hexWidth, '0')}'
      '-${counter.toRadixString(16).padLeft(4, '0')}'
      '-$nodeId';

  static Hlc decode(String s) {
    final i1 = s.indexOf('-');
    if (i1 != _hexWidth) {
      throw FormatException('HLC 格式非法（首段应为 $_hexWidth 位）：$s');
    }
    final i2 = s.indexOf('-', i1 + 1);
    if (i2 != _hexWidth + 5) {
      throw FormatException('HLC 格式非法（次段应为 4 位）：$s');
    }
    return Hlc(
      int.parse(s.substring(0, i1), radix: 16),
      int.parse(s.substring(i1 + 1, i2), radix: 16),
      s.substring(i2 + 1),
    );
  }

  /// 解析失败时返回 null，用于处理历史脏数据（不抛异常打断同步循环）。
  static Hlc? tryDecode(String s) {
    try {
      return decode(s);
    } on FormatException {
      return null;
    }
  }

  @override
  int compareTo(Hlc other) {
    if (physicalMs != other.physicalMs) {
      return physicalMs.compareTo(other.physicalMs);
    }
    if (counter != other.counter) return counter.compareTo(other.counter);
    return nodeId.compareTo(other.nodeId);
  }

  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator >=(Hlc other) => compareTo(other) >= 0;
  bool operator <=(Hlc other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.physicalMs == physicalMs &&
      other.counter == counter &&
      other.nodeId == nodeId;

  @override
  int get hashCode => Object.hash(physicalMs, counter, nodeId);

  @override
  String toString() => encode();
}
