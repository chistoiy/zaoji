import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/pantry_watch.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/timer_alert.dart';
import 'package:zaoji/main.dart';
import 'package:zaoji/models.dart';

import 'fss_stub.dart';

/// R47 · 库存到期与临期的提醒（FR-PAN-04 缺的那半：推送时机）。
///
/// 三件事必须钉住：
/// ① **聚合成两条**（过期一条、临期一条），14 样临期不该发 14 条横幅；
/// ② **同一天只发一次**，而这条去重戳要在被授权闸门挡掉时**不落**——
///    否则用户点了授权，这台设备今天反而再也不会提醒了；
/// ③ 提醒**静默**：响的是灶上的计时器，到期提醒只是「有空看一眼」。
void main() {
  setUpAll(stubSecureStorageForTest);

  // 判定基准固定在 2026-09-30：过期=昨天及以前，临期=1~3 天内。
  final today = DateTime(2026, 9, 30, 12);
  PantryItem it(String id, String name, {String? exp, PantryStock st = PantryStock.have}) =>
      PantryItem(id: id, name: name, expireAt: exp, status: st);

  group('PantryWatch 聚合与闸门（单元）', () {
    test('★ 过期与临期各聚合成一条，且都静默、id 是 1 与 2', () async {
      final sent = <AlertNotice>[];
      final alert = TimerAlert(sender: (n) async => sent.add(n))
        ..permission = NotifyPermission.granted;
      final watch = PantryWatch(
        items: () => [
          it('a', '番茄', exp: '2026-09-29'),
          it('b', '生菜', exp: '2026-09-28'),
          it('c', '小葱', exp: '2026-10-02'),
          it('d', '鸡蛋', exp: '2026-10-20'),
        ],
        alert: alert,
        notifyEnabled: () => true,
        lastNotifiedDay: () => '',
        markNotified: (_) async {},
        clock: () => today,
      );

      expect(await watch.checkAndNotify(), 2);
      expect(sent.map((n) => n.id).toList(), [1, 2]);
      expect(sent[0].title, '2 样已经过期');
      expect(sent[0].body, '生菜、番茄', reason: '到期日早的先看（前天那样更危险）');
      expect(sent[1].title, '1 样三天内到期');
      expect(sent.every((n) => n.sound == false), isTrue, reason: '到期提醒不该响');
      expect(watch.lastBad, 2);
      expect(watch.lastSoon, 1);
    });

    test('名字超过三个收成「等 N 样」，不把通知栏写成清单', () async {
      final sent = <AlertNotice>[];
      final alert = TimerAlert(sender: (n) async => sent.add(n))
        ..permission = NotifyPermission.granted;
      final watch = PantryWatch(
        items: () => [
          it('a', '甲', exp: '2026-09-29'),
          it('b', '乙', exp: '2026-09-29'),
          it('c', '丙', exp: '2026-09-29'),
          it('d', '丁', exp: '2026-09-29'),
          it('e', '戊', exp: '2026-09-29'),
        ],
        alert: alert,
        notifyEnabled: () => true,
        lastNotifiedDay: () => '',
        markNotified: (_) async {},
        clock: () => today,
      );
      expect(await watch.checkAndNotify(), 1);
      expect(sent.single.body, '甲、乙、丙 等 5 样');
    });

    test('没过期也没临期 → 一条都不发（不打扰是默认）', () async {
      var sends = 0;
      final alert = TimerAlert(sender: (_) async => sends++)
        ..permission = NotifyPermission.granted;
      final watch = PantryWatch(
        items: () => [it('a', '大蒜', exp: '2027-01-01'), it('b', '食盐')],
        alert: alert,
        notifyEnabled: () => true,
        lastNotifiedDay: () => '',
        markNotified: (_) async {},
        clock: () => today,
      );
      expect(await watch.checkAndNotify(), 0);
      expect(sends, 0);
    });

    test('标成「没有」的项不参与提醒（库存三态里 none 就是不存在）', () async {
      final alert = TimerAlert(sender: (_) async {})
        ..permission = NotifyPermission.granted;
      final watch = PantryWatch(
        items: () => [it('a', '豆腐', exp: '2026-09-29', st: PantryStock.none)],
        alert: alert,
        notifyEnabled: () => true,
        lastNotifiedDay: () => '',
        markNotified: (_) async {},
        clock: () => today,
      );
      expect(await watch.checkAndNotify(), 0, reason: '已经用完的东西不需要提醒过期');
    });

    test('★ 同一天第二次开 App 不再发；跨天会再发一次', () async {
      var sends = 0;
      var day = '';
      final alert = TimerAlert(sender: (_) async => sends++)
        ..permission = NotifyPermission.granted;
      final watch = PantryWatch(
        items: () => [it('a', '番茄', exp: '2026-09-29')],
        alert: alert,
        notifyEnabled: () => true,
        lastNotifiedDay: () => day,
        markNotified: (d) async => day = d,
        clock: () => today,
      );
      expect(await watch.checkAndNotify(), 1);
      expect(day, '2026-09-30', reason: '戳要落下来，否则回前台一次就多一次');
      expect(await watch.checkAndNotify(), 0);
      expect(sends, 1);

      // 换到明天：同一批货还没处理，就该再提醒一次
      final tomorrow = DateTime(2026, 10, 1, 9);
      final watch2 = PantryWatch(
        items: () => [it('a', '番茄', exp: '2026-09-29')],
        alert: alert,
        notifyEnabled: () => true,
        lastNotifiedDay: () => day,
        markNotified: (d) async => day = d,
        clock: () => tomorrow,
      );
      expect(await watch2.checkAndNotify(), 1);
      expect(day, '2026-10-01');
    });

    test('★ 被授权闸门挡掉时**不落戳**（不然点了授权今天反而不提醒）', () async {
      var day = '';
      final alert = TimerAlert(sender: (_) async {})..permission = NotifyPermission.unknown;
      final watch = PantryWatch(
        items: () => [it('a', '番茄', exp: '2026-09-29')],
        alert: alert,
        notifyEnabled: () => true,
        lastNotifiedDay: () => '',
        markNotified: (d) async => day = d,
        clock: () => today,
      );
      expect(await watch.checkAndNotify(), 0);
      expect(day, '', reason: '一条都没发出去，不能记成「今天已经提醒过了」');

      // 用户随后点了授权 → 同一批还得能发出去
      alert.permission = NotifyPermission.granted;
      expect(await watch.checkAndNotify(), 1);
    });

    test('本机「库存到期提醒」关掉：不发也不落戳，且与计时器那枚开关互不影响', () async {
      var day = '';
      var sends = 0;
      final alert = TimerAlert(sender: (_) async => sends++)
        ..permission = NotifyPermission.granted;
      final watch = PantryWatch(
        items: () => [it('a', '番茄', exp: '2026-09-29')],
        alert: alert,
        notifyEnabled: () => false,
        lastNotifiedDay: () => day,
        markNotified: (d) async => day = d,
        clock: () => today,
      );
      expect(await watch.checkAndNotify(), 0);
      expect(sends, 0);
      expect(day, '');
    });

    test('★ 号段互不重叠：库存占 1/2，计时器一律 ≥ 1000', () {
      expect(PantryWatch.noticeIdBad, 1);
      expect(PantryWatch.noticeIdSoon, 2);
      for (final key in ['01J...', 'a', 'zzz', '00000000000000000000000000']) {
        expect(TimerAlert.noticeIdOf(key),
            greaterThanOrEqualTo(TimerAlert.timerIdFloor),
            reason: '计时器 id 落到 1/2 会把库存横幅顶掉（或反过来）');
      }
    });
  });

  group('去重戳真的落本机（真重载）', () {
    test('markExpiryNotified 写 local_pref，重建 store 读得回', () async {
      final exec = NativeDatabase.memory();
      final a = RecipeStore(executor: exec);
      await a.ready();
      expect(a.expiryNotifiedDay, '', reason: '新库默认没提醒过');
      await a.markExpiryNotified('2026-09-30');
      expect(a.expiryNotifiedDay, '2026-09-30');

      // 同一个 executor 再造一个 store = 真重启（只断言「库里有行」会假绿）
      final b = RecipeStore(executor: exec);
      await b.ready();
      expect(b.expiryNotifiedDay, '2026-09-30');
      b.dispose();
      a.dispose();
    });

    test('expiryNotifyOn 与其余五路各自独立地持久化', () async {
      final exec = NativeDatabase.memory();
      final a = RecipeStore(executor: exec);
      await a.ready();
      a.setKitchenPrefs(a.kitchenPrefs.copyWith(expiryNotifyOn: false));
      final b = RecipeStore(executor: exec);
      await b.ready();
      expect(b.kitchenPrefs.expiryNotifyOn, isFalse);
      expect(b.kitchenPrefs.notifyOn, isTrue, reason: '别的路不该被带跑');
      expect(b.kitchenPrefs.vibrateOn, isTrue);
      b.dispose();
      a.dispose();
    });

    test('戳只认 YYYY-MM-DD：被手改坏的旧值当没有，不猜', () async {
      final exec = NativeDatabase.memory();
      final a = RecipeStore(executor: exec);
      await a.ready();
      // 直接塞一个不像日期的值（模拟用户手改 local_pref 或旧版本写错）
      await a.dbOrNull!.customInsert(
        'INSERT INTO local_pref (pref_key, pref_value) VALUES (?, ?) '
        'ON CONFLICT(pref_key) DO UPDATE SET pref_value = excluded.pref_value',
        variables: [
          Variable('pantry_expiry_notified_day'),
          Variable('昨天好像提醒过'),
        ],
      );
      final b = RecipeStore(executor: exec);
      await b.ready();
      expect(b.expiryNotifiedDay, '', reason: '认不出来的戳要当没有，而不是当成今天');
      b.dispose();
      a.dispose();
    });
  });

  group('接到真动线', () {
    testWidgets('「我的」页有「库存到期提醒」这一行，点了就写进偏好', (tester) async {
      final store = RecipeStore(executor: NativeDatabase.memory());
      await store.ready();
      addTearDown(store.dispose);
      tester.view.physicalSize = const Size(414, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ZaojiApp(store: store));
      await tester.pumpAndSettle();

      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('prefs-expiry')), findsOneWidget);
      expect(find.text('打开 App 时提醒一次，同一天不重复'), findsOneWidget);
      expect(store.kitchenPrefs.expiryNotifyOn, isTrue, reason: '出厂默认开');

      await tester.tap(find.byKey(const ValueKey('prefs-expiry')));
      await tester.pumpAndSettle();
      expect(store.kitchenPrefs.expiryNotifyOn, isFalse);
      // 与悬浮窗/震动/通知三行并存（各管各的，不是二选一）
      expect(find.byKey(const ValueKey('prefs-timer-float')), findsOneWidget);
      expect(find.byKey(const ValueKey('prefs-vibrate')), findsOneWidget);
      expect(find.byKey(const ValueKey('prefs-notify')), findsOneWidget);
    });
  });
}
