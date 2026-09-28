import 'package:flutter/material.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import '../data/share_text.dart';
import '../data/store_scope.dart';
import '../theme.dart';
import '../widgets/allergen_bits.dart';
import 'menus_page.dart';
import 'share_sheet.dart';

/// 备菜清单（R23）：这一餐所有菜的食材合并视图。
///
/// 清单本体是**派生计算**（shared 的去重/折算/别名），永远等于菜谱现状；
/// 落库的只有备菜板（勾选/排除/手动项）——本机偏好，谁买菜谁勾。
class PrepPage extends StatefulWidget {
  const PrepPage({super.key, required this.menuId});

  final String menuId;

  @override
  State<PrepPage> createState() => _PrepPageState();
}

class _PrepPageState extends State<PrepPage> {
  final _extraName = TextEditingController();
  final _extraQty = TextEditingController();
  final Set<String> _sourcesOpen = {};

  @override
  void dispose() {
    _extraName.dispose();
    _extraQty.dispose();
    super.dispose();
  }

  Future<void> _addExtra() async {
    final name = _extraName.text.trim();
    if (name.isEmpty) return;
    await StoreScope.of(context)
        .addPrepExtra(widget.menuId, name, _extraQty.text);
    _extraName.clear();
    _extraQty.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.zj.paper,
      appBar: AppBar(
        title: const Text('备菜清单'),
        backgroundColor: context.zj.paper,
        actions: [
          // FR-PLAN-10 第一步：这份清单能一键变购物清单（同名去重在 store 里）。
          // 货架排序/导出图片等尾巴记在交接文档——先让"买菜带着手机"成立。
          TextButton.icon(
            key: const ValueKey('prep-to-shop'),
            onPressed: () async {
              final store = StoreScope.of(context);
              final menu = store.menuById(widget.menuId);
              if (menu == null) return;
              final lines = store.mergeForPrep(menu.recipeIds);
              final n = await store.addShoppingItems(
                [
                  for (final l in lines)
                    (
                      name: l.name,
                      qtyText:
                          l.qtyText.isEmpty ? null : l.qtyText,
                      recipeId: null,
                    )
                ],
                source: 'prep',
              );
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(
                      n == 0 ? '清单里已经有了' : '已把 $n 样加进购物清单'),
                  duration: const Duration(seconds: 2)));
            },
            icon: const Icon(Icons.list_alt, size: 16),
            label: const Text('购物清单',
                style: TextStyle(fontSize: 12.5)),
          ),
          // R34 · 把这张清单分享出去（FR-SHARE-08：每行 ☐，对方买菜可逐项打勾）。
          IconButton(
            key: const ValueKey('prep-share'),
            icon: const Icon(Icons.ios_share),
            tooltip: '分享清单',
            onPressed: () {
              final store = StoreScope.of(context);
              final menu = store.menuById(widget.menuId);
              if (menu == null) return;
              final board = store.prepBoardOf(widget.menuId);
              final kept = store
                  .mergeForPrep(menu.recipeIds)
                  .where((l) => !board.excluded.contains(l.key))
                  .where((l) => !board.done.contains(l.key))
                  .toList();
              // 手动项拼成同型的 MergedLine：量走 unparsed（原样显示，不折算）。
              final lines = [
                ...kept,
                for (final e in board.extra.entries)
                  MergedLine(
                    key: 'x:${e.key}',
                    name: e.key,
                    parts: [
                      Amount(
                          value: null,
                          unit: e.value,
                          kind: AmountKind.unparsed,
                          raw: e.value.isEmpty ? '适量' : e.value)
                    ],
                    from: const [],
                    anyVague: false,
                  ),
              ];
              showShareSheet(
                context,
                title: '${menu.day} · ${menu.meal} 备菜清单',
                filename: '灶记-备菜-${menu.day}.txt',
                toggles: [
                  if (lines.any((l) => l.from.length > 1))
                    const ShareToggle('src', '标出来自哪道菜'),
                  const ShareToggle('sig', '署名'),
                ],
                buildText: (on) => sharePrep(
                  day: menu.day,
                  meal: menu.meal,
                  lines: lines,
                  withSources: on.contains('src'),
                  withSignature: on.contains('sig'),
                ),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: StoreScope.of(context),
        builder: (context, _) => _body(context),
      ),
    );
  }

  Widget _body(BuildContext context) {
    final store = StoreScope.of(context);
    final menu = store.menuById(widget.menuId);
    if (menu == null) {
      return Center(
          child: Text('这个菜单已经不存在了',
              style:
                  TextStyle(fontSize: 13, color: context.zj.muted)));
    }
    final board = store.prepBoardOf(widget.menuId);
    final lines = store.mergeForPrep(menu.recipeIds);
    final kept = lines.where((l) => !board.excluded.contains(l.key)).toList();
    final excluded = lines.where((l) => board.excluded.contains(l.key)).toList();
    final open = kept.where((l) => !board.done.contains(l.key)).toList();
    final done = kept.where((l) => board.done.contains(l.key)).toList();
    final extraEntries = board.extra.entries.toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 32),
      children: [
        Text(
          '${dayLabel(menu.day)} · ${menu.meal}',
          style: TextStyle(fontSize: 12, color: context.zj.muted),
        ),
        const SizedBox(height: 12),
        for (final l in open) _line(l.key, l.name, l.qtyText,
            from: l.from, merged: l.isMerged),
        for (final e in extraEntries)
          _line('x:${e.key}', e.key, e.value,
              extra: true, removable: true),
        if (open.isEmpty && extraEntries.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Text('要买要备的都勾完了',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: context.zj.muted)),
          ),
        if (done.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('已备齐',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.zj.muted)),
          const SizedBox(height: 6),
          for (final l in done) _line(l.key, l.name, l.qtyText, dimmed: true),
        ],
        if (excluded.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('已排除 ${excluded.length} 项',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.zj.muted)),
          const SizedBox(height: 6),
          for (final l in excluded)
            _line(l.key, l.name, l.qtyText,
                excludedRow: true, merged: false),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('prep-extra-name'),
                controller: _extraName,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '补一项，如 嫩豆腐',
                  filled: true,
                  fillColor: context.zj.surface,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                    borderSide: BorderSide(color: context.zj.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                    borderSide:
                        BorderSide(color: context.zj.accent, width: 1.4),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 90,
              child: TextField(
                key: const ValueKey('prep-extra-qty'),
                controller: _extraQty,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '分量',
                  filled: true,
                  fillColor: context.zj.surface,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                    borderSide: BorderSide(color: context.zj.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                    borderSide:
                        BorderSide(color: context.zj.accent, width: 1.4),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: const ValueKey('prep-add-extra'),
              onPressed: _addExtra,
              icon: const Icon(Icons.add_circle_outline),
              color: context.zj.accent,
              tooltip: '加上',
            ),
          ],
        ),
      ],
    );
  }

  Widget _line(
    String key,
    String name,
    String qty, {
    List<String> from = const [],
    bool merged = false,
    bool dimmed = false,
    bool excludedRow = false,
    bool extra = false,
    bool removable = false,
  }) {
    final store = StoreScope.of(context);
    final board = store.prepBoardOf(widget.menuId);
    // 板上的键 = 归一键（合并行的 key），显示名可能是「西红柿」这种表面形态。
    final plainKey = extra ? name : key.startsWith('x:') ? key.substring(2) : key;
    final checked = board.done.contains(plainKey);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(6, 4, 10, 4),
      decoration: BoxDecoration(
        color: context.zj.surface,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(color: context.zj.lineSoft),
      ),
      child: Row(
        children: [
          Checkbox(
            key: ValueKey('prep-check-$key'),
            value: checked,
            visualDensity: VisualDensity.compact,
            activeColor: context.zj.ok,
            onChanged: excludedRow
                ? null
                : (on) => store.setPrepDone(widget.menuId, plainKey, on ?? false),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: dimmed ? context.zj.muted : context.zj.ink,
                    decoration:
                        dimmed ? TextDecoration.lineThrough : null,
                  ),
                ),
                // 备菜清单也标过敏原（R40）：这一行的用途是"去买/去洗"，
                // 恰恰是最该知道"这袋虾是给谁买不得"的时刻
                if (!dimmed && store.allergenWarnInRecipes)
                  Builder(builder: (context) {
                    final hits = store
                        .allergenHitsForIngredient(name)
                        .where((h) => h.isAllergy)
                        .toList();
                    if (hits.isEmpty) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Wrap(
                        key: ValueKey('prep-alert-$key'),
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final h in hits)
                            AllergenTag(
                                who: h.memberName,
                                word: h.word,
                                allergy: true),
                        ],
                      ),
                    );
                  }),
                if (merged && from.isNotEmpty)
                  InkWell(
                    onTap: () => setState(() {
                      if (!_sourcesOpen.remove(key)) _sourcesOpen.add(key);
                    }),
                    child: Text(
                      _sourcesOpen.contains(key)
                          ? '来自：${from.join('、')}'
                          : '${from.length} 道菜合并 · 点开看来源',
                      key: ValueKey('prep-sources-$key'),
                      style: TextStyle(
                          fontSize: 11, color: context.zj.muted),
                    ),
                  ),
              ],
            ),
          ),
          Text(
            qty,
            style: TextStyle(
              fontSize: 13,
              color: dimmed ? context.zj.muted : context.zj.ink2,
            ),
          ),
          if (removable)
            IconButton(
              key: ValueKey('prep-remove-$key'),
              icon: const Icon(Icons.close, size: 18),
              color: context.zj.muted,
              onPressed: () => store.removePrepExtra(widget.menuId, name),
            )
          else if (!excludedRow)
            IconButton(
              key: ValueKey('prep-exclude-$key'),
              icon: const Icon(Icons.do_not_disturb_on_outlined, size: 18),
              color: context.zj.muted,
              tooltip: '这餐不用了',
              onPressed: () =>
                  store.setPrepExcluded(widget.menuId, plainKey, true),
            )
          else
            TextButton(
              key: ValueKey('prep-restore-$key'),
              onPressed: () =>
                  store.setPrepExcluded(widget.menuId, plainKey, false),
              child: const Text('恢复',
                  style: TextStyle(fontSize: 12.5)),
            ),
        ],
      ),
    );
  }
}
