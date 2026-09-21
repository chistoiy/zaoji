import 'package:flutter/material.dart';

import '../data/store_scope.dart';
import '../data/sync/conflict_box.dart';
import '../data/sync/sync_scope.dart';
import '../theme.dart';

/// 冲突箱（R22）：两端改了同一字段时逐字段选保留哪版。
///
/// 版式照高保真原型：按菜分组 → 每字段三选（改动 A / 改动 B / 自己填）→
/// 整组应用。「改动 A/B」刻意不叫「本地/远端」——对用户来说那是两次改动，
/// 没有哪次是"远"的。
class ConflictBoxPage extends StatefulWidget {
  const ConflictBoxPage({super.key});

  @override
  State<ConflictBoxPage> createState() => _ConflictBoxPageState();
}

class _ConflictBoxPageState extends State<ConflictBoxPage> {
  /// 裁决草稿：conflict_item.id → 'local' | 'remote' | 'custom'。
  final Map<String, String> _sel = {};

  /// 手动档的值（应用时才收口进请求体）。
  final Map<String, TextEditingController> _custom = {};

  Future<List<ConflictGroup>>? _groups;
  bool _applying = false;

  @override
  void dispose() {
    for (final c in _custom.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _reload() {
    setState(() {
      _groups = StoreScope.of(context).conflictGroups();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _groups ??= StoreScope.of(context).conflictGroups();
  }

  Future<void> _applyGroup(ConflictGroup g) async {
    final engine = SyncScope.of(context);
    final items = <Map<String, Object?>>[];
    for (final f in g.fields) {
      final side = _sel[f.id];
      if (side == null) continue;
      if (side == 'custom') {
        final v = _custom[f.id]?.text.trim();
        if (v == null || v.isEmpty) continue; // 没填就等于没裁，留在箱里
        items.add({'conflictId': f.id, 'choice': 'merged', 'mergedValue': v});
      } else {
        items.add({'conflictId': f.id, 'choice': side});
      }
    }
    if (items.isEmpty) return;

    setState(() => _applying = true);
    final results = await engine.resolveConflicts(items);
    if (!mounted) return;
    setState(() => _applying = false);
    for (final r in results) {
      _sel.remove('${r['conflictId']}');
    }
    final applied = results.where((r) => r['outcome'] == 'applied').length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          results.isEmpty
              ? (engine.lastError ?? '提交失败')
              : '已应用 $applied 处裁决',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZaojiColors.paper,
      appBar: AppBar(
        title: const Text('冲突箱'),
        backgroundColor: ZaojiColors.paper,
      ),
      body: ListenableBuilder(
        // 同步落库（冲突卡是业务行，拉回来/归档都靠 reload）后自动重画。
        listenable: StoreScope.of(context),
        builder: (context, _) => FutureBuilder<List<ConflictGroup>>(
          future: _groups,
          builder: (context, snap) {
            final groups = snap.data ?? const <ConflictGroup>[];
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: ZaojiColors.accent,
                ),
              );
            }
            if (groups.isEmpty) return _empty();
            final total = groups.fold<int>(0, (a, g) => a + g.fields.length);
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Text(
                  '$total 处待裁决 · 逐字段选保留哪版',
                  style: const TextStyle(
                    fontSize: 12,
                    color: ZaojiColors.muted,
                  ),
                ),
                const SizedBox(height: 12),
                for (final g in groups) ..._groupBlocks(g),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _empty() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(Icons.check_circle_outline, size: 40, color: Color(0xFF2F5B40)),
          SizedBox(height: 12),
          Text('没有待裁决的冲突', style: TextStyle(fontSize: 15)),
          SizedBox(height: 6),
          Text(
            '两端改了同一个字段时才会出现在这里，字段不重叠的改动会自动合并',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: ZaojiColors.muted),
          ),
        ],
      ),
    ),
  );

  List<Widget> _groupBlocks(ConflictGroup g) {
    // ConflictField 不带 tbl（同组同表），渲染组时记一下给标签翻译用。
    for (final f in g.fields) {
      _tblById[f.id] = g.tbl;
    }
    final decided = g.fields
        .where((f) => (_sel[f.id] ?? '') != '')
        .length;
    return [
      Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                g.title,
                style: ZaojiText.display(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '$decided/${g.fields.length}',
              style: const TextStyle(
                fontSize: 11.5,
                color: ZaojiColors.muted,
              ),
            ),
          ],
        ),
      ),
      for (final f in g.fields) _fieldCard(f),
      const SizedBox(height: 6),
      FilledButton(
        onPressed: _applying || decided == 0
            ? null
            : () => _applyGroup(g),
        style: FilledButton.styleFrom(backgroundColor: ZaojiColors.accent),
        child: Text(_applying ? '提交中…' : '应用这一组的裁决'),
      ),
      const SizedBox(height: 20),
    ];
  }

  Widget _fieldCard(ConflictField f) {
    final sel = _sel[f.id];
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(ZaojiRadius.lg),
        border: Border.all(color: ZaojiColors.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            fieldLabel(_tblOf(f), f.field),
            key: ValueKey('field-${f.id}'),
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: ZaojiColors.ink2,
            ),
          ),
          const SizedBox(height: 8),
          _option(f, 'local', '改动 A', f.localValue, f.localBy, f.localHlc),
          const SizedBox(height: 6),
          _option(f, 'remote', '改动 B', f.remoteValue, f.remoteBy, f.remoteHlc),
          const SizedBox(height: 6),
          _customOption(f, sel == 'custom'),
        ],
      ),
    );
  }

  // 字段卡片在分组遍历时才知道 tbl，但 ConflictField 自身不带——
  // 标签只影响显示，取 group 时缓存一下即可（同组字段同表）。
  String _tblOf(ConflictField f) => _tblById[f.id] ?? f.field;
  final Map<String, String> _tblById = {};

  Widget _option(
    ConflictField f,
    String side,
    String tag,
    Object? value,
    String by,
    String hlc,
  ) {
    final on = _sel[f.id] == side;
    return InkWell(
      borderRadius: BorderRadius.circular(ZaojiRadius.md),
      onTap: () => setState(() {
        if (_sel[f.id] == side) {
          _sel.remove(f.id);
        } else {
          _sel[f.id] = side;
        }
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: on ? const Color(0x1437634A) : ZaojiColors.paper,
          borderRadius: BorderRadius.circular(ZaojiRadius.md),
          border: Border.all(
            color: on ? const Color(0xFF2F5B40) : ZaojiColors.line,
            width: on ? 1.4 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              on ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 17,
              color: on ? const Color(0xFF2F5B40) : ZaojiColors.muted,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    valueText(value),
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: ZaojiColors.ink,
                    ),
                  ),
                  Text(
                    [
                      tag,
                      if (by.isNotEmpty) deviceTail(by),
                      if (hlcClock(hlc).isNotEmpty) hlcClock(hlc),
                    ].join(' · '),
                    style: const TextStyle(
                      fontSize: 11,
                      color: ZaojiColors.muted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _customOption(ConflictField f, bool on) {
    final ctrl = _custom.putIfAbsent(f.id, () => TextEditingController());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          borderRadius: BorderRadius.circular(ZaojiRadius.md),
          onTap: () => setState(() {
            if (on) {
              _sel.remove(f.id);
            } else {
              _sel[f.id] = 'custom';
            }
          }),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: on ? const Color(0x1437634A) : ZaojiColors.paper,
              borderRadius: BorderRadius.circular(ZaojiRadius.md),
              border: Border.all(
                color: on ? const Color(0xFF2F5B40) : ZaojiColors.line,
                width: on ? 1.4 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  on ? Icons.check_circle : Icons.radio_button_unchecked,
                  size: 17,
                  color: on ? const Color(0xFF2F5B40) : ZaojiColors.muted,
                ),
                const SizedBox(width: 8),
                const Text(
                  '都不是，自己填',
                  style: TextStyle(fontSize: 13.5, color: ZaojiColors.ink),
                ),
              ],
            ),
          ),
        ),
        if (on)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              controller: ctrl,
              style: const TextStyle(fontSize: 13.5),
              cursorColor: ZaojiColors.accent,
              decoration: const InputDecoration(
                isDense: true,
                filled: true,
                fillColor: Colors.white,
                hintText: '填最终要留下的值',
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(10)),
                  borderSide: BorderSide(color: ZaojiColors.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(10)),
                  borderSide: BorderSide(color: ZaojiColors.accent, width: 1.4),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
