import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/main.dart';
import 'package:zaoji/ui/cooking_page.dart';

import 'fss_stub.dart';

/// 做菜模式（R20）走通测试。
///
/// 全部从 App 根注入内存库、走真实导航（列表 → 详情 → 开火），
/// 因为这一屏的价值恰恰在「链」：进度落库 → 退出 → 重进能续上。
Future<void> pumpApp(WidgetTester tester, {double w = 414}) async {
  tester.view.physicalSize = Size(w, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ZaojiApp(executor: NativeDatabase.memory()));
  await tester.pumpAndSettle();
}

/// 从主页打开第一道菜（葱油拌面）的详情，点 AppBar 的「开始做菜」。
Future<void> openCooking(WidgetTester tester) async {
  await tester.tap(find.text('葱油拌面').first);
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.local_fire_department_outlined));
  await tester.pumpAndSettle();
}

void main() {
  // 测试环境没有 Keystore 插件的 handler，不挂 mock 通道会挂起（见 fss_stub.dart）。
  setUpAll(stubSecureStorageForTest);

  testWidgets('★ 开火：一步一屏 + 步骤指示 + 大字号（FR-COOK-06）', (tester) async {
    await pumpApp(tester);
    await openCooking(tester);
    expect(find.byType(CookingPage), findsOneWidget);
    expect(find.textContaining('第 1 步'), findsOneWidget);

    // 字号 ≥20px 是「1 米外可读」的硬指标——用断言，不靠肉眼。
    // 步骤正文渲染成 RichText（时间胶囊是 WidgetSpan，只能是富文本），
    // 页面里其它文字的 style 都在 17px 以下，所以按字号筛即可。
    final big = tester.widgetList<RichText>(find.byType(RichText)).where(
      (r) =>
          ((r.text as TextSpan).style?.fontSize ?? 0) >= 20 &&
          r.text.toPlainText().contains('葱'),
    );
    expect(big, isNotEmpty, reason: '步骤正文必须 ≥20px（FR-COOK-06 竖屏）');

    await tester.pump(const Duration(seconds: 4)); // 泵掉防抖 Timer
  });

  testWidgets('★ 翻页 + 退出 + 原位续做（FR-COOK-08）', (tester) async {
    await pumpApp(tester);
    await openCooking(tester);

    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.textContaining('第 2 步'), findsOneWidget);

    // 做菜页刻意不显示返回箭头（automaticallyImplyLeading: false），
    // 离开走 AppBar 的「先离开」——pageBack() 找不到返回键会直接报错。
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    // 详情页出现「继续做菜」横幅，且标明停在哪一步
    expect(find.textContaining('继续做菜'), findsOneWidget);
    expect(find.textContaining('第 2 步'), findsOneWidget);

    await tester.tap(find.textContaining('继续做菜'));
    await tester.pumpAndSettle();
    expect(find.byType(CookingPage), findsOneWidget);
    expect(find.textContaining('第 2 步'), findsOneWidget,
        reason: '续做必须回到离开时的步骤，而不是从 1 开始');

    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('★ 完成：长按 300ms 才记账；短点只提示（FR-COOK-07/15）', (tester) async {
    await pumpApp(tester);
    await openCooking(tester);

    // 翻到最后一步
    for (var i = 0; i < 20; i++) {
      if (tester.any(find.text('完成这道菜'))) break;
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
    }
    expect(find.text('完成这道菜'), findsOneWidget);

    // 短点 = 不完成（湿手误触的防线）
    await tester.tap(find.text('完成这道菜'));
    await tester.pumpAndSettle();
    expect(find.byType(CookingPage), findsOneWidget,
        reason: '短点就完成等于没有防误触');

    // SnackBar 悬在底部按钮上方，不泵掉它的 1 秒时长的话，
    // 后面的 longPress 会被 SnackBar 的遮挡层吃掉。
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('完成这道菜'));
    await tester.pumpAndSettle();
    expect(find.byType(CookingPage), findsNothing);

    // 回到详情：做过次数 +1（种子数据葱油拌面做过 18 次）
    expect(find.text('19 次'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('食材速查：展开可勾选（FR-COOK-11）', (tester) async {
    await pumpApp(tester);
    await openCooking(tester);

    // 标题是「食材速查（已备 0/5）」且勾选后会变数字，只能 textContaining
    await tester.tap(find.textContaining('食材速查'));
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsWidgets);

    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    // 勾选状态保留：折叠再展开仍是勾上
    await tester.tap(find.textContaining('食材速查'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('食材速查'));
    await tester.pumpAndSettle();
    final first = tester.widget<Checkbox>(find.byType(Checkbox).first);
    expect(first.value, isTrue);

    await tester.pump(const Duration(seconds: 4));
  });

  // 一个 testWidgets 里循环换三种宽度会互相踩：上一轮的 surface/视图尺寸
  // 复位在下一轮 pumpApp 之前不生效，导航栈也难保证干净。一种宽度一个用例。
  for (final w in [320.0, 390.0, 430.0]) {
    testWidgets('${w.toInt()}px 窄屏不溢出', (tester) async {
      await pumpApp(tester, w: w);
      await openCooking(tester);
      expect(tester.takeException(), isNull, reason: '${w}px 宽度溢出');
      await tester.pump(const Duration(seconds: 4));
    });
  }
}
