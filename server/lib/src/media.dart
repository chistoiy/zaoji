import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 内容寻址的图片存储：`data/media/<sha256>`。
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
class MediaStore {
  MediaStore(this.dir);

  /// 存放目录（`data/media`）。`put` 时按需创建。
  final Directory dir;

  static final RegExp _shaPattern = RegExp(r'^[0-9a-f]{64}$');

  /// 路径参数与客户端引用都必须是 64 位小写十六进制。
  /// 挡掉 `../`、绝对路径这类路径穿越尝试——拼路径之前先验格式。
  static bool isValidSha(String s) => _shaPattern.hasMatch(s);

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

  File fileFor(String sha) =>
      File('${dir.path}${Platform.pathSeparator}$sha');

  bool exists(String sha) => isValidSha(sha) && fileFor(sha).existsSync();

  /// 落盘。调用方必须已完成鉴权 / 大小上限 / 哈希校验 / 格式嗅探——
  /// 这里只负责「写一次」本身。
  Future<MediaPutResult> put(String sha, Uint8List bytes) async {
    await dir.create(recursive: true);
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

    // 先写临时文件再 rename：写一半被杀不会留下一个「存在但损坏」的媒体文件
    // （哈希寻址的世界里，损坏比缺失更糟——缺失还能重传，损坏会被永久引用）。
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    try {
      await tmp.rename(target.path);
    } on FileSystemException {
      // 并发写同一张图：rename 因目标已存在而失败是良性的（内容必然一致），
      // 丢掉自己的临时文件即可。
      if (target.existsSync()) {
        try {
          await tmp.delete();
        } catch (_) {}
      } else {
        rethrow;
      }
    }

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
