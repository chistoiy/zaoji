import 'package:flutter/material.dart';

import '../data/store_scope.dart';
import '../theme.dart';

/// 主题选择页（R39 · FR-SET-08 的第一半：换肤）。
///
/// **每张卡外面套一层自己的 [Theme]**——卡里那一小块就是那套配色渲染出来的
/// 真样子，不是示意图。这样色值只有一份（[ZaojiTokens] 里那五个常量），
/// 预览再抄一遍就必然和实机不一致。
///
/// 交互照原型：点一下立即生效、页面不关，可以连着比五套。
/// 副标题那句「只影响这台设备」是**状态说明**不是教程——
/// 用户会问"平板上换了手机上怎么没变"，这行提前回答它。
class ThemePage extends StatelessWidget {
  const ThemePage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    return Scaffold(
      backgroundColor: context.zj.paper,
      appBar: AppBar(
        title: const Text('主题'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(22),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '五套配色 · 只影响这台设备',
                style: TextStyle(fontSize: 12, color: context.zj.muted),
              ),
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          for (final t in ZaojiTokens.all)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _ThemeCard(
                tokens: t,
                selected: store.themeId == t.id,
                onTap: () => store.setTheme(t.id),
              ),
            ),
        ],
      ),
    );
  }
}

class _ThemeCard extends StatelessWidget {
  const _ThemeCard({
    required this.tokens,
    required this.selected,
    required this.onTap,
  });

  final ZaojiTokens tokens;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 外层 Theme 决定卡内一切取色；selected 的描边用**页面自己的**强调色，
    // 否则五张卡会各自亮各自的边框色，看不出"哪个是当前用的"。
    final pageZj = context.zj;
    return Theme(
      data: buildZaojiTheme(tokens),
      child: Material(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        child: InkWell(
          key: ValueKey('theme-${tokens.id}'),
          borderRadius: BorderRadius.circular(ZaojiRadius.md),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(ZaojiRadius.md),
              border: Border.all(
                color: selected ? pageZj.accent : tokens.line,
                width: selected ? 1.6 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const _MiniPreview(),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tokens.label,
                        style: ZaojiText.displayOf(context, 
                          fontSize: 15.5,
                          fontWeight: FontWeight.w600,
                          color: tokens.ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        tokens.hint,
                        style: TextStyle(fontSize: 12, color: tokens.muted),
                      ),
                    ],
                  ),
                ),
                if (selected)
                  Text(
                    '使用中',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: tokens.ok,
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

/// 一小块"纸上界面"：菜名、两行正文、一枚强调色按钮、三枚库存状态点。
/// 这四样是全套界面里最吃配色的东西，它们都读得清，别的屏基本也读得清。
class _MiniPreview extends StatelessWidget {
  const _MiniPreview();

  @override
  Widget build(BuildContext context) {
    final zj = context.zj;
    return Container(
      width: 104,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: zj.paper,
        borderRadius: BorderRadius.circular(ZaojiRadius.sm),
        border: Border.all(color: zj.lineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '葱油拌面',
            style: ZaojiText.displayOf(context, 
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: zj.ink,
            ),
          ),
          const SizedBox(height: 6),
          _bar(zj.line, 1),
          const SizedBox(height: 4),
          _bar(zj.line, .58),
          const SizedBox(height: 8),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: zj.accent,
                  borderRadius: BorderRadius.circular(ZaojiRadius.xl),
                ),
                child: Text(
                  '开火',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: zj.onAccent,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              _dot(zj.ok),
              _dot(zj.amber2),
              _dot(zj.line),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bar(Color color, double frac) => FractionallySizedBox(
        widthFactor: frac,
        child: Container(
          height: 4,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
      );

  Widget _dot(Color color) => Padding(
        padding: const EdgeInsets.only(right: 3),
        child: Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      );
}
