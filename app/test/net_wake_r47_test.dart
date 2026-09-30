import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart' show Size;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/net_wake.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/main.dart';

import 'fss_stub.dart';

/// R47 第七段 · 网络恢复即同步（需求书 §9.2 S1「飞行模式新增 10 道菜 →
/// 恢复网络后自动同步」；计划书 §22.3 第 1 条点名的洞）。
///
/// 这一路要断的全是**判定**，不是通道：
/// ① 第一个事件只记录不触发（启动已经同步过一次，别把它当恢复）；
/// ② 只有「离线 → 在线」的上升沿算恢复（wifi 切移动网络没断过，不算）；
/// ③ 恢复那一瞬间的多次上升沿要合并成一次同步；
/// ④ 拿不到监听能力（桌面预览 / 测试区没通道）不许炸掉 App。
void main() {
  setUpAll(stubSecureStorageForTest);

  const debounce = Duration(milliseconds: 40);
  const wifi = [ConnectivityResult.wifi];
  const none = [ConnectivityResult.none];
  const mobile = [ConnectivityResult.mobile];

  /// 过一帧又等一下：流投递走微任务，去抖走定时器。
  Future<void> settle([Duration d = Duration.zero]) => Future<void>.delayed(d);

  late StreamController<List<ConnectivityResult>> ctrl;
  late int calls;
  NetWake make({FutureOr<void> Function()? onOnline}) {
    ctrl = StreamController<List<ConnectivityResult>>();
    calls = 0;
    return NetWake(
      streamOf: () => ctrl.stream,
      debounce: debounce,
      onOnline: onOnline ?? () => calls++,
    );
  }

  Future<void> close(NetWake w) async {
    await w.dispose();
    if (!ctrl.isClosed) await ctrl.close();
  }

  group('上升沿判定（单元）', () {
    test('★ 第一个事件只记录不触发：开 App 时本来就联网，不该算「恢复」', () async {
      final w = make();
      w.start();
      ctrl.add(wifi);
      await settle(const Duration(milliseconds: 120));
      expect(calls, 0, reason: '启动路径已经同步过一次，再补一轮是白打服务端');
      expect(w.lastResults, wifi);
      expect(w.edges, 0);
      await close(w);
    });

    test('★ 离线 → 在线：认出一个上升沿，到点回调一次', () async {
      final w = make();
      w.start();
      ctrl.add(none);
      await settle();
      ctrl.add(wifi);
      await settle(const Duration(milliseconds: 120));
      expect(w.edges, 1);
      expect(calls, 1);
      await close(w);
    });

    test('★ 没断过就不算恢复：wifi → mobile → 双接口，一次都不触发', () async {
      final w = make();
      w.start();
      for (final r in [wifi, mobile, [ConnectivityResult.wifi, ConnectivityResult.mobile]]) {
        ctrl.add(r);
        await settle();
      }
      await settle(const Duration(milliseconds: 120));
      expect(w.edges, 0);
      expect(calls, 0, reason: '换网络不是恢复，用户没被断过');
      await close(w);
    });

    test('一直离线不触发；空读数按离线算（平台侧不该发空列表，但别当在线）', () async {
      final w = make();
      w.start();
      ctrl.add(wifi);
      await settle();
      ctrl.add(none);
      await settle();
      ctrl.add(none);
      await settle();
      ctrl.add(<ConnectivityResult>[]);
      await settle(const Duration(milliseconds: 120));
      expect(calls, 0);
      expect(NetWake.isOffline(none), isTrue);
      expect(NetWake.isOffline(<ConnectivityResult>[]), isTrue);
      expect(NetWake.isOffline(wifi), isFalse);
      await close(w);
    });

    test('★ 恢复那一瞬间的三次上升沿合并成一次同步', () async {
      final w = make();
      w.start();
      // none→wifi→none→mobile→none→wifi，全在去抖窗口内
      for (final r in [none, wifi, none, mobile, none, wifi]) {
        ctrl.add(r);
        await settle();
      }
      expect(w.edges, 3, reason: '上升沿确实认了三次');
      expect(calls, 0, reason: '还在合并窗口里');
      await settle(const Duration(milliseconds: 120));
      expect(calls, 1, reason: '刚通的那一秒连环打服务端是最不该做的事');
      await close(w);
    });

    test('合并不是抑制：下一次真正的恢复仍然会同步', () async {
      final w = make();
      w.start();
      ctrl.add(none);
      await settle();
      ctrl.add(wifi);
      await settle(const Duration(milliseconds: 120));
      expect(calls, 1);
      ctrl.add(none);
      await settle();
      ctrl.add(mobile);
      await settle(const Duration(milliseconds: 120));
      expect(calls, 2);
      await close(w);
    });

    test('start 幂等：订两次就会一次恢复同步两遍', () async {
      final w = make();
      w.start();
      w.start();
      expect(w.isListening, isTrue);
      ctrl.add(none);
      await settle();
      ctrl.add(wifi);
      await settle(const Duration(milliseconds: 120));
      expect(calls, 1);
      await close(w);
    });
  });

  group('失败不许把监听弄哑（这一路是体验，不是数据）', () {
    test('onOnline 抛：留痕、不 rethrow，下一次恢复仍然同步', () async {
      var boom = true;
      var hits = 0;
      final w = NetWake(
        streamOf: () {
          ctrl = StreamController<List<ConnectivityResult>>();
          return ctrl.stream;
        },
        debounce: debounce,
        onOnline: () {
          if (boom) throw StateError('同步炸了');
          hits++;
        },
      );
      w.start();
      ctrl.add(none);
      await settle();
      ctrl.add(wifi);
      await settle(const Duration(milliseconds: 120));
      expect(w.lastError, contains('同步炸了'), reason: '要看得见，但不该往上抛');
      boom = false;
      ctrl.add(none);
      await settle();
      ctrl.add(wifi);
      await settle(const Duration(milliseconds: 120));
      expect(hits, 1, reason: '一次失败不能让这只耳朵永久聋掉');
      await close(w);
    });

    test('流自己报错：留痕之后继续订着，恢复仍然能听见', () async {
      final w = make();
      w.start();
      ctrl.add(none);
      await settle();
      ctrl.addError(SocketException('没通道'));
      await settle();
      expect(w.lastError, contains('没通道'));
      ctrl.add(wifi);
      await settle(const Duration(milliseconds: 120));
      expect(calls, 1, reason: '流报错不等于「没有网络」，更不等于「不用再听了」');
      await close(w);
    });

    test('★ 取不到监听能力（桌面预览 / 测试区）：start 不炸，只留痕', () async {
      final w = NetWake(
        streamOf: () => throw MissingPluginException(),
        onOnline: () => calls++,
      );
      expect(() => w.start(), returnsNormally);
      expect(w.isListening, isFalse);
      expect(w.lastError, contains('MissingPluginException'));
      await w.dispose();
    });

    test('dispose 撤手：未触发的去抖定时器不许再回调，订阅也取消', () async {
      final w = make();
      w.start();
      ctrl.add(none);
      await settle();
      ctrl.add(wifi);
      await w.dispose();
      await settle(const Duration(milliseconds: 120));
      expect(calls, 0, reason: 'App 都退了，不该再留一个会打网络的一次性定时器');
      expect(w.isListening, isFalse);
    });
  });

  group('接到真动线', () {
    testWidgets('ZaojiApp 起来后网络从断到通：走的是引擎的 syncIfPaired 那一条口', (tester) async {
      final store = RecipeStore(executor: NativeDatabase.memory());
      await store.ready();
      addTearDown(store.dispose);
      var wakes = 0;
      final ctrl2 = StreamController<List<ConnectivityResult>>();
      final wake = NetWake(
        streamOf: () => ctrl2.stream,
        debounce: debounce,
        onOnline: () => wakes++,
      );
      addTearDown(() async {
        await wake.dispose();
        await ctrl2.close();
      });
      tester.view.physicalSize = const Size(414, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ZaojiApp(store: store, net: wake));
      await tester.pumpAndSettle();

      // 监听是 App 起引擎之后自己 start 的（_ensureSync 那一处），用例不用手动开。
      ctrl2.add(none);
      await tester.pump();
      ctrl2.add(wifi);
      expect(wakes, 0, reason: '去抖窗口内不该立刻打网络');
      await tester.pump(const Duration(milliseconds: 120));
      expect(wakes, 1);
      expect(wake.lastResults, wifi);
    });
  });
}
