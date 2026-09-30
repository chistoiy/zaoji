// R47 · 原型「多计时器 + 按目标时间戳倒计时」逐屏走查（FR-COOK-04/05、FR-COOK-14、NFR-REL-03）。
//
// 这一轮的原型改动是**状态模型级**的（单实例 → 数组 + endAt），不是换个皮肤，
// 所以断言要打在「并行是否真独立」和「切后台是否真不漂移」这两件事上：
//   ① 两个计时器各自暂停/加时/关闭，互不牵连；
//   ② 剩余量由 endAt 现算——把墙上时钟往前拨 10 分钟，剩余就正好少 600 秒。
// 这条不跑，改完直接写 Flutter，等于拿没验证过的规格去实现。
//
// 页面里的 S 在 IIFE 内部，脚本一律走 window.__zaoji 出口
// （本轮给它补了 startTimer / syncTimers / activeTimer / renderOverlays 四个成员）。
//
// 用法：node tool/proto_timers_r47_walk.cjs [--headed]
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const ROOT = path.resolve(__dirname, '..');
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 8797;
const OUT = path.join(ROOT, 'dist', 'timers_r47_previews');

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
function ok(name, cond, extra) {
  console.log((cond ? '  PASS ' : '  FAIL ') + name + (extra ? '  [' + extra + ']' : ''));
  if (!cond) fails++;
}

(async () => {
  await new Promise((r) => srv.listen(PORT, '127.0.0.1', r));
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch({
    executablePath: CHROME, args: ['--no-sandbox'],
    headless: process.argv.indexOf('--headed') < 0,
  });
  const page = await browser.newPage({ viewport: { width: 430, height: 900 } });
  const errs = [];
  const missing = [];
  page.on('console', (m) => {
    if (m.type() !== 'error') return;
    // 静态服务只挂原型一个文件：控制台里那句「Failed to load resource 404」不带 URL，
    // 光看文本分不清是页面自己的错还是 favicon 请求，所以另开一个 response 监听记 URL，
    // 控制台这条只在「不是资源 404」时才计入（工装先自证：别把工装噪声报成产品错误）。
    if (/Failed to load resource/.test(m.text())) return;
    errs.push(m.text());
  });
  page.on('response', (r) => {
    if (r.status() === 404) missing.push(r.url());
  });
  page.on('pageerror', (e) => errs.push('pageerror: ' + e.message));

  // 同一 hash 的 page.goto **不会真的重载**（R46 就栽过一次：上一屏的状态留下来，
  // 断言看起来像产品 bug）。每次导航都带一个自增的 _r 查询串。
  let seq = 0;
  const go = async (hash, tag) => {
    const sep = hash.indexOf('?') >= 0 ? '&' : '?';
    await page.goto(`http://127.0.0.1:${PORT}/zaoji-prototype.html${sep}_r=${++seq}${hash}`,
      { waitUntil: 'load' });
    await page.waitForTimeout(320);
    await page.screenshot({ path: path.join(OUT, tag + '.png') });
  };
  // 每次重新取快照，别把上一次的数组引用带过去
  const st = () => page.evaluate(() => {
    const Z = window.__zaoji;
    return {
      n: Z.S.timers.length,
      focus: Z.S.timerFocus,
      list: Z.S.timers.map((t) => ({
        id: t.id, label: t.label, total: t.total, left: Math.round(t.left),
        running: t.running, done: t.done, float: !!t.float,
        endAtIn: Math.round((t.endAt - Date.now()) / 1000),
      })),
    };
  });
  const add = (sec, label) => page.evaluate(([s, l]) => {
    const Z = window.__zaoji;
    Z.startTimer(s, l);
    Z.renderOverlays();
  }, [sec, label]);

  console.log('\n[1] 深链起一个计时器：全屏态在、剩余量来自 endAt');
  await go('#screen=cooking&id=r2&timer=300&label=%E7%82%96', '01_one_timer');
  let s = await st();
  ok('计时器数组里有 1 个实例', s.n === 1, 'n=' + s.n);
  ok('该实例在跑', !!(s.list[0] && s.list[0].running === true));
  // 起表到取样之间真实过了几秒（页面加载 + 回环），endAt 法本来就把它减掉了；
  // 这里钉的是「不超过 300、也没少得离谱」，而不是死盯 05:00。
  ok('剩余量在 300 秒附近且不超过', !!s.list[0] && s.list[0].left <= 300 && s.list[0].left > 280,
    'left=' + (s.list[0] || {}).left);
  ok('全屏计时器渲染出来', (await page.locator('.timer-full').count()) === 1);
  const ringTime = ((await page.locator('#tfMm').textContent().catch(() => '')) || '').trim();
  ok('环上时间与 left 一致（04:5x / 05:00）', /^0[45]:[0-5]\d$/.test(ringTime), ringTime);

  console.log('\n[2] 并行第二个：数组真有两个，各自目标戳不同');
  await add(360, '蒸 6 分钟');
  await page.waitForTimeout(200);
  s = await st();
  ok('变成 2 个并行计时器', s.n === 2, 'n=' + s.n);
  ok('两个 endAt 不同', s.list.length === 2 && s.list[0].endAtIn !== s.list[1].endAtIn,
    JSON.stringify(s.list.map((t) => t.endAtIn)));
  ok('全屏态列出「其他计时器」', (await page.locator('.tf-others .tf-other').count()) === 1);

  console.log('\n[3] ★ 切后台不漂移：30 分钟的表，把墙上时钟拨快 10 分钟，必须正好少 600 秒');
  // 用 30 分钟的长表而不是 5 分钟的短表：短表拨 10 分钟会撞到 clamp(0)，
  // 「少了 600 秒」这个性质就被截断掩盖了（第一版走查正是在这里假失败）。
  await go('#screen=cooking&id=r2&timer=1800&label=%E6%85%A2%E7%82%96', '03_long_timer');
  s = await st();
  const drift = await page.evaluate((before) => {
    const Z = window.__zaoji;
    // 用「拨快时钟」而不是真等：endAt 法的定义就是 剩余 = endAt - now，
    // 拨时钟与真等价的，而 CI 上等 10 分钟不现实。
    const fired = Z.syncTimers(Date.now() + 10 * 60 * 1000);
    return { before: before, after: Z.S.timers[0].left, fired: fired.length };
  }, s.list[0].left);
  ok('少了约 600 秒（不是少走几秒）', Math.abs(drift.before - drift.after - 600) < 1.5,
    JSON.stringify(drift));
  ok('没到点就不该报 fired', drift.fired === 0, 'fired=' + drift.fired);
  ok('剩余量仍为正（30 分钟的表拨 10 分钟不该归零）', drift.after > 1100, 'after=' + drift.after);
  const drift2 = await page.evaluate(() => {
    const Z = window.__zaoji;
    // 第二次是**从真实 now 起算 31 分钟**，不是在上一次的基础上再加：
    // endAt 是固定目标戳，第一次拨快并没有「消耗」掉时间——这正是这一轮要的性质。
    const fired = Z.syncTimers(Date.now() + 31 * 60 * 1000);
    return { fired: fired.length, left: Z.S.timers[0].left };
  });
  ok('真到点了：报出来 + 归零', drift2.fired === 1 && drift2.left === 0, JSON.stringify(drift2));
  await page.waitForTimeout(300);
  s = await st();
  ok('「时间到」的实例 running=false / done=true', s.list.some((t) => t.done === true && t.running === false));
  ok('剩余量不为负', s.list.every((t) => t.left >= 0));

  console.log('\n[4] 独立性：暂停一个不能碰另一个');
  await go('#screen=cooking&id=r2&timer=300&label=%E7%82%96', '04_fresh');
  await add(360, '蒸 6 分钟');
  await page.waitForTimeout(150);
  s = await st();
  const a1 = s.list[0].id, b1 = s.list[1].id;
  await page.locator(`[data-act="timer-toggle"][data-id="${a1}"]`).first().click();
  await page.waitForTimeout(150);
  s = await st();
  let a = s.list.find((t) => t.id === a1), b = s.list.find((t) => t.id === b1);
  ok('第一个已暂停', !!(a && a.running === false), JSON.stringify(a));
  ok('第二个仍在跑（没被连累）', !!(b && b.running === true), JSON.stringify(b));

  console.log('\n[5] 续跑要重算目标戳（否则回来立刻跳零）');
  await page.locator(`[data-act="timer-toggle"][data-id="${a1}"]`).first().click();
  await page.waitForTimeout(150);
  s = await st();
  a = s.list.find((t) => t.id === a1);
  ok('恢复后 running=true', !!(a && a.running === true));
  ok('恢复后 left 与 endAt 对齐（误差 <2 秒）', !!a && Math.abs(a.left - a.endAtIn) < 2,
    'left=' + (a || {}).left + ' endAtIn=' + (a || {}).endAtIn);

  console.log('\n[6] 加时改的是目标戳，不是只改显示');
  // 「+1 分钟」只挂在**全屏态当前显示的那个**表上；b1 若不是焦点，先在「其他计时器」里点它切焦点。
  const focused = await page.evaluate(() => window.__zaoji.activeTimer().id);
  if (focused !== b1) {
    const btn = page.locator(`[data-act="timer-focus"][data-id="${b1}"]`).first();
    if (await btn.count() > 0) { await btn.click(); await page.waitForTimeout(150); }
  }
  const addDelta = await page.evaluate((id) => {
    const Z = window.__zaoji;
    const t = Z.S.timers.find((x) => x.id === id);
    const before = t.endAt;
    const btn = document.querySelector(`[data-act="timer-add"][data-id="${id}"]`);
    if (!btn) return { missing: true };
    btn.click();
    return { delta: (t.endAt - before) / 1000 };
  }, b1);
  ok('点「+1 分钟」后目标戳正好 +60 秒', Math.abs((addDelta.delta || 0) - 60) < 0.6, JSON.stringify(addDelta));

  console.log('\n[7] 悬浮窗形态与并行计数徽标');
  await go('#screen=cooking&id=r2&timer=300&label=%E7%82%96&float=1', '07_fab');
  ok('深链 float=1 直接就是悬浮球', (await page.locator('#timerFab').count()) === 1,
    'full=' + (await page.locator('.timer-full').count()));
  // 新起的表默认是全屏态、而且会成为焦点：这一节要的是悬浮态，所以连着 float 一起给。
  await page.evaluate(() => {
    const Z = window.__zaoji;
    Z.startTimer(120, '再来一个');
    Z.S.timers.forEach((t) => { t.float = true; });
    Z.renderOverlays();
  });
  await page.waitForTimeout(200);
  s = await st();
  ok('两个实例并存', s.n === 2, 'n=' + s.n);
  ok('悬浮球出现', (await page.locator('#timerFab').count()) === 1);
  const badge = await page.locator('.fab-count').count();
  const badgeText = badge ? (await page.locator('.fab-count').textContent() || '').trim() : '-';
  ok('并行 ≥2 时球上有计数徽标', badge === 1, 'text=' + badgeText);
  await page.evaluate(() => {
    const Z = window.__zaoji;
    Z.S.timers = Z.S.timers.slice(0, 1);
    Z.S.timerFocus = Z.S.timers[0].id;
    Z.renderOverlays();
  });
  await page.waitForTimeout(150);
  ok('只剩 1 个时徽标自己收掉（不写「×1」）', (await page.locator('.fab-count').count()) === 0);

  console.log('\n[8] 关掉一个不影响另一个');
  await add(90, '第三个');
  await page.waitForTimeout(150);
  s = await st();
  ok('又是 2 个', s.n === 2, 'n=' + s.n);
  const victim = s.list[s.list.length - 1].id;
  const survivor = s.list[0].id;
  await page.evaluate((id) => {
    document.querySelector(`[data-act="timer-close"][data-id="${id}"]`).click();
  }, victim);
  await page.waitForTimeout(150);
  s = await st();
  ok('关掉后剩 1 个', s.n === 1, 'n=' + s.n);
  ok('活下来的那个还是原来那个且在跑',
    !!(s.list[0] && s.list[0].id === survivor && s.list[0].running === true), JSON.stringify(s.list));

  console.log('\n[9] 三个并行 + 全屏态切焦点 + 布局与控制台');
  await go('#screen=cooking&id=r2&timer=600&label=%E7%82%96%E7%85%AE', '09_three');
  await add(120, '蒸');
  await add(45, '收汁');
  await page.waitForTimeout(250);
  s = await st();
  ok('三个并行', s.n === 3, 'n=' + s.n);

  // ★ prev/next 是「切焦点」这个动作的可见入口：横滑是隐藏手势，
  //   只靠手势等于读屏用户和不想摸索的人没有这条路。
  //   新起的表默认就是焦点（第 3 个），所以先把焦点钉回第 1 个再走位序断言。
  await page.evaluate(() => {
    const Z = window.__zaoji;
    Z.S.timerFocus = Z.S.timers[0].id;
    Z.renderOverlays();
  });
  await page.waitForTimeout(150);
  const idx = async () =>
    ((await page.locator('.tf-idx').textContent().catch(() => '')) || '').trim();
  ok('并行时显示位序 1/3', (await idx()) === '1/3', await idx());
  await page.locator('[data-act="timer-next"]').click();
  await page.waitForTimeout(150);
  s = await st();
  ok('点「下一个」焦点移到第 2 个', s.focus === s.list[1].id, JSON.stringify(s.focus));
  ok('位序跟着变 2/3', (await idx()) === '2/3', await idx());
  await page.locator('[data-act="timer-prev"]').click();
  await page.waitForTimeout(150);
  s = await st();
  ok('点「上一个」回到第 1 个', s.focus === s.list[0].id);
  ok('切焦点不删表：还是 3 个', s.n === 3, 'n=' + s.n);
  const others = await page.evaluate(() => {
    const el = document.querySelector('.tf-others');
    return el ? el.scrollWidth - el.clientWidth : -1;
  });
  ok('「其他计时器」列表不横向溢出', others <= 0, 'overflow=' + others);
  const overflow = await page.evaluate(() => {
    const el = document.querySelector('#phone .screen');
    return el ? el.scrollWidth - el.clientWidth : -1;
  });
  ok('做菜页不横向溢出', overflow <= 0, 'overflow=' + overflow);
  await page.screenshot({ path: path.join(OUT, '99_three_parallel.png') });
  ok('零 JS 错误', errs.length === 0, errs.slice(0, 3).join(' | '));
  // 资源 404 单独报出来看一眼：走查服务只挂一个文件，favicon 属预期噪声
  const realMissing = missing.filter((u) => !/favicon|_r=/.test(u));
  ok('除 favicon 外没有 404 资源', realMissing.length === 0, realMissing.slice(0, 2).join(' | ') + '（共 ' + missing.length + ' 条）');

  await browser.close();
  srv.close();
  console.log('\n截图目录：' + OUT);
  console.log(fails === 0 ? '全部 PASS' : `有 ${fails} 条 FAIL`);
  process.exit(fails === 0 ? 0 : 1);
})();
