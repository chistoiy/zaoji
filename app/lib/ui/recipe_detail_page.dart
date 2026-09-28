import 'dart:convert';

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
    final s = await StoreScope.of(context).activeCookingSession(widget.recipe.id);
    if (mounted) setState(() => _active = s);
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
              if (recipe.notes.trim().isNotEmpty) ...[
                const SizedBox(height: 26),
                const _SectionTitle(num: '03', title: '注意'),
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
    await store.softDeleteRecipe(widget.recipe.id);
    if (context.mounted) {
      // 成功删除后回到列表页（详情页里的菜谱已经不在了）
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已删除（可在回收站恢复）')));
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
/// 三种形态：**有数据** → 结果卡（AI 估算，仅供参考 + 模型 + 把握度 + 免责）；
/// **没数据** → 「估算热量」入口按钮——入口**恒定显示**，配没配 AI 都在，
/// 未配置时点它引导去配置页（一个默认隐藏的能力等于不存在）。
class _NutritionBlock extends StatefulWidget {
  const _NutritionBlock({required this.recipe});

  final Recipe recipe;

  @override
  State<_NutritionBlock> createState() => _NutritionBlockState();
}

class _NutritionBlockState extends State<_NutritionBlock> {
  bool _busy = false;

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
          basisJson: jsonEncode(n['per_ingredient'] ?? const []),
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
      return OutlinedButton.icon(
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
      );
    }

    return Container(
      key: const ValueKey('nutrition-card'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.zj.surface,
        borderRadius: BorderRadius.circular(ZaojiRadius.lg),
        border: Border.all(color: context.zj.aiBg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome, size: 14, color: context.zj.ai),
              const SizedBox(width: 6),
              Text('AI 估算',
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: context.zj.ai)),
              const Spacer(),
              Text('把握度 ${n.confidenceLabel}',
                  style: TextStyle(
                      fontSize: 11, color: context.zj.muted)),
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
                      color: context.zj.ai,
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
          Text(
            '${n.source == 'ai' && n.model != null && n.model!.isNotEmpty ? '${n.model} · ' : ''}'
            '来源：${n.source == 'ai' ? 'AI 估算' : '手动填写'}。'
            'AI 估算，仅供参考，不能用于医疗或饮食处方。',
            style:
                TextStyle(fontSize: 10.5, color: context.zj.muted, height: 1.6),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _busy ? null : _estimate,
              child: Text(_busy ? '正在重算…' : '重新估算',
                  style: TextStyle(
                      fontSize: 12, color: context.zj.ai)),
            ),
          ),
        ],
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
                      onTap: (hit) => showTimerSheet(
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
