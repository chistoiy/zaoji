// 图片链路冒烟测试的小工具（不是产品代码，只是让验证可重复）。
//
// 为什么需要它：验证缩略图链路必须有一张**尺寸够大、真能解码**的图片。
// 魔数嗅探用 16 字节的假字节就能骗过，但派生缩略图要真解码——
// 而拿手机拍的照片当 fixture 既不进仓库也不好复现。
//
// 用法（在 server/ 目录下）：
//   dart run tool/make_sample_photo.dart gen  <out.jpg> [salt]   # 生成 2000×1500 的 JPEG
//       salt 改变底色 → 改变字节与 sha256。**内容寻址存储里，同图只存一份**——
//       E2E 想要一次「真的新增文件」，必须每次生成不同的图，否则会被幂等去重吞掉。
//   dart run tool/make_sample_photo.dart info <file>      # 打印宽高与字节数（验缩略图用）
//
// 典型冒烟链路（配合 curl，注意 --noproxy 与 Bearer token）：
//   PUT  /api/media/<sha>        → 上传
//   GET  /api/media/<sha>        → 原图，info 应报 2000×1500
//   GET  /api/media/<sha>?w=640  → 缩略图，info 应报 640×480
//   GET  /api/media/<sha>?w=1280 → 缩略图，info 应报 1280×960
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('用法：dart run tool/make_sample_photo.dart gen|info|sha <路径>');
    exit(2);
  }
  final cmd = args[0];
  final path = args[1];

  switch (cmd) {
    case 'gen':
      final salt = args.length > 2 ? int.tryParse(args[2]) ?? 0 : 0;
      final bytes = img.encodeJpg(
        img.fill(
          img.Image(width: 2000, height: 1500),
          color: img.ColorRgb8(
            100 + salt % 100,
            80 + (salt * 13) % 120,
            60 + (salt * 29) % 140,
          ),
        ),
        quality: 90,
      );
      File(path).writeAsBytesSync(bytes, flush: true);
      stdout.writeln('written=$path bytes=${bytes.length} '
          'sha256=${sha256.convert(bytes)}');
      break;

    case 'info':
      final f = File(path);
      if (!f.existsSync()) {
        stderr.writeln('文件不存在：$path');
        exit(1);
      }
      final bytes = f.readAsBytesSync();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) {
        stdout.writeln('bytes=${bytes.length} 解码失败（缩略图没派生成功？）');
        exit(1);
      }
      stdout.writeln('bytes=${bytes.length} '
          'size=${decoded.width}x${decoded.height} '
          'sha256=${sha256.convert(bytes)}');
      break;

    default:
      stderr.writeln('未知命令：$cmd');
      exit(2);
  }
}
