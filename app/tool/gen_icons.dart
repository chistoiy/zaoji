// R39 · 从一张源图生成全端应用图标。
//
//   dart run tool/gen_icons.dart          （在 app/ 目录下执行）
//
// 源图：assets/icon/source.png（1536×1536，线装手账 + 锅铲 + 食材清单）
// 源图右下角带「豆包AI生成」水印，而它正好在画面主体之外——
// 所以第一步是**把主体下方那条带子刷白**，不是裁剪、也不是覆盖贴图：
// 裁掉会丢画面，覆盖会留一块和背景不同的补丁。
//
// 产出：
//   · Android 五档密度 ic_launcher.png（mdpi48 … xxxhdpi192）
//   · Android 自适应图标 mipmap-anydpi-v26/ic_launcher.xml
//     （前景 = 主体缩到安全区内；背景 = 暖纸纯色，让白卡片浮在纸上）
//   · Web/PWA icons/Icon-192.png、Icon-512.png、Icon-maskable-*.png、favicon.png
//
// 为什么不用 flutter_launcher_icons：它要求源图本身干净、且自适应图层的
// 留白比例不好控制；这里要同时管水印、安全区和"纸底 + 白卡"两层，
// 自己写 60 行比跟插件的配置项较劲划算。

import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

const _source = 'assets/icon/source.png';

/// 纸底：跟**默认主题**的纸色走（现在是蓝染粗布 = 冷白）。
/// 改默认主题时这里和 web/manifest.json 的两个颜色要一起改。
const _paper = 0xFFF2F5F8;

/// 源图里主体（那张白卡片）的下边缘在这一行以下、水印在这一行以上。
/// 22% 底部条带是水印区，实测主体止于 80% 高度。
const _watermarkFrom = 0.84;

const _densities = <String, int>{
  'mipmap-mdpi': 48,
  'mipmap-hdpi': 72,
  'mipmap-xhdpi': 96,
  'mipmap-xxhdpi': 144,
  'mipmap-xxxhdpi': 192,
};

/// 自适应图标前景占画布的比例。Android 的安全区是中间 66/108，
/// 留一点余量取 0.62：圆/方/水滴三种遮罩下都不会被切到主体。
const _adaptiveFg = 0.62;

void main() {
  final raw = img.decodePng(File(_source).readAsBytesSync());
  if (raw == null) throw StateError('源图读不出来：$_source');
  final src = _cleanWatermark(raw);
  final box = _subjectBounds(src);
  stdout.writeln('源图 ${raw.width}x${raw.height}，去水印后主体 bbox=$box');

  // ── 传统图标：纸底铺满 + 主体居中（四周留 8% 呼吸）────────────────
  for (final e in _densities.entries) {
    final n = e.value;
    final out = _compose(src, box, n, n, n * 0.08, background: _paper);
    _write('android/app/src/main/res/${e.key}/ic_launcher.png', out);
    _write('android/app/src/main/res/${e.key}/ic_launcher_round.png', out);
  }

  // ── 自适应图标：前景按各密度出图（透明底）+ 纯色背景 xml ──────────
  // 尺寸口径：自适应画布 = 图标尺寸 × 3（mdpi 108dp → 144px，xxxhdpi → 576px）。
  // 之前先写了一版 432 再被循环里的 xxxhdpi 覆盖成 576，等于留了个"看起来成功"
  // 的中间步骤——现在只按密度各写一次。
  for (final e in _densities.entries) {
    final n = e.value;
    final side = n * 3;
    _write(
        'android/app/src/main/res/${e.key}/ic_launcher_foreground.png',
        _compose(src, box, side, side, side * (1 - _adaptiveFg) / 2,
            background: null));
  }
  File('android/app/src/main/res/drawable/ic_launcher_background.xml')
      .writeAsStringSync(_colorDrawable(_paper));
  Directory('android/app/src/main/res/mipmap-anydpi-v26').createSync(
      recursive: true);
  for (final name in ['ic_launcher', 'ic_launcher_round']) {
    File('android/app/src/main/res/mipmap-anydpi-v26/$name.xml')
        .writeAsStringSync('''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
''');
  }

  // ── Web / PWA ────────────────────────────────────────────────────
  _write('web/icons/Icon-192.png', _compose(src, box, 192, 192, 192 * .08,
      background: _paper));
  _write('web/icons/Icon-512.png', _compose(src, box, 512, 512, 512 * .08,
      background: _paper));
  // maskable 版：主体再缩一点，四周铺满纸色（系统会任意裁切形状）
  _write('web/icons/Icon-maskable-192.png',
      _compose(src, box, 192, 192, 192 * .20, background: _paper));
  _write('web/icons/Icon-maskable-512.png',
      _compose(src, box, 512, 512, 512 * .20, background: _paper));
  _write('web/favicon.png', _compose(src, box, 64, 64, 64 * .06,
      background: _paper));

  stdout.writeln('完成：Android 五档 + 自适应图层 + Web 图标与 favicon');
}

/// 把主体以下的水印条带刷白（只动源图右下角那块纯白背景上的字）。
img.Image _cleanWatermark(img.Image src) {
  final out = img.Image.from(src);
  final y0 = (src.height * _watermarkFrom).round();
  var erased = 0;
  for (var y = y0; y < out.height; y++) {
    for (var x = 0; x < out.width; x++) {
      final p = out.getPixel(x, y);
      if (p.r.toInt() < 250 || p.g.toInt() < 250 || p.b.toInt() < 250) {
        out.setPixelRgba(x, y, 255, 255, 255, 255);
        erased++;
      }
    }
  }
  stdout.writeln('水印区刷掉 $erased 个非白像素（y>=$y0）');
  return out;
}

/// 非白内容的包围盒——主体是白卡片，卡片外是纯白画布，
/// 所以"非白"就是主体本身（含卡片浅灰描边）。
List<int> _subjectBounds(img.Image src) {
  var minX = src.width, minY = src.height, maxX = 0, maxY = 0;
  for (var y = 0; y < src.height; y += 2) {
    for (var x = 0; x < src.width; x += 2) {
      final p = src.getPixel(x, y);
      if (p.r.toInt() < 250 || p.g.toInt() < 250 || p.b.toInt() < 250) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  return [minX, minY, maxX, maxY];
}

/// 生成一张 size×size 的图标：背景色（可空=透明）+ 主体按 [pad] 留白居中。
img.Image _compose(img.Image src, List<int> box, int w, int h, double pad,
    {int? background}) {
  final out = img.Image(width: w, height: h, numChannels: 4);
  if (background != null) {
    // package:image 4.x 不给你 new 一个 Pixel，只能走 setPixelRgba
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        out.setPixelRgba(
            x,
            y,
            (background >> 16) & 0xFF,
            (background >> 8) & 0xFF,
            background & 0xFF,
            255);
      }
    }
  }
  final sw = box[2] - box[0] + 1, sh = box[3] - box[1] + 1;
  final avail = math.min(w - 2 * pad, h - 2 * pad);
  final scale = avail / math.max(sw, sh);
  final dw = (sw * scale).round(), dh = (sh * scale).round();
  final cropped = img.copyCrop(
      src, x: box[0], y: box[1], width: sw, height: sh);
  final scaled = img.copyResize(cropped, width: dw, height: dh,
      interpolation: img.Interpolation.average);
  img.compositeImage(out, scaled,
      dstX: ((w - dw) / 2).round(), dstY: ((h - dh) / 2).round());
  return out;
}

String _colorDrawable(int argb) => '''<?xml version="1.0" encoding="utf-8"?>
<color xmlns:android="http://schemas.android.com/apk/res/android"
    android:color="#${argb.toRadixString(16).padLeft(8, '0')}" />
''';

void _write(String path, img.Image image) {
  final f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(img.encodePng(image));
  stdout.writeln('  写出 $path (${image.width}x${image.height})');
}
