import 'package:flutter/material.dart';

import '../data/store_scope.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/chili_scale.dart';
import '../widgets/cover_image.dart';
import '../widgets/time_capsule_text.dart';
import 'recipe_edit_page.dart';
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
class RecipeDetailPage extends StatelessWidget {
  const RecipeDetailPage({super.key, required this.recipe});

  final Recipe recipe;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(recipe.name),
        actions: [
          IconButton(
            tooltip: '删除',
            onPressed: () => _confirmDelete(context),
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: '编辑',
            onPressed: () => _edit(context),
            icon: const Icon(Icons.edit_outlined),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
        children: [
          _Hero(recipe: recipe),
          const SizedBox(height: 22),
          _SectionTitle(
            num: '01',
            title: '食材',
            trailing: '${recipe.servings} 人份',
          ),
          const SizedBox(height: 10),
          _IngredientTable(ingredients: recipe.ingredients),
          const SizedBox(height: 26),
          const _SectionTitle(num: '02', title: '做法'),
          const SizedBox(height: 4),
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Text(
              '琥珀色的时间可以点一下直接起计时',
              style: TextStyle(fontSize: 12, color: ZaojiColors.muted),
            ),
          ),
          for (var i = 0; i < recipe.steps.length; i++)
            _StepRow(index: i + 1, text: recipe.steps[i].text),
          if (recipe.notes.trim().isNotEmpty) ...[
            const SizedBox(height: 26),
            const _SectionTitle(num: '03', title: '注意'),
            const SizedBox(height: 10),
            _Notes(text: recipe.notes),
          ],
        ],
      ),
    );
  }

  void _edit(BuildContext context) {
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
              backgroundColor: const Color(0xFFC33F14),
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    final store = StoreScope.of(context);
    await store.softDeleteRecipe(recipe.id);
    if (context.mounted) {
      // 成功删除后回到列表页（详情页里的菜谱已经不在了）
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已删除（可在回收站恢复）')));
    }
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
              child: CoverImage(sha: recipe.coverSha256!),
            ),
          ),
          const SizedBox(height: 14),
        ],
        Text(
          recipe.sub,
          style: const TextStyle(
            fontSize: 13.5,
            height: 1.6,
            color: ZaojiColors.ink2,
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
              color: ZaojiColors.aiBg,
              borderRadius: BorderRadius.circular(ZaojiRadius.sm),
              border: Border.all(color: ZaojiColors.ai.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                const Icon(Icons.auto_awesome, size: 14, color: ZaojiColors.ai),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '这道菜由 ${recipe.sourceModel ?? '大模型'} 生成，请核对后再做',
                    style: const TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: ZaojiColors.ai,
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
          style: const TextStyle(fontSize: 12, color: ZaojiColors.muted),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: ZaojiColors.ink,
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
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: ZaojiColors.accent,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: ZaojiText.display(fontSize: 17, fontWeight: FontWeight.w500),
        ),
        if (trailing != null) ...[
          const Spacer(),
          Text(
            trailing!,
            style: const TextStyle(fontSize: 12, color: ZaojiColors.muted),
          ),
        ],
      ],
    );
  }
}

class _IngredientTable extends StatelessWidget {
  const _IngredientTable({required this.ingredients});

  final List<Ingredient> ingredients;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(color: ZaojiColors.lineSoft),
      ),
      child: Column(
        children: [
          for (var i = 0; i < ingredients.length; i++) ...[
            if (i > 0)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: Divider(height: 1),
              ),
            _IngredientRow(item: ingredients[i]),
          ],
        ],
      ),
    );
  }
}

class _IngredientRow extends StatelessWidget {
  const _IngredientRow({required this.item});

  final Ingredient item;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
      child: Row(
        children: [
          // 主食材加一个小圆点。推荐算法里缺主食材要 ×0.5，
          // 所以这个标记在界面上也该看得见
          SizedBox(
            width: 14,
            child: item.isMain
                ? const Icon(Icons.circle, size: 6, color: ZaojiColors.accent)
                : const SizedBox.shrink(),
          ),
          Expanded(
            child: Text(
              item.name,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: item.isMain ? FontWeight.w600 : FontWeight.w400,
                color: ZaojiColors.ink,
              ),
            ),
          ),
          // 分量显示**原文**（「半个」不写成「0.5 个」）
          Text(
            item.qty,
            style: const TextStyle(fontSize: 13, color: ZaojiColors.muted),
          ),
        ],
      ),
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.index, required this.text});

  final int index;
  final String text;

  @override
  Widget build(BuildContext context) {
    const bodyStyle = TextStyle(
      fontSize: 14.5,
      height: 1.85,
      color: ZaojiColors.ink,
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
              color: ZaojiColors.paper2,
              borderRadius: BorderRadius.circular(ZaojiRadius.xs),
            ),
            alignment: Alignment.center,
            child: Text(
              '$index',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: ZaojiColors.ink2,
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: RichText(
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
        color: ZaojiColors.paper2,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(color: ZaojiColors.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                line,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.7,
                  color: ZaojiColors.ink2,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
