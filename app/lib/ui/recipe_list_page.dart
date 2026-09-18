import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../data/recipe_store.dart';
import '../data/store_scope.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/chili_scale.dart';
import '../widgets/cover_image.dart';
import '../widgets/dish_art.dart';
import 'recipe_detail_page.dart';
import 'recipe_edit_page.dart';

/// 菜谱库（主页）。
///
/// **这一屏是照着高保真原型（`zaoji-prototype.html` 的 `SCREENS.recipes`）逐块实现的**，
/// 结构与原型一一对应，改哪块先看原型：
///
/// | 原型 | 这里 |
/// |---|---|
/// | `.appbar`（菜谱 + 共 N 道 · 收藏 N 道 + 搜索/筛选） | `_HomeHeader` |
/// | `.searchbar`（实时过滤菜名/食材） | `_SearchBar` |
/// | `.rail`（只看收藏 + 操作方式快捷筛选） | `_Rail` |
/// | `.sec-head`（编号 + 标题 + 排序） | `_SectionHead` |
/// | `.recipe-grid` 的 `.recipe-card`（封面插画 + 徽章 + 收藏） | `_RecipeCard` |
/// | `.add-fab`（长按 380ms 可拖动的悬浮按钮） | `_AddFab` |
/// | `.tabbar` | `home_shell.dart` |
///
/// 排序/筛选 sheet 是原型 `sheet-filter` 的简化版（排序四档 + 难度多选），
/// 完整版（菜系/口味/食材分组）等 M3 一起做。
class RecipeListPage extends StatefulWidget {
  const RecipeListPage({super.key});

  @override
  State<RecipeListPage> createState() => _RecipeListPageState();
}

enum _Sort { recent, cooked, fast, easy }

extension _SortLabel on _Sort {
  String get label => switch (this) {
    _Sort.recent => '最近做过',
    _Sort.cooked => '做过最多',
    _Sort.fast => '耗时最短',
    _Sort.easy => '难度最低',
  };
}

class _RecipeListPageState extends State<RecipeListPage> {
  final _searchFocus = FocusNode();
  final _searchCtrl = TextEditingController();

  String _query = '';
  bool _favOnly = false;
  final Set<String> _methods = {};
  final Set<int> _diffs = {};
  _Sort _sort = _Sort.recent;

  // 收藏是本机偏好，存在 [RecipeStore] 里（列表/详情共用一份状态）

  @override
  void dispose() {
    _searchFocus.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _reset() {
    // ★ 清的是「筛选」，就必须把**搜索框里的字**与**排序档**一起复位。
    // 之前只清状态字段：输入框还写着「番茄」，列表却回到「全部菜品」——
    // 界面自相矛盾，用户以为搜索坏了。
    _searchCtrl.clear();
    setState(() {
      _query = '';
      _favOnly = false;
      _methods.clear();
      _diffs.clear();
      _sort = _Sort.recent;
    });
  }

  /// 原型 `visibleRecipes()` 的直译。
  List<Recipe> _visible(RecipeStore store) {
    var list = store.recipes.toList();
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where(
            (r) =>
                r.name.toLowerCase().contains(q) ||
                r.sub.toLowerCase().contains(q) ||
                r.ingredients.any((i) => i.name.toLowerCase().contains(q)),
          )
          .toList();
    }
    if (_favOnly) list = list.where((r) => store.isFav(r.id)).toList();
    if (_methods.isNotEmpty) {
      list = list.where((r) => r.methods.any(_methods.contains)).toList();
    }
    if (_diffs.isNotEmpty) {
      list = list.where((r) => _diffs.contains(r.difficulty)).toList();
    }
    switch (_sort) {
      case _Sort.cooked:
        list.sort((a, b) => b.cookedCount.compareTo(a.cookedCount));
      case _Sort.fast:
        list.sort((a, b) => a.selfTime.compareTo(b.selfTime));
      case _Sort.easy:
        list.sort((a, b) => a.difficulty.compareTo(b.difficulty));
      case _Sort.recent:
        list.sort((a, b) => b.lastCooked.compareTo(a.lastCooked));
    }
    return list;
  }

  int get _filterCount => _methods.length + _diffs.length + (_favOnly ? 1 : 0);

  void _openSortSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(ZaojiRadius.lg),
        ),
      ),
      builder: (sheetCtx) {
        var sort = _sort;
        var diffs = Set<int>.of(_diffs);
        return SafeArea(
          top: false,
          child: StatefulBuilder(
            builder: (ctx, setSheet) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: ZaojiColors.line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Text(
                        '排序',
                        style: ZaojiText.display(
                          fontSize: 17,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          setSheet(() => diffs.clear());
                          setState(_diffs.clear);
                        },
                        child: const Text(
                          '清空难度',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  for (final s in _Sort.values)
                    InkWell(
                      onTap: () {
                        setSheet(() => sort = s);
                        setState(() => _sort = s);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                s.label,
                                style: TextStyle(
                                  fontSize: 14.5,
                                  color: s == sort
                                      ? ZaojiColors.accent
                                      : ZaojiColors.ink,
                                  fontWeight: s == sort
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                ),
                              ),
                            ),
                            if (s == sort)
                              const Icon(
                                Icons.check,
                                size: 17,
                                color: ZaojiColors.accent,
                              ),
                          ],
                        ),
                      ),
                    ),
                  const Divider(height: 22, color: ZaojiColors.lineSoft),
                  Text(
                    '难度',
                    style: ZaojiText.body(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: ZaojiColors.ink2,
                    ),
                  ),
                  const SizedBox(height: 9),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (var d = 1; d <= 3; d++)
                        _FilterChip(
                          label: ChiliScale.diffLabel(d),
                          selected: diffs.contains(d),
                          onTap: () {
                            setSheet(
                              () => diffs.contains(d)
                                  ? diffs.remove(d)
                                  : diffs.add(d),
                            );
                            setState(
                              () => _diffs.contains(d)
                                  ? _diffs.remove(d)
                                  : _diffs.add(d),
                            );
                          },
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    // ★ 数据由 store 的通知驱动刷新，而不是靠每处手写 setState——
    //   同步引擎接入后（别的设备改了菜谱），这里会自动重画。
    //   之前 store 是 ChangeNotifier 却没人听：写入后 UI 永远不刷新。
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final list = _visible(store);
        final favCount = store.favs.length;

        return Scaffold(
          backgroundColor: ZaojiColors.paper,
          body: SafeArea(
            bottom: false,
            child: Stack(
              children: [
                Column(
                  children: [
                    _HomeHeader(
                      total: store.recipes.length,
                      favCount: favCount,
                      filterCount: _filterCount,
                      searchFocus: _searchFocus,
                      onOpenFilter: _openSortSheet,
                    ),
                    Expanded(
                      child: CustomScrollView(
                        slivers: [
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
                              child: _SearchBar(
                                controller: _searchCtrl,
                                focus: _searchFocus,
                                onChanged: (v) => setState(() => _query = v),
                              ),
                            ),
                          ),
                          SliverToBoxAdapter(
                            child: _Rail(
                              favOnly: _favOnly,
                              selectedMethods: _methods,
                              onFav: () => setState(() => _favOnly = !_favOnly),
                              onMethod: (m) => setState(
                                () => _methods.contains(m)
                                    ? _methods.remove(m)
                                    : _methods.add(m),
                              ),
                            ),
                          ),
                          SliverToBoxAdapter(
                            child: _SectionHead(
                              count: list.length,
                              title: _favOnly
                                  ? '我的收藏'
                                  : _query.trim().isEmpty
                                  ? '全部菜品'
                                  : '搜索结果',
                              sortLabel: _sort.label,
                              onSort: _openSortSheet,
                            ),
                          ),
                          if (list.isEmpty)
                            SliverToBoxAdapter(
                              child: _EmptyState(onReset: _reset),
                            )
                          else
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                              sliver: SliverGrid(
                                gridDelegate:
                                    const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 2,
                                      mainAxisSpacing: 12,
                                      crossAxisSpacing: 12,
                                      // 卡片高度钉死，封面吃掉剩余部分（fit: cover）。
                                      // 不用 childAspectRatio 是因为它的比例随屏宽变，
                                      // 字号一变就溢出——R7 在 320px 上溢出 71px 的教训。
                                      mainAxisExtent: 192,
                                    ),
                                delegate: SliverChildBuilderDelegate(
                                  (context, i) => _RecipeCard(
                                    recipe: list[i],
                                    isFav: store.isFav(list[i].id),
                                    onFav: () => store.toggleFav(list[i].id),
                                    onTap: () => Navigator.of(context).push(
                                      MaterialPageRoute(
                                        builder: (_) =>
                                            RecipeDetailPage(recipe: list[i]),
                                      ),
                                    ),
                                  ),
                                  childCount: list.length,
                                ),
                              ),
                            ),
                          const SliverToBoxAdapter(child: SizedBox(height: 96)),
                        ],
                      ),
                    ),
                  ],
                ),
                _AddFab(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const RecipeEditPage()),
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/* ─────────── 顶栏（原型 .appbar） ─────────── */

class _HomeHeader extends StatelessWidget {
  const _HomeHeader({
    required this.total,
    required this.favCount,
    required this.filterCount,
    required this.searchFocus,
    required this.onOpenFilter,
  });

  final int total;
  final int favCount;
  final int filterCount;
  final FocusNode searchFocus;
  final VoidCallback onOpenFilter;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 10, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '菜谱',
                  style: ZaojiText.display(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '共 $total 道 · 收藏 $favCount 道',
                  style: const TextStyle(
                    fontSize: 11,
                    color: ZaojiColors.muted,
                    letterSpacing: .2,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '搜索',
            // 原型里这一步跳独立搜索页；M0 先聚焦到下面的搜索框——
            // 功能是真实可用的，只是入口合一
            onPressed: () => searchFocus.requestFocus(),
            icon: const Icon(Icons.search, size: 21),
          ),
          const SizedBox(width: 2),
          // is-solid：白底描边，与普通透明 iconbtn 区分
          _IconSolidButton(
            tooltip: '筛选排序',
            onPressed: onOpenFilter,
            icon: const Icon(Icons.tune, size: 20),
            badge: filterCount > 0 ? filterCount : null,
          ),
        ],
      ),
    );
  }
}

class _IconSolidButton extends StatelessWidget {
  const _IconSolidButton({
    required this.tooltip,
    required this.onPressed,
    required this.icon,
    this.badge,
  });

  final String tooltip;
  final VoidCallback onPressed;
  final Widget icon;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: ZaojiColors.line),
            boxShadow: const [
              BoxShadow(
                color: Color(0x123A2816), // rgba(58,40,22,.07)
                blurRadius: 3,
                offset: Offset(0, 1),
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              IconTheme(
                data: const IconThemeData(size: 20, color: ZaojiColors.ink2),
                child: icon,
              ),
              if (badge != null)
                Positioned(
                  top: 2,
                  right: 2,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 17),
                    height: 17,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: ZaojiColors.accent,
                      borderRadius: BorderRadius.circular(9),
                    ),
                    child: Text(
                      '$badge',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ─────────── 搜索条（原型 .searchbar） ─────────── */

class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.focus,
    required this.onChanged,
  });

  /// **controller 归父级所有**：清空按钮要能清文本，
  /// 而 controller 每次重建会丢光标位置——不能在 build 里现造。
  final TextEditingController controller;
  final FocusNode focus;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: ZaojiColors.line),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 18, color: ZaojiColors.muted),
          const SizedBox(width: 9),
          Expanded(
            child: TextField(
              focusNode: focus,
              controller: controller,
              onChanged: onChanged,
              style: const TextStyle(fontSize: 14, color: ZaojiColors.ink),
              cursorColor: ZaojiColors.accent,
              decoration: const InputDecoration(
                isCollapsed: true,
                border: InputBorder.none,
                hintText: '搜菜名、食材，如「番茄」「虾」',
                hintStyle: TextStyle(fontSize: 14, color: ZaojiColors.muted),
              ),
            ),
          ),
          if (controller.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                controller.clear();
                onChanged('');
              },
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 15, color: ZaojiColors.muted),
              ),
            ),
        ],
      ),
    );
  }
}

/* ─────────── 快捷筛选轨（原型 .rail） ─────────── */

class _Rail extends StatelessWidget {
  const _Rail({
    required this.favOnly,
    required this.selectedMethods,
    required this.onFav,
    required this.onMethod,
  });

  final bool favOnly;
  final Set<String> selectedMethods;
  final VoidCallback onFav;
  final ValueChanged<String> onMethod;

  /// 原型 `GROUP_MAP.method.tags`
  static const _quickMethods = ['爆炒', '水煮', '清蒸', '红烧', '烧烤', '火锅', '凉拌', '烘焙'];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        children: [
          _FilterChip(
            icon: Icons.bookmark_border,
            label: '只看收藏',
            plain: true,
            selected: favOnly,
            onTap: onFav,
          ),
          const SizedBox(width: 8),
          for (final m in _quickMethods) ...[
            _FilterChip(
              label: m,
              color: ZaojiColors.tagMethod,
              selected: selectedMethods.contains(m),
              onTap: () => onMethod(m),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

/// 原型 `.chip`。选中 = 填充自身颜色 + 白字（`.chip[aria-pressed="true"]`）。
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.color,
    this.plain = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;
  final Color? color;
  final bool plain;

  @override
  Widget build(BuildContext context) {
    // is-plain 的选中态是 accent（原型 .chip[aria-pressed="true"].is-plain）
    final c = plain ? ZaojiColors.ink2 : (color ?? ZaojiColors.ink2);
    final active = plain ? ZaojiColors.accent : c;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 170),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? active
              : plain
              ? const Color(0x09231C15) // rgba(35,28,21,.035)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: selected
                ? active
                : plain
                ? ZaojiColors.line
                : c,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 12, color: selected ? Colors.white : c),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: selected ? const Color(0xFFFFF7EE) : c,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ─────────── 区块标题（原型 .sec-head） ─────────── */

class _SectionHead extends StatelessWidget {
  const _SectionHead({
    required this.count,
    required this.title,
    required this.sortLabel,
    required this.onSort,
  });

  final int count;
  final String title;
  final String sortLabel;
  final VoidCallback onSort;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 12),
      child: Row(
        children: [
          Text(
            count.toString().padLeft(2, '0'),
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: ZaojiColors.accent,
              letterSpacing: .4,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            title,
            style: ZaojiText.display(fontSize: 19, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 12),
          const Expanded(child: Divider(height: 1, color: ZaojiColors.line)),
          const SizedBox(width: 12),
          InkWell(
            onTap: onSort,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    sortLabel,
                    style: const TextStyle(
                      fontSize: 12,
                      color: ZaojiColors.muted,
                    ),
                  ),
                  const Icon(
                    Icons.expand_more,
                    size: 13,
                    color: ZaojiColors.muted,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/* ─────────── 菜谱卡片（原型 .recipe-card） ─────────── */

class _RecipeCard extends StatelessWidget {
  const _RecipeCard({
    required this.recipe,
    required this.isFav,
    required this.onFav,
    required this.onTap,
  });

  final Recipe recipe;
  final bool isFav;
  final VoidCallback onFav;
  final VoidCallback onTap;

  /// 徽章文字的公共样式。**必须带阴影**——它们坐在封面插画上，
  /// 底图颜色不受控，原型里就是 text-shadow 撑住可读性的。
  static const List<Shadow> _chipShadow = [
    Shadow(blurRadius: 3, offset: Offset(0, 1), color: Color(0x80000000)),
  ];

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(ZaojiRadius.lg),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ZaojiRadius.lg),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(ZaojiRadius.lg),
            border: Border.all(color: ZaojiColors.lineSoft),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(ZaojiRadius.lg - 0.5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 封面
                Expanded(
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      DishArt(kind: recipe.art, palette: recipe.palette),
                      // 实拍封面（R16）：叠在插画上，未拉到时透明退化为插画
                      if (recipe.coverSha256 != null)
                        CoverImage(sha: recipe.coverSha256!),
                      const ArtVeil(),
                      if (recipe.isAi)
                        Positioned(
                          top: 8,
                          left: 8,
                          child: _PillBadge(
                            icon: Icons.auto_awesome,
                            label: 'AI 生成',
                          ),
                        ),
                      // 收藏（右上）
                      Positioned(
                        top: 6,
                        right: 6,
                        child: _FavButton(isFav: isFav, onTap: onFav),
                      ),
                      // 难度 + 耗时（左下）
                      Positioned(
                        left: 9,
                        bottom: 8,
                        right: 40,
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                ChiliScale(
                                  level: recipe.difficulty,
                                  size: 10,
                                  // 底图是深色遮罩，默认的线色会看不见
                                  offColor: Colors.white.withValues(alpha: .32),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  ChiliScale.diffLabel(recipe.difficulty),
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFFFFF4E9),
                                    shadows: _chipShadow,
                                  ),
                                ),
                              ],
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.schedule,
                                  size: 11,
                                  color: Color(0xFFFFF4E9),
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  '${recipe.selfTime} 分',
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xFFFFF4E9),
                                    shadows: _chipShadow,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // 卡身
                Padding(
                  padding: const EdgeInsets.fromLTRB(11, 10, 11, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        recipe.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ZaojiText.display(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                          height: 1.32,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(
                            Icons.local_fire_department,
                            size: 11,
                            color: ZaojiColors.muted,
                          ),
                          const SizedBox(width: 4),
                          // Flexible + ellipsis：320px 宽时两列卡片只有 138px，
                          // 这一行自然宽度放不下——宁可截断也别溢出
                          Flexible(
                            child: Text(
                              '做过 ${recipe.cookedCount} 次',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: ZaojiColors.muted,
                              ),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Container(
                            width: 2.5,
                            height: 2.5,
                            decoration: BoxDecoration(
                              color: ZaojiColors.muted.withValues(alpha: .5),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 7),
                          Text(
                            recipe.lastCookedShort,
                            style: const TextStyle(
                              fontSize: 10.5,
                              color: ZaojiColors.muted,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 封面上的实底药丸（AI 来源标记）。
///
/// 热量徽标（`.art-kcal`）等有数据了也用这个样式——紫底白字，
/// 「信息」而非「氛围」，任何插画上都要读得清。
class _PillBadge extends StatelessWidget {
  const _PillBadge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
      decoration: BoxDecoration(
        color: ZaojiColors.ai.withValues(alpha: .86),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: const Color(0xFFF5EBF4)),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Color(0xFFF5EBF4),
            ),
          ),
        ],
      ),
    );
  }
}

/// 收藏按钮（原型 `.fav-btn`）。34×34 深色毛玻璃圆，选中变柿红。
class _FavButton extends StatelessWidget {
  const _FavButton({required this.isFav, required this.onTap});

  final bool isFav;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: isFav ? '取消收藏' : '收藏',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isFav
                ? ZaojiColors.accent.withValues(alpha: .82)
                : const Color(0x4D18110B), // rgba(24,17,11,.30)
          ),
          child: Icon(
            isFav ? Icons.bookmark_rounded : Icons.bookmark_border_rounded,
            size: 17,
            color: isFav ? const Color(0xFFFFD9C4) : const Color(0xFFFFF1E4),
          ),
        ),
      ),
    );
  }
}

/* ─────────── 空状态（原型 .empty） ─────────── */

class _EmptyState extends StatelessWidget {
  const _EmptyState({this.onReset});

  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 56, 24, 24),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: ZaojiColors.paper2,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.search, size: 30, color: ZaojiColors.muted),
          ),
          const SizedBox(height: 14),
          Text(
            '没有找到菜品',
            style: ZaojiText.display(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          const Text(
            '试试换个关键词，或清掉筛选条件。也可以直接点右下角的按钮新建一道菜——配方记得越细，越值钱。',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              height: 1.72,
              color: ZaojiColors.muted,
            ),
          ),
          if (onReset != null) ...[
            const SizedBox(height: 16),
            TextButton(onPressed: onReset, child: const Text('清空筛选')),
          ],
        ],
      ),
    );
  }
}

/* ─────────── 悬浮添加按钮（原型 .add-fab） ─────────── */

/// **长按 380ms 才进入拖动，不是按住就拖。**
///
/// 理由与原型一致：这个按钮同时是「新建菜品」的点击入口，
/// 按住即拖会让「想点但手指停了一下」变成意外位移。
/// 拖完的那一下不会触发点击——长按与点按在手势竞技场里是互斥的，
/// 原型当年要靠「拖完抑制下一次 click」绕的坑，这里天然不存在。
///
/// 位置目前只活在内存里（切 tab 会保留，重启回默认）；
/// 「存本机偏好」等本地存储落地后一起做。
class _AddFab extends StatefulWidget {
  const _AddFab({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_AddFab> createState() => _AddFabState();
}

class _AddFabState extends State<_AddFab> {
  static const double _size = 60;
  static const double _margin = 16;
  static const double _defaultRight = 18;
  static const double _defaultBottom = 24;

  /// 顶部留白：不要让按钮拖到标题栏里去
  static const double _topLimit = 96;

  Offset? _pos;
  bool _armed = false;
  bool _dragging = false;

  /// 拖动起点。**`localOffsetFromOrigin` 是相对按下点的累计偏移**，
  /// 不是每次回调的增量——当年网页原型按增量算，一格只能挪一点。
  Offset? _dragStart;

  /// LayoutBuilder 的约束存下来给手势回调用（回调里拿不到 builder 参数）。
  BoxConstraints? _constraints;

  Offset get _defaultPos => Offset(
    _constraints!.maxWidth - _defaultRight - _size,
    _constraints!.maxHeight - _defaultBottom - _size,
  );

  Offset _clamp(Offset p) {
    final c = _constraints!;
    return Offset(
      p.dx.clamp(_margin, c.maxWidth - _size - _margin),
      p.dy.clamp(_topLimit, c.maxHeight - _size - _margin),
    );
  }

  void _onLongPressStart(LongPressStartDetails d) {
    setState(() {
      _armed = true;
      _dragStart = _pos ?? _defaultPos;
    });
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails d) {
    setState(() {
      _dragging = true;
      _pos = _clamp(_dragStart! + d.localOffsetFromOrigin);
    });
  }

  void _onLongPressEnd(LongPressEndDetails d) {
    setState(() {
      _armed = false;
      _dragging = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _constraints = constraints;
        final clamped = _clamp(_pos ?? _defaultPos);

        // ★ 提示条（.fab-tip）必须是**与按钮平级的兄弟节点**、只在拖动时挂上来。
        // 上一版把它放进包着按钮的 Column 里靠 AnimatedOpacity 隐藏——
        // 透明度不影响布局，它照样把按钮往下顶 33px、往右挤 39px，
        // 按钮直接被屏幕裁掉一半。这种 bug 靠位置断言抓，截图上只会觉得"歪了"。
        final children = <Widget>[
          Positioned(
            left: clamped.dx,
            top: clamped.dy,
            // ★ 之前整个按钮是 RawGestureDetector——语义树里根本没有它，
            //   读屏用户永远点不到「新建菜品」。Semantics 补上 button 角色
            //   与 onTap 动作（a11y 点击走语义动作，不经过手势竞技场，
            //   与物理点按互不干扰）；自动化 E2E 也靠这个 label 定位。
            child: Semantics(
              button: true,
              label: '新建菜品',
              onTap: widget.onTap,
              child: RawGestureDetector(
                behavior: HitTestBehavior.opaque,
                gestures: {
                  LongPressGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        LongPressGestureRecognizer
                      >(
                        // 380ms：原型定的时间。默认 500ms 会让「想拖」的等待感偏长。
                        () => LongPressGestureRecognizer(
                          duration: const Duration(milliseconds: 380),
                        ),
                        (instance) {
                          instance
                            ..onLongPressStart = _onLongPressStart
                            ..onLongPressMoveUpdate = _onLongPressMoveUpdate
                            ..onLongPressEnd = _onLongPressEnd;
                        },
                      ),
                  TapGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                        TapGestureRecognizer
                      >(() => TapGestureRecognizer(), (instance) {
                        // 长按在手势竞技场里天然压过点按，拖完不会触发点击——
                        // 这里的判断只是双保险（比如长按刚结束的极短窗口）。
                        instance.onTap = () {
                          if (!_armed && !_dragging) widget.onTap();
                        };
                      }),
                },
                child: AnimatedScale(
                  scale: _dragging
                      ? 1.12
                      : _armed
                      ? 1.06
                      : 1,
                  duration: const Duration(milliseconds: 170),
                  curve: ZaojiMotion.ease,
                  child: Container(
                    width: _size,
                    height: _size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        begin: Alignment(-0.6, -1),
                        end: Alignment(0.6, 1),
                        colors: [Color(0xFFE2571F), Color(0xFFC33F14)],
                      ),
                      boxShadow: _dragging
                          ? const [
                              BoxShadow(
                                color: Color(0x80C33F14),
                                blurRadius: 44,
                                offset: Offset(0, 20),
                              ),
                              BoxShadow(
                                color: Color(0x212E491C),
                                blurRadius: 12,
                              ),
                            ]
                          : const [
                              BoxShadow(
                                color: Color(0x5CC33F14), // rgba(195,63,20,.36)
                                blurRadius: 24,
                                offset: Offset(0, 10),
                              ),
                              BoxShadow(
                                color: Color(0x3318110B), // rgba(24,17,11,.2)
                                blurRadius: 8,
                                offset: Offset(0, 3),
                              ),
                            ],
                    ),
                    child: AnimatedRotation(
                      turns: _dragging ? 0.125 : 0,
                      duration: const Duration(milliseconds: 340),
                      child: const Icon(
                        Icons.add,
                        size: 26,
                        color: Color(0xFFFFF3E8),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ];

        if (_dragging) {
          final tipLeft = (clamped.dx + _size / 2 - 80).clamp(
            0.0,
            constraints.maxWidth - 160,
          );
          children.add(
            Positioned(
              left: tipLeft,
              top: clamped.dy - 34,
              child: Container(
                width: 160,
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xDD18110B), // rgba(24,17,11,.86)
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text(
                  '松开前拖到我顺手的位置',
                  style: TextStyle(fontSize: 10.5, color: Color(0xFFFFF3E8)),
                ),
              ),
            ),
          );
        }

        return Stack(children: children);
      },
    );
  }
}
