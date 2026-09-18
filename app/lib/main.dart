import 'package:drift/drift.dart' show QueryExecutor;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'data/recipe_store.dart';
import 'data/store_scope.dart';
import 'data/sync/sync_engine.dart';
import 'data/sync/sync_prefs.dart';
import 'data/sync/sync_scope.dart';
import 'theme.dart';
import 'ui/home_shell.dart';
import 'ui/recipe_detail_page.dart';

void main() {
  // 查询参数 `?a11y=1` 强制启用语义树（放 query 而不是 fragment——
  // fragment 是路由的一部分，会被深链解析当成路径）。
  // Flutter Web 平时只画 Canvas，DOM 里没有可点的节点——自动化验证
  // （sync_e2e.cjs：配对→同步→验证）需要可寻址的语义树；对无障碍体检也长久有用。
  // ★ 必须先 ensureInitialized：binding 未初始化时 SemanticsBinding.instance
  //   是 null，直接调 ensureSemantics 会在启动时崩（profile 构建实测抓到的栈）。
  WidgetsFlutterBinding.ensureInitialized();
  if (Uri.base.queryParameters.containsKey('a11y')) {
    SemanticsBinding.instance.ensureSemantics();
  }
  runApp(const ZaojiApp());
}

class ZaojiApp extends StatefulWidget {
  const ZaojiApp({super.key, this.store, this.executor});

  /// 测试注入完整的 store。生产为 null。
  final RecipeStore? store;

  /// 测试注入执行器（常配 `NativeDatabase.memory()`）。生产为 null。
  final QueryExecutor? executor;

  @override
  State<ZaojiApp> createState() => _ZaojiAppState();
}

class _ZaojiAppState extends State<ZaojiApp> {
  late final RecipeStore _store =
      widget.store ?? RecipeStore(executor: widget.executor);

  /// 同步引擎。在 store 就绪后创建（依赖同一个底层库）；
  /// 测试注入的 store 走同一条路径。
  SyncEngine? _sync;
  bool _autoSyncScheduled = false;

  @override
  void initState() {
    super.initState();
    // init 在测试的 FakeAsync 区里被调用并完成——这是刻意的，
    // 在真实区（比如 setUpAll）完成的话，测试区永远等不到它（见 store_scope.dart）。
    _store.init();
  }

  @override
  void dispose() {
    // 自己创建的 store 由自己关（关库）；测试注入的归测试管。
    // 之前漏了这一步，生产路径上本地库从来没有被关过。
    if (widget.store == null) {
      _sync?.dispose();
      _store.dispose();
    }
    super.dispose();
  }

  /// 创建同步引擎（只一次）。等 store 就绪后由 build 分支调用。
  SyncEngine _ensureSync() {
    return _sync ??= SyncEngine(
      db: _store.dbOrNull!,
      prefs: SyncPrefs(_store.dbOrNull!),
      // 拉到新数据后刷新内存缓存——页面经 ListenableBuilder 消费 store，
      // reload 里的 notifyListeners 会让列表/详情自动重画（R12 铺的路）。
      onDataApplied: _store.reload,
    );
  }

  @override
  Widget build(BuildContext context) {
    // ★ 数据就绪前不创建 MaterialApp：initialRoute 的深链解析
    //   （`#/recipe/r1`）要从库里找菜谱，库里没数据时会把用户甩到 404 页。
    return FutureBuilder<void>(
      future: _store.ready(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const _Booting();
        }
        if (snap.hasError) {
          return _BootError(error: '${snap.error}');
        }
        final sync = _ensureSync();
        // 首帧后自动同步一次（未配对时是安静 no-op）。
        // 放 postFrame：不在 build 流程里发网络请求。**只排一次**——
        // build 可能因各种原因重跑，每次都排就变成「每次重建都全量同步」。
        if (!_autoSyncScheduled) {
          _autoSyncScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            sync.syncIfPaired();
          });
        }
        return SyncScope(
          engine: sync,
          child: StoreScope(
            store: _store,
            child: MaterialApp(
              title: '灶记',
              debugShowCheckedModeBanner: false,
              theme: buildZaojiTheme(),
              initialRoute: initialRouteFromUrl(),
              routes: {
                // 主页 = 带底部标签栏的外壳，菜谱库是它的第一页
                '/': (_) => const HomeShell(),
              },
              onGenerateRoute: _generateRoute,
            ),
          ),
        );
      },
    );
  }
}

/// 从 URL 的 fragment 取初始路由。
///
/// 为什么要这个：这是**唯一的验收手段**。服务端托管的是静态产物，
/// 想在 iPhone 视口下直接截到某一屏（而不是靠手点），就得能用 URL 直达。
/// 原型阶段已经定下这套约定（`#screen=recipe-detail&id=r2`），这里沿用它的思路，
/// 但用更标准的路径形式：`#/recipe/r1`。
///
/// 用 `Uri.base.fragment` 而不是 query/path，是因为服务端对深层路径做了 SPA 回退，
/// 用 fragment 可以少一次往返，而且刷新不会 404。
String initialRouteFromUrl() {
  final raw = Uri.base.fragment;
  if (raw.isEmpty) return '/';
  final path = raw.startsWith('/') ? raw : '/$raw';
  return path;
}

Route<dynamic>? _generateRoute(RouteSettings settings) {
  final name = settings.name ?? '/';

  final match = RegExp(r'^/recipe/(.+)$').firstMatch(name);
  if (match != null) {
    final id = match.group(1)!;
    return MaterialPageRoute(
      builder: (_) => _RecipeDetailLoader(id: id),
      settings: settings,
    );
  }

  return null; // 交给默认的 404 处理
}

/// 深链进入详情时先从库里找菜谱，找不到给「去哪儿」而不是一句"不存在"。
class _RecipeDetailLoader extends StatelessWidget {
  const _RecipeDetailLoader({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    final recipe = StoreScope.of(context).recipeById(id);
    if (recipe != null) return RecipeDetailPage(recipe: recipe);
    return _NotFound(id: id);
  }
}

class _NotFound extends StatelessWidget {
  const _NotFound({required this.id});

  final String id;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('找不到这道菜')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.search_off, size: 40, color: ZaojiColors.muted),
              const SizedBox(height: 14),
              Text(
                '菜谱 $id 不在手边',
                style: const TextStyle(fontSize: 15, color: ZaojiColors.ink),
              ),
              const SizedBox(height: 6),
              // 链接可能来自另一端同步过来的、你还没拉到的菜谱——
              // 所以这句话要给下一步动作，而不是只说"不存在"
              const Text(
                '可能是还没从服务端同步下来',
                style: TextStyle(fontSize: 12.5, color: ZaojiColors.muted),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.of(
                  context,
                ).pushNamedAndRemoveUntil('/', (route) => false),
                style: FilledButton.styleFrom(
                  backgroundColor: ZaojiColors.accent,
                ),
                child: const Text('回到菜谱库'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 启动画面：本地库打开 + 建表 + 灌种子通常毫秒级，
/// 但 Web 首次要拉 sqlite3.wasm（731 KB），给一个同风格的过渡。
class _Booting extends StatelessWidget {
  const _Booting();

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: ZaojiColors.paper,
        child: const Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: ZaojiColors.accent,
            ),
          ),
        ),
      ),
    );
  }
}

class _BootError extends StatelessWidget {
  const _BootError({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: ZaojiColors.paper,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 36,
                  color: ZaojiColors.warn,
                ),
                const SizedBox(height: 12),
                const Text(
                  '本地数据库打不开',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    color: ZaojiColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
