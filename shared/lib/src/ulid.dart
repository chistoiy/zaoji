/// ULID —— 用作所有业务表的主键。
///
/// 为什么不用自增整数或 UUID v4：
///
/// | 方案 | 问题 |
/// |---|---|
/// | 自增整数 | 两端各自生成必然撞车，同步时无法合并 |
/// | UUID v4 | 随机，**无序**。用它当主键，B-Tree 索引会频繁页分裂；列表按 id 排序毫无意义 |
/// | **ULID** | 前 48 bit 是毫秒时间戳，**字典序 == 时间序**，天然按创建顺序排列，且全局唯一 |
///
/// 与 HLC 是同一个设计思想：**把「有序」编码进字符串本身**，
/// 这样两端各自离线生成的 ID 合到一起也不需要重排。
///
/// 编码用 Crockford Base32（去掉容易看错的 I / L / O / U），26 字符定长。
library;

import 'dart:math';

/// Crockford Base32 字母表：去掉了 `I` `L` `O` `U` 四个易混字符。
const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/// 时间戳部分占 10 字符（48 bit），随机部分占 16 字符（80 bit）。
const int timeChars = 10;
const int randomChars = 16;
const int ulidLength = timeChars + randomChars;

class Ulid {
  Ulid._();

  /// 生成一个新的 ULID。
  ///
  /// [at] 指定时间戳（测试用）。[random] 注入随机源（测试用）。
  static String generate({DateTime? at, Random? random}) {
    final rnd = random ?? Random.secure();
    final ms = (at ?? DateTime.now()).millisecondsSinceEpoch;
    if (ms < 0) {
      throw ArgumentError('时间戳不能为负：$ms');
    }
    // 48 bit 上限（约公元 10889 年）。超过就是调用方传错了。
    if (ms > 0xFFFFFFFFFFFF) {
      throw ArgumentError('时间戳超出 48 bit 范围：$ms');
    }
    return _encodeTime(ms) + _encodeRandom(rnd);
  }

  /// 从 ULID 里取回创建时间。非法输入返回 null。
  static DateTime? timestampOf(String ulid) {
    if (!isValid(ulid)) return null;
    var ms = 0;
    for (var i = 0; i < timeChars; i++) {
      ms = (ms << 5) | _alphabet.indexOf(ulid[i]);
    }
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// 校验格式。
  ///
  /// 注意与标准 ULID 的一处**有意偏离**：标准规定首位不能大于 `7`
  /// （因为 48 bit 装不满 10×5 bit）。我们对首位不做这个限制，
  /// 但生成时**一定会保证**它在合法范围内——校验放宽是为了兼容未来导入的外部数据。
  static bool isValid(String ulid) {
    if (ulid.length != ulidLength) return false;
    for (var i = 0; i < ulidLength; i++) {
      if (!_alphabet.contains(ulid[i])) return false;
    }
    return true;
  }

  /// 排序用比较器。因为编码后字典序 == 时间序，直接比字符串即可。
  static int compare(String a, String b) => a.compareTo(b);

  static String _encodeTime(int ms) {
    final buf = List<String>.filled(timeChars, '0');
    var v = ms;
    for (var i = timeChars - 1; i >= 0; i--) {
      buf[i] = _alphabet[v & 0x1F];
      v >>= 5;
    }
    return buf.join();
  }

  static String _encodeRandom(Random rnd) {
    final buf = List<String>.filled(randomChars, '0');
    for (var i = 0; i < randomChars; i++) {
      buf[i] = _alphabet[rnd.nextInt(_alphabet.length)];
    }
    return buf.join();
  }
}

/// 单调 ULID 生成器。
///
/// 同一毫秒内连续生成多个 ID 时，普通 `generate()` 的顺序是随机的——
/// 批量导入 50 道菜后，列表按 id 排序会得到一个**打乱的顺序**。
/// 这个工厂保证同一毫秒内生成的 ULID 严格递增（把随机部分当计数器 +1），
/// 所以「按 id 排序」永远等于「按创建顺序排序」。
class UlidFactory {
  final Random _rnd;

  int _lastMs = -1;
  final List<int> _lastRandom = List<int>.filled(randomChars, 0);

  UlidFactory({Random? random}) : _rnd = random ?? Random.secure();

  String next({DateTime? at}) {
    final ms = (at ?? DateTime.now()).millisecondsSinceEpoch;

    if (ms > _lastMs) {
      _lastMs = ms;
      final r = _rnd.nextInt(1 << 30);
      // 用 30 bit 随机打底，剩下的位留给同毫秒内的递增
      for (var i = 0; i < randomChars; i++) {
        _lastRandom[i] = (r >> (i * 2)) & 0x1F;
      }
    } else {
      _increment();
    }
    return _encodeTime(_lastMs) + _lastRandom.map((v) => _alphabet[v]).join();
  }

  /// 随机部分当作大整数 +1；溢出时进位到毫秒（保证单调不破坏）。
  void _increment() {
    for (var i = randomChars - 1; i >= 0; i--) {
      if (_lastRandom[i] < _alphabet.length - 1) {
        _lastRandom[i]++;
        return;
      }
      _lastRandom[i] = 0;
    }
    _lastMs++;
  }

  static String _encodeTime(int ms) {
    final buf = List<String>.filled(timeChars, '0');
    var v = ms;
    for (var i = timeChars - 1; i >= 0; i--) {
      buf[i] = _alphabet[v & 0x1F];
      v >>= 5;
    }
    return buf.join();
  }
}
