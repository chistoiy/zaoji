import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/timer_board.dart';
import 'package:zaoji/main.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji/widgets/time_capsule_text.dart';

import 'fss_stub.dart';

/// R47 · 厨房偏好（FR-SET-02/03 两路 + 第六段接上的 FR-SET-01；口径见 `_KitchenPrefsCard`）。
///
/// 三条钉法各有理由：
/// ① **持久化必须真重载**：只断言「store 内存里改了值」是假绿（本仓库定过这条规矩）。
/// ② **开关必须能改到行为**：关掉悬浮窗后球真的不出现，而不是「界面还在只是点不动」。
/// ③ 震动那行进的是 `TimerBoard.vibrate` 闸门：关掉之后到点不该再被提醒。
/// ④ FR-SET-01 那一行在第六段之前是**刻意缺席**（待办没有落点时不放空转开关），
///    现在反过来要求它出现在界面上——缺席与在场都各有一条断言钉着，别让下一轮顺手改回去。
void main() {
  setUpAll(stubSecureStorageForTest);

  group('KitchenPrefs 本体', () {
    test('默认值与需求一致：悬浮窗开、震动开、提前量 90 分钟', () {
      const p = KitchenPrefs();
      expect(p.timerFloatOn, isTrue);
      expect(p.vibrateOn, isTrue);
      expect(p.mealLeadMinutes, 90);
    });

    test('提前量越界夹回合法档，不抛（这一行是用户可写的偏好）', () {
      expect(const KitchenPrefs(mealLeadMinutes: 3).leadMinutesClamped,
          KitchenPrefs.minLead);
      expect(const KitchenPrefs(mealLeadMinutes: 9999).leadMinutesClamped,
          KitchenPrefs.maxLead);
    });

    test('解不出来就返回 null 让调用方保持原值（不猜）', () {
      expect(KitchenPrefs.decode('不是 JSON'), isNull);
      expect(KitchenPrefs.decode('"一个裸字符串"'), isNull);
      expect(KitchenPrefs.decode(null), isNull);
      final ok = KitchenPrefs.decode(
          '{"mealReminderOn":false,"mealLeadMinutes":45,"timerFloatOn":false,"vibrateOn":true,"soundOn":false}');
      expect(ok, isNotNull);
      expect(ok!.mealLeadMinutes, 45);
      expect(ok.timerFloatOn, isFalse);
    });
  });

  group('落库与真重载', () {
    late QueryExecutor executor;
    late RecipeStore store;

    setUp(() async {
      executor = NativeDatabase.memory();
      store = RecipeStore(executor: executor);
      await store.ready();
    });
    tearDown(() async {
      await store.dbOrNull!.close();
      store.dispose();
    });

    test('★ 改完偏好、用同一个库重新起一个 store（等价冷启动）：值还在', () async {
      store.setKitchenPrefs(
          store.kitchenPrefs.copyWith(timerFloatOn: false, vibrateOn: false));
      // 落库是 unawaited 的异步写：重新开库前必须让它写完，
      // 否则测的是「内存态」而不是「库里到底有没有」。
      await Future<void>.delayed(const Duration(milliseconds: 60));

      final again = RecipeStore(executor: executor);
      await again.ready();
      expect(again.kitchenPrefs.timerFloatOn, isFalse);
      expect(again.kitchenPrefs.vibrateOn, isFalse);
      // 没动过的那一路保持默认（证明读回来的是这一行的内容，不是整份重置）
      expect(again.kitchenPrefs.mealReminderOn, isTrue);
      await again.dbOrNull!.close();
      again.dispose();
    });

    test('setKitchenPrefs 会通知（页面靠这个即时反馈）', () {
      var hits = 0;
      store.addListener(() => hits++);
      store.setKitchenPrefs(store.kitchenPrefs.copyWith(vibrateOn: false));
      expect(hits, 1);
      // 同样的值再写一次不该通知（避免无谓整页重建）
      store.setKitchenPrefs(store.kitchenPrefs);
      expect(hits, 1);
    });
  });

  group('开关改到行为', () {
    Future<void> pumpApp(WidgetTester tester,
        {required RecipeStore store, required TimerBoard board}) async {
      tester.view.physicalSize = const Size(414, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ZaojiApp(store: store, timers: board));
      await tester.pumpAndSettle();
    }

    testWidgets('★ 关掉「计时器悬浮窗」：起了表也不上屏（不是看得见点不动的假关闭）',
        (tester) async {
      final store = RecipeStore(executor: NativeDatabase.memory());
      await store.ready();
      addTearDown(store.dispose);
      final board = TimerBoard(vibrate: () => false);
      addTearDown(board.dispose);
      await pumpApp(tester, store: store, board: board);

      // 先确认「开」的时候球会出现
      await tester.tap(find.text('番茄炒蛋'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TimeCapsule).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('timer-ball')), findsOneWidget);

      // 收口在面板里，球本身只有一个「打开面板」的动作——先点开再关全部
      await tester.tap(find.byKey(const ValueKey('timer-ball')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('timer-close-all')));
      await tester.pumpAndSettle();
      // 关全部刻意不弹面板（要让用户看见空态），所以这里得自己收起：
      // 点遮罩。不点的话面板还挡着下方，下一次起表会打在遮罩上（第一版就红在这）。
      await tester.tapAt(const Offset(207, 60));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('timer-board-empty')), findsNothing);

      // 关掉偏好，再起一张表
      store.setKitchenPrefs(store.kitchenPrefs.copyWith(timerFloatOn: false));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TimeCapsule).first);
      await tester.pumpAndSettle();
      expect(board.count, 1, reason: '表还是要起（关的是跟随显示，不是计时能力）');
      expect(find.byKey(const ValueKey('timer-ball')), findsNothing);

      // 再打开：球立刻回来（偏好翻转要听得见，不能等重启）
      store.setKitchenPrefs(store.kitchenPrefs.copyWith(timerFloatOn: true));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('timer-ball')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('timer-ball')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('timer-close-all')));
      await tester.pumpAndSettle();
    });

    testWidgets('「我的」页两路开关可点，点了就写进偏好', (tester) async {
      final store = RecipeStore(executor: NativeDatabase.memory());
      await store.ready();
      addTearDown(store.dispose);
      final board = TimerBoard(vibrate: () => false);
      addTearDown(board.dispose);
      await pumpApp(tester, store: store, board: board);

      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('prefs-timer-float')), findsOneWidget);
      expect(find.byKey(const ValueKey('prefs-vibrate')), findsOneWidget);
      // R47 第六段：FR-SET-01 有落点了（投待办走 MealReminderWatch 的通知通路），
      // 上一段那条「刻意不上 UI」的约束作废——现在反过来要求它在界面上，且档位就地摆着。
      expect(find.byKey(const ValueKey('prefs-meal-reminder')), findsOneWidget);
      expect(find.byKey(const ValueKey('prefs-lead-90')), findsOneWidget);
      // 出厂默认：悬浮窗开、震动开、开饭提醒开、提前量 90 分钟（与原型 S.prefs 同一份默认值）
      expect(store.kitchenPrefs.timerFloatOn, isTrue);
      expect(store.kitchenPrefs.vibrateOn, isTrue);
      expect(store.kitchenPrefs.mealReminderOn, isTrue);
      expect(store.kitchenPrefs.mealLeadMinutes, 90);

      await tester.tap(find.byKey(const ValueKey('prefs-timer-float')));
      await tester.pumpAndSettle();
      expect(store.kitchenPrefs.timerFloatOn, isFalse);

      await tester.tap(find.byKey(const ValueKey('prefs-vibrate')));
      await tester.pumpAndSettle();
      expect(store.kitchenPrefs.vibrateOn, isFalse,
          reason: '默认是开，点一下应该关掉——第一版把预期写成 isTrue，红的是我的预期不是实现');
      expect(store.kitchenPrefs.timerFloatOn, isFalse, reason: '两路各自独立');
    });

    test('震动闸门：偏好关掉后到点不再算「已提醒」，打开才计', () {
      final store = RecipeStore(executor: NativeDatabase.memory());
      addTearDown(() async {
        await store.dbOrNull?.close();
        store.dispose();
      });
      var fakeNow = DateTime(2026, 9, 29, 18).millisecondsSinceEpoch;
      // 生产里 main.dart 就是这个闭包：偏好读成 vibrate 闸门。
      final board = TimerBoard(
        clock: () => fakeNow,
        vibrate: () => store.kitchenPrefs.vibrateOn,
      );
      addTearDown(board.dispose);

      store.setKitchenPrefs(store.kitchenPrefs.copyWith(vibrateOn: false));
      board.start('60 秒', 60);
      fakeNow += 61 * 1000;
      expect(board.tickAt(fakeNow).length, 1, reason: '表照常到点');
      expect(board.remindedCount, 0, reason: '但闸门关着，不该记成已提醒');

      store.setKitchenPrefs(store.kitchenPrefs.copyWith(vibrateOn: true));
      board.start('再一表', 30);
      fakeNow += 31 * 1000;
      board.tickAt(fakeNow);
      expect(board.remindedCount, 1, reason: '打开之后到点就计一次');
    });
  });
}
