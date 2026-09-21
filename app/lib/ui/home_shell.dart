import 'package:flutter/material.dart';

import '../theme.dart';
import 'me_page.dart';
import 'menus_page.dart';
import 'recipe_list_page.dart';

/// 主页外壳：底部 5 标签 + 页面栈。
///
/// 结构与原型一致（`TABS` + `.tabbar`）：
/// 菜谱 / 菜单 / 备菜 / 日历 / 我的。
///
/// **R13：「我的」升级为同步设置页**（配对 / 立即同步 / 设备身份），
/// **R23：「菜单」做实**（餐次卡 / 详情 / 一键备菜）；
/// 其余两页仍是占位空态——这比两种做法都好：
/// 导航结构先立起来（否则主页就缺一块，和高保真对不上），
/// 又不至于用半成品假数据冒充已实现。
/// 用 `IndexedStack` 而不是切换路由，是为了**保住列表页的筛选/收藏/滚动位置**——
/// 挑完菜回到菜谱页，状态还在。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.initialTab = 0});

  /// 深链入口用（`#/menus` → 1）。
  final int initialTab;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

typedef _TabData = ({IconData icon, IconData activeIcon, String label});

/// 五个标签（原型 `TABS`）。菜谱 / 菜单 / 备菜 / 日历 / 我的。
const List<_TabData> _kTabs = [
  (icon: Icons.menu_book_outlined, activeIcon: Icons.menu_book, label: '菜谱'),
  (icon: Icons.receipt_long_outlined, activeIcon: Icons.receipt_long, label: '菜单'),
  (icon: Icons.shopping_basket_outlined, activeIcon: Icons.shopping_basket, label: '备菜'),
  (icon: Icons.calendar_month_outlined, activeIcon: Icons.calendar_month, label: '日历'),
  (icon: Icons.person_outline, activeIcon: Icons.person, label: '我的'),
];

class _HomeShellState extends State<HomeShell> {
  late int _index = widget.initialTab;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZaojiColors.paper,
      body: IndexedStack(
        index: _index,
        children: [
          const RecipeListPage(),
          const MenusPage(),
          _ComingSoon(icon: Icons.shopping_basket, title: '备菜'),
          _ComingSoon(icon: Icons.calendar_month, title: '日历'),
          const MePage(),
        ],
      ),
      bottomNavigationBar: _TabBar(
        index: _index,
        onTap: (i) => setState(() => _index = i),
      ),
    );
  }
}

/// 底部标签栏（原型 `.tabbar` / `.tab`）。
///
/// **不用 Material 的 NavigationBar**：它自带 M3 的胶囊指示器，
/// 而原型的选中态是「顶部 2px 短线 + 变色」——导航是每屏都在的骨架，
/// 这里走样一点，整个 App 的气质就跟着走样。
class _TabBar extends StatelessWidget {
  const _TabBar({required this.index, required this.onTap});

  final int index;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: ZaojiColors.paper,
        border: Border(top: BorderSide(color: ZaojiColors.lineSoft)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              for (final (i, t) in _kTabs.indexed)
                Expanded(
                  child: _TabItem(
                    data: t,
                    selected: i == index,
                    onTap: () => onTap(i),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.data,
    required this.selected,
    required this.onTap,
  });

  final _TabData data;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? ZaojiColors.accent : ZaojiColors.muted;
    return Semantics(
      button: true,
      selected: selected,
      label: data.label,
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 选中态：顶部 2px 短线（原型 .tab::after）
            SizedBox(
              height: 2,
              width: 22,
              child: AnimatedOpacity(
                opacity: selected ? 1 : 0,
                duration: const Duration(milliseconds: 340),
                curve: ZaojiMotion.ease,
                child: Container(
                  decoration: BoxDecoration(
                    color: ZaojiColors.accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 3),
            Icon(selected ? data.activeIcon : data.icon, size: 22, color: color),
            const SizedBox(height: 3),
            Text(
              data.label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
                letterSpacing: .2,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 未实现屏的占位。
///
/// **给的是状态和下一步，不是一句「开发中」就完了**——
/// 用户点过来是要干一件事的，得告诉他这事现在去哪儿干。
class _ComingSoon extends StatelessWidget {
  const _ComingSoon({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZaojiColors.paper,
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  color: ZaojiColors.paper2,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 32, color: ZaojiColors.muted),
              ),
              const SizedBox(height: 16),
              Text('$title还没有做出来',
                  style: ZaojiText.display(fontSize: 17, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              const Text(
                '先把菜谱库用起来。这一屏在 M2/M3 排期里，\n做完会自动出现在这里。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, height: 1.7, color: ZaojiColors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
