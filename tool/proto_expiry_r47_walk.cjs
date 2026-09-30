// R47 第四段 · 原型「库存到期提醒」走查（FR-PAN-04 的本机开关那半）。
//
// 这一路的关键区别要钉住：**这行不依赖系统授权**。
// 「通知带声音」在没授权时不出现是对的（那时它确实无效），
// 而「库存到期提醒」说的是这台设备要不要参与这条策略——
// 没授权它照样是个真实开关（关掉就真的不发），所以必须一直在。
// 用法：node tool/proto_expiry_r47_walk.cjs
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const ROOT = path.resolve(__dirname, '..');
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 8801;
const OUT = path.join(ROOT, 'dist', 'expiry_r47_previews');

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
  const page = await browser.newPage({ viewport: { width: 430, height: 1200 } });
  const errs = [];
  page.on('console', (m) => {
    if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errs.push(m.text());
  });
  page.on('pageerror', (e) => errs.push('pageerror: ' + e.message));

  let seq = 0;
  const go = async (tag) => {
    await page.goto(
      `http://127.0.0.1:${PORT}/zaoji-prototype.html?_r=${++seq}#screen=me`,
      { waitUntil: 'load' });
    await page.waitForTimeout(300);
    if (tag) await page.screenshot({ path: path.join(OUT, tag + '.png') });
  };
  const prefs = () => page.evaluate(() => ({ ...window.__zaoji.S.prefs }));
  const sw = (k) => page.locator(`[data-act="pref-switch"][data-pref="${k}"]`);

  await go('01_default');
  console.log('\n[1] 出厂默认：这一行在，而且是开的');
  let p = await prefs();
  ok('expiryNotifyOn 默认开', p.expiryNotifyOn === true, JSON.stringify(p));
  ok('行渲染出来', (await sw('expiryNotifyOn').count()) === 1);
  ok('aria-checked=true', (await sw('expiryNotifyOn').getAttribute('aria-checked')) === 'true');
  ok('副标题写的是策略（打开 App 时提醒一次，同一天不重复）',
    (await page.locator('.row-sub').filter({ hasText: '打开 App 时提醒一次，同一天不重复' }).count()) === 1);

  console.log('\n[2] ★ 没授权时它照样在（这行讲的是策略，不是授权结果）');
  p = await prefs();
  ok('此刻 notifyPerm 还是 default', (await page.evaluate(() => window.__zaoji.S.notifyPerm)) === 'default');
  ok('声音行不在（对照：那行才依赖授权）', (await sw('soundOn').count()) === 0);
  ok('到期行在', (await sw('expiryNotifyOn').count()) === 1);

  console.log('\n[3] 关掉：状态与 a11y 一起改，别的路不被牵连');
  await sw('expiryNotifyOn').click();
  await page.waitForTimeout(200);
  p = await prefs();
  ok('expiryNotifyOn = false', p.expiryNotifyOn === false, JSON.stringify(p));
  ok('aria-checked=false', (await sw('expiryNotifyOn').getAttribute('aria-checked')) === 'false');
  ok('震动/悬浮窗/通知都没被带跑',
    p.vibrateOn === true && p.timerFloatOn === true && p.notifyOn === true, JSON.stringify(p));

  console.log('\n[4] 授权拿到之后三行并存（通知 / 声音 / 到期）');
  await page.locator('[data-act="notify-perm"]').click();
  await page.waitForTimeout(200);
  ok('通知行在', (await sw('notifyOn').count()) === 1);
  ok('声音行出现', (await sw('soundOn').count()) === 1);
  ok('到期行一直在', (await sw('expiryNotifyOn').count()) === 1);
  await page.screenshot({ path: path.join(OUT, '04_three_rows.png') });

  console.log('\n[5] 刷新 = 真重启：回到默认（原型不假装持久，App 才落 local_pref）');
  await go('05_reload');
  p = await prefs();
  ok('expiryNotifyOn 回 true', p.expiryNotifyOn === true, JSON.stringify(p));

  console.log('\n[6] 布局与控制台');
  const overflow = await page.evaluate(() => {
    const el = document.querySelector('#phone .screen');
    return el ? el.scrollWidth - el.clientWidth : -1;
  });
  ok('我的屏不横向溢出', overflow <= 0, 'overflow=' + overflow);
  ok('零 JS 错误', errs.length === 0, errs.slice(0, 3).join(' | '));

  await browser.close();
  srv.close();
  console.log('\n截图目录：' + OUT);
  console.log(fails === 0 ? '全部 PASS' : `有 ${fails} 条 FAIL`);
  process.exit(fails === 0 ? 0 : 1);
})();
