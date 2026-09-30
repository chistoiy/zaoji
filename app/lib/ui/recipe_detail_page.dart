import 'package:flutter/material.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import '../data/share_text.dart';
import '../data/store_scope.dart';
import '../widgets/allergen_bits.dart';
import '../data/sync/sync_engine.dart';
import '../data/sync/sync_scope.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/chili_scale.dart';
import '../widgets/cover_image.dart';
import '../widgets/time_capsule_text.dart';
import 'ai_settings_page.dart';
import 'cooking_page.dart';
import 'menus_page.dart';
import 'recipe_edit_page.dart';
import 'share_sheet.dart';
import 'timer_sheet.dart';

/// 菜品详情。
///
/// 这一屏的核心不是「信息全」，而是**步骤读起来顺**——
/// 用户是站在灶台前看的，中间还插着锅。
/// 所以：食材在前（下锅前先对一遍）、步骤在后、注意事项收尾，
/// 而且步骤里的时间全部变成可以点的琥珀胶囊。
///
/// **R14：AppBar 加编辑 + 删除按钮。** 删除会弹确认 dialog，走软删除
/// （打墓碑而非物理删），同步引擎能把墓碑推到别的设备。
///
/// **R20：改为有状态并监听 store**——做过次数、编辑结果要即时反映
/// （旧实现拿的是 push 时传入的 Recipe 快照，做完菜回来数字还是旧的）；
/// 另加「开始做菜」入口与**本机未完成会话**的续做横幅。
class RecipeDetailPage extends StatefulWidget {
  const RecipeDetailPage({super.key, required this.recipe});

  final Recipe recipe;

  @override
  State<RecipeDetailPage> createState() => _RecipeDetailPageState();
}

class _RecipeDetailPageState extends State<RecipeDetailPage> {
  CookSession? _active;
  List<CookSession> _history = const [];
  bool _sessionLoadedOnce = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // StoreScope.of 不能在 initState 里调（InheritedWidget 查找的时机限制），
    // didChangeDependencies 是首次依赖就绪的地方。
    if (!_sessionLoadedOnce) {
      _sessionLoadedOnce = true;
      _loadSession();
    }
  }

  Future<void> _loadSession() async {
    final store = StoreScope.of(context);
    // 做过记录（FR-REC-13）与续做横幅同源：都在这一次刷新里取，
    // 做完菜回到详情页时两者一起变新，不各刷一次。
    final both = await Future.wait([
      store.activeCookingSession(widget.recipe.id),
      store.cookSessions(widget.recipe.id),
    ]);
    if (!mounted) return;
    setState(() {
      _active = both[0] as CookSession?;
      _history = both[1] as List<CookSession>;
    });
  }

  Future<void> _cook(Recipe recipe) async {
    await CookingPage.open(context, recipe);
    // 从做菜页回来（完成 / 中途退出）都要刷新横幅与计数
    await _loadSession();
  }

  /// 加入菜单（R23）：选一餐把这道菜加进去。addDish 幂等，连点不长两个行。
  ///
  /// R40：命中过敏原时先确认一次（FR-SET-04 的「排菜单时拦截」开关）。
  Future<void> _pickMenu(BuildContext context, Recipe recipe) async {
    final store = StoreScope.of(context);
    final menus = store.menus;
    final hits = store.allergenHitsFor(recipe);
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
              child: Text('加到哪一餐',
                  style:
                      TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
                children: [
                  for (final m in menus)
                    ListTile(
                      key: ValueKey('addmenu-${m.id}'),
                      dense: true,
                      title: Text('${dayLabel(m.day)} · ${m.meal}',
                          style: const TextStyle(fontSize: 14)),
                      subtitle: Text(
                          '${m.serveAt.isEmpty ? '' : '${m.serveAt} 开饭 · '}${m.recipeIds.length} 道菜',
                          style: TextStyle(
                              fontSize: 11.5, color: context.zj.muted)),
                      onTap: () async {
                        // 先确认再关弹层：反过来做的话确认框会挂在
                        // 已经消失的 ctx 上，表现为"点了一下没反应"
                        if (store.allergenConfirmOnMenu &&
                            !await confirmAllergenAddToMenu(ctx,
                                hits: hits,
                                recipeName: recipe.name,
                                mealLabel: '${dayLabel(m.day)} · ${m.meal}')) {
                          return;
                        }
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                        store.addDish(m.id, recipe.id);
                      },
                    ),
                  if (menus.isEmpty)
                    Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('还没有排过餐次——去「菜单」页先排一顿',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 12.5, color: context.zj.muted)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 分享面板：热量块**只在有估算时出现**（FR-SHARE-04 的勾选项跟着数据走），
  /// 默认勾选；署名按 FR-SHARE-10 可关（设置里全局关是尾巴，先就地关）。
  void _share(BuildContext context, Recipe recipe) {
    final store = StoreScope.of(context);
    final n = store.nutritionFor(recipe.id);
    showShareSheet(
      context,
      title: recipe.name,
      filename: '灶记-${recipe.name}.txt',
      toggles: [
        const ShareToggle('ing', '食材'),
        const ShareToggle('step', '步骤'),
        if (recipe.notes.trim().isNotEmpty) const ShareToggle('note', '注意'),
        if (n != null) const ShareToggle('kcal', '热量'),
        const ShareToggle('sig', '署名'),
      ],
      buildText: (on) => shareRecipe(
        recipe: recipe,
        servings: recipe.servings,
        nutritionLine: on.contains('kcal') && n != null
            ? '每份 ≈ ${n.perServingKcalRounded} 千卡 · 整锅约 ${n.totalKcalRounded} 千卡'
            : null,
        withIngredients: on.contains('ing'),
        withSteps: on.contains('step'),
        withNotes: on.contains('note'),
        withSignature: on.contains('sig'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // store 通知驱动重画：做菜计数、编辑、别的设备同步下来都会走到这里
    return ListenableBuilder(
      listenable: StoreScope.of(context),
      builder: (context, _) {
        final store = StoreScope.of(context);
        final recipe =
            StoreScope.of(context).recipeById(widget.recipe.id) ?? widget.recipe;
        // 警示开关关掉后四处都不标（FR-SET-04 的开关是全局的），
        // 但加菜单的拦截走另一个开关——那是"要不要问我一次"，不是"要不要标出来"
        final warnHits =
            store.allergenWarnInRecipes ? store.allergenHitsFor(recipe) : const <AllergenHit>[];
        return Scaffold(
          appBar: AppBar(
            title: Text(recipe.name),
            actions: [
              // R34 · 文字分享（FR-SHARE-01 第一类）：内容即产物，不带服务器链接。
              IconButton(
                key: const ValueKey('detail-share'),
                tooltip: '分享',
                onPressed: () => _share(context, recipe),
                icon: const Icon(Icons.ios_share),
              ),
              IconButton(
                tooltip: '开始做菜',
                onPressed: () => _cook(recipe),
                icon: const Icon(Icons.local_fire_department_outlined),
              ),
              IconButton(
                key: const ValueKey('add-to-menu'),
                tooltip: '加入菜单',
                onPressed: () => _pickMenu(context, recipe),
                icon: const Icon(Icons.event_outlined),
              ),
              IconButton(
                tooltip: '删除',
                onPressed: () => _confirmDelete(context),
                icon: const Icon(Icons.delete_outline),
              ),
              IconButton(
                tooltip: '编辑',
                onPressed: () => _edit(context, recipe),
                icon: const Icon(Icons.edit_outlined),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
            children: [
              if (_active != null) ...[
                const SizedBox(height: 10),
                _ResumeBanner(
                  session: _active!,
                  onResume: () => _cook(recipe),
                  onDiscard: () async {
                    await StoreScope.of(context)
                        .discardCooking(_active!.id);
                    await _loadSession();
                  },
                ),
                const SizedBox(height: 10),
              ],
              _Hero(recipe: recipe),
              const SizedBox(height: 16),
              // 无命中时横幅自己收成 0 尺寸，布局不跳版
              RecipeAllergenBanner(hits: warnHits),
              _NutritionBlock(recipe: recipe),
              if (recipe.photos.isNotEmpty) ...[
                const SizedBox(height: 18),
                _GalleryStrip(recipe: recipe),
              ],
              const SizedBox(height: 22),
              _SectionTitle(
                num: '01',
                title: '食材',
                trailing: '${recipe.servings} 人份',
              ),
              const SizedBox(height: 10),
              _IngredientTable(
                  ingredients: recipe.ingredients, hits: warnHits),
              const SizedBox(height: 26),
              const _SectionTitle(num: '02', title: '做法'),
              const SizedBox(height: 4),
              Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  '琥珀色的时间可以点一下直接起计时',
                  style: TextStyle(fontSize: 12, color: context.zj.muted),
                ),
              ),
              for (var i = 0; i < recipe.steps.length; i++)
                _StepRow(
                  index: i + 1,
                  text: recipe.steps[i].text,
                  images: recipe.steps[i].images,
                ),
              const SizedBox(height: 26),
              // FR-REC-13 · 原型 sec 05「每次做的时间」：次数之外还要看得见每次的时刻，
              // 不然「上周做过一次」这种判断只能靠记忆。
              _SectionTitle(
                num: '03',
                title: '每次做的时间',
                trailing: _history.isEmpty ? null : '最近 ${_history.length} 次',
              ),
              const SizedBox(height: 10),
              _CookHistory(sessions: _history),
              if (recipe.notes.trim().isNotEmpty) ...[
                const SizedBox(height: 26),
                const _SectionTitle(num: '04', title: '注意'),
                const SizedBox(height: 10),
                _Notes(text: recipe.notes),
              ],
            ],
          ),
        );
      },
    );
  }

  void _edit(BuildContext context, Recipe recipe) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => RecipeEditPage(recipe: recipe)));
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这道菜？'),
        content: const Text('删除后可以在「我的 → 回收站」里恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('再想想'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.zj.accentDeep,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    final store = StoreScope.of(context);
    final id = widget.recipe.id;
    final name = widget.recipe.name;
    await store.softDeleteRecipe(id);
    if (context.mounted) {
      // 成功删除后回到列表页（详情页里的菜谱已经不在了）
      Navigator.of(context).pop();
      final messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        // R43 · FR-DATA-14：删除后 5 秒内可撤销。
        // ★ `persist: false` 是必须的，`duration` 单独写不管用：
        //   SnackBar 的构造里 `persist = persist ?? action != null`
        //   ——**只要带了 action，框架就默认它要一直挂着**（怕撤销按钮跑掉），
        //   连 5 秒都不设，变成一条挂在列表上的横幅。
        //   本轮那条"5 秒到点自己收"的测试测的就是这个：只写 duration 时
        //   假时钟推到 7.5 秒条还在，补上 persist:false 才按点收。
        // 撤销就是"把墓碑擦掉"，走既有的 restoreRecipe（它会重新盖 HLC 并广播），
        // 所以 5 秒之后也不是不能恢复——只是得自己去回收站，兜的是手滑那一秒。
        SnackBar(
          key: const ValueKey('delete-undo-bar'),
          duration: const Duration(seconds: 5),
          persist: false,
          content: Text('已删除「$name」'),
          action: SnackBarAction(
            key: const ValueKey('delete-undo'),
            label: '撤销',
            onPressed: () async {
              // 撤销成功就别让"已删除"那条还杵在那儿：移除当前条，
              // 否则新的提示条要排队等它 5 秒超时才露脸（用户会以为没撤销成）。
              messenger.removeCurrentSnackBar();
              await store.restoreRecipe(id);
              messenger.showSnackBar(
                SnackBar(
                  key: const ValueKey('delete-undone'),
                  duration: const Duration(seconds: 2),
                  content: Text('已恢复「$name」'),
                ),
              );
            },
          ),
        ),
      );
    }
  }
}

/// 本机未完成会话的续做横幅（R20）。
/// 只列**自己设备**的进度——别的设备做到哪一步是它自己的事。
class _ResumeBanner extends StatelessWidget {
  const _ResumeBanner({
    required this.session,
    required this.onResume,
    required this.onDiscard,
  });

  final CookSession session;
  final VoidCallback onResume;
  final VoidCallback onDiscard;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.zj.amberBg,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(color: context.zj.amber.withValues(alpha: 0.4)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      child: Row(
        children: [
          Icon(Icons.local_fire_department,
              size: 18, color: context.zj.amber),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: onResume,
              child: Text(
                '继续做菜（第 ${session.currentStep + 1} 步）',
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: context.zj.amber,
                ),
              ),
            ),
          ),
          TextButton(
            onPressed: onDiscard,
            child: const Text('放弃', style: TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}

/// R27 · 热量区（FR-AI-20~28 + FR-REC-22/23）。
///
/// **R46 补上的是「手」——数据层从 R27 起就能写任意草稿，但入口只有一个：
/// AI 回调里的那次 `saveNutrition`。** 于是 FR-AI-24（结果可手动编辑）与
/// 验收 A6 一直不成立：数值没处填、AI 结果改不动、份数改了不折算。现在：
///
/// - **没数据**：两枚入口并排——「估算热量」+「手动填写热量」。手填入口**恒在**，
///   未配置 AI、能力关着、服务端不在线都能填（FR-AI-69）。估算那枚仍按 FR-AI-10
///   带「未配置」徽记，配与不配布局不跳版。
/// - **有数据**：AI 与手动态是**同一张卡的两种状态**，只换来源标、副标题、免责行
///   与第三枚按钮；手动态不挂「AI 估算，仅供参考」——数值是你自己填的，
///   再挂 AI 免责反而误导（Q4）。
/// - **看依据**：逐食材贡献 + 手改过的那版留着的 **AI 原值两段对照**（FR-AI-71）。
///   这一段以前只在 models 注释里被提到过，UI 从来没做。
class _NutritionBlock extends StatefulWidget {
  const _NutritionBlock({required this.recipe});

  final Recipe recipe;

  @override
  State<_NutritionBlock> createState() => _NutritionBlockState();
}

class _NutritionBlockState extends State<_NutritionBlock> {
  bool _busy = false;

  /// R46：打开手填/二次编辑弹层。保存动作在弹层里直接写库，
  /// 提示条**等弹层关掉之后**再挂——模态弹层压着页面 Scaffold，
  /// 在弹层里 showSnackBar 是看不见的（R44 那批记过这条框架陷阱）。
  Future<void> _openEdit() async {
    final saved = await _NutritionEditSheet.show(context, widget.recipe);
    if (saved != true || !mounted) return;
    final n = StoreScope.of(context).nutritionFor(widget.recipe.id);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(n == null
          ? '已保存'
          : '已保存 · 每份 ≈ ${n.perServingKcalRounded} 千卡，来源：${n.isManual ? '手动填写' : 'AI 估算'}'),
      duration: const Duration(seconds: 2),
    ));
  }

  /// R46：看依据（逐食材贡献 + AI 原值对照）。
  Future<void> _openBasis(Nutrition n) async {
    await _NutritionBasisSheet.show(context, widget.recipe, n);
  }

  Future<void> _estimate() async {
    final store = StoreScope.of(context);
    final engine = SyncScope.of(context);
    final r = widget.recipe;
    setState(() => _busy = true);
    void say(String msg, {bool goSettings = false}) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 3),
        action: goSettings
            ? SnackBarAction(
                label: '去配置',
                textColor: context.zj.onAccent,
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const AiSettingsPage()),
                ),
              )
            : null,
      ));
    }

    try {
      final res = await engine.aiCall('/api/ai/calories', {
        'name': r.name,
        'servings': r.servings,
        'ingredients': [
          for (final i in r.ingredients)
            {
              'name': i.name,
              'amount': i.qty,
              'kind': i.isMain ? 'main' : 'side',
            }
        ],
      });
      // R44：本机视角记一行（服务端的 ai_runs 才是权威留痕）。fire-and-forget，
      // 写失败绝不影响热量结果展示。
      final u = (res['usage'] as Map?)?.cast<String, Object?>() ?? const {};
      store.logAiRun(
        feature: 'calories',
        ok: res['ok'] == true,
        model: '${res['model'] ?? ''}',
        promptTokens: (u['prompt_tokens'] as num?)?.toInt() ?? 0,
        completionTokens: (u['completion_tokens'] as num?)?.toInt() ?? 0,
        runRef: res['runId'] == null ? null : '${res['runId']}',
        summary: r.name,
      );
      if (res['ok'] != true) {
        final msg = '${res['message'] ?? res['error'] ?? '估算失败'}';
        say(msg.contains('未启用') || res['error'] == 'off'
            ? 'AI 或「卡路里估算」未启用 · $msg'
            : msg);
        return;
      }
      final n = (res['result'] as Map).cast<String, Object?>();
      num d(Object? v) => v is num ? v : num.tryParse('$v') ?? 0;
      await store.saveNutrition(
        r.id,
        NutritionDraft(
          perServingKcal: d(n['kcal_per_serving']).toDouble(),
          totalKcal: d(n['total_kcal']).toDouble(),
          proteinG: d(n['protein_g']).toDouble(),
          fatG: d(n['fat_g']).toDouble(),
          carbG: d(n['carb_g']).toDouble(),
          // R46：依据统一走 NutritionBasis 编码（对象形状 {items, ai}），
          // 解码兼容 R27 那代存下来的**纯数组**老行——同步过来的数据不用迁。
          basisJson: NutritionBasis(
            items: [
              for (final e in (n['per_ingredient'] as List? ?? const []))
                if (e is Map) e.cast<String, Object?>()
            ],
          ).encode(),
          confidence:
              NutritionDraft.confidenceFromWire('${n['confidence']}'),
          source: 'ai',
          model: '${res['model'] ?? ''}',
          servingsBasis: r.servings,
        ),
      );
      if (!mounted) return;
      final kcal = d(n['kcal_per_serving']).round();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('估算完成 · 每份 ≈ $kcal 千卡'),
            duration: const Duration(seconds: 2)),
      );
    } catch (e) {
      final s = '$e';
      store.logAiRun(feature: 'calories', ok: false, summary: r.name);
      final notConfigured =
          s.contains('401') || s.contains('未配置') || s.contains('StateError');
      final off = s.contains('未启用') || s.contains('off');
      say(notConfigured
          ? '还没配置大模型，配好就能估算热量'
          : off
              ? '「卡路里估算」能力当前是关闭的，可在配置页打开'
              : '估算失败：$s', goSettings: notConfigured || off);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    // SyncScope 做成**可选依赖**：详情页在个别测试里是脱离引擎单独 pump 的
    // （R24 就有这情况），缺它只影响「未配置」徽标的显示，入口照常渲染。
    final engine =
        context.getInheritedWidgetOfExactType<SyncScope>()?.engine;
    final n = store.nutritionFor(widget.recipe.id);

    if (n == null) {
      final unconfigured =
          engine?.aiStatusCache != null && engine!.aiStatusCache!['configured'] != true;
      // 没算过：只显示入口，绝不画灰色占位数字（FR-AI-27）。
      // 但手填入口**恒在**——FR-AI-69：没配 AI 的人不该被挡在热量之外。
      return Wrap(
        key: const ValueKey('nutrition-entries'),
        spacing: 8,
        runSpacing: 8,
        children: [
          OutlinedButton.icon(
            key: const ValueKey('ai-calories-entry'),
            onPressed: _busy ? null : _estimate,
            icon: _busy
                ? SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: context.zj.ai))
                : Icon(Icons.auto_awesome, size: 16, color: context.zj.ai),
            label: Text(
              _busy
                  ? '正在估算…'
                  : unconfigured
                      ? '估算热量（未配置）'
                      : '估算热量',
              style: TextStyle(fontSize: 13, color: context.zj.ai),
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: context.zj.aiBg),
              backgroundColor: context.zj.aiBg,
            ),
          ),
          OutlinedButton.icon(
            key: const ValueKey('nutri-manual-entry'),
            onPressed: _busy ? null : _openEdit,
            icon: Icon(Icons.edit_outlined, size: 16, color: context.zj.ink2),
            label: Text('手动填写热量',
                style: TextStyle(fontSize: 13, color: context.zj.ink2)),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: context.zj.line),
            ),
          ),
        ],
      );
    }

    final basis = NutritionBasis.decode(n.basisJson);
    final echo = basis.ai;

    return Container(
      key: ValueKey(n.isManual ? 'nutrition-card-manual' : 'nutrition-card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.zj.surface,
        borderRadius: BorderRadius.circular(ZaojiRadius.lg),
        border: Border.all(color: n.isManual ? context.zj.line : context.zj.aiBg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                  n.isManual
                      ? Icons.edit_outlined
                      : Icons.auto_awesome, // 手动态用笔，不用星星（NFR-UX-03：不只靠颜色）
                  size: 14,
                  color: n.isManual ? context.zj.ink2 : context.zj.ai),
              const SizedBox(width: 6),
              Text(n.isManual ? '手动填写' : 'AI 估算',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: n.isManual ? context.zj.ink2 : context.zj.ai)),
              const Spacer(),
              // 手动态没有「把握度」这个概念——它是我们自己的数；改成写清按几人份算的
              Text(
                  n.isManual
                      ? '按 ${n.servingsBasisOrFallback} 人份'
                      : '把握度 ${n.confidenceLabel}',
                  key: const ValueKey('nutri-source-sub'),
                  style: TextStyle(fontSize: 11, color: context.zj.muted)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('≈ ${n.perServingKcalRounded}',
                  style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w700,
                      color: n.isManual ? context.zj.ink : context.zj.ai,
                      height: 1)),
              const SizedBox(width: 8),
              // Flexible：数字与说明文字共处一 Row，窄屏上必须让文字换行
              // 而不是把卡撑爆（widget 测试 414 宽实测溢出 52px 的教训）
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '千卡 / 每份 · 整锅约 ${n.totalKcalRounded} 千卡',
                    style: TextStyle(
                        fontSize: 12, color: context.zj.ink2),
                  ),
                ),
              ),
              if (n.isManual && echo?.perServingKcal != null)
                Flexible(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 3, left: 6),
                    child: Text(
                      '· AI 原估 ${echo!.perServingKcal!.round()}',
                      key: const ValueKey('nutri-ai-echo'),
                      style: TextStyle(
                          fontSize: 11,
                          color: context.zj.muted,
                          decoration: TextDecoration.lineThrough,
                          decorationColor: context.zj.line),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final e in [
                ('蛋白质', n.proteinG),
                ('脂肪', n.fatG),
                ('碳水', n.carbG),
              ])
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          e.$2 == null
                              ? '—'
                              : '${e.$2!.round()}g',
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w700)),
                      Text(e.$1,
                          style: TextStyle(
                              fontSize: 11, color: context.zj.muted)),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          // Q4 口径：手填的数不该再挂 AI 免责——数值是你自己填的，
          // 挂着「AI 估算，仅供参考」反而把责任指错了地方。
          Text(
            n.isManual
                ? (echo != null
                    ? '来源：手动填写 · AI 原值留在「看依据」里对照'
                    : '来源：手动填写')
                : '${n.model != null && n.model!.isNotEmpty ? '${n.model} · ' : ''}'
                    '来源：AI 估算。AI 估算，仅供参考，不能用于医疗或饮食处方。',
            style:
                TextStyle(fontSize: 10.5, color: context.zj.muted, height: 1.6),
          ),
          Wrap(
            spacing: 4,
            runSpacing: 0,
            alignment: WrapAlignment.end,
            children: [
              TextButton(
                key: const ValueKey('nutri-basis-btn'),
                onPressed: () => _openBasis(n),
                child: Text('看依据',
                    style: TextStyle(fontSize: 12, color: context.zj.ink2)),
              ),
              TextButton(
                key: const ValueKey('nutri-edit-btn'),
                onPressed: _busy ? null : _openEdit,
                child: Text('手动改',
                    style: TextStyle(fontSize: 12, color: context.zj.ink2)),
              ),
              TextButton(
                key: const ValueKey('nutri-calc-btn'),
                onPressed: _busy ? null : _estimate,
                child: Text(_busy
                    ? '正在重算…'
                    : n.isManual
                        ? '用 AI 重算'
                        : '重新估算',
                    style: TextStyle(fontSize: 12, color: context.zj.ai)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// R46 · 热量手填 / 二次编辑弹层（FR-AI-69~74）。
///
/// 三条实现约束都在这里落地：
/// ① **换算只在 [nutriApply]（shared）里做**——三个框互相推导，Web 与 Android
///    不可能算出两个数（NFR-MNT-01）；
/// ② 校验不过**用弹层内的行内提示**，不用 SnackBar：模态弹层压着页面 Scaffold，
///    那条提示挂上去看不见（R44 那批踩过的框架陷阱）；
/// ③ 超限值是**点保存那一刻**才点亮确认条——填上就拦等于把二次确认做成一次。
///
/// 返回 true = 已保存；null / false = 取消或没动。
class _NutritionEditSheet extends StatefulWidget {
  const _NutritionEditSheet({required this.recipe, required this.initial});

  final Recipe recipe;
  final Nutrition? initial;

  static Future<bool?> show(BuildContext context, Recipe recipe) async {
    final store = StoreScope.of(context);
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.zj.paper,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(ZaojiRadius.xl))),
      builder: (sheetContext) => Padding(
        // 弹层里的输入框必须自己吃键盘高度（Flutter 3.38 起 showModalBottomSheet
        // 不再自动抬升），否则「每份千卡」那个框在手机上被键盘盖住。
        padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom),
        child: _NutritionEditSheet(
            recipe: recipe, initial: store.nutritionFor(recipe.id)),
      ),
    );
    return saved;
  }

  @override
  State<_NutritionEditSheet> createState() => _NutritionEditSheetState();
}

class _NutritionEditSheetState extends State<_NutritionEditSheet> {
  late NutritionCalc _calc;
  late final TextEditingController _per;
  late final TextEditingController _total;
  late final TextEditingController _serv;
  late final TextEditingController _p;
  late final TextEditingController _f;
  late final TextEditingController _c;

  /// 二次确认已点亮（每份超 [kNutritionAbsurdPerServing]）。
  bool _armed = false;

  /// 校验/提示的行内文案（不用 SnackBar，见类注释②）。
  String? _hint;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final n = widget.initial;
    // Q6：基数默认跟菜谱份数；已有行记过自己的基数就用自己的（手改后独立记住）
    final serv = n?.servingsBasis ?? widget.recipe.servings;
    _calc = NutritionCalc(
      perServingKcal: n?.perServingKcal,
      totalKcal: n?.totalKcal,
      servings: nutriSanitizeServings(serv, fallback: 4),
    );
    String s(double? v) => v == null ? '' : '${v.round()}';
    _per = TextEditingController(text: s(_calc.perServingKcal));
    _total = TextEditingController(text: s(_calc.totalKcal));
    _serv = TextEditingController(text: '${_calc.servings}');
    _p = TextEditingController(text: s(n?.proteinG));
    _f = TextEditingController(text: s(n?.fatG));
    _c = TextEditingController(text: s(n?.carbG));
  }

  @override
  void dispose() {
    for (final t in [_per, _total, _serv, _p, _f, _c]) {
      t.dispose();
    }
    super.dispose();
  }

  /// 把换算结果写回另外两个框。程序改 `controller.text` **不会**触发 onChanged，
  /// 所以这里不存在回灌递归，不需要防抖标志（一开始写了个 _syncing 是多余的，已摘）。
  void _apply(NutritionField field, String raw) {
    final next = nutriApply(_calc, field, raw);
    setState(() {
      _calc = next;
      _per.text = next.perServingKcal == null ? '' : '${next.perServingKcal!.round()}';
      _total.text = next.totalKcal == null ? '' : '${next.totalKcal!.round()}';
      _serv.text = '${next.servings}';
      // 数值改回正常范围，确认条自己收回
      if (_armed && !(next.perServingKcal != null && next.perServingKcal! > kNutritionAbsurdPerServing)) {
        _armed = false;
      }
      _hint = null;
    });
  }

  Widget _field(String label, TextEditingController t, ValueChanged<String>? onChanged,
      {String? key, TextInputType? input}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        height: 58,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(fontSize: 11, color: context.zj.muted)),
            Expanded(
              child: TextField(
                key: key == null ? null : ValueKey(key),
                controller: t,
                onChanged: onChanged,
                keyboardType: input ?? TextInputType.number,
                textAlign: TextAlign.start,
                style: const TextStyle(fontSize: 15),
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final check = nutriCheck(_calc, armed: _armed);
    if (check == NutritionCheck.needPerServing) {
      setState(() => _hint = '每份千卡得填个正数');
      return;
    }
    if (check == NutritionCheck.needConfirm) {
      setState(() {
        _armed = true;
        _hint = null;
      });
      return;
    }
    final store = StoreScope.of(context);
    if (_saving) return;
    setState(() => _saving = true);
    final prev = widget.initial;
    final prevBasis = NutritionBasis.decode(prev?.basisJson);
    final echo = nutriEchoFor(prevBasis,
        prevSource: prev?.source,
        prevPer: prev?.perServingKcal,
        prevTotal: prev?.totalKcal,
        prevModel: prev?.model,
        prevConfidence: prev?.confidence);
    double? num(TextEditingController t) {
      final v = t.text.trim();
      if (v.isEmpty) return null;
      return double.tryParse(v);
    }

    await store.saveNutrition(
      widget.recipe.id,
      NutritionDraft(
        perServingKcal: _calc.perServingKcal ?? 0,
        totalKcal: _calc.totalKcal ?? _calc.perServingKcal! * _calc.servings,
        proteinG: num(_p),
        fatG: num(_f),
        carbG: num(_c),
        // 逐项依据原样带走，另存一份 AI 原值留痕（FR-AI-71）
        basisJson: NutritionBasis(items: prevBasis.items, ai: echo).encode(),
        confidence: null, // 手填没有「把握度」
        source: 'manual',
        model: prev?.model,
        servingsBasis: _calc.servings,
      ),
    );
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final hasEcho = widget.initial != null &&
        widget.initial!.source == 'ai';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
        child: Column(
          key: const ValueKey('nutri-edit-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.initial == null ? '手动填写热量' : '调整热量',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            // 即时预览：空值画「—」而不是 0——画 0 会让人以为已经填过了。
            // key 挂在 Text 上（不是外壳 Container）：测试与走查都按文本取数。
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                  color: context.zj.surface,
                  borderRadius: BorderRadius.circular(10)),
              child: Text(
                key: const ValueKey('nutri-preview'),
                '每份 ≈ ${_calc.perServingKcal == null ? '—' : _calc.perServingKcal!.round()} 千卡'
                '　·　整锅约 ${_calc.totalKcal == null ? '—' : _calc.totalKcal!.round()} 千卡'
                '　·　按 ${_calc.servings} 人份',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                    child: _field('每份（千卡）', _per,
                        (v) => _apply(NutritionField.per, v),
                        key: 'nutri-per')),
                const SizedBox(width: 10),
                Expanded(
                    child: _field('整锅（千卡）', _total,
                        (v) => _apply(NutritionField.total, v),
                        key: 'nutri-total')),
              ],
            ),
            _field('份数基数', _serv, (v) => _apply(NutritionField.servings, v),
                key: 'nutri-serv'),
            Row(
              children: [
                Expanded(child: _field('蛋白质 g', _p, null, key: 'nutri-p')),
                const SizedBox(width: 10),
                Expanded(child: _field('脂肪 g', _f, null, key: 'nutri-f')),
                const SizedBox(width: 10),
                Expanded(child: _field('碳水 g', _c, null, key: 'nutri-c')),
              ],
            ),
            if (hasEcho)
              Text(
                'AI 原估 每份 ${widget.initial!.perServingKcal.round()} 千卡会留在「看依据」里对照。',
                style: TextStyle(fontSize: 11, color: context.zj.muted, height: 1.6),
              ),
            if (_hint != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_hint!,
                    key: const ValueKey('nutri-hint'),
                    style: TextStyle(fontSize: 12, color: context.zj.warn)),
              ),
            if (_armed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Container(
                  key: const ValueKey('nutri-confirm-bar'),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                      color: context.zj.aiBg,
                      borderRadius: BorderRadius.circular(12)),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '每份 ${_calc.perServingKcal?.round()} 千卡，超过 ${kNutritionAbsurdPerServing.round()} 的上限线——确定是这个数？',
                          style: TextStyle(fontSize: 11.5, color: context.zj.ink2),
                        ),
                      ),
                      TextButton(
                        // 与底部那枚主保存**分开键名**：确认条出现时两枚同时在树上，
                        // 撞 key 会让 find.byKey 命中两个（测试直接崩）。
                        key: const ValueKey('nutri-save-confirm'),
                        onPressed: _saving ? null : _save,
                        child: const Text('确定保存', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('取消', style: TextStyle(fontSize: 13)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    key: const ValueKey('nutri-save'),
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? '正在保存…' : '保存',
                        style: const TextStyle(fontSize: 13)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// R46 · 看依据：逐食材贡献 + 手改过的那版留着的 **AI 原值两段对照**（FR-AI-71）。
///
/// 这一段 models 的注释里早就写了「UI 只在「看依据」里展开」，但实现层从来没做——
/// 手改之后如果没有这里，AI 原值就真的只剩一个划线数字，对不了账。
class _NutritionBasisSheet extends StatelessWidget {
  const _NutritionBasisSheet({required this.recipe, required this.n});

  final Recipe recipe;
  final Nutrition n;

  static Future<void> show(BuildContext context, Recipe recipe, Nutrition n) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.zj.paper,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(ZaojiRadius.xl))),
      builder: (_) => _NutritionBasisSheet(recipe: recipe, n: n),
    );
  }

  Widget _row(BuildContext context, String k, String v,
      {bool strong = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
              child: Text(k,
                  style: TextStyle(
                      fontSize: 12,
                      color: context.zj.muted,
                      fontWeight: strong ? FontWeight.w700 : FontWeight.normal))),
          Text(v,
              style: TextStyle(
                  fontSize: 12.5,
                  color: color ?? context.zj.ink,
                  fontWeight: strong ? FontWeight.w700 : FontWeight.w600)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final basis = NutritionBasis.decode(n.basisJson);
    final echo = basis.ai;
    return SafeArea(
      child: SingleChildScrollView(
        key: const ValueKey('nutri-basis-sheet'),
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('热量是怎么算出来的 · ${recipe.name}',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            if (n.isManual && echo != null && echo.perServingKcal != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: context.zj.surface,
                    borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _row(context, 'AI 原估 · 每份',
                        '≈ ${echo.perServingKcal!.round()} 千卡',
                        color: context.zj.muted),
                    if (echo.totalKcal != null)
                      _row(context, 'AI 原估 · 整锅', '≈ ${echo.totalKcal!.round()} 千卡',
                          color: context.zj.muted),
                    if (echo.model != null && echo.model!.isNotEmpty)
                      _row(context, '出自', echo.model!),
                    Divider(color: context.zj.line, height: 18),
                    _row(context, '现在生效 · 每份（手填）',
                        '≈ ${n.perServingKcalRounded} 千卡',
                        strong: true, color: context.zj.accent),
                  ],
                ),
              ),
              const SizedBox(height: 14),
            ],
            if (basis.items.isEmpty)
              Text(
                n.isManual ? '逐食材贡献只有 AI 估的那一版才有，手填的数不带这一项。' : '这次估算没给出逐食材贡献。',
                style: TextStyle(fontSize: 12, color: context.zj.muted, height: 1.6),
              )
            else
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: context.zj.surface,
                    borderRadius: BorderRadius.circular(12)),
                child: Column(
                  children: [
                    for (final it in basis.items)
                      _row(context, 
                          [
                            NutritionBasis.itemName(it),
                            if (NutritionBasis.itemQty(it).isNotEmpty)
                              NutritionBasis.itemQty(it)
                          ].join(' · '),
                          '≈ ${(NutritionBasis.itemKcal(it) ?? 0).round()} 千卡'),
                    Divider(color: context.zj.line, height: 18),
                    _row(context, '合计（整锅）', '≈ ${n.totalKcalRounded} 千卡'),
                    _row(context, '每份（按 ${n.servingsBasisOrFallback} 人份）',
                        '≈ ${n.perServingKcalRounded} 千卡',
                        strong: true,
                        color: n.isManual ? context.zj.accent : context.zj.ai),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了', style: TextStyle(fontSize: 13)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 实拍封面（R16）：有就展示，没有保持原有排版不动
        if (recipe.coverSha256 != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(ZaojiRadius.lg),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: CoverImage(
                sha: recipe.coverSha256!,
                // 详情展示的是满宽大图，用 detail 档（1280）而不是原始 1600px：
                // 差值看不出来，省下来的是手机的解码时间与内存
                width: MediaWidth.detail,
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
        Text(
          recipe.sub,
          style: TextStyle(
            fontSize: 13.5,
            height: 1.6,
            color: context.zj.ink2,
          ),
        ),
        const SizedBox(height: 14),
        // 同样用 Wrap：320px 宽时「刻度 + 耗时 + 分量 + 做过」放不下一行。
        // 详情页比列表页更容易踩到，因为这里的数值更长（「120 分钟」「4 人份」）。
        Wrap(
          spacing: 18,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ChiliScale(level: recipe.difficulty, size: 15),
            _Stat(label: '耗时', value: '${recipe.selfTime} 分钟'),
            _Stat(label: '分量', value: '${recipe.servings} 人份'),
            if (recipe.cookedCount > 0)
              _Stat(label: '做过', value: '${recipe.cookedCount} 次'),
          ],
        ),
        if (recipe.isAi) ...[
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.fromLTRB(11, 9, 11, 9),
            decoration: BoxDecoration(
              color: context.zj.aiBg,
              borderRadius: BorderRadius.circular(ZaojiRadius.sm),
              border: Border.all(color: context.zj.ai.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                Icon(Icons.auto_awesome, size: 14, color: context.zj.ai),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '这道菜由 ${recipe.sourceModel ?? '大模型'} 生成，请核对后再做',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: context.zj.ai,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, color: context.zj.muted),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: context.zj.ink,
          ),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.num, required this.title, this.trailing});

  final String num;
  final String title;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          num,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: context.zj.accent,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: ZaojiText.displayOf(context, fontSize: 17, fontWeight: FontWeight.w500),
        ),
        if (trailing != null) ...[
          const Spacer(),
          Text(
            trailing!,
            style: TextStyle(fontSize: 12, color: context.zj.muted),
          ),
        ],
      ],
    );
  }
}

class _IngredientTable extends StatelessWidget {
  const _IngredientTable({required this.ingredients, this.hits = const []});

  final List<Ingredient> ingredients;

  /// 整道菜的命中项（R40）。按食材名分到各行，没命中的行不垫条纹——
  /// 满屏警告等于没有警告。
  final List<AllergenHit> hits;

  @override
  Widget build(BuildContext context) {
    final byIng = <String, List<AllergenHit>>{};
    for (final h in hits) {
      (byIng[h.ingredient] ??= []).add(h);
    }
    return Container(
      decoration: BoxDecoration(
        color: context.zj.surface,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(color: context.zj.lineSoft),
      ),
      child: Column(
        children: [
          for (var i = 0; i < ingredients.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: Divider(height: 1),
              ),
            _IngredientRow(
                item: ingredients[i],
                hits: byIng[ingredients[i].name] ?? const []),
          ],
        ],
      ),
    );
  }
}

class _IngredientRow extends StatelessWidget {
  const _IngredientRow({required this.item, this.hits = const []});

  final Ingredient item;
  final List<AllergenHit> hits;

  @override
  Widget build(BuildContext context) {
    final hard = hits.where((h) => h.isAllergy).toList();
    final row = Row(
      children: [
        // 主食材加一个小圆点。推荐算法里缺主食材要 ×0.5，
        // 所以这个标记在界面上也该看得见
        SizedBox(
          width: 14,
          child: item.isMain
              ? Icon(Icons.circle, size: 6, color: context.zj.accent)
              : const SizedBox.shrink(),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.name,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: item.isMain ? FontWeight.w600 : FontWeight.w400,
                  color: context.zj.ink,
                ),
              ),
              if (hits.isNotEmpty) ...[
                const SizedBox(height: 5),
                Wrap(
                  key: ValueKey('ing-alert-${item.name}'),
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final h in hits)
                      AllergenTag(
                          who: h.memberName, word: h.word, allergy: h.isAllergy),
                  ],
                ),
              ],
            ],
          ),
        ),
        // 分量显示**原文**（「半个」不写成「0.5 个」）
        Text(
          item.qty,
          style: TextStyle(fontSize: 13, color: context.zj.muted),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      // 命中的行整行垫一层淡警告底（原型 .ing.is-allergen）：
      // 标签只在行内某处时容易被扫过去漏掉，整行垫底才拦得住
      child: hard.isEmpty
          ? row
          : DecoratedBox(
              decoration: BoxDecoration(
                color: context.zj.accentSofter,
                borderRadius: BorderRadius.circular(ZaojiRadius.xs),
              ),
              child: row,
            ),
    );
  }
}

/// 成品照片墙（FR-REC-06）：封面之外拍过的成品照，横向一排，点开看大图。
class _GalleryStrip extends StatelessWidget {
  const _GalleryStrip({required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 92,
      child: ListView(
        key: const ValueKey('recipe-gallery'),
        scrollDirection: Axis.horizontal,
        children: [
          for (final sha in recipe.photos)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                onTap: () => _StepRow._showFull(context, sha),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(ZaojiRadius.sm),
                  child: SizedBox(
                    width: 122,
                    child: CoverImage(sha: sha, width: MediaWidth.card),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.index, required this.text, this.images = const []});

  final int index;
  final String text;

  /// R29：本步实拍（至多 4 张，schema v5）。
  final List<String> images;

  @override
  Widget build(BuildContext context) {
    // 原来是 `bodyStyle`：颜色进了主题令牌之后它不再是常量，
    // 每次 build 现取一份，代价可以忽略，但**不能留在 里**。
    final bodyStyle = TextStyle(
      fontSize: 14.5,
      height: 1.85,
      color: context.zj.ink,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            margin: const EdgeInsets.only(top: 3),
            decoration: BoxDecoration(
              color: context.zj.paper2,
              borderRadius: BorderRadius.circular(ZaojiRadius.xs),
            ),
            alignment: Alignment.center,
            child: Text(
              '$index',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: context.zj.ink2,
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                RichText(
                  // 原文一个字都没改写：只是把时间区间换成胶囊
                  text: TextSpan(
                    style: bodyStyle,
                    children: buildTimeCapsuleSpans(
                      text,
                      style: bodyStyle,
                      onTap: (hit) => startKitchenTimer(
                        context,
                        sourceText: hit.text,
                        seconds: hit.suggestedSeconds,
                      ),
                    ),
                  ),
                ),
                if (images.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      key: ValueKey('step-img-$index'),
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final sha in images)
                          GestureDetector(
                            onTap: () => _showFull(context, sha),
                            child: ClipRRect(
                              borderRadius:
                                  BorderRadius.circular(ZaojiRadius.xs),
                              child: SizedBox(
                                width: 88,
                                height: 66,
                                child: CoverImage(
                                    sha: sha, width: MediaWidth.card),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 全屏看原图（详情页照片墙与步骤图共用）。
  static void _showFull(BuildContext context, String sha) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(18),
        backgroundColor: Colors.black,
        child: InteractiveViewer(
          child: CoverImage(sha: sha, fit: BoxFit.contain),
        ),
      ),
    );
  }
}

/// 每次做的时间（FR-REC-13 · 原型 `sec 05` 的 `.spec` 行）。
///
/// 数据来自 `cookSessions()`：只有 `finished_at` 非空、且没进回收站的会话，
/// 按完成时刻倒序。所以这里**不显示进行中**的那次——它归顶部续做横幅管，
/// 两处各说各的，不会同一件事出现两行。
class _CookHistory extends StatelessWidget {
  const _CookHistory({required this.sessions});

  final List<CookSession> sessions;

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// `09/14 18:30` —— 年份留给日历页，这一屏只关心「什么时候做的」。
  static String stamp(DateTime d) =>
      '${_two(d.month)}/${_two(d.day)} ${_two(d.hour)}:${_two(d.minute)}';

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      // 与原型一致的空态：不藏这一块，否则用户不知道「做过」会被记下来。
      return Text(
        '还没有做过这道菜，做一次后会自动记录。',
        style: TextStyle(fontSize: 12.5, color: context.zj.muted),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
      decoration: BoxDecoration(
        color: context.zj.paper2,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(color: context.zj.lineSoft),
      ),
      child: Column(
        children: [
          for (var i = 0; i < sessions.length; i++)
            Padding(
              key: ValueKey('cook-history-${sessions[i].id}'),
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      stamp(sessions[i].finishedAt ?? sessions[i].startedAt),
                      style: TextStyle(
                        fontSize: 13,
                        color: context.zj.ink,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  Text(
                    // 倒序列表里的「第 N 次」要从末尾数回来
                    '第 ${sessions.length - i} 次',
                    style: TextStyle(fontSize: 12.5, color: context.zj.muted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _Notes extends StatelessWidget {
  const _Notes({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).toList();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 13, 14, 13),
      decoration: BoxDecoration(
        color: context.zj.paper2,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(color: context.zj.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                line,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.7,
                  color: context.zj.ink2,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
