// R48 补正（真机走查抓到的两条）划账。
// 三份文档一起改，每处带命中断言；跑完再过 doc_table_lint（表格插行会吞行首，记过）。
// 用法：node tool/doc_r48b.cjs [--check]
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const HAND = path.join(ROOT, '灶记-交接文档.md');
const PLAN = path.join(ROOT, '灶记-开发计划书.md');
const GAP = path.join(ROOT, '灶记-功能查漏补缺-2026-09-29.md');

const FIX_SECTION =
  '\n' +
  '**补正（同日 · 装机走查抓到的三条，都不是坐在桌面能想到的）**\n' +
  '\n' +
  '★ 上面 ①~⑨ 全绿（shared 20 + app 14 + 五刀变异 + 原型走查 27 条）之后，把 apk 装上真机走了一遍才抓到这三条。\n' +
  '**"测试全绿"不等于"这屏对了"**——尤其当测试的断言只覆盖了"有数据时会怎样"。\n' +
  '\n' +
  '⑩ **点「看更早」什么都不变**（真机上按了两下、坐标也对着 uiautomator 报的 bounds 打的，列表纹丝不动）。' +
  '查下来是**注释与实现各说各话**：`_earlier()` 的注释写着"窗口整体往前推一页：不是追加"，' +
  '可代码里 `toDay` 恒为明天、只有 `fromDay` 往前退——**它就是追加**。' +
  '这台机上近 90 天之外没有记录，于是那一按没有任何可见反馈，正撞「控件点了必须有看得见的变化」。' +
  '收口三条：① 口径统一成**追加**（已看过的留着，注释跟着改）；② 每点一次底部给一行读数——' +
  '有新记录说「已看到最近 180 天」，没翻到东西说「再往前 90 天没有记录」（这句是实话：更早的历史可能还在，' +
  '不许写"到底了"）；③ 顺手补掉一个竞态——查询在跑时翻页会被静默吞掉，改成 `_pending` 记一笔、跑完补一趟。' +
  '用例三条（有新增 / 无新增 / 今天那条不许因为翻页消失），变异刀 `earlierNoFeedback` 摘掉读数必红。\n' +
  '⑪ **耗时读数：966 分钟没人读得动**。机上那趟菜是昨天 15:14 开的、走查时长按完成，挂钟 16 小时——' +
  '数字是**真的**，但「实际耗时 966 分钟」是假的可用性。shared 加 `timelineDurationLabel`' +
  '（<60 写分钟；≥60 写「H 小时 M 分」，整点不补「0 分」；负数夹到 0），' +
  '★ **时间线与日历一把尺**：日历那行原来直接写 `${e.minutes} 分钟`，两处一起换过去（同一趟会话在两屏必须同一个读法）。' +
  '变异刀 `durNoHours`；装机复验那趟显示「16 小时 6 分」。' +
  '★ 一处**刻意没统一**：统计页那格本月累计早就是自己转小时的（`12 时 40 分` 这种紧凑写法，`stats_page.dart:121-123`），' +
  '量的是"这个月总共在灶前多久"而不是"某一趟多久"，本轮不动它，留作口径备忘。\n' +
  '⑫ ★ **记账不改数据：示例种子写着假历史**。`app/lib/data/seed.dart:26-296` 给示例菜塞了' +
  '`cooked_count: 18` 与 `last_cooked_at: \'2026-09-17\'`，可 `cook_session` 里**没有对应行**——' +
  '于是首页卡与详情页说"做过 18 次 · 09/17"，日历说"本月开火 0 次"，时间线里也没那条。' +
  '两屏同源没坏（日历与时间线都读 `cook_session`），坏的是**首屏那两处读的是 recipe 上的冗余列**。' +
  '要不要让示例菜带假计数是产品口径，**等拍**：要么种子不写这两列，要么首屏那行标"示例"。本轮只记这条账，没动数据。\n' +
  '⑬ **产物**：`0.16.0+16`（时间线首版）→ 补正后 `0.16.0+17`，arm64 与 armeabi-v7a **两件一起重编**' +
  '（v7a 那份自 9-29 17:50 起就没重编过，这次顺手换掉），`app/tool/verify_apk.ps1` 两 ABI 的 ' +
  'versionName / versionCode 尾号 / INTERNET / libsqlite3.so **四件全 PASS**，装机复验两条都过。' +
  '★ 仍然**没发版**：versionName 还是 0.16.0，没建 tag、没挂四件套，exe 与 web 产物没动（零改列，不欠「apk + exe 同发」）。\n' +
  '⑭ **基线随补正再升**：shared 213→**217** · app 465→**469** · server **320** 未动 · analyze 三处 0 ·' +
  '反向验证五刀→**七刀** · 原型走查新增 `tool/proto_timeline_r48b_walk.cjs` **15 条全 PASS**' +
  '（时长期望由走查脚本自己算一遍，不拿被测的 `durLabel` 验被测的）。\n';

const JOBS = [
  {
    file: HAND,
    edits: [
      {
        name: '§五 R48 段末追加补正三条',
        from: '产物 / 版本号 / push：门禁绿后经用户确认（"门禁绿了就提交并推双远端"）提交并推 GitHub origin + Gitee；**版本号不动、apk/exe/web 产物一律不重编**（时间线是新屏，要进真机得随下一次发版一起编，零改列所以不欠「apk + exe 同发」）。\n',
        to: '产物 / 版本号 / push：门禁绿后经用户确认（"门禁绿了就提交并推双远端"）提交并推 GitHub origin + Gitee。\n' +
          FIX_SECTION,
      },
      {
        name: '§六-21 行尾更正（翻页口径 + 产物已重编）',
        from: '基线 shared **213** · server 320 · app **465** · analyze 三处 0 · 反向验证五刀（`tool/timeline_r48_mutation.cjs`）各红一条。细节见 §五 R48。**没做的**：行上照片（要 R48 改列）、评分/翻车事件（FR-LOG-06）、apk 未重编 |',
        to: '基线 shared **217** · server 320 · app **469** · analyze 三处 0 · 反向验证**七刀**（`tool/timeline_r48_mutation.cjs`）各红一条。' +
          '★ **同日补正（装机走查抓到的）**：「看更早」是**追加**不是平移，且每点一次必须给一行读数' +
          '（「已看到最近 180 天」/「再往前 90 天没有记录」）；耗时 ≥60 转「H 小时 M 分」，' +
          '时间线与日历共用 `timelineDurationLabel` 一把尺。细节见 §五 R48 ⑩~⑭。' +
          '**apk 已重编两件并装机**（`0.16.0+17`，arm64 + v7a，v7a 那笔旧账顺手换掉），**但没发版**：' +
          'versionName 仍 0.16.0，tag / 四件套 / exe / web 产物都没动。' +
          '**没做的**：行上照片（要 R48 改列）、评分/翻车事件（FR-LOG-06）、' +
          '★ 示例种子的假"做过 N 次 · 日期"与日历/时间线口径矛盾（§五 R48 ⑫，等产品拍） |',
      },
      {
        name: '§7.10 追加补正的三条坑',
        from: '先补证据再动手（§7.3 取证先自证的老口径） |',
        to: '先补证据再动手（§7.3 取证先自证的老口径） |\n' +
          '| ★★ **注释写着"不是追加"，代码就是追加；测试全绿，真机上点了没反应**（R48 补正） | ' +
          '`_earlier()` 那行注释斩钉截铁写着"窗口整体往前推一页：不是追加"，可 `toDay` 恒为明天、只有 `fromDay` 往前退——' +
          '实现从头到尾都是追加。这台机上近 90 天之外没记录，于是按钮按下去**什么都不变**，' +
          '而 14 条用例全绿：**断言只覆盖了"有数据时翻得出来"，没覆盖"没数据时点了要有反应"**。' +
          '三条一起收：① 口径与注释对齐（追加就写追加）；② 每次点击给一行诚实读数；' +
          '③ 补 `_pending`——查询在跑时那一下会被一次性闩静默吞掉。' +
          '★ **通用口径：窗口/翻页类控件，用例要断"每一次点击都有可见变化"，不能只断"有货时能翻到货"** |\n' +
          '| ★ **示例种子写着假历史，派生屏写着真话，两边在真机上打架**（R48 补正） | ' +
          '`seed.dart` 给示例菜塞 `cooked_count: 18` / `last_cooked_at: 2026-09-17`，' +
          '但 `cook_session` 一行没有——首页说"做过 18 次 · 09/17"，日历说"本月开火 0 次"，时间线空白。' +
          '这不是派生逻辑的 bug（日历与时间线都读 `cook_session`，同源成立），' +
          '是**冗余列与事实并存**的账：同一件事两种说法，谁都没错。' +
          '★ 教训口径：数据类功能要在**真机现有库**上走一遍，夹具里的数据永远是自己造给自己看的 |\n' +
          '| ★ **数字是真的，但读不动 = 假可用性**（R48 补正） | 一趟忘了点完成的会话挂了 16 小时，' +
          '"实际耗时 966 分钟"每个字符都对，可没人能从 966 读出"过夜"。' +
          '格式化也是口径：≥60 转「H 小时 M 分」，整点不补「0 分」，负数（改系统时间/跨时区）夹到 0。' +
          '★ 而且这把尺**两屏共用**（时间线与日历原来各写各的），一处改两处生效，别在 UI 里再拼一次字符串 |\n',
      },
      {
        name: '§九 修 R48 行里的编号 typo',
        from: '3 ★「第 N 次」按该菜**全部**会话排名',
        to: '③ ★「第 N 次」按该菜**全部**会话排名',
      },
      {
        name: '§九 变更日志加一行 R48 补正',
        from: '——见 §五 R48、§六-21 |',
        to: '——见 §五 R48、§六-21 |\n' +
          '| R48 补正 | 2026-10-01 | **时间线装机走查抓到的三条**（用户：「继续吧」→ 选「编 apk 装机走查时间线」）。' +
          '⑩ ★ 点「看更早」在真机上**没有任何可见变化**：注释说"往前推一页"、代码是追加（`toDay` 恒为明天），' +
          '这台机又确实没有 90 天外的记录——14 条用例全绿也照样漏，因为断言只覆盖"有货时翻得出来"。' +
          '改成口径统一（追加）+ 每次点击给一行诚实读数（「已看到最近 180 天」/「再往前 90 天没有记录」）' +
          '+ `_pending` 补掉"查询在跑时那一下被静默吞掉"。' +
          '⑪ ★ 那趟挂了 16 小时的会话写着「实际耗时 966 分钟」——数字真但读不动：shared 加 `timelineDurationLabel`' +
          '（≥60 转「H 小时 M 分」、整点不补 0 分、负数夹 0），**时间线与日历一把尺**（日历原来直接拼 `${e.minutes} 分钟`）。' +
          '⑫ ★ 记账不改数据：`seed.dart` 给示例菜写了假 `cooked_count`/`last_cooked_at`，' +
          '与日历"本月开火 0 次"、时间线空白打架——两屏同源没坏，坏在冗余列与事实并存，等产品拍口径。' +
          '⑬ 守卫：shared 20→**24** 例、app 14→**17** 例（翻页三种反应 + 时长边界 + 日历那把尺），' +
          '反向验证五刀→**七刀**（新增 `durNoHours` / `earlierNoFeedback`），原型走查 `tool/proto_timeline_r48b_walk.cjs` ' +
          '**15 条全 PASS**（时长期望由走查脚本自己算，不拿被测函数验被测 DOM）。' +
          '⑭ 基线 shared **217** · server **320** · app **469** · analyze 三处 0；' +
          'apk **两件重编并装机**（`0.16.0+17`，v7a 那笔 9-29 的旧账顺手换掉，verify_apk 两 ABI 四件全 PASS），' +
          '★ **没发版**：versionName 仍 0.16.0，tag/四件套/exe/web 都没动。——见 §五 R48 ⑩~⑭、§六-21、§7.10 |',
      },
    ],
  },
  {
    file: PLAN,
    edits: [
      {
        name: '§22.2 R48 第一段行补记同日补正',
        from: '| **R48 第一段** ✅ **已完成（2026-10-01）** | 回顾时间线：三类事件（做菜 / 建菜单 / 新增菜品）一屏，聚合与「没有的时刻」放 `shared/lib/src/timeline.dart` | FR-LOG-01 |',
        to: '| **R48 第一段** ✅ **已完成（2026-10-01，同日补正三条）** | 回顾时间线：三类事件（做菜 / 建菜单 / 新增菜品）一屏，聚合与「没有的时刻」放 `shared/lib/src/timeline.dart`；★ 装机走查后补：「看更早」按**追加**收口且每点必给覆盖读数、耗时 ≥60 转小时（两屏一把尺）、示例种子的假"做过 N 次"记账等拍 | FR-LOG-01 |',
      },
    ],
  },
  {
    file: GAP,
    edits: [
      {
        name: '盘点：加一条"首屏冗余计数与派生屏打架"待拍',
        from: '**FR-LOG-03**（点日期看当天全部事件）在 R24 做实日历时就有了，不用再排一轮 |',
        to: '**FR-LOG-03**（点日期看当天全部事件）在 R24 做实日历时就有了，不用再排一轮 |\n' +
          '| 回顾（口径打架） | 示例种子的假历史与派生屏的事实并存，**等产品拍** | ' +
          '★ 装机走查量到的：`app/lib/data/seed.dart` 给示例菜写了 `cooked_count: 18` / `last_cooked_at: 2026-09-17`，' +
          '而 `cook_session` 里没有对应行 → 首页/详情说"做过 18 次 · 09/17"，日历说"本月开火 0 次"、时间线空白。' +
          '日历与时间线**同源没错**（都读 `cook_session`），错在冗余列与事实各说各话。' +
          '两条出路：① 种子不写这两列（首屏那行自然消失）；② 保留但在首屏标"示例"。' +
          '本轮只记账没动数据。见交接文档 §五 R48 ⑫ |',
      },
    ],
  },
];

const check = process.argv.includes('--check');
let bad = 0;
const staged = new Map();
for (const job of JOBS) {
  const raw = fs.readFileSync(job.file, 'utf8');
  const eol = raw.includes('\r\n') ? '\r\n' : '\n';
  const j = (s) => s.split('\n').map((x) => x.replace(/\r$/, '')).join(eol);
  let text = staged.get(job.file) || raw;
  for (const e of job.edits) {
    const from = j(e.from), to = j(e.to);
    const hits = text.split(from).length - 1;
    if (hits !== 1) {
      console.log(`[${path.basename(job.file)}] ${e.name} → 命中 ${hits} 次 FAIL`);
      bad++;
      continue;
    }
    text = text.replace(from, to);
    if (text.split(to).length - 1 !== 1) {
      console.log(`[${path.basename(job.file)}] ${e.name} → 落地自检 FAIL`);
      bad++;
      continue;
    }
    console.log(`[${path.basename(job.file)}] ${e.name} OK`);
  }
  staged.set(job.file, text);
}
if (bad) { console.log(`\n${bad} 处锚点没对上，未写盘。`); process.exit(1); }
if (check) { console.log('\n--check：全部命中，未写盘。'); process.exit(0); }
for (const [f, text] of staged) {
  fs.writeFileSync(f + '.bak_r48b', fs.readFileSync(f), 'utf8');
  const grew = Buffer.byteLength(text) - Buffer.byteLength(fs.readFileSync(f));
  fs.writeFileSync(f, text, 'utf8');
  console.log(`写盘 ${path.basename(f)}：+${grew} bytes（备份 .bak_r48b）`);
}
