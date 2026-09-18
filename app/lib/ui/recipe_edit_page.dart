import 'package:flutter/material.dart';

import '../data/recipe_store.dart';
import '../data/store_scope.dart';
import '../models.dart';
import '../theme.dart';

/// 菜谱新建/编辑页。
///
/// 对照 prototype `SCREENS['recipe-edit']` 逐块实现。
/// 一个页面两种模式：`recipe` 参数为 null 时 = 新建，非 null = 编辑。
///
/// ## 设计取舍（第一版）
///
/// - 封面插画：第一版固定 palette + 默认 art（后续做封面重选）
/// - 标签分组：prototype 有四组（菜系/食材/口味/操作方式），第一版先简化
///   操作方式快捷选择
/// - 图片/分量/单位换算：延后（R14 核心是打通写路径 + 同步）
class RecipeEditPage extends StatefulWidget {
  const RecipeEditPage({super.key, this.recipe});

  /// 非 null = 编辑模式。null = 新建。
  final Recipe? recipe;

  bool get isNew => recipe == null;

  @override
  State<RecipeEditPage> createState() => _RecipeEditPageState();
}

class _RecipeEditPageState extends State<RecipeEditPage> {
  final _formKey = GlobalKey<FormState>();

  // 临时表单状态
  late final TextEditingController _nameCtrl;
  late final TextEditingController _subCtrl;
  late final TextEditingController _timeCtrl;
  late final TextEditingController _servingsCtrl;
  late final TextEditingController _notesCtrl;

  late int _difficulty;
  late List<_IngredientRow> _ingredients;
  late List<TextEditingController> _stepCtrls;

  bool _saving = false;

  // 快捷操作方式标签
  static const _quickMethods = ['爆炒', '水煮', '清蒸', '红烧', '烧烤', '凉拌', '烘焙', '火锅'];
  final Set<String> _selectedMethods = {};

  @override
  void initState() {
    super.initState();
    final r = widget.recipe;
    _nameCtrl = TextEditingController(text: r?.name ?? '');
    _subCtrl = TextEditingController(text: r?.sub ?? '');
    _timeCtrl = TextEditingController(text: r?.selfTime.toString() ?? '');
    _servingsCtrl = TextEditingController(text: r?.servings.toString() ?? '2');
    _notesCtrl = TextEditingController(text: r?.notes ?? '');

    _difficulty = r?.difficulty ?? 1;

    _ingredients = [
      for (final ing in r?.ingredients ?? const [])
        _IngredientRow(nameCtrl: TextEditingController(text: ing.name), qtyCtrl: TextEditingController(text: ing.qty), isMain: ing.isMain),
      // 新建时给 2 个空行
      if (r == null) ...[
        _IngredientRow(nameCtrl: TextEditingController(), qtyCtrl: TextEditingController()),
        _IngredientRow(nameCtrl: TextEditingController(), qtyCtrl: TextEditingController()),
      ],
    ];

    _stepCtrls = [
      for (final s in r?.steps ?? const []) TextEditingController(text: s.text),
      if (r == null) ...[TextEditingController(), TextEditingController()],
    ];

    if (r != null) {
      _selectedMethods.addAll(r.methods);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _subCtrl.dispose();
    _timeCtrl.dispose();
    _servingsCtrl.dispose();
    _notesCtrl.dispose();
    for (final row in _ingredients) {
      row.nameCtrl.dispose();
      row.qtyCtrl.dispose();
    }
    for (final c in _stepCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    // 收集 draft
    final ingredients = <IngredientDraft>[
      for (final row in _ingredients)
        if (row.nameCtrl.text.trim().isNotEmpty || row.qtyCtrl.text.trim().isNotEmpty)
          IngredientDraft(
            name: row.nameCtrl.text.trim().isEmpty ? '食材' : row.nameCtrl.text.trim(),
            qty: row.qtyCtrl.text.trim(),
            isMain: row.isMain,
          ),
    ];

    final steps = <String>[
      for (final c in _stepCtrls)
        if (c.text.trim().isNotEmpty) c.text.trim(),
    ];

    final tags = <String, List<String>>{};
    if (_selectedMethods.isNotEmpty) {
      tags['method'] = _selectedMethods.toList();
    }

    final draft = RecipeDraft(
      name: _nameCtrl.text.trim(),
      sub: _subCtrl.text.trim(),
      difficulty: _difficulty,
      selfTime: int.tryParse(_timeCtrl.text.trim()) ?? 0,
      servings: int.tryParse(_servingsCtrl.text.trim()) ?? 2,
      notes: _notesCtrl.text.trim(),
      ingredients: ingredients,
      steps: steps,
      art: DishArtKind.plate,
      palette: const [],
      tags: tags,
    );

    setState(() => _saving = true);
    try {
      final store = StoreScope.of(context);
      if (widget.isNew) {
        await store.createRecipe(draft);
      } else {
        await store.updateRecipe(widget.recipe!.id, draft);
      }
      if (mounted) {
        Navigator.of(context).pop(true); // 告诉上一页保存成功
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmPop() async {
    // 简单：直接弹确认 dialog，第一版不做「有改动才提示」
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('放弃编辑？'),
        content: const Text('当前的内容不会保存。'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('继续编辑')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ZaojiColors.accent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmPop();
      },
      child: Scaffold(
        backgroundColor: ZaojiColors.paper,
        appBar: AppBar(
          title: Text(widget.isNew ? '新建菜品' : '编辑菜品'),
          actions: [
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('保存', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            children: [
              _basicFields(),
              const SizedBox(height: 18),
              _difficultyField(),
              const SizedBox(height: 18),
              _servingsField(),
              const SizedBox(height: 22),
              // 标签区
              const _SectionHead(num: '01', title: '操作方式'),
              _tagChips(),
              const SizedBox(height: 22),
              // 食材区
              const _SectionHead(num: '02', title: '食材与分量'),
              _ingredientEditor(),
              const SizedBox(height: 22),
              // 步骤区
              const _SectionHead(num: '03', title: '做法步骤'),
              _stepEditor(),
              const SizedBox(height: 22),
              // 注意事项
              const _SectionHead(num: '04', title: '注意事项'),
              _notesField(),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : _confirmPop,
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    style: FilledButton.styleFrom(backgroundColor: ZaojiColors.accent),
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Text('保存菜品'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─────────── 各区块 ───────────

  Widget _basicFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel('菜品名称', required: true),
        TextFormField(
          controller: _nameCtrl,
          decoration: _inputDeco('例：番茄炒蛋'),
          validator: (v) => (v == null || v.trim().isEmpty) ? '菜名不能为空' : null,
        ),
        const SizedBox(height: 14),
        _fieldLabel('一句话描述'),
        TextFormField(
          controller: _subCtrl,
          decoration: _inputDeco('例：十五分钟的家常底味'),
        ),
      ],
    );
  }

  Widget _difficultyField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel('难度'),
        Row(
          children: [
            for (var d = 1; d <= 3; d++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: IconButton(
                  onPressed: () => setState(() => _difficulty = d),
                  icon: Icon(
                    Icons.local_fire_department,
                    color: d <= _difficulty ? ZaojiColors.accent : ZaojiColors.muted,
                    size: 26,
                  ),
                ),
              ),
            Text(
              ['简单', '中等', '较难'][_difficulty - 1],
              style: const TextStyle(fontSize: 13, color: ZaojiColors.ink2),
            ),
          ],
        ),
      ],
    );
  }

  Widget _servingsField() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _fieldLabel('分量（人）'),
              TextFormField(
                controller: _servingsCtrl,
                keyboardType: TextInputType.number,
                decoration: _inputDeco('2'),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _fieldLabel('耗时（分钟）'),
              TextFormField(
                controller: _timeCtrl,
                keyboardType: TextInputType.number,
                decoration: _inputDeco('15'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tagChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final m in _quickMethods)
          FilterChip(
            label: Text(m),
            selected: _selectedMethods.contains(m),
            onSelected: (v) => setState(() {
              if (v) {
                _selectedMethods.add(m);
              } else {
                _selectedMethods.remove(m);
              }
            }),
          ),
      ],
    );
  }

  Widget _ingredientEditor() {
    return Column(
      children: [
        for (var i = 0; i < _ingredients.length; i++) ...[
          Row(
            children: [
              SizedBox(
                width: 16,
                child: Checkbox(
                  value: _ingredients[i].isMain,
                  onChanged: (v) => setState(() => _ingredients[i].isMain = v ?? false),
                  visualDensity: VisualDensity.compact,
                ),
              ),
              Expanded(
                flex: 3,
                child: TextFormField(
                  controller: _ingredients[i].nameCtrl,
                  decoration: _inputDeco('食材名'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: _ingredients[i].qtyCtrl,
                  decoration: _inputDeco('2 个'),
                ),
              ),
              IconButton(
                iconSize: 18,
                tooltip: '删除这行',
                onPressed: () => setState(() => _ingredients.removeAt(i)),
                icon: const Icon(Icons.remove_circle_outline, color: ZaojiColors.muted),
              ),
            ],
          ),
        ],
        OutlinedButton.icon(
          onPressed: () => setState(() => _ingredients.add(_IngredientRow(
                nameCtrl: TextEditingController(),
                qtyCtrl: TextEditingController(),
              ))),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('添加食材'),
        ),
      ],
    );
  }

  Widget _stepEditor() {
    return Column(
      children: [
        for (var i = 0; i < _stepCtrls.length; i++) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              border: Border.all(color: ZaojiColors.lineSoft),
              borderRadius: BorderRadius.circular(ZaojiRadius.md),
              color: Colors.white,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: ZaojiColors.accent.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text('${i + 1}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ZaojiColors.accent)),
                    ),
                    const SizedBox(width: 8),
                    const Text('步骤', style: TextStyle(fontSize: 12, color: ZaojiColors.muted)),
                    const Spacer(),
                    IconButton(
                      iconSize: 16,
                      tooltip: '删除',
                      onPressed: () => setState(() => _stepCtrls.removeAt(i)),
                      icon: const Icon(Icons.delete_outline, color: ZaojiColors.muted),
                    ),
                  ],
                ),
                TextFormField(
                  controller: _stepCtrls[i],
                  maxLines: 3,
                  minLines: 2,
                  decoration: _inputDeco('描述这一步，直接写时间关键词（如「小火炖 20 分钟」）'),
                ),
              ],
            ),
          ),
        ],
        OutlinedButton.icon(
          onPressed: () => setState(() => _stepCtrls.add(TextEditingController())),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('添加步骤'),
        ),
      ],
    );
  }

  Widget _notesField() {
    return TextFormField(
      controller: _notesCtrl,
      maxLines: 4,
      minLines: 3,
      decoration: _inputDeco('记录翻车点、替代食材、火候提醒…'),
    );
  }

  // ── 样式助手 ──

  InputDecoration _inputDeco(String hint) {
    return InputDecoration(
      isCollapsed: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ZaojiRadius.sm),
        borderSide: const BorderSide(color: ZaojiColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ZaojiRadius.sm),
        borderSide: const BorderSide(color: ZaojiColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ZaojiRadius.sm),
        borderSide: const BorderSide(color: ZaojiColors.accent),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      hintText: hint,
      hintStyle: const TextStyle(fontSize: 13, color: ZaojiColors.muted),
    );
  }

  Widget _fieldLabel(String text, {bool required = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(text, style: ZaojiText.body(fontSize: 12.5, fontWeight: FontWeight.w600, color: ZaojiColors.ink2)),
          if (required) const Text(' *', style: TextStyle(color: ZaojiColors.accent, fontSize: 13, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _SectionHead extends StatelessWidget {
  const _SectionHead({required this.num, required this.title});
  final String num;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(num, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ZaojiColors.accent, letterSpacing: 0.5)),
          const SizedBox(width: 8),
          Text(title, style: ZaojiText.display(fontSize: 17, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

class _IngredientRow {
  final TextEditingController nameCtrl;
  final TextEditingController qtyCtrl;
  bool isMain;

  _IngredientRow({required this.nameCtrl, required this.qtyCtrl, this.isMain = false});
}
