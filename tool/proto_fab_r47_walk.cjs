// R47 第八段 · 原型走查：悬浮球吸边收成耳朵 / 点耳朵展开 / 全屏时球不出现。
// 期望值从状态与 deviceSize() 现算（drag 的输入坐标才读 DOM——那是操作，不是判据）。
// 用法：node tool/proto_fab_r47_walk.cjs
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const ROOT = path.resolve(__dirname, '..');
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 8792;
const OUT = path.join(ROOT, 'dist', 'fab_r47_previews');

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
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const errs = [], net404 = [];
  page.on('console', (m) => {
    const t = m.text();
    if (m.type() === 'error' && !/Failed to load resource/.test(t)) errs.push(t);
  });
  page.on('response', (r) => { if (r.status() === 404) net404.push(r.url()); });

  let seq = 0;
  const go = async (tag) => {
    await page.goto(`http://127.0.0.1:${PORT}/zaoji-prototype.html?_r=${++seq}#screen=recipes`,
      { waitUntil: 'load' });
    await page.waitForTimeout(400);
    if (tag) await page.screenshot({ path: path.join(OUT, tag + '.png') });
  };
  const fabState = () => page.evaluate(() => ({ ...window.__zaoji.S.fab }));
  const has = (sel) => page.locator(sel).count();
  // 设计像素 → 客户端像素的比例（只为算拖拽输入，不作为判据）
  const scaleOf = () => page.evaluate(() => {
    const pr = document.getElementById('phone').getBoundingClientRect();
    return pr.width / window.__zaoji.deviceSize().w;
  });
  // 贴边是 CSS 锚定（right:0 / left:0），所以读**内联样式**：那才是声明本身。
  // ★ 别用 getComputedStyle——绝对定位元素的 left/right 会返回「用后值」，
  //   auto 被解析成实际像素，于是永远断不出 auto。
  const anchored = (sel) => page.evaluate((sel) => {
    const el = document.querySelector(sel);
    if (!el) return null;
    return { right: el.style.right, left: el.style.left, top: el.style.top,
      snapped: window.__zaoji.S.fab.snapped, side: window.__zaoji.S.fab.side };
  }, sel);

  const dragFab = async (dxDesign, dyDesign) => {
    const sc = await scaleOf();
    const box = await page.locator('#timerFab').boundingBox();
    // 抓球的左段（进度环那块）：中心正落在 .fab-btn 上，而按钮是刻意不启动拖拽的
    const gx = box.x + 20, gy = box.y + box.height / 2;
    await page.mouse.move(gx, gy);
    await page.mouse.down();
    await page.mouse.move(gx + dxDesign * sc, gy + dyDesign * sc, { steps: 8 });
    await page.mouse.up();
    await page.waitForTimeout(250);
  };

  console.log('[1] 起表：完整球在位，耳朵不在');
  await go('01_ball');
  // 第三参数 true = 悬浮窗态（不传就是全屏页）
  await page.evaluate(() => { window.__zaoji.startTimer(300, '炖肉', true); });
  await page.waitForTimeout(300);
  ok('完整球出现', (await has('#timerFab')) === 1);
  ok('耳朵不出现', (await has('#timerEar')) === 0);
  let f = await fabState();
  const def = await page.evaluate(() => window.__zaoji.fabDefault());
  ok('默认不收起、贴右（期望取自 fabDefault，不抄字面量）', f.collapsed === def.collapsed && f.side === def.side, JSON.stringify(f));
  const PW = await page.evaluate(() => window.__zaoji.deviceSize().w);
  const ballW = (await page.locator('#timerFab').boundingBox()).width / (await scaleOf());
  ok('球与屏的宽度关系合理（球没宽过屏幕）', ballW > 80 && ballW < PW, 'ballW=' + ballW.toFixed(1) + ' PW=' + PW);
  await page.screenshot({ path: path.join(OUT, '01_ball.png') });

  console.log('\n[2] 拖到右边缘松手：吸边 + 收成耳朵');
  await dragFab(PW, 0); // 往右推到底，让 clamp 把它顶到右边界
  f = await fabState();
  ok('collapsed=true', f.collapsed === true, JSON.stringify(f));
  ok('side=right', f.side === 'right', JSON.stringify(f));
  const aR = await anchored('#timerEar');
  ok('耳朵锚在右缘（right:0 / left:auto）',
    aR && aR.right === '0px' && aR.left === 'auto' && aR.snapped === true && aR.side === 'right',
    JSON.stringify(aR));
  const snappedX = f.x;
  ok('耳朵在、完整球没了', (await has('#timerEar')) === 1 && (await has('#timerFab')) === 0);
  await page.screenshot({ path: path.join(OUT, '02_ear_right.png') });

  console.log('\n[3] 点耳朵：回到完整球（位置留在右侧，不弹回默认角）');
  await page.locator('#timerEar').click();
  await page.waitForTimeout(250);
  f = await fabState();
  ok('collapsed=false', f.collapsed === false, JSON.stringify(f));
  ok('完整球回来、耳朵消失', (await has('#timerFab')) === 1 && (await has('#timerEar')) === 0);
  // 展开后形态变宽，x 必然要挪（挪了才贴边）——判据是几何：球右缘仍贴手机右缘、且没被弹回默认角
  const aB = await anchored('#timerFab');
  ok('展开后球仍锚在右缘（同一条边，不用重算宽度）',
    aB && aB.right === '0px' && aB.left === 'auto' && aB.snapped === true, JSON.stringify(aB));
  ok('展开后仍记着贴右（side=right，没被重置回默认角）', f.side === 'right' && f.snapped === true,
    JSON.stringify(f));

  console.log('\n[4] 拖到左边缘：side=left 且 x=0');
  await dragFab(-PW, 0);
  f = await fabState();
  ok('collapsed=true', f.collapsed === true, JSON.stringify(f));
  ok('side=left', f.side === 'left', JSON.stringify(f));
  const aL = await anchored('#timerEar');
  ok('耳朵锚在左缘（left:0 / right:auto）',
    aL && aL.left === '0px' && aL.right === 'auto' && aL.side === 'left', JSON.stringify(aL));
  ok('耳朵带 on-left（圆角朝内）',
    (await page.locator('#timerEar.on-left').count()) === 1);
  await page.screenshot({ path: path.join(OUT, '04_ear_left.png') });

  console.log('\n[5] 停在中间松手：不收起（吸边是"靠边"才有的行为）');
  await page.locator('#timerEar').click();
  await page.waitForTimeout(200);
  const mid = await page.evaluate(() => {
    const z = window.__zaoji;
    return Math.round(z.deviceSize().w / 2 - 74); // 摆到屏幕中间
  });
  // 自由态 = 有 x 且没吸附。只改 x 不清 snapped 的话，渲染仍按锚定走，
  // 拖拽起点会被 pointerdown 按矩形重算到边上——那这条用例就白写了。
  await page.evaluate((x) => {
    const z = window.__zaoji;
    z.S.fab.snapped = false; z.S.fab.collapsed = false; z.S.fab.x = x;
    z.renderOverlays();
  }, mid);
  await page.waitForTimeout(200);
  const box = await page.locator('#timerFab').boundingBox();
  const sc = await scaleOf();
  const gx = box.x + 20, gy = box.y + box.height / 2;
  await page.mouse.move(gx, gy);
  await page.mouse.down();
  await page.mouse.move(gx + 6 * sc, gy - 40 * sc, { steps: 5 });
  await page.mouse.up();
  await page.waitForTimeout(250);
  f = await fabState();
  ok('中间松手不收起', f.collapsed === false, JSON.stringify(f));
  ok('中间松手也不吸附（snapped=false，坐标是自由的）', f.snapped === false, JSON.stringify(f));
  ok('完整球还在', (await has('#timerFab')) === 1);

  console.log('\n[6] 并行两张表：耳朵上带 ×N 徽标（收起也不丢"还有别的表"）');
  await page.evaluate(() => { window.__zaoji.startTimer(120, '烫生菜', true); });
  await page.waitForTimeout(250);
  ok('计时器数量到 2', (await page.evaluate(() => window.__zaoji.S.timers.length)) === 2);
  await dragFab(PW, 0);
  const earCount = await page.locator('#timerEar .fab-count').innerText().catch(() => '');
  ok('耳朵上有计数徽标 2', earCount.trim() === '2', 'badge=' + JSON.stringify(earCount));
  await page.screenshot({ path: path.join(OUT, '06_ear_badge.png') });

  console.log('\n[7] 展开成全屏：球与耳朵都不该出现（全屏独占，实现要跟上这条）');
  await page.locator('#timerEar').click();
  await page.waitForTimeout(200);
  await page.locator('#timerFab [data-act="timer-max"]').click();
  await page.waitForTimeout(350);
  ok('全屏页在', (await has('.timer-full')) === 1);
  ok('完整球不出现', (await has('#timerFab')) === 0);
  ok('耳朵也不出现', (await has('#timerEar')) === 0);
  // ★ 全屏页**从状态栏那一层开始画**：这一屏里要自带一条状态栏（浅色浮在深色底上）。
  //   判据取自状态与配色声明，不是「DOM 里刚好有个 div」。
  const sb = await page.evaluate(() => {
    const el = document.querySelector('.timer-full .statusbar');
    if (!el) return null;
    const cs = getComputedStyle(el);
    const full = document.querySelector('.timer-full').getBoundingClientRect();
    const me = el.getBoundingClientRect();
    return { color: cs.color, topGap: Math.round(me.top - full.top), h: Math.round(me.height) };
  });
  ok('全屏页里画了状态栏', sb !== null, JSON.stringify(sb));
  ok('状态栏文字转浅色（深色底上可读）',
    sb && /255,\s*243,\s*232/.test(sb.color), sb && sb.color);
  ok('状态栏顶到这一屏的最上沿（页面含通知栏，不是让出来的一条空白）',
    sb && sb.topGap <= 1 && sb.h > 30, sb && JSON.stringify(sb));
  await page.screenshot({ path: path.join(OUT, '07_full.png') });
  await page.locator('[data-act="timer-min"]').click();
  await page.waitForTimeout(300);
  ok('收成悬浮窗后球回来', (await has('#timerFab')) === 1);

  console.log('\n[8] 表全关掉：球与耳朵一起消失（不留空壳）');
  await page.evaluate(() => {
    const z = window.__zaoji;
    z.S.timers.forEach((t) => z.syncTimers && null);
    z.S.timers.length = 0;
    z.renderOverlays();
  });
  await page.waitForTimeout(250);
  ok('球与耳朵都没了', (await has('#timerFab')) === 0 && (await has('#timerEar')) === 0);

  console.log('\n[9] 布局与控制台');
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
