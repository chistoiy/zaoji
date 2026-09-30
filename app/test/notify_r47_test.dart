import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/timer_alert.dart';
import 'package:zaoji/data/timer_board.dart';
import 'package:zaoji/main.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import 'fss_stub.dart';

/// R47 · 计时结束的通知与声音（FR-COOK-14 + FR-SET-03 那两路）。
///
/// 这一段真正要钉的是**两道闸门**：
/// ① 本机开关（`KitchenPrefs.notifyOn`）关着 → 一条都不发；
/// ② 系统授权（[NotifyPermission]）没拿到 → 也一条都不发，而且界面上要给出口，
///    不是摆一枚点了没反应的按钮。
/// 发送动作整个换成假的（插件在测试区没有通道实现），
/// 断言打在「发了几条、title/sound 是什么、被挡掉几条」上。
void main() {
  setUpAll(stubSecureStorageForTest);

  group('TimerAlert 闸门（单元）', () {
    test('★ 没授权时一条都不发，但把被挡掉的条数记下来', () async {
      final sent = <AlertNotice>[];
      final alert = TimerAlert(sender: (n) async => sent.add(n));
      expect(alert.permission, NotifyPermission.unknown,
          reason: '初始态必须是 unknown：Web 在用户点之前根本读不到授权');

      final n = await alert.fire([firedTimer('a', '炖', 60)], sound: true);
      expect(n, 0);
      expect(sent, isEmpty);
      expect(alert.skippedCount, 1, reason: '挡掉要留痕，否则排查时只能说“没反应”');
    });

    test('授权到手后才发，title 与 sound 都跟着参数走', () async {
      final sent = <AlertNotice>[];
      final alert = TimerAlert(sender: (n) async => sent.add(n))
        ..permission = NotifyPermission.granted;

      final n = await alert.fire([firedTimer('a', '蒸 6 分钟', 60)], sound: false);
      expect(n, 1);
      expect(sent.single.title, '「蒸 6 分钟」时间到');
      expect(sent.single.sound, isFalse, reason: '关掉「通知带声音」就该是静默横幅');
    });

    test('★ 振动是**每条**的参数：灶上传 true 才振，默认不振', () async {
      final sent = <AlertNotice>[];
      final alert = TimerAlert(sender: (n) async => sent.add(n))
        ..permission = NotifyPermission.granted;

      await alert.fire([firedTimer('a', '炖', 60)], sound: true, vibrate: true);
      expect(sent.single.vibrate, isTrue,
          reason: '到点这一路要通知自己振——HapticFeedback 会被系统「触摸反馈」开关吞掉');

      sent.clear();
      await alert.fire([firedTimer('b', '炖', 60)], sound: true);
      expect(sent.single.vibrate, isFalse,
          reason: '不传就是不振：开关关掉必须真的关，别的路也不该顺手振');
    });

    test('requestAccess：同意算 granted，系统说不行就 denied（不假装成功）', () async {
      var asked = 0;
      final ok = TimerAlert(requestPermission: () async {
        asked++;
        return true;
      });
      expect(await ok.requestAccess(), isTrue);
      expect(ok.permission, NotifyPermission.granted);

      final no = TimerAlert(requestPermission: () async => false);
      expect(await no.requestAccess(), isFalse);
      expect(no.permission, NotifyPermission.denied,
          reason: '被拒就是被拒——界面据此换措辞并给「去系统设置」的出口');

      final boom = TimerAlert(requestPermission: () async => throw StateError('没有通道'));
      expect(await boom.requestAccess(), isFalse);
      expect(boom.lastError, contains('没有通道'));
      expect(asked, 1);
    });

    test('并行到点各发一条；同一条计时器的 id 稳定（不攒一屏垃圾横幅）', () async {
      final sent = <AlertNotice>[];
      final alert = TimerAlert(sender: (n) async => sent.add(n))
        ..permission = NotifyPermission.granted;

      final n = await alert.fire(
          [firedTimer('a', '炖', 60), firedTimer('b', '蒸', 30)],
          sound: true);
      expect(n, 2);
      expect(sent.map((e) => e.title).toList(), ['「炖」时间到', '「蒸」时间到']);

      // 同一条再报一次 → 同一个 id（系统覆盖旧的那条而不是叠一条）
      final again = <AlertNotice>[];
      final a2 = TimerAlert(sender: (n) async => again.add(n))..permission = NotifyPermission.granted;
      await a2.fire([firedTimer('a', '炖', 60)], sound: true);
      await a2.fire([firedTimer('a', '炖', 60)], sound: true);
      expect(again[0].id, again[1].id);
      expect(TimerAlert.noticeIdOf('a'), greaterThan(0), reason: '通知 id 要非零且确定');
    });

    test('一条失败不挡住后面那几条，也不炸调用方', () async {
      final attempts = <String>[];
      final alert = TimerAlert(sender: (n) async {
        attempts.add(n.title);
        if (n.title.contains('坏')) throw StateError('渠道没建好');
      })
        ..permission = NotifyPermission.granted;

      final n = await alert.fire(
          [firedTimer('x', '坏菜', 60), firedTimer('y', '好菜', 60)],
          sound: true);
      expect(attempts.length, 2, reason: '并行的表各发各的，一条失败不该牵连另一条');
      expect(n, 1);
      expect(alert.lastError, contains('渠道没建好'));
    });

    test('init 读得到真值就收敛：true→granted、false→denied、读不到→保持 unknown', () async {
      final g = TimerAlert(readPermission: () async => true);
      await g.init();
      expect(g.permission, NotifyPermission.granted);

      final d = TimerAlert(readPermission: () async => false);
      await d.init();
      expect(d.permission, NotifyPermission.denied);

      final u = TimerAlert(readPermission: () async => null);
      await u.init();
      expect(u.permission, NotifyPermission.unknown, reason: '读不到就不许猜（Web 授权前正是这种）');

      final boom = TimerAlert(readPermission: () async => throw StateError('无通道'));
      await boom.init();
      expect(boom.permission, NotifyPermission.unknown);
      expect(boom.lastError, contains('无通道'));
    });

    test('被拒之后要有去系统设置的出口，而不是死胡同', () async {
      var opened = 0;
      final alert = TimerAlert(openSettings: () async {
        opened++;
      });
      await alert.openSystemSettings();
      expect(opened, 1);

      final boom = TimerAlert(openSettings: () async => throw StateError('这一端没有这个口'));
      await boom.openSystemSettings();
      expect(boom.lastError, contains('这一端没有这个口'), reason: '失败只留痕，不往外抛');
    });

    test('清单里声明了 POST_NOTIFICATIONS（release 包通知硬门槛）', () {
      final xml = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      expect(xml, contains('android.permission.POST_NOTIFICATIONS'),
          reason: '漏了这条，Android 13+ 上通知永远发不出去，看着像功能没做');
      expect(xml, contains('android.permission.INTERNET'),
          reason: 'R35 那条老账不能被这次改动顶掉');
    });

    test('notifyOn 落 local_pref：真重载读得回', () async {
      final exec = NativeDatabase.memory();
      final a = RecipeStore(executor: exec);
      await a.ready();
      a.setKitchenPrefs(a.kitchenPrefs.copyWith(notifyOn: false, soundOn: false));
      expect(a.kitchenPrefs.notifyOn, isFalse);

      // 同一个 executor 再造一个 store = 真重启
      final b = RecipeStore(executor: exec);
      await b.ready();
      expect(b.kitchenPrefs.notifyOn, isFalse);
      expect(b.kitchenPrefs.soundOn, isFalse);
      expect(b.kitchenPrefs.vibrateOn, isTrue, reason: '别的路不该被带跑');
      b.dispose();
      a.dispose();
    });
  });

  group('接到真动线（App 根注入假闸门）', () {
    late RecipeStore store;
    late TimerBoard board;
    late TimerAlert alert;
    late List<AlertNotice> sent;

    Future<void> boot(WidgetTester tester, {bool grant = false}) async {
      store = RecipeStore(executor: NativeDatabase.memory());
      await store.ready();
      addTearDown(store.dispose);
      board = TimerBoard(vibrate: () => false);
      addTearDown(board.dispose);
      sent = <AlertNotice>[];
      alert = TimerAlert(sender: (n) async => sent.add(n));
      if (grant) alert.permission = NotifyPermission.granted;
      addTearDown(alert.dispose);

      tester.view.physicalSize = const Size(414, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ZaojiApp(store: store, timers: board, alert: alert));
      await tester.pumpAndSettle();
    }

    /// 让表「过点」：把时钟拨到终点之后结算一次，走的就是 main 里接的那个闸门。
    Future<void> fireOverdue(WidgetTester tester, String label) async {
      board.start(label, 60);
      board.tickAt(DateTime.now().millisecondsSinceEpoch + 120000);
      await tester.pump();
    }

    testWidgets('★ 到点：开着通知才发得出（本机开关是真的开关）', (tester) async {
      await boot(tester, grant: true);
      await fireOverdue(tester, '炖牛肉');
      expect(sent, hasLength(1), reason: '过点该往通知栏发一条');
      expect(sent.single.title, contains('炖牛肉'));
    });

    testWidgets('★ 把「计时结束通知」关掉：到点一条都不发', (tester) async {
      await boot(tester, grant: true);
      store.setKitchenPrefs(store.kitchenPrefs.copyWith(notifyOn: false));
      await fireOverdue(tester, '红烧肉');
      expect(sent, isEmpty, reason: '开关关着还发通知就是假开关');
      expect(alert.skippedCount, 0, reason: '本机这一道门先挡住，不该记到授权闸门头上');
    });

    testWidgets('声音那一路：关掉「通知带声音」发出去的是静默那条', (tester) async {
      await boot(tester, grant: true);
      store.setKitchenPrefs(store.kitchenPrefs.copyWith(soundOn: false));
      await fireOverdue(tester, '蒸蛋');
      expect(sent.single.sound, isFalse);
    });

    testWidgets('★ 振动那一路：开关跟着 vibrateOn 传到**通知本身**（不是只靠 HapticFeedback）',
        (tester) async {
      await boot(tester, grant: true);
      await fireOverdue(tester, '炖牛肉');
      expect(sent.single.vibrate, isTrue, reason: '默认开 → 这条通知要自己振');

      sent.clear();
      store.setKitchenPrefs(store.kitchenPrefs.copyWith(vibrateOn: false));
      await fireOverdue(tester, '炖排骨');
      expect(sent.single.vibrate, isFalse, reason: '关掉还振就是假开关');
      // ★ 真机踩过的坑：HapticFeedback 在系统「触摸反馈」关掉时被静默吞掉，
      //   而渠道级 enableVibration 一直是 false，两头都不振 = 用户以为功能没做。
      //   所以振动必须挂在通知上，而不是只挂在震动调用上。
    });

    testWidgets('「我的」页：没授权时声音行不出现，但给能点的授权入口', (tester) async {
      await boot(tester); // unknown
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('prefs-notify')), findsOneWidget);
      expect(store.kitchenPrefs.notifyOn, isTrue, reason: '出厂默认开');
      expect(find.byKey(const ValueKey('prefs-sound')), findsNothing);
      expect(find.text('还没拿到系统授权'), findsOneWidget);
      expect(find.byKey(const ValueKey('prefs-notify-access')), findsOneWidget);
    });

    testWidgets('点授权入口：拿到授权后声音行立刻出现、入口自己收掉', (tester) async {
      store = RecipeStore(executor: NativeDatabase.memory());
      await store.ready();
      addTearDown(store.dispose);
      board = TimerBoard(vibrate: () => false);
      addTearDown(board.dispose);
      alert = TimerAlert(requestPermission: () async => true);
      addTearDown(alert.dispose);

      tester.view.physicalSize = const Size(414, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ZaojiApp(store: store, timers: board, alert: alert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('prefs-notify-access')));
      await tester.pumpAndSettle();
      expect(alert.permission, NotifyPermission.granted, reason: '点它就该真的去要授权');
      expect(find.byKey(const ValueKey('prefs-sound')), findsOneWidget);
      expect(find.text('到点在通知栏提醒一次'), findsOneWidget);
      expect(find.byKey(const ValueKey('prefs-notify-access')), findsNothing);
    });

    testWidgets('被拒过：文案换口、点它走系统设置而不是反复弹框', (tester) async {
      store = RecipeStore(executor: NativeDatabase.memory());
      await store.ready();
      addTearDown(store.dispose);
      board = TimerBoard(vibrate: () => false);
      addTearDown(board.dispose);
      var opened = 0;
      var asked = 0;
      alert = TimerAlert(
        openSettings: () async {
          opened++;
        },
        requestPermission: () async {
          asked++;
          return false;
        },
      )..permission = NotifyPermission.denied;
      addTearDown(alert.dispose);

      tester.view.physicalSize = const Size(414, 2000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ZaojiApp(store: store, timers: board, alert: alert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();

      expect(find.text('系统已拒绝，去系统设置里开'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('prefs-notify-access')));
      await tester.pumpAndSettle();
      expect(opened, 1, reason: '被拒后要的是设置出口，不是再来一次弹框');
      expect(asked, 0);
    });

    testWidgets('关掉通知那一行：声音行与授权入口都收起（不留着能点）', (tester) async {
      await boot(tester, grant: true);
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('prefs-sound')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('prefs-notify')));
      await tester.pumpAndSettle();
      expect(store.kitchenPrefs.notifyOn, isFalse);
      expect(find.byKey(const ValueKey('prefs-sound')), findsNothing);
      expect(find.text('不开通知，只剩震动与视觉'), findsOneWidget);
      expect(alert.sentCount, 0);
    });
  });
}

/// 造一个「刚过点」的计时器值对象：通知那一路只读 id 与 label。
KitchenTimer firedTimer(String id, String label, int totalSeconds) => KitchenTimer(
      id: id,
      label: label,
      totalSeconds: totalSeconds,
      endAtMs: 0,
      leftSeconds: 0,
      running: false,
      done: true,
    );
