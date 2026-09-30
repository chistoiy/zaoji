// R48 补正 · 原型走查：翻页必须有读数，耗时过小时必须转小时。
//
// 两条都是真机装机量到的（不是设计稿推的）：
//  ① 点「看更早」在没东西可翻时**什么都不变** → 现在每点一次必有一行读数；
//  ② 挂了一夜的会话写成「实际耗时 966 分钟」 → ≥60 转「H 小时 M 分」。
// 期望值一律从 window.__zaoji 的源数据现算，且**时长的期望由本脚本自己算一遍**
// （拿被测代码的 durLabel 验被测代码 = 假绿）。
// 用法：node tool/proto_timeline_r48b_walk.cjs
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const ROOT = path.resolve(__dirname, '..');
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 8799;
const OUT = path.join(ROOT, 'dist', 'r48b_previews');

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

// 本脚本自己的那把尺（规格：≥60 转小时，整点不补 0 分）
const want = (m) => {
  if (m < 60) return m + ' 分钟';
  const h = Math.floor(m / 60), r = m % 60;
  return r ? h + ' 小时 ' + r + ' 分' : h + ' 小时';
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
  const text = (sel) => page.evaluate((s) => {
    const el = document.querySelector(s);
    return el ? el.textContent.replace(/\s+/g, ' ').trim() : null;
  }, sel);
  const count = () => page.evaluate(() => document.querySelectorAll('#tlList .tl-item').length);

  await go('01_first_page');

  // ──  首屏不显示读数（列表本身就是近 90 天）
  ok('首屏没有翻页读数（#tlSpan 不存在）', (await text('#tlSpan')) === null);

  // ──  耗时读数：所有 ≥60 的会话都要以「小时」形态出现，且裸分钟不出现
  const logs = await page.evaluate(() => {
    const out = [];
    Object.keys(window.__zaoji.COOK_LOG).forEach((rid) =>
      window.__zaoji.COOK_LOG[rid].forEach((l) => out.push({ date: l[0], m: l[3] })));
    return out;
  });
  const listText = (await text('#tlList')) || '';
  const over = logs.filter((l) => l.m >= 60);
  ok('演示数据里确实有 ≥60 分钟的会话（不然这条判据是空的）', over.length > 0,
    'n=' + over.length);
  const missing = over.filter((l) => !listText.includes(want(l.m)));
  ok('每条 ≥60 分钟的会话都按「H 小时 M 分」写', missing.length === 0,
    missing.slice(0, 3).map((x) => `${x.m}→${want(x.m)}`).join(' / '));
  const leaked = over.filter((l) => listText.includes('实际耗时 ' + l.m + ' 分钟'));
  ok('没有一条还写着裸分钟（966 分钟那种）', leaked.length === 0,
    leaked.slice(0, 3).map((x) => x.m).join(' / '));
  const under = logs.filter((l) => l.m < 60);
  const badShort = under.filter((l) => !listText.includes(l.m + ' 分钟'));
  ok('< 60 的仍写分钟，不硬凑小时', badShort.length === 0,
    badShort.slice(0, 3).map((x) => x.m).join(' / '));

  // ── ③ 点「看更早」：读数必须出现
  const before = await count();
  await page.click('#tlEarlier');
  await page.waitForTimeout(300);
  await page.screenshot({ path: path.join(OUT, '02_after_earlier.png') });
  const span1 = await text('#tlSpan');
  ok('点一次后读数出现', span1 !== null, 'span=' + span1);
  ok('读数只有两种诚实说法之一',
    /^已看到最近 \d+ 天$/.test(span1 || '') || span1 === '再往前 90 天没有记录', span1);
  const after1 = await count();
  ok('翻页是追加：已看过的一条都不许消失', after1 >= before, `${before} → ${after1}`);
  // 演示数据全在近 90 天内，所以这一页翻不出新东西 → 必须说实话
  ok('这一页没新记录时说实话，不冒充有进展',
    after1 === before ? span1 === '再往前 90 天没有记录' : span1 === '已看到最近 180 天',
    span1 + ' / ' + before + '→' + after1);

  // ── ④ 再点一次：读数还在、按钮还在（更早的历史可能真的有）
  await page.click('#tlEarlier');
  await page.waitForTimeout(300);
  await page.screenshot({ path: path.join(OUT, '03_after_earlier2.png') });
  const span2 = await text('#tlSpan');
  ok('第二次点击后仍有读数', span2 !== null, 'span=' + span2);
  ok('按钮不会翻着翻着消失', (await text('#tlEarlier')) !== null);

  // ── ⑤ 分段过滤器回归：点了条数必须变（这条是第一段就立的规矩）
  await page.click('[data-act="tl-kind"][data-kind="cook"]');
  await page.waitForTimeout(300);
  const cookN = await page.evaluate(() =>
    window.__zaoji.timelineEvents('cook').filter((e) =>
      (new Date(window.__zaoji.TODAY) - new Date(e.date)) / 86400000 < 90 * 3).length);
  const shownCook = await count();
  ok('切到「做菜」只剩做菜那些（条数与数据现算一致）',
    shownCook === cookN && shownCook < after1, `期望 ${cookN}，屏上 ${shownCook}`);
  await page.screenshot({ path: path.join(OUT, '04_filter_cook.png') });

  // ── ⑥ 空态不许有教学第二行（切到的这一类在演示数据里都有记录，
  //     所以按 DOM 断是**空跑**——直接查整份页面源码里那句还在不在）
  const src = await page.content();
  ok('页面源码里已经没有「换个类型看看」那句教学文案', !/换个类型看看/.test(src));

  ok('没有 console 报错', errs.length === 0, errs.slice(0, 2).join(' | '));
  ok('除了 favicon 没有 404', net404.filter((u) => !/favicon/.test(u)).length === 0,
    net404.filter((u) => !/favicon/.test(u)).slice(0, 2).join(' | '));

  await browser.close();
  srv.close();
  console.log(fails ? `\n${fails} 条 FAIL（FAIL ≠ 通过）` : '\n全部 PASS');
  process.exit(fails ? 1 : 0);
})().catch((e) => { console.error('跑挂了：', e); process.exit(1); });
