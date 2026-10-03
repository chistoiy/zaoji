import 'dart:async';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/sync/sync_engine.dart';
import 'package:zaoji/data/sync/sync_prefs.dart';
import 'package:zaoji/data/sync/sync_scope.dart';
import 'package:zaoji/data/sync/sync_transport.dart';
import 'package:zaoji/ui/ai_settings_page.dart';

/// 真机报障（2026-10-03）：手机在家庭网外（5G+VPN）打开「大模型能力」，
/// 服务端地址连不通 → `/api/ai/status` 的 TCP 挂在校层永远不回话，
/// 而 aiCall 这条通道**没带超时**（同引擎的 refreshAccessConfig 带了 5s），
/// 于是 _loading 永远不清，页面钉在转圈。
///
/// 这里用一个**永不完成**的 transport 演那台半死的服务端：
/// 修复前 aiCall 会挂到测试超时（红灯=复现）；修复后必须在预算内
/// 抛 SyncNetworkException，设置页必须落到「读不到服务端配置」的错误版式。
class _HangingTransport implements SyncTransport {
  final gets = <String>[];
  final Map<String, Object?> _neverReply = const {};
  final Completer<Map<String, Object?>> _mapHang = Completer();
  final Completer<Uint8List> _bytesHang = Completer();

  @override
  Future<Map<String, Object?>> get(String path, {String? token}) {
    gets.add(path);
    return _mapHang.future;
  }

  @override
  Future<Map<String, Object?>> post(
    String path,
    Map<String, Object?> body, {
    String? token,
  }) =>
      _mapHang.future;

  @override
  Future<Map<String, Object?>> delete(String path, {String? token}) =>
      _mapHang.future;

  @override
  Future<Map<String, Object?>> putBytes(
    String path,
    Uint8List bytes, {
    String? token,
  }) =>
      _mapHang.future;

  @override
  Future<Uint8List> getBytes(String path, {String? token}) =>
      _bytesHang.future;

  @override
  void close() {}

  // 让分析器知道 _neverReply 是有意的占位（不参与任何回包）。
  Map<String, Object?> get unusedReply => _neverReply;
}

void main() {
  late RecipeStore store;
  late SyncPrefs prefs;

  setUp(() async {
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
    prefs = SyncPrefs(store.dbOrNull!);
    await prefs.setServerUrl('http://home.server.test:8666');
  });
  tearDown(() async {
    await store.dbOrNull!.close();
    store.dispose();
  });

  SyncEngine makeEngine(SyncTransport t) =>
      SyncEngine(db: store.dbOrNull!, prefs: prefs, transport: t);

  group('aiCall 超时闸门', () {
    test('快路径（status）挂死的服务端要在预算内抛错，而不是永挂', () async {
      SyncEngine.aiFastTimeoutForTest = const Duration(milliseconds: 80);
      addTearDown(SyncEngine.resetAiTimeoutsForTest);
      final engine = makeEngine(_HangingTransport());
      await expectLater(
        engine.aiCall('/api/ai/status'),
        throwsA(
          isA<SyncNetworkException>().having(
            (e) => e.message,
            'message',
            contains('超时'),
          ),
        ),
      );
      engine.dispose();
    });

    test('能力路径（calories）预算更长，但同样不许永挂', () async {
      SyncEngine.aiSlowTimeoutForTest = const Duration(milliseconds: 120);
      addTearDown(SyncEngine.resetAiTimeoutsForTest);
      final engine = makeEngine(_HangingTransport());
      await expectLater(
        engine.aiCall('/api/ai/calories', {'name': '番茄炒蛋'}),
        throwsA(isA<SyncNetworkException>()),
      );
      engine.dispose();
    });

    test('aiDelete（执行记录清理）同样带闸门', () async {
      SyncEngine.aiFastTimeoutForTest = const Duration(milliseconds: 80);
      addTearDown(SyncEngine.resetAiTimeoutsForTest);
      final engine = makeEngine(_HangingTransport());
      await expectLater(
        engine.aiDelete('/api/ai/runs'),
        throwsA(isA<SyncNetworkException>()),
      );
      engine.dispose();
    });
  });

  testWidgets('挂死的服务端：设置页要落到错误版式，不能钉在转圈', (tester) async {
    SyncEngine.aiFastTimeoutForTest = const Duration(milliseconds: 80);
    addTearDown(SyncEngine.resetAiTimeoutsForTest);
    final engine = makeEngine(_HangingTransport());
    addTearDown(engine.dispose);

    await tester.binding.setSurfaceSize(const Size(414, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: SyncScope(
        engine: engine,
        child: const AiSettingsPage(),
      ),
    ));
    // 先确认确实进了加载态（转圈在屏上）
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    // 推过超时预算：闸门必须触发 → catch → 错误文案
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('读不到服务端配置'), findsOneWidget);
  });
}
