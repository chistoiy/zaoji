// R47 · 原型「提醒与计时」偏好走查（FR-SET-01/02/03）。
//
// 这三行原来在原型里是**装饰开关**：aria-checked 就地翻，状态不落、文案不动、
// 提前量根本不存在。App 端做实之后规格必须回落到原型，否则「原型是实现的规格」
// 这条铁律就变成空话。所以这一遍断言的是：翻开关真的改状态、文案跟着变、
// 提前量档位就地可选、且它只是本机偏好。
//
// 用法：node tool/proto_prefs_r47_walk.cjs
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const ROOT = path.resolve(__dirname, '..');
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 8798;
const OUT = path.join(ROOT, 'dist', 'prefs_r47_previews');

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

  await go('01_default');
  let p = await prefs();
  ok('默认：开饭前提醒开、提前量 90 分钟、悬浮窗开、震动开（与 App 的 KitchenPrefs 同一份默认值）',
    p.mealReminderOn === true && p.mealLead === 90 && p.timerFloatOn === true && p.vibrateOn === true,
    JSON.stringify(p));
  ok('开饭前提醒那行的文案写的是提前量', (await page.locator('.row-sub').filter({ hasText: '提前 1.5 小时' }).count()) === 1);
  ok('档位就地可见（6 档）', (await page.locator('.lead-chip').count()) === 6);
  ok('当前档位高亮且 aria-pressed', (await page.locator('.lead-chip.is-on').count()) === 1 &&
    (await page.locator('.lead-chip.is-on').getAttribute('aria-pressed')) === 'true');

  console.log('\n[2] 选「1 小时」：状态与文案一起变');
  await page.locator('[data-act="lead-pick"][data-min="60"]').click();
  await page.waitForTimeout(200);
  p = await prefs();
  ok('mealLead = 60', p.mealLead === 60, JSON.stringify(p));
  ok('文案改口「提前 1 小时」', (await page.locator('.row-sub').filter({ hasText: '提前 1 小时' }).count()) === 1);
  ok('高亮档跟着挪', (await page.locator('.lead-chip.is-on').getAttribute('data-min')) === '60');

  console.log('\n[3] 关掉总开关：档位整排收起（不是留着能点）');
  await page.locator('[data-act="pref-switch"][data-pref="mealReminderOn"]').click();
  await page.waitForTimeout(200);
  p = await prefs();
  ok('mealReminderOn = false', p.mealReminderOn === false, JSON.stringify(p));
  ok('档位不再渲染', (await page.locator('.lead-chip').count()) === 0);
  ok('文案改成「不开待办」', (await page.locator('.row-sub').filter({ hasText: '不开待办' }).count()) === 1);
  ok('开关自己是 aria-checked=false',
    (await page.locator('[data-pref="mealReminderOn"]').getAttribute('aria-checked')) === 'false');
  await page.screenshot({ path: path.join(OUT, '03_reminder_off.png') });

  console.log('\n[4] 再打开：档位回来，且回到上次选的 1 小时（不是跳回默认）');
  await page.locator('[data-act="pref-switch"][data-pref="mealReminderOn"]').click();
  await page.waitForTimeout(200);
  ok('档位回来了', (await page.locator('.lead-chip').count()) === 6);
  ok('mealLead 仍是 60', (await prefs()).mealLead === 60);

  console.log('\n[5] 悬浮窗与震动两路各自独立（都从默认开往下关）');
  await page.locator('[data-act="pref-switch"][data-pref="timerFloatOn"]').click();
  await page.waitForTimeout(150);
  p = await prefs();
  ok('悬浮窗关掉', p.timerFloatOn === false, JSON.stringify(p));
  await page.locator('[data-act="pref-switch"][data-pref="vibrateOn"]').click();
  await page.waitForTimeout(150);
  p = await prefs();
  ok('震动关掉', p.vibrateOn === false, JSON.stringify(p));
  ok('关过的悬浮窗没被带回来', p.timerFloatOn === false, JSON.stringify(p));

  console.log('\n[6] 刷新 = 真重启：偏好回到默认（本机偏好在原型里不持久，App 才落 local_pref）');
  await go('06_reload');
  p = await prefs();
  ok('刷新后回到默认（这一条钉的是「原型不假装持久」）',
    p.mealLead === 90 && p.timerFloatOn === true && p.vibrateOn === true, JSON.stringify(p));

  console.log('\n[7] 布局与控制台');
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
