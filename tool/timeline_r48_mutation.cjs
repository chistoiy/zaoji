// R48 · 时间线的反向验证：摘掉七条**决策**，看测试是不是真的红。
//
// 挑这七刀的理由（§7.10：摘算术谁都会红，摘决策才验得到口径）：
//   serveAsTime —— 「菜单事件没有创建时刻」。最容易犯的混用就是把 `serve_at`（开饭时间）
//                  当成创建时刻填进去 —— 那一行会凭空多出一个钟点，而它说的是"几点吃饭"。
//   guessDay    —— 「created_at 为空的老行不出现」。改成"拿今天顶上"，
//                  升级那天所有老菜都会变成"今天新学了一道"，日历与时间线一起多假记录。
//   nthInWindow —— 「第 N 次按该菜全部会话排名」。只数窗口内的话，
//                  翻页时同一趟的"第几次"会跟着变，那是假账。
//   noFilter    —— 「分段过滤器真的筛」。摘了它按钮还在、条数不变，正是本轮在原型上刚修掉的病。
//   clockFirst  —— 「无时刻的那条落在那天最后」。反过来就变成"排最前"，
//                  读起来像那件事发生在一天开始之前。
//   durNoHours  —— 补正刀（真机量到的）：挂了一夜的会话写成「966 分钟」数字是真的但读不动。
//                  摘掉"≥60 转小时"，两屏（时间线与日历）那把共用的尺就退化成分钟堆。
//   earlierNoFeedback —— 补正刀：点「看更早」不给任何读数 = 用户眼里"这按钮没反应"。
//                  摘掉那行覆盖读数，翻页这条交互就没有任何可见反馈了。
//
// 用法：node tool/timeline_r48_mutation.cjs [serveAsTime|guessDay|nthInWindow|noFilter|clockFirst|durNoHours|earlierNoFeedback|restore]
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const SNAPDIR = path.join(ROOT, 'dist');
const STORE = path.join(ROOT, 'app', 'lib', 'data', 'recipe_store.dart');
const SHARED = path.join(ROOT, 'shared', 'lib', 'src', 'timeline.dart');
const PAGE = path.join(ROOT, 'app', 'lib', 'ui', 'timeline_page.dart');

const MUTS = {
  serveAsTime: {
    file: STORE,
    snap: path.join(SNAPDIR, 'recipe_store_pristine_r48.dart'),
    mustKeep: ['timelineEvents', 'timelineDayOf', 'rankRows'],
    from: "        // ★ 没有时刻：菜单表只有\"哪一天\"，time 留空 → UI 写「全天」\n" +
          "        kind: TimelineKind.menu,",
    to: "        // ★ 变异：把开饭时间当成创建时刻填进去（最常见的那次混用）\n" +
          "        time: m.serveAt,\n" +
          "        kind: TimelineKind.menu,",
    pkg: 'app',
    test: 'test/timeline_r48_test.dart',
    name: '菜单事件没有创建时刻',
    expect: '空串 = 没有这个事实',
  },
  guessDay: {
    file: STORE,
    snap: path.join(SNAPDIR, 'recipe_store_pristine_r48.dart'),
    mustKeep: ['timelineEvents', 'timelineDayOf', 'rankRows'],
    from: "      final day = timelineDayOf(r.createdAt);\n" +
          "      if (day == null || day.compareTo(fromDay) < 0 || day.compareTo(toDay) >= 0) {\n" +
          "        continue; // ★ v7 之前入册的老菜：不知道哪天，不出现\n" +
          "      }",
    to: "      // ★ 变异：不知道哪天就「拿今天顶上」——升级那天所有老菜都变成今天新学的\n" +
          "      final day = timelineDayOf(r.createdAt) ?? timelineDayOf(DateTime.now().toIso8601String());\n" +
          "      if (day == null || day.compareTo(fromDay) < 0 || day.compareTo(toDay) >= 0) {\n" +
          "        continue;\n" +
          "      }",
    pkg: 'app',
    test: 'test/timeline_r48_test.dart',
    name: '老菜不进「菜品」',
    expect: 'v7 之前入册：不知道哪天，宁可不出现',
  },
  nthInWindow: {
    file: STORE,
    snap: path.join(SNAPDIR, 'recipe_store_pristine_r48.dart'),
    mustKeep: ['timelineEvents', 'timelineDayOf', 'rankRows'],
    from: "    for (final r in rankRows) {\n" +
          "      final rid = '${r.data['recipe_id']}';",
    to: "    // ★ 变异：只按窗口内的会话排名 → 翻页时同一趟的「第 N 次」会跟着变\n" +
          "    for (final r in rows) {\n" +
          "      final rid = '${r.data['recipe_id']}';",
    pkg: 'app',
    test: 'test/timeline_r48_test.dart',
    name: '跨窗口稳定',
    expect: '排名要吃全量',
  },
  noFilter: {
    file: SHARED,
    snap: path.join(SNAPDIR, 'timeline_pristine_r48.dart'),
    mustKeep: ['timelineSorted', 'timelineFiltered', 'timelineMarks'],
    from: "  if (kind == null) return timelineSorted(items);\n" +
          "  return timelineSorted(items.where((e) => e.kind == kind).toList());",
    to: "  // ★ 变异：忽略 kind —— 按钮还在、条数不变，正是「只切按下态」那种装饰\n" +
          "  return timelineSorted(items);",
    pkg: 'shared',
    test: 'test/timeline_test.dart',
    name: '每种过滤都必须真的改条数',
    expect: '筛完还全量等于没筛',
  },
  clockFirst: {
    file: SHARED,
    snap: path.join(SNAPDIR, 'timeline_pristine_r48.dart'),
    mustKeep: ['timelineSorted', 'timelineFiltered', 'timelineMarks'],
    from: "    if (at.isEmpty != bt.isEmpty) return at.isEmpty ? 1 : -1; // 无时刻排那天最后",
    to: "    if (at.isEmpty != bt.isEmpty) return at.isEmpty ? -1 : 1; // ★ 变异：无时刻的跑到那天最前",
    pkg: 'shared',
    test: 'test/timeline_test.dart',
    name: '无时刻的那条排在当天最后',
    expect: '当成 00:00 就会跑到当天最前',
  },
  durNoHours: {
    file: SHARED,
    snap: path.join(SNAPDIR, 'timeline_pristine_r48.dart'),
    mustKeep: ['timelineSorted', 'timelineFiltered', 'timelineMarks', 'timelineDurationLabel'],
    from: "  if (m < 60) return '$m 分钟';",
    to: "  if (m >= 0) return '$m 分钟'; // ★ 变异：过一小时也不转，966 分钟照写",
    pkg: 'shared',
    test: 'test/timeline_test.dart',
    name: '966 分钟那趟',
    expect: '≥60 要转成小时（两屏一把尺）',
  },
  earlierNoFeedback: {
    file: PAGE,
    snap: path.join(SNAPDIR, 'timeline_page_pristine_r48b.dart'),
    mustKeep: ['_earlier', 'tl-span', '_noEarlier', '_pending'],
    from: "        if (_pages > 1)\n          Padding(",
    to: "        if (_pages > 99) // ★ 变异：翻页不给任何读数——用户眼里就是「点了没反应」\n          Padding(",
    pkg: 'app',
    test: 'test/timeline_r48_test.dart',
    name: '点了要有反应',
    expect: '翻页必须有可见读数',
  },
};

const guard = (label, cond, extra) => {
  if (!cond) {
    console.error('✘ ' + label + (extra ? '  [' + extra + ']' : ''));
    process.exit(1);
  }
  console.log('✔ ' + label);
};

function must(label, cond, extra) {
  if (!cond) throw new Error(label + (extra ? '  [' + extra + ']' : ''));
  console.log('✔ ' + label);
}

const join = (s, crlf) => (crlf ? s.replace(/\n/g, '\r\n') : s);

function applyMutation(m) {
  const src = fs.readFileSync(m.file, 'utf8');
  if (!fs.existsSync(m.snap)) {
    fs.writeFileSync(m.snap, src);
    console.log('✔ 改前快照已存 ' + path.relative(ROOT, m.snap));
  }
  const snap = fs.readFileSync(m.snap, 'utf8');
  const crlf = src.includes('\r\n');
  const from = join(m.from, crlf), to = join(m.to, crlf);
  must('快照里是原逻辑', snap.includes(from), m.name);
  must('锚唯一命中', src.split(from).length - 1 === 1, 'n=' + (src.split(from).length - 1));
  const out = src.replace(from, to);
  fs.writeFileSync(m.file, out);
  must('变异已落盘', fs.readFileSync(m.file, 'utf8').includes(to));
}

function restore(m) {
  guard('快照在', fs.existsSync(m.snap), path.relative(ROOT, m.snap));
  const snap = fs.readFileSync(m.snap, 'utf8');
  const missing = (m.mustKeep || []).filter((k) => !snap.includes(k));
  guard('快照不是过期版本（含全部 mustKeep 标记）', missing.length === 0,
    '快照里缺：' + missing.join(' / ') + ' → 删掉 dist 里那份快照重跑');
  fs.writeFileSync(m.file, snap);
  guard('装回后与快照逐字节一致', fs.readFileSync(m.file).equals(fs.readFileSync(m.snap)),
    path.relative(ROOT, m.file));
}

function runCase(m) {
  const env = { ...process.env };
  for (const k of ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy']) {
    delete env[k];
  }
  env.no_proxy = 'localhost,127.0.0.1,::1';
  env.NO_PROXY = env.no_proxy;
  const r = spawnSync('flutter', ['test', m.test, '--plain-name', m.name], {
    cwd: path.join(ROOT, m.pkg), env, encoding: 'utf8',
    shell: process.platform === 'win32',
  });
  const out = (r.stdout || '') + (r.stderr || '');
  // ★ 两道自证（本会话真撞到过一次假红）：
  //   ① `--plain-name` 匹配不到任何用例时，flutter test 也是非零退出——
  //      那是"没跑"，不是"跑红了"，当证据用就是把工装当结论。
  //   ② 红的必须是**那一条**：看 `[E]` 行里有没有用例名，比看 reason 文本稳
  //      （失败消息会被折行，字符串匹配会假阴）。
  const ran = /\+\s*\d+/.test(out);
  const failedLines = out.split(/\r?\n/).filter((l) => l.includes('[E]')).join('\n');
  return {
    ran,
    red: r.status !== 0,
    hitExpected: ran && failedLines.includes(m.name),
    tail: out.split(/\r?\n/).filter((l) => /^\d\d:\d\d/.test(l)).slice(-3).join(' | '),
  };
}

const mode = process.argv[2];
if (mode === 'restore') {
  const seen = new Set();
  for (const m of Object.values(MUTS)) {
    if (seen.has(m.file)) continue;
    seen.add(m.file);
    if (!fs.existsSync(m.snap)) {
      console.log('· ' + path.relative(ROOT, m.file) + ' 没有快照（本轮没动过），跳过');
      continue;
    }
    restore(m);
  }
  console.log('✔ 全部装回');
  process.exit(0);
}

const keys = mode ? [mode] : Object.keys(MUTS);
guard('模式合法', keys.every((k) => MUTS[k]), '可选：' + Object.keys(MUTS).join(' / ') + ' / restore');

let bad = 0;
const check = (label, cond, extra) => {
  if (cond) { console.log('✔ ' + label); } else { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); bad++; }
};
for (const k of keys) {
  const m = MUTS[k];
  console.log('\n—— 变异 ' + k + '（' + m.pkg + '，期望红在：' + m.expect + '）');
  try {
    applyMutation(m);
    const r = runCase(m);
    check('这一筛真的有用例在跑（不是 "No tests ran" 的假红）', r.ran, r.tail);
    check('摘掉这条决策后测试真的红', r.red, r.tail);
    check('红的就是这一条（看 [E] 行的用例名）', r.hitExpected);
  } catch (e) {
    console.error('✘ 变异 ' + k + ' 没做成：' + e.message);
    bad++;
  } finally {
    restore(m);
  }
}
console.log('\n' + (bad ? '有 ' + bad + ' 处没验到（用例没真的钉住这条决策）' : '全部验到：摘决策必红、装回必绿'));
process.exit(bad ? 1 : 0);
