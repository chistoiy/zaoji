import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/timer_board.dart';
import 'package:zaoji/data/timer_scope.dart';
import 'package:zaoji/main.dart';
import 'package:zaoji/ui/timer_full_page.dart';
import 'package:zaoji/widgets/time_capsule_text.dart';

import 'fss_stub.dart';

/// R47 第八段 · 悬浮球的两态、占场互斥与「全屏含通知栏」。
///
/// 五件事都是**决策**，不是算术，所以各有用例钉着：
/// ① 靠边松手才吸边并收成耳朵（停在中间不该自动收起来——用户会找不到球）；
/// ② 展开后仍贴同一条边（贴哪一边是事实源，不随形态变）；
/// ③ 全屏计时页开着时球必须消失（原型从第一版就是「全屏 / 悬浮窗」二选一，
///    实现却把 `OverlayEntry` 一直挂着）；且退出全屏后**形态要记住**，
///    不能因为中途隐藏过一次就弹回默认右下角、耳朵也自己展开；
/// ④ 计时面板开着时球同样要让位——面板就是球的展开态，
///    球继续浮在上面会把面板里的「全屏/关闭」按钮吃掉（这条就是被吃掉时撞出来的）；
/// ⑤ 全屏页**含通知栏**：深色底从 y=0 铺起、状态栏图标转浅色（需求原话：
///    「全屏要包含通知栏的，当前没有」）。
void main() {
  setUpAll(stubSecureStorageForTest);

  const ball = ValueKey('timer-ball');
  const ear = ValueKey('timer-ear');

  /// 起一台机器。`bars` 用来造"有状态栏/导航栏"的场景。
  /// ★ [FakeViewPadding] 按**物理像素**计，这里 dpr=1.0，所以 44 就是 44 逻辑像素。
  Future<void> pumpApp(WidgetTester tester,
      {double h = 2200, FakeViewPadding bars = const FakeViewPadding()}) async {
    // store / 视图尺寸都在用例自己的 FakeAsync 区里造（setUp 里跑的是真 async 区，
    // 从那边递进来会把界面的 settle 卡死——§7.10 记过）
    tester.view.physicalSize = Size(414, h);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = bars;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ZaojiApp(executor: NativeDatabase.memory()));
    await tester.pumpAndSettle();
  }

  TimerBoard boardOf(WidgetTester tester) =>
      tester.widget<TimerScope>(find.byType(TimerScope).first).board;

  /// 进菜谱详情 → 点第一个时间胶囊起表。
  /// ★ 胶囊在**详情页**（步骤里的琥珀色时间），列表页没有——先导航再点，
  ///   否则 `find.byType(TimeCapsule).first` 直接抛 Bad state: No element。
  Future<void> startTimer(WidgetTester tester, {int which = 0}) async {
    await tester.tap(find.text('番茄炒蛋'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TimeCapsule).at(which));
    await tester.pumpAndSettle();
  }

  Future<void> dragBall(WidgetTester tester, double dx) async {
    await tester.drag(find.byKey(ball), Offset(dx, 0));
    await tester.pumpAndSettle();
  }

  /// 球 → 面板 → 这一张表的全屏入口。两个组都要用，放在外面。
  Future<void> openFull(WidgetTester tester) async {
    await tester.tap(find.byKey(ball)); // 点开面板
    await tester.pumpAndSettle();
    final id = boardOf(tester).timers.last.id;
    await tester.tap(find.byKey(ValueKey('timer-full-$id')));
    await tester.pumpAndSettle();
  }

  group('吸边与耳朵', () {
    testWidgets('起表：完整球在位，耳朵不在', (tester) async {
      await pumpApp(tester);
      await startTimer(tester);
      expect(find.byKey(ball), findsOneWidget);
      expect(find.byKey(ear), findsNothing, reason: '默认不收起（用户没靠过边）');
    });

    testWidgets('★ 拖到右边缘松手：收成耳朵，完整球消失', (tester) async {
      await pumpApp(tester);
      await startTimer(tester);
      await dragBall(tester, 600);
      expect(find.byKey(ear), findsOneWidget);
      expect(find.byKey(ball), findsNothing);
      // 贴边是几何事实：耳朵的右缘就该在屏幕右缘上
      expect(tester.getRect(find.byKey(ear)).right, closeTo(414, 1));
    });

    testWidgets('★ 点耳朵：展开回完整球，且仍贴同一条边（不弹回默认角）', (tester) async {
      await pumpApp(tester);
      await startTimer(tester);
      await dragBall(tester, 600);
      await tester.tap(find.byKey(ear));
      await tester.pumpAndSettle();
      expect(find.byKey(ball), findsOneWidget);
      expect(find.byKey(ear), findsNothing);
      expect(tester.getRect(find.byKey(ball)).right, closeTo(414, 1),
          reason: '展开后球比耳朵宽，横向要按球宽重贴——右缘仍该贴着屏幕右边');
    });

    testWidgets('拖到左边缘：耳朵贴左（左缘在 0）', (tester) async {
      await pumpApp(tester);
      await startTimer(tester);
      await dragBall(tester, -600);
      expect(find.byKey(ear), findsOneWidget);
      expect(tester.getRect(find.byKey(ear)).left, closeTo(0, 1));
      // 圆角朝内：贴左时左侧是平的（用展开后的位置反证它确实记着"在左"）
      await tester.tap(find.byKey(ear));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(ball)).left, closeTo(0, 1));
    });

    testWidgets('★ 停在中间松手：不收起也不吸附（靠边才有的行为不该到处生效）', (tester) async {
      await pumpApp(tester);
      await startTimer(tester);
      final before = tester.getRect(find.byKey(ball)).center.dx;
      await dragBall(tester, -100); // 从右下角往左挪一点，离两条边都远
      expect(find.byKey(ball), findsOneWidget, reason: '球还在，没收成耳朵');
      expect(find.byKey(ear), findsNothing);
      final after = tester.getRect(find.byKey(ball)).center.dx;
      expect(after, lessThan(before), reason: '位置跟着手走，没被吸回边上去');
    });

    testWidgets('★ 贴右展开后往中间拖：跟手走、不被吸回（阈值只认"真的靠边"）', (tester) async {
      await pumpApp(tester);
      await startTimer(tester);
      await dragBall(tester, 600); // 吸右 + 收耳朵
      await tester.tap(find.byKey(ear));
      await tester.pumpAndSettle(); // 展开，仍贴右
      expect(tester.getRect(find.byKey(ball)).right, closeTo(414, 1));
      // 拖回中间（超过 40 的吸边阈值）：应该变成自由态，而不是又被吸回收起
      await dragBall(tester, -150);
      expect(find.byKey(ball), findsOneWidget, reason: '离边够远 → 保持完整球');
      expect(find.byKey(ear), findsNothing);
      final r = tester.getRect(find.byKey(ball));
      expect(r.right, lessThan(414 - 100), reason: '手往左走了 150，球就该在左边，不是吸回边上');
    });

    testWidgets('★ 贴左展开后起拖：从边上走，不跳回默认右下角', (tester) async {
      await pumpApp(tester);
      await startTimer(tester);
      await dragBall(tester, -600); // 吸左 + 收耳朵
      await tester.tap(find.byKey(ear));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(ball)).left, closeTo(0, 1),
          reason: '展开后仍贴左（贴哪一边是事实源）');
      // 往右拖 150：坐标必须从**当前贴边位置**实体化起算。
      // 少了这一步起算，球会先跳到默认右下角（≈260）再动——这就是这条用例存在的理由。
      await dragBall(tester, 150);
      expect(find.byKey(ball), findsOneWidget);
      final left = tester.getRect(find.byKey(ball)).left;
      expect(left, greaterThan(80), reason: '确实离开左边了');
      expect(left, lessThan(240), reason: '从左边走了 150，不是从右下角走的');
    });

    testWidgets('并行两张表：耳朵上带计数（收起也不丢"还有别的表"）', (tester) async {
      await pumpApp(tester);
      await startTimer(tester);
      await tester.tap(find.byType(TimeCapsule).at(1));
      await tester.pumpAndSettle();
      expect(boardOf(tester).count, 2);
      await dragBall(tester, 600);
      expect(find.byKey(ear), findsOneWidget);
      expect(find.byKey(const ValueKey('timer-ear-count')), findsOneWidget);
      expect(find.text('×2'), findsOneWidget, reason: '与完整球的计数同一写法');
    });
  });

  group('全屏独占', () {
    testWidgets('★ 全屏页开着：球与耳朵都不该在屏幕上', (tester) async {
      await pumpApp(tester);
      await startTimer(tester);
      expect(find.byKey(ball), findsOneWidget);
      await openFull(tester);
      expect(find.byKey(const ValueKey('timer-full-time')), findsOneWidget,
          reason: '全屏页本身要在');
      expect(boardOf(tester).screenOccupied, isTrue);
      expect(find.byKey(ball), findsNothing,
          reason: '原型里全屏与悬浮窗是互斥渲染，实现不能把 entry 一直挂着');
      expect(find.byKey(ear), findsNothing);
    });

    testWidgets('全屏页开着 → 退出后球回来，且仍贴原来那条边', (tester) async {
      await pumpApp(tester);
      await startTimer(tester);
      await dragBall(tester, 600); // 吸右 + 收成耳朵
      expect(find.byKey(ear), findsOneWidget);
      await tester.tap(find.byKey(ear)); // 展开才能进面板
      await tester.pumpAndSettle();
      await openFull(tester);
      expect(boardOf(tester).screenOccupied, isTrue);
      expect(find.byKey(ball), findsNothing);
      expect(find.byKey(ear), findsNothing);

      // 退出全屏：球该回来。此时它是完整球（进全屏前就是展开态）
      await tester.tap(find.byKey(const ValueKey('timer-full-min')));
      await tester.pumpAndSettle();
      expect(boardOf(tester).screenOccupied, isFalse);
      expect(find.byKey(ball), findsOneWidget);
      expect(tester.getRect(find.byKey(ball)).right, closeTo(414, 1),
          reason: '退出全屏后仍贴原来那条边，不弹回默认角');
    });

    testWidgets('全部关掉再起表：回到默认完整球（不残留耳朵态）', (tester) async {
      await pumpApp(tester);
      await startTimer(tester);
      await dragBall(tester, 600);
      expect(find.byKey(ear), findsOneWidget);
      // 关完所有表
      await tester.tap(find.byKey(ear));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ball));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('timer-close-all')));
      await tester.pumpAndSettle();
      expect(boardOf(tester).count, 0);
      // 收起面板（关完刻意不 pop，要让人看见空态——§7.10 记过）
      await tester.tapAt(const Offset(207, 200));
      await tester.pumpAndSettle();
      await startTimer(tester);
      expect(find.byKey(ball), findsOneWidget);
      expect(find.byKey(ear), findsNothing, reason: '新起一张表该回到默认形态');
    });
  });

  // 需求原话：「全屏要包含通知栏的，当前没有」。
  // 这条不是配色审美：状态栏那 40 多像素要是没被这一屏接管，
  // 深色页顶上就是一条与页面无关的系统带，看着像"没铺满"。
  group('全屏含通知栏', () {
    /// 造一台"有状态栏/导航栏"的机器。
    Future<void> pumpWithBars(WidgetTester tester) async {
      await pumpApp(tester, bars: const FakeViewPadding(top: 44, bottom: 24));
    }

    testWidgets('★ 面板开着时球让位：面板里的「全屏」按钮点得到（球压上去就吃点击）',
        (tester) async {
      await pumpWithBars(tester);
      await startTimer(tester);
      await tester.tap(find.byKey(ball));
      await tester.pumpAndSettle();
      expect(find.byKey(ball), findsNothing,
          reason: '面板就是球的展开态，两个同屏会互相压着');
      // 这一 tap 本身就是判据：球还浮在面板上时，命中的会是球而不是按钮
      final id = boardOf(tester).timers.last.id;
      await tester.tap(find.byKey(ValueKey('timer-full-$id')));
      await tester.pumpAndSettle();
      expect(find.byType(TimerFullPage), findsOneWidget);
    });

    testWidgets('★ 深色底顶到 y=0（状态栏那一条在这屏里，不是让出来的空白）', (tester) async {
      await pumpWithBars(tester);
      await startTimer(tester);
      await openFull(tester);
      final bg = tester.getRect(find.byKey(const ValueKey('timer-full-bg')));
      expect(bg.top, closeTo(0, 0.5), reason: '页面本体从屏幕最上沿开始');
      expect(bg.bottom, closeTo(2200, 1));
      // 内容仍要让开状态栏，否则第一行会被系统时钟压住
      expect(tester.getRect(find.byKey(const ValueKey('timer-full-top'))).top,
          greaterThanOrEqualTo(44));
    });

    testWidgets('★ 这一屏声明浅色状态栏图标（深色底上才看得见）', (tester) async {
      await pumpWithBars(tester);
      await startTimer(tester);
      await openFull(tester);
      final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.descendant(
              of: find.byType(TimerFullPage),
              matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>)));
      expect(region.value.statusBarIconBrightness, Brightness.light,
          reason: 'Android 看这条：深色页必须是浅色图标');
      expect(region.value.statusBarColor, isA<Color>(),
          reason: '状态栏底色由这屏给（透明=露出页面深色底）');
    });

    testWidgets('收成悬浮窗后这屏消失：系统栏样式**显式**设回底下那屏的', (tester) async {
      // 这一路不止我们一个写家：`MaterialApp._themeBuilder` 每次构建都按主题推一记默认
      // 样式（`material/app.dart:1003`，那份的导航栏是**实心黑**），`RenderView` 在有注解时也会推。
      // 所以只比 `latestStyle` 测到的是"谁最后写"的竞态。这里改成**看推给系统的调用记录**：
      // 我们那一记的指纹是「深色图标 + 两套栏都透明」，别人冒充不了。
      final pushed = <Map<Object?, Object?>>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemChrome.setSystemUIOverlayStyle' &&
            call.arguments != null) {
          pushed.add(Map<Object?, Object?>.from(call.arguments! as Map));
        }
        return null;
      });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );

      await pumpWithBars(tester);
      await startTimer(tester);
      await openFull(tester);
      // 全屏页在场：注解推给系统的样式是浅色图标（深色页才看得见）
      expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.light,
          reason: '这一屏接管了通知栏');
      await tester.tap(find.byKey(const ValueKey('timer-full-min')));
      await tester.pumpAndSettle();
      expect(find.byType(TimerFullPage), findsNothing);
      expect(find.byKey(const ValueKey('timer-full-bg')), findsNothing);
      // ★ 框架在读不到注解时是直接 return（`RenderView._updateSystemChrome`），
      //   不会替我们还原；靠 MaterialApp 兜底会留一条实心黑导航栏。所以收尾自己推。
      expect(
        pushed.any((m) =>
            m['statusBarIconBrightness'] == 'Brightness.dark' &&
            m['systemNavigationBarColor'] == 0 &&
            m['statusBarColor'] == 0),
        isTrue,
        reason: '退出这屏要显式推一记「深色图标 + 透明栏」，$pushed',
      );
      // 底线也单独钉一条：离开深色页之后，浅色页上的图标必须是深色
      expect(SystemChrome.latestStyle?.statusBarIconBrightness, Brightness.dark,
          reason: '离开全屏计时页，状态栏图标必须回到浅色页该有的深色');
      // 球回来，而且不爬到状态栏里（钳位与全屏页读的是同一份 padding）
      expect(find.byKey(ball), findsOneWidget);
      // 往左上拖：纯竖直拖会停在右缘 40 阈值内 → 按吸边规则收成耳朵，
      // 那是另一条决策（与原型同一口径），别和"越界钳位"混在一条用例里判。
      await tester.drag(find.byKey(ball), const Offset(-200, -4000));
      await tester.pumpAndSettle();
      expect(find.byKey(ball), findsOneWidget, reason: '离边够远，还是完整球');
      expect(tester.getRect(find.byKey(ball)).top, greaterThanOrEqualTo(44),
          reason: '往上拖到底也只能停在状态栏下方，不能被系统时钟压住');
    });
  });
}
