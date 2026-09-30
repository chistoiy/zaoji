/* eslint-disable */
// 一次性文档补丁：给 灶记-交接文档.md 补 R44 记档、§六 新行 18、§九 变更日志三行。
// 三条护栏（§7.5 的规矩）：① 改前拍快照 ② 每个锚点必须**恰好命中一次**否则整体不动
// ③ 体积校验（新必须大于旧，且增幅在预期区间）+ 残行检测（不许出现以空格开头的表格行）。
// 本文行尾是 CRLF，所有锚点按 \r\n 拼。
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const target = path.join(root, '灶记-交接文档.md');
const snapshot = path.join(root, 'dist', 'handover_before_r46_planning.md');

const src = fs.readFileSync(target, 'utf8');
const NL = src.includes('\r\n') ? '\r\n' : '\n';
let lines = src.split(/\r?\n/);

const one = (pred, what) => {
  const hits = [];
  lines.forEach((l, i) => {
    if (pred(l)) hits.push(i);
  });
  if (hits.length !== 1) {
    console.error(`ABORT: 锚点「${what}」命中 ${hits.length} 次（要求恰好 1 次），文件未改动。`);
    process.exit(1);
  }
  return hits[0];
};

// ── 快照 ────────────────────────────────────────────────────────────
fs.mkdirSync(path.dirname(snapshot), { recursive: true });
fs.writeFileSync(snapshot, src, 'utf8');
const beforeBytes = Buffer.byteLength(src, 'utf8');

// ── ① §六 新行 18（插在 R38 缺口块那道引用之前，与上面的表格续上）──────
const idxQuote = one((l) => l.startsWith('> ### R38 之后的需求缺口清单'), '§六 末的 R38 缺口块');
const row18 = [
  '| 18 | **R44 / R45 之后的实况与立项（2026-09-29，本节最后更新）** | ' +
    '★ **本文件此前完全没有 R44 的记录**（全文 `grep -c R44` = 0）：§五 停在 R43、§九 变更日志停在 v0.14.4/v0.15.0 那两行——' +
    '而 R44 已经开发完、已发版 **v0.16.0**、两端发行版都挂了四件套。接手的人照本文档读会漏掉一整轮，' +
    '所以本轮先**补记 R44**（见 §五 末），再在此登记三条今天就能收的账与一份立项。' +
    '**① 立项**：全部缺口已转成轮次写进《开发计划书》§二十二（v1.5），R46~R53 各轮范围/是否改列/验收判据都在那里；' +
    '盘点全表（逐条回代码、带 file:line）在仓库根 `灶记-功能查漏补缺-2026-09-29.md`。' +
    '**下面那份 R38 时点的清单保留作历史**，读的时候按 §五 R39~R44 划掉已完成的，未完成的以计划书 §二十二 为准。' +
    '**② 三笔不用排期的账**：a) **R45 已定位且影响面比已报的宽**——`app/lib/data/recipe_store.dart:90-116` 的 `_doInit` 不加载 ' +
    '`_loadNutrition` / `_loadPantry` / `_loadShopping`，而这三张表只在 `reload()` 里被填，`reload()` 又只在同步 ' +
    '「pushed 或 applied 大于 0」时跑（`sync_engine.dart:534-536`）→ 没有增量可同步的冷启动后，**热量徽标、厨房库存、购物清单三处一起空**；' +
    '零 schema 改动，归 R46，回归必须真重载（只断言「库里有行」会假绿）。' +
    'b) **在跑的服务端没带 `-w`**：`/api/health` 实读 `webRoot: null`、`webReady: false`，' +
    'iPhone / 平板的网页版此刻打不开，重启时要把 `-w ..\\app\\build\\web` 带回（`upgrade_local_instance.ps1` 专为防这个）。' +
    'c) **备份三通道一个都没配**：`backup.configured: false`、`last: null`，`BackupScheduler.tick()` 的闸门是 `!cfg.hasRemote` 直接 return ' +
    '→ FR-DATA-11「每日自动备份」名义完成、实际未生效。' +
    '**③ 对外文案有一处说错了**：v0.16.0 发布说明写「AI 推荐菜品的界面入口还挂在下一轮」——' +
    '**厨房页的推荐这一版早就接上了**（`kitchen_page.dart:1056`，R31），那句是从 `ai_settings_page.dart:233` 那枚过时副标题抄来的。' +
    '两处一起随 R46 清掉，别让下一个用户以为功能没做。 |',
];
lines.splice(idxQuote, 0, ...row18);

// ── ② §五 补记 R44（插在 §六 标题前，前面已有 --- 分隔）─────────────────
const idxSix = one((l) => l.startsWith('## 六、下一步'), '§六 标题');
const r44 = [
  '### R44 · 2026-09-29 · AI 提示词管理 + 执行记录（已发布 v0.16.0）',
  '',
  '> **本小节是补记**：这一轮开发当时只写了代码与发行，没进本文件（全文原先 `R44` 零命中）。',
  '> 决策与取证原文在仓库根 `灶记-R44-AI提示词管理与执行记录-规划.md`（§10 实施校正、§11 尾巴）与',
  '> `dist/release_notes_v0.16.0.md`；这里只留接手需要的骨架。',
  '',
  '**做了什么**：服务端三段硬编码 prompt 变成「可查看 / 可编辑 / 可恢复默认」的配置，',
  '每一次 AI 调用（成功、上游失败、解析失败、能力被关的拒绝、**命中缓存**、配置页连通测试）都留下一行',
  '输入与输出全文的执行记录，可筛选、可搜索、可单删、可清空，默认滚动 90 天 + 硬上限 2000 条。',
  '',
  '**五条提交**（分层走法照旧）：`0cc5c61` schema v8 纯增 `ai_prompts` / `ai_runs` 两张 **serverOnly** 表 + `ai_usage` 补 `run_ref`/`summary`',
  '→ `8586910` 服务端三路留痕 + 占位符白名单校验 + runs/prompts 八端点 + 用量改读 `ai_runs` 聚合 → `93c7684` 客户端本机留痕 +',
  '执行记录页 + 提示词页 + 三能力调用点 → `b958b80` 版本 0.15.0→0.16.0 + README 对外补写 →',
  '`5047936` 真机走查修正：**缓存命中的响应要回传本次那行的 runId**（原来回传第一次真调用的 id，',
  '客户端照它写 `run_ref`，缓存那条就丢了「本机」标记）。',
  '',
  '**三条口径**（接手最容易踩的）：① 记录**两端都记**——服务端 `ai_runs` 是权威，客户端 `localOnly` 的 `ai_usage` 是本机视角；',
  '② 用量口径改成 **`ai_runs` 为唯一真相**，只数 `ok=1 AND cached=0`（失败与命中缓存都不计次不计费），',
  '旧 kv 计数器与 `_bumpUsage` 已删；③ 提示词与记录**都不出自家服务端、不进同步、不含 API Key**（两表都 `serverOnly`，',
  '有测试专门钉 Key 不出现）。修剪挂在**写入后**而不是定时器，所以服务端重启后不会立刻回收过期行，下一次调用才收。',
  '',
  '**恢复默认的实现选了「删覆盖行」而不是双份存储**（`ai.dart:349-352`），保存即清结果缓存——不会出现「提示词改了、估算还是老的」。',
  '',
  '**基线与发行**：shared 160 · server 315 · app 311（含 `ai_runs_page_test` 8 例、`ai_prompts_page_test` 5 例），`analyze` 0；',
  'tag `v0.16.0` = `5047936`，GitHub 与 Gitee 两端都挂了四件套（arm64 / v7a apk、exe、web zip），',
  '本机实例已换装到 v0.16.0 + schema v8（`/api/health` 现读 version 0.16.0、schemaVersion 8）。',
  '',
  '**留下的尾巴**（都进 R46~R53）：R45 冷启动那条（已定位，见 §六-18②）、执行记录修剪不挂定时器是有意立场、',
  '`ai_settings_page.dart:233` 那句「下一轮接入」是过时文案、发布说明跟着抄错的那句要对外更正。',
  '',
  '---',
  '',
];
lines.splice(idxSix, 0, ...r44);

// ── ③ §九 变更日志补三行（表在文件末尾）─────────────────────────────────
const lastIdx = lines.length - 1;
let tailIdx = lastIdx;
while (tailIdx >= 0 && lines[tailIdx].trim() === '') tailIdx--;
if (!lines[tailIdx].startsWith('| v0.14.4 |')) {
  console.error('ABORT: 变更日志表尾行不是 v0.14.4，实际是：' + lines[tailIdx].slice(0, 60));
  process.exit(1);
}
const logRows = [
  '| R44 | 2026-09-29 | **（补记）AI 提示词管理 + 执行记录**：schema v8 纯增 `ai_prompts`/`ai_runs` 两张 serverOnly 表 · 六路留痕（成功/上游失败/解析失败/关闭拒绝/缓存命中/连通测试）· 输入输出全文可查可删可清空 · 90 天滚动 + 2000 条硬上限 · system+user 双模板可编（占位符白名单校验、恢复默认=删覆盖行、保存即清缓存）· 用量改读 `ai_runs` 聚合为唯一真相。基线 shared 160 · server 315 · app 311。详见 §五 R44 |',
  '| 发行 | 2026-09-29 | **v0.16.0**（0.15.0+12 → 0.16.0+13）：R44 一块内容出去，**前后端都要换**。tag `v0.16.0` = `5047936`（含真机走查修正：缓存命中回传**本次**那行的 runId），GitHub + Gitee 双远端各挂全四件套，本机实例已换装并实测 `/api/health` 报 v0.16.0 / schema v8。⚠ 发布说明里「AI 推荐的界面入口还挂在下一轮」那句**是错的**（`kitchen_page.dart:1056` R31 就接上了），随 R46 更正 |',
  '| 立项 | 2026-09-29 | **第三轮全量查漏补缺 + R46~R53 立项（本轮只动文档，不动代码）**：① 按四条判据把功能面重头盘一遍，全表带 file:line 落 `灶记-功能查漏补缺-2026-09-29.md`；② **R45 已定位**且影响面比已报的宽（`_doInit` 漏加载 nutrition/pantry/shopping 三张内存表 → 热量徽标 + 库存 + 购物清单三处冷启动后同空）；③ 用户新增需求「热量可手动编辑、AI 结果可二次编辑」成文为需求书 **§4.5.7 / FR-AI-69~74**（七条实现口径，含「零 schema 改动、AI 原值走 `basis_json` 留痕、来源只保留 ai/manual 两态」）；④ 需求书 → **v1.4**（A6 改写、新增 A17/A18、A16 按门控反转口径更正、变更记录补 v1.2~v1.4 三行）；⑤ 计划书 → **v1.5** 新增 **§二十二**（R46~R53 范围/是否改列/量/优先级，所有改列需求压进 R48 一次付账）；⑥ 顺手登记一批文档与事实漂移：`/api/health` 端点清单缺 R44 那 7 条还写着不存在的 `/api/ai/{feature}`、`monthly_limit` 与 `ai_cache` 是「有列有表零代码」的摆设项、`calendar_page`/`home_shell`/`ai_settings_page` 三处头注过时、SRS 默认模型 `deepseek-v4-flash` vs 代码 `deepseek-flash` |',
];
lines.splice(tailIdx + 1, 0, ...logRows);

// ── 校验与写盘 ───────────────────────────────────────────────────────
const out = lines.join(NL);
const afterBytes = Buffer.byteLength(out, 'utf8');
const addedRows = out.split(/\r?\n/).filter((l, i, a) => /^\| /.test(l) && a[i - 1] !== undefined && /^\| /.test(a[i - 1]) === false && i > 0).length;
if (!(afterBytes > beforeBytes)) {
  console.error(`ABORT: 体积没增大 ${beforeBytes} → ${afterBytes}`);
  process.exit(1);
}
if (afterBytes - beforeBytes > 40000 || afterBytes - beforeBytes < 4000) {
  console.error(`ABORT: 增幅异常 ${afterBytes - beforeBytes} B（预期 4k~40k）`);
  process.exit(1);
}
// 残行：表格行不许以空格开头；也不许出现「| |」空首格
const bad = out.split(/\r?\n/).filter((l) => /^ +\| /.test(l) || /^\|\s*\|.*\|$/.test(l));
if (bad.length) {
  console.error(`ABORT: 检出 ${bad.length} 行残行，样例：\n${bad.slice(0, 3).join('\n')}`);
  process.exit(1);
}
fs.writeFileSync(target, out, 'utf8');
console.log(`OK  ${beforeBytes} B → ${afterBytes} B（+${afterBytes - beforeBytes}）`);
console.log(`行数 ${src.split(/\r?\n/).length} → ${out.split(/\r?\n/).length}`);
console.log(`快照 ${path.relative(root, snapshot)}`);
