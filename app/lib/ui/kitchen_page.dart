import 'package:flutter/material.dart';

import '../data/recipe_store.dart';
import '../data/store_scope.dart';
import '../data/sync/sync_scope.dart';
import 'ai_settings_page.dart';
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
      backgroundColor: context.zj.paper,
      appBar: AppBar(
        titleSpacing: 16,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('厨房'),
            SizedBox(height: 1),
            Text('家里有什么、能做什么',
                style:
                    TextStyle(fontSize: 11, color: context.zj.muted)),
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
                ButtonSegment(value: 2, label: Text('购物清单')),
              ],
              selected: {_segment},
              onSelectionChanged: (s) =>
                  setState(() => _segment = s.first),
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: context.zj.accent,
                selectedForegroundColor: context.zj.onAccent,
              ),
            ),
          ),
          Expanded(
            // 监听 store：步进/添加/同步引擎拉回的新库存都要即时现身
            // （R20 同类教训：页面只 build 一次 = 数据是照片不是实况）
            child: ListenableBuilder(
              listenable: store,
              builder: (context, _) => switch (_segment) {
                0 => _PantryTab(store: store),
                1 => _RecommendTab(store: store),
                _ => _ShoppingTab(store: store),
              },
            ),
          ),
        ],
      ),
      floatingActionButton: _segment == 0
          ? FloatingActionButton(
              key: const ValueKey('pantry-add-fab'),
              backgroundColor: context.zj.accent,
              onPressed: () => _PantrySheet.show(context, null),
              child: const Icon(Icons.add),
            )
          : _segment == 2
              ? FloatingActionButton(
                  key: const ValueKey('shopping-add-fab'),
                  backgroundColor: context.zj.accent,
                  onPressed: () => _addShoppingItem(context),
                  child: const Icon(Icons.add),
                )
              : null,
    );
  }

  /// 手动加一样进购物清单：轻量两字段对话框（名称必填）。
  Future<void> _addShoppingItem(BuildContext context) async {
    final nameCtrl = TextEditingController();
    final qtyCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('加进购物清单'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('shopping-name'),
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: '名称'),
            ),
            TextField(
              controller: qtyCtrl,
              decoration:
                  const InputDecoration(labelText: '要多少（可空，如 500g / 2个）'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              key: const ValueKey('shopping-save'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('加入')),
        ],
      ),
    );
    if (ok != true || nameCtrl.text.trim().isEmpty) return;
    if (!context.mounted) return; // 对话框挂着时页面可能被销毁（R22 弹层同族纪律）
    final store = StoreScope.of(context);
    await store.addShoppingItems([
      (
        name: nameCtrl.text.trim(),
        qtyText: qtyCtrl.text.trim().isEmpty ? null : qtyCtrl.text.trim(),
        recipeId: null
      )
    ]);
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
    // v7：「快没了」从**猜**变成**记**。
    // 之前是 `qtyValue <= 1` 的启发式，一瓶 500ml 的油和一把剩两根的粉丝
    // 会被同一行代码判成同一种东西；现在三态是用户在库存表上自己标的。
    final low = items.where((p) => p.status == PantryStock.low).length;
    final out = items.where((p) => p.status == PantryStock.none).length;

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
            color: context.zj.surface,
            borderRadius: BorderRadius.circular(ZaojiRadius.lg),
            border: Border.all(color: context.zj.line),
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
                  Text('样食材在家里',
                      style:
                          TextStyle(fontSize: 12.5, color: context.zj.muted)),
                  if (bad > 0)
                    _statBadge('$bad 今天到期', context.zj.accent),
                  if (soon > 0)
                    _statBadge('$soon 快到期', context.zj.amber),
                  if (low > 0) _statBadge('$low 快没了', context.zj.muted),
                  if (out > 0) _statBadge('$out 没有', context.zj.muted),
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
                  fillColor: context.zj.paper,
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
          Padding(
            padding: EdgeInsets.only(top: 60),
            child: Center(
              child: Text(
                '库存还是空的\n点右下角 + 记一样家里有的食材',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13,
                    height: 1.8,
                    color: context.zj.muted),
              ),
            ),
          ),
        for (final entry in byCat.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 10, 0, 8),
            child: Row(
              children: [
                Text(entry.key,
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: context.zj.ink2)),
                const SizedBox(width: 6),
                Text('${entry.value.length}',
                    style: TextStyle(
                        fontSize: 11.5, color: context.zj.muted)),
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

/// 库存行下面那行小字里的一段（状态 / 保质期 / 存储 / 购入 / 备注）。
Widget _meta(String text, Color color, BuildContext context) => Text(
      text,
      style: TextStyle(fontSize: 11, color: color),
    );

class _PantryRow extends StatelessWidget {
  const _PantryRow({required this.item, required this.store});

  final PantryItem item;
  final RecipeStore store;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final exp = item.expState(now);
    // 状态点 = 三态（原型 `.lvl`）；保质期是另一件事，走下面那行文字徽标。
    // 之前这里把"今天到期"画成红点、把三态画成一个开关，两件事挤在一个点上，
    // 结果哪个都读不准。
    final dotColor = switch (item.status) {
      PantryStock.have => exp == 'bad'
          ? context.zj.accent
          : exp == 'soon'
              ? context.zj.amber
              : context.zj.tagIngredient,
      PantryStock.low => context.zj.amber2,
      PantryStock.none => context.zj.line,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.zj.surface,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(color: context.zj.line),
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
                        Padding(
                          padding: EdgeInsets.only(left: 6),
                          child: Text('常备',
                              style: TextStyle(
                                  fontSize: 10, color: context.zj.muted)),
                        ),
                    ],
                  ),
                  Builder(builder: (context) {
                    // 元信息一行：状态 → 保质期 → 存储位置 → 购入 → 备注。
                    // 缺哪项就不显示哪项（不写"未填"占位——列表是扫读的，
                    // 一排"未填"只会把真正有用的那条挤下去）。
                    final bits = <Widget>[];
                    if (item.status != PantryStock.have) {
                      bits.add(_meta(
                          item.status == PantryStock.none ? '没有' : '快没了',
                          item.status == PantryStock.none
                              ? context.zj.muted
                              : context.zj.amber,
                          context));
                    } else if (exp == 'bad') {
                      bits.add(_meta('今天到期', context.zj.accent, context));
                    } else if (exp == 'soon') {
                      bits.add(_meta(
                          '${item.expireAt!.substring(5).replaceFirst('-', '/')} 到期',
                          context.zj.amber,
                          context));
                    }
                    final st = item.storage;
                    if (st != null && st.isNotEmpty) {
                      bits.add(_meta(st, context.zj.muted, context));
                    }
                    final b = item.boughtAt;
                    if (b != null && b.length >= 10) {
                      bits.add(_meta(
                          '购于 ${b.substring(5).replaceFirst('-', '/')}',
                          context.zj.muted,
                          context));
                    }
                    final note = item.note;
                    if (note != null && note.isNotEmpty) {
                      bits.add(_meta(note, context.zj.accentDeep, context));
                    }
                    if (bits.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Wrap(spacing: 8, runSpacing: 2, children: bits),
                    );
                  }),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (item.isStaple || item.qtyValue == null)
            Text(item.qtyLabel,
                style: TextStyle(
                    fontSize: 12.5, color: context.zj.muted))
          else
            // 步进器：±1 不超过两次点击（FR-PAN-03）
            Row(
              children: [
                _stepBtn(context, Icons.remove,
                    '减少 ${item.name}', () => store.adjustPantry(item.id, -1)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text(item.qtyLabel.isEmpty ? '有' : item.qtyLabel,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
                _stepBtn(context, Icons.add, '增加 ${item.name}',
                    () => store.adjustPantry(item.id, 1)),
              ],
            ),
        ],
      ),
    );
  }

  Widget _stepBtn(BuildContext context, IconData icon, String label,
          VoidCallback onTap) =>
      IconButton(
        icon: Icon(icon, size: 16),
        tooltip: label,
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
        color: context.zj.ink2,
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
      backgroundColor: context.zj.paper,
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
  late PantryStock _status = widget.item?.status ?? PantryStock.have;
  late bool _staple = widget.item?.isStaple ?? false;
  late String? _expire = widget.item?.expireAt;
  // v7（FR-PAN-01）：存储位置 / 购入日期 / 备注。三者都可空——
  // 库存是辅助决策不是账本，空着就空着，不替用户填一个看起来完整的值。
  late String? _storage = widget.item?.storage;
  late String? _bought = widget.item?.boughtAt;
  late final _noteCtrl = TextEditingController(text: widget.item?.note ?? '');

  static const _cats = ['冷藏', '冷冻', '常温', '干货'];
  static const _storages = ['冷藏', '冷冻', '常温'];

  @override
  void dispose() {
    _nameCtrl.dispose();
    _qtyCtrl.dispose();
    _unitCtrl.dispose();
    _noteCtrl.dispose();
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
      status: _status,
      expireAt: _expire,
      isStaple: _staple,
      storage: _storage,
      boughtAt: _bought,
      note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
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
            decoration: InputDecoration(
              labelText: '名称',
              isDense: true,
              filled: true,
              fillColor: context.zj.surface,
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
                  decoration: InputDecoration(
                      labelText: '数量（可空=只记有）', isDense: true, filled: true, fillColor: context.zj.surface),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 90,
                child: TextField(
                  key: const ValueKey('pantry-unit'),
                  controller: _unitCtrl,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                      labelText: '单位', isDense: true, filled: true, fillColor: context.zj.surface),
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
          // 三态（FR-PAN-01）：替代原来那个「家里有」开关。
          // 用 chips 不用循环点击——点一下就切一档，看一眼就知道现在在哪档。
          Wrap(
            key: const ValueKey('pantry-status'),
            spacing: 8,
            children: [
              for (final s in PantryStock.values)
                ChoiceChip(
                  label: Text(s.label),
                  selected: _status == s,
                  onSelected: (_) => setState(() => _status = s),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text('存储位置',
              style: TextStyle(fontSize: 12, color: context.zj.muted)),
          Wrap(
            key: const ValueKey('pantry-storage'),
            spacing: 8,
            children: [
              for (final s in _storages)
                ChoiceChip(
                  label: Text(s),
                  // 再点一次取消：没填就是没填，库存不该有"默认冷藏"
                  selected: _storage == s,
                  onSelected: (_) =>
                      setState(() => _storage = _storage == s ? null : s),
                ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('pantry-note'),
            controller: _noteCtrl,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              labelText: '备注（可空）',
              isDense: true,
              filled: true,
              fillColor: context.zj.surface,
            ),
          ),
          const SizedBox(height: 4),
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
                    style: TextStyle(
                        fontSize: 13, color: context.zj.ink2)),
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
          Row(
            children: [
              Expanded(
                child: Text(_bought == null ? '购入日期：未填' : '购入日期：$_bought',
                    style: TextStyle(
                        fontSize: 13, color: context.zj.ink2)),
              ),
              TextButton(
                key: const ValueKey('pantry-bought'),
                onPressed: () async {
                  final d = await showDatePicker(
                      context: context,
                      initialDate: DateTime.now(),
                      firstDate: DateTime.now().subtract(const Duration(days: 3650)),
                      lastDate: DateTime.now().add(const Duration(days: 1)));
                  if (d != null && mounted) {
                    setState(() => _bought =
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
                  child: Text('删除',
                      style: TextStyle(color: context.zj.muted)),
                ),
              const Spacer(),
              FilledButton(
                key: const ValueKey('pantry-save'),
                onPressed: _save,
                style: FilledButton.styleFrom(
                    backgroundColor: context.zj.accent),
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

// ──────────────────────────── 购物清单（R30） ────────────────────────────

/// 买前可勾、买回一键入库。未购在上、已购沉底——清单的动线就是购物的动线。
class _ShoppingTab extends StatelessWidget {
  const _ShoppingTab({required this.store});

  final RecipeStore store;

  @override
  Widget build(BuildContext context) {
    final items = [...store.shoppingItems]
      ..sort((a, b) => (a.bought ? 1 : 0).compareTo(b.bought ? 1 : 0));
    final boughtCount = items.where((x) => x.bought).length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 96),
      children: [
        if (items.isEmpty)
          Padding(
            padding: EdgeInsets.only(top: 60),
            child: Center(
              child: Text(
                '购物清单是空的\n去「能做什么」把缺的加进来，或点 + 手动记',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 13,
                    height: 1.8,
                    color: context.zj.muted),
              ),
            ),
          ),
        if (boughtCount > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text('已买 $boughtCount 样，买齐了入库变库存',
                      style: TextStyle(
                          fontSize: 12, color: context.zj.muted)),
                ),
                FilledButton.icon(
                  key: const ValueKey('shopping-stockin'),
                  onPressed: () async {
                    final n = await store.stockInBoughtShopping();
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('已入库 $n 样'),
                        duration: const Duration(seconds: 2)));
                  },
                  icon: const Icon(Icons.download, size: 16),
                  label: Text('购物入库（$boughtCount）'),
                  style: FilledButton.styleFrom(
                      backgroundColor: context.zj.accent),
                ),
              ],
            ),
          ),
        for (final x in items)
          Container(
            key: ValueKey('shopping-row-${x.id}'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: context.zj.surface,
              borderRadius: BorderRadius.circular(ZaojiRadius.md),
              border: Border.all(color: context.zj.line),
            ),
            child: Row(
              children: [
                Checkbox(
                  value: x.bought,
                  activeColor: context.zj.accent,
                  onChanged: (v) =>
                      store.toggleShoppingBought(x.id, v ?? false),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        x.name +
                            (x.qtyText != null && x.qtyText!.isNotEmpty
                                ? ' · ${x.qtyText}'
                                : ''),
                        style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            decoration: x.bought
                                ? TextDecoration.lineThrough
                                : null,
                            color: x.bought
                                ? context.zj.muted
                                : context.zj.ink),
                      ),
                      Text('来源：${x.sourceLabel}',
                          style: TextStyle(
                              fontSize: 10.5, color: context.zj.muted)),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close,
                      size: 16, color: context.zj.muted),
                  tooltip: '移除 ${x.name}',
                  onPressed: () => store.removeShopping(x.id),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

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
      return Center(
        child: Text(
          '先在「库存」里记几样家里有的\n就能算出今天能做什么',
          textAlign: TextAlign.center,
          style:
              TextStyle(fontSize: 13, height: 1.8, color: context.zj.muted),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        _AiRecoSection(store: store),
        _group('能做', canCook.length, context.zj.tagIngredient, canCook, context,
            empty: '都不齐——先看「要买不少」那组挑一样补？'),
        _group('差一点', almost.length, context.zj.amber, almost, context,
            empty: '没有只差一两样的菜'),
        _group('要买不少', need.length, context.zj.muted, need, context,
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
                    TextStyle(fontSize: 12, color: context.zj.muted)),
          ),
        for (final e in list)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: context.zj.surface,
              borderRadius: BorderRadius.circular(ZaojiRadius.md),
              border: Border.all(color: context.zj.line),
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
                                  ? context.zj.accent.withValues(alpha: .1)
                                  : context.zj.amberBg,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '缺·${m['name']}',
                              style: TextStyle(
                                  fontSize: 10.5,
                                  color: m['isMain'] == true
                                      ? context.zj.accent
                                      : context.zj.amber),
                            ),
                          ),
                      ],
                    ),
                    // FR-RECO-04：缺项一键加进购物清单（另一台设备上也能看到）
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        key: ValueKey('reco-shop-${e['id']}'),
                        onPressed: () async {
                          final n = await store.addShoppingItems(
                            [
                              for (final m in (e['missing'] as List)
                                  .cast<Map<Object?, Object?>>())
                                (
                                  name: '${m['name']}',
                                  qtyText: m['qtyText'] == null ||
                                          '${m['qtyText']}'.isEmpty
                                      ? null
                                      : '${m['qtyText']}',
                                  recipeId: '${e['id']}',
                                )
                            ],
                            source: 'reco',
                          );
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text(n == 0
                                    ? '缺的都已经在清单里了'
                                    : '已把 $n 样缺的加进购物清单'),
                                duration: const Duration(seconds: 2)),
                          );
                        },
                        child: Text('把缺的加进清单',
                            style: TextStyle(
                                fontSize: 12,
                                color: context.zj.accent)),
                      ),
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

/// R31 · 「让 AI 推荐」区（FR-AI-40~48）。
///
/// 与本地匹配的关系是**补集**：本地三组只看你记过的菜，AI 推「你现在做得成、
/// 但库里没记录」的菜——所以卡上必须标注「AI 推荐 · 不在你的菜谱中」（FR-AI-44），
/// 加入前要确认（FR-AI-46），忽略只在本次会话生效（FR-AI-47）。
class _AiRecoSection extends StatefulWidget {
  const _AiRecoSection({required this.store});

  final RecipeStore store;

  @override
  State<_AiRecoSection> createState() => _AiRecoSectionState();
}

class _AiRecoSectionState extends State<_AiRecoSection> {
  bool _busy = false;
  List<Map<String, Object?>>? _dishes;
  String? _error;
  final Set<String> _ignored = {};

  Future<void> _ask() async {
    // SyncScope 可选：个别测试脱引擎 pump 推荐页（R27 详情页同族教训）
    final engine = context.getInheritedWidgetOfExactType<SyncScope>()?.engine;
    if (engine == null) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '还没接入家庭服务端';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await engine.aiCall('/api/ai/recommend', {
        'pantry': [
          for (final p in widget.store.pantryItems)
            if (p.have) {'name': p.name, 'amount': p.qtyLabel}
        ],
        'existing': [for (final r in widget.store.recipes) r.name],
      });
      if (res['ok'] != true) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _error = '${res['message'] ?? '推荐失败'}';
        });
        return;
      }
      final dishes = ((res['result'] as Map)['dishes'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, Object?>())
          .toList();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _dishes = dishes;
      });
    } catch (e) {
      if (!mounted) return;
      final t = '$e';
      setState(() {
        _busy = false;
        _error = t.contains('401') || t.contains('StateError')
            ? '还没配置大模型 · 我的 → 大模型能力'
            : t.contains('未启用')
                ? '「AI 推荐菜品」当前是关闭的，可在配置页打开'
                : t;
      });
    }
  }

  Future<void> _adopt(Map<String, Object?> d) async {
    final name = '${d['name']}';
    final steps = (d['steps'] as List? ?? const []).map((e) => '$e').toList();
    final ings =
        (d['ingredients'] as List? ?? const []).whereType<Map>().toList();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: context.zj.paper,
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(ZaojiRadius.xl))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          key: const ValueKey('ai-adopt-confirm'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('加入「$name」？',
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(
              '食材 ${ings.length} 样 · 步骤 ${steps.length} 步 · '
              '难度 ${d['difficulty'] ?? 1} · 约 ${d['self_time'] ?? 0} 分钟\n'
              '加入后来源会标记为 AI，可以照常逐项修改。',
              style: TextStyle(
                  fontSize: 12.5, height: 1.8, color: context.zj.ink2),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('先不')),
                const Spacer(),
                FilledButton(
                  key: const ValueKey('ai-adopt-yes'),
                  onPressed: () => Navigator.pop(ctx, true),
                  style: FilledButton.styleFrom(
                      backgroundColor: context.zj.accent),
                  child: const Text('加入我的菜谱'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final engine =
        context.getInheritedWidgetOfExactType<SyncScope>()?.engine;
    await widget.store.createRecipe(RecipeDraft(
      name: name,
      sub: '${d['sub'] ?? ''}',
      difficulty: (d['difficulty'] as num?)?.round().clamp(1, 3) ?? 1,
      selfTime: (d['self_time'] as num?)?.round() ?? 0,
      servings: (d['servings'] as num?)?.round() ?? 2,
      ingredients: [
        for (final i in ings)
          IngredientDraft(
              name: '${i['name']}',
              qty: '${i['amount'] ?? ''}',
              isMain: false),
      ],
      steps: steps,
      source: 'ai',
      sourceModel: '${engine?.aiStatusCache?['model'] ?? ''}',
    ));
    if (!mounted) return;
    setState(
        () => _dishes = _dishes?.where((x) => '${x['name']}' != name).toList());
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('「$name」已加入，来源标记为 AI'),
        duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) {
    final engine = context.getInheritedWidgetOfExactType<SyncScope>()?.engine;
    final notConfigured = engine?.aiStatusCache != null &&
        engine!.aiStatusCache!['configured'] != true;
    final shown = (_dishes ?? const [])
        .where((d) => !_ignored.contains('${d['name']}'))
        .toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        key: const ValueKey('ai-reco-section'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: context.zj.aiBg,
              borderRadius: BorderRadius.circular(ZaojiRadius.md),
              border: Border.all(color: context.zj.aiBg),
            ),
            child: Row(
              children: [
                Icon(Icons.auto_awesome,
                    size: 18, color: context.zj.ai),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                      '让 AI 按库存再推几道？\n能推出你还没记录过、但现在做得成的菜',
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.6,
                          color: context.zj.ai)),
                ),
                if (_busy)
                  SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: context.zj.ai))
                else
                  TextButton(
                    key: const ValueKey('ai-reco-ask'),
                    onPressed: notConfigured ? _gotoSettings : _ask,
                    child: Text(notConfigured ? '去配置' : '推荐',
                        style: TextStyle(
                            fontSize: 13, color: context.zj.ai)),
                  ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: TextStyle(
                      fontSize: 11.5, color: context.zj.accent)),
            ),
          for (final dish in shown)
            Container(
              margin: const EdgeInsets.only(top: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.zj.surface,
                borderRadius: BorderRadius.circular(ZaojiRadius.md),
                border: Border.all(color: context.zj.aiBg),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('${dish['name']}',
                            style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: context.zj.aiBg,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text('AI 推荐 · 不在你的菜谱中',
                            style: TextStyle(
                                fontSize: 9.5, color: context.zj.ai)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('${dish['reason'] ?? ''}',
                      style: TextStyle(
                          fontSize: 12,
                          height: 1.6,
                          color: context.zj.ink2)),
                  if ((dish['extra_needed'] as List? ?? const [])
                      .isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                          '还要买：${(dish['extra_needed'] as List).join('、')}',
                          style: TextStyle(
                              fontSize: 11.5, color: context.zj.amber)),
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        key: ValueKey('ai-ignore-${dish['name']}'),
                        onPressed: () => setState(
                            () => _ignored.add('${dish['name']}')),
                        child: Text('忽略',
                            style: TextStyle(
                                fontSize: 12,
                                color: context.zj.muted)),
                      ),
                      FilledButton(
                        key: ValueKey('ai-adopt-${dish['name']}'),
                        onPressed: () => _adopt(dish),
                        style: FilledButton.styleFrom(
                            backgroundColor: context.zj.accent,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 8)),
                        child: const Text('加入我的菜谱',
                            style: TextStyle(fontSize: 12.5)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  void _gotoSettings() {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const AiSettingsPage()));
  }
}
