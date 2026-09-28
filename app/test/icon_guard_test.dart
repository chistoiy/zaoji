import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// R39 · 应用图标产物的静态守护。
///
/// 为什么钉这个：图标是"生成物"，源图在 `assets/icon/source.png`。
/// 换图的人很容易只换源图、不跑生成脚本，或者只跑了 Android 那半边
/// 忘了 Web —— 结果就是手机上换了、iPhone 添加到主屏还是老图标，
/// 而且**没有任何报错**。所以这里按清单逐个点名。
void main() {
  const densities = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
  };

  group('Android 图标', () {
    for (final e in densities.entries) {
      test('${e.key}/ic_launcher.png 是 ${e.value}×${e.value}', () {
        final f = File('android/app/src/main/res/${e.key}/ic_launcher.png');
        expect(f.existsSync(), isTrue, reason: '${f.path} 不在——跑 dart run tool/gen_icons.dart');
        final decoded = img.decodePng(f.readAsBytesSync());
        expect(decoded, isNotNull);
        expect(decoded!.width, e.value);
        expect(decoded.height, e.value);
      });
    }

    test('自适应图标三件套齐（xml + 前景 + 背景色）', () {
      for (final p in [
        'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml',
        'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher_round.xml',
        'android/app/src/main/res/drawable/ic_launcher_background.xml',
        'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_foreground.png',
      ]) {
        expect(File(p).existsSync(), isTrue, reason: '缺 $p');
      }
      final xml = File(
              'android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml')
          .readAsStringSync();
      expect(xml, contains('<adaptive-icon'));
      expect(xml, contains('@drawable/ic_launcher_background'));
      expect(xml, contains('@mipmap/ic_launcher_foreground'));
    });

    test('清单同时挂方形与圆形图标', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(manifest, contains('android:icon="@mipmap/ic_launcher"'));
      expect(manifest, contains('android:roundIcon="@mipmap/ic_launcher_round"'),
          reason: '圆形启动器（部分三星/像素桌面）只认 roundIcon，漏了它就用默认图');
    });
  });

  group('Web / PWA 图标', () {
    for (final e in {
      'web/icons/Icon-192.png': 192,
      'web/icons/Icon-512.png': 512,
      'web/icons/Icon-maskable-192.png': 192,
      'web/icons/Icon-maskable-512.png': 512,
      'web/favicon.png': 64,
    }.entries) {
      test('${e.key} 是 ${e.value} 见方', () {
        final f = File(e.key);
        expect(f.existsSync(), isTrue, reason: '缺 ${e.key}');
        final decoded = img.decodePng(f.readAsBytesSync())!;
        expect(decoded.width, e.value);
        expect(decoded.height, e.value);
      });
    }

    test('manifest 说的是这个产品，不是 Flutter 模板', () {
      final s = File('web/manifest.json').readAsStringSync();
      expect(s, contains('灶记'));
      expect(s, isNot(contains('A new Flutter project')),
          reason: 'iPhone 添加到主屏时这行字会露出来');
      expect(s, isNot(contains('#0175C2')), reason: '模板蓝底会和暖纸主题打架');
      expect(s, contains('#F2F5F8'), reason: '启动背景色 = 默认主题（蓝染粗布）的纸色');
    });

    test('index.html 的状态栏与标题也跟着默认主题', () {
      final s = File('web/index.html').readAsStringSync();
      expect(s, contains('<title>灶记 ZAOJI</title>'));
      expect(s, contains('apple-mobile-web-app-status-bar-style" content="default"'),
          reason: '浅色主题配 black-translucent 会让状态栏压成深色一块');
      expect(s, contains('name="theme-color"'));
    });
  });

  test('源图在仓库里（生成脚本要吃它）', () {
    expect(File('assets/icon/source.png').existsSync(), isTrue,
        reason: '图标是生成物；源图不在就等于这套产物不可复现');
  });
}
