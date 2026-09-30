// R47 第五段 · 原型走查：厨房 tab 顶部的「到期 / 快没了」告警卡（FR-PAN-06）。
//
// 关键口径（也是这个工装要钉的东西）：
//  · 期望值一律从 __zaoji.PANTRY **现算**，不从 DOM 读数反推 DOM（那是假绿）；
//  · 三组的截断（前 3 个名字 + 「等 N 样」）必须与 App 的 PantryWatch 同一口径；
//  · 「有数据才出现」是需求书 FR-PAN-06 的验收判据，所以空数据那条不是可选项；
//  · 已在推荐段时不给「按库存找菜」按钮（点了没反应的控件不放）。
// 用法：node tool/proto_pantry_card_r47_walk.cjs [--headed]
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const ROOT = path.resolve(__dirname, '..');
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 8803;
const OUT = path.join(ROOT, 'dist', 'pancard_r47_previews');

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
  const browser = await chromium.launch({
    executablePath: CHROME, args: ['--no-sandbox'],
    headless: process.argv.indexOf('--headed') < 0,
  });
  const page = await browser.newPage({ viewport: { width: 430, height: 1400 } });
  const errs = [];
  page.on('console', (m) => {
    if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errs.push(m.text());
  });
  page.on('pageerror', (e) => errs.push('pageerror: ' + e.message));

  let seq = 0;
  const go = async (screen, tag) => {
    await page.goto(
      `http://127.0.0.1:${PORT}/zaoji-prototype.html?_r=${++seq}#screen=${screen}`,
      { waitUntil: 'load' });
    await page.waitForTimeout(320);
    if (tag) await page.screenshot({ path: path.join(OUT, tag + '.png') });
  };
  // 期望值：与页面里 pantryWatchCard 同一套过滤，但**独立写一遍**（不复用它的输出）
  const expected = () => page.evaluate(() => {
    const P = window.__zaoji.PANTRY;
    const live = (p) => p.level !== 'out';
    const byExp = (a, b) => String(a.exp || '9999').localeCompare(String(b.exp || '9999'));
    const cut = (arr) => {
      const head = arr.slice(0, 3).map((p) => p.name).join('、');
      return arr.length > 3 ? head + ' 等 ' + arr.length + ' 样' : head;
    };
    const bad = P.filter((p) => live(p) && p.expState === 'warn').sort(byExp);
    const soon = P.filter((p) => live(p) && p.expState === 'soon').sort(byExp);
    const low = P.filter((p) => p.level === 'low');
    const out = P.filter((p) => p.level === 'out');
    return {
      bad: bad.length, soon: soon.length, low: low.length, out: out.length,
      badNames: cut(bad), soonNames: cut(soon), lowNames: cut(low), outNames: cut(out),
      any: !!(bad.length || soon.length || low.length || out.length),
    };
  });
  const rowText = (kw) => page.locator(`#pw-card .pw-row[data-kw="${kw}"]`).innerText();

  console.log('\n[1] 三个厨房子段顶部都有这张卡，且位置在分段导航之后');
  await go('prep'); // ★ 先真加载一次：没导航之前页面是空的，__zaoji 还不存在
  const e = await expected();
  ok('样本数据本身有告警项（否则这段没得验）', e.any, JSON.stringify(e));
  for (const s of ['prep', 'pantry', 'recommend']) {
    await go(s, 'card_' + s);
    ok(`${s} 段卡片渲染一次`, (await page.locator('#pw-card').count()) === 1);
    const order = await page.evaluate(() => {
      const seg = document.querySelector('.kitchen-seg'), card = document.querySelector('#pw-card');
      return !!(seg && card) && (seg.compareDocumentPosition(card) & Node.DOCUMENT_POSITION_FOLLOWING) > 0;
    });
    ok(`${s} 段卡片在分段导航下方`, order);
  }

  console.log('\n[2] 三组的计数与名字，逐个对（期望从 PANTRY 现算）');
  await go('pantry');
  const has = (kw) => page.locator(`#pw-card .pw-row[data-kw="${kw}"]`).count();
  for (const [kw, n, names] of [['bad', e.bad, e.badNames], ['soon', e.soon, e.soonNames],
      ['low', e.low, e.lowNames], ['out', e.out, e.outNames]]) {
    if (!n) { ok(`${kw} 组数量为 0，行不出现`, (await has(kw)) === 0); continue; }
    ok(`${kw} 组出现一行`, (await has(kw)) === 1, 'n=' + n);
    const t = await rowText(kw);
    ok(`${kw} 组带计数 ${n}`, t.includes(String(n)), t.replace(/\s+/g, ' '));
    ok(`${kw} 组列到名字（前 3 + 等 N 样）`, t.includes(names.split('、')[0]), t.replace(/\s+/g, ' '));
    if (n > 3) ok(`${kw} 组截断写成「等 ${n} 样」`, t.includes('等 ' + n + ' 样'), t.replace(/\s+/g, ' '));
  }
  ok('「没有」的不算到期（家里本来就没有，提醒它没意义）',
    e.bad === 0 || !(await rowText('bad')).includes('没有'));
  // ★ 去重：这张卡是**唯一**的计数出口。头部那组徽标若还在，同一屏就有两份数字，
  //    改一处忘一处（本轮正是为此把它们摘掉的）。
  ok('「已过期」这枚计数在屏幕上只出现一次（头部徽标已摘）',
    (await page.locator('.badge:has-text("已过期")').count()) === 1);
  ok('「快没了」也只出现一次',
    (await page.locator('.badge:has-text("快没了")').count()) === 1);

  console.log('\n[3] 去处按钮：只有备菜清单段给（另两段一个本来就有同一颗、一个已在目的地）');
  await go('pantry');
  ok('库存段不给重复按钮', (await page.locator('#pw-to-reco').count()) === 0);
  ok('但库存段本来就有那颗「按库存找菜」', (await page.locator('.btn:has-text("按库存找菜")').count()) >= 1);
  await go('prep');
  ok('备菜段给（那里没别的入口）', (await page.locator('#pw-to-reco').count()) === 1);
  await go('recommend');
  ok('推荐段不给（点了没反应的控件不放）', (await page.locator('#pw-to-reco').count()) === 0);
  ok('但卡本身还在（告警与在不在哪一段无关）', (await page.locator('#pw-card').count()) === 1);

  console.log('\n[4] 从备菜段点按钮 → 真的切到推荐段，卡跟着在');
  await go('prep');
  await page.locator('#pw-to-reco').click();
  await page.waitForTimeout(320);
  const nowSeg = await page.evaluate(() => window.__zaoji.S.route.name);
  ok('切到了 recommend', nowSeg === 'recommend', nowSeg);
  ok('切完卡片还在', (await page.locator('#pw-card').count()) === 1);
  await page.screenshot({ path: path.join(OUT, 'card_after_jump.png') });

  console.log('\n[5] ★ 有数据才出现：把四组都清空后整卡不渲染');
  await go('pantry'); // 清空要在库存段上做——上一段结束时人在推荐段，那里本来就没有 .pan-item
  const cleared = await page.evaluate(() => {
    const P = window.__zaoji.PANTRY;
    P.forEach((p) => { p.expState = ''; p.level = 'sufficient'; });
    window.__zaoji.renderScreen(true);
    return document.querySelectorAll('#pw-card').length;
  });
  ok('清空后卡片数量 = 0', cleared === 0, 'cards=' + cleared);
  const stillList = await page.evaluate(() => document.querySelectorAll('.pan-item').length > 0);
  ok('库存列表本身没被误伤（只是卡没了）', stillList);

  console.log('\n[6] 刷新复原 + 那句教学文案确实摘了 + 布局与控制台');
  await go('pantry', 'card_reload');
  const e2 = await expected();
  ok('刷新后卡片回来（数据是常量，原型不假装持久）', (await page.locator('#pw-card').count()) === 1);
  ok('刷新后四组计数复原',
    e2.bad === e.bad && e2.soon === e.soon && e2.low === e.low && e2.out === e.out,
    JSON.stringify(e2));
  ok('那句「有 N 样快过期了，点下面的…」已经不在了',
    (await page.locator('text=能优先消耗掉它们').count()) === 0);
  const overflow = await page.evaluate(() => {
    const el = document.querySelector('#phone .screen');
    return el ? el.scrollWidth - el.clientWidth : -1;
  });
  ok('厨房段不横向溢出', overflow <= 0, 'overflow=' + overflow);
  ok('零 JS 错误', errs.length === 0, errs.slice(0, 3).join(' | '));

  await browser.close();
  srv.close();
  console.log('\n截图目录：' + OUT);
  console.log(fails === 0 ? '全部 PASS' : `有 ${fails} 条 FAIL`);
  process.exit(fails === 0 ? 0 : 1);
})();
