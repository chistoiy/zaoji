// R48 · 时间线原型走查（FR-LOG-01）。
// 期望值一律从 window.__zaoji 的三份源数据现算（COOK_LOG / MENUS / RECIPES），
// 拿 DOM 反推 DOM 是假绿——这条本仓库记过多次。
// 用法：node tool/proto_timeline_r48_walk.cjs
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const ROOT = path.resolve(__dirname, '..');
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 8793;
const OUT = path.join(ROOT, 'dist', 'r48timeline_previews');

const srv = http.createServer((req, res) => {
  const rel = decodeURIComponent(req.url.split('?')[0]);
  const abs = path.join(ROOT, rel === '/' ? '/zaoji-prototype.html' : rel);
  if (!abs.startsWith(ROOT) || !fs.existsSync(abs) || fs.statSync(abs).isDirectory()) {
    res.writeHead(404); res.end('nope'); return;
  }
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(fs.readFileSync(abs));
});

let fails = 0;
const ok = (name, cond, extra) => {
  console.log((cond ? '  PASS ' : '  FAIL ') + name + (extra ? '  [' + extra + ']' : ''));
  if (!cond) fails++;
};

(async () => {
  await new Promise((r) => srv.listen(PORT, '127.0.0.1', r));
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errs = [], net404 = [];
  page.on('console', (m) => {
    const t = m.text();
    if (m.type() === 'error' && !/Failed to load resource/.test(t)) errs.push(t);
  });
  page.on('response', (r) => { if (r.status() === 404) net404.push(r.url()); });

  let seq = 0;
  const go = async (tag) => {
    await page.goto(`http://127.0.0.1:${PORT}/zaoji-prototype.html?_r=${++seq}#screen=timeline`,
      { waitUntil: 'load' });
    await page.waitForTimeout(450);
    if (tag) await page.screenshot({ path: path.join(OUT, tag + '.png') });
  };
  // 从数据现算的期望（不读 DOM）
  const expectOf = (kind) => page.evaluate((kind) => {
    const z = window.__zaoji;
    const ev = z.timelineEvents(kind);
    const days = [...new Set(ev.map((e) => e.date))];
    return {
      n: ev.length, days: days,
      kinds: ev.map((e) => e.kind),
      times: ev.map((e) => e.time),
      withCreated: z.RECIPES.filter((r) => r.created).length,
      totalRecipes: z.RECIPES.length,
      today: z.TODAY,
    };
  }, kind);
  // DOM 实际渲染出来的（只作为"实际值"，不作为期望值）
  const domOf = () => page.evaluate(() => {
    const items = [...document.querySelectorAll('#tlList .tl-item')];
    return {
      n: items.length,
      kinds: items.map((i) => i.dataset.kind),
      dates: items.map((i) => i.dataset.date),
      timeTexts: items.map((i) => i.querySelector('.tl-time').textContent.trim()),
      heads: [...document.querySelectorAll('#tlList .sec-head')].map((h) => h.dataset.day),
      pressed: [...document.querySelectorAll('#tlSeg .seg')]
        .filter((b) => b.getAttribute('aria-pressed') === 'true')
        .map((b) => b.dataset.kind),
      empty: !!document.querySelector('#tlEmpty'),
      body: document.querySelector('.screen') ? document.querySelector('.screen').innerText : '',
    };
  });

  console.log('[1] 全部：行数与分组来自三份数据，不是手写表');
  await go('01_all');
  let exp = await expectOf('all');
  let dom = await domOf();
  ok(`条数 == timelineEvents('all')（${exp.n}）`, dom.n === exp.n, `dom=${dom.n}`);
  ok('类型序列一致（顺序也是判据：日期倒序、同日按时刻倒序）',
    JSON.stringify(dom.kinds) === JSON.stringify(exp.kinds),
    `dom=${dom.kinds.slice(0, 6)} exp=${exp.kinds.slice(0, 6)}`);
  // 同日内的顺序单独验一次：时刻必须从晚到早，且「全天」（无时刻）落在那天最后
  const byDay = {};
  dom.dates.forEach((d, i) => { (byDay[d] = byDay[d] || []).push(dom.timeTexts[i]); });
  const badDay = Object.entries(byDay).find(([d, ts]) => {
    const real = ts.filter((t) => t !== '全天');
    if (real.join() !== [...real].sort().reverse().join()) return true;      // 时刻没倒序
    return ts.slice(real.length).some((t) => t !== '全天');                   // 「全天」没排在最后
  });
  ok('同一天内：时刻倒序，「全天」的那条落在那天最后', badDay === undefined,
    badDay ? badDay[0] + ' → ' + badDay[1].join(',') : '');
  ok('日头序列 == 事件里出现过的日期（倒序、不重不漏）',
    JSON.stringify(dom.heads) === JSON.stringify([...new Set(exp.days)]),
    `heads=${dom.heads.slice(0, 5)} exp=${[...new Set(exp.days)].slice(0, 5)}`);
  ok('今天那一组标了「今天」', dom.body.includes('今天'), '');

  console.log('\n[2] ★ 菜单事件没有创建时刻 → 时间位是「全天」，不是编出来的钟点');
  const menuRows = dom.dates.map((d, i) => ({ d: d, k: dom.kinds[i], t: dom.timeTexts[i] }))
    .filter((r) => r.k === 'menu');
  ok('菜单行数 == MENUS.length', menuRows.length === (await page.evaluate(() => window.__zaoji.MENUS.length)),
    `menu=${menuRows.length}`);
  ok('每条菜单事件的时间位都写「全天」', menuRows.every((r) => r.t === '全天'),
    JSON.stringify(menuRows.map((r) => r.t)));
  ok('页面上找不到旧的手写钟点 09:12（那份 EVENTS 已撤）', !dom.body.includes('09:12'));

  console.log('\n[3] ★ 只有带 created 的菜才进「新增菜品」（老行不出现，也不猜日子）');
  const recipeRows = dom.kinds.filter((k) => k === 'recipe').length;
  ok(`新增菜品行数 == RECIPES 里有 created 的条数（${exp.withCreated}）`, recipeRows === exp.withCreated,
    `dom=${recipeRows}`);
  ok('确实存在"没 created 所以不出现"的菜（否则这条用例是空转）',
    exp.withCreated < exp.totalRecipes && exp.totalRecipes - exp.withCreated >= 6,
    `有 created ${exp.withCreated} / 共 ${exp.totalRecipes}`);

  console.log('\n[4] ★ 分段过滤器真的筛（原来只切 aria-pressed 是空转）');
  for (const kind of ['cook', 'menu', 'recipe']) {
    await page.click(`#tlSeg .seg[data-kind="${kind}"]`);
    await page.waitForTimeout(220);
    exp = await expectOf(kind);
    dom = await domOf();
    ok(`切「${kind}」后条数 == timelineEvents('${kind}')（${exp.n}）`,
      dom.n === exp.n, `dom=${dom.n}`);
    ok(`切「${kind}」后每一行都是这个类型`, dom.kinds.every((k) => k === kind),
      [...new Set(dom.kinds)].join(','));
    ok(`切「${kind}」后只有那颗是按下态`, dom.pressed.length === 1 && dom.pressed[0] === kind,
      dom.pressed.join(','));
  }
  await page.click('#tlSeg .seg[data-kind="all"]');
  await page.waitForTimeout(200);
  dom = await domOf();
  ok('切回「全部」条数回到全量', dom.n === (await expectOf('all')).n, `dom=${dom.n}`);
  await page.screenshot({ path: path.join(OUT, '04_filter_all.png') });

  console.log('\n[5] 空态：把某类数据清空后那一类真的没有行');
  await page.evaluate(() => { window.__zaoji.MENUS.length = 0; });
  await page.click('#tlSeg .seg[data-kind="menu"]');
  await page.waitForTimeout(250);
  dom = await domOf();
  ok('清空 MENUS 后「菜单」这一类为空', dom.n === 0, `dom=${dom.n}`);
  ok('空的时候出现空态块（不是留一张空卡）', dom.empty === true);
  ok('空态文案在（不写教学性说明，只说没有）', dom.body.includes('这一类还没有记录'));
  await page.screenshot({ path: path.join(OUT, '05_empty.png') });
  await go(null);   // 刷新还原演示数据

  console.log('\n[6] ★ 一份口径两处吃：日历画的点 == 时间线有的行');
  const cross = await page.evaluate(() => {
    const z = window.__zaoji;
    const evDays = [...new Set(z.timelineEvents('all').map((e) => e.date))].sort();
    const markDays = Object.keys(z.calMarksFromEvents()).sort();
    const cookOnly = [...new Set(z.timelineEvents('cook').map((e) => e.date))].sort();
    const markCook = markDays.filter((d) => z.calMarksFromEvents()[d].indexOf('cook') >= 0).sort();
    return { evDays, markDays, cookOnly, markCook };
  });
  ok('日历有点的日子集合 == 时间线出现过的日子集合',
    JSON.stringify(cross.evDays) === JSON.stringify(cross.markDays),
    `日历 ${cross.markDays.length} 天 / 时间线 ${cross.evDays.length} 天`);
  ok('只挑"做菜"也对得上（日历的 cook 点 == 做菜事件的日期）',
    JSON.stringify(cross.cookOnly) === JSON.stringify(cross.markCook));

  console.log('\n[7] 布局与控制台');
  const overflow = await page.evaluate(() => {
    const el = document.querySelector('#phone .screen');
    return el ? el.scrollWidth - el.clientWidth : -1;
  });
  ok('屏幕不横向溢出', overflow <= 0, 'overflow=' + overflow);
  ok('零 JS 错误', errs.length === 0, errs.slice(0, 3).join(' | '));
  ok('除 favicon 外没有 404', net404.filter((u) => !/favicon/.test(u)).length === 0,
    '404=' + (net404.length ? net404.join(' | ') : 'none'));

  await browser.close();
  srv.close();
  console.log('\n截图目录：' + OUT);
  console.log(fails === 0 ? '全部 PASS' : `有 ${fails} 条 FAIL`);
  process.exit(fails === 0 ? 0 : 1);
})();
