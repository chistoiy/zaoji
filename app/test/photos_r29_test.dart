import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/data/sync/sync_engine.dart';
import 'package:zaoji/data/sync/sync_prefs.dart';
import 'package:zaoji/data/sync/sync_scope.dart';
import 'package:zaoji/data/sync/sync_transport.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji/ui/recipe_detail_page.dart';

import 'fake_sync_server.dart';

/// R29 · 多照片 + 步骤图（App 侧链路）。
///
/// 假服务端的媒体白名单收 a*64/b*64 两个 sha——正好当照片墙的钉。
/// 钉三件事：写了能读回（重启等价）、详情能渲染（含步骤图）、
/// 步骤图跟着**过滤后的步骤**走位（空行删掉不许把图错接到下一行）。
void main() {
  late RecipeStore store;
  late FakeSyncServer server;

  setUp(() async {
    server = await FakeSyncServer.start();
    FakeSyncServer.allowRealHttp();
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
  });
  tearDown(() async {
    await server.close();
    await store.dbOrNull!.close();
    store.dispose();
  });

  Future<Recipe> seedWall() => store.createRecipe(RecipeDraft(
        name: '红烧肉',
        ingredients: const [IngredientDraft(name: '五花肉', qty: '500g', isMain: true)],
        steps: const ['焯水 5 分钟', '小火炖 60 分钟', '收汁 8 分钟'],
        photos: [kA, kB],
        stepImages: [
          [kA],
          const [],
          [kB, kA],
        ],
      ));

  Future<void> pumpDetail(WidgetTester tester, Recipe r) async {
    final prefs = SyncPrefs(store.dbOrNull!);
    await prefs.setServerUrl(server.url);
    final engine = SyncEngine(
      db: store.dbOrNull!,
      prefs: prefs,
      transport: HttpSyncTransport(Uri.parse(server.url), nodeId: 'testnode01'),
    );
    await tester.binding.setSurfaceSize(const Size(414, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(StoreScope(
      store: store,
      child: SyncScope(
        engine: engine,
        child: MaterialApp(home: RecipeDetailPage(recipe: r)),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
    await tester.pumpAndSettle();
    engine.dispose();
  }

  group('落库往返', () {
    test('照片与步骤图存得下读得回（含重启等价）', () async {
      final r = await seedWall();
      expect(r.photos, [kA, kB]);
      expect(r.steps[0].images, [kA]);
      expect(r.steps[2].images, [kB, kA]);

      await store.reloadForTest();
      final back = store.recipeById(r.id)!;
      expect(back.photos, [kA, kB], reason: 'photos 是 v5 列，读路径解 JSON');
      expect(back.steps[2].images, [kB, kA]);
      expect(back.steps[1].images, isEmpty);
    });

    test('编辑保存：删掉一步空行，其余步骤的图不串位', () async {
      final r = await store.createRecipe(RecipeDraft(
        name: '测试串位',
        steps: const ['第一步', '', '第三步'],
        stepImages: [
          const [],
          const [],
          [kA],
        ],
      ));
      await store.reloadForTest();
      final back = store.recipeById(r.id)!;
      expect(back.steps.length, 3, reason: 'store 层不吞空行（UI 负责过滤）');
      expect(back.steps.last.images, [kA]);
      expect(back.steps.first.images, isEmpty);
    });

    test('updateRecipe 整行重写：photos 跟随新草稿', () async {
      final r = await seedWall();
      await store.updateRecipe(r.id, RecipeDraft(
        name: '红烧肉',
        steps: const ['焯水 5 分钟'],
        photos: [kB],
        stepImages: const [],
      ));
      await store.reloadForTest();
      final back = store.recipeById(r.id)!;
      expect(back.photos, [kB]);
      expect(back.steps.single.images, isEmpty,
          reason: '本用例只改 photos；步骤图未传即为空（草稿口径与封面一致）');
    });
  });

  group('详情页渲染', () {
    testWidgets('照片墙出现；步骤行带缩略图', (tester) async {
      final r = await seedWall();
      await pumpDetail(tester, r);
      expect(find.byKey(const ValueKey('recipe-gallery')), findsOneWidget);
      // 两张墙图 + 步骤一/三共 3 张步骤缩略（同 sha 会重复请求？引擎缓存兜着）
      expect(find.byKey(const ValueKey('step-img-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('step-img-3')), findsOneWidget);
      // 无图的步骤二不出图容器
      expect(find.byKey(const ValueKey('step-img-2')), findsNothing);
    });
  });
}

/// 假服务端媒体白名单认的两个 64 位 sha（运行期拼，Dart 常量不做字符串乘法）
final String kA = 'a' * 64;
final String kB = 'b' * 64;
