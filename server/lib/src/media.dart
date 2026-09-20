import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

/// 内容寻址的图片存储：`data/media/<sha256>`，以及按需派生的缩略图
/// `data/media/thumb/<sha256>-<width>.jpg`。
///
/// 设计要点（出处：计划书 §6 图片管线 / 交接文档「图片：客户端压 1600px/q82，
/// 缩略图入库，原图按 sha256 按需拉取」）：
///
/// - **图片不走 change_log**。change_log 的载荷是按行现取的 JSON，
///   塞几 MB 的图片进去会把增量拉取整个拖垮。图片只在 recipe 行上留一个
///   `cover_sha256` 引用（跟着普通同步走），字节本体由显示端**按需**来拉。
/// - **哈希即内容契约**：客户端先算 sha256、PUT 到 `/api/media/<sha>`，
///   服务端重算并校验一致才落盘。校验失败拒绝——否则一个写错的引用
///   会让显示端永远拉到错的图，且两头都不报错。
/// - **内容寻址 = 天然去重**：同一张图传两遍、两道菜用同一张图，
///   磁盘上永远只有一份。写一次永不改（改名是内容变更 = 新哈希 = 新文件）。
///
/// 缩略图（R17）为什么放在**服务端按需派生**，而不是让客户端多传一份：
///
/// - 客户端多传一份要动 `recipe` 表再加一列 → schema 迁移 + 老数据没有缩略图
///   （要么回填要么长期双路径）；
/// - 派生结果是 `(sha, width)` 的**纯函数**，缓存永不过期、天然幂等，
///   且对**所有已有图片立刻生效**，不需要一次性重算历史数据；
/// - 代价只是笔记本上第一次访问时多几十到几百毫秒 CPU，之后全是读文件。
class MediaStore {
  MediaStore(this.dir);

  /// 存放目录（`data/media`）。`put` 时按需创建。
  final Directory dir;

  /// 派生缩略图的子目录。
  ///
  /// 放**子目录**而不是与原名平铺：`media/` 下每个文件都必须是一个内容寻址的原图，
  /// 这条不变量要保住——将来做孤儿回收、统计磁盘占用、备份，都是直接遍历 `media/` 一层。
  /// 派生文件混进去，这类遍历立刻需要过滤条件（而过滤条件总会有人忘加）。
  Directory get thumbDir =>
      Directory('${dir.path}${Platform.pathSeparator}thumb');

  static final RegExp _shaPattern = RegExp(r'^[0-9a-f]{64}$');

  /// 路径参数与客户端引用都必须是 64 位小写十六进制。
  /// 挡掉 `../`、绝对路径这类路径穿越尝试——拼路径之前先验格式。
  static bool isValidSha(String s) => _shaPattern.hasMatch(s);

  /// 缩略图档位白名单（像素宽）。
  ///
  /// - `640` → 列表卡片。手机 390 逻辑像素宽两列，卡片约 173 逻辑像素 × 3 DPR ≈ 519 物理像素。
  /// - `1280` → 详情大图。满宽 390 逻辑像素 × 3 DPR ≈ 1170。
  ///
  /// **必须是白名单，不能「任意宽度都接受」**：派生结果要落盘成
  /// `<sha>-<w>.jpg`，接受任意 w 就等于把 `?w=1`、`?w=2` … `?w=9999` 变成
  /// 一条写满磁盘的路径——而这台机器是家里没人看着的笔记本，不是有运维的服务器。
  /// 白名单顺带保证了「同一个 sha 的派生结果是一个固定有限集」，缓存可以放心长期留存。
  static const List<int> thumbWidths = [640, 1280];

  /// 缩略图一律重编码成 JPEG：统一格式，客户端不必按档位去猜 content-type。
  static const int thumbQuality = 78;

  static bool isValidThumbWidth(int w) => thumbWidths.contains(w);

  /// 允许的图片格式，按**魔数**判断（不信扩展名、不信 Content-Type 头）。
  /// 白名单之外一律拒绝：这是图片接口，不是网盘。
  static String? sniffImageType(Uint8List b) {
    if (b.length < 12) return null;
    // JPEG: FF D8 FF
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return 'image/jpeg';
    // PNG: 89 50 4E 47 0D 0A 1A 0A
    if (b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47 &&
        b[4] == 0x0D &&
        b[5] == 0x0A &&
        b[6] == 0x1A &&
        b[7] == 0x0A) {
      return 'image/png';
    }
    // WebP: RIFF....WEBP
    if (b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      return 'image/webp';
    }
    return null;
  }

  /// 计算 bytes 的 sha256（小写 hex）。客户端与服务端共用同一个算法约定。
  static String sha256Hex(Uint8List bytes) => sha256.convert(bytes).toString();

  /// 原图路径。`<dir>/<64 位 hex>`。
  File fileFor(String sha) =>
      File('${dir.path}${Platform.pathSeparator}$sha');

  /// 缩略图路径。`<dir>/thumb/<64 位 hex>-<width>.jpg`。
  File thumbFileFor(String sha, int width) =>
      File('${thumbDir.path}${Platform.pathSeparator}$sha-$width.jpg');

  bool exists(String sha) => isValidSha(sha) && fileFor(sha).existsSync();

  bool thumbExists(String sha, int width) =>
      isValidSha(sha) && thumbFileFor(sha, width).existsSync();

  /// 落盘。调用方必须已完成鉴权 / 大小上限 / 哈希校验 / 格式嗅探——
  /// 这里只负责「写一次」本身。
  Future<MediaPutResult> put(String sha, Uint8List bytes) async {
    final target = fileFor(sha);

    if (target.existsSync()) {
      // 内容寻址：已存在 = 同一张图，直接判成功（幂等）。
      // 不重写：磁盘上这一份可能与正在写入的并发请求共享。
      final existing = await target.readAsBytes();
      return MediaPutResult(
        sha: sha,
        size: existing.length,
        type: sniffImageType(existing) ?? 'application/octet-stream',
        duplicated: true,
      );
    }

    await _writeOnce(target, bytes);

    return MediaPutResult(
      sha: sha,
      size: bytes.length,
      type: sniffImageType(bytes) ?? 'application/octet-stream',
      duplicated: false,
    );
  }

  Future<Uint8List> read(String sha) async {
    final bytes = await fileFor(sha).readAsBytes();
    return Uint8List.fromList(bytes);
  }

  // ───────────────────── 清单 / 统计 / 删除（R18 孤儿回收用） ─────────────────────

  /// 原图清单（只认 64 位 hex 的文件名）。
  ///
  /// 临时文件（`<sha>.tmp`）与派生图都不会被列进来——这正是把派生图放子目录的好处：
  /// 「遍历 `media/` 一层拿到的就是全部原图」这条不变量可以直接用，不必加过滤条件。
  List<String> listOriginals() {
    if (!dir.existsSync()) return const [];
    final out = <String>[];
    for (final e in dir.listSync()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (isValidSha(name)) out.add(name);
    }
    out.sort();
    return out;
  }

  static final RegExp _thumbNamePattern = RegExp(r'^([0-9a-f]{64})-(\d+)\.jpg$');

  /// 派生图清单。解析不出名字的文件（如残留的 `.tmp`）一律忽略。
  List<MediaThumb> listThumbs() {
    final td = thumbDir;
    if (!td.existsSync()) return const [];
    final out = <MediaThumb>[];
    for (final e in td.listSync()) {
      if (e is! File) continue;
      final m = _thumbNamePattern.firstMatch(e.uri.pathSegments.last);
      if (m == null) continue;
      out.add(MediaThumb(sha: m.group(1)!, width: int.parse(m.group(2)!), file: e));
    }
    out.sort((a, b) => a.sha == b.sha
        ? a.width.compareTo(b.width)
        : a.sha.compareTo(b.sha));
    return out;
  }

  /// 删掉一张原图**连同它的所有派生图**。
  ///
  /// 一起删是刻意的：派生图的存在前提是原图存在。留下「没有原图的缩略图」
  /// 只会让下一次统计把它们算成另一类垃圾，问题被推给下一轮而不是解决。
  ///
  /// 调用方负责判断「这张图确实没有引用了」——这里不做任何引用检查。
  Future<MediaDeleteResult> delete(String sha) async {
    var files = 0;
    var bytes = 0;
    final f = fileFor(sha);
    if (f.existsSync()) {
      bytes += await f.length();
      await f.delete();
      files++;
    }
    for (final t in listThumbs()) {
      if (t.sha != sha) continue;
      bytes += await t.file.length();
      await t.file.delete();
      files++;
    }
    return MediaDeleteResult(files: files, bytes: bytes);
  }

  /// 统计磁盘占用。**遍历的是真实文件，不是数据库里的引用**——
  /// 这一条是刻意的：库里的引用与实际占用的差额，正是「孤儿」的定义。
  MediaStats stats() {
    var originals = 0;
    var originalBytes = 0;
    for (final sha in listOriginals()) {
      final f = fileFor(sha);
      if (!f.existsSync()) continue;
      originals++;
      originalBytes += f.lengthSync();
    }
    var thumbs = 0;
    var thumbBytes = 0;
    for (final t in listThumbs()) {
      thumbs++;
      thumbBytes += t.file.lengthSync();
    }
    return MediaStats(
      originals: originals,
      originalBytes: originalBytes,
      thumbs: thumbs,
      thumbBytes: thumbBytes,
    );
  }

  /// 取缩略图：**有缓存读缓存，没有就派生一次并落盘**。
  ///
  /// 宽度不在白名单里直接抛（调用方本该先验，这里是第二道闸）。
  /// 派生失败抛 [FormatException]（图片解不开），由调用方翻成 415。
  Future<Uint8List> readOrDeriveThumb(String sha, int width) async {
    if (!isValidThumbWidth(width)) {
      throw ArgumentError.value(width, 'width', '不在缩略图档位白名单里');
    }
    final f = thumbFileFor(sha, width);
    if (await f.exists()) {
      return Uint8List.fromList(await f.readAsBytes());
    }
    final derived = await _deriveMany(await read(sha), [width]);
    final bytes = derived[width]!;
    await _writeOnce(f, bytes);
    return bytes;
  }

  /// 预热：把还缺的档位一次派生好。
  ///
  /// 上传后顺手调用，这样「刚选完照片回到列表」立刻就有缩略图，
  /// 不必等第一次拉取时现算（那一次用户是能感觉到转圈的）。
  ///
  /// **一次解码、多档缩放**：两档分别跑等于把同一张 JPEG 解码两遍，
  /// 而解码是整条链路里最贵的一步。
  ///
  /// **best-effort**：失败不影响上传结果——缩略图是纯派生数据，丢了随时能再算；
  /// 而「用户刚选的照片被拒绝」是不可重来的。
  Future<void> warmThumbs(String sha) async {
    if (!exists(sha)) return;
    final missing = <int>[];
    for (final w in thumbWidths) {
      if (!thumbExists(sha, w)) missing.add(w);
    }
    if (missing.isEmpty) return;
    try {
      final derived = await _deriveMany(await read(sha), missing);
      for (final w in missing) {
        await _writeOnce(thumbFileFor(sha, w), derived[w]!);
      }
    } catch (_) {
      // 故意吞掉：见上，缩略图是纯派生数据
    }
  }

  /// 解码 + 缩放 + 编码。**必须在 isolate 里跑**。
  ///
  /// 这三步是纯 CPU 活，一张 1600px JPEG 解码是几十到几百毫秒。
  /// 服务端只有一个事件循环，在请求处理里同步做完，等于让同一时刻
  /// 所有人的 `/api/changes` 一起等这一张图——那才是真事故。
  static Future<Map<int, Uint8List>> _deriveMany(
    Uint8List src,
    List<int> widths,
  ) {
    return Isolate.run(() => _deriveManySync(src, widths));
  }

  static Map<int, Uint8List> _deriveManySync(Uint8List src, List<int> widths) {
    // 解码器面对截断 / 伪造的文件头会抛各种异常（RangeError / ImageException…），
    // 全部收敛成一个语义：**这个文件的格式不对**。否则一个坏文件会以 500 冒出去，
    // 看起来像服务端故障，实际只是某张图存坏了。
    img.Image? decoded;
    try {
      decoded = img.decodeImage(src);
    } catch (_) {
      decoded = null;
    }
    if (decoded == null) {
      throw const FormatException('无法解码这张图片，派生不了缩略图');
    }
    final out = <int, Uint8List>{};
    for (final w in widths) {
      // 原图比目标还窄就不放大——放大只会更糊、还更大
      final scaled = decoded.width <= w
          ? decoded
          : img.copyResize(
              decoded,
              width: w,
              interpolation: img.Interpolation.average,
            );
      out[w] = img.encodeJpg(scaled, quality: thumbQuality);
    }
    return out;
  }

  /// 「写一次」：先写临时文件再 rename。
  ///
  /// 写一半被杀不会留下一个「存在但损坏」的文件（哈希寻址的世界里，
  /// **损坏比缺失更糟**——缺失还能重传，损坏会被永久引用）。
  ///
  /// 临时文件后缀 `.tmp` 落在同目录，但它既不匹配 64 位 hex（原图）也不匹配
  /// `<sha>-<w>.jpg`（缩略图），所以遍历目录时不会被误认成一份正式数据。
  Future<void> _writeOnce(File target, Uint8List bytes) async {
    await target.parent.create(recursive: true);
    if (target.existsSync()) return; // 内容必然一致，不重写
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      // 并发写同一份：rename 因目标已存在而失败是良性的（内容必然一致），
      // 丢掉自己的临时文件即可。
      if (target.existsSync()) {
        try {
          await tmp.delete();
        } catch (_) {}
      } else {
        rethrow;
      }
    }
  }
}

class MediaPutResult {
  const MediaPutResult({
    required this.sha,
    required this.size,
    required this.type,
    required this.duplicated,
  });

  final String sha;
  final int size;
  final String type;

  /// true = 服务端早就有这张图（重复上传 / 幂等重放）。
  final bool duplicated;
}

/// 一个派生文件的身份：来自哪张原图、哪一档。
class MediaThumb {
  const MediaThumb({required this.sha, required this.width, required this.file});

  /// 源原图的 sha256。
  final String sha;

  /// 档位（像素宽）。
  final int width;

  final File file;
}

class MediaDeleteResult {
  const MediaDeleteResult({required this.files, required this.bytes});

  /// 实际删掉的文件数（原图 + 派生图）。
  final int files;

  /// 实际释放的字节数。
  final int bytes;
}

/// 磁盘占用快照。
class MediaStats {
  const MediaStats({
    required this.originals,
    required this.originalBytes,
    required this.thumbs,
    required this.thumbBytes,
  });

  final int originals;
  final int originalBytes;
  final int thumbs;
  final int thumbBytes;

  /// 从 health 载荷里那份 JSON 还原（状态页与健康接口共用同一份数字，
  /// 避免页面自己再遍历一遍盘）。
  factory MediaStats.fromJson(Map<String, Object?> j) => MediaStats(
        originals: (j['originals'] as int?) ?? 0,
        originalBytes: (j['originalBytes'] as int?) ?? 0,
        thumbs: (j['thumbs'] as int?) ?? 0,
        thumbBytes: (j['thumbBytes'] as int?) ?? 0,
      );

  int get totalBytes => originalBytes + thumbBytes;

  /// 平均一张原图多大（用来向用户解释「占了这么多是因为多少张照片」）。
  int get avgOriginalBytes =>
      originals == 0 ? 0 : (originalBytes / originals).round();

  Map<String, Object?> toJson() => {
        'originals': originals,
        'originalBytes': originalBytes,
        'thumbs': thumbs,
        'thumbBytes': thumbBytes,
        'totalBytes': totalBytes,
      };
}
