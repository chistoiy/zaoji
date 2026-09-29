import 'package:flutter/material.dart';

import '../data/store_scope.dart';
import '../data/sync/sync_scope.dart';
import '../models.dart';
import '../theme.dart';

/// 回收站：列出被软删除的菜谱，支持恢复与永久删除（R43 · FR-DATA-13）。
///
/// 删除不物理删（避免别的设备收不到墓碑），恢复也走新 HLC 章
/// （让同步引擎看到「恢复」这个真实写入）。
///
/// 数据一律读 [RecipeStore.deletedItems]，页面自己不查库：
/// 一是与全站"store 是唯一真相 + 挂 ListenableBuilder"的规矩一致，
/// 二是这条查询走真库，Widget 测试的 FakeAsync 里 isolate 的回复进不来
/// ——第一版就是页面永远停在加载圈，测试找不到卡片。
///
/// 永久删除**必须先问服务端**（[SyncEngine.purgeRecipePermanently]）：
/// 只删本机这一份的话，别的设备回收站里那条还能恢复，一推就回来——
/// 对用户来说就是"我说删掉，它又冒出来"，比不删更糟。
class TrashPage extends StatefulWidget {
  const TrashPage({super.key});

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  Future<void> _restore(Recipe r) async {
    final store = StoreScope.of(context);
    await store.restoreRecipe(r.id);
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已恢复「${r.name}」')));
  }

  /// 永久删除：二次确认 → 服务端点头 → 本机物理删。
  /// 失败（没接入 / 连不上 / 被拒）把服务端或引擎给的原话显示出来，不编第二套话术。
  Future<void> _purge(Recipe r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('永久删除「${r.name}」？'),
        content: const Text(
            '这道菜的食材与步骤会从家里每一台设备上清掉，恢复不了。'
            '回收站里超过 30 天的条目也会按同样方式自动清掉。'),
        actions: [
          TextButton(
              key: const ValueKey('purge-cancel'),
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          TextButton(
            key: const ValueKey('purge-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('永久删除', style: TextStyle(color: ctx.zj.warn)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final engine = SyncScope.of(context);
    final err = await engine.purgeRecipePermanently(r.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(err == null ? '已永久删除「${r.name}」' : '没删成：$err'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final deleted = store.deletedItems;
        return Scaffold(
          backgroundColor: context.zj.paper,
          appBar: AppBar(title: const Text('回收站')),
          body: deleted.isEmpty
              ? const _Empty()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  itemCount: deleted.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _TrashCard(
                    recipe: deleted[i],
                    onRestore: () => _restore(deleted[i]),
                    onPurge: () => _purge(deleted[i]),
                  ),
                ),
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: context.zj.paper2,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.delete_outline,
                size: 30,
                color: context.zj.muted,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '回收站是空的',
              style: ZaojiText.displayOf(context, 
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '删掉的菜会暂时放在这里，可以恢复。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.7,
                color: context.zj.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrashCard extends StatelessWidget {
  const _TrashCard({
    required this.recipe,
    required this.onRestore,
    required this.onPurge,
  });
  final Recipe recipe;
  final VoidCallback onRestore;
  final VoidCallback onPurge;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.zj.surface,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(color: context.zj.lineSoft),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  recipe.name,
                  style: ZaojiText.displayOf(context, 
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  recipe.sub.isEmpty
                      ? '${recipe.ingredients.length} 种食材 · ${recipe.steps.length} 步'
                      : recipe.sub,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: context.zj.muted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          FilledButton.icon(
            key: ValueKey('trash-restore-${recipe.id}'),
            onPressed: onRestore,
            style: FilledButton.styleFrom(
              backgroundColor: context.zj.accent,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            icon: const Icon(Icons.restore, size: 16),
            label: const Text('恢复'),
          ),
          // 永久删除刻意做成**没有底色的文字按钮**，还不与「恢复」并排等高：
          // 两个动作的不可逆程度差着一个数量级，视觉上一样重就是怂恿误点。
          TextButton(
            key: ValueKey('trash-purge-${recipe.id}'),
            onPressed: onPurge,
            style: TextButton.styleFrom(
              foregroundColor: context.zj.muted,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('永久删除'),
          ),
        ],
      ),
    );
  }
}
