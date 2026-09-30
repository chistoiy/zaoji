// R47 第六段 · 原型同步（FR-SET-01 + FR-PLAN-09「开饭前投待办」）。
//
// UI 铁律：先改原型，再动实现。原型里那一行开关与就地档位从第四段就在（设计意图的规格），
// 这一遍补的是「投什么」——今天哪一餐会被投、投出去的摘要长什么样。
// 为什么要在设置页就地显示：否则这枚开关又变成「能打开但什么都不发生」的控件，
// 而那正是本轮查漏补缺在清的东西。
//
// 用法：node tool/proto_meal_r47.cjs
// 前置快照：dist/zaoji-prototype_before_r47meal.html（本脚本会校验它存在）
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const TARGET = path.join(ROOT, 'zaoji-prototype.html');
const SNAP = path.join(ROOT, 'dist', 'zaoji-prototype_before_r47meal.html');

const before = fs.readFileSync(TARGET, 'utf8');
if (!fs.existsSync(SNAP)) {
  console.error('✘ 先拍快照（cp zaoji-prototype.html dist/zaoji-prototype_before_r47meal.html）再跑');
  process.exit(1);
}
console.log('✔ 前置快照在：dist/zaoji-prototype_before_r47meal.html');

// ★ 行尾跟随目标文件（记过的坑：LF 锚在 CRLF 文件里一条都命不中，
//   而「锚没命中就退出」至少比假成功好——脚本自己报告才看得见）。
const EOL = before.includes('\r\n') ? '\r\n' : '\n';
const j = (s) => s.replace(/\n/g, EOL);

let out = before;
let order = 0;
const edit = (label, from0, to0) => {
  order++;
  const from = j(from0), to = j(to0);
  const n = out.split(from).length - 1;
  if (n !== 1) {
    console.error(`✘ [${order}] ${label}：锚命中 ${n} 次（要的是 1 次），一个字节都不改`);
    process.exit(1);
  }
  out = out.replace(from, to);
  console.log(`✔ [${order}] ${label}`);
};

// ── 1. CSS：档位下面那一列就地状态 ───────────────────────────────
edit('加 .meal-todo 样式',
  ".lead-chip.is-on{border-color:var(--accent);background:var(--accent-softer);color:var(--accent-deep);font-weight:600}\n",
  ".lead-chip.is-on{border-color:var(--accent);background:var(--accent-softer);color:var(--accent-deep);font-weight:600}\n" +
  "/* R47 第六段：今天会投给谁、投多长，就地列在档位下面（不藏弹层、不写教学文案） */\n" +
  ".meal-todo{display:flex;flex-direction:column;gap:5px;margin:-2px 0 12px}\n" +
  ".meal-todo-row{font-size:12.5px;color:var(--ink-2);line-height:1.6}\n" +
  ".meal-todo-row.is-empty{color:var(--muted)}\n");

// ── 2. 判定与摘要两个纯函数（设置页与走查共用同一份算法）────────────
edit('加 mealTodoTargets / mealDigest',
  "/* ─────────── 备菜 / 待办 ─────────── */",
  "/* R47 第六段 · 开饭前投待办（FR-SET-01 + FR-PLAN-09）的口径收在这两个函数里。\n" +
  "   「我的」页那一行与走查脚本吃同一份算法——两处各写一遍必然漂成两种说法\n" +
  "   （§7.10：卡片与通知共用口径靠的是抽纯函数，不是抄文案）。\n" +
  "   能被投的餐次 = 今天 + 定了开饭时间；摘要 = 菜数 / 备菜样数（同名归并）/ 步骤数。 */\n" +
  "function mealTodoTargets(menus) {\n" +
  "  return (menus || MENUS).filter(function (m) { return m.isToday && m.time; });\n" +
  "}\n" +
  "function mealDigest(m) {\n" +
  "  const ds = (m.dishes || []).map(function (id) { return R_MAP[id]; }).filter(Boolean);\n" +
  "  const names = {};\n" +
  "  ds.forEach(function (r) { (r.ings || []).forEach(function (i) { names[i.n] = 1; }); });\n" +
  "  return {\n" +
  "    dishes: ds.length,\n" +
  "    ingredients: Object.keys(names).length,\n" +
  "    steps: ds.reduce(function (a, r) { return a + (r.steps || []).length; }, 0),\n" +
  "    names: ds.map(function (r) { return r.name; }),\n" +
  "  };\n" +
  "}\n" +
  "\n" +
  "/* ─────────── 备菜 / 待办 ─────────── */");

// ── 3. 「我的」页那一行：摘掉一处游离的未闭合 .row，并把摘要列出来 ──
// 原第 4495 行是第四段那次脚本改写留下的残句：它先开了一个 `<div class="row">` 却没闭合，
// 整个后面的行都被 HTML 解析器塞进这个空 row 里。走查当时只断言了「chip 有 6 个」，
// 没断言层级，所以它一直没响——这次一并修掉，并让走查钉住「这一行是 .list 的直接子元素」。
edit('重写开饭前提醒那一块（含游离 row 的修复）',
  "      '<div class=\"row\"><span class=\"row-ico\">' + ic('bell', 18) + '</span>' +\n" +
  "      (function () {\n" +
  "        var leadLabel = function (m) {\n" +
  "          return m < 60 ? (m + ' 分钟') : ((m / 60) % 1 === 0 ? (m / 60) + ' 小时' : (m / 60).toFixed(1) + ' 小时');\n" +
  "        };\n" +
  "        var steps = [30, 45, 60, 90, 120, 180];\n",
  "      (function () {\n" +
  "        var leadLabel = function (m) {\n" +
  "          return m < 60 ? (m + ' 分钟') : ((m / 60) % 1 === 0 ? (m / 60) + ' 小时' : (m / 60).toFixed(1) + ' 小时');\n" +
  "        };\n" +
  "        var steps = [30, 45, 60, 90, 120, 180];\n" +
  "        var todoTargets = mealTodoTargets();\n");

edit('档位下面列今日投递摘要',
  "            ? '<div class=\"px\"><div class=\"lead-row\">' + steps.map(function (m) {\n" +
  "                return '<button type=\"button\" class=\"lead-chip' + (S.prefs.mealLead === m ? ' is-on' : '') + '\" data-act=\"lead-pick\" data-min=\"' + m + '\" aria-pressed=\"' + (S.prefs.mealLead === m) + '\">' + leadLabel(m) + '</button>';\n" +
  "              }).join('') + '</div></div>'\n",
  "            ? '<div class=\"px\"><div class=\"lead-row\">' + steps.map(function (m) {\n" +
  "                return '<button type=\"button\" class=\"lead-chip' + (S.prefs.mealLead === m ? ' is-on' : '') + '\" data-act=\"lead-pick\" data-min=\"' + m + '\" aria-pressed=\"' + (S.prefs.mealLead === m) + '\">' + leadLabel(m) + '</button>';\n" +
  "              }).join('') + '</div><div class=\"meal-todo\">' +\n" +
  "              (todoTargets.length\n" +
  "                ? todoTargets.map(function (m) {\n" +
  "                    var d = mealDigest(m);\n" +
  "                    return '<div class=\"meal-todo-row' + (d.dishes ? '' : ' is-empty') + '\" data-menu=\"' + m.id + '\">' +\n" +
  "                      esc(m.time + ' ' + m.meal) + ' · ' +\n" +
  "                      (d.dishes\n" +
  "                        ? (d.dishes + ' 道菜 · 备菜 ' + d.ingredients + ' 样 · 步骤 ' + d.steps + ' 步')\n" +
  "                        : '还没排菜') + '</div>';\n" +
  "                  }).join('')\n" +
  "                : '<div class=\"meal-todo-row is-empty\">今天没有定了开饭时间的餐次</div>') +\n" +
  "              '</div></div>'\n");

// ── 4. 走查出口：期望值要从数据现算，所以把数据与算法一起交出去 ────
edit('__zaoji 暴露 MENUS 与两个纯函数',
  "  PANTRY: PANTRY, renderScreen: renderScreen,\n",
  "  PANTRY: PANTRY, renderScreen: renderScreen,\n" +
  "  // R47 第六段：投待办的判定与摘要要能被走查「按同一份数据算期望」与「造空数据」，\n" +
  "  // 拿 DOM 读数反推 DOM 是假绿，所以交出去的是数据本体和算法，不是渲染结果。\n" +
  "  MENUS: MENUS, mealTodoTargets: mealTodoTargets, mealDigest: mealDigest,\n");

// ── 体积护栏（本轮改的都是小段，涨太多说明重复插入了）──────────────
const growth = out.length - before.length;
if (growth < 600 || growth > 4000) {
  console.error('✘ 体积变化异常：' + growth + ' 字节（预期 +600 ~ +4000），不落盘');
  process.exit(1);
}
if (out.includes(j(
  "      '<div class=\"row\"><span class=\"row-ico\">' + ic('bell', 18) + '</span>' +\n" +
  "      (function () {\n"))) {
  console.error('✘ 游离的未闭合 .row 还在');
  process.exit(1);
}
fs.writeFileSync(TARGET, out);
console.log(`✔ 已落盘（+${growth} 字节，${out.split('\n').length} 行）`);
