import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/widgets/time_capsule_text.dart';

/// 时间胶囊的渲染测试。
///
/// 这一组测试存在的理由：`shared` 里的 `parseStepTimes` 只返回**区间**，
/// 真正把它变成高亮的是 Flutter 这边的 `TextSpan`。
/// 而这中间有一个两端都可能踩的坑——**全角与规范化**：
/// 解析器内部会把全角数字规范化后再扫描，如果返回的偏移不是映射回原文的，
/// 高亮就会**切错字**（把「分钟」圈进去、或者把数字切掉一半）。
///
/// shared 那边已经有测试盯着偏移，这里再钉一遍**渲染层**：
/// 把 spans 拼回去，必须和原文一字不差。
void main() {
  /// 把 spans 拼回纯文本。`WidgetSpan` 里的胶囊取它显示的原文。
  String joinSpans(List<InlineSpan> spans) {
    final buf = StringBuffer();
    for (final s in spans) {
      if (s is TextSpan) {
        buf.write(s.text ?? '');
      } else if (s is WidgetSpan) {
        final child = s.child;
        if (child is TimeCapsule) buf.write(child.text);
      }
    }
    return buf.toString();
  }

  group('区间映射（原文一个字都不能改写）', () {
    const samples = <String>[
      '转小火炖 20 分钟，加盐调味。',
      '盖上盖子焖 1 个半小时。',
      '大火蒸 6-8 分钟，虾身变红就打住。',
      '加 ２０ 克糖，中火炒 3 分钟。',
      '热锅冷油下蒜片爆香 10 秒。',
      '粉丝用温水泡 10 分钟，泡到能绕在手指上不断就行。',
    ];

    for (final src in samples) {
      test('拼回去和原文一致：$src', () {
        final spans = buildTimeCapsuleSpans(src, onTap: (_) {});
        expect(joinSpans(spans), src);
      });
    }

    test('没有时间关键词时，整句原样返回单个 span', () {
      const src = '番茄顶部划十字，剥皮后切成滚刀块。';
      final spans = buildTimeCapsuleSpans(src, onTap: (_) {});
      expect(spans, hasLength(1));
      expect(joinSpans(spans), src);
    });

    test('胶囊数量与解析出的命中数量一致', () {
      const src = '先炖 20 分钟，再焖 1 个半小时，最后收汁 10 分钟。';
      final spans = buildTimeCapsuleSpans(src, onTap: (_) {});
      final capsules = spans.whereType<WidgetSpan>().toList();
      expect(capsules, hasLength(3));
    });

    test('胶囊上显示的是原文片段（不是换算后的样子）', () {
      // 「半个 小时」这种写法特别容易暴露问题：胶囊必须显示用户写的那个样子
      const src = '再炖半个小时。';
      final spans = buildTimeCapsuleSpans(src, onTap: (_) {});
      final capsule = spans.whereType<WidgetSpan>().single.child as TimeCapsule;
      expect(src.substring(capsule.hit.start, capsule.hit.end), capsule.text);
      expect(joinSpans(spans), src);
    });
  });

  group('交互', () {
    testWidgets('点胶囊会回调，并带上正确的时长', (tester) async {
      const src = '小火炖 20 分钟。';
      final tapped = <int>[];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 14),
              children: buildTimeCapsuleSpans(
                src,
                onTap: (hit) => tapped.add(hit.suggestedSeconds),
              ),
            ),
          ),
        ),
      ));

      expect(find.byType(TimeCapsule), findsOneWidget);
      await tester.tap(find.byType(TimeCapsule));
      await tester.pump();

      expect(tapped, [1200], reason: '20 分钟应当是 1200 秒');
    });

    testWidgets('胶囊带无障碍语义（读屏用户看不到颜色）', (tester) async {
      const src = '炖 20 分钟。';
      // 查语义树要先把它打开。
      // 注意必须在测试体里显式 dispose —— 框架检查语义句柄是否释放的时机
      // 在 tearDown 之前，用 addTearDown 会报「SemanticsHandle was active」。
      final semantics = tester.ensureSemantics();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RichText(
            text: TextSpan(
              children: buildTimeCapsuleSpans(src, onTap: (_) {}),
            ),
          ),
        ),
      ));

      // 颜色与位置对读屏用户没有意义，必须有一条说明「这里能点、点了会怎样」。
      // 用 bySemanticsLabel 而不是 matchesSemantics：RichText 会把整段文字
      // 合并成一个语义节点，逐节点比对形状会假失败。
      expect(
        find.bySemanticsLabel(RegExp('时间 20 分钟，点击开始计时')),
        findsWidgets,
      );

      semantics.dispose();
    });
  });
}
