import 'package:flutter/material.dart';

import '../data/store_scope.dart';
import '../models.dart';
import '../theme.dart';

/// 回收站：列出被软删除的菜谱，支持恢复。
///
/// 删除不物理删（避免别的设备收不到墓碑），恢复也走新 HLC 章
/// （让同步引擎看到「恢复」这个真实写入）。
class TrashPage extends StatefulWidget {
  const TrashPage({super.key});

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  List<Recipe> _deleted = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final store = StoreScope.of(context);
    final list = await store.listDeleted();
    if (!mounted) return;
    setState(() {
      _deleted = list;
      _loading = false;
    });
  }

  Future<void> _restore(Recipe r) async {
    final store = StoreScope.of(context);
    await store.restoreRecipe(r.id);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已恢复「${r.name}」')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZaojiColors.paper,
      appBar: AppBar(title: const Text('回收站')),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: ZaojiColors.accent),
            )
          : _deleted.isEmpty
          ? const _Empty()
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              itemCount: _deleted.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _TrashCard(
                recipe: _deleted[i],
                onRestore: () => _restore(_deleted[i]),
              ),
            ),
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
              decoration: const BoxDecoration(
                color: ZaojiColors.paper2,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.delete_outline,
                size: 30,
                color: ZaojiColors.muted,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              '回收站是空的',
              style: ZaojiText.display(
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '删掉的菜会暂时放在这里，可以恢复。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.7,
                color: ZaojiColors.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrashCard extends StatelessWidget {
  const _TrashCard({required this.recipe, required this.onRestore});
  final Recipe recipe;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(color: ZaojiColors.lineSoft),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  recipe.name,
                  style: ZaojiText.display(
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
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: ZaojiColors.muted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: onRestore,
            style: FilledButton.styleFrom(
              backgroundColor: ZaojiColors.accent,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            icon: const Icon(Icons.restore, size: 16),
            label: const Text('恢复'),
          ),
        ],
      ),
    );
  }
}
