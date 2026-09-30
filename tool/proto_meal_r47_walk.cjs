// R47 第六段 · 原型「开饭前投待办」走查（FR-SET-01 + FR-PLAN-09）。
//
// 断言的三族事：
// ① 那一行与就地档位是真的联动（翻开关收起档位与摘要、选档改状态与文案）；
// ② 「投什么」的摘要从 MENUS/RECIPES **现算**，不从 DOM 反推（§7.10：从 DOM 反推 DOM 是假绿）；
// ③ 结构：这一行是 .list 的直接子元素——第四段那次脚本改写留过一个未闭合的 .row，
//    当时的走查只数 chip、没数层级，所以它一直没响。
//
// 用法：node tool/proto_meal_r47_walk.cjs   （加 --headed 看窗口）
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const ROOT = path.resolve(__dirname, '..');
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 8794;
const OUT = path.join(ROOT, 'dist', 'meal_r47_previews');

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

// 与原型同一套提前量文本（三处各写一遍就会漂，所以这里也只认这一份规则）
const leadLabel = (m) => (m < 60 ? m + ' 分钟'
  : (m / 60) % 1 === 0 ? (m / 60) + ' 小时' : (m / 60).toFixed(1) + ' 小时');

(async () => {
  await new Promise((r) => srv.listen(PORT, '127.0.0.1', r));
  fs.mkdirSync(OUT, { recursive: true });
  const browser = await chromium.launch({
    executablePath: CHROME, args: ['--no-sandbox'],
    headless: process.argv.indexOf('--headed') < 0,
  });
  const page = await browser.newPage({ viewport: { width: 430, height: 1400 } });
  const errs = [];
  const net404 = [];
  page.on('console', (m) => {
    const t = m.text();
    // 「Failed to load resource」那句控制台里没有 URL，分不出是谁 404；
    // 走查按 §7.10 要「favicon 单列一条」，所以 404 改由 response 事件按 URL 记。
    if (m.type() === 'error' && !/Failed to load resource/.test(t)) errs.push(t);
  });
  page.on('response', (r) => { if (r.status() === 404) net404.push(r.url()); });
  page.on('pageerror', (e) => errs.push('pageerror: ' + e.message));

  let seq = 0;
  const go = async (tag) => {
    // 同一个 hash 再 goto 不会重新加载 → 带自增缓存戳
    await page.goto(`http://127.0.0.1:${PORT}/zaoji-prototype.html?_r=${++seq}#screen=me`,
      { waitUntil: 'load' });
    await page.waitForTimeout(300);
    if (tag) await page.screenshot({ path: path.join(OUT, tag + '.png') });
  };
  const prefs = () => page.evaluate(() => ({ ...window.__zaoji.S.prefs }));
  // 期望一律从数据现算：数据本体 + 原型那两个纯函数（同一个口径，不复制算法）
  const expectTodo = () => page.evaluate(() => {
    const z = window.__zaoji;
    return z.mealTodoTargets().map((m) => {
      const d = z.mealDigest(m);
      return {
        menuId: m.id,
        text: m.time + ' ' + m.meal + ' · ' + (d.dishes
          ? d.dishes + ' 道菜 · 备菜 ' + d.ingredients + ' 样 · 步骤 ' + d.steps + ' 步'
          : '还没排菜'),
        dishes: d.dishes, ingredients: d.ingredients, steps: d.steps,
      };
    });
  });

  console.log('[1] 默认态：开关开、档位就地、摘要按数据算出来的那几行');
  await go('01_default');
  let p = await prefs();
  const want = await expectTodo();
  ok('默认 mealReminderOn=true / mealLead=90（与 App 的 KitchenPrefs 同一份默认值）',
    p.mealReminderOn === true && p.mealLead === 90, JSON.stringify(p));
  ok('今天可投的餐次确实有（数据侧先自证，不然下面的空断言是假的）',
    want.length >= 1, JSON.stringify(want));
  ok('摘要行数 == 数据算出来的餐次数',
    (await page.locator('.meal-todo-row').count()) === want.length,
    'dom=' + (await page.locator('.meal-todo-row').count()) + ' data=' + want.length);
  for (const w of want) {
    const t = await page.locator(`.meal-todo-row[data-menu="${w.menuId}"]`).innerText();
    ok(`「${w.menuId}」那行写的就是现算的摘要`, t.trim() === w.text.trim(), t);
    ok(`「${w.menuId}」的菜数不是凭空写出来的`,
      /\d+ 道菜/.test(t) && t.includes(w.dishes + ' 道菜'), t);
  }
  await page.screenshot({ path: path.join(OUT, '01_default.png') });

  console.log('\n[2] 结构：开饭前提醒那一行是 .list 的直接子元素，没有游离的未闭合 .row');
  const struct = await page.evaluate(() => {
    const row = Array.from(document.querySelectorAll('.row'))
      .find((r) => (r.querySelector('.row-title') || {}).textContent === '开饭前提醒');
    if (!row) return { found: false };
    const parentIsList = !!row.closest('.list') && row.parentElement.classList.contains('list');
    // 空 row = 只有图标没有正文的残句；它会把后面的行吞进自己肚子里
    const empties = Array.from(document.querySelectorAll('.list > .row'))
      .filter((r) => !r.querySelector('.row-main')).length;
    const floats = row.parentElement.querySelectorAll(':scope > .row').length;
    return { found: true, parentIsList, empties, floats, tag: row.tagName };
  });
  ok('找到了那一行', struct.found === true, JSON.stringify(struct));
  ok('它的父级就是 .list（不是被塞进别的 row 里）', struct.parentIsList === true, JSON.stringify(struct));
  ok('偏好段里没有空 .row（游离残句已摘）', struct.empties === 0, 'empties=' + struct.empties);
  ok('档位与摘要在 row 之外（不是 row 的子节点）',
    (await page.evaluate(() => {
      const lead = document.querySelector('.lead-row');
      return !!lead && !lead.closest('.row');
    })), 'lead 在 .row 里 = 结构又歪了');

  console.log('\n[3] 选「1 小时」：就地改档位，不弹任何层');
  await page.locator('[data-act="lead-pick"][data-min="60"]').click();
  await page.waitForTimeout(200);
  p = await prefs();
  ok('mealLead=60', p.mealLead === 60, JSON.stringify(p));
  ok('副文案跟着改口「提前 1 小时」',
    (await page.locator('.row-sub').filter({ hasText: '提前 1 小时' }).count()) === 1);
  ok('高亮档挪到 60', (await page.locator('.lead-chip.is-on').getAttribute('data-min')) === '60');
  ok('六档全在页面上（没有第二段弹层要展开）', (await page.locator('.lead-chip').count()) === 6);
  ok('页面上没有打开的模态层', (await page.locator('.sheet, .modal, [role="dialog"]').count()) === 0);
  ok('档位与摘要都没变（提前量只管时机，不改投什么）',
    (await page.locator('.meal-todo-row').count()) === want.length);

  console.log('\n[4] 关掉总开关：档位与摘要整块收起，副文案改口');
  await page.locator('[data-act="pref-switch"][data-pref="mealReminderOn"]').click();
  await page.waitForTimeout(200);
  p = await prefs();
  ok('mealReminderOn=false', p.mealReminderOn === false, JSON.stringify(p));
  ok('档位收起', (await page.locator('.lead-chip').count()) === 0);
  ok('摘要也收起（开关关了就不该再宣称要投什么）', (await page.locator('.meal-todo-row').count()) === 0);
  ok('副文案改成「不开待办，只在菜单里看」',
    (await page.locator('.row-sub').filter({ hasText: '不开待办' }).count()) === 1);
  await page.screenshot({ path: path.join(OUT, '04_off.png') });

  console.log('\n[5] 再打开：回到刚选的 1 小时，摘要按数据重新算');
  await page.locator('[data-act="pref-switch"][data-pref="mealReminderOn"]').click();
  await page.waitForTimeout(200);
  ok('档位回来了', (await page.locator('.lead-chip').count()) === 6);
  ok('mealLead 仍是 60（不是跳回默认）', (await prefs()).mealLead === 60);
  const want2 = await expectTodo();
  ok('摘要与重算的一致',
    (await page.locator('.meal-todo-row').allInnerTexts()).join('|') === want2.map((w) => w.text).join('|'),
    JSON.stringify(await page.locator('.meal-todo-row').allInnerTexts()));

  console.log('\n[6] 今天没有定了开饭时间的餐次 → 如实说，不空挂一行');
  await page.evaluate(() => {
    // 造空数据：把今天两餐的开饭时间抹掉（走查要能造状态，不然空分支永远没被断过）
    window.__zaoji.MENUS.forEach((m) => { if (m.isToday) m.time = ''; });
    window.__zaoji.renderScreen();
  });
  await page.waitForTimeout(200);
  const rows = await page.locator('.meal-todo-row');
  ok('只剩一行空态', (await rows.count()) === 1, 'n=' + (await rows.count()));
  ok('空态文案是「今天没有定了开饭时间的餐次」',
    (await rows.first().innerText()).trim() === '今天没有定了开饭时间的餐次',
    await rows.first().innerText());
  await page.screenshot({ path: path.join(OUT, '06_empty.png') });

  console.log('\n[7] 定了时间但没排菜 → 那一行说「还没排菜」');
  await page.evaluate(() => {
    const z = window.__zaoji;
    z.MENUS.forEach((m) => { if (m.isToday) { m.time = '18:30'; m.dishes = []; } });
    z.renderScreen();
  });
  await page.waitForTimeout(200);
  ok('这一行在，且写「还没排菜」',
    (await page.locator('.meal-todo-row').count()) === 1 &&
    (await page.locator('.meal-todo-row').first().innerText()).includes('还没排菜'),
    await page.locator('.meal-todo-row').first().innerText());
  ok('数据侧也确认 dishes=0（不是文案硬编）',
    (await expectTodo())[0].dishes === 0);
  await page.screenshot({ path: path.join(OUT, '07_no_dish.png') });

  console.log('\n[8] 提前量六档都在，且档位文本与 leadLabel 规则一致');
  await go('08_reload_chips');
  const chips = await page.locator('.lead-chip').allInnerTexts();
  ok('六档 = 30/45/60/90/120/180 的文本',
    chips.join('|') === [30, 45, 60, 90, 120, 180].map(leadLabel).join('|'), chips.join(' | '));

  console.log('\n[9] 刷新 = 真重启：原型不假装持久（App 才落 local_pref）');
  p = await prefs();
  ok('回到默认 90 分钟', p.mealLead === 90 && p.mealReminderOn === true, JSON.stringify(p));
  ok('刷新后摘要回到演示数据（3 道菜那道餐）',
    (await expectTodo())[0].dishes === 3, JSON.stringify(await expectTodo()));

  console.log('\n[10] 布局与控制台');
  const overflow = await page.evaluate(() => {
    const el = document.querySelector('#phone .screen');
    return el ? el.scrollWidth - el.clientWidth : -1;
  });
  ok('我的屏不横向溢出', overflow <= 0, 'overflow=' + overflow);
  ok('零 JS 错误', errs.length === 0, errs.slice(0, 3).join(' | '));
  ok('除 favicon 外没有 404',
    net404.filter((u) => !/favicon/.test(u)).length === 0,
    '404=' + (net404.length ? net404.join(' | ') : 'none'));
  ok('favicon 的 404 单独计数（它会被记成资源加载失败，别和 JS 错误混成一条）',
    net404.every((u) => /favicon/.test(u)), 'favicon404=' + net404.length);

  await browser.close();
  srv.close();
  console.log('\n截图目录：' + OUT);
  console.log(fails === 0 ? '全部 PASS' : `有 ${fails} 条 FAIL`);
  process.exit(fails === 0 ? 0 : 1);
})();
