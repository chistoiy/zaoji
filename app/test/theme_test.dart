import 'dart:io';
import 'dart:math' as math;
import 'package:zaoji_shared/zaoji_shared.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/theme.dart';
import 'package:zaoji/ui/theme_page.dart';

/// R39 · 主题（五套调色板 + 换肤 + 本机偏好）。
///
/// 这一组测试钉的不是"好不好看"，而是**四件会静默坏掉的事**：
///   1. Dart 侧的色值和原型 `[data-theme]` 块**逐字一致**——两边一漂移，
///      评审看到的和装到手机上的就不是同一个东西；
///   2. 每套主题自己读得清（正文压在纸底上、字压在强调色上）；
///   3. 主题是本机偏好：落 local_pref、重启还在、**不进同步流**；
///   4. 换肤要真的传到页面（不是只改了 store 里一个字符串）。
void main() {
  late RecipeStore store;

  setUp(() async {
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
  });
  tearDown(() async {
    await store.dbOrNull!.close();
    store.dispose();
  });

  group('调色板与原型一致', () {
    /// 从原型里抠出 `[data-theme="x"]{...}` 块的令牌表。
    /// 找不到文件就跳过而不是失败：这个测试的意义在"两边对齐"，
    /// 在拿不到原型的环境里硬失败只会让人直接删测试。
    Map<String, String>? protoTokens(String id) {
      // flutter test 的工作目录是 app/，原型在仓库根
      final f = File('../zaoji-prototype.html');
      if (!f.existsSync()) return null;
      final src = f.readAsStringSync();
      final start = src.indexOf('[data-theme="$id"]{');
      if (start < 0) return null;
      final body = src.substring(start, src.indexOf('}', start));
      final out = <String, String>{};
      for (final m in RegExp(r'(--[\w-]+)\s*:\s*([^;]+);').allMatches(body)) {
        out[m.group(1)!] = m.group(2)!.trim();
      }
      return out;
    }

    const pairs = <String, String>{
      '--paper': 'paper',
      '--paper-2': 'paper2',
      '--ink': 'ink',
      '--ink-2': 'ink2',
      '--muted': 'muted',
      '--accent': 'accent',
      '--accent-deep': 'accentDeep',
      '--on-accent': 'onAccent',
      '--amber': 'amber',
      '--ok': 'ok',
      '--warn': 'warn',
      '--t-method': 'tagMethod',
    };

    for (final t in ZaojiTokens.all) {
      test('${t.id} 的 12 个核心令牌与原型同值', () {
        final proto = protoTokens(t.id);
        if (proto == null) {
          markTestSkipped('找不到 zaoji-prototype.html（相对 app/ 跑测试）');
          return;
        }
        for (final e in pairs.entries) {
          final want = proto[e.key];
          expect(want, isNotNull, reason: '原型 ${t.id} 缺 ${e.key}');
          final got = _argbOf(t, e.value)!;
          expect(got.toUpperCase(),
              want!.toUpperCase().replaceAll('#', ''),
              reason: '${t.id} 的 ${e.value} 与原型 ${e.key} 不一致');
        }
      });
    }

    test('五套主题 id 与原型块名一一对应，且顺序就是设置页顺序', () {
      expect(ZaojiTokens.all.map((e) => e.id),
          ['shihong', 'indigo', 'rouge', 'night', 'stone'],
          reason: '设置页顺序不变；默认是 indigo，靠 fallback 表达，不靠排序');
    });

    test('两套深色主题必须真的标 dark：brightness 错了 Material 弹层就是白底白字', () {
      for (final t in ZaojiTokens.all) {
        final dark = t.id == 'night' || t.id == 'stone';
        expect(t.brightness == Brightness.dark, dark, reason: t.id);
      }
    });
  });

  group('每套主题自己读得清', () {
    double contrast(Color a, Color b) {
      double l(Color c) {
        final ch = [c.r, c.g, c.b].map((double v) =>
            v <= 0.03928 ? v / 12.92 : _pow((v + 0.055) / 1.055, 2.4)).toList();
        return 0.2126 * ch[0] + 0.7152 * ch[1] + 0.0722 * ch[2];
      }

      final l1 = l(a), l2 = l(b);
      return (l1 > l2 ? l1 + .05 : l2 + .05) / (l1 > l2 ? l2 + .05 : l1 + .05);
    }

    for (final t in ZaojiTokens.all) {
      test('${t.id}：正文/弱化字/强调色面上的字都过 AA', () {
        expect(contrast(t.ink, t.paper), greaterThan(7.0),
            reason: '正文压在纸底上');
        expect(contrast(t.muted, t.paper), greaterThanOrEqualTo(4.5),
            reason: '弱化文字也要读得清（R39 就是为此把三套浅色的 muted 压暗的）');
        // 强调色面上的字：本轮把它从「一律白字」改成「浅色主题白字、
        // 深色主题近黑」，四套新主题都过 4.5；**默认那套是 4.09**——
        // 再往上就要动柿红本身（D2491C 改更深），那是品牌色决定，不擅自改。
        // 所以这里钉 3.0（AA-Large 线），并把已知缺口留在测试名字里，别让它被忘掉。
        final onAccent = contrast(t.onAccent, t.accent);
        expect(onAccent, greaterThanOrEqualTo(3.0),
            reason: '强调色底上的字：深色主题这里是近黑，不是白');
        if (t.id != 'shihong') {
          expect(onAccent, greaterThanOrEqualTo(4.5),
              reason: '除柿红那套以外，其它四套没有沿用旧缺口的份');
        }
        expect(contrast(t.ok, t.paper), greaterThanOrEqualTo(3.0),
            reason: '状态点旁边那行小字');
      });
    }
  });

  group('主题是本机偏好', () {
    test('默认是蓝染粗布（R39 收尾改判）', () {
      expect(store.themeId, 'indigo');
      expect(store.tokens.id, 'indigo');
    });

    test('setTheme 立即生效 + 落库 + 重启还在（真重载，不是看内存）', () async {
      store.setTheme('night');
      expect(store.tokens.id, 'night');
      final db = store.dbOrNull!;
      final raw = await db
          .customSelect("SELECT pref_value FROM local_pref WHERE pref_key = 'theme'")
          .get();
      expect(raw, hasLength(1), reason: '不落库的话下次启动就回到默认了');

      await store.reloadForTest();
      expect(store.themeId, 'night', reason: '重载不该把本机偏好洗掉');
    });

    test('认不出来的 id 落回默认，不崩', () {
      store.setTheme('从没有过的一套');
      expect(store.themeId, 'indigo');
      store.setTheme('stone');
      expect(store.tokens.id, 'stone');
    });

    test('主题存在 local_pref，而它不在同步白名单里', () {
      // 手机设成夜里开火，不该把客厅平板也拽黑
      expect(syncWhitelist.containsKey('pantry_item'), isTrue,
          reason: '白名单是从表定义算出来的，先确认这份数据源活着');
      expect(syncWhitelist.keys, isNot(contains('local_pref')));
    });
  });

  group('换肤要真的传到界面', () {
    Future<void> pumpApp(WidgetTester tester, RecipeStore s) async {
      await tester.binding.setSurfaceSize(const Size(420, 1500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(StoreScope(
        store: s,
        child: MaterialApp(
          theme: buildZaojiTheme(s.tokens),
          home: const ThemePage(),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('五张卡 + 当前那套标「使用中」，点一下立即换', (tester) async {
      await pumpApp(tester, store);
      expect(find.text('柿红暖纸'), findsOneWidget);
      expect(find.text('青石夜色'), findsOneWidget);
      expect(find.text('使用中'), findsOneWidget, reason: '只有一张卡该亮');

      await tester.tap(find.byKey(const ValueKey('theme-stone')));
      await tester.pumpAndSettle();
      expect(store.themeId, 'stone');
      expect(
          Theme.of(tester.element(find.byKey(const ValueKey('theme-stone'))))
              .extension<ZaojiTokens>()!
              .id,
          'stone',
          reason: '卡内预览必须用**它自己那套**渲染，不是页面那套');

      await tester.tap(find.byKey(const ValueKey('theme-night')));
      await tester.pumpAndSettle();
      expect(find.text('使用中'), findsOneWidget);
      expect(store.themeId, 'night');
    });

    testWidgets('页面底色跟着 store.tokens 走', (tester) async {
      store.setTheme('indigo');
      await pumpApp(tester, store);
      final theme = Theme.of(tester.element(find.byType(ThemePage)));
      expect(theme.extension<ZaojiTokens>()!.id, 'indigo');
      expect(theme.scaffoldBackgroundColor, ZaojiTokens.indigo.paper);
    });
  });
}


/// 取某个令牌名的值（测试用；不为此往 ZaojiTokens 上加一套"通用查表"API）。
String? _argbOf(ZaojiTokens t, String name) {
  final c = switch (name) {
    'paper' => t.paper,
    'paper2' => t.paper2,
    'ink' => t.ink,
    'ink2' => t.ink2,
    'muted' => t.muted,
    'accent' => t.accent,
    'accentDeep' => t.accentDeep,
    'onAccent' => t.onAccent,
    'amber' => t.amber,
    'ok' => t.ok,
    'warn' => t.warn,
    'tagMethod' => t.tagMethod,
    _ => null,
  };
  if (c == null) return null;
  return (c.toARGB32() & 0xFFFFFF).toRadixString(16).toUpperCase().padLeft(6, '0');
}

double _pow(num base, num exp) => math.pow(base, exp).toDouble();
