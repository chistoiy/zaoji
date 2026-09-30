import 'dart:async';

import 'package:drift/drift.dart' show QueryExecutor;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import 'data/alert_scope.dart';
import 'data/meal_reminder.dart';
import 'data/net_wake.dart';
import 'data/timer_alert.dart';
import 'data/pantry_watch.dart';
import 'data/recipe_store.dart';
import 'data/screen_wake.dart';
import 'data/store_scope.dart';
import 'data/sync/sync_engine.dart';
import 'data/sync/sync_prefs.dart';
import 'data/sync/sync_scope.dart';
import 'data/sync/token_vault.dart';
import 'data/timer_board.dart';
import 'data/timer_scope.dart';
import 'data/wake_scope.dart';
import 'ui/timer_overlay.dart';
import 'theme.dart';
import 'ui/home_shell.dart';
import 'ui/members_page.dart';
import 'ui/recipe_detail_page.dart';
import 'ui/theme_page.dart';

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
  const ZaojiApp({
    super.key,
    this.store,
    this.executor,
    this.timers,
    this.wake,
    this.alert,
    this.pantry,
    this.meal,
    this.net,
  });

  /// 测试注入完整的 store。生产为 null。
  final RecipeStore? store;

  /// 测试注入执行器（常配 `NativeDatabase.memory()`）。生产为 null。
  final QueryExecutor? executor;

  /// R47 · 测试注入**带假时钟的计时台**。
  ///
  /// 为什么它要能注入：`testWidgets` 的 FakeAsync 只推 Timer 与 Future，
  /// **不推 `DateTime.now()`**。所以「球上的读数会随时间变小」这件事
  /// 在默认注入下永远验不了（`pump(1s)` 后读数是原样的，看着像 bug）。
  /// 把时钟做成可注入，测试就能真的「拨快 10 分钟」再推一帧。
  final TimerBoard? timers;

  /// R47 · 测试注入**假拨锁**的常亮记账本（FR-COOK-09）。
  ///
  /// 为什么它要能注入：`wakelock_plus` 是静态方法通道调用，widget 测试区里
  /// 没有插件实现，真调会 `MissingPluginException` 把不相干的用例炸掉；
  /// 而这一路真正要断的是**命令序列**（谁登记了、第几次真的拨锁）。
  /// 生产为 null，走真实插件。
  final ScreenWake? wake;

  /// R47 · 测试注入**假发送**的通知闸门（FR-COOK-14）。
  ///
  /// 与 `wake` 同一个理由：插件在测试区没有通道实现，而这一段真正要断的是
  /// 「没授权一条都不发 / 关掉通知不发 / 声音关掉时 sound=false」这三道闸门。
  final TimerAlert? alert;

  /// R47 · 测试注入的库存提醒检查器（FR-PAN-04）。
  ///
  /// 不注入的话它自己从 store 取库存、从 [alert] 取闸门——真要断的是
  /// 「同一天第二次打开不再发」「本机通知开关关掉就不发」这两条口径，
  /// 而那些用假 items/假戳就能测，不必把真库存灌进用例。
  final PantryWatch? pantry;

  /// R47 · 测试注入的开饭前投待办检查器（FR-PLAN-09 + FR-SET-01）。
  ///
  /// 与 [pantry] 同一个理由：真要断的是「进窗口才投、一天每餐一次、开关关掉就不投」
  /// 这几条口径，用假 menus/假戳就能测，不必把真菜单灌进用例。
  final MealReminderWatch? meal;

  /// R47 · 测试注入的网络恢复监听（需求书 §9.2 S1）。
  ///
  /// 为什么必须能注入：`Connectivity()` 依赖平台通道，测试区构造订阅就会抛
  /// `MissingPluginException`；而这一路真正要断的是**边沿判定与合并**
  /// （首事件不算恢复、没断过不算恢复、窗口内多次上升沿只同步一次），
  /// 那些用一条假流就能测（与 [pantry] / [alert] 同一个理由）。
  final NetWake? net;

  @override
  State<ZaojiApp> createState() => _ZaojiAppState();
}

class _ZaojiAppState extends State<ZaojiApp> with WidgetsBindingObserver {
  late final RecipeStore _store =
      widget.store ?? RecipeStore(executor: widget.executor);

  /// 同步引擎。在 store 就绪后创建（依赖同一个底层库）；
  /// 测试注入的 store 走同一条路径。
  SyncEngine? _sync;
  bool _autoSyncScheduled = false;

  /// R47 · 厨房计时台：跨页面活着的多计时器。
  /// 跟着这棵树创建、跟着这棵树销毁（不做全局单例，理由见 `timer_scope.dart`）；
  /// 测试可注入带假时钟的板子（理由见 [ZaojiApp.timers] 的头注）。
  ///
  /// **震动闸门走 FR-SET-03 的偏好**：用户在设置页关掉「计时结束震动」，
  /// 到点就真的不震——开关必须是开关，不能只是个装饰。
  late final TimerBoard _timers = widget.timers ??
      TimerBoard(vibrate: () {
        if (!_store.kitchenPrefs.vibrateOn) return false;
        HapticFeedback.vibrate();
        return true;
      });

  /// R47 · 屏幕常亮的记账本（FR-COOK-09）。两路各登记一次：
  /// `cook` 由做菜模式自己管（进屏 need / 离屏 done），
  /// `timer` 由这里跟着计时台的状态走——**有在走的表就亮，全停/全关就撤**。
  /// 为什么不在 UI 里两头拨：那会出现「计时器跑完把灯关了，人还在做菜模式」，
  /// 引用计数正是为了让谁都不能替对方决定灭屏（见 `screen_wake.dart` 头注）。
  late final ScreenWake _wake = widget.wake ?? ScreenWake();

  /// R47 · 计时结束的通知闸门（FR-COOK-14）。
  /// 授权态由它自己管：Android 启动时读得到真值，Web 读不到就保持 unknown，
  /// 设置页那一行「开启系统通知授权」只在 unknown/denied 时出现（`me_page.dart`）。
  late final TimerAlert _alert = widget.alert ?? TimerAlert();

  /// 到点的那一批往通知栏发。**先过本机开关**（FR-SET-03 的通知/声音两路），
  /// 再过 `TimerAlert` 里的授权闸门——两道门各管各的，任何一道关着都不该发出去。
  void _onTimersFired(List<KitchenTimer> fired) {
    if (!_store.kitchenPrefs.notifyOn) return;
    unawaited(_alert.fire(fired, sound: _store.kitchenPrefs.soundOn));
  }

  /// 插件初始化 + 读授权态。失败只留痕不响：通知发不出去不该让 App 起不来。
  Future<void> _initAlert() async {
    try {
      await TimerAlert.setupPlugin();
    } catch (_) {
      // 桌面预览、测试区、以及个别没通道的运行环境都走这里。
    }
    await _alert.init();
    // ★ 库存提醒（FR-PAN-04）等库存表读到位再跑：`_loadPantry` 在 `_doInit` 末尾，
    //   抢跑的话 pantryItems 还是空的，等于每次冷启动都"没东西可提醒"。
    try {
      await _store.ready();
    } catch (_) {
      // 库起不来时启动流程自己会报错，这里不该再叠一条异常。
      return;
    }
    await _pantry.checkAndNotify();
    // ★ 开饭前投待办（FR-PLAN-09）与库存提醒同一个时机：菜单表也已经在 `_doInit` 里读完了。
    //   两条各管各的闸门，一条被挡不影响另一条。
    await _meal.checkAndNotify();
  }

  /// R47 · 库存到期与临期的提醒（FR-PAN-04 的推送时机）。
  /// 触发点是「打开 App / 回前台」，同一天只发一次（去重戳在 local_pref）。
  late final PantryWatch _pantry = widget.pantry ??
      PantryWatch(
        items: () => _store.pantryItems,
        alert: _alert,
        notifyEnabled: () => _store.kitchenPrefs.expiryNotifyOn,
        lastNotifiedDay: () => _store.expiryNotifiedDay,
        markNotified: _store.markExpiryNotified,
      );

  /// R47 · 开饭前把当餐的备菜与制作投进待办（FR-PLAN-09 + FR-SET-01）。
  ///
  /// **派生、不建表**（用户拍定的方向）：摘要现算自 `mergeForPrep` 与各道菜的步骤，
  /// 所以这里一行 schema 都没动，也就不欠「apk 与 exe 同发」。
  /// 触发点与库存提醒同两处（打开 App / 回前台），后台排程是 M3 的架构账。
  late final MealReminderWatch _meal = widget.meal ??
      MealReminderWatch(
        menus: () => _store.menus,
        digestOf: (m) => digestOfMenu(_store, m),
        alert: _alert,
        // 本机那枚开关（FR-SET-01）；系统授权闸门在 TimerAlert.send 里再过一道。
        enabled: () => _store.kitchenPrefs.mealReminderOn,
        leadMinutes: () => _store.kitchenPrefs.mealLeadMinutes,
        alreadyNotified: _store.mealReminderNotified,
        markNotified: _store.markMealReminderNotified,
      );

  /// R47 · 网络恢复即同步（需求书 §9.2 S1「飞行模式新增 → 恢复网络自动同步」）。
  ///
  /// 写同步的四条触发线（防抖 3s / 退避 ≤8 次 / 15 分钟兜底 / 启动一次）里没有一条
  /// 听得见「网通了」这个事件：飞行模式里退避几分钟就烧完，之后只能等兜底或手动。
  /// 这一路补上那只耳朵，恢复时走的是同一个 `syncIfPaired`（未配对仍是安静 no-op）。
  late final NetWake _net = widget.net ??
      NetWake(
        streamOf: connectivityStream,
        onOnline: () => _sync?.syncIfPaired(),
      );

  void _syncWake() {
    if (_timers.hasRunning) {
      _wake.need('timer');
    } else {
      _wake.done('timer');
    }
  }

  /// 导航器钥匙：悬浮计时球要插在 **root Overlay** 上才能跨路由活着，
  /// 而 root Overlay 只有拿着这个钥匙才摸得到（`TimerOverlay` 用）。
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  late final TimerOverlay _timerOverlay = TimerOverlay(
    board: _timers,
    navigatorKey: _navKey,
    // FR-SET-02：关掉悬浮窗就真的不插 entry（不是「看得见但点不动」的假关闭）。
    // 监听 store：偏好翻转时球要立刻出现/收掉。
    visible: () => _store.kitchenPrefs.timerFloatOn,
    visibilityListenable: _store,
  );

  /// 写入后的 3 秒防抖 timer——连续写入时不打断，而是重置倒计时。
  Timer? _writeDebounce;

  /// 已配对时维持的 15 分钟兜底同步（计划书 §5.4 的最后一块）。
  /// 由 [_onSyncPhaseChanged] 按引擎状态增减——未配对的 app 永远不会有
  /// 挂着的兜底 Timer（widget 测试的 FakeAsync 纪律：收尾时不能留 Timer）。
  Timer? _fallbackTimer;

  /// 同步失败后的退避重试（一次性，间隔来自引擎的 backoffDelay）。
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // init 在测试的 FakeAsync 区里被调用并完成——这是刻意的，
    // 在真实区（比如 setUpAll）完成的话，测试区永远等不到它（见 store_scope.dart）。
    _store.init();
    // 计时台一起步就把「有没有在走的表」翻译成常亮登记（FR-COOK-09 的第二路）。
    _timers.addListener(_syncWake);
    _syncWake();
    // 到点提醒接通知那一路（FR-COOK-14）。写在 initState 而不是构造函数里：
    // 板子可能是测试注入的（那时它的构造早跑完了），只能事后接。
    _timers.onFired = _onTimersFired;
    unawaited(_initAlert());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _writeDebounce?.cancel();
    _fallbackTimer?.cancel();
    _retryTimer?.cancel();
    _sync?.removeListener(_onSyncPhaseChanged);
    // 自己创建的 store 由自己关（关库）；测试注入的归测试管。
    // 之前漏了这一步，生产路径上本地库从来没有被关过。
    if (widget.store == null) {
      _sync?.dispose();
      _store.dispose();
    }
    // 先摘悬浮球（它往 root Overlay 插 entry），再停心跳。
    _timerOverlay.detach();
    // 常亮：先撤掉自己那一路（'timer'），再无条件收干净并关灯——
    // App 都退了，留着一个不会自己释手的 wakelock 是耗电 bug。
    _timers.removeListener(_syncWake);
    _timers.onFired = null;
    _wake.releaseAll();
    // 计时台里有周期 Timer：自己创建的才自己关（注入的归测试管，同 store 那条口径）。
    if (widget.timers == null) _timers.dispose();
    // 网络监听：自己创建的才自己关（去抖那个一次性 Timer 也在它自己手里收）。
    if (widget.net == null) unawaited(_net.dispose());
    if (widget.wake == null) _wake.dispose();
    if (widget.alert == null) _alert.dispose();
    super.dispose();
  }

  /// 回前台时拉一次（用户可能在后台期间被别的设备推了数据）。
  ///
  /// 顺带把库存提醒也过一遍（FR-PAN-04）：厨房里「切出去看购物 App 再回来」很常见，
  /// 这一路不重发也是安全的——同一天已经提醒过会被 local_pref 戳挡掉。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_sync != null) _sync!.syncIfPaired();
      unawaited(_pantry.checkAndNotify());
      // 切出去看一眼购物 App 再回来，正好可能已经进了开饭前的窗口。
      // 会不会重发由本机戳决定（每餐一次），所以这一路是安全的。
      unawaited(_meal.checkAndNotify());
    }
  }

  /// 创建同步引擎（只一次）。等 store 就绪后由 build 分支调用。
  SyncEngine _ensureSync() {
    if (_sync != null) return _sync!;

    // R19④：Android 上 token 落 Keystore（vault），Web 上为 null = 沿用 local_pref。
    final prefs = SyncPrefs(
      _store.dbOrNull!,
      vault: vaultForCurrentPlatform(),
    );
    final sync = SyncEngine(
      db: _store.dbOrNull!,
      prefs: prefs,
      // 拉到新数据后刷新内存缓存——页面经 ListenableBuilder 消费 store，
      // reload 里的 notifyListeners 会让列表/详情自动重画（R12 铺的路）。
      onDataApplied: _store.reload,
    );
    _sync = sync;

    // ★ R14 写路径 → 同步的接线：
    //   nodeId 从 SyncPrefs 取（引擎和 prefs 用同一个 db，安全）
    //   onLocalWrite 排 3 秒防抖——不阻塞 UI，连续写入只触发一次 sync
    _store.nodeIdGetter = prefs.nodeId;
    _store.onLocalWrite = _scheduleDebouncedSync;

    // R15：兜底与退避都挂在这一根线上（见 _onSyncPhaseChanged）。
    sync.addListener(_onSyncPhaseChanged);

    // R47 · S1：引擎有了才开网络监听的耳朵（恢复时喊的就是它的 syncIfPaired）。
    // start 是幂等的，_ensureSync 只会走到这里一次。
    _net.start();

    return sync;
  }

  /// 兜底与退避的统一接线路（计划书 §5.4 的收尾）：
  ///
  /// - **15 分钟兜底**：引擎离开 neverPaired（= 已配对）就维持一个周期同步，
  ///   unpair 回到 neverPaired 时自动撤掉。挂在引擎状态上而不是自己记一份
  ///   「是否配对」，是因为状态只有引擎一个事实源。
  /// - **退避自动重试**：phase=error 且 shouldAutoRetry（连续失败 < 8 次）
  ///   时排一次 backoffDelay；成功或解封后取消。duration.zero 的失败
  ///   （协议版本不一致 / 服务器身份变更）不排——它们要人介入，
  ///   自动重试只会空转；backoffDelay 的 365 天哨兵值也不排（= 8 次已封顶）。
  void _onSyncPhaseChanged() {
    final sync = _sync;
    if (sync == null) return;

    if (sync.phase != SyncPhase.neverPaired) {
      _fallbackTimer ??= Timer.periodic(
        const Duration(minutes: 15),
        (_) => _sync?.syncIfPaired(),
      );
    } else {
      _fallbackTimer?.cancel();
      _fallbackTimer = null;
    }

    _retryTimer?.cancel();
    _retryTimer = null;
    if (sync.phase == SyncPhase.error && sync.shouldAutoRetry) {
      final delay = sync.backoffDelay();
      if (delay > Duration.zero && delay < const Duration(days: 365)) {
        _retryTimer = Timer(delay, () => _sync?.syncIfPaired());
      }
    }
  }

  /// 3 秒防抖：每次写入重置 timer，空闲满 3 秒才真的触发 sync。
  /// 保存表单 = 一次写入，排一次；编辑时连续改 5 个字段 = 排一次。
  void _scheduleDebouncedSync() {
    _writeDebounce?.cancel();
    _writeDebounce = Timer(const Duration(seconds: 3), () {
      _sync?.syncIfPaired();
    });
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
        // 验收用的 URL 覆盖：`?theme=night` 直接以某套主题启动。
        // 与 `?a11y=1` 同一类工装——逐屏走查五套主题时不必每次手点三下。
        // 它走 setTheme，所以会像用户手选一样落库（这是有意的：验的就是真状态）。
        final urlTheme = Uri.base.queryParameters['theme'];
        if (urlTheme != null && _store.themeId != urlTheme) {
          _store.setTheme(urlTheme);
        }
        // 首帧后自动同步一次（未配对时是安静 no-op）。
        // 放 postFrame：不在 build 流程里发网络请求。**只排一次**——
        // build 可能因各种原因重跑，每次都排就变成「每次重建都全量同步」。
        if (!_autoSyncScheduled) {
          _autoSyncScheduled = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            sync.syncIfPaired();
            // 悬浮球挂在 navigator 的 root Overlay 上，第一次 build 之后才存在。
            // 它自己会跟着计时台开关：没表的时候树上根本不多一个 entry。
            _timerOverlay.attach();
          });
        }
        return SyncScope(
          engine: sync,
          // ★ 计时台挂在 MaterialApp **外面**：弹层与悬浮球都是从 navigator 推出来的路由，
          //   挂在页面里它们取不到 board（R46 同一条教训）。
          child: TimerScope(
            board: _timers,
            // 常亮记账本与计时台同层：做菜模式是从 navigator 推上来的一屏，
            // 挂在页面里它取不到（同 TimerScope 那条 R46 教训）。
            child: WakeScope(
              wake: _wake,
              // 通知闸门同样挂 MaterialApp 之上：设置页要点「开启系统通知授权」，
              // 那是从 navigator 里推出来的页面上做的事。
              child: AlertScope(
                alert: _alert,
                child: StoreScope(
              store: _store,
              // R39：主题是本机偏好，换它要重建整棵 MaterialApp 才能传到每一页。
              // 监听 store 而不是另起一个 ValueNotifier——偏好只有一个事实源。
              child: ListenableBuilder(
                listenable: _store,
                builder: (context, _) => MaterialApp(
              title: '灶记',
              debugShowCheckedModeBanner: false,
              navigatorKey: _navKey,
              theme: buildZaojiTheme(_store.tokens),
              initialRoute: initialRouteFromUrl(),
              routes: {
                // 主页 = 带底部标签栏的外壳，菜谱库是它的第一页
                '/': (_) => const HomeShell(),
                '/menus': (_) => const HomeShell(initialTab: 1),
                '/calendar': (_) => const HomeShell(initialTab: 3),
              },
              onGenerateRoute: _generateRoute,
            ),
            ),
          ),
          ),
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

  // 两张独立页也开深链：它们平时只能从「我的」点进去，
  // 逐屏验收（截真产物）和排查"换肤后某页有没有漏接令牌"都要能直达。
  if (name == '/members') {
    return MaterialPageRoute(
        builder: (_) => const MembersPage(), settings: settings);
  }
  if (name == '/theme') {
    return MaterialPageRoute(
        builder: (_) => const ThemePage(), settings: settings);
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
              Icon(Icons.search_off, size: 40, color: context.zj.muted),
              const SizedBox(height: 14),
              Text(
                '菜谱 $id 不在手边',
                style: TextStyle(fontSize: 15, color: context.zj.ink),
              ),
              const SizedBox(height: 6),
              // 链接可能来自另一端同步过来的、你还没拉到的菜谱——
              // 所以这句话要给下一步动作，而不是只说"不存在"
              Text(
                '可能是还没从服务端同步下来',
                style: TextStyle(fontSize: 12.5, color: context.zj.muted),
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.of(
                  context,
                ).pushNamedAndRemoveUntil('/', (route) => false),
                style: FilledButton.styleFrom(
                  backgroundColor: context.zj.accent,
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
/// ★ 这两屏渲染在 MaterialApp 之外，没有 Theme 祖先，所以取色一律走
///   [ZaojiTokens.fallback]（`context.zj` 在这儿会直接抛断言）。
/// 但 Web 首次要拉 sqlite3.wasm（731 KB），给一个同风格的过渡。
class _Booting extends StatelessWidget {
  const _Booting();

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: ZaojiTokens.fallback.paper,
        child: Center(
          child: SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: ZaojiTokens.fallback.accent,
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
        color: ZaojiTokens.fallback.paper,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline,
                  size: 36,
                  color: ZaojiTokens.fallback.warn,
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
                  style: TextStyle(
                    fontSize: 11,
                    color: ZaojiTokens.fallback.muted,
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
