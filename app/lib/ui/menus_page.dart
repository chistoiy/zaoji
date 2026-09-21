import 'package:flutter/material.dart';

import '../data/recipe_store.dart';
import '../data/store_scope.dart';
import '../theme.dart';
import 'menu_detail_page.dart';

/// 菜单（R23）：按餐次安排「哪天哪一餐吃什么」。
///
/// 版式照高保真原型：日期分组 → 餐次卡（餐次章 + 开饭时间 + 菜名条 + 一键备菜）。
/// 菜单/菜品行是同步业务表；本页只管本机视图组织，写入全部走 RecipeStore。

/// YYYY-MM-DD → 「今天 / 明天 / 后天 / 周四 09-25」。
String dayLabel(String day) {
  final d = DateTime.tryParse(day);
  if (d == null) return day;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = d.difference(today).inDays;
  const wd = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  final w = wd[d.weekday - 1];
  if (diff == 0) return '今天 · $w';
  if (diff == 1) return '明天 · $w';
  if (diff == 2) return '后天 · $w';
  return '$w ${_two(d.month)}-${_two(d.day)}';
}

String _two(int v) => v.toString().padLeft(2, '0');

/// 今天/明天/后天的日期字符串（表单 chips 用）。
String dayOffsetValue(int offset) {
  final now = DateTime.now();
  final d = DateTime(now.year, now.month, now.day + offset);
  return '${d.year}-${_two(d.month)}-${_two(d.day)}';
}

class MenusPage extends StatelessWidget {
  const MenusPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZaojiColors.paper,
      appBar: AppBar(
        title: const Text('菜单'),
        backgroundColor: ZaojiColors.paper,
        actions: [
          IconButton(
            key: const ValueKey('menu-add'),
            icon: const Icon(Icons.add),
            color: ZaojiColors.accent,
            tooltip: '新建餐次',
            onPressed: () => showMealForm(context),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: StoreScope.of(context),
        builder: (context, _) => _body(context, StoreScope.of(context)),
      ),
    );
  }

  Widget _body(BuildContext context, RecipeStore store) {
    if (store.menus.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.receipt_long_outlined,
                  size: 40, color: ZaojiColors.muted),
              const SizedBox(height: 12),
              Text('还没排过菜单',
                  style: ZaojiText.display(
                      fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              const Text('先定「哪天哪一餐」，再往里加菜',
                  style: TextStyle(fontSize: 12, color: ZaojiColors.muted)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => showMealForm(context),
                style: FilledButton.styleFrom(
                    backgroundColor: ZaojiColors.accent),
                child: const Text('排第一餐'),
              ),
            ],
          ),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        for (final m in store.menus)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _MenuCard(menu: m),
          ),
      ],
    );
  }
}

class _MenuCard extends StatelessWidget {
  const _MenuCard({required this.menu});

  final MenuPlan menu;

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final names = [
      for (final id in menu.recipeIds)
        store.recipeById(id)?.name ?? '（已删除的菜）',
    ];
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(ZaojiRadius.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(ZaojiRadius.lg),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => MenuDetailPage(menuId: menu.id)),
        ),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(ZaojiRadius.lg),
            border: Border.all(color: ZaojiColors.lineSoft),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _MealStamp(meal: menu.meal),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${dayLabel(menu.day)} · ${menu.meal}',
                          key: ValueKey('menu-title-${menu.id}'),
                          style: const TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w600,
                            color: ZaojiColors.ink,
                          ),
                        ),
                        Text(
                          menu.serveAt.isEmpty
                              ? '${names.length} 道菜'
                              : '${menu.serveAt} 开饭 · ${names.length} 道菜',
                          style: const TextStyle(
                              fontSize: 11.5, color: ZaojiColors.muted),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right,
                      size: 20, color: ZaojiColors.muted),
                ],
              ),
              if (names.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  names.take(3).join(' · ') + (names.length > 3 ? ' 等${names.length}道' : ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, color: ZaojiColors.ink2),
                ),
              ],
              if (menu.note.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(menu.note,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5, color: ZaojiColors.muted)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 餐次章（原型 `.meal-tag`）：早/午/晚一个圆角方块，自定义给「自」。
class _MealStamp extends StatelessWidget {
  const _MealStamp({required this.meal});

  final String meal;

  @override
  Widget build(BuildContext context) {
    final short = switch (meal) {
      '早餐' => '早',
      '午餐' => '午',
      '晚餐' => '晚',
      _ => '自',
    };
    return Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0x1437634A),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(short,
          style: const TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
              color: Color(0xFF2F5B40))),
    );
  }
}

// ─────────────────── 新建 / 编辑餐次 ───────────────────

/// 打开餐次表单弹层。editing 为 null 是新建。
Future<void> showMealForm(BuildContext context, {MenuPlan? editing}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: ZaojiColors.paper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => _MealFormSheet(editing: editing),
  );
}

class _MealFormSheet extends StatefulWidget {
  const _MealFormSheet({this.editing});

  final MenuPlan? editing;

  @override
  State<_MealFormSheet> createState() => _MealFormSheetState();
}

class _MealFormSheetState extends State<_MealFormSheet> {
  late String _day;
  late String _meal;
  late bool _customMeal;
  late bool _customDay;

  final _customMealCtrl = TextEditingController();
  late final TextEditingController _dayCtrl;
  final _serveCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    final m = widget.editing;
    final now = DateTime.now();
    final today =
        '${now.year}-${_two(now.month)}-${_two(now.day)}';
    _day = m?.day ?? dayOffsetValue(0);
    _customDay = _day != today && _day != dayOffsetValue(1) && _day != dayOffsetValue(2);
    _dayCtrl = TextEditingController(text: _customDay ? _day : '');
    _meal = m?.meal ?? '晚餐';
    _customMeal = !['早餐', '午餐', '晚餐'].contains(_meal);
    if (_customMeal) _customMealCtrl.text = _meal;
    _serveCtrl.text = m?.serveAt ?? '';
    _noteCtrl.text = m?.note ?? '';
  }

  @override
  void dispose() {
    _customMealCtrl.dispose();
    _dayCtrl.dispose();
    _serveCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final day = _customDay ? _dayCtrl.text.trim() : _day;
    final meal =
        _customMeal ? _customMealCtrl.text.trim() : _meal;
    if (DateTime.tryParse(day) == null) {
      setState(() => _error = '日期要写成 2026-09-25 这样');
      return;
    }
    if (meal.isEmpty) {
      setState(() => _error = '自定义餐次总得有个名字');
      return;
    }
    final serve = _serveCtrl.text.trim();
    if (serve.isNotEmpty &&
        !RegExp(r'^\d{1,2}:\d{2}$').hasMatch(serve)) {
      setState(() => _error = '开饭时间要写成 18:30 这样');
      return;
    }
    final store = StoreScope.of(context);
    final m = widget.editing;
    if (m == null) {
      await store.createMenu(
          day: day, meal: meal, serveAt: serve, note: _noteCtrl.text.trim());
    } else {
      await store.updateMenu(m.id,
          day: day, meal: meal, serveAt: serve, note: _noteCtrl.text.trim());
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  Widget _chip(String label, bool on, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: on,
        onSelected: (_) => onTap(),
        labelStyle: TextStyle(
          fontSize: 13,
          color: on ? Colors.white : ZaojiColors.ink2,
        ),
        selectedColor: ZaojiColors.accent,
        backgroundColor: Colors.white,
        showCheckmark: false,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
              color: on ? ZaojiColors.accent : ZaojiColors.line),
        ),
      ),
    );
  }

  InputDecoration _field(String hint) => InputDecoration(
        isDense: true,
        hintText: hint,
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: ZaojiColors.line),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: ZaojiColors.accent, width: 1.4),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 18,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.editing == null ? '新建餐次' : '编辑餐次',
                style: ZaojiText.display(
                    fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
          const Text('哪一天',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: ZaojiColors.ink2)),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final (i, l) in const ['今天', '明天', '后天'].indexed)
                _chip(l, !_customDay && _day == dayOffsetValue(i), () {
                  setState(() {
                    _day = dayOffsetValue(i);
                    _customDay = false;
                  });
                }),
              _chip('其它', _customDay, () {
                setState(() => _customDay = true);
              }),
            ],
          ),
          if (_customDay)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                key: const ValueKey('meal-day-custom'),
                controller: _dayCtrl,
                style: const TextStyle(fontSize: 13.5),
                decoration: _field('2026-10-01'),
              ),
            ),
          const SizedBox(height: 14),
          const Text('餐次',
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: ZaojiColors.ink2)),
          const SizedBox(height: 6),
          Row(
            children: [
              for (final m in const ['早餐', '午餐', '晚餐'])
                _chip(m, !_customMeal && _meal == m, () {
                  setState(() {
                    _meal = m;
                    _customMeal = false;
                  });
                }),
              _chip('自定义', _customMeal, () {
                setState(() => _customMeal = true);
              }),
            ],
          ),
          if (_customMeal)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: TextField(
                key: const ValueKey('meal-name-custom'),
                controller: _customMealCtrl,
                style: const TextStyle(fontSize: 13.5),
                decoration: _field('下午茶 / 夜宵 / 朋友来做客'),
              ),
            ),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('meal-serve-at'),
            controller: _serveCtrl,
            style: const TextStyle(fontSize: 13.5),
            decoration: _field('开饭时间（可空），如 18:30'),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('meal-note'),
            controller: _noteCtrl,
            style: const TextStyle(fontSize: 13.5),
            decoration: _field('备注（可空）'),
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(
                    fontSize: 12, color: Color(0xFFA3320D))),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey('meal-save'),
              onPressed: _save,
              style:
                  FilledButton.styleFrom(backgroundColor: ZaojiColors.accent),
              child: Text(widget.editing == null ? '就这么安排' : '保存修改'),
            ),
          ),
          ],
        ),
      ),
    );
  }
}
