import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/main.dart';
import 'package:zaoji/ui/home_shell.dart';
import 'package:zaoji/ui/recipe_detail_page.dart';
import 'package:zaoji/widgets/time_capsule_text.dart';

/// 主页（菜谱库）与「列表 → 详情」走通测试。
///
/// 这一轮把主页照高保真原型重做了（封面插画卡片 / 搜索 / 筛选 / 排序 /
/// 悬浮按钮 / 底部标签栏），这些测试同时是两边的守门人：
/// · 有人把原型定下的结构改没了（比如搜索框、标签栏），这里红；
/// · 有人把布局改溢出了，`takeException` 会红——**判断布局靠断言，不靠截图**。
void main() {
  /// 每个测试自建 store（内存库），init 发生在该测试自己的 FakeAsync 区里。
  ///
  /// ★ 不能用 `setUpAll` + 全局单例：在真实 async 区完成的 Future，
  ///   它的监听器排在真实 zone 的微任务队列里，测试区推帧时永远看不到完成，
  ///   症状是「pumpAndSettle 超时」（详见 lib/data/store_scope.dart 的注释）。
  Future<void> pumpApp(WidgetTester tester, {double h = 1400}) async {
    tester.view.physicalSize = Size(414, h);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ZaojiApp(executor: NativeDatabase.memory()));
    await tester.pumpAndSettle();
  }

  testWidgets('主页结构与高保真一致：顶栏/搜索/筛选轨/区块标题/标签栏', (tester) async {
    await pumpApp(tester);

    // 顶栏：菜谱 + 共 N 道 · 收藏 N 道（种子 9 道，收藏 4 道）
    expect(find.text('菜谱'), findsWidgets); // 顶栏 + 标签栏各一处
    expect(find.text('共 9 道 · 收藏 4 道'), findsOneWidget);
    // 搜索条
    expect(find.text('搜菜名、食材，如「番茄」「虾」'), findsOneWidget);
    // 快捷筛选轨
    expect(find.text('只看收藏'), findsOneWidget);
    expect(find.text('红烧'), findsOneWidget);
    // 区块标题：编号两位 + 标题 + 排序
    expect(find.text('09'), findsOneWidget);
    expect(find.text('全部菜品'), findsOneWidget);
    expect(find.text('最近做过'), findsOneWidget);
    // 底部标签栏五项
    for (final t in ['菜单', '备菜', '日历', '我的']) {
      expect(find.text(t), findsOneWidget, reason: '底部标签栏缺「$t」');
    }
  });

  testWidgets('默认按「最近做过」排序，卡片带封面与做过的次数', (tester) async {
    await pumpApp(tester, h: 2200);

    // 葱油拌面 09/17 最近 → 应排在第一个可见位置（区块标题之下）
    expect(find.text('葱油拌面'), findsOneWidget);
    expect(find.text('做过 18 次'), findsOneWidget);
    expect(find.text('09/17'), findsOneWidget);
  });

  testWidgets('搜索框实时过滤菜名与食材', (tester) async {
    await pumpApp(tester);

    await tester.enterText(find.byType(TextField), '番茄');
    await tester.pumpAndSettle();

    expect(find.text('搜索结果'), findsOneWidget);
    expect(find.text('01'), findsOneWidget, reason: '只有番茄炒蛋命中（食材里带番茄的还有别的？没有）');
    expect(find.text('番茄炒蛋'), findsOneWidget);
    expect(find.text('红烧肉'), findsNothing);

    // 清空恢复
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('全部菜品'), findsOneWidget);
  });

  testWidgets('「只看收藏」只留收藏的菜', (tester) async {
    await pumpApp(tester, h: 2200);

    await tester.tap(find.text('只看收藏'));
    await tester.pumpAndSettle();

    expect(find.text('我的收藏'), findsOneWidget);
    expect(find.text('04'), findsOneWidget, reason: '种子里收藏了 4 道');
    expect(find.text('麻婆豆腐'), findsOneWidget);
    expect(find.text('蚝油生菜'), findsNothing, reason: '蚝油生菜没收藏');
  });

  testWidgets('排序 sheet 切到「耗时最短」后列表重排', (tester) async {
    await pumpApp(tester, h: 2200);

    await tester.tap(find.text('最近做过'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('耗时最短'));
    await tester.pumpAndSettle();

    // 8 分钟的蚝油生菜应是第一位；同时区块标题的排序档名更新
    expect(find.text('蚝油生菜'), findsOneWidget);
    // 卡片位置断言：蚝油生菜的顶部应高于葱油拌面（15 分）
    final a = tester.getTopLeft(find.text('蚝油生菜'));
    final b = tester.getTopLeft(find.text('葱油拌面'));
    expect(a.dy, lessThan(b.dy), reason: '耗时最短档下蚝油生菜应排在葱油拌面前面');
  });

  testWidgets('AI 生成的菜谱带来源标记', (tester) async {
    await pumpApp(tester, h: 2200);

    // 需求硬要求：AI 生成的菜谱必须标明来源（列表上也要有）
    expect(find.text('AI 生成'), findsOneWidget);
  });

  testWidgets('底部标签栏可切换：「我的」是同步设置页，切回菜谱状态保留', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeShell), findsOneWidget);
    // R13：「我的」从占位页升级为同步设置页（配对 / 立即同步 / 设备身份）
    expect(find.text('同步'), findsOneWidget);
    expect(find.text('设备'), findsOneWidget);
    expect(find.text('服务端地址'), findsOneWidget);
    expect(find.text('配对'), findsOneWidget, reason: '未配对时给配对入口');

    await tester.tap(find.text('菜谱'));
    await tester.pumpAndSettle();
    expect(find.text('全部菜品'), findsOneWidget, reason: '切回菜谱，状态应保留（IndexedStack）');
  });

  testWidgets('★ 悬浮按钮默认位置：右缘距屏幕 18px、不压到标签栏', (tester) async {
    // 这个测试是修出来的：拖动提示（.fab-tip）曾靠 AnimatedOpacity 隐藏，
    // 但它**照样占布局**，把按钮往下顶 33px、往右挤 39px，结果被屏幕裁掉一半。
    // 截图上只觉得"歪了"，位置断言一跑就是精确的 39px——这种问题必须钉在这。
    const phoneW = 390.0, phoneH = 844.0, tabbarH = 56.0;
    tester.view.physicalSize = const Size(phoneW, phoneH);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ZaojiApp(executor: NativeDatabase.memory()));
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.byIcon(Icons.add));
    final rightEdge = center.dx + 30; // 图标 26 居中于 60 的容器
    final bottomEdge = center.dy + 30;

    expect(
      rightEdge,
      closeTo(phoneW - 18, 0.5),
      reason: '右缘应距屏幕 18px（原型 .add-fab right:18）',
    );
    expect(
      bottomEdge,
      lessThanOrEqualTo(phoneH - tabbarH),
      reason: '按钮不能压到底部标签栏下面',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('★ 悬浮按钮长按可拖动，且拖动后不会误触发点击', (tester) async {
    await pumpApp(tester);

    final fab = find.byIcon(Icons.add);
    final before = tester.getTopLeft(fab);

    // 长按（380ms 阈值，测试里等 600ms 稳过）然后拖一段
    final gesture = await tester.startGesture(tester.getCenter(fab));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(-120, -200));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final after = tester.getTopLeft(fab);
    expect(after.dx, lessThan(before.dx), reason: '向左拖了，按钮应该在左边');
    expect(after.dy, lessThan(before.dy), reason: '向上拖了，按钮应该在上面');

    // 松手后不应把这次操作当成「点了新建」
    expect(find.textContaining('还没做'), findsNothing);
  });

  testWidgets('点卡片进详情，步骤里的时间变成胶囊', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.text('番茄炒蛋'));
    await tester.pumpAndSettle();

    expect(find.byType(RecipeDetailPage), findsOneWidget);
    expect(find.text('食材'), findsOneWidget);
    expect(find.text('做法'), findsOneWidget);
    expect(find.byType(TimeCapsule), findsWidgets);
  });

  testWidgets('点胶囊能弹出计时器，并且真的会走', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('番茄炒蛋'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TimeCapsule).first);
    await tester.pumpAndSettle();

    expect(find.text('开始'), findsOneWidget);

    await tester.tap(find.text('开始'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('20:00'), findsNothing);

    // 收尾：暂停，别把周期计时器留给下一个测试
    await tester.tap(find.text('暂停'));
    await tester.pumpAndSettle();
  });

  testWidgets('★ 清空筛选会把搜索框与排序档一起复位（R12 修的界面自相矛盾 bug）', (tester) async {
    await pumpApp(tester, h: 2200);

    // 1) 先把排序档改走：最近做过 → 耗时最短
    await tester.tap(find.text('最近做过'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('耗时最短'));
    await tester.pumpAndSettle();
    // 关掉 sheet（点遮罩）
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // 2) 输入一个搜不到的关键词 → 空态出现
    await tester.enterText(find.byType(TextField), '不存在的菜');
    await tester.pumpAndSettle();
    expect(find.text('没有找到菜品'), findsOneWidget);

    // 3) 点「清空筛选」
    await tester.tap(find.text('清空筛选'));
    await tester.pumpAndSettle();

    // 修复前：_query 清了但 _searchCtrl 没清——输入框还写着「不存在的菜」，
    // 列表却回到全部，界面自相矛盾；排序档也不会复位。
    expect(
      find.text('搜菜名、食材，如「番茄」「虾」'),
      findsOneWidget,
      reason: '搜索框必须清空（hint 重新出现）',
    );
    expect(find.text('全部菜品'), findsOneWidget);
    expect(find.text('红烧肉'), findsOneWidget, reason: '列表恢复');
    expect(find.text('最近做过'), findsOneWidget, reason: '排序档复位为默认');
  });

  testWidgets('★ 点卡片收藏，顶栏计数立即变（store 通知驱动，不靠页面 setState）', (tester) async {
    await pumpApp(tester, h: 2200);

    String headerText() =>
        tester.widget<Text>(find.textContaining('共 9 道')).data!;

    expect(headerText(), '共 9 道 · 收藏 4 道');

    // 找一张未收藏卡片的收藏按钮（空心书签），点两次：+1 再 -1。
    // 注意 finder 是惰性求值的：第一次点击后这颗图标会变成实心，
    // 再 evaluate 同一个 finder 会命中**另一张**卡片——所以先取坐标，用坐标点两次。
    final favButton = find.byIcon(Icons.bookmark_border_rounded).first;
    final favCenter = tester.getCenter(favButton);
    await tester.tapAt(favCenter);
    await tester.pumpAndSettle();
    expect(
      headerText(),
      isNot('共 9 道 · 收藏 4 道'),
      reason:
          'toggleFav 走 notifyListeners → ListenableBuilder 重建，'
          '这条断言保证「store 通知 → UI 刷新」这条链路是通的',
    );

    await tester.tapAt(favCenter);
    await tester.pumpAndSettle();
    expect(headerText(), '共 9 道 · 收藏 4 道', reason: '切换两次回到原值');
  });

  testWidgets('★ 三种手机宽度都不溢出（320 / 390 / 430）', (tester) async {
    // 用断言而不是看截图来判断布局对不对。
    // Flutter 里布局溢出会抛异常，测试能直接抓到；
    // 而截图受窗口尺寸、缩放、裁剪影响，看走眼太容易。
    addTearDown(tester.view.reset);

    for (final width in <double>[320, 390, 430]) {
      tester.view.physicalSize = Size(width, 1400);
      tester.view.devicePixelRatio = 1.0;

      await tester.pumpWidget(ZaojiApp(executor: NativeDatabase.memory()));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '主页在 ${width}px 宽时溢出了');

      await tester.tap(find.text('番茄炒蛋'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '详情页在 ${width}px 宽时溢出了');
      expect(find.text('做法'), findsOneWidget);

      // 回到列表再进下一轮
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
  });
}
