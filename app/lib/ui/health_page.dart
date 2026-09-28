import 'package:flutter/material.dart';

import '../data/health_models.dart';
import '../data/recipe_store.dart';
import '../data/store_scope.dart';
import '../theme.dart';
import 'kitchen_page.dart';
import 'recipe_list_page.dart';

/// 数据体检（R33）：账本自查一页清。
///
/// 判定全在 `health_models.dart` 的纯函数里，这层只做三件事：
/// 从 store 取料（含两份异步原始料）、排版、按组跳转。
/// 监听 store——改完一条问题回来数字自动跟上，不为体检单开刷新通道。
class HealthPage extends StatefulWidget {
  const HealthPage({super.key});

  @override
  State<HealthPage> createState() => _HealthPageState();
}

class _HealthPageState extends State<HealthPage> {
  List<HealthIssue>? _issues;
  bool _loading = false;
  bool _pending = false;
  RecipeStore? _listened;

  RecipeStore get _store => StoreScope.of(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final store = _store;
    if (_listened != store) {
      _listened?.removeListener(_onStore);
      store.addListener(_onStore);
      _listened = store;
    }
    if (_issues == null) _load();
  }

  @override
  void dispose() {
    _listened?.removeListener(_onStore);
    super.dispose();
  }

  /// 改完一条问题回来，账要重算——异步料（会话/时刻表）只听 notify 拿不到，
  /// 必须重查；_loading 闩 + _pending 补偿：加载期间到达的通知不会丢。
  void _onStore() {
    if (_loading) {
      _pending = true;
      return;
    }
    _load();
  }

  Future<void> _load() async {
    _loading = true;
    final store = _store;
    final opens = await store.openCookSessions();
    final ages = await store.shoppingItemAges();
    final now = DateTime.now();
    final zombies = [
      for (final s in opens)
        if (DateTime.tryParse(s.startedAt) != null)
          ZombieSession(
            recipeId: s.recipeId,
            recipeName:
                store.recipeById(s.recipeId)?.name ?? '（已删除的菜）',
            startedAt: DateTime.parse(s.startedAt),
          ),
    ];
    final issues = healthIssues(
      recipes: store.recipes,
      pantry: store.pantryItems,
      shopping: store.shoppingItems,
      zombies: zombies,
      shoppingAges: ages,
      now: now,
    );
    if (!mounted) {
      _loading = false;
      return;
    }
    setState(() => _issues = issues);
    _loading = false;
    if (_pending) {
      _pending = false;
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    return Scaffold(
      backgroundColor: context.zj.paper,
      appBar: AppBar(
        title: const Text('数据体检'),
        backgroundColor: context.zj.paper,
      ),
      body: ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final issues = _issues;
          if (issues == null) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          if (issues.isEmpty) {
            return Center(
              child: Text('账本没有要紧的事',
                  key: ValueKey('health-allclear'),
                  style: TextStyle(fontSize: 13, color: context.zj.muted)),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 32),
            children: [
              for (final it in issues) _issueCard(it),
            ],
          );
        },
      ),
    );
  }

  Widget _issueCard(HealthIssue it) {
    return Material(
      color: context.zj.surface,
      borderRadius: BorderRadius.circular(ZaojiRadius.md),
      child: InkWell(
        key: ValueKey('health-${it.key}'),
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => switch (it.target) {
                  HealthTarget.kitchen => const KitchenPage(),
                  HealthTarget.recipeList => const RecipeListPage(),
                  HealthTarget.shopping => const KitchenPage(initialSegment: 2),
                })),
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(ZaojiRadius.md),
            border: Border.all(color: context.zj.lineSoft),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(it.title,
                        style: const TextStyle(
                            fontSize: 13.5, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    Text(it.detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: context.zj.muted)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text('${it.count}',
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: context.zj.accent)),
            ],
          ),
        ),
      ),
    );
  }
}
