import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/main.dart';
import 'package:zaoji/ui/recipe_edit_page.dart';

/// R14 编辑页的走通测试（smoke）：「UI 表单 → store 写路径 → 列表」这条链，
/// 以及 PopScope 拦截的两面（未保存要拦 / 保存后必须放行）。
///
/// 复用 [ZaojiApp] 注入内存库——不直接 pump RecipeEditPage，是因为
/// 保存走 StoreScope + 弹回列表，整条链只有从根注入才真实。
void main() {
  Future<void> pumpApp(WidgetTester tester, {double h = 2200}) async {
    tester.view.physicalSize = Size(414, h);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ZaojiApp(executor: NativeDatabase.memory()));
    await tester.pumpAndSettle();
  }

  /// 用 hint 文案定位输入框（编辑页字段多，label 结构不统一，hint 最稳）。
  /// ★ 两个坑：hint 渲染成 InputDecorator 里的真实 Text（widgetWithText 才找得到）；
  ///   定位必须落在内层 TextField 上——enterText 要求 state 是 EditableTextState，
  ///   TextFormField 的 state（FormFieldState）不是，直接用会「Bad state: No element」。
  Finder fieldByHint(String hint) => find.widgetWithText(TextField, hint);

  testWidgets('★ 新建一道菜：填表 → 保存 → 列表出现，且不弹「放弃编辑」', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.byType(RecipeEditPage), findsOneWidget);
    expect(find.text('新建菜品'), findsOneWidget);

    // ★ 字段按位置定位（实测的 TextField 顺序）：
    //   0=菜名 1=描述 2=分量 3=耗时 4=食材1名 5=食材1量 6=食材2名 7=食材2量 8=步骤1 9=步骤2 10=备注
    // 为什么不用 hint 文案找第二个之后的字段：**enterText 过一次之后，
    // 「hint Text → TextField」的祖先链 finder 就断了**——find.text 还能
    // 找到 hint（=2），ancestor 匹配却为空（Bad state: No element，R15 实测）。
    // 索引最稳，代价是结构变了要跟着改。
    Future<void> fill(int index, String text) =>
        tester.enterText(find.byType(TextField).at(index), text);

    await fill(0, 'E2E 测试菜');
    await fill(4, '鸡蛋');
    await fill(8, '小火煎 3 分钟');

    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    // 保存成功 = 弹回列表；★ R14 hotfix 的回归点：PopScope 不能反手
    // 把「保存后的 pop」当成「用户要放弃」再弹一次确认框。
    expect(find.byType(RecipeEditPage), findsNothing);
    expect(find.text('放弃编辑？'), findsNothing);
    expect(find.textContaining('共 10 道'), findsOneWidget);

    // 新菜按「最近做过」排在末尾，不在首屏——用搜索验证它真的进了库。
    // 搜中后「E2E 测试菜」出现两处：搜索框里的值 + 菜卡标题。
    await tester.enterText(find.byType(TextField).first, 'E2E 测试菜');
    await tester.pumpAndSettle();
    expect(find.text('E2E 测试菜'), findsExactly(2));

    // 把 3 秒防抖 Timer 泵掉（未配对时它是一次安静 no-op），
    // 否则测试收尾时 FakeAsync 报「仍有 pending Timer」。
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('★ 填了内容点返回：先拦下来问「放弃编辑？」，放弃后不落库', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(fieldByHint('例：番茄炒蛋'), '不该出现的菜');
    await tester.pump();

    // AppBar 返回键 → PopScope 拦截 → 确认框
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('放弃编辑？'), findsOneWidget);

    await tester.tap(find.text('放弃'));
    await tester.pumpAndSettle();

    expect(find.byType(RecipeEditPage), findsNothing);
    expect(
      find.textContaining('共 9 道'),
      findsOneWidget,
      reason: '放弃 = 没有写入，数量不变',
    );
  });
}
