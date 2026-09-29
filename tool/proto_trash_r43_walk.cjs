// R43 · 原型「删除这道菜 → 5 秒撤销 → 回收站 → 永久删除」逐屏走查。
//
// 为什么单独走这一遍：widget 测试证的是接线（点了确实删、确实恢复），
// 这一遍证的是**眼睛看得见的顺序**——确认弹层的话术、撤销条按钮点得到、
// 条到点自己收、删掉的菜当场出现在回收站、永久删除之后不许回列表冒出来。
// 原型是实现的规格（UI 铁律：先改原型再动实现），所以这一遍跑的是原型页。
//
// 用法：node tool/proto_trash_r43_walk.cjs [--headed]
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const ROOT = path.resolve(__dirname, '..');
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 8795;
const OUT = path.join(ROOT, 'dist', 'trash_r43_previews');
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript',
  '.css': 'text/css', '.png': 'image/png', '.jpg': 'image/jpeg', '.svg': 'image/svg+xml',
  '.woff2': 'font/woff2' };

const srv = http.createServer((req, res) => {
  const rel = decodeURIComponent(req.url.split('?')[0]);
  const abs = path.join(ROOT, rel === '/' ? '/zaoji-prototype.html' : rel);
  if (!abs.startsWith(ROOT) || !fs.existsSync(abs) || fs.statSync(abs).isDirectory()) {
    res.writeHead(404); res.end('nope'); return;
  }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(abs).toLowerCase()] || 'application/octet-stream' });
  res.end(fs.readFileSync(abs));
});

let fails = 0;
function ok(name, cond, extra) {
  console.log((cond ? '  PASS ' : '  FAIL ') + name + (extra ? '  [' + extra + ']' : ''));
  if (!cond) fails++;
}

(async () => {
  await new Promise((r) => srv.listen(PORT, '127.0.0.1', r));
  fs.mkdirSync(OUT, { recursive: true });
  // ★ 用本机真 Chrome，不用 playwright 自带的 headless shell（这台机器没下载它，
  //   仓库里另外三个走查脚本也都是这么钉的）
  const browser = await chromium.launch({
    executablePath: CHROME,
    args: ['--no-sandbox'],
    headless: process.argv.indexOf('--headed') < 0,
  });
  const page = await browser.newPage({ viewport: { width: 430, height: 900 } });
  const consoleErrs = [];
  page.on('console', (m) => {
    if (m.type() !== 'error') return;
    const at = (m.location() && m.location().url) || '';
    // 浏览器自发要 /favicon.ico，原型页没挂图标；这条与被测对象无关
    if (/favicon/i.test(at)) return;
    consoleErrs.push(m.text().slice(0, 100) + (at ? ' @' + at.slice(-40) : ''));
  });
  page.on('pageerror', (e) => consoleErrs.push('pageerror: ' + String(e).slice(0, 120)));

  await page.goto('http://127.0.0.1:' + PORT + '/zaoji-prototype.html', { waitUntil: 'load' });
  await page.waitForTimeout(1200);
  const booted = await page.evaluate(() => !!(window.__zaoji && window.__zaoji.screens));
  ok('原型渲染出来了', booted);
  if (!booted) { console.log('控制台：' + consoleErrs.slice(0, 3).join(' / ')); await browser.close(); srv.close(); process.exit(1); }

  const gotoScreen = (name) => page.evaluate((n) => window.__zaoji.goto(n, 'indigo', 'android'), name);
  const dishCount = () => page.evaluate(() => {
    const m = (document.querySelector('.screen') || document.body).textContent.match(/共 (\d+) 道/);
    return m ? Number(m[1]) : -1;
  });
  const trashNames = () => page.evaluate(() =>
    Array.from(document.querySelectorAll('.trash-row .row-title')).map((e) => e.textContent));
  const shot = (tag) => page.locator('.device').first().screenshot({ path: path.join(OUT, tag + '.png') });

  await gotoScreen('recipes');
  const n0 = await dishCount();
  ok('菜谱库基线有菜', n0 > 0, '共 ' + n0 + ' 道');

  /* ① 详情页那个删除入口 → 先问一次 */
  await gotoScreen('recipe-detail');
  const delBtn = page.locator('[data-act="sheet-trash-confirm"]').first();
  ok('详情页有删除入口（不是藏在「更多」里）', await delBtn.count() === 1);
  await delBtn.click();
  await page.waitForTimeout(320);
  const sheetText = await page.evaluate(() => {
    const s = document.querySelector('.sheet');
    return s ? s.textContent : '';
  });
  ok('点了先弹二次确认', /删除这道菜？/.test(sheetText), sheetText.slice(0, 30));
  ok('确认里说清"进回收站 · 30 天可恢复"', /回收站/.test(sheetText) && /30 天/.test(sheetText));
  ok('确认里指路"彻底清掉去回收站按永久删除"', /永久删除/.test(sheetText));
  await shot('01-confirm');

  /* ② 取消 = 什么都没发生 */
  await page.locator('[data-act="sheet-close"]').first().click();
  await page.waitForTimeout(300);
  await gotoScreen('recipes');
  ok('取消之后菜还在', (await dishCount()) === n0);

  /* ③ 真删：条 + 撤销 */
  await gotoScreen('recipe-detail');
  await page.locator('[data-act="sheet-trash-confirm"]').first().click();
  await page.waitForTimeout(320);
  await page.locator('[data-act="trash-run"]').first().click();
  await page.waitForTimeout(320);
  const bar = page.locator('.toast.has-act');
  ok('删除后出现带撤销的提示条', await bar.count() >= 1);
  ok('条上「撤销」是真按钮（外层 .toast-wrap 不吞点击）',
    await page.locator('.toast.has-act .toast-act').count() >= 1);
  await shot('02-undo-bar');
  const barText = await bar.first().textContent();
  ok('条上写的是"已删除「菜名」"', /已删除/.test(barText || ''), (barText || '').trim());

  await gotoScreen('recipes');
  const n1 = await dishCount();
  ok('删掉一道，列表计数当场少 1', n1 === n0 - 1, n0 + ' → ' + n1);

  /* ④ 撤销 = 把回收站里那条拿回来 */
  await gotoScreen('recipe-detail');
  await page.locator('[data-act="sheet-trash-confirm"]').first().click();
  await page.waitForTimeout(320);
  await page.locator('[data-act="trash-run"]').first().click();
  await page.waitForTimeout(300);
  await page.locator('.toast.has-act .toast-act').first().click();
  await page.waitForTimeout(300);
  const undone = await page.evaluate(() =>
    Array.from(document.querySelectorAll('.toast')).map((e) => e.textContent).join('|'));
  ok('按撤销就出「已恢复」', /已恢复/.test(undone), undone.slice(0, 40));
  await gotoScreen('recipes');
  ok('撤销之后计数回到基线', (await dishCount()) === n0, String(await dishCount()));

  /* ⑤ 条到点自己收（真机上对应 persist:false 那条坑） */
  await gotoScreen('recipe-detail');
  await page.locator('[data-act="sheet-trash-confirm"]').first().click();
  await page.waitForTimeout(320);
  await page.locator('[data-act="trash-run"]').first().click();
  await page.waitForTimeout(300);
  ok('刚删完条在', await page.locator('.toast.has-act').count() >= 1);
  const lastName = await page.evaluate(() => {
    const t = document.querySelector('.toast.has-act');
    const m = t && t.textContent.match(/已删除「(.+?)」/);
    return m ? m[1] : '';
  });
  await page.waitForTimeout(5600);
  ok('5 秒后条自己收掉（不许永挂）', await page.locator('.toast.has-act').count() === 0);
  await gotoScreen('recipes');
  ok('窗口过了菜仍在回收站（不是丢了）', (await dishCount()) === n0 - 1);

  /* ⑥ 回收站看得见它 */
  await gotoScreen('trash');
  const names = await trashNames();
  // 读数先自证工装自己：这一屏到底是不是回收站、行是从哪个节点来的（本轮跑出过一次 6 项的空读数）
  const dump = await page.evaluate(() => ({
    screen: (document.querySelector('.appbar-title, .screen h1, .screen') || {}).textContent
      ? String((document.querySelector('.appbar-title, .screen h1, .screen') || {}).textContent).slice(0, 24) : '-',
    rows: document.querySelectorAll('.trash-row').length,
    titles: Array.from(document.querySelectorAll('.trash-row')).slice(0, 3)
      .map((r) => String((r.querySelector('.row-title') || {}).textContent).slice(0, 12)),
    inIframe: !!document.querySelector('iframe'),
  }));
  console.log('  读数 ⑥：' + JSON.stringify(dump));
  ok('刚删的菜当场出现在回收站，且排在最前', names[0] === lastName,
    '期望「' + lastName + '」实得「' + names[0] + '」');
  ok('回收站比基线多一项', names.length === 7, names.length + ' 项');
  ok('新那项写「还剩 30 天」', await page.evaluate(() => {
    const t = document.querySelector('.trash-row .trash-life');
    return !!t && /还剩 30 天/.test(t.textContent);
  }));
  ok('回收站写明 30 天保留', await page.evaluate(() => /30 天后自动清理/.test(document.body.textContent)));
  await shot('03-trash');

  /* ⑦ 回收站里恢复 */
  await gotoScreen('recipes');
  const rRestore0 = await dishCount();
  await gotoScreen('trash');
  // 本机刚删的那批排在最前（trashAll = trashedRecipes().concat(TRASH)）
  const row = page.locator('.trash-row').first();
  await row.locator('[data-act="trash-restore-one"]').click();
  await page.waitForTimeout(320);
  await gotoScreen('recipes');
  ok('回收站点「恢复」→ 菜回列表', (await dishCount()) === rRestore0 + 1,
    rRestore0 + ' → ' + await dishCount());

  /* ⑧ 永久删除：从回收站抹掉，不许回列表 */
  await gotoScreen('recipe-detail');
  await page.locator('[data-act="sheet-trash-confirm"]').first().click();
  await page.waitForTimeout(320);
  await page.locator('[data-act="trash-run"]').first().click();
  await page.waitForTimeout(5800);
  await gotoScreen('trash');
  const rPurge0 = await (async () => { await gotoScreen('recipes'); return dishCount(); })();
  await gotoScreen('trash');
  const gone = await page.evaluate(() => {
    const rows = Array.from(document.querySelectorAll('.trash-row'));
    const t = rows[0];
    const name = t.querySelector('.row-title').textContent;
    t.click();
    return name;
  });
  await page.waitForTimeout(320);
  await page.locator('[data-act="trash-purge"]').first().click();
  await page.waitForTimeout(400);
  const names2 = await trashNames();
  ok('永久删除后回收站里没有了', names2.indexOf(gone) < 0, gone);
  await gotoScreen('recipes');
  ok('永久删除不许把菜退回列表', (await dishCount()) === rPurge0,
    rPurge0 + ' / ' + await dishCount());
  await shot('04-purged');

  ok('全程无控制台报错', consoleErrs.length === 0, consoleErrs.slice(0, 2).join(' / '));

  await browser.close();
  srv.close();
  console.log(fails === 0 ? '\n原型走查：全部通过' : '\n原型走查：' + fails + ' 项不通过');
  process.exit(fails === 0 ? 0 : 1);
})().catch((e) => { console.log('崩溃：' + e.stack); process.exit(1); });
