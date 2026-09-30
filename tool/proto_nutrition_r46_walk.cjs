// R46 · 原型「热量手动填写 / AI 结果二次编辑」逐屏走查（FR-AI-69~74）。
//
// 为什么跑这一遍：这条需求是「数据层早就备好、只差入口」的那一类，最容易写成
// 「按钮在、点了没落地」。所以这一遍断言的是**眼睛看得见的因果**：
// 未配置 AI 也得有手填入口、填进去的数当场变、份数一改每份就跟着折算、
// 来源标记从「AI 估算」翻成「手动填写」、AI 原值不丢、超限要确认一次才落。
// 原型是实现的规格（UI 铁律：先改原型再动实现），这一遍过了才去动 Flutter。
//
// 用法：node tool/proto_nutrition_r46_walk.cjs [--headed]
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const ROOT = path.resolve(__dirname, '..');
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 8796;
const OUT = path.join(ROOT, 'dist', 'nutrition_r46_previews');
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
  const browser = await chromium.launch({
    executablePath: CHROME,
    args: ['--no-sandbox'],
    headless: process.argv.indexOf('--headed') < 0,
  });
  const page = await browser.newPage({ viewport: { width: 430, height: 900 } });
  const errs = [];
  page.on('console', (m) => {
    if (m.type() !== 'error') return;
    const at = (m.location() && m.location().url) || '';
    if (/favicon/i.test(at)) return;
    errs.push(m.text().slice(0, 120));
  });
  page.on('pageerror', (e) => errs.push('pageerror: ' + String(e).slice(0, 140)));

  const goto = async (hash, query) => {
    // ★ 必须带一个每次都不一样的 query：只变 hash 的 page.goto 是**同文档导航**，
    //   不会重载页面，上一场景的状态（包括有没有配 AI）会被悄悄带进下一场景——
    //   这条在第一版里把「用 AI 重算」那颗按钮的存在性判断整个骗过去了。
    const bump = 'walk' + Date.now() + Math.random().toString(36).slice(2, 6);
    const extra = query ? (query.replace(/^\?/, '&') || '') : '';
    await page.goto(`http://127.0.0.1:${PORT}/zaoji-prototype.html?_r=${bump}${extra}${hash}`, { waitUntil: 'load' });
    await page.waitForTimeout(900);
  };
  const txt = (sel) => page.$eval(sel, (e) => e.textContent.replace(/\s+/g, ' ').trim()).catch(() => null);
  const has = (sel) => page.locator(sel).count().then((n) => n > 0);
  const shot = (n) => page.screenshot({ path: path.join(OUT, n + '.png'), fullPage: false });

  /* ── 场景 1：未配置 AI、没算过 → 手填入口必须在（FR-AI-69），且不许有灰占位数字（FR-AI-27）── */
  console.log('\n[1] 未配置 AI + 未算过（r2）');
  await goto('#screen=recipe-detail&id=r2');
  ok('热量入口区存在', await has('.nutri-entries'));
  ok('有「估算热量」占位入口（未配置徽记）', await has('.nutri-entries [data-act="nutri-calc"]'),
    await txt('.nutri-entries [data-act="nutri-calc"]'));
  ok('有「手动填写热量」入口', await has('.nutri-entries [data-act="nutri-edit"]'),
    await txt('.nutri-entries [data-act="nutri-edit"]'));
  ok('未配置徽记在位', await has('.nutri-entries .ai-mini-lock'));
  ok('没有热量卡片（未算过不画占位）', !(await has('.nutri')));
  await shot('1_no_ai_entries');

  /* ── 场景 2：手填弹层——预览随行输入即时折算（FR-AI-72）── */
  console.log('\n[2] 手填弹层与份数折算');
  await page.click('.nutri-entries [data-act="nutri-edit"]');
  await page.waitForTimeout(300);
  ok('弹层打开', await has('.sheet'));
  ok('有即时预览行', await has('.nutri-preview'), await txt('.nutri-preview'));
  for (const k of ['per', 'total', 'serv', 'p', 'f', 'c']) {
    ok(`输入框 ${k} 在位`, await has(`[data-nf="${k}"]`));
  }
  await page.fill('[data-nf="per"]', '150');
  await page.waitForTimeout(250);
  const pv1 = await txt('.nutri-preview');
  ok('填每份 150 → 整锅自动 600（按 4 人份）', /整锅约 600/.test(pv1 || ''), pv1);
  await page.fill('[data-nf="serv"]', '6');
  await page.waitForTimeout(250);
  const pv2 = await txt('.nutri-preview');
  ok('份数 4→6 → 整锅不变、每份重算成 100', /每份 ≈ 100/.test(pv2 || '') && /整锅约 600/.test(pv2 || ''), pv2);
  await page.fill('[data-nf="total"]', '720');
  await page.waitForTimeout(250);
  const pv3 = await txt('.nutri-preview');
  ok('改整锅 720 → 每份按 6 人份重算成 120', /每份 ≈ 120/.test(pv3 || ''), pv3);
  await shot('2_form_recalc');

  /* ── 场景 3：超限要**真二次确认**（FR-AI-74）── */
  console.log('\n[3] 数值校验与二次确认');
  await page.fill('[data-nf="per"]', '');
  await page.click('[data-act="nutri-edit-save"]');
  await page.waitForTimeout(250);
  ok('每份留空 → 保存被挡，给原话', /得填个正数/.test((await txt('.toast-wrap')) || ''), await txt('.toast-wrap'));
  ok('挡下之后弹层还在（数据没丢）', await has('[data-nf="serv"]'));

  await page.fill('[data-nf="per"]', '25000');
  await page.waitForTimeout(250);
  ok('只是填上超限值 → 先不拦（还没点保存）', !(await has('.confirm-inline')));
  await page.click('[data-act="nutri-edit-save"]');
  await page.waitForTimeout(300);
  ok('点保存 → 就地出确认条，**这一下不落库**', (await has('.confirm-inline')) && (await has('.sheet')),
    await txt('.confirm-inline'));
  await shot('3_over_limit_confirm');

  await page.fill('[data-nf="per"]', '300');
  await page.waitForTimeout(250);
  ok('数值改回正常范围 → 确认条自己收回', !(await has('.confirm-inline')));

  await page.fill('[data-nf="per"]', '25000');
  await page.waitForTimeout(250);
  await page.click('[data-act="nutri-edit-save"]');   // 第一次：只确认
  await page.waitForTimeout(250);
  await page.click('[data-act="nutri-edit-save"]');   // 第二次：真落
  await page.waitForTimeout(350);
  ok('确认之后再点 → 落库、弹层收', !(await has('.sheet')) && (await has('.nutri.is-manual')));
  ok('落的是确认过的那个值', /25000/.test((await txt('.nutri-hero')) || ''), await txt('.nutri-hero'));

  /* ── 场景 4：保存真落地 + 来源翻转 + 免责行退场（FR-AI-70 / Q4）── */
  console.log('\n[4] 保存落数据');
  ok('上一步已存成手动态卡', await has('.nutri.is-manual'));
  await page.click('.nutri-foot [data-act="nutri-edit"]');
  await page.waitForTimeout(300);
  ok('已有数据时「手动改」在脚上（第二枚按钮）', await has('[data-nf="per"]'));
  await page.fill('[data-nf="per"]', '120');
  await page.fill('[data-nf="serv"]', '6');
  await page.waitForTimeout(250);
  await page.click('[data-act="nutri-edit-save"]');
  await page.waitForTimeout(350);
  ok('弹层已关', !(await has('.sheet')));
  ok('卡片出现且是手动态', await has('.nutri.is-manual'));
  const chip = await txt('.nutri .nutri-head .ai-chip');
  ok('来源标记翻成「手动填写」', /手动填写/.test(chip || ''), chip);
  const hero = await txt('.nutri-hero');
  ok('数值是填进去的那份（≈120 / 整锅 720）', /≈ 120/.test(hero || '') && /720/.test(hero || ''), hero);
  ok('手填态不挂 AI 免责句', !/不能用于医疗或饮食处方/.test((await txt('.nutri')) || ''));
  ok('脚上有三枚按钮（看依据/手动改/用 AI 重算）', (await page.locator('.nutri-foot .btn').count()) === 3,
    String(await page.locator('.nutri-foot .btn').count()));
  ok('toast 写明来源', /来源：手动填写/.test((await txt('.toast-wrap')) || ''), await txt('.toast-wrap'));
  await shot('4_saved_manual');

  /* ── 场景 5：列表徽标跟着来源换牌子（**站内返回**，别 reload——reload 会清掉刚才存的手填态）
     选择器一律锁 #phone：原型是单文件，总览故事板里也画了一份卡片，那些副本 rect 是 0×0。
     另外详情页上 #tabbar 是 `display:none`（子页有返回头，不带底栏），回列表要点返回而不是点标签。── */
  console.log('\n[5] 列表徽标');
  ok('详情页不带底栏（与实现一致）', (await page.$eval('#tabbar', (e) => getComputedStyle(e).display)) === 'none');
  await page.click('#phone [data-act="back"]');
  await page.waitForTimeout(400);
  const titles = await page.$$eval('#phone .art-kcal', (els) => els.map((e) => e.getAttribute('title')));
  ok('手填那道菜的徽标 title 是「手动填写」', titles.some((t) => /手动填写/.test(t || '')), titles.join(' / '));
  ok('AI 那道菜的徽标仍写「AI 估算，仅供参考」', titles.some((t) => /AI 估算/.test(t || '')));
  await shot('5_list_badge_manual');

  /* ── 场景 6：AI 原值留对照（FR-AI-71，用 r1 = 已有 AI 数据的菜）── */
  console.log('\n[6] AI 结果二次编辑，原值不丢');
  await page.click('#phone [data-act="nav"][data-screen="recipe-detail"][data-id="r1"]');
  await page.waitForTimeout(400);
  ok('AI 态卡片在', await has('.nutri'));
  ok('AI 态仍挂免责句', /不能用于医疗或饮食处方/.test((await txt('.nutri')) || ''));
  await page.click('.nutri-foot [data-act="nutri-edit"]');
  await page.waitForTimeout(300);
  ok('弹层提示 AI 原值会留在依据里', /AI 原估 每份 186/.test((await txt('.sheet')) || ''));
  await page.fill('[data-nf="per"]', '95');
  await page.waitForTimeout(250);
  await page.click('[data-act="nutri-edit-save"]');
  await page.waitForTimeout(350);
  ok('改成手动态', await has('.nutri.is-manual'));
  const echo = await txt('.nutri-ai-echo');
  ok('卡上带出「AI 原估 186」', /AI 原估 186/.test(echo || ''), echo);
  await page.click('.nutri-foot [data-act="nutri-basis"]');
  await page.waitForTimeout(300);
  const basis = (await txt('.sheet')) || '';
  ok('依据弹层两段都在', /AI 原估 · 每份/.test(basis) && /现在生效 · 每份（手填）/.test(basis));
  ok('逐食材贡献没丢（手改不该抹掉依据）', /鸡蛋|嫩豆腐/.test(basis), basis.slice(0, 40));
  await shot('6_ai_echo_basis');
  await page.click('[data-act="sheet-close"]');
  await page.waitForTimeout(250);

  /* ── 场景 7：配好 AI 后能重算覆盖回 AI 口径（FR-AI-73）── */
  console.log('\n[7] 用 AI 重算覆盖回来');
  // 注意：`ai=1` 是 **hash 参数**（原型深链的写法是 `#screen=...&ai=1`），
  // 拼成 `?ai=1#...` 原型读不到，会一直停在「未配置」态——这是工装的错，不是原型的错。
  await goto('#screen=recipe-detail&id=r1&ai=1');
  await page.click('.nutri-foot [data-act="nutri-edit"]');
  await page.waitForTimeout(300);
  await page.fill('[data-nf="per"]', '88');
  await page.waitForTimeout(250);
  await page.click('[data-act="nutri-edit-save"]');
  await page.waitForTimeout(350);
  ok('先手改成 88', /88/.test((await txt('.nutri-hero')) || ''));
  const recalc = await page.$('.nutri-foot [data-act="nutri-calc"]');
  ok('手动态出现「用 AI 重算」按钮', !!recalc);
  await page.click('.nutri-foot [data-act="nutri-calc"]');
  await page.waitForTimeout(2200);
  const after = await txt('.nutri-head .ai-chip');
  ok('重算后来源回到「AI 估算」', /AI 估算/.test(after || ''), after);
  ok('重算后免责句回来', /不能用于医疗或饮食处方/.test((await txt('.nutri')) || ''));
  await shot('7_ai_recalc_back');

  /* ── 场景 8：窄屏与横屏不溢出（原型的 hero 行有数字 + 单位 + echo 三段共处）── */
  console.log('\n[8] 布局不溢出');
  await goto('#screen=recipe-detail&id=r1');
  const of1 = await page.$eval('.nutri-hero', (e) => e.scrollWidth - e.clientWidth);
  ok('430 宽下热量主行不溢出', of1 <= 1, 'overflow=' + of1);
  await page.setViewportSize({ width: 844, height: 390 });
  await goto('#land=1&screen=recipe-detail&id=r1');
  const of2 = await page.$eval('.nutri-hero', (e) => e.scrollWidth - e.clientWidth).catch(() => -99);
  ok('横屏下也不溢出', of2 <= 1, 'overflow=' + of2);
  await shot('8_landscape');
  await page.setViewportSize({ width: 430, height: 900 });

  /* ── 控制台 ── */
  console.log('\n[9] 控制台');
  ok('零 JS 错误', errs.length === 0, errs.slice(0, 3).join(' | '));

  console.log(fails ? `\n合计 ${fails} 条 FAIL` : '\n全部 PASS');
  await browser.close();
  srv.close();
  process.exit(fails ? 1 : 0);
})().catch((e) => {
  console.error('工装本身崩了：', String(e).slice(0, 300));
  if (typeof errs !== 'undefined' && errs.length) console.error('页面错误：\n  ' + errs.slice(0, 8).join('\n  '));
  process.exit(2);
});
