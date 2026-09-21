import 'package:flutter/material.dart';

import '../data/store_scope.dart';
import '../theme.dart';
import 'menus_page.dart';

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
      backgroundColor: ZaojiColors.paper,
      appBar: AppBar(
        title: const Text('备菜清单'),
        backgroundColor: ZaojiColors.paper,
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
      return const Center(
          child: Text('这个菜单已经不存在了',
              style:
                  TextStyle(fontSize: 13, color: ZaojiColors.muted)));
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
          style: const TextStyle(fontSize: 12, color: ZaojiColors.muted),
        ),
        const SizedBox(height: 12),
        for (final l in open) _line(l.key, l.name, l.qtyText,
            from: l.from, merged: l.isMerged),
        for (final e in extraEntries)
          _line('x:${e.key}', e.key, e.value,
              extra: true, removable: true),
        if (open.isEmpty && extraEntries.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Text('要买要备的都勾完了',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: ZaojiColors.muted)),
          ),
        if (done.isNotEmpty) ...[
          const SizedBox(height: 10),
          const Text('已备齐',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: ZaojiColors.muted)),
          const SizedBox(height: 6),
          for (final l in done) _line(l.key, l.name, l.qtyText, dimmed: true),
        ],
        if (excluded.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text('已排除 ${excluded.length} 项',
              style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: ZaojiColors.muted)),
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
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '补一项，如 嫩豆腐',
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                    borderSide: BorderSide(color: ZaojiColors.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                    borderSide:
                        BorderSide(color: ZaojiColors.accent, width: 1.4),
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
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '分量',
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                    borderSide: BorderSide(color: ZaojiColors.line),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.all(Radius.circular(10)),
                    borderSide:
                        BorderSide(color: ZaojiColors.accent, width: 1.4),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: const ValueKey('prep-add-extra'),
              onPressed: _addExtra,
              icon: const Icon(Icons.add_circle_outline),
              color: ZaojiColors.accent,
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(color: ZaojiColors.lineSoft),
      ),
      child: Row(
        children: [
          Checkbox(
            key: ValueKey('prep-check-$key'),
            value: checked,
            visualDensity: VisualDensity.compact,
            activeColor: const Color(0xFF2F5B40),
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
                    color: dimmed ? ZaojiColors.muted : ZaojiColors.ink,
                    decoration:
                        dimmed ? TextDecoration.lineThrough : null,
                  ),
                ),
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
                      style: const TextStyle(
                          fontSize: 11, color: ZaojiColors.muted),
                    ),
                  ),
              ],
            ),
          ),
          Text(
            qty,
            style: TextStyle(
              fontSize: 13,
              color: dimmed ? ZaojiColors.muted : ZaojiColors.ink2,
            ),
          ),
          if (removable)
            IconButton(
              key: ValueKey('prep-remove-$key'),
              icon: const Icon(Icons.close, size: 18),
              color: ZaojiColors.muted,
              onPressed: () => store.removePrepExtra(widget.menuId, name),
            )
          else if (!excludedRow)
            IconButton(
              key: ValueKey('prep-exclude-$key'),
              icon: const Icon(Icons.do_not_disturb_on_outlined, size: 18),
              color: ZaojiColors.muted,
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
