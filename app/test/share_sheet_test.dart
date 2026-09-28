import 'package:drift/native.dart';
// models 的 Step（菜谱步骤）与 material 的 Step（向导步）撞名——详情页系测试都藏后者。
import 'package:flutter/material.dart' hide Step;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/share_text.dart';
import 'package:zaoji/data/store_scope.dart';
import 'package:zaoji/models.dart';
import 'package:zaoji/ui/menu_detail_page.dart';
import 'package:zaoji/ui/prep_page.dart';
import 'package:zaoji/ui/recipe_detail_page.dart';
import 'package:zaoji/ui/share_sheet.dart';

/// R34 · 分享面板与三个入口（FR-SHARE-03/04/01）。
///
/// 文本本身的账面与红线在 share_text_test.dart 钉死；这里只验**面板行为**：
/// 勾选实时反映到预览（FR-SHARE-04 的验收标准就是这条）、复制真的进剪贴板、
/// 三个入口都点得开。图片载体/系统分享面板不在本轮（见交接文档 R34 尾巴）。
void main() {
  late RecipeStore store;

  setUp(() async {
    store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
  });

  tearDown(() async {
    await store.dbOrNull!.close();
    store.dispose();
  });

  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.binding.setSurfaceSize(const Size(540, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(StoreScope(
      store: store,
      child: MaterialApp(home: page),
    ));
    await tester.pumpAndSettle();
  }

  /// 剪贴板 mock：测试里读不到系统剪贴板，只能截 Flutter 侧的调用。
  final List<String> clipboard = [];
  void mockClipboard() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add(((call.arguments as Map)['text'] ?? '') as String);
      }
      return null;
    });
  }

  testWidgets('勾选实时反映到预览；关掉署名尾巴就没了（FR-SHARE-04）', (tester) async {
    await pump(tester, const HomePage());
    await tester.tap(find.byKey(const ValueKey('home-open-share')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('share-preview')), findsOneWidget);
    expect(find.textContaining('【番茄炒蛋】'), findsOneWidget);
    expect(find.textContaining('— 食材（2 人份）—'), findsOneWidget);
    expect(find.textContaining(kShareSignature), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('share-t-ing')));
    await tester.pumpAndSettle();
    expect(find.textContaining('— 食材（2 人份）—'), findsNothing);
    expect(find.textContaining('【番茄炒蛋】'), findsOneWidget,
        reason: '只关掉一块，其余照旧');

    await tester.tap(find.byKey(const ValueKey('share-t-sig')));
    await tester.pumpAndSettle();
    expect(find.textContaining('灶记'), findsNothing);
  });

  testWidgets('复制进剪贴板的是预览里那段全文', (tester) async {
    mockClipboard();
    await pump(tester, const HomePage());
    await tester.tap(find.byKey(const ValueKey('home-open-share')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('share-copy')));
    await tester.pumpAndSettle();

    expect(clipboard, hasLength(1));
    expect(clipboard.single, contains('【番茄炒蛋】'));
    expect(clipboard.single, isNot(contains('http')), reason: 'FR-SHARE-07 红线');
    expect(find.text('已复制'), findsOneWidget);
    expect(find.byKey(const ValueKey('share-hint')), findsOneWidget);
  });

  testWidgets('菜谱详情顶栏 → 面板：热量块只在有估算时出现', (tester) async {
    final r = await store.createRecipe(RecipeDraft(
      name: '葱油拌面',
      ingredients: const [IngredientDraft(name: '小葱', qty: '2 根')],
      steps: const ['煮面 4 分钟'],
    ));
    await pump(tester, RecipeDetailPage(recipe: r));
    await tester.tap(find.byKey(const ValueKey('detail-share')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('share-t-kcal')), findsNothing,
        reason: '没估过热量就不摆一个勾了也没内容的块');
    expect(find.byKey(const ValueKey('share-t-ing')), findsOneWidget);
    expect(find.textContaining('葱油拌面'), findsWidgets);

    // 先收起面板再估热量——面板盖着顶栏，二次 tap 打在遮罩上（这颗坑同款见过一次）。
    Navigator.of(tester.element(find.byKey(const ValueKey('share-preview')))).pop();
    await tester.pumpAndSettle();
    await store.saveNutrition(
        r.id, const NutritionDraft(perServingKcal: 300, totalKcal: 600));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('detail-share')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('share-t-kcal')), findsOneWidget);
    final preview = tester.widget<SelectableText>(
        find.byKey(const ValueKey('share-preview')));
    expect(preview.data, contains('每份 ≈ 300 千卡'));
    expect(preview.data, contains('整锅约 600 千卡'));
  });

  testWidgets('菜单详情顶栏 → 面板带【周六 · 晚餐】抬头', (tester) async {
    final r = await store.createRecipe(RecipeDraft(name: '蚝油生菜'));
    final m = await store.createMenu(day: '2026-09-26', meal: '晚餐', serveAt: '18:30');
    await store.addDish(m.id, r.id);
    await pump(tester, MenuDetailPage(menuId: m.id));

    await tester.tap(find.byKey(const ValueKey('menu-share')));
    await tester.pumpAndSettle();
    // 抬头/开饭时间/菜名都从预览文本里读——页面本身也显示 18:30，按文案找会撞。
    final preview = tester.widget<SelectableText>(
        find.byKey(const ValueKey('share-preview')));
    expect(preview.data, contains('【周六 · 晚餐】'));
    expect(preview.data, contains('18:30 开饭'));
    expect(preview.data, contains('· 蚝油生菜'));
  });

  testWidgets('备菜屏 → 面板逐行 ☐，已排除/已备齐的不进产物', (tester) async {
    final r = await store.createRecipe(RecipeDraft(
      name: '番茄炒蛋',
      ingredients: const [
        IngredientDraft(name: '番茄', qty: '2 个'),
        IngredientDraft(name: '鸡蛋', qty: '3 个'),
      ],
    ));
    final m = await store.createMenu(day: '2026-09-26', meal: '晚餐');
    await store.addDish(m.id, r.id);
    final lines = store.mergeForPrep([r.id]);
    await store.setPrepDone(m.id, lines.first.key, true);
    await store.setPrepExcluded(m.id, lines[1].key, true);

    await pump(tester, PrepPage(menuId: m.id));
    await tester.tap(find.byKey(const ValueKey('prep-share')));
    await tester.pumpAndSettle();

    final preview = tester.widget<SelectableText>(
        find.byKey(const ValueKey('share-preview')));
    final text = preview.data!;
    expect(text, contains('备菜清单'));
    expect(text, isNot(contains('番茄')), reason: '已备齐的不进买菜清单');
    expect(text, isNot(contains('鸡蛋')), reason: '已排除的更不该出现');
  });
}

/// 面板本身的宿主页：给一个固定的分享载荷，专测面板行为。
class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static final recipe = Recipe(
    id: 'x',
    name: '番茄炒蛋',
    sub: '十五分钟的家常底味',
    difficulty: 1,
    selfTime: 10,
    servings: 2,
    ingredients: const [Ingredient('番茄', '2 个'), Ingredient('鸡蛋', '3 个')],
    steps: const [Step('鸡蛋打散，静置 3 分钟。')],
    notes: '番茄要选熟透的',
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Builder(builder: (context) => ElevatedButton(
              key: const ValueKey('home-open-share'),
              onPressed: () => showShareSheet(
                context,
                title: recipe.name,
                filename: '灶记-${recipe.name}.txt',
                toggles: const [
                  ShareToggle('ing', '食材'),
                  ShareToggle('sig', '署名'),
                ],
                buildText: (on) => shareRecipe(
                  recipe: recipe,
                  servings: 2,
                  withIngredients: on.contains('ing'),
                  withSignature: on.contains('sig'),
                ),
              ),
              child: const Text('open'),
            )),
      ),
    );
  }
}
