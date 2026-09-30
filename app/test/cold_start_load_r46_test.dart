import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/models.dart';

/// R46 · 冷启动加载回归（钉住 R45 那一族）。
///
/// **为什么这个文件必须存在**：R45 报的是「AI 估算结果重启后不见了」，实际根因是
/// `_doInit` 从来没加载 nutrition / pantry / shopping 三张内存表，而它们只在
/// `reload()` 里被填——`reload()` 又只有同步引擎在「本轮真有增量」时才调。
/// 于是没有增量的冷启动后：热量卡回落按钮态、厨房库存显示空态、购物清单空态，
/// **三处一起**，而 sqlite 与服务端一行数据都没丢。
///
/// 判据是「真重载」：开**第二个 store 实例**吃同一个库，等于用户杀掉 App 再打开。
/// 只断言「库里有行」会假绿——那正是这个 bug 混过测试的方式。
void main() {
  test('冷启动（新建 store 实例、不跑同步）→ 热量/库存/购物清单三处都还在', () async {
    final executor = NativeDatabase.memory();
    final a = RecipeStore(executor: executor);
    await a.ready();

    final rid = a.recipes.first.id;
    await a.saveNutrition(
      rid,
      const NutritionDraft(
        perServingKcal: 250,
        totalKcal: 1000,
        proteinG: 18,
        fatG: 12,
        carbG: 30,
        source: 'ai',
        model: 'deepseek-flash',
        servingsBasis: 4,
      ),
    );
    await a.upsertPantry(name: '番茄', qtyValue: 4, qtyUnit: '个');
    await a.addShoppingItems(const [
      (name: '鸡蛋', qtyText: '1 盒', recipeId: null)
    ], source: 'prep');

    // 基线：第一个实例里三处都在（写入路径自己会更新内存，这一步不算证据）
    expect(a.nutritionFor(rid)?.perServingKcal, 250);
    expect(a.pantryItems, isNotEmpty);
    expect(a.shoppingItems, isNotEmpty);

    // ★ 真正的判据：**第二个实例**，同一条库，没有任何同步发生
    final b = RecipeStore(executor: executor);
    await b.ready();
    expect(b.nutritionFor(rid)?.perServingKcal, 250,
        reason: 'R45：冷启动后营养行没进内存表 → 详情页与徽标双双空');
    expect(b.nutritionFor(rid)?.source, 'ai');
    expect(b.pantryItems.map((p) => p.name), contains('番茄'),
        reason: '同一条链：_loadPantry 也从未在 _doInit 里被调用');
    expect(b.shoppingItems.map((s) => s.name), contains('鸡蛋'),
        reason: '同一条链：_loadShopping 同上');

    await a.dbOrNull!.close();
    b.dispose();
  });

  test('手填的热量也一样要活过冷启动（FR-AI-69/70 不只是 AI 那条路）', () async {
    final executor = NativeDatabase.memory();
    final a = RecipeStore(executor: executor);
    await a.ready();
    final rid = a.recipes.first.id;

    await a.saveNutrition(
      rid,
      const NutritionDraft(
        perServingKcal: 120,
        totalKcal: 720,
        source: 'manual',
        servingsBasis: 6,
      ),
    );

    final b = RecipeStore(executor: executor);
    await b.ready();
    final n = b.nutritionFor(rid);
    expect(n?.isManual, isTrue);
    expect(n?.perServingKcal, 120);
    expect(n?.servingsBasis, 6, reason: '份数基数是手改后自己记住的（Q6）');

    await a.dbOrNull!.close();
    b.dispose();
  });
}
