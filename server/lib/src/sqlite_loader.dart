import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

/// SQLite 动态库的解析结果。落在启动横幅与 `/api/health` 上。
///
/// 存在的理由：SQLite 是本项目唯一一个「不随代码走」的运行时依赖。
/// 万一某天 Windows 更新挪走了 `winsqlite3.dll`，或者部署目录被拷到了
/// 一台没有它的机器上，**必须在启动时就明确报出来**，
/// 而不是等到用户第一次保存菜谱才抛一个栈。
class SqliteLibraryInfo {
  /// 实际生效的库（描述或路径）。
  final String library;

  /// 库自己报告的版本（由一次真实的 `SELECT sqlite_version()` 得到）。
  final String version;

  /// 是不是走命令行/环境变量显式指定的。
  final bool isForced;

  /// 被跳过的库，连同原因。启动时打印，便于排障。
  final List<String> skipped;

  const SqliteLibraryInfo({
    required this.library,
    required this.version,
    required this.isForced,
    this.skipped = const [],
  });

  /// 用到的功能所需的最低版本。
  ///
  /// `3.24` 是硬门槛 —— 同步的幂等写入依赖 `UPSERT`
  /// （`INSERT ... ON CONFLICT ... DO UPDATE`），低于它直接语法报错。
  static const String minimumVersion = '3.24.0';

  String get summary => 'SQLite $version（$library）';

  @override
  String toString() => summary;
}

SqliteLibraryInfo? _loaded;

/// 已加载的库信息。加载过之后可以直接取，没加载过则为 null。
SqliteLibraryInfo? get sqliteLibraryInfo => _loaded;

/// 清掉缓存，让下一次 [loadSqlite] 重新走一遍解析。只给测试用。
void resetSqliteLoaderForTesting() => _loaded = null;

/// 核心符号：少了任何一个就不必继续了。
///
/// `DynamicLibrary.open` 成功**不代表能用**——名字对、内容错的 DLL 同样能被加载。
/// 这是绝对最小集合；package:sqlite3 还需要更多，那些交给后面那次真实查询暴露。
const List<String> _requiredSymbols = [
  'sqlite3_libversion',
  'sqlite3_open_v2',
  'sqlite3_prepare_v2',
  'sqlite3_step',
  'sqlite3_finalize',
  'sqlite3_exec',
  'sqlite3_errmsg',
  'sqlite3_close',
];

/// 解析并加载 SQLite 动态库；成功后返回它究竟是什么。
///
/// 三种情况，按顺序：
///
/// 1. **显式指定**（`--sqlite-lib <path>` 或环境变量 `ZAOJI_SQLITE_LIB`）：
///    用这一份。**失败就抛错，不会静默回落** —— 用户既然指定了，就有权知道
///    它有没有生效；偷偷换一个库比直接报错更糟。
/// 2. **默认解析**：交给 `package:sqlite3`。Windows 上它依次试
///    `sqlite3.dll` → `winsqlite3.dll`（Windows 10 17063+ 自带，本机实测 3.51.1）。
///    而 `LoadLibrary` 的搜索顺序本就是**先 exe 所在目录**，
///    所以「自己带一份 sqlite3.dll 放 exe 旁边」这条天然成立，不必我们再排一遍。
/// 3. **兜底**：默认解析如果加载成功但**符号不全**（典型的「exe 旁边躺着一个坏 DLL」），
///    显式改用 `winsqlite3.dll`。`package:sqlite3` 自己不会做这件事 ——
///    它只对 `DynamicLibrary.open` 的失败回退，不对符号缺失回退。
///
/// 每条路径都会真的跑一次 `SELECT sqlite_version()` 并校验最低版本。
///
/// ## 为什么不能「换个候选就跑一次 SQL 看行不行」
///
/// `package:sqlite3` 里库是这样拿到的：
///
/// ```dart
/// Sqlite3 get sqlite3 => _sqlite3 ??= FfiSqlite3(open.openSqlite());
/// ```
///
/// **第一次访问就被永久记住**，之后 `overrideFor` 改也不生效。
/// 所以逐候选试 SQL 验证不到新候选——跑的还是最初那个库。
/// （踩过：给一个根本不存在的路径，候选 1 却"成功"了。）
/// 因此覆盖只发生在**已经决定用它**的时候，绝不用来试探。
SqliteLibraryInfo loadSqlite({String? explicitPath}) {
  if (_loaded != null) return _loaded!;

  final env = Platform.environment['ZAOJI_SQLITE_LIB'];
  final forced = explicitPath ?? ((env == null || env.isEmpty) ? null : env);
  final skipped = <String>[];

  // ── 1. 显式指定：权威，失败即抛 ──
  //
  // 注意顺序：**先验证 DLL，通过了才 override**。
  // 反过来的话，路径写错时 override 已经指向那个坏函数并留在全局，
  // 会连带把后面的默认解析一起毒掉。
  if (forced != null) {
    try {
      _requireSymbols(DynamicLibrary.open(forced));
    } catch (e) {
      // 包装成自己的异常：FFI 原生的 ArgumentError 虽然也说了原因，
      // 但不会告诉你「要么修路径、要么把这一项去掉」。
      throw SqliteLoadException(
        '显式指定的 SQLite 库用不了：$forced\n'
        '  原因：$e\n'
        '  要么把路径改对，要么去掉 --sqlite-lib / 环境变量 ZAOJI_SQLITE_LIB 让它走默认解析。',
      );
    }
    _overrideTo(() => DynamicLibrary.open(forced));
    _loaded = SqliteLibraryInfo(
      library: forced,
      version: _verify(),
      isForced: true,
      skipped: skipped,
    );
    return _loaded!;
  }

  // ── 2. 默认解析 ──
  try {
    final version = _verify();
    _loaded = SqliteLibraryInfo(
      library: '默认解析（sqlite3.dll → winsqlite3.dll）',
      version: version,
      isForced: false,
      skipped: skipped,
    );
    return _loaded!;
  } catch (e) {
    skipped.add('默认解析 → $e');
  }

  // ── 3. 兜底：只可能是「默认解析到的库符号不全」，直接换系统库 ──
  if (Platform.isWindows) {
    try {
      _overrideTo(() => DynamicLibrary.open('winsqlite3.dll'));
      final version = _verify();
      return _loaded = SqliteLibraryInfo(
        library: 'winsqlite3.dll（Windows 自带）',
        version: version,
        isForced: false,
        skipped: skipped,
      );
    } catch (e) {
      skipped.add('winsqlite3.dll（Windows 自带） → $e');
    }
  }

  throw SqliteLoadException(
    '没有可用的 SQLite 动态库：\n'
    '${skipped.map((r) => '  · $r').join('\n')}\n'
    '解决办法：把一份 sqlite3.dll 放到 exe 同级目录，'
    '或用 --sqlite-lib <路径> 指定。',
  );
}

/// 让 package:sqlite3 改用这份库。只能在**已经验证过它可用**之后调用。
void _overrideTo(DynamicLibrary Function() opener) {
  final os = open.os;
  if (os == null) {
    throw UnsupportedError('无法识别当前操作系统，不能指定 SQLite 库路径');
  }
  open.overrideFor(os, opener);
}

/// 校验当前生效的库：符号齐全 + 能开内存库 + 版本达标。返回版本号。
String _verify() {
  _requireSymbols(open.openSqlite());
  final db = sqlite3.openInMemory();
  final String version;
  try {
    version = db.select('SELECT sqlite_version() AS v').first['v'] as String;
  } finally {
    db.dispose();
  }
  final min = SqliteLibraryInfo.minimumVersion;
  if (compareVersions(version, min) < 0) {
    throw UnsupportedError('SQLite $version 太旧，需要 >= $min（UPSERT 用于同步的幂等写入）');
  }
  return version;
}

void _requireSymbols(DynamicLibrary lib) {
  for (final name in _requiredSymbols) {
    try {
      lib.lookupFunction<Void Function(), void Function()>(name);
    } on ArgumentError {
      throw StateError('缺少符号 $name');
    }
  }
}

/// 比较 `3.51.1` 这类版本号。缺省的段按 0 处理（`3.24` == `3.24.0`）。
int compareVersions(String a, String b) {
  List<int> parts(String s) => s
      .split('.')
      .map((x) => int.tryParse(RegExp(r'^\d+').stringMatch(x) ?? '') ?? 0)
      .toList();

  final pa = parts(a);
  final pb = parts(b);
  for (var i = 0; i < 3; i++) {
    final x = i < pa.length ? pa[i] : 0;
    final y = i < pb.length ? pb[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

class SqliteLoadException implements Exception {
  final String message;
  const SqliteLoadException(this.message);

  @override
  String toString() => 'SqliteLoadException: $message';
}
