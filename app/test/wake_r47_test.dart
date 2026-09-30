import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/screen_wake.dart';
import 'package:zaoji/data/timer_board.dart';
import 'package:zaoji/main.dart';
import 'package:zaoji/ui/cooking_page.dart';
import 'package:zaoji/widgets/time_capsule_text.dart';

import 'fss_stub.dart';

/// R47 · 屏幕常亮（FR-COOK-09）。
///
/// 这一路真正要钉的不是「有没有调插件」，而是**引用计数那件事**：
/// 做菜模式与计时中是两条独立的路，谁先撤都不能把灯关掉。
/// 所以拨锁动作被换成一个记录调用序列的假实现（`ScreenWake(toggle: ...)`），
/// 断言打在「第几次真的拨、参数是什么」上——这是 `screen_wake.dart` 头注里
/// 写明的那个设计理由，测试必须能反过来证明它成立。
void main() {
  setUpAll(stubSecureStorageForTest);

  group('ScreenWake 引用计数（单元）', () {
    test('第一路登记才真的拨锁，第二路只记账、不重发', () {
      final calls = <bool>[];
      final wake = ScreenWake(toggle: (on) => calls.add(on));
      wake.need('cook');
      expect(calls, [true], reason: '第一次要真的亮屏');
      wake.need('timer');
      expect(calls, [true], reason: '已经亮着，不该再拨一次');
      expect(wake.reasons, ['cook', 'timer']);
      expect(wake.active, isTrue);
    });

    test('★ 一路撤走、另一路还在 → 灯不许灭（这是本轮的设计核心）', () {
      final calls = <bool>[];
      final wake = ScreenWake(toggle: (on) => calls.add(on));
      wake.need('cook');
      wake.need('timer');
      wake.done('timer');
      expect(calls, [true], reason: '计时器跑完不该把盯步骤的屏幕关掉');
      wake.done('cook');
      expect(calls, [true, false], reason: '最后一路撤掉才真的关灯');
      expect(wake.active, isFalse);
    });

    test('重复登记与重复撤手都只算一次；撤不存在的路不产生拨锁', () {
      final calls = <bool>[];
      final wake = ScreenWake(toggle: (on) => calls.add(on));
      wake.need('cook');
      wake.need('cook');
      expect(calls, [true]);
      wake.done('cook');
      wake.done('cook');
      expect(calls, [true, false]);
      wake.done('cook');
      expect(calls, [true, false], reason: '已经没有这一路了，别再拨');
    });

    test('releaseAll 无条件收干净；本来就没亮时它不拨锁', () {
      final calls = <bool>[];
      final a = ScreenWake(toggle: (on) => calls.add(on))
        ..need('cook')
        ..need('timer');
      a.releaseAll();
      expect(calls, [true, false]);
      expect(a.reasons, isEmpty);
      a.releaseAll();
      expect(calls, [true, false], reason: '幂等：第二次撤手不该再拨');

      final b = ScreenWake(toggle: (on) => calls.add(on));
      b.releaseAll();
      expect(calls, [true, false], reason: '从没亮过就什么都不做');
    });

    test('★ 拨锁抛异常不能把调用方炸掉（常亮是体验，不是数据）', () {
      final wake = ScreenWake(toggle: (on) => throw StateError('没有通道实现'));
      expect(() => wake.need('cook'), returnsNormally);
      expect(wake.lastError, contains('没有通道实现'));
      expect(wake.active, isTrue, reason: '登记本身要成立，失败只落在拨锁那一步');
    });

    test('没拨过一次时 commanded 是 false（别把「还没开始」读成「已经关」）', () {
      final calls = <bool>[];
      final wake = ScreenWake(toggle: (on) => calls.add(on));
      expect(wake.commanded, isFalse);
      expect(calls, isEmpty);
    });
  });

  group('接到真动线（App 根注入假拨锁）', () {
    /// 三件一起造、一起挂到 teardown。
    ///
    /// ★ **必须在 testWidgets 体内造，不能在 setUp 里**：`setUp` 跑在真实区，
    /// 那里完成的 store init 与 FakeAsync 测试区不是同一个时钟，
    /// 表现是 `pumpAndSettle timed out`（本文件第一版就是这么红的）。
    /// 与 `kitchen_prefs_r47_test.dart` 同一口径。
    Future<(RecipeStore, TimerBoard, ScreenWake, List<bool>)> boot(
        WidgetTester tester) async {
      final store = RecipeStore(executor: NativeDatabase.memory());
      await store.ready();
      addTearDown(store.dispose);
      final board = TimerBoard(vibrate: () => false);
      addTearDown(board.dispose);
      final calls = <bool>[];
      final wake = ScreenWake(toggle: (on) => calls.add(on));
      addTearDown(wake.dispose);

      tester.view.physicalSize = const Size(414, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ZaojiApp(store: store, timers: board, wake: wake));
      await tester.pumpAndSettle();
      return (store, board, wake, calls);
    }

    /// 从主页进做菜模式（列表 → 详情 → 开火）。
    Future<void> enterCooking(WidgetTester tester) async {
      await tester.tap(find.text('葱油拌面').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.local_fire_department_outlined));
      await tester.pumpAndSettle();
      expect(find.byType(CookingPage), findsOneWidget);
    }

    testWidgets('★ 进做菜模式就亮，走「先离开」就撤（FR-COOK-09）', (tester) async {
      final (_, _, wake, calls) = await boot(tester);
      expect(calls, isEmpty, reason: '还没进这一屏，不该提前拨锁');

      await enterCooking(tester);
      expect(wake.reasons, contains('cook'));
      expect(calls, [true]);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(wake.reasons, isNot(contains('cook')), reason: '离开必须撤手，否则锁一直挂着耗电');
      expect(calls, [true, false]);
    });

    testWidgets('★ 计时器到点不该把做菜屏弄黑（两路互不替对方决定）', (tester) async {
      final (_, board, wake, calls) = await boot(tester);
      await enterCooking(tester);
      expect(wake.reasons, contains('cook'));

      // 在步骤上点时间胶囊起一张表 → 第二路登记，但**不多拨一次锁**
      await tester.tap(find.byType(TimeCapsule).first);
      await tester.pumpAndSettle();
      expect(wake.reasons, containsAll(<String>['cook', 'timer']));
      expect(calls, [true], reason: '本来就亮着，第二路只记账');

      // 表全撤了 → 灯必须还亮（做菜模式这一路还在）
      board.closeAll();
      await tester.pump();
      expect(wake.reasons, isNot(contains('timer')));
      expect(wake.reasons, contains('cook'));
      expect(calls, [true], reason: '★ 这一行就是本轮设计核心的证据');

      // 退出做菜屏 → 最后一路撤掉，灯才灭
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();
      expect(calls, [true, false]);
    });

    testWidgets('暂停所有的表 → 心跳停了、常亮也撤；再 resume 又亮回来', (tester) async {
      final (_, board, wake, calls) = await boot(tester);
      final t = board.start('炖', 600);
      await tester.pumpAndSettle();
      expect(wake.reasons, contains('timer'));

      board.pause(t.id);
      await tester.pump();
      expect(wake.reasons, isNot(contains('timer')), reason: '暂停期间不需要常亮');
      expect(calls, [true, false]);

      board.resume(t.id);
      await tester.pump();
      expect(wake.reasons, contains('timer'));
      expect(calls, [true, false, true]);

      // 收尾一定把表关干净：注入的 board 不由 App dispose，留着 250ms 心跳
      // 会被「A Timer is still pending」判红（本仓库的老规矩）。
      board.closeAll();
      await tester.pump();
    });

    testWidgets('App 整棵树收掉时把锁撤干净（漏这一步就是后台挂着 wakelock）', (tester) async {
      final (_, board, _, calls) = await boot(tester);
      board.start('蒸', 300);
      await tester.pumpAndSettle();
      expect(calls, [true]);

      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pumpAndSettle();
      expect(calls, [true, false], reason: 'dispose 里 releaseAll 要真的把灯关掉');

      board.closeAll();
      await tester.pump();
    });
  });
}
