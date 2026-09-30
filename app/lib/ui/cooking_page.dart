import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import '../data/screen_wake.dart';
import '../data/store_scope.dart';
import '../data/sync/sync_engine.dart' show MediaWidth;
import '../data/wake_scope.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/allergen_bits.dart';
import '../widgets/cover_image.dart';
import '../widgets/time_capsule_text.dart';
import 'timer_sheet.dart';

/// 做菜模式（R20）：一步一屏，大字、防误触、进度续做。
///
/// 这一屏的用户画像和 App 其它页完全不同：**手是湿的、油的是真的、
/// 视线在锅和屏幕之间来回**。所以：
/// - 步骤正文 ≥20px（FR-COOK-06，1 米外可读）；
/// - 底部按钮高 ≥62px（FR-COOK-07）；「完成这道菜」必须**长按**才生效——
///   误触下一步的代价是看一眼，误触完成的代价是一次做菜记录被污染；
/// - 每翻一步都把进度写回 cook_session（FR-COOK-08）：被叫走、没电、
///   杀进程，回来都接得上。进度是**本设备**的事（会话行的 updated_by
///   就是设备身份），别的设备的进行中会话不会出现在这里。
class CookingPage extends StatefulWidget {
  const CookingPage({
    super.key,
    required this.recipe,
    required this.sessionId,
    required this.initialStep,
    required this.initialChecked,
  });

  final Recipe recipe;
  final String sessionId;
  final int initialStep;
  final Set<int> initialChecked;

  /// 打开做菜模式：有本机未完成会话就续上，没有就开一条新会话。
  static Future<void> open(BuildContext context, Recipe recipe) async {
    final store = StoreScope.of(context);
    final active = await store.activeCookingSession(recipe.id);
    final sessionId = active?.id ?? await store.startCooking(recipe.id);
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => CookingPage(
        recipe: recipe,
        sessionId: sessionId,
        initialStep: active?.currentStep ?? 0,
        initialChecked: _decodeChecked(active?.state),
      ),
    ));
  }

  static Set<int> _decodeChecked(String? state) {
    if (state == null || state.isEmpty) return {};
    try {
      final j = jsonDecode(state);
      if (j is Map && j['checked'] is List) {
        return {for (final x in (j['checked'] as List)) (x as num).toInt()};
      }
    } catch (_) {/* 状态是尽力而为的便利，解析失败就当没勾过 */}
    return {};
  }

  @override
  State<CookingPage> createState() => _CookingPageState();
}

class _CookingPageState extends State<CookingPage> {
  late int _step = widget.initialStep.clamp(0, _total - 1);
  late final Set<int> _checked = {...widget.initialChecked};
  bool _finishing = false;

  /// FR-COOK-09：做菜模式屏幕常亮。登记与撤手都走 [ScreenWake] 的引用计数，
  /// 所以计时器先跑完不会把正在盯步骤的屏幕关掉。
  ScreenWake? _wake;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 不在 initState 取：InheritedWidget 要到 didChangeDependencies 才保证可读。
    _wake ??= WakeScope.of(context)..need('cook');
  }

  @override
  void dispose() {
    // 离开这一屏（含返回、含做完）一定要撤手，否则锁会一直挂着耗电。
    _wake?.done('cook');
    super.dispose();
  }

  int get _total => widget.recipe.steps.length;
  bool get _isLast => _step >= _total - 1;

  // 不在 initState 落一次进度：startCooking 已把 current_step 写成 0，
  // 续做时进度本来就是库里的那个——重复写只会多一次无谓的同步推送。

  Future<void> _persist() async {
    await StoreScope.of(context).saveCookingStep(
      widget.sessionId,
      _step,
      state: jsonEncode({'checked': _checked.toList()..sort()}),
    );
  }

  void _goto(int next) {
    setState(() => _step = next.clamp(0, _total - 1));
    _persist();
  }

  void _toggleChecked(int i) {
    setState(() => _checked.contains(i) ? _checked.remove(i) : _checked.add(i));
    _persist();
  }

  Future<void> _finish() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await StoreScope.of(context).finishCooking(widget.sessionId);
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「${widget.recipe.name}」又做了一次')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stepText = widget.recipe.steps[_step].text;
    final store = StoreScope.of(context);
    // 命中过敏原时把横幅钉在**屏幕顶部**而不是原型那样放在右侧速查面板里：
    // 原型那侧面板就是「食材速查」的展开区，收起时横幅跟着消失——
    // 而这屏的"收起来"才是常态，警告不该跟着一起收。
    final hits = store.allergenWarnInRecipes
        ? store.allergenHitsFor(widget.recipe)
        : const <AllergenHit>[];

    return Scaffold(
      appBar: AppBar(
        title: Text('第 ${_step + 1} 步 / 共 $_total 步 · ${widget.recipe.name}'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            tooltip: '先离开（进度会留着）',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
      body: Column(
        children: [
          LinearProgressIndicator(
            value: (_step + 1) / _total,
            minHeight: 4,
            backgroundColor: context.zj.lineSoft,
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              children: [
                RecipeAllergenBanner(
                  hits: hits,
                  title: '注意分餐',
                  withIngredients: false,
                  padding: const EdgeInsets.only(bottom: 14),
                ),
                // ★ 正文 ≥20px（FR-COOK-06）：灶台前 1 米外要读得清。
                // 时间胶囊照旧可点起计时（FR-COOK-02），原文一字不改。
                RichText(
                  text: TextSpan(
                    style: TextStyle(
                      fontSize: 21,
                      height: 1.75,
                      color: context.zj.ink,
                      fontWeight: FontWeight.w500,
                    ),
                    children: buildTimeCapsuleSpans(
                      stepText,
                      style: TextStyle(
                        fontSize: 21,
                        height: 1.75,
                        color: context.zj.ink,
                        fontWeight: FontWeight.w500,
                      ),
                      onTap: (hit) => startKitchenTimer(
                        context,
                        sourceText: hit.text,
                        seconds: hit.suggestedSeconds,
                      ),
                    ),
                  ),
                ),
                // R29：本步实拍随步骤展示（FR-COOK-10）——灶台前不用翻回详情页找图
                if (widget.recipe.steps[_step].images.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    key: const ValueKey('cook-step-images'),
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final sha in widget.recipe.steps[_step].images)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(ZaojiRadius.md),
                          child: SizedBox(
                            width: 150,
                            height: 112,
                            child: CoverImage(
                                sha: sha, width: MediaWidth.detail),
                          ),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 18),
                // 食材速查（FR-COOK-11）：下锅前对一遍，勾选状态随进度落库
                _IngredientChecklist(
                  ingredients: widget.recipe.ingredients,
                  checked: _checked,
                  onToggle: _toggleChecked,
                  hits: hits,
                ),
              ],
            ),
          ),
          SafeArea(
            minimum: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            child: Row(
              children: [
                SizedBox(
                  height: 62, // FR-COOK-07：按钮高度 ≥62px，湿手可操作
                  child: OutlinedButton(
                    onPressed: _step > 0 ? () => _goto(_step - 1) : null,
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: context.zj.line),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(ZaojiRadius.md),
                      ),
                    ),
                    child: const Text('上一步',
                        style: TextStyle(fontSize: 16)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _isLast
                      ? _HoldToFinishButton(onFinish: _finish)
                      : SizedBox(
                          height: 62,
                          child: FilledButton(
                            onPressed: () => _goto(_step + 1),
                            style: FilledButton.styleFrom(
                              backgroundColor: context.zj.accent,
                              foregroundColor: context.zj.onAccent,
                              shape: RoundedRectangleBorder(
                                borderRadius:
                                    BorderRadius.circular(ZaojiRadius.md),
                              ),
                            ),
                            child: const Text('下一步',
                                style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 「完成这道菜」= 长按才生效（FR-COOK-07 防误触）。
/// 短点只给一句提示——误触下一步是看一眼，误触完成是污染一次记录。
class _HoldToFinishButton extends StatelessWidget {
  const _HoldToFinishButton({required this.onFinish});

  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 62,
      child: GestureDetector(
        onLongPress: onFinish,
        onTap: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('按住不放 0.3 秒，完成这道菜'),
            duration: Duration(seconds: 1),
          ),
        ),
        child: Semantics(
          button: true,
          enabled: true,
          label: '完成这道菜（长按确认）',
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: context.zj.amber,
              borderRadius: BorderRadius.circular(ZaojiRadius.md),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle_outline, color: context.zj.onAccent),
                SizedBox(width: 8),
                Text('完成这道菜',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: context.zj.onAccent)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _IngredientChecklist extends StatelessWidget {
  const _IngredientChecklist({
    required this.ingredients,
    required this.checked,
    required this.onToggle,
    this.hits = const [],
  });

  final List<Ingredient> ingredients;
  final Set<int> checked;
  final ValueChanged<int> onToggle;

  /// 整道菜的命中项（R40）。勾选面板默认是收起来的，所以真正的提醒
  /// 靠上面那条横幅；这里只是"展开对菜时能看到是谁"。
  final List<AllergenHit> hits;

  @override
  Widget build(BuildContext context) {
    final byIng = <String, List<AllergenHit>>{};
    for (final h in hits) {
      (byIng[h.ingredient] ??= <AllergenHit>[]).add(h);
    }
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        initiallyExpanded: false,
        title: Text(
          '食材速查（已备 ${checked.length}/${ingredients.length}）',
          style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: context.zj.ink2),
        ),
        children: [
          for (var i = 0; i < ingredients.length; i++)
            CheckboxListTile(
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              value: checked.contains(i),
              onChanged: (_) => onToggle(i),
              title: Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    '${ingredients[i].name}　${ingredients[i].qty}',
                    style: const TextStyle(fontSize: 14),
                  ),
                  // 灶台前只来得及扫一眼，这里只挂「是谁」，
                  // 完整原因在上面的横幅和菜谱详情里
                  for (final h in (byIng[ingredients[i].name] ?? const []))
                    if (h.isAllergy)
                      AllergenTag(
                          who: h.memberName,
                          word: h.word,
                          allergy: true,
                          mode: AllergenTagMode.who),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
