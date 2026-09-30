import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/meal_reminder.dart';
import 'package:zaoji/data/pantry_watch.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/timer_alert.dart';
import 'package:zaoji/main.dart';
import 'package:zaoji/models.dart';

import 'fss_stub.dart';

/// R47 第六段 · 开饭前投待办（FR-PLAN-09 + FR-SET-01）。
///
/// 方向是用户拍定的：**继续派生、不建 `plan_task` 表**，所以这一段零 schema 改动。
/// 要钉住的四件事：
/// ① 只有「今天 + 定了开饭时间 + 排了菜 + 进了提前量窗口」才投，一次只投最早那一餐；
/// ② 去重按**餐次**（`YYYY-MM-DD#餐名`）而不是按天，且**被闸门挡掉不许落戳**；
/// ③ 这枚开关是**自己的**（`mealReminderOn`），不借计时器那枚 `notifyOn`；
/// ④ 设置页那一行说的与通知正文发的是**同一句话**（同一个 `MealDigest.summary`）。
void main() {
  setUpAll(stubSecureStorageForTest);

  // 判定基准由注入的假时钟给，日期从它现算——
  // 用例之间只靠这个 `now` 与菜单时刻的**相对关系**成立，不写死「今天」。
  final now = DateTime(2026, 12, 25, 17, 30);
  final dayStamp = mealDay(now);

  MenuPlan menu(
    String meal,
    String serveAt, {
    List<String> dishes = const ['r1', 'r2', 'r3'],
    String? day,
  }) =>
      MenuPlan(
        id: 'm-$meal',
        day: day ?? dayStamp,
        meal: meal,
        serveAt: serveAt,
        recipeIds: dishes,
      );

  /// 假闸门：授权态可改，发出去的都留在 [sent] 里。
  TimerAlert grantedAlert(List<AlertNotice> sent) =>
      TimerAlert(sender: (n) async => sent.add(n))
        ..permission = NotifyPermission.granted;

  /// 假检查器：戳用内存集合，`markNotified` 写回它（真落库那一半另有一组用例）。
  MealReminderWatch watch(
    List<MenuPlan> menus, {
    required TimerAlert alert,
    required Set<String> stamped,
    bool enabled = true,
    int lead = 90,
  }) =>
      MealReminderWatch(
        menus: () => menus,
        digestOf: (m) => MealDigest(
          dishNames: [for (final id in m.recipeIds) '菜$id'],
          ingredientCount: 5,
          stepCount: 9,
        ),
        alert: alert,
        enabled: () => enabled,
        leadMinutes: () => lead,
        alreadyNotified: stamped.contains,
        markNotified: (k) async => stamped.add(k),
        clock: () => now,
      );

  group('投递判定（单元）', () {
    test('★ 还没进窗口不投；进了窗口投一条，标题带剩余分钟、正文就是摘要、静默', () async {
      final sent = <AlertNotice>[];
      final stamped = <String>{};
      // 19:30 开饭、提前量 90 分钟 → 现在（17:30）还差 120 分钟，窗口没开
      expect(
          await watch([menu('晚餐', '19:30')],
              alert: grantedAlert(sent), stamped: stamped)
              .checkAndNotify(),
          0);
      expect(sent, isEmpty);

      // 18:30 开饭 → 剩 60 分钟，进了窗口
      final w = watch([menu('晚餐', '18:30')],
          alert: grantedAlert(sent), stamped: stamped);
      expect(await w.checkAndNotify(), 1);
      expect(sent.single.id, MealReminderWatch.noticeIdMeal);
      expect(sent.single.title, '18:30 晚餐 · 还剩 60 分钟开饭');
      expect(sent.single.body, '3 道菜 · 备菜 5 样 · 步骤 9 步',
          reason: '正文就是设置页那一行说的话（同一个 summary，不各写一遍）');
      expect(sent.single.sound, isFalse, reason: '这是「有空看一眼」，响的该是灶上的计时器');
      expect(stamped, { '$dayStamp#晚餐' });
      expect(w.lastEligible, 1);
    });

    test('★ 开关关掉：一条都不发，也不许落戳（不然再打开就永远不会投了）', () async {
      final sent = <AlertNotice>[];
      final stamped = <String>{};
      expect(
          await watch([menu('晚餐', '18:00')],
              alert: grantedAlert(sent), stamped: stamped, enabled: false)
              .checkAndNotify(),
          0);
      expect(sent, isEmpty);
      expect(stamped, isEmpty);
    });

    test('★ 被系统授权闸门挡掉时不落戳：当场点完授权，这一餐还投得出去', () async {
      final sent = <AlertNotice>[];
      final stamped = <String>{};
      final alert = TimerAlert(sender: (n) async => sent.add(n))
        ..permission = NotifyPermission.unknown;
      final w = watch([menu('晚餐', '18:00')], alert: alert, stamped: stamped);
      expect(await w.checkAndNotify(), 0);
      expect(stamped, isEmpty, reason: '一条都没发出去，不能记成「今天这餐投过了」');

      alert.permission = NotifyPermission.granted;
      expect(await w.checkAndNotify(), 1);
      expect(sent.length, 1);
      expect(stamped, { '$dayStamp#晚餐' });
    });

    test('★ 去重按餐次：同一餐第二次开 App 不重发，另一餐在自己窗口里照样投', () async {
      final sent = <AlertNotice>[];
      final stamped = <String>{'$dayStamp#晚餐'}; // 晚餐今天已经投过
      final menus = [menu('晚餐', '18:00'), menu('夜宵', '18:15')];
      final w = watch(menus, alert: grantedAlert(sent), stamped: stamped);
      expect(await w.checkAndNotify(), 1,
          reason: '戳只挡晚餐，夜宵还在窗口里（提前量 90 分钟）');
      expect(sent.single.title, '18:15 夜宵 · 还剩 45 分钟开饭');
      expect(stamped, {'$dayStamp#晚餐', '$dayStamp#夜宵'});
    });

    test('一个窗口里两餐都到期：只投开饭最早的那一餐', () async {
      final sent = <AlertNotice>[];
      final stamped = <String>{};
      final menus = [menu('夜宵', '18:30'), menu('晚餐', '18:00')];
      await watch(menus, alert: grantedAlert(sent), stamped: stamped)
          .checkAndNotify();
      expect(sent.length, 1, reason: '两条横幅等于让用户在通知栏里排菜的序，那是 R50 的活');
      expect(sent.single.title.startsWith('18:00 晚餐'), isTrue, reason: sent.single.title);
      expect(stamped, { '$dayStamp#晚餐' }, reason: '没投的那餐不能占戳');

      // 第一餐投完之后，下一餐在自己窗口里会顶上来
      final again = <AlertNotice>[];
      expect(
          await watch(menus,
              alert: grantedAlert(again), stamped: stamped).checkAndNotify(),
          1);
      expect(again.single.title.startsWith('18:30 夜宵'), isTrue, reason: again.single.title);
    });

    test('没排菜的餐次不投（一条写着「还没排菜」的待办就是垃圾），也不占戳', () async {
      final sent = <AlertNotice>[];
      final stamped = <String>{};
      expect(
          await watch([menu('晚餐', '18:00', dishes: [])],
              alert: grantedAlert(sent), stamped: stamped)
              .checkAndNotify(),
          0);
      expect(sent, isEmpty);
      expect(stamped, isEmpty);
    });

    test('过了开饭点不投；不是今天的、没定时间的、时间形状不对的一律不投', () async {
      final sent = <AlertNotice>[];
      final stamped = <String>{};
      final menus = [
        menu('晚餐', '17:00'), // 已经开过饭
        menu('午餐', ''), // 没定开饭时间
        menu('早餐', '25:99'), // 形状不对，不猜
        menu('明天的晚餐', '18:00', day: '2027-01-05'), // 不是今天
      ];
      expect(
          await watch(menus, alert: grantedAlert(sent), stamped: stamped)
              .checkAndNotify(),
          0);
      expect(sent, isEmpty);
    });

    test('★ 提前量越界按钳位算：存进来的 10 分钟当 15 分钟用', () async {
      final sent = <AlertNotice>[];
      final menus = [menu('晚餐', '17:50')]; // 还剩 20 分钟
      expect(
          await watch(menus,
              alert: grantedAlert(sent), stamped: <String>{}, lead: 10)
              .checkAndNotify(),
          0,
          reason: '10 < minLead(15)，钳成 15 之后 20 分钟仍不在窗口里');
      expect(
          await watch(menus,
              alert: grantedAlert(sent), stamped: <String>{}, lead: 30)
              .checkAndNotify(),
          1);
      expect(sent.last.title, '17:50 晚餐 · 还剩 20 分钟开饭');
    });

    test('★ 号段三段互不重叠：库存 1/2、开饭 100、计时器一律 ≥ 1000', () {
      expect(PantryWatch.noticeIdBad, 1);
      expect(PantryWatch.noticeIdSoon, 2);
      expect(MealReminderWatch.noticeIdMeal, 100);
      expect(MealReminderWatch.noticeIdMeal,
          greaterThan(PantryWatch.noticeIdSoon));
      expect(MealReminderWatch.noticeIdMeal,
          lessThan(TimerAlert.timerIdFloor));
      for (final key in ['01J...', 'a', 'zzz', '00000000000000000000000000']) {
        expect(TimerAlert.noticeIdOf(key),
            greaterThanOrEqualTo(TimerAlert.timerIdFloor));
      }
    });

    test('提前量的说法只有一套：档位文本与副文案共用 mealLeadLabel', () {
      expect(mealLeadLabel(30), '30 分钟');
      expect(mealLeadLabel(45), '45 分钟');
      expect(mealLeadLabel(60), '1 小时');
      expect(mealLeadLabel(90), '1.5 小时');
      expect(mealLeadLabel(120), '2 小时');
      expect(mealLeadLabel(180), '3 小时');
      expect(KitchenPrefs.leadSteps.map(mealLeadLabel).toList(),
          ['30 分钟', '45 分钟', '1 小时', '1.5 小时', '2 小时', '3 小时']);
    });
  });

  group('去重戳真的落本机（真重载）', () {
    test('markMealReminderNotified 写 local_pref，重建 store 读得回', () async {
      final exec = NativeDatabase.memory();
      final a = RecipeStore(executor: exec);
      await a.ready();
      expect(a.mealReminderNotifiedKeys, isEmpty, reason: '新库默认没投过');
      final key = '${mealDay(DateTime.now())}#晚餐';
      await a.markMealReminderNotified(key);
      expect(a.mealReminderNotified(key), isTrue);

      // 同一个 executor 再造一个 store = 真重启（只断言「库里有行」会假绿）
      final b = RecipeStore(executor: exec);
      await b.ready();
      expect(b.mealReminderNotifiedKeys, {key});
      expect(b.mealReminderNotified(key), isTrue);
      b.dispose();
      a.dispose();
    });

    test('只认 YYYY-MM-DD#餐名：被手改坏的旧值当没有，不猜', () async {
      final exec = NativeDatabase.memory();
      final a = RecipeStore(executor: exec);
      await a.ready();
      await a.dbOrNull!.customInsert(
        'INSERT INTO local_pref (pref_key, pref_value) VALUES (?, ?) '
        'ON CONFLICT(pref_key) DO UPDATE SET pref_value = excluded.pref_value',
        variables: [
          Variable('meal_reminder_notified'),
          Variable('["胡说八道","2026-13-99#晚餐",42]'),
        ],
      );
      final b = RecipeStore(executor: exec);
      await b.ready();
      expect(b.mealReminderNotifiedKeys, isEmpty,
          reason: '认不出来的戳要当没有，而不是当成「今天投过了」——那是永久静音');
      b.dispose();
      a.dispose();
    });

    test('写新的一餐时把非当天的戳剪掉（日期在键里，所以不用读时钟）', () async {
      final exec = NativeDatabase.memory();
      final a = RecipeStore(executor: exec);
      await a.ready();
      await a.markMealReminderNotified('2026-01-01#早餐');
      await a.markMealReminderNotified('2026-01-02#晚餐');
      expect(a.mealReminderNotifiedKeys, {'2026-01-02#晚餐'});

      final b = RecipeStore(executor: exec);
      await b.ready();
      expect(b.mealReminderNotifiedKeys, {'2026-01-02#晚餐'});
      expect(b.mealReminderNotified('2026-01-01#早餐'), isFalse);
      b.dispose();
      a.dispose();
    });

    test('mealReminderOn 与提前量持久化，且不带着别的路一起翻', () async {
      final exec = NativeDatabase.memory();
      final a = RecipeStore(executor: exec);
      await a.ready();
      expect(a.kitchenPrefs.mealReminderOn, isTrue, reason: '出厂默认开（与原型同一份默认值）');
      expect(a.kitchenPrefs.mealLeadMinutes, 90);
      a.setKitchenPrefs(a.kitchenPrefs
          .copyWith(mealReminderOn: false, mealLeadMinutes: 45));

      final b = RecipeStore(executor: exec);
      await b.ready();
      expect(b.kitchenPrefs.mealReminderOn, isFalse);
      expect(b.kitchenPrefs.mealLeadMinutes, 45);
      expect(b.kitchenPrefs.notifyOn, isTrue, reason: '开饭那枚开关不能把计时器通知一起关掉');
      expect(b.kitchenPrefs.expiryNotifyOn, isTrue);
      b.dispose();
      a.dispose();
    });
  });

  group('设置页（FR-SET-01 的 UI）', () {
    Future<RecipeStore> storeWith({
      String serveAt = '',
      int dishes = 0,
      String? meal,
    }) async {
      final store = RecipeStore(executor: NativeDatabase.memory());
      await store.ready();
      final recipes = store.recipes.take(dishes).toList();
      if (serveAt.isNotEmpty) {
        await store.createMenu(
          day: mealDay(DateTime.now()),
          meal: meal ?? '晚餐',
          serveAt: serveAt,
        );
        if (recipes.isNotEmpty) {
          await store.addDish(store.menus.last.id, recipes.first.id);
        }
      }
      return store;
    }

    testWidgets('默认就有这一行，副文案写的是提前量；档位六颗就地摆着', (tester) async {
      final store = RecipeStore(executor: NativeDatabase.memory());
      await store.ready();
      addTearDown(store.dispose);
      tester.view.physicalSize = const Size(414, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ZaojiApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('prefs-meal-reminder')), findsOneWidget);
      expect(find.text('提前 1.5 小时把备菜与制作投进待办'), findsOneWidget);
      for (final m in KitchenPrefs.leadSteps) {
        expect(find.byKey(ValueKey('prefs-lead-$m')), findsOneWidget,
            reason: '$m 那一档要在页面上，不该藏在弹层里');
      }
      // ★ 就地内嵌：不许出现「点了先弹一层」的中间态。
      //   （这里不能用 ModalBarrier 判——App 起起来本来就带一层遮罩，那是背景不是弹层）
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      // 今天没定开饭时间 → 如实说，而不是挂一枚看起来坏掉的开关
      expect(find.byKey(const ValueKey('prefs-meal-none')), findsOneWidget);
      expect(find.text(kMealNoTargetText), findsOneWidget);
      // 与其余几路并存（各管各的）
      expect(find.byKey(const ValueKey('prefs-timer-float')), findsOneWidget);
      expect(find.byKey(const ValueKey('prefs-expiry')), findsOneWidget);
    });

    testWidgets('点「1 小时」那档：偏好当场改、副文案跟着改，收起的档位不冒出来', (tester) async {
      final store = RecipeStore(executor: NativeDatabase.memory());
      await store.ready();
      addTearDown(store.dispose);
      tester.view.physicalSize = const Size(414, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ZaojiApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('prefs-lead-60')));
      await tester.pumpAndSettle();
      expect(store.kitchenPrefs.mealLeadMinutes, 60);
      expect(find.text('提前 1 小时把备菜与制作投进待办'), findsOneWidget);
      final on = tester.widget<FilterChip>(find.byKey(const ValueKey('prefs-lead-60')));
      expect(on.selected, isTrue);
      final off = tester.widget<FilterChip>(find.byKey(const ValueKey('prefs-lead-90')));
      expect(off.selected, isFalse);
    });

    testWidgets('关掉开关：档位与今日行整块收起，副文案改口', (tester) async {
      final store = await storeWith(serveAt: '18:30', dishes: 1);
      addTearDown(store.dispose);
      tester.view.physicalSize = const Size(414, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ZaojiApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('prefs-lead-60')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('prefs-meal-reminder')));
      await tester.pumpAndSettle();
      expect(store.kitchenPrefs.mealReminderOn, isFalse);
      expect(find.text('不开待办，只在菜单里看'), findsOneWidget);
      expect(find.byKey(const ValueKey('prefs-lead-60')), findsNothing);
      expect(find.byKey(const ValueKey('prefs-meal-none')), findsNothing,
          reason: '开关关了就不该再宣称今天要投什么');
    });

    testWidgets('★ 今日那一行的文字 == 通知正文要用的那句（一份口径两处吃）', (tester) async {
      final serve = DateTime.now().add(const Duration(hours: 6));
      final store = RecipeStore(executor: NativeDatabase.memory());
      await store.ready();
      addTearDown(store.dispose);
      final menu = await store.createMenu(
        day: mealDay(serve),
        meal: '晚餐',
        serveAt: '${serve.hour.toString().padLeft(2, '0')}:'
            '${serve.minute.toString().padLeft(2, '0')}',
      );
      await store.addDish(menu.id, store.recipes.first.id);
      await store.addDish(menu.id, store.recipes[1].id);

      tester.view.physicalSize = const Size(414, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ZaojiApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();

      final line = find.byKey(ValueKey('prefs-meal-today-${menu.id}'));
      expect(line, findsOneWidget);
      final digest = digestOfMenu(store, store.menuById(menu.id)!);
      expect(find.text('${menu.serveAt} 晚餐 · ${digest.summary}'), findsOneWidget);
      expect(digest.summary, contains('道菜'), reason: digest.summary);
      expect(digest.summary, contains('备菜'), reason: digest.summary);
      expect(digest.summary, contains('步骤'), reason: digest.summary);
      expect(find.text(kMealNoTargetText), findsNothing);
    });

    testWidgets('定了时间但还没排菜：那一行说「还没排菜」', (tester) async {
      final store = await storeWith(serveAt: '19:00');
      addTearDown(store.dispose);
      tester.view.physicalSize = const Size(414, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ZaojiApp(store: store));
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();

      final m = store.menus.single;
      expect(find.text('${m.serveAt} 晚餐 · 还没排菜'), findsOneWidget);
      expect(digestOfMenu(store, m).summary, '还没排菜');
    });
  });

  group('接到真动线', () {
    testWidgets('★ 打开 App 就投：进窗口 + 已授权 → 一条通知并落本机戳', (tester) async {
      final serve = DateTime.now().add(const Duration(minutes: 40));
      final store = RecipeStore(executor: NativeDatabase.memory());
      await store.ready();
      addTearDown(store.dispose);
      final menu = await store.createMenu(
        day: mealDay(serve),
        meal: '测试晚餐',
        serveAt: '${serve.hour.toString().padLeft(2, '0')}:'
            '${serve.minute.toString().padLeft(2, '0')}',
      );
      await store.addDish(menu.id, store.recipes.first.id);
      store.setKitchenPrefs(store.kitchenPrefs.copyWith(notifyOn: false));

      final sent = <AlertNotice>[];
      final alert = TimerAlert(sender: (n) async => sent.add(n))
        ..permission = NotifyPermission.granted;
      tester.view.physicalSize = const Size(414, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ZaojiApp(store: store, alert: alert));
      await tester.pumpAndSettle();

      // ★ 计时器那枚开关（notifyOn）关着也照投——两枚开关各管各的，
      //   不然「静音到点提醒」会顺手把开饭待办一起掐掉。
      expect(sent.map((n) => n.id).toList(), [MealReminderWatch.noticeIdMeal],
          reason: '开饭前投待办只走 mealReminderOn 这一枚闸门');
      expect(sent.single.title, contains('测试晚餐'), reason: sent.single.title);
      expect(store.mealReminderNotified('${mealDay(serve)}#测试晚餐'), isTrue,
          reason: '投出去就该落戳，否则回前台一次就多一条');

      // 回前台：同一餐不重发
      final before = sent.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(sent.length, before, reason: '每餐只投一次');
    });
  });
}
