import 'package:flutter/material.dart';

import '../data/recipe_store.dart';
import '../data/store_scope.dart';
import '../models.dart';
import '../theme.dart';
import 'recipe_detail_page.dart';

/// 厨房页（R28）：库存 + 清空冰箱推荐。
///
/// 原型里「备菜、库存、推荐都在这里」的厨房段，落到 App 就是底部第三个 tab；
/// 备菜清单本身仍挂在每一餐里（菜单详情进），这里不放重复入口
/// ——控件去重要按场景查覆盖，删入口前先确认每条路径都有门。
class KitchenPage extends StatefulWidget {
  const KitchenPage({super.key, this.initialSegment = 0});

  final int initialSegment;

  @override
  State<KitchenPage> createState() => _KitchenPageState();
}

class _KitchenPageState extends State<KitchenPage> {
  late int _segment = widget.initialSegment;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return Scaffold(
      backgroundColor: ZaojiColors.paper,
      appBar: AppBar(
        titleSpacing: 16,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text('厨房'),
            SizedBox(height: 1),
            Text('家里有什么、能做什么',
                style:
                    TextStyle(fontSize: 11, color: ZaojiColors.muted)),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 0, label: Text('库存')),
                ButtonSegment(value: 1, label: Text('能做什么')),
              ],
              selected: {_segment},
              onSelectionChanged: (s) =>
                  setState(() => _segment = s.first),
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: ZaojiColors.accent,
                selectedForegroundColor: Colors.white,
              ),
            ),
          ),
          Expanded(
            // 监听 store：步进/添加/同步引擎拉回的新库存都要即时现身
            // （R20 同类教训：页面只 build 一次 = 数据是照片不是实况）
            child: ListenableBuilder(
              listenable: store,
              builder: (context, _) => _segment == 0
                  ? _PantryTab(store: store)
                  : _RecommendTab(store: store),
            ),
          ),
        ],
      ),
      floatingActionButton: _segment == 0
          ? FloatingActionButton(
              key: const ValueKey('pantry-add-fab'),
              backgroundColor: ZaojiColors.accent,
              onPressed: () => _PantrySheet.show(context, null),
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}

// ────────────────────────────── 库存 ──────────────────────────────

class _PantryTab extends StatefulWidget {
  const _PantryTab({required this.store});

  final RecipeStore store;

  @override
  State<_PantryTab> createState() => _PantryTabState();
}

class _PantryTabState extends State<_PantryTab> {
  final _searchCtrl = TextEditingController();
  String _cat = 'all';

  static const _storageCats = ['冷藏', '冷冻', '常温', '干货'];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.store.pantryItems;
    final q = _searchCtrl.text.trim();
    final now = DateTime.now();

    final bad = items
        .where((p) => p.have && p.expState(now) == 'bad')
        .length;
    final soon = items
        .where((p) => p.have && p.expState(now) == 'soon')
        .length;
    final low = items.where((p) => p.have && (p.qtyValue ?? 1) <= 1).length;
    final out = items.where((p) => !p.have).length;

    var shown = items.where((p) {
      if (_cat != 'all' && (p.category ?? '') != _cat) return false;
      if (q.isNotEmpty && !p.name.contains(q)) return false;
      return true;
    }).toList();
    // 「没有」的沉底，其余按到期近的在前（不猜排序=用户找不到快过期的东西）
    shown.sort((a, b) {
      if (a.have != b.have) return a.have ? -1 : 1;
      final ae = a.expireAt ?? '9999', be = b.expireAt ?? '9999';
      return ae.compareTo(be);
    });

    final byCat = <String, List<PantryItem>>{};
    for (final p in shown) {
      byCat.putIfAbsent(p.category ?? '未分类', () => []).add(p);
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      children: [
        // 统计卡（原型头部那块）
        Container(
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(ZaojiRadius.lg),
            border: Border.all(color: ZaojiColors.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: [
                  Text('${items.length}',
                      style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          height: 1)),
                  const Text('样食材在家里',
                      style:
                          TextStyle(fontSize: 12.5, color: ZaojiColors.muted)),
                  if (bad > 0)
                    _statBadge('$bad 今天到期', ZaojiColors.accent),
                  if (soon > 0)
                    _statBadge('$soon 快到期', ZaojiColors.amber),
                  if (low > 0) _statBadge('$low 快没了', ZaojiColors.muted),
                  if (out > 0) _statBadge('$out 没有', ZaojiColors.muted),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _searchCtrl,
                style: const TextStyle(fontSize: 13.5),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜食材…',
                  prefixIcon: const Icon(Icons.search, size: 18),
                  filled: true,
                  fillColor: ZaojiColors.paper,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(ZaojiRadius.md),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final c in ['all', ..._storageCats])
                    ChoiceChip(
                      label: Text(c == 'all' ? '全部' : c),
                      selected: _cat == c,
                      onSelected: (_) => setState(() => _cat = c),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 60),
            child: Center(
              child: Text(
                '库存还是空的\n点右下角 + 记一样家里有的食材',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13,
                    height: 1.8,
                    color: ZaojiColors.muted),
              ),
            ),
          ),
        for (final entry in byCat.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 10, 0, 8),
            child: Row(
              children: [
                Text(entry.key,
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: ZaojiColors.ink2)),
                const SizedBox(width: 6),
                Text('${entry.value.length}',
                    style: const TextStyle(
                        fontSize: 11.5, color: ZaojiColors.muted)),
              ],
            ),
          ),
          for (final p in entry.value) _PantryRow(item: p, store: widget.store),
          const SizedBox(height: 8),
        ],
      ],
    );
  }

  Widget _statBadge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: .1),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w600, color: color)),
      );
}

class _PantryRow extends StatelessWidget {
  const _PantryRow({required this.item, required this.store});

  final PantryItem item;
  final RecipeStore store;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final exp = item.expState(now);
    final dotColor = !item.have
        ? ZaojiColors.muted
        : exp == 'bad'
            ? ZaojiColors.accent
            : exp == 'soon'
                ? ZaojiColors.amber
                : const Color(0xFF37634A);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(color: ZaojiColors.line),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
                color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _PantrySheet.show(context, item),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(item.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600)),
                      ),
                      if (item.isStaple)
                        const Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Text('常备',
                              style: TextStyle(
                                  fontSize: 10, color: ZaojiColors.muted)),
                        ),
                    ],
                  ),
                  if (exp.isNotEmpty || !item.have)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        !item.have
                            ? '记为「没有」'
                            : exp == 'bad'
                                ? '今天到期'
                                : '${item.expireAt!.substring(5).replaceFirst('-', '/')} 到期',
                        style: TextStyle(
                            fontSize: 11,
                            color: exp == 'bad'
                                ? ZaojiColors.accent
                                : ZaojiColors.amber),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (item.isStaple || item.qtyValue == null)
            Text(item.qtyLabel,
                style: const TextStyle(
                    fontSize: 12.5, color: ZaojiColors.muted))
          else
            // 步进器：±1 不超过两次点击（FR-PAN-03）
            Row(
              children: [
                _stepBtn(Icons.remove,
                    '减少 ${item.name}', () => store.adjustPantry(item.id, -1)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(item.qtyLabel.isEmpty ? '有' : item.qtyLabel,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                _stepBtn(Icons.add, '增加 ${item.name}',
                    () => store.adjustPantry(item.id, 1)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _stepBtn(IconData icon, String label, VoidCallback onTap) =>
      IconButton(
        icon: Icon(icon, size: 16),
        tooltip: label,
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        color: ZaojiColors.ink2,
      );
}

/// 新增 / 编辑库存条目的底部表单。id 传 null = 新增。
class _PantrySheet extends StatefulWidget {
  const _PantrySheet({required this.item});

  final PantryItem? item;

  static Future<void> show(BuildContext context, PantryItem? item) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: ZaojiColors.paper,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(ZaojiRadius.xl))),
      builder: (_) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: _PantrySheet(item: item),
      ),
    );
  }

  @override
  State<_PantrySheet> createState() => _PantrySheetState();
}

class _PantrySheetState extends State<_PantrySheet> {
  late final _nameCtrl = TextEditingController(text: widget.item?.name ?? '');
  late final _qtyCtrl = TextEditingController(
      text: widget.item?.qtyValue == null
          ? ''
          : '${widget.item!.qtyValue!.round()}');
  late final _unitCtrl = TextEditingController(text: widget.item?.qtyUnit ?? '');
  late String _cat = widget.item?.category ?? '冷藏';
  late bool _have = widget.item?.have ?? true;
  late bool _staple = widget.item?.isStaple ?? false;
  late String? _expire = widget.item?.expireAt;

  static const _cats = ['冷藏', '冷冻', '常温', '干货'];

  @override
  void dispose() {
    _nameCtrl.dispose();
    _qtyCtrl.dispose();
    _unitCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    final store = StoreScope.of(context);
    await store.upsertPantry(
      id: widget.item?.id,
      name: name,
      category: _cat,
      qtyValue: double.tryParse(_qtyCtrl.text.trim()),
      qtyUnit: _unitCtrl.text.trim().isEmpty ? null : _unitCtrl.text.trim(),
      have: _have,
      expireAt: _expire,
      isStaple: _staple,
    );
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final item = widget.item;
    if (item == null) return;
    final store = StoreScope.of(context);
    await store.deletePantry(item.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        key: const ValueKey('pantry-sheet'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.item == null ? '添加食材' : '编辑「${widget.item!.name}」',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('pantry-name'),
            controller: _nameCtrl,
            style: const TextStyle(fontSize: 14),
            decoration: const InputDecoration(
              labelText: '名称',
              isDense: true,
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('pantry-qty'),
                  controller: _qtyCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                      labelText: '数量（可空=只记有）', isDense: true, filled: true, fillColor: Colors.white),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 90,
                child: TextField(
                  key: const ValueKey('pantry-unit'),
                  controller: _unitCtrl,
                  style: const TextStyle(fontSize: 14),
                  decoration: const InputDecoration(
                      labelText: '单位', isDense: true, filled: true, fillColor: Colors.white),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              for (final c in _cats)
                ChoiceChip(
                  label: Text(c),
                  selected: _cat == c,
                  onSelected: (_) => setState(() => _cat = c),
                ),
            ],
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            key: const ValueKey('pantry-have'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('家里有', style: TextStyle(fontSize: 13.5)),
            value: _have,
            onChanged: (v) => setState(() => _have = v),
          ),
          SwitchListTile(
            key: const ValueKey('pantry-staple'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('常备调料（不算缺）',
                style: TextStyle(fontSize: 13.5)),
            value: _staple,
            onChanged: (v) => setState(() => _staple = v),
          ),
          Row(
            children: [
              Expanded(
                child: Text(_expire == null ? '保质期：未填' : '保质期：$_expire',
                    style: const TextStyle(
                        fontSize: 13, color: ZaojiColors.ink2)),
              ),
              TextButton(
                onPressed: () async {
                  final d = await showDatePicker(
                      context: context,
                      initialDate: DateTime.now().add(const Duration(days: 3)),
                      firstDate: DateTime.now().subtract(const Duration(days: 365)),
                      lastDate: DateTime.now().add(const Duration(days: 3650)));
                  if (d != null && mounted) {
                    setState(() => _expire =
                        '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}');
                  }
                },
                child: const Text('选择'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (widget.item != null)
                TextButton(
                  key: const ValueKey('pantry-delete'),
                  onPressed: _delete,
                  child: const Text('删除',
                      style: TextStyle(color: ZaojiColors.muted)),
                ),
              const Spacer(),
              FilledButton(
                key: const ValueKey('pantry-save'),
                onPressed: _save,
                style: FilledButton.styleFrom(
                    backgroundColor: ZaojiColors.accent),
                child: const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────── 能做什么 ────────────────────────────

class _RecommendTab extends StatelessWidget {
  const _RecommendTab({required this.store});

  final RecipeStore store;

  @override
  Widget build(BuildContext context) {
    final r = store.recommendByPantry();
    final canCook = (r['canCook'] as List).cast<Map<String, Object?>>();
    final almost = (r['almostThere'] as List).cast<Map<String, Object?>>();
    final need = (r['needShopping'] as List).cast<Map<String, Object?>>();

    if (store.pantryItems.isEmpty) {
      return const Center(
        child: Text(
          '先在「库存」里记几样家里有的\n就能算出今天能做什么',
          textAlign: TextAlign.center,
          style:
              TextStyle(fontSize: 13, height: 1.8, color: ZaojiColors.muted),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        _group('能做', canCook.length, const Color(0xFF37634A), canCook, context,
            empty: '都不齐——先看「要买不少」那组挑一样补？'),
        _group('差一点', almost.length, ZaojiColors.amber, almost, context,
            empty: '没有只差一两样的菜'),
        _group('要买不少', need.length, ZaojiColors.muted, need, context,
            empty: '库存把菜谱全罩住了，好极了'),
      ],
    );
  }

  Widget _group(String title, int n, Color color,
      List<Map<String, Object?>> list, BuildContext context,
      {required String empty}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 14, 0, 8),
          child: Row(
            children: [
              Text('$title（$n）',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: color)),
            ],
          ),
        ),
        if (list.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 0, 6),
            child: Text(empty,
                style:
                    const TextStyle(fontSize: 12, color: ZaojiColors.muted)),
          ),
        for (final e in list)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(ZaojiRadius.md),
              border: Border.all(color: ZaojiColors.line),
            ),
            child: InkWell(
              onTap: () {
                final recipe = store.recipeById('${e['id']}');
                if (recipe == null) return;
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => RecipeDetailPage(recipe: recipe)));
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${e['name']}',
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  if ((e['missing'] as List).isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final m in (e['missing'] as List)
                            .cast<Map<Object?, Object?>>())
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: m['isMain'] == true
                                  ? ZaojiColors.accent.withValues(alpha: .1)
                                  : ZaojiColors.amberBg,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '缺·${m['name']}',
                              style: TextStyle(
                                  fontSize: 10.5,
                                  color: m['isMain'] == true
                                      ? ZaojiColors.accent
                                      : ZaojiColors.amber),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}
