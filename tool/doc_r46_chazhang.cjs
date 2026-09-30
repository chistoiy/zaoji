// R46 · 划账：把这轮实现写进四份项目文档（这些文档 gitignored，改错了没有 git 能救，
// 所以一律走「快照 → 锚点必须命中恰好一次 → 体积/结构校验 → 写回」）。
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const snapDir = path.resolve(__dirname, '../dist');
const log = [];

function patchDoc(rel, jobs) {
  const file = path.join(root, rel);
  const src = fs.readFileSync(file, 'utf8');
  // 文档全是 CRLF（Windows 上手工编辑过）。锚点与插入文本都跟着换行风格走，
  // 不然「命中 0 次」——本轮第一次写这类脚本就在这上面白跑一趟。
  const crlf = src.includes('\r\n');
  const E = (t) => (crlf ? t.replace(/\n/g, '\r\n') : t);
  const stamp = rel.replace(/[^\w]/g, '_');
  fs.writeFileSync(path.join(snapDir, `before_r46log_${stamp}.md`), src);
  let out = src;
  for (const j of jobs) {
    const anchor = E(j.anchor);
    const n = out.split(anchor).length - 1;
    if (n !== 1) throw new Error(`${rel}：锚点命中 ${n} 次（应为 1）→ ${j.anchor.slice(0, 48)}`);
    out = j.mode === 'after'
      ? out.replace(anchor, anchor + E(j.text))
      : out.replace(anchor, E(j.text) + anchor);
    if (j.assert && !out.includes(j.assert)) throw new Error(`${rel}：插入后找不到预期内容 ${j.assert}`);
  }
  if (out.length <= src.length) throw new Error(`${rel}：体积没增长`);
  fs.writeFileSync(file, out);
  log.push(`✔ ${rel}：${jobs.length} 处，${src.length} -> ${out.length}（${crlf ? 'CRLF' : 'LF'}）`);
}

/* ───────── 1. 盘点报告：补 key_hint 这第三个摆设列 ───────── */
patchDoc('灶记-功能查漏补缺-2026-09-29.md', [{
  anchor: '→ **重启即失效，S10「双端缓存命中不重复计费」在服务端重启后不成立** |',
  mode: 'after',
  text: '\n| 摆设列（R46 复核） | `ai_config.key_hint` 同样「有列、零代码」 | 掩码是 `ai.dart:78` **现算**的（`••••` + 末四位），这一列从来没被写过。三个摆设列由 `tool/dead_columns_r46.cjs` 一次列出——它把 snake / camel / drift 属性名三种写法都查过才算「零引用」，第一版只查 snake_case 时误报过 5 列（工装先自证的又一例） |',
  assert: 'tool/dead_columns_r46.cjs',
}]);

/* ───────── 2. 交接文档 §五：新增 R46 实现轮小节 ───────── */
const r46 = `### R46 · 2026-09-29 · 热量可手填可二改 + 冷启动补加载 + 快赢包（实现轮，**未发行**）

**这一轮干了四件事**（立项见 §九「立项」行与计划书 §二十二；本节只记落地）：

① **R45 的洞补上**：\`RecipeStore._doInit\` 末尾补 \`_loadNutrition/_loadPantry/_loadShopping\`（\`recipe_store.dart\`）。
一个修复救三处 UI——热量徽标、库存页、购物清单原本冷启动后全空，只有同步拉到增量才 \`reload\`。
守卫由 \`app/test/cold_start_load_r46_test.dart\`（2 例）钉死：用**同一个 executor 再造一个 RecipeStore** 当「真重启」，
反向验证过（摘掉三行 → \`Expected: <250> Actual: <null>\`）。

② **热量手动编辑 + AI 结果二次编辑（FR-AI-69~74）**：零 schema 改动。
算法落 shared（\`shared/lib/src/nutrition_math.dart\`：每份↔整锅↔人数三向换算、荒谬值二次确认、\`NutritionBasis\` 编解码、
\`nutriEchoFor\` 决定 AI 原值怎么带走），UI 落 \`recipe_detail_page.dart\`（双态卡片 + 编辑弹层 + 依据弹层）。
**来源只有 \`ai\` / \`manual\` 两态**；手改后卡片不再挂 AI 免责句，但「AI 原估」以删除线留在依据页里，
\`basis_json\` 存食材逐条 + AI 回包回声——用户点「用 AI 重算」才回到 ai 态。

③ **快赢包**：状态页/\`/api/health\` 的接口清单补齐 R44 那 7 条与 R27 三条代理接口、
摘掉根本不存在的 \`/api/ai/{feature}\`，并加 \`server/test/endpoint_registry_r46_test.dart\`（5 例）
把「路由表 ↔ 清单」双向钉住（故意改错一条 → 三条测试红，反向验证过）；
清掉三处过时文案（\`ai_settings_page.dart\` 的「下一轮接入」、\`calendar_page.dart\` 头注说没有第三种点、
\`home_shell.dart\` 头注写「备菜 tab 占位」）；搜索补上标签这一路（FR-REC-10）；
详情页补「每次做的时间」区块（FR-REC-13，读 \`store.cookSessions()\`，进行中的那次不混进来）。

④ **原型同步**（UI 铁律：先原型后实现）：热量卡双态/编辑弹层/依据弹层/二次确认条，
第三个主标签名「备菜」→「厨房」（App 里 R28 就做实了，原型一直没跟上），
搜索框 placeholder 两处口径统一成「搜菜名、食材、标签」。
\`tool/proto_nutrition_r46_walk.cjs\` 40 条断言全绿。

**基线**：shared 177（160→177）· server 320（315→320）· app **329**（311→329）· analyze 三处全 0。

**没有做的事**（接手时别误以为做了）：**没发行**——没重编 apk/exe/web，没动版本号，没 push 任何远端。
本轮**零 schema 改动**，所以按 §八 的发版账目它不欠「apk+exe 同发」；但 R26~R44 攒的产物债还在（见 §六-18）。

---

`;
patchDoc('灶记-交接文档.md', [{
  anchor: '## 六、下一步（按优先级，可直接照着做）',
  mode: 'before',
  text: r46,
  assert: '### R46 · 2026-09-29',
}]);

/* ───────── 3. 交接文档 §七：本轮新增的坑（独立子表，不动别人的表） ───────── */
const pits = `### 7.9 R46 新增的坑（这一轮真实踩到的，每条都红过）

| 坑 | 实况与结论 |
|---|---|
| ★★ **弹层要读 store，树必须把 \`StoreScope\` 挂在 \`MaterialApp\` 之上** | 详情页的热量编辑弹层是 \`showModalBottomSheet\` 推的路由——它挂在 navigator 下面，**不在页面子树里**。测试树写成 \`MaterialApp(home: StoreScope(...))\` 时弹层内 \`StoreScope.of(context)\` 拿到 null，表现是「弹层一打开就崩」而不是「查不到数据」。定式：**StoreScope/SyncScope 在 MaterialApp 外面**，本文件所有页面测试照此写 |
| ★★ **空库首启会灌 9 道示例菜，测试菜名撞上它就是「同一行出现两次」** | \`RecipeStore.ready()\` 在空库时插示例数据（番茄炒蛋 / 麻婆豆腐 / 红烧肉…）。用示例名做列表断言，\`find.text\` 稳定命中 2 个，看起来像「渲染重复」的产品 bug。**测试菜名一律带「测试」前缀**，或先确认 \`store.recipes.length\` |
| ★ **搜索框自己就是页面上第二段同样的文字** | 输入「测试戊」后 \`find.text('测试戊')\` 会连 \`TextField\` 的文本一起数到。列表断言要限范围：\`find.descendant(of: find.byType(SliverGrid), matching: find.text(...))\` |
| ★ **改了 UI 文案，得连「钉文案」的测试一起改** | 搜索 placeholder 一改，\`recipe_flow_test.dart\` 两处「主页结构与高保真一致」立刻红（它把旧文案原样钉着）。这类测试是资产不是累赘——红得正好，说明**原型/实现/测试三方必须同时改**，漏一个就是漂移 |
| ★ **状态页清单是手写的，会宣传不存在的能力** | \`/api/ai/{feature}\` 从来没注册过，清单里挂了半年；R44 的 7 条真接口反倒一条没登记。修法不是「记得改」，是 \`endpoint_registry_r46_test.dart\` 用**解析 \`server.dart\` 路由注册**的方式双向比对。别改成「打请求看状态码」：路由没注册回 404、业务「记录不存在」也回 404，**状态码分不开这两件事** |
| ★ **「下一轮接入」这类文案是定时炸弹** | \`ai_settings_page.dart\` 写着推荐「下一轮接入」，实际 R31 就接进厨房页了；\`calendar_page.dart\` 头注说「刻意没有第三种点」，v7 之后第三种点早就在做。文案过期没人报错，**只有用户会当成事实**——本轮把三处清掉，并在计划书 §二十二把「清过时文案」列为快赢固定项 |
| ★ **归一化比对要连占位符写法一起吃掉** | 路由写 \`/api/media/<sha>\`、清单写 \`/api/media/{sha256}?w=640\|1280\`。比对前统一 \`split('?')[0]\` 再把 \`<...>\`/\`{...}\` 都换成 \`*\`，否则清单一共 30 条要人工对齐 3 条 |
| ★ **\`JSON.stringify\` 写进 Dart 源码会踩 \`prefer_single_quotes\`** | 脚本生成 \`kEndpoints\` 条目时用双引号，analyze 立刻 30 条 info。**生成 Dart 字面量就手写单引号**，或者生成后跑一次区间内的引号归一（\`tool/server_endpoints_r46_fix.cjs\`，只碰新区间那一串行） |

---

`;
patchDoc('灶记-交接文档.md', [{
  anchor: '## 八、项目约定（改代码前请先读这一节）',
  mode: 'before',
  text: pits,
  assert: '### 7.9 R46 新增的坑',
}]);

fs.writeFileSync(path.join(snapDir, 'r46_doc_patch_note.txt'), log.join('\n'));
console.log(log.join('\n'));
