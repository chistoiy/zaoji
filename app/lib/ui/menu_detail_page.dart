import 'package:flutter/material.dart';

import '../data/recipe_store.dart';
import '../data/store_scope.dart';
import '../theme.dart';
import 'menus_page.dart';
import 'prep_page.dart';
import 'recipe_detail_page.dart';

/// 菜单详情（R23）：这一餐的菜 + 加菜/移除 + 一键备菜入口。
class MenuDetailPage extends StatelessWidget {
  const MenuDetailPage({super.key, required this.menuId});

  final String menuId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZaojiColors.paper,
      appBar: AppBar(
        title: const Text('这一餐'),
        backgroundColor: ZaojiColors.paper,
        actions: [
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
            style: FilledButton.styleFrom(backgroundColor: ZaojiColors.accent),
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
      return const Center(
        child: Text('这个菜单已经不存在了',
            style: TextStyle(fontSize: 13, color: ZaojiColors.muted)),
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
                style: ZaojiText.display(
                    fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                [
                  if (menu.serveAt.isNotEmpty) '${menu.serveAt} 开饭',
                  '${menu.recipeIds.length} 道菜',
                ].join(' · '),
                style: const TextStyle(
                    fontSize: 12, color: ZaojiColors.muted),
              ),
              if (menu.note.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(menu.note,
                    style: const TextStyle(
                        fontSize: 12.5, color: ZaojiColors.ink2)),
              ],
              const SizedBox(height: 16),
              for (final id in menu.recipeIds) _dishRow(context, store, id),
              OutlinedButton.icon(
                key: const ValueKey('dish-add'),
                onPressed: () => _pickDish(context, menu),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加菜品到这一餐'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: ZaojiColors.accent,
                  alignment: Alignment.centerLeft,
                  side: const BorderSide(color: ZaojiColors.line),
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
                  backgroundColor: ZaojiColors.accent,
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
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(ZaojiRadius.lg),
        border: Border.all(color: ZaojiColors.lineSoft),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.only(left: 14, right: 6),
        title: Text(r?.name ?? '（已删除的菜）',
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w600)),
        subtitle: r == null
            ? null
            : Text('${r.selfTime} 分钟 · 做过 ${r.cookedCount} 次',
                style:
                    const TextStyle(fontSize: 11.5, color: ZaojiColors.muted)),
        onTap: r == null
            ? null
            : () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => RecipeDetailPage(recipe: r)),
                ),
        trailing: IconButton(
          key: ValueKey('dish-remove-$recipeId'),
          icon: const Icon(Icons.close, size: 19),
          color: ZaojiColors.muted,
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
      backgroundColor: ZaojiColors.paper,
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
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('菜谱库里的菜都在这餐里了',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12.5, color: ZaojiColors.muted)),
                    ),
                  // 最新创建的菜排最前——刚做完的菜最可能马上进菜单。
                  for (final r in candidates.reversed)
                    ListTile(
                      key: ValueKey('pick-${r.id}'),
                      dense: true,
                      title: Text(r.name,
                          style: const TextStyle(fontSize: 14)),
                      subtitle: Text(
                          '${r.ingredients.length} 样食材 · ${r.selfTime} 分钟',
                          style: const TextStyle(
                              fontSize: 11.5, color: ZaojiColors.muted)),
                      onTap: () {
                        Navigator.pop(ctx);
                        store.addDish(menu.id, r.id);
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
