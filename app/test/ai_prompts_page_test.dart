import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/data/sync/sync_engine.dart';
import 'package:zaoji/data/sync/sync_prefs.dart';
import 'package:zaoji/data/sync/sync_scope.dart';
import 'package:zaoji/data/sync/sync_transport.dart';
import 'package:zaoji/ui/ai_prompts_page.dart';

import 'fake_sync_server.dart';

/// R44 · 提示词管理页（客户端侧）。
///
/// 钉的是**编辑→校验→落库→回落**这条接线：
/// ① 进页拉 /api/ai/prompts，三能力分段渲染，占位符 chips 就位；
/// ② 改文本点保存 → POST 带 feature+system+user → 成功后打「已修改」；
/// ③ 服务端拒存（bad_placeholder）→ 原话回显，不误报成功；
/// ④ 恢复默认 → POST reset → 整页重读回内置模板；
/// ⑤ 点占位符 chip 把 token 插进当前编辑框。
void main() {
  late FakeSyncServer server;
  late RecipeStore store;
  late SyncPrefs prefs;

  setUpAll(() async => server = await FakeSyncServer.start());
  tearDownAll(() async => server.close());

  setUp(() async {
    server.reset();
    server.accessMode = 'open';
    server.aiConfigured = true;
    server.aiEnabled = true;
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
    prefs = SyncPrefs(store.dbOrNull!);
    await prefs.setServerUrl(server.url);
  });

  tearDown(() async {
    await store.dbOrNull!.close();
    store.dispose();
  });

  SyncEngine makeEngine() => SyncEngine(
        db: store.dbOrNull!,
        prefs: prefs,
        transport:
            HttpSyncTransport(Uri.parse(server.url), nodeId: 'testnode01'),
      );

  Future<SyncEngine> pump(WidgetTester tester) async {
    FakeSyncServer.allowRealHttp();
    final engine = makeEngine();
    await tester.binding.setSurfaceSize(const Size(414, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => SyncScope(
        engine: engine,
        child: StoreScope(store: store, child: child!),
      ),
      home: const AiPromptsPage(),
    ));
    return engine;
  }

  Future<void> waitUntil(WidgetTester tester, bool Function() done,
      {int seconds = 8}) async {
    final until = DateTime.now().add(Duration(seconds: seconds));
    while (!done() && DateTime.now().isBefore(until)) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  testWidgets('进页拉取：三能力分段 + 占位符 chips 渲染', (tester) async {
    final engine = await pump(tester);
    await waitUntil(tester,
        () => find.byKey(const ValueKey('prompt-save-calories')).evaluate().isNotEmpty);

    expect(find.text('热量估算'), findsOneWidget);
    expect(find.text('菜谱补全'), findsOneWidget);
    expect(find.text('菜品推荐'), findsOneWidget);
    // calories 的三个必填占位符 chip 都在
    expect(find.byKey(const ValueKey('ph-calories-{{ingredients}}')), findsOneWidget);
    // 未修改时不显示「恢复默认」
    expect(find.byKey(const ValueKey('prompt-reset-calories')), findsNothing);
    engine.dispose();
  });

  testWidgets('改文本 → 保存：POST 带三字段，成功后标「已修改」', (tester) async {
    final engine = await pump(tester);
    await waitUntil(tester,
        () => find.byKey(const ValueKey('prompt-save-calories')).evaluate().isNotEmpty);

    await tester.enterText(
        find.byKey(const ValueKey('prompt-system-calories')), '热量估算器 {{name}}');
    await tester.enterText(find.byKey(const ValueKey('prompt-user-calories')),
        '菜名：{{name}} {{servings}} {{ingredients}}');
    await tester.tap(find.byKey(const ValueKey('prompt-save-calories')));
    await waitUntil(tester, () => server.aiPromptSaves.isNotEmpty);

    final sent = server.aiPromptSaves.single;
    expect(sent['feature'], 'calories');
    expect('${sent['system']}', contains('热量估算器'));
    expect(find.text('已修改'), findsWidgets);
    expect(find.byKey(const ValueKey('prompt-reset-calories')), findsOneWidget);
    engine.dispose();
  });

  testWidgets('服务端拒存（缺占位符）→ 回显原话，不误报', (tester) async {
    server.aiPromptReject = true;
    final engine = await pump(tester);
    await waitUntil(tester,
        () => find.byKey(const ValueKey('prompt-save-calories')).evaluate().isNotEmpty);

    await tester.tap(find.byKey(const ValueKey('prompt-save-calories')));
    await waitUntil(tester,
        () => find.textContaining('缺少必填占位符').evaluate().isNotEmpty);

    expect(find.textContaining('缺少必填占位符'), findsWidgets);
    // 没落库 → 不显示「已修改」标（因为服务端没接受）
    expect(find.byKey(const ValueKey('prompt-reset-calories')), findsNothing);
    engine.dispose();
  });

  testWidgets('恢复默认 → POST reset → 重读回落内置模板', (tester) async {
    // 先预置一条覆盖，让「恢复默认」按钮可见
    server.aiPromptOverrides['calories'] = {
      'system': '旧的覆盖 {{name}} {{servings}} {{ingredients}}',
      'user': '{{name}}',
    };
    final engine = await pump(tester);
    await waitUntil(tester,
        () => find.byKey(const ValueKey('prompt-reset-calories')).evaluate().isNotEmpty);

    await tester.tap(find.byKey(const ValueKey('prompt-reset-calories')));
    // reset 后 _load 整页重读；等 system 框文本回落成内置默认才算真到位
    await waitUntil(tester, () {
      final f = find.byKey(const ValueKey('prompt-system-calories'));
      if (f.evaluate().isEmpty) return false;
      return tester.widget<TextField>(f).controller!.text == '你是家庭菜谱的热量估算器';
    });

    expect(server.aiPromptResets, greaterThanOrEqualTo(1));
    expect(server.aiPromptOverrides.containsKey('calories'), isFalse);
    final field = tester.widget<TextField>(
        find.byKey(const ValueKey('prompt-system-calories')));
    expect(field.controller!.text, '你是家庭菜谱的热量估算器');
    engine.dispose();
  });

  testWidgets('点占位符 chip → token 插进 user 编辑框', (tester) async {
    final engine = await pump(tester);
    await waitUntil(tester,
        () => find.byKey(const ValueKey('prompt-save-calories')).evaluate().isNotEmpty);

    // 先把光标定位到 user 框并清空
    await tester.tap(find.byKey(const ValueKey('prompt-user-calories')));
    await tester.enterText(
        find.byKey(const ValueKey('prompt-user-calories')), '');
    await tester.tap(find.byKey(const ValueKey('ph-calories-{{ingredients}}')));
    await tester.pump();

    final field = tester.widget<TextField>(
        find.byKey(const ValueKey('prompt-user-calories')));
    expect(field.controller!.text, contains('{{ingredients}}'));
    engine.dispose();
  });
}
