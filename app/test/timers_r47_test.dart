import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/timer_board.dart';
import 'package:zaoji/data/timer_scope.dart';
import 'package:zaoji/main.dart';
import 'package:zaoji/widgets/time_capsule_text.dart';

import 'fss_stub.dart';

/// R47 · 厨房计时台（FR-COOK-04 并行、FR-COOK-05 不漂移、FR-COOK-03 切换不丢）。
///
/// 分两层钉：
/// ① **纯逻辑层**：给 [TimerBoard] 注入假时钟，把时间「拨快 10 分钟」而不真等——
///    这与原型走查 (`tool/proto_timers_r47_walk.cjs`) 用的是同一个手法，
///    两边钉的是同一条性质：剩余量 = 目标戳 - 现在。
/// ② **接线层**：真点胶囊、真开弹层、真关弹层，钉「表活着活在台面上，不在弹层里」。
///
/// 为什么不测真倒计时：真等 10 分钟不是测试；而递减法恰恰只在真等时才露馅，
/// 所以把「时间」做成可注入的，比模拟等待更有价值。
void main() {
  setUpAll(stubSecureStorageForTest);

  group('计时台：假时钟下的性质', () {
    final t0 = DateTime(2026, 9, 29, 18).millisecondsSinceEpoch;
    late int clock;
    late TimerBoard board;
    late List<String> vibrated;

    setUp(() {
      clock = t0;
      vibrated = [];
      board = TimerBoard(
        clock: () => clock,
        // 记录「谁被提醒了」而不是真去敲振动通道：R47-3 接通知时同样走这个口子
        vibrate: () {
          vibrated.add('buzz');
          return true;
        },
      );
    });
    tearDown(() => board.dispose());

    void advance(int seconds) => clock += seconds * 1000;

    test('起三个表：各走各的，剩余量互不影响', () {
      final a = board.start('炖 30 分钟', 1800);
      final b = board.start('蒸 6 分钟', 360);
      final c = board.start('收汁 3 分钟', 180);
      expect(board.count, 3);

      advance(300); // 5 分钟
      expect(board.remainingOf(a.id), closeTo(1500, 0.001));
      expect(board.remainingOf(b.id), closeTo(60, 0.001));
      expect(board.remainingOf(c.id), 0, reason: '3 分钟的表早就到点了');
    });

    test('★ 后台 10 分钟回来：30 分钟的表正好少 600 秒（NFR-REL-03 误差 <2s）', () {
      final a = board.start('慢炖', 1800);
      board.tickAt(clock);
      advance(600);
      board.tickAt(clock);
      expect(1800 - board.remainingOf(a.id), closeTo(600, 0.001));
    });

    test('到点只提醒一次，不每次心跳重响', () {
      board.start('60 秒', 60);
      advance(30);
      expect(board.tickAt(clock), isEmpty);
      expect(vibrated, isEmpty);
      advance(40);
      final fired = board.tickAt(clock);
      expect(fired.length, 1);
      expect(vibrated.length, 1);
      // 再跳一次：已经是 done 态，不该再报
      advance(10);
      expect(board.tickAt(clock), isEmpty);
      expect(vibrated.length, 1);
    });

    test('暂停一个不动另一个；续跑用冻结的剩余量重算目标戳', () {
      final a = board.start('炖', 600);
      final b = board.start('蒸', 900);
      advance(100);
      board.pause(a.id);
      advance(200); // a 暂停期间时间照走，但它不该跟着掉
      expect(board.remainingOf(a.id), closeTo(500, 0.001));
      expect(board.remainingOf(b.id), closeTo(600, 0.001));

      board.resume(a.id);
      expect(board.remainingOf(a.id), closeTo(500, 1.0),
          reason: '续跑不能沿用旧目标戳，否则当场归零');
      advance(100);
      expect(board.remainingOf(a.id), closeTo(400, 0.001));
    });

    test('+1 分改的是目标戳；重置回到「当前设定值」并停住', () {
      final a = board.start('炖', 300);
      board.extend(a.id, 60);
      expect(board.remainingOf(a.id), closeTo(360, 0.001));
      board.reset(a.id);
      // 重置回到的是**加时之后的设定值 360**，不是最初的 300：
      // +1 分同时抬了进度分母（totalSeconds），这一条与原型 `timer-reset` 的
      // `left = total` 完全一致。测试第一版按「回到起表时长」断言 300，
      // 红的是我的预期，不是实现——原型口径优先。
      expect(board.remainingOf(a.id), closeTo(360, 0.001));
      advance(120);
      expect(board.remainingOf(a.id), closeTo(360, 0.001), reason: '重置后是暂停态，不该继续掉');
    });

    test('关掉一个不动其他；全部关掉后心跳自己停（不给测试留 pending Timer）', () {
      final a = board.start('a', 60);
      final b = board.start('b', 120);
      board.close(a.id);
      expect(board.count, 1);
      expect(board.remainingOf(b.id), closeTo(120, 0.001));
      board.close(b.id);
      expect(board.hasRunning, isFalse);
    });
  });

  group('接线：胶囊 → 计时台 → 悬浮球 → 面板', () {
    /// 每个测试自建 store（内存库），init 落在自己的 FakeAsync 区里
    /// ——与 `recipe_flow_test.dart` 同一条定式（全局单例 + 真 async 区是陷阱）。
    Future<void> pumpApp(WidgetTester tester,
        {double h = 2200, TimerBoard? timers}) async {
      tester.view.physicalSize = Size(414, h);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ZaojiApp(
        executor: NativeDatabase.memory(),
        timers: timers,
      ));
      await tester.pumpAndSettle();
    }

    TimerBoard boardOf(WidgetTester tester) =>
        tester.widget<TimerScope>(find.byType(TimerScope).first).board;

    Future<void> openPanel(WidgetTester tester) async {
      await tester.tap(find.byKey(const ValueKey('timer-ball')));
      await tester.pumpAndSettle();
    }

    Future<void> backToDetail(WidgetTester tester) async {
      await tester.tap(find.text('番茄炒蛋'));
      await tester.pumpAndSettle();
    }

    testWidgets('连点两个胶囊 = 两个并行表（面板一开就吃不掉胶囊了）', (tester) async {
      await pumpApp(tester);
      await backToDetail(tester);

      await tester.tap(find.byType(TimeCapsule).at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TimeCapsule).at(0));
      await tester.pumpAndSettle();

      expect(boardOf(tester).count, 2, reason: '点两次要起两个表，不是把同一个改时长');
      expect(find.byKey(const ValueKey('timer-ball')), findsOneWidget);
      expect(find.byKey(const ValueKey('timer-ball-count')), findsOneWidget);
      expect(find.text('×2'), findsOneWidget);

      await openPanel(tester);
      expect(find.text('并行 2'), findsOneWidget);
      expect(find.text('暂停'), findsNWidgets(2));

      await tester.tap(find.byKey(const ValueKey('timer-close-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('timer-ball')), findsNothing);
    });

    testWidgets('★ 面板关掉、切到别的屏，表还在走（状态在台上，不在弹层里）', (tester) async {
      await pumpApp(tester);
      await backToDetail(tester);
      await tester.tap(find.byType(TimeCapsule).first);
      await tester.pumpAndSettle();
      final id = boardOf(tester).timers.single.id;

      // 回列表（表跨路由活着：球插在 navigator 的 root Overlay 上）
      Navigator.of(tester.element(find.byType(TimeCapsule).first)).pop();
      await tester.pumpAndSettle();
      expect(boardOf(tester).count, 1);
      expect(find.byKey(const ValueKey('timer-ball')), findsOneWidget);

      // 再进详情、再开面板：原来那一行还在
      await backToDetail(tester);
      await openPanel(tester);
      expect(find.byKey(ValueKey('timer-row-$id')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('timer-close-all')));
      await tester.pumpAndSettle();
    });

    testWidgets('★ 假时钟拨快 30 秒：球上的读数正好少 30 秒（FR-COOK-05 端到端）',
        (tester) async {
      // FakeAsync 推 Timer 但**不推 DateTime.now()**，所以这条必须用注入的假时钟：
      // 心跳照常跳，读数取自 endAt - 假时钟，两者一起动才证明 UI 没有自己攒一份倒计时。
      var fakeNow = DateTime(2026, 9, 29, 18).millisecondsSinceEpoch;
      final board = TimerBoard(clock: () => fakeNow, vibrate: () => false);
      addTearDown(board.dispose);
      await pumpApp(tester, timers: board);
      await backToDetail(tester);

      await tester.tap(find.byType(TimeCapsule).first);
      await tester.pumpAndSettle();
      int ballSeconds() {
        final t = tester
            .widget<Text>(find.byKey(const ValueKey('timer-ball-time')))
            .data!;
        final p = t.split(':');
        return int.parse(p[0]) * 60 + int.parse(p[1]);
      }

      final before = ballSeconds();
      fakeNow += const Duration(seconds: 30).inMilliseconds;
      await tester.pump(const Duration(milliseconds: 300)); // 心跳：250ms 一跳
      final after = ballSeconds();

      expect(before - after, 30, reason: '读数必须由目标戳现算，差值要正好等于拨快的量');
      expect(board.hasRunning, isTrue);

      await tester.tap(find.byKey(const ValueKey('timer-ball')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('timer-close-all')));
      await tester.pumpAndSettle();
    });

    testWidgets('单个表时球上不写「×1」；全部关闭后心跳自己停', (tester) async {
      await pumpApp(tester);
      await backToDetail(tester);
      await tester.tap(find.byType(TimeCapsule).first);
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('timer-ball-count')), findsNothing,
          reason: '一个表的时候计数是噪声');
      expect(boardOf(tester).hasRunning, isTrue);

      await openPanel(tester);
      await tester.tap(find.byKey(const ValueKey('timer-close-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('timer-board-empty')), findsOneWidget);
      expect(boardOf(tester).hasRunning, isFalse);
    });

    testWidgets('暂停一个不动另一个（面板上各有一枚暂停键）', (tester) async {
      await pumpApp(tester);
      await backToDetail(tester);
      await tester.tap(find.byType(TimeCapsule).at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TimeCapsule).at(0));
      await tester.pumpAndSettle();
      final ids = boardOf(tester).timers.map((t) => t.id).toList();

      await openPanel(tester);
      await tester.tap(find.byKey(ValueKey('timer-toggle-${ids[0]}')));
      await tester.pumpAndSettle();

      expect(find.byKey(ValueKey('timer-state-${ids[0]}')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(ValueKey('timer-state-${ids[0]}'))).data, '已暂停');
      expect(tester.widget<Text>(find.byKey(ValueKey('timer-state-${ids[1]}'))).data, '计时中');

      await tester.tap(find.byKey(const ValueKey('timer-close-all')));
      await tester.pumpAndSettle();
    });

    testWidgets('悬浮球可拖动且不越界（FR-COOK-03）', (tester) async {
      await pumpApp(tester);
      await backToDetail(tester);
      await tester.tap(find.byType(TimeCapsule).first);
      await tester.pumpAndSettle();

      final before = tester.getRect(find.byKey(const ValueKey('timer-ball')));
      // 往左上角猛拖，超出安全区的那一段必须被钳住
      await tester.drag(find.byKey(const ValueKey('timer-ball')), const Offset(-4000, -4000));
      await tester.pumpAndSettle();
      final after = tester.getRect(find.byKey(const ValueKey('timer-ball')));

      expect(after.left, lessThan(before.left), reason: '往左拖要真的动');
      expect(after.left, greaterThanOrEqualTo(0), reason: '不能拖出屏幕左缘');
      expect(after.top, greaterThanOrEqualTo(0), reason: '不能拖进状态栏上面');
      expect(after.right, lessThanOrEqualTo(414));
      expect(after.bottom, lessThanOrEqualTo(2200));

      // 往右下角猛拖同样钳得住
      await tester.drag(find.byKey(const ValueKey('timer-ball')), const Offset(4000, 4000));
      await tester.pumpAndSettle();
      final again = tester.getRect(find.byKey(const ValueKey('timer-ball')));
      expect(again.right, lessThanOrEqualTo(414));
      expect(again.bottom, lessThanOrEqualTo(2200));

      await tester.tap(find.byKey(const ValueKey('timer-ball')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('timer-close-all')));
      await tester.pumpAndSettle();
    });

    testWidgets('全屏形态：面板 → 全屏 → 收成悬浮窗，读数一路不断（FR-COOK-03 两态）',
        (tester) async {
      var fakeNow = DateTime(2026, 9, 29, 18).millisecondsSinceEpoch;
      final board = TimerBoard(clock: () => fakeNow, vibrate: () => false);
      addTearDown(board.dispose);
      await pumpApp(tester, timers: board);
      await backToDetail(tester);
      await tester.tap(find.byType(TimeCapsule).first);
      await tester.pumpAndSettle();
      final id = board.timers.single.id;

      await openPanel(tester);
      await tester.tap(find.byKey(ValueKey('timer-full-$id')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('timer-full-time')), findsOneWidget);
      expect(find.byKey(const ValueKey('timer-full-top')), findsOneWidget);

      // 全屏里暂停一下再收成悬浮窗：回到球那一态，表还在
      await tester.tap(find.byKey(const ValueKey('timer-full-toggle')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const ValueKey('timer-full-state'))).data,
          '已暂停');
      await tester.tap(find.byKey(const ValueKey('timer-full-min')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('timer-ball')), findsOneWidget);
      expect(board.timers.single.running, isFalse);

      // 球上点开面板，把表关掉（收尾不留心跳）
      await openPanel(tester);
      await tester.tap(find.byKey(const ValueKey('timer-close-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('timer-ball')), findsNothing);
    });

    testWidgets('全屏里横切并行表：切的是焦点，不是把别的关掉', (tester) async {
      final board = TimerBoard(clock: () => DateTime(2026, 9, 29, 18).millisecondsSinceEpoch,
          vibrate: () => false);
      addTearDown(board.dispose);
      await pumpApp(tester, timers: board);
      await backToDetail(tester);
      await tester.tap(find.byType(TimeCapsule).at(0));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TimeCapsule).at(0));
      await tester.pumpAndSettle();
      final ids = board.timers.map((t) => t.id).toList();

      await openPanel(tester);
      await tester.tap(find.byKey(ValueKey('timer-full-${ids[0]}')));
      await tester.pumpAndSettle();
      expect(find.text('1/2'), findsOneWidget);

      await tester.drag(find.byKey(const ValueKey('timer-full-time')), const Offset(-260, 0));
      await tester.pumpAndSettle();
      expect(find.text('2/2'), findsOneWidget, reason: '左滑切到第二个表');
      expect(board.count, 2, reason: '切焦点不能顺手删表');

      // prev/next 是同一个动作的可见入口（横滑是隐藏手势，不能是唯一路径）
      await tester.tap(find.byKey(const ValueKey('timer-full-prev')));
      await tester.pumpAndSettle();
      expect(find.text('1/2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('timer-full-next')));
      await tester.pumpAndSettle();
      expect(find.text('2/2'), findsOneWidget);

      // 全屏的「关掉这个」只关当前这一个
      await tester.tap(find.byKey(const ValueKey('timer-full-close')));
      await tester.pumpAndSettle();
      expect(board.count, 1);
      expect(find.byKey(const ValueKey('timer-ball')), findsOneWidget);

      await openPanel(tester);
      await tester.tap(find.byKey(const ValueKey('timer-close-all')));
      await tester.pumpAndSettle();
    });
  });
}
