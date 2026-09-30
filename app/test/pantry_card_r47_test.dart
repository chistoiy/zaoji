import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/pantry_watch.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/timer_alert.dart';
import 'package:zaoji/main.dart';
import 'package:zaoji/models.dart';

import 'fss_stub.dart';

/// R47 · 厨房 tab 顶部的库存告警卡（FR-PAN-06）。
///
/// 用户拍的落点是**厨房 tab 顶部**（不是菜谱那屏）：打开 App 的触达已经归
/// 通知那一路（`PantryWatch`），这张卡管的是「人已经在厨房页，一眼看到该先处理谁」。
///
/// 这个文件要钉住四件事：
/// ① 卡与通知**共用一份口径**（`pantryAlertOf` / `PantryAlert.names`），
///    两处各写一遍过滤条件必然漂成两种说法；
/// ② **有数据才出现**（FR-PAN-06 的验收判据），三组全空时不占位；
/// ③ 它是这屏**唯一**的计数出口——头部那组徽标本轮被摘掉了，
///    留着就是同一屏两份数字（去重前按场景查过覆盖：四个数卡里都在）；
/// ④ 数据是实况不是照片：库存一改，卡跟着改，不用重进页面。
void main() {
  setUpAll(stubSecureStorageForTest);

  // 基准钉在「运行当天」，日期一律相对它算——写死日期会种下时间炸弹。
  final now = DateTime.now();
  String day(int offset) {
    final d = now.add(Duration(days: offset));
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  PantryItem it(String id, String name,
          {String? exp, PantryStock st = PantryStock.have}) =>
      PantryItem(id: id, name: name, expireAt: exp, status: st);

  group('pantryAlertOf（卡与通知共用的一份口径）', () {
    test('★ 四组各归位，且「没有」的不参与到期判定', () {
      final a = pantryAlertOf([
        it('a', '番茄', exp: day(-2)),
        it('b', '牛奶', exp: day(2)),
        it('c', '鸡蛋', exp: day(30)),
        it('d', '小葱', st: PantryStock.low),
        it('e', '虾', exp: day(-1), st: PantryStock.none),
      ], now);
      expect(a.bad.map((p) => p.name).toList(), ['番茄'],
          reason: '标成「没有」的那条不算过期——家里本来就没有，提醒它没意义');
      expect(a.soon.map((p) => p.name).toList(), ['牛奶']);
      expect(a.low.map((p) => p.name).toList(), ['小葱']);
      expect(a.out.map((p) => p.name).toList(), ['虾']);
      expect(a.isEmpty, isFalse);
    });

    test('到期日近的排前面（不是按添加顺序）', () {
      final a = pantryAlertOf([
        it('1', '甲', exp: day(3)),
        it('2', '乙', exp: day(1)),
        it('3', '丙', exp: day(2)),
        it('4', '丁', exp: day(-5)),
        it('5', '戊', exp: day(-1)),
      ], now);
      expect(a.bad.map((p) => p.name).toList(), ['丁', '戊']);
      expect(a.soon.map((p) => p.name).toList(), ['乙', '丙', '甲']);
    });

    test('★ 名字超过三个收成「等 N 样」，而且卡与通知用的是同一个函数', () async {
      final xs = [
        it('1', '甲', exp: day(-4)),
        it('2', '乙', exp: day(-3)),
        it('3', '丙', exp: day(-2)),
        it('4', '丁', exp: day(-1)),
      ];
      expect(PantryAlert.names(pantryAlertOf(xs, now).bad), '甲、乙、丙 等 4 样');

      // 同四行喂给通知那条路：正文与卡片读出来必须一字不差
      final sent = <AlertNotice>[];
      final alert = TimerAlert(sender: (n) async => sent.add(n))
        ..permission = NotifyPermission.granted;
      await PantryWatch(
        items: () => xs,
        alert: alert,
        notifyEnabled: () => true,
        lastNotifiedDay: () => '',
        markNotified: (_) async {},
        clock: () => now,
      ).checkAndNotify();
      expect(sent.first.body, PantryAlert.names(pantryAlertOf(xs, now).bad),
          reason: '两处各写一遍截断，过两天就是两种说法');
    });

    test('只有「没有」时：卡要出现（它接管了头部徽标），但通知不发', () async {
      final a = pantryAlertOf([it('1', '冰糖', st: PantryStock.none)], now);
      expect(a.isEmpty, isFalse);
      expect(a.hasExpiry, isFalse, reason: '家里没有不是紧急事件，不该吵人');

      final sent = <AlertNotice>[];
      final alert = TimerAlert(sender: (n) async => sent.add(n))
        ..permission = NotifyPermission.granted;
      final n = await PantryWatch(
        items: () => [it('1', '冰糖', st: PantryStock.none)],
        alert: alert,
        notifyEnabled: () => true,
        lastNotifiedDay: () => '',
        markNotified: (_) async {},
        clock: () => now,
      ).checkAndNotify();
      expect(n, 0);
      expect(sent, isEmpty);
    });

    test('四组都空 → isEmpty（整卡不渲染的前提）', () {
      final a = pantryAlertOf([it('1', '鸡蛋', exp: day(30))], now);
      expect(a.isEmpty, isTrue);
    });
  });

  group('厨房 tab 顶部的卡（widget）', () {
    // store 必须在 testWidgets 体内造（setUp 跑在真实区，FakeAsync 区等不到它）
    Future<RecipeStore> boot(WidgetTester tester) async {
      final store = RecipeStore(executor: NativeDatabase.memory());
      await store.ready();
      addTearDown(store.dispose);
      tester.view.physicalSize = const Size(414, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ZaojiApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('厨房'));
      await tester.pumpAndSettle();
      return store;
    }

    Finder card() => find.byKey(const ValueKey('pantry-watch-card'));
    Finder inCard(String text) =>
        find.descendant(of: card(), matching: find.text(text));

    testWidgets('★ 有数据：卡在厨房顶部，四组计数与名字都在', (tester) async {
      final store = await boot(tester);
      await store.upsertPantry(name: '番茄', expireAt: day(-2), qtyValue: 2, qtyUnit: '个');
      await store.upsertPantry(name: '牛奶', expireAt: day(2), qtyValue: 1);
      await store.upsertPantry(name: '小葱', status: PantryStock.low);
      await store.upsertPantry(name: '冰糖', status: PantryStock.none);
      await tester.pumpAndSettle();

      expect(card(), findsOneWidget);
      expect(inCard('食材要处理'), findsOneWidget);
      expect(inCard('1 已过期'), findsOneWidget);
      expect(inCard('1 快到期'), findsOneWidget);
      expect(inCard('1 快没了'), findsOneWidget);
      expect(inCard('1 没有'), findsOneWidget);
      for (final key in ['pwc-bad', 'pwc-soon', 'pwc-low', 'pwc-out']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      expect(inCard('2 番茄'), findsNothing,
          reason: '行里只列名字，分量留给下面的库存行');
      expect(inCard('番茄'), findsOneWidget);
    });

    testWidgets('★ 没数据：整卡不出现，也不占位', (tester) async {
      final store = await boot(tester);
      await store.upsertPantry(name: '鸡蛋', expireAt: day(30), qtyValue: 6);
      await tester.pumpAndSettle();
      expect(store.pantryItems.length, 1);
      expect(card(), findsNothing);
      expect(find.text('食材要处理'), findsNothing);
    });

    testWidgets('★ 数据是实况不是照片：库存一改，卡跟着改，不用重进页面', (tester) async {
      final store = await boot(tester);
      await store.upsertPantry(name: '小葱', status: PantryStock.low);
      await tester.pumpAndSettle();
      expect(inCard('1 快没了'), findsOneWidget);
      expect(inCard('1 已过期'), findsNothing);

      await store.upsertPantry(name: '番茄', expireAt: day(-1), qtyValue: 1);
      await tester.pumpAndSettle();
      expect(inCard('1 已过期'), findsOneWidget,
          reason: '新加一条过期项，卡当场要多一行——只 build 一次就是照片');

      // 处理掉了（改到期日）之后那行自己收起
      final t = store.pantryItems.firstWhere((p) => p.name == '番茄');
      await store.upsertPantry(
          id: t.id, name: '番茄', expireAt: day(20), qtyValue: 1);
      await tester.pumpAndSettle();
      expect(inCard('1 已过期'), findsNothing);
      expect(inCard('1 快没了'), findsOneWidget, reason: '另一组不受牵连');
    });

    testWidgets('★ 这屏只留一份计数：头部那组徽标确实摘掉了', (tester) async {
      final store = await boot(tester);
      await store.upsertPantry(name: '番茄', expireAt: day(-2), qtyValue: 1);
      await tester.pumpAndSettle();
      // 「1 已过期」在卡里出现一次；头部若还留着徽标，这里就是两次
      expect(find.text('1 已过期'), findsOneWidget);
      expect(find.textContaining('样食材在家里'), findsOneWidget,
          reason: '头部统计卡本身还在，摘掉的只是那四枚徽标');
    });

    testWidgets('去处按钮：库存段给、能做什么段收起、点了真的切段', (tester) async {
      final store = await boot(tester);
      await store.upsertPantry(name: '番茄', expireAt: day(-2), qtyValue: 1);
      await tester.pumpAndSettle();

      final btn = find.byKey(const ValueKey('pwc-reco'));
      expect(btn, findsOneWidget);

      await tester.tap(btn);
      await tester.pumpAndSettle();
      expect(card(), findsOneWidget, reason: '换了段，告警跟着在');
      expect(btn, findsNothing, reason: '已经在目的地了，按钮就是假的');

      // 切回库存段，按钮回来
      await tester.tap(find.descendant(
          of: find.byType(SegmentedButton<int>), matching: find.text('库存')));
      await tester.pumpAndSettle();
      expect(btn, findsOneWidget);
    });

    testWidgets('单行标签说准话：今天到期与已过期分得开', (tester) async {
      final store = await boot(tester);
      await store.upsertPantry(name: '今天那条', expireAt: day(0), qtyValue: 1);
      await store.upsertPantry(name: '上周那条', expireAt: day(-6), qtyValue: 1);
      await tester.pumpAndSettle();

      expect(inCard('2 已过期'), findsOneWidget,
          reason: '成组统计宁可说重（含今天），一律「已过期」');
      expect(find.text('今天到期'), findsOneWidget,
          reason: '单行分得清就说准的：到期日正好今天');
      expect(find.text('已过期'), findsOneWidget,
          reason: '更早的那条才叫已过期');
    });
  });
}
