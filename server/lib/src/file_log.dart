import 'dart:io';

/// 带轮转的文件日志（R19③）。
///
/// **为什么必须存在**：注册成 Windows 服务后没有控制台，stdout 重定向到文件
/// 又是块缓冲——进程被强杀时缓冲区连同启动横幅一起消失（R5 坑 6）。届时
/// 「家里那台笔记本半夜为什么重启过」将完全没有线索。
///
/// 三条立场：
/// 1. **每行即写即 flush**。家庭场景的日志量是每分钟几条，不是每秒几千条——
///    flush 的代价可以忽略，而「写完立刻可见」正是块缓冲的反义词。
/// 2. **按大小轮转、份数有封顶**。没有上限的轮转等于换一种方式涨满磁盘；
///    轮转是搬家不是删除，旧内容完整进下一份。
/// 3. **控制台与文件是同一份内容**（echo 回调），不允许两条路各写各的——
///    「日志与事实一致」在这里的推论是「日志与屏幕一致」。
///
/// `dir == null` 时退化为纯控制台（单元测试与未配置日志目录的开发环境），
/// 与引入本类之前的行为完全相同。
class FileLog {
  FileLog(this.dir, {
    this.maxBytes = 5 * 1024 * 1024,
    this.keep = 5,
    this.echo,
  });

  /// 日志目录。null = 不写文件。
  final Directory? dir;

  /// 单份上限。越过它才轮转——允许最后一行把它撑爆一点（检查发生在写入前）。
  final int maxBytes;

  /// 保留几份历史（`.1 … .keep`）。
  final int keep;

  /// 每行同时送去的地方（通常是 `stdout.writeln`）。
  final void Function(String line)? echo;

  static final String _sep = Platform.pathSeparator;

  String get _basePath => '${dir!.path}${_sep}zaoji.log';

  /// 主日志文件路径（未配置目录时为 null，状态页/health 原样报出，不编造）。
  String? get path => dir == null ? null : _basePath;

  /// 主日志当前字节数。
  int get bytes => dir == null ? 0 : File(_basePath).lengthSync();

  /// 写一条日志。`content` 含换行时**按行拆开**，每行各自带时间戳——
  /// 半行无时间戳的日志在 grep 里是孤儿。空行丢弃（日志文件不存排版）。
  Future<void> write(String content) async {
    for (final line in content.split('\n')) {
      if (line.isEmpty) continue;
      echo?.call(line);
      if (dir == null) continue;
      await _append('${DateTime.now().toIso8601String()} $line');
    }
  }

  Future<void> _append(String s) async {
    if (!dir!.existsSync()) dir!.createSync(recursive: true);
    final main = File(_basePath);
    if (main.existsSync() && main.lengthSync() >= maxBytes) _rotate(main);
    // flush: true —— 本类存在的意义就在这一个参数上
    await main.writeAsString('$s\n', mode: FileMode.append, flush: true);
  }

  /// 轮转：删掉最旧一份 → 其余依次后移 → 主文件成为 `.1`。
  void _rotate(File main) {
    final oldest = File('$_basePath.$keep');
    if (oldest.existsSync()) oldest.deleteSync();
    for (var i = keep - 1; i >= 1; i--) {
      final from = File('$_basePath.$i');
      if (from.existsSync()) from.renameSync('$_basePath.${i + 1}');
    }
    main.renameSync('$_basePath.1');
  }
}
