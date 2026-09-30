// R46 · 快赢包：详情页补「每次做的时间」区块（FR-REC-13 · 原型 sec 05）。
// 护栏：快照 → 锚点各命中一次 → 体积增长校验 → 写回。
const fs = require('fs');
const path = require('path');

const file = path.resolve(__dirname, '../app/lib/ui/recipe_detail_page.dart');
const snap = path.resolve(__dirname, '../dist/recipe_detail_before_r46history.dart');
const src = fs.readFileSync(file, 'utf8');
fs.writeFileSync(snap, src);

const ANCHOR = 'class _Notes extends StatelessWidget {';
if (src.split(ANCHOR).length - 1 !== 1) {
  throw new Error('锚点命中次数异常：' + (src.split(ANCHOR).length - 1));
}

const WIDGET = `/// 每次做的时间（FR-REC-13 · 原型 \`sec 05\` 的 \`.spec\` 行）。
///
/// 数据来自 \`cookSessions()\`：只有 \`finished_at\` 非空、且没进回收站的会话，
/// 按完成时刻倒序。所以这里**不显示进行中**的那次——它归顶部续做横幅管，
/// 两处各说各的，不会同一件事出现两行。
class _CookHistory extends StatelessWidget {
  const _CookHistory({required this.sessions});

  final List<CookSession> sessions;

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// \`09/14 18:30\` —— 年份留给日历页，这一屏只关心「什么时候做的」。
  static String stamp(DateTime d) =>
      '\${_two(d.month)}/\${_two(d.day)} \${_two(d.hour)}:\${_two(d.minute)}';

  @override
  Widget build(BuildContext context) {
    if (sessions.isEmpty) {
      // 与原型一致的空态：不藏这一块，否则用户不知道「做过」会被记下来。
      return Text(
        '还没有做过这道菜，做一次后会自动记录。',
        style: TextStyle(fontSize: 12.5, color: context.zj.muted),
      );
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
      decoration: BoxDecoration(
        color: context.zj.paper2,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(color: context.zj.lineSoft),
      ),
      child: Column(
        children: [
          for (var i = 0; i < sessions.length; i++)
            Padding(
              key: ValueKey('cook-history-\${sessions[i].id}'),
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      stamp(sessions[i].finishedAt ?? sessions[i].startedAt),
                      style: TextStyle(
                        fontSize: 13,
                        color: context.zj.ink,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  Text(
                    // 倒序列表里的「第 N 次」要从末尾数回来
                    '第 \${sessions.length - i} 次',
                    style: TextStyle(fontSize: 12.5, color: context.zj.muted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

`;

const out = src.replace(ANCHOR, WIDGET + ANCHOR);
if (out.length <= src.length) throw new Error('体积未增长');
fs.writeFileSync(file, out);
console.log(`✔ 已插入 _CookHistory，${src.length} -> ${out.length}；快照 ${snap}`);
