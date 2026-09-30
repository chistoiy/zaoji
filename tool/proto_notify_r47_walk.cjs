// R47 第三段 · 原型「计时结束通知与声音」走查（FR-COOK-14 + FR-SET-03 声音）。
//
// 这一段要钉的是**授权态参与渲染**这件事：
// ① 没拿到系统授权时，界面上不能摆一枚「能打开但什么都不发生」的声音开关；
// ② 也不能只写一句「要去授权」却不给可点的入口；
// ③ 开关与授权是两件事——翻开关不许把自己算成已授权（那是假绿的原型版）。
// 所以断言全打在「行出没跟着状态走」上，而不是只打「点了会变」。
//
// 用法：node tool/proto_notify_r47_walk.cjs
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const ROOT = path.resolve(__dirname, '..');
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 8799;
const OUT = path.join(ROOT, 'dist', 'notify_r47_previews');

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
  const st = () => page.evaluate(() => ({
    ...window.__zaoji.S.prefs, perm: window.__zaoji.S.notifyPerm,
  }));
  // 开关与文字是同一行的**兄弟节点**，所以要先 closest('.row') 再往下找
  const sub = (key) => page.evaluate((k) => {
    const el = document.querySelector(`[data-pref="${k}"]`);
    const row = el && el.closest('.row');
    const s = row && row.querySelector('.row-sub');
    return s ? s.textContent : '(找不到)';
  }, key);
  const sw = (key) => page.locator(`[data-act="pref-switch"][data-pref="${key}"]`);
  const rowCount = (sel) => page.locator(sel).count();

  await go('01_before_grant');
  console.log('\n[1] 出厂态：通知与声音都默认开，但系统授权还没拿到');
  let s = await st();
  ok('默认 notifyOn/soundOn/vibrateOn/timerFloatOn 全开',
    s.notifyOn === true && s.soundOn === true && s.vibrateOn === true && s.timerFloatOn === true,
    JSON.stringify(s));
  ok('授权态是 default（原型不假装已经授权）', s.perm === 'default', JSON.stringify(s));
  ok('通知行文案说实话「还没拿到系统授权」', (await sub('notifyOn')) === '还没拿到系统授权',
    await sub('notifyOn'));
  ok('★ 声音行这时不出现（没授权就不摆能点却无效的开关）', (await rowCount('[data-pref="soundOn"]')) === 0);
  ok('★ 但给了可点的授权入口', (await rowCount('[data-act="notify-perm"]')) === 1);

  console.log('\n[2] 点授权入口：模拟系统弹框点了「允许」，声音行这才露面');
  await page.locator('[data-act="notify-perm"]').click();
  await page.waitForTimeout(200);
  s = await st();
  ok('notifyPerm 变 granted', s.perm === 'granted', JSON.stringify(s));
  ok('notifyOn 没被带跑（还是开）', s.notifyOn === true, JSON.stringify(s));
  ok('文案改口「到点在通知栏提醒一次」', (await sub('notifyOn')) === '到点在通知栏提醒一次',
    await sub('notifyOn'));
  ok('授权入口自己收掉（拿到了就别再劝）', (await rowCount('[data-act="notify-perm"]')) === 0);
  ok('声音行出现且默认开', (await rowCount('[data-pref="soundOn"]')) === 1 &&
    (await sw('soundOn').getAttribute('aria-checked')) === 'true');
  ok('声音行文案', (await sub('soundOn')) === '跟着系统的音量与静音档走', await sub('soundOn'));
  await page.screenshot({ path: path.join(OUT, '02_granted.png') });

  console.log('\n[3] 关声音：文案跟着变，状态真的落进偏好');
  await sw('soundOn').click();
  await page.waitForTimeout(200);
  s = await st();
  ok('soundOn = false', s.soundOn === false, JSON.stringify(s));
  ok('文案改口「静音：通知栏只落一条横幅」', (await sub('soundOn')) === '静音：通知栏只落一条横幅',
    await sub('soundOn'));

  console.log('\n[4] 关掉通知：声音行与授权入口都收起（不能留着能点）');
  await sw('notifyOn').click();
  await page.waitForTimeout(200);
  s = await st();
  ok('notifyOn = false', s.notifyOn === false, JSON.stringify(s));
  ok('声音行不再渲染', (await rowCount('[data-pref="soundOn"]')) === 0);
  ok('文案改成「不开通知，只剩震动与视觉」', (await sub('notifyOn')) === '不开通知，只剩震动与视觉',
    await sub('notifyOn'));
  ok('震动与悬浮窗没被牵连（各管各的）', s.vibrateOn === true && s.timerFloatOn === true,
    JSON.stringify(s));
  ok('★ 翻开关没有把自己算成已授权（perm 还是 granted，没被重置也没被绕过）',
    s.perm === 'granted', JSON.stringify(s));

  console.log('\n[5] 再打开：授权记住的是 granted，声音行回来且保持上次关着的状态');
  await sw('notifyOn').click();
  await page.waitForTimeout(200);
  s = await st();
  ok('perm 还是 granted（不重复要授权）', s.perm === 'granted', JSON.stringify(s));
  ok('声音行回来了', (await rowCount('[data-pref="soundOn"]')) === 1);
  ok('soundOn 仍是上次那个关着的状态', s.soundOn === false, JSON.stringify(s));
  await page.screenshot({ path: path.join(OUT, '05_reopen.png') });

  console.log('\n[6] 刷新 = 真重启：回到出厂态（原型不假装持久）');
  await go('06_reload');
  s = await st();
  ok('刷新后 notifyOn/soundOn 回默认、perm 回 default',
    s.notifyOn === true && s.soundOn === true && s.perm === 'default', JSON.stringify(s));

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
