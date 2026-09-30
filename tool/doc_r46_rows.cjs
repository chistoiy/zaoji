// R46 · 划账第二半：交接文档 §六（下一步）加第 19 行、§九（变更日志）加 R46 行。
// 表格插行的老坑：拿「下一行的行首」当锚点会吞掉那行。这里改成**行级**定位——
// 先按整行找到目标行，再在它后面插新行，插完断言：行数 +1、没有以空格开头的残行。
const fs = require('fs');
const path = require('path');

const file = path.resolve(__dirname, '../灶记-交接文档.md');
const snap = path.resolve(__dirname, '../dist/before_r46log_rows.md');
const src = fs.readFileSync(file, 'utf8');
fs.writeFileSync(snap, src);
const crlf = src.includes('\r\n');
const NL = crlf ? '\r\n' : '\n';
const lines = src.split(NL);

function insertAfterRow(startsWith, newRow, label) {
  const idx = lines.findIndex((l) => l.startsWith(startsWith));
  if (idx < 0) throw new Error(`${label}：找不到以「${startsWith}」开头的行`);
  const dup = lines.filter((l) => l.startsWith(startsWith)).length;
  if (dup !== 1) throw new Error(`${label}：匹配 ${dup} 行，应为 1`);
  if (!newRow.startsWith('|') || !newRow.endsWith('|')) throw new Error(`${label}：新行不是完整表格行`);
  lines.splice(idx + 1, 0, newRow);
  return idx + 1;
}

const row19 = '| 19 | **R46 已完成（2026-09-29，实现轮 · 未发行）** | ✅ 四块全落地：① **R45 冷启动补加载**（`recipe_store.dart` `_doInit` 末尾补 `_loadNutrition/_loadPantry/_loadShopping`，一处修复救三处 UI：热量徽标 / 库存 / 购物清单）；② **热量可手填 + AI 结果可二改**（FR-AI-69~74，零 schema 改动：算法进 shared `nutrition_math.dart`，UI 进 `recipe_detail_page.dart` 双态卡 + 编辑弹层 + 依据弹层，来源只留 `ai`/`manual`，AI 原值以删除线留在依据页并由 `basis_json` 回声带走）；③ **快赢包**（接口清单补 R44 七条 + 摘掉幻影 `/api/ai/{feature}` + `endpoint_registry_r46_test` 双向钉死；三处过时文案清掉；搜索补标签这一路 FR-REC-10；详情页补「每次做的时间」FR-REC-13）；④ **原型同步**（热量双态/弹层/二次确认、第三标签「备菜」→「厨房」、搜索 placeholder 两处统一）。**基线**：shared 177 · server 320 · app 329 · analyze 三处 0。**这一轮欠的账**：产物没重编、版本号没动、没 push——本轮零改列所以不欠「apk+exe 同发」，但 R26~R44 的产物债见 §六-18；两处运维一分钟事（服务端带 `-w` 重启、备份远端配置）还挂着；`monthly_limit` / `ai_cache` / `key_hint` 三个摆设列留给 R53（取证工装已固化成 `tool/dead_columns_r46.cjs`） |';

const rowLog = '| R46 | 2026-09-29 | **热量手动编辑 + 冷启动补加载 + 快赢包（实现轮，未发行）**：按「先原型后实现」的铁律走完一整条链——原型热量双态卡/编辑弹层/依据弹层/二次确认 + 第三标签改名「厨房」+ 搜索 placeholder 统一（`tool/proto_nutrition_r46_walk.cjs` 40 断言全绿）→ shared 新增 `nutrition_math.dart`（三向换算 / 荒谬值二次确认 / `NutritionBasis` 编解码 / `nutriEchoFor`）→ app 双态卡片与两个弹层 + `_doInit` 补三张内存表。**零 schema 改动**：手改的来源写 `manual`，AI 原值走 `basis_json` 回声。测试：`cold_start_load_r46_test` 2 例（同 executor 再造一个 store 当真重启，摘掉三行 `_load*` 立刻红=反向验证）、`nutrition_manual_r46_test` 10 例、`quick_wins_r46_test` 6 例、`endpoint_registry_r46_test` 5 例（故意改错一条清单，三条测试红）。快赢顺手清掉：幻影接口 `/api/ai/{feature}` 摘除、R44 七条接口登记、`ai_settings_page`/`calendar_page`/`home_shell` 三处过时文案、搜索补标签（FR-REC-10）、详情页补每次做的时间（FR-REC-13）。新增可复用工装 `tool/dead_columns_r46.cjs`（snake/camel/drift 三种写法全查才算零引用，第一版只查 snake 误报 5 列）。基线 shared 160→177 · server 315→320 · app 311→329，`flutter analyze` 三处 0 |';

const a = insertAfterRow('| 18 | **R44 / R45 之后的实况与立项', row19, '§六-19');
const b = insertAfterRow('| 立项 | 2026-09-29 | **第三轮全量查漏补缺', rowLog, '§九 R46');

const out = lines.join(NL);
// 残行检查：本轮之前就因为「行首多空格」让整张表退化成纯文本
const stray = [];
for (let i = 0; i < lines.length; i++) {
  if (/^[ ]+\|/.test(lines[i])) stray.push(i + 1);
}
if (stray.length) throw new Error('出现空格开头的表格残行：' + stray.slice(0, 5).join(','));
const cols = (s) => s.replace(/\\\|/g, '').split('|').length - 2;
// §九 表头是「轮次 | 日期 | 内容」三列；§六 是「# | 任务 | 说明」三列。
if (cols(row19) !== 3) throw new Error('§六 新行列数 ' + cols(row19) + '，应为 3');
if (cols(rowLog) !== 3) throw new Error('§九 新行列数 ' + cols(rowLog) + '，应为 3');
fs.writeFileSync(file, out);
console.log(`✔ §六 第 ${a} 行、§九 第 ${b} 行插入完成；${src.length} -> ${out.length}`);
