import 'package:flutter/material.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import '../data/recipe_store.dart';
import '../data/share_text.dart';
import '../data/store_scope.dart';
import '../theme.dart';
import '../widgets/allergen_bits.dart';
import 'menus_page.dart';
import 'prep_page.dart';
import 'recipe_detail_page.dart';
import 'share_sheet.dart';

/// 菜单详情（R23）：这一餐的菜 + 加菜/移除 + 一键备菜入口。
class MenuDetailPage extends StatelessWidget {
  const MenuDetailPage({super.key, required this.menuId});

  final String menuId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.zj.paper,
      appBar: AppBar(
        title: const Text('这一餐'),
        backgroundColor: context.zj.paper,
        actions: [
          // R34 · 文字分享（FR-SHARE-01 第二类）：这一餐的搭配发出去，不带任何链接。
          IconButton(
            key: const ValueKey('menu-share'),
            icon: const Icon(Icons.ios_share),
            tooltip: '分享这一餐',
            onPressed: () {
              final store = StoreScope.of(context);
              final m = store.menuById(menuId);
              if (m == null) return;
              final dishes = [
                for (final id in m.recipeIds)
                  if (store.recipeById(id) != null) store.recipeById(id)!,
              ];
              showShareSheet(
                context,
                title: '${m.day} · ${m.meal}',
                filename: '灶记-${m.day}-${m.meal}.txt',
                toggles: const [ShareToggle('sig', '署名')],
                buildText: (on) => shareMenu(
                  menu: m,
                  dishes: dishes,
                  withSignature: on.contains('sig'),
                ),
              );
            },
          ),
          IconButton(
            key: const ValueKey('menu-edit'),
            icon: const Icon(Icons.edit_outlined),
            tooltip: '编辑餐次',
            onPressed: () {
              final m = StoreScope.of(context).menuById(menuId);
              if (m != null) showMealForm(context, editing: m);
            },
          ),
          IconButton(
            key: const ValueKey('menu-delete'),
            icon: const Icon(Icons.delete_outline),
            tooltip: '删除菜单',
            onPressed: () => _confirmDelete(context),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: StoreScope.of(context),
        builder: (context, _) => _body(context),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final store = StoreScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这一餐？'),
        content: const Text('餐次和它记录的搭配会被删掉，菜谱本身不受影响。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            key: const ValueKey('menu-delete-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: context.zj.accent),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await store.deleteMenu(menuId);
      if (context.mounted) Navigator.of(context).pop();
    }
  }

  Widget _body(BuildContext context) {
    final store = StoreScope.of(context);
    final menu = store.menuById(menuId);
    if (menu == null) {
      // 在别的设备上被删了——这屏原地给自己一个体面的收场。
      return Center(
        child: Text('这个菜单已经不存在了',
            style: TextStyle(fontSize: 13, color: context.zj.muted)),
      );
    }
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              Text(
                '${dayLabel(menu.day)} · ${menu.meal}',
                key: const ValueKey('detail-title'),
                style: ZaojiText.displayOf(context, 
                    fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                [
                  if (menu.serveAt.isNotEmpty) '${menu.serveAt} 开饭',
                  '${menu.recipeIds.length} 道菜',
                ].join(' · '),
                style: TextStyle(
                    fontSize: 12, color: context.zj.muted),
              ),
              if (menu.note.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(menu.note,
                    style: TextStyle(
                        fontSize: 12.5, color: context.zj.ink2)),
              ],
              const SizedBox(height: 16),
              _MenuAllergenBanner(menu: menu, store: store),
              for (final id in menu.recipeIds) _dishRow(context, store, id),
              OutlinedButton.icon(
                key: const ValueKey('dish-add'),
                onPressed: () => _pickDish(context, menu),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加菜品到这一餐'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.zj.accent,
                  alignment: Alignment.centerLeft,
                  side: BorderSide(color: context.zj.line),
                ),
              ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const ValueKey('open-prep'),
                onPressed: menu.recipeIds.isEmpty
                    ? null
                    : () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => PrepPage(menuId: menuId)),
                        ),
                icon: const Icon(Icons.shopping_basket_outlined, size: 19),
                label: const Text('一键备菜'),
                style: FilledButton.styleFrom(
                  backgroundColor: context.zj.accent,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _dishRow(BuildContext context, RecipeStore store, String recipeId) {
    final r = store.recipeById(recipeId);
    final hits = r == null || !store.allergenWarnInRecipes
        ? const <AllergenHit>[]
        : store.allergenHitsFor(r);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: context.zj.surface,
        borderRadius: BorderRadius.circular(ZaojiRadius.lg),
        border: Border.all(color: context.zj.lineSoft),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 14, right: 6),
        title: Text(r?.name ?? '（已删除的菜）',
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: r == null
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${r.selfTime} 分钟 · 做过 ${r.cookedCount} 次',
                      style:
                          TextStyle(fontSize: 11.5, color: context.zj.muted)),
                  if (hits.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        key: ValueKey('dish-alert-$recipeId'),
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final h in hits)
                            AllergenTag(
                                who: h.memberName,
                                word: h.word,
                                allergy: h.isAllergy),
                        ],
                      ),
                    ),
                ],
              ),
        onTap: r == null
            ? null
            : () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => RecipeDetailPage(recipe: r)),
                ),
        trailing: IconButton(
          key: ValueKey('dish-remove-$recipeId'),
          icon: const Icon(Icons.close, size: 19),
          color: context.zj.muted,
          tooltip: '从这一餐移除',
          onPressed: () => store.removeDish(menuId, recipeId),
        ),
      ),
    );
  }

  Future<void> _pickDish(BuildContext context, MenuPlan menu) async {
    final store = StoreScope.of(context);
    final candidates = [
      for (final r in store.recipes)
        if (!menu.recipeIds.contains(r.id)) r,
    ];
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: context.zj.paper,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('选一道菜加进来',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                children: [
                  if (candidates.isEmpty)
                    Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('菜谱库里的菜都在这餐里了',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12.5, color: context.zj.muted)),
                    ),
                  // 最新创建的菜排最前——刚做完的菜最可能马上进菜单。
                  for (final r in candidates.reversed)
                    ListTile(
                      key: ValueKey('pick-${r.id}'),
                      dense: true,
                      title: Text(r.name,
                          style: const TextStyle(fontSize: 14)),
                      subtitle: () {
                        final h = store.allergenWarnInRecipes
                            ? store.allergenHitsFor(r)
                            : const <AllergenHit>[];
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                                '${r.ingredients.length} 样食材 · ${r.selfTime} 分钟',
                                style: TextStyle(
                                    fontSize: 11.5, color: context.zj.muted)),
                            if (h.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 5),
                                child: Wrap(
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: [
                                    for (final x in h)
                                      AllergenTag(
                                          who: x.memberName,
                                          word: x.word,
                                          allergy: x.isAllergy),
                                  ],
                                ),
                              ),
                          ],
                        );
                      }(),
                      onTap: () async {
                        // 在这道菜上要选的是「加不加」，所以先标出来再问一次；
                        // 问完仍留在弹层里，连着排几道菜不用反复开
                        final hits = store.allergenHitsFor(r);
                        if (store.allergenConfirmOnMenu &&
                            !await confirmAllergenAddToMenu(ctx,
                                hits: hits,
                                recipeName: r.name,
                                mealLabel: '${dayLabel(menu.day)} · ${menu.meal}')) {
                          return;
                        }
                        store.addDish(menu.id, r.id);
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                      },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 整餐的过敏原汇总横幅（照原型 `menuBanner`）。
///
/// 按「谁 · 对什么」合并，后面跟**涉及的菜名**——一餐里三道菜都含虾，
/// 拆成三行读起来像出了三次事，合并成一行才是「今晚这桌要换掉虾」。
class _MenuAllergenBanner extends StatelessWidget {
  const _MenuAllergenBanner({required this.menu, required this.store});

  final MenuPlan menu;
  final RecipeStore store;

  @override
  Widget build(BuildContext context) {
    final zj = context.zj;
    if (!store.allergenWarnInRecipes) return const SizedBox.shrink();
    final order = <String>[];
    final map = <String, _MenuConflict>{};
    for (final id in menu.recipeIds) {
      final r = store.recipeById(id);
      if (r == null) continue;
      for (final h in store.allergenHitsFor(r)) {
        if (!h.isAllergy) continue;
        final k = '${h.memberId}|${h.word}';
        if (!map.containsKey(k)) {
          order.add(k);
          map[k] = _MenuConflict(h.memberName, h.word, []);
        }
        if (!map[k]!.dishes.contains(r.name)) map[k]!.dishes.add(r.name);
      }
    }
    final groups = [for (final k in order) map[k]!];
    if (groups.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: AllergenBanner(
        title: '这一餐有 ${groups.length} 处过敏原冲突',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final g in groups)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text.rich(TextSpan(
                  style:
                      TextStyle(fontSize: 11.5, color: zj.ink2, height: 1.6),
                  children: [
                    TextSpan(
                        text: g.who,
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    TextSpan(text: ' 对「${g.word}」过敏 → 涉及 ${g.dishes.join('、')}'),
                  ],
                )),
              ),
          ],
        ),
      ),
    );
  }
}

class _MenuConflict {
  _MenuConflict(this.who, this.word, this.dishes);
  final String who;
  final String word;
  final List<String> dishes;
}
