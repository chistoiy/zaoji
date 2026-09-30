// R48（FR-LOG-01 时间线）· 原型先行。
//
// 三件事一次改到位，都是"实现要照着抄"的口径：
//  ① 事件不再手写一份 EVENTS —— 从三份数据现推（COOK_LOG / MENUS / RECIPES.created），
//     与 App 的三张表一一对应；日历的点也改成同一份派生，
//     ★ 消掉「时间线一份、日历一份」这两份要各维护的说法（§7.10 记过这类账）。
//  ② 菜单事件**没有创建时刻**这个事实（menu 表只有 day/meal/serve_at），
//     所以那一行的时间位写「全天」，不再画一个 09:12 那种编出来的钟点。
//     同理 RECIPES 只给两道菜补 created（= v7 之后入册的），其余没这个事实 → 不出现、不猜。
//  ③ 分段过滤器（全部/做菜/菜单/菜品）原来是空转（只切 aria-pressed 不筛数据）——
//     按「控件点了必须有看得见的变化」，改成真的筛，并给空结果留空态。
//
// 用法：node tool/proto_timeline_r48.cjs [--check]
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const FILE = path.join(ROOT, 'zaoji-prototype.html');
const SNAP = path.join(ROOT, 'dist', 'zaoji-prototype_before_r48timeline.html');
const raw = fs.readFileSync(FILE, 'utf8');
const eol = raw.includes('\r\n') ? '\r\n' : '\n';
const j = (s) => s.split('\n').map((x) => x.replace(/\r$/, '')).join(eol);

const EDITS = [
  {
    name: 'COOK_LOG 补完成时刻与耗时（App 侧 = finished_at + started→finished）',
    from: `const COOK_LOG = {
  r1: [['2026-09-14','晚餐'],['2026-09-07','晚餐'],['2026-08-30','午餐'],['2026-08-21','晚餐'],['2026-08-12','午餐']],
  r2: [['2026-09-11','周末晚餐'],['2026-08-16','宴客'],['2026-07-28','周末晚餐']],
  r3: [['2026-09-15','晚餐'],['2026-08-30','宴客'],['2026-08-09','晚餐']],
  r4: [['2026-09-08','晚餐'],['2026-08-24','晚餐'],['2026-08-05','午餐']],
  r5: [['2026-09-16','夜宵'],['2026-09-02','夜宵'],['2026-08-19','夜宵']],
  r6: [['2026-09-17','夜宵'],['2026-09-10','夜宵'],['2026-09-03','晚餐'],['2026-08-27','夜宵']],
  r7: [['2026-09-06','周末'],['2026-08-02','周末']],
  r8: [['2026-09-15','晚餐'],['2026-09-08','晚餐'],['2026-08-30','午餐']]
};`,
    to: `/* R48：每条 = [日期, 那顿的名字, 完成时刻 HH:MM, 实际耗时分钟]。
   后两项是**给时间线用的**（App 侧对应 cook_session.finished_at 与 started→finished 的差）。
   ★ 详情页那处只读 l[0]/l[1]，加字段不动它。 */
const COOK_LOG = {
  r1: [['2026-09-14','晚餐','19:20',12],['2026-09-07','晚餐','18:50',13],['2026-08-30','午餐','12:30',11],['2026-08-21','晚餐','19:05',14],['2026-08-12','午餐','12:10',10]],
  r2: [['2026-09-11','周末晚餐','19:40',95],['2026-08-16','宴客','18:20',110],['2026-07-28','周末晚餐','19:00',88]],
  r3: [['2026-09-15','晚餐','18:45',22],['2026-08-30','宴客','13:00',26],['2026-08-09','晚餐','19:10',24]],
  r4: [['2026-09-08','晚餐','18:30',90],['2026-08-24','晚餐','19:15',86],['2026-08-05','午餐','12:40',80]],
  r5: [['2026-09-16','夜宵','22:40',62],['2026-09-02','夜宵','23:05',58],['2026-08-19','夜宵','22:20',60]],
  r6: [['2026-09-17','夜宵','21:30',14],['2026-09-10','夜宵','21:15',13],['2026-09-03','晚餐','18:55',15],['2026-08-27','夜宵','22:00',12]],
  r7: [['2026-09-06','周末','12:20',45],['2026-08-02','周末','12:00',48]],
  r8: [['2026-09-15','晚餐','18:47',7],['2026-09-08','晚餐','18:32',6],['2026-08-30','午餐','12:32',8]]
};`,
  },
  {
    name: 'r3 补 created（= v7 之后入册的菜才有）',
    from: "    diff:2, selfTime:25, autoTime:22, cooked:4, lastCook:'2026-09-15',\n    fav:false,",
    to: "    diff:2, selfTime:25, autoTime:22, cooked:4, lastCook:'2026-09-15',\n    created:'2026-09-16T20:15',   // R48：入册时刻（App = recipe.created_at；★ 老菜没这字段）\n    fav:false,",
  },
  {
    name: 'r8 补 created',
    from: "    diff:1, selfTime:8, autoTime:7, cooked:15, lastCook:'2026-09-15',\n    fav:false,",
    to: "    diff:1, selfTime:8, autoTime:7, cooked:15, lastCook:'2026-09-15',\n    created:'2026-09-08T09:40',    // R48：入册时刻（App = recipe.created_at）\n    fav:false,",
  },
  {
    name: 'EVENTS 手写表 → timelineEvents() 三份数据现推',
    from: `/* ─────────── 时间线事件 ─────────── */
const EVENTS = [
  { date:'2026-09-17', time:'19:05', kind:'cook', title:'做了 <b>葱油拌面</b>', desc:'夜宵 · 实际耗时 14 分钟 · 第 18 次' },
  { date:'2026-09-17', time:'09:12', kind:'menu', title:'新建菜单 <b>今天 · 晚餐</b>', desc:'3 道菜：番茄炒蛋 / 蒜蓉粉丝蒸虾 / 蚝油生菜' },
  { date:'2026-09-16', time:'22:40', kind:'cook', title:'做了 <b>银耳莲子羹</b>', desc:'夜宵 · 实际耗时 62 分钟 · 第 6 次' },
  { date:'2026-09-16', time:'20:15', kind:'recipe', title:'新增菜品 <b>蒜蓉粉丝蒸虾</b>', desc:'补充了 4 个步骤、6 张成品图' },
  { date:'2026-09-15', time:'18:52', kind:'cook', title:'做了 <b>蒜蓉粉丝蒸虾 + 蚝油生菜</b>', desc:'晚餐 · 实际耗时 22 / 7 分钟' },
  { date:'2026-09-14', time:'19:20', kind:'cook', title:'做了 <b>番茄炒蛋</b>', desc:'晚餐 · 实际耗时 12 分钟 · 第 23 次' },
  { date:'2026-09-14', time:'08:00', kind:'menu', title:'新建菜单 <b>周六 · 午餐</b>', desc:'3 道菜，已生成备菜清单 9 项' }
];`,
    to: `/* ─────────── R48 · 时间线（FR-LOG-01）：事件从三份数据现推 ───────────
   和 App 的取数一一对应，**一份口径两处吃**（日历的点与时间线的行同出一源）：
     · cook   ← COOK_LOG            （App：cook_session.finished_at，有时刻、有耗时）
     · menu   ← MENUS               （App：menu.day —— ★ 只有"哪一天"这个事实，
                                       menu 表没有创建时刻列，所以行上给「全天」而不是编一个 09:12）
     · recipe ← RECIPES[].created   （App：recipe.created_at，schema v7 起才有；
                                       ★ 没这个字段的老菜就是"不知道哪天入的册"——
                                       不出现，也不拿 updated_at / ULID 前缀猜一个日子） */
const TODAY = '2026-09-17';   // 原型的演示"今天"（与 S.calSel 同一天）

function timelineEvents(kind) {
  const out = [];
  Object.keys(COOK_LOG).forEach(function (rid) {
    const r = R_MAP[rid], logs = COOK_LOG[rid];
    if (!r) return;
    logs.forEach(function (l, i) {
      out.push({
        date: l[0], time: l[2] || '', kind: 'cook', rid: rid,
        title: '做了 <b>' + esc(r.name) + '</b>',
        desc: l[1] + ' · 实际耗时 ' + l[3] + ' 分钟 · 第 ' + (logs.length - i) + ' 次'
      });
    });
  });
  MENUS.forEach(function (m) {
    out.push({
      date: m.date, time: '', kind: 'menu', menuId: m.id,
      title: '排了菜单 <b>' + esc(m.meal) + '</b>',
      desc: m.time + ' 开饭 · ' + m.dishes.length + ' 道菜'
    });
  });
  RECIPES.forEach(function (r) {
    if (!r.created) return;              // ★ 不知道入册时刻 = 不出现，不猜
    out.push({
      date: r.created.slice(0, 10), time: r.created.slice(11, 16), kind: 'recipe', rid: r.id,
      title: '新增菜品 <b>' + esc(r.name) + '</b>',
      desc: r.steps ? ('入册时带 ' + r.steps.length + ' 个步骤') : '入册'
    });
  });
  const k = kind || 'all';
  return out.filter(function (e) { return k === 'all' || e.kind === k; })
    .sort(function (a, b) {
      if (a.date !== b.date) return a.date < b.date ? 1 : -1;   // 日期倒序
      const at = a.time || '00:00', bt = b.time || '00:00';      // 同日按时刻倒序；无时刻的落在那天最后
      return at < bt ? 1 : (at > bt ? -1 : 0);
    });
}

/* 日历的点由同一份事件派生（原来这里另手写一份 CAL_MARKS，两屏各维护一份迟早对不上）。 */
function calMarksFromEvents() {
  const m = {};
  timelineEvents('all').forEach(function (e) {
    if (!m[e.date]) m[e.date] = [];
    if (m[e.date].indexOf(e.kind) < 0) m[e.date].push(e.kind);
  });
  Object.keys(m).forEach(function (k) { m[k].sort(); });
  return m;
}`,
  },
  {
    name: 'CAL_MARKS 手写表 → 派生',
    from: `/* ─────────── 日历标记 ─────────── */
const CAL_MARKS = {
  '2026-08-24':['cook'], '2026-08-27':['cook'], '2026-08-30':['cook','menu'],
  '2026-09-02':['cook'], '2026-09-03':['cook'], '2026-09-06':['cook','menu'],
  '2026-09-07':['cook'], '2026-09-08':['cook','menu','recipe'], '2026-09-10':['cook'],
  '2026-09-11':['cook'], '2026-09-14':['cook','menu'], '2026-09-15':['cook'],
  '2026-09-16':['cook','recipe'], '2026-09-17':['cook','menu'],
  '2026-09-19':['menu'], '2026-09-20':['menu']
};`,
    to: `/* ─────────── 日历标记（R48 起改为派生） ───────────
   ★ 以前这里手写一份日期表，时间线又手写一份 EVENTS——两屏各维护一份，
   改一处忘一处是迟早的事；现在同出一源：日历画的点 == 时间线有的行。 */
const CAL_MARKS = calMarksFromEvents();`,
  },
  {
    name: 'S 加 tlKind（分段过滤器的状态）',
    from: "  calSel:'2026-09-17',",
    to: "  calSel:'2026-09-17',\n  tlKind:'all',          // R48：时间线的分段过滤器（all/cook/menu/recipe），是真的在筛",
  },
  {
    name: 'SCREENS.timeline 重写（派生 + 真筛 + 空态 + 「全天」）',
    from: `SCREENS.timeline = function () {
  const kinds = { cook:'做菜', menu:'菜单', recipe:'菜品' };
  let cur = '', out = '';
  EVENTS.forEach(function (e) {
    if (e.date !== cur) {
      cur = e.date;
      out += '<div class="sec-head"><span class="sec-num">' + e.date.slice(5).replace('-', '/') + '</span>' +
        '<span class="sec-title">' + (e.date === '2026-09-17' ? '今天' : '') + '</span></div>';
    }
    out += '<div class="tl-item" data-kind="' + e.kind + '"><span class="tl-dot"></span>' +
      '<div style="display:flex;align-items:center;gap:8px">' +
        '<span class="tl-time" style="margin-left:0">' + e.time + '</span>' +
        '<span class="badge ' + (e.kind === 'cook' ? 'badge-err' : e.kind === 'menu' ? 'badge-idle' : 'badge-ok') + '">' + kinds[e.kind] + '</span></div>' +
      '<div class="tl-title">' + e.title + '</div><div class="tl-desc">' + e.desc + '</div></div>';
  });

  return '<div class="screen">' +
    appbar('时间线', '这台家里的灶，什么时候开过火', { act:'back' },
      '<button type="button" class="iconbtn" data-act="nav" data-screen="calendar" aria-label="日历">' + ic('calendar', 20) + '</button>') +
    '<div class="px" style="margin-bottom:6px"><div class="segmented">' +
      '<button type="button" class="seg" data-act="seg" aria-pressed="true">全部</button>' +
      '<button type="button" class="seg" data-act="seg" aria-pressed="false">做菜</button>' +
      '<button type="button" class="seg" data-act="seg" aria-pressed="false">菜单</button>' +
      '<button type="button" class="seg" data-act="seg" aria-pressed="false">菜品</button>' +
    '</div></div>' +
    '<div class="px"><div class="card pad-lg">' + out + '</div></div>' +
  '</div>';
};`,
    to: `SCREENS.timeline = function () {
  const kinds = { cook:'做菜', menu:'菜单', recipe:'菜品' };
  const list = timelineEvents(S.tlKind);
  let cur = '', out = '';
  list.forEach(function (e) {
    if (e.date !== cur) {
      cur = e.date;
      out += '<div class="sec-head" data-day="' + e.date + '"><span class="sec-num">' + e.date.slice(5).replace('-', '/') + '</span>' +
        '<span class="sec-title">' + (e.date === TODAY ? '今天' : '') + '</span></div>';
    }
    out += '<div class="tl-item" data-kind="' + e.kind + '" data-date="' + e.date + '"><span class="tl-dot"></span>' +
      '<div style="display:flex;align-items:center;gap:8px">' +
        // ★ 菜单事件没有"创建时刻"这个事实 → 时间位写「全天」，不编钟点
        '<span class="tl-time" style="margin-left:0">' + (e.time || '全天') + '</span>' +
        '<span class="badge ' + (e.kind === 'cook' ? 'badge-err' : e.kind === 'menu' ? 'badge-idle' : 'badge-ok') + '">' + kinds[e.kind] + '</span></div>' +
      '<div class="tl-title">' + e.title + '</div><div class="tl-desc">' + e.desc + '</div></div>';
  });

  const segs = [['all','全部'], ['cook','做菜'], ['menu','菜单'], ['recipe','菜品']];
  return '<div class="screen">' +
    appbar('时间线', '这台家里的灶，什么时候开过火', { act:'back' },
      '<button type="button" class="iconbtn" data-act="nav" data-screen="calendar" aria-label="日历">' + ic('calendar', 20) + '</button>') +
    '<div class="px" style="margin-bottom:6px"><div class="segmented" id="tlSeg">' +
      segs.map(function (s) {
        return '<button type="button" class="seg" data-act="tl-kind" data-kind="' + s[0] +
          '" aria-pressed="' + (S.tlKind === s[0]) + '">' + s[1] + '</button>';
      }).join('') +
    '</div></div>' +
    '<div class="px">' + (list.length
      ? '<div class="card pad-lg" id="tlList">' + out + '</div>'
      : '<div class="card pad" id="tlEmpty" style="text-align:center;color:var(--muted);font-size:12.5px;padding:28px 16px;line-height:1.8">这一类还没有记录<br>换个类型看看</div>') +
    '</div>' +
  '</div>';
};`,
  },
  {
    name: 'tl-kind 处理器（真筛；原 seg 只切按下态）',
    from: `  /* —— 分段控件 —— */
  if (act === 'seg') {`,
    to: `  /* —— 时间线分段过滤：切的是数据源，不是按钮样式 —— */
  if (act === 'tl-kind') {
    S.tlKind = el.dataset.kind || 'all';
    renderScreen(true);
    return;
  }

  /* —— 分段控件 —— */
  if (act === 'seg') {`,
  },
  {
    name: '自检桥导出（走查要按同一份数据算期望）',
    from: "  MENUS: MENUS, mealTodoTargets: mealTodoTargets, mealDigest: mealDigest,",
    to: "  MENUS: MENUS, mealTodoTargets: mealTodoTargets, mealDigest: mealDigest,\n  // R48：时间线的三份源数据与派生函数一起交出去——\n  // 走查的期望值必须从数据现算，拿 DOM 反推 DOM 是假绿。\n  COOK_LOG: COOK_LOG, RECIPES: RECIPES, timelineEvents: timelineEvents,\n  calMarksFromEvents: calMarksFromEvents, TODAY: TODAY,",
  },
];

const check = process.argv.includes('--check');
let out = raw, bad = 0;
for (const e of EDITS) {
  const from = j(e.from), to = j(e.to);
  const hits = out.split(from).length - 1;
  if (hits !== 1) {
    console.log(`[${e.name}] 命中 ${hits} 次（要求恰好 1）→ FAIL`);
    bad++;
    continue;
  }
  console.log(`[${e.name}] OK`);
  if (!check) out = out.replace(from, to);
}
if (bad) { console.log(`\n${bad} 处锚点没对上，未写盘。`); process.exit(1); }
if (check) { console.log('\n--check：全部命中，未写盘。'); process.exit(0); }

const grew = Buffer.byteLength(out) - Buffer.byteLength(raw);
if (grew < 1000) { console.log(`体积只变 ${grew} 字节，不像加了这些内容，未写盘。`); process.exit(1); }
if (!fs.existsSync(SNAP)) fs.writeFileSync(SNAP, raw, 'utf8');
fs.writeFileSync(FILE, out, 'utf8');

// 编码自检（上一轮 latin1 事故的教训：新插入中文后要确认这份还是干净 UTF-8）
const buf = fs.readFileSync(FILE);
let i = 0, illegal = 0;
while (i < buf.length) {
  const c = buf[i];
  const n = c < 0x80 ? 1 : (c & 0xE0) === 0xC0 ? 2 : (c & 0xF0) === 0xE0 ? 3 : (c & 0xF8) === 0xF0 ? 4 : 0;
  if (!n) { illegal++; i++; continue; }
  let ok = true;
  for (let k = 1; k < n; k++) if ((buf[i + k] & 0xC0) !== 0x80) { ok = false; break; }
  if (!ok) { illegal++; i++; continue; }
  i += n;
}
console.log(`写盘完成：+${grew} bytes（快照 dist/zaoji-prototype_before_r48timeline.html）`);
console.log(illegal === 0 ? 'UTF-8 合法性：干净' : `★ 非法 UTF-8 序列 ${illegal} 处！`);
