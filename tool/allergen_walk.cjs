// R40 · 成员与过敏原的逐屏走查（跑真产物，不是 widget 测试）。
//
// widget 测试证明"命中了就挂标签"；这一遍证明的是**眼睛看得见的东西**：
// 斜条纹在深色主题下压不压得住、横幅那句"谁对什么过敏"读不读得清、
// 建档弹层在小屏上会不会把保存按钮顶出屏幕。
//
// 用法：node tool/allergen_walk.cjs [主题，逗号分隔]
//   前提：先出 app/build/web（powershell -ExecutionPolicy Bypass -File app/tool/build_web.ps1）
//
// ★ 三条 Flutter Web 自动化的硬约定（每一条都在这轮里真栽过一次）：
//   1) 必须 `?a11y=1` 把语义树挂进 DOM，而且要用**真实鼠标**点在语义节点坐标上；
//      合成 PointerEvent 只会落到画布，框架收不到。
//   2) 同一段文案会挂在**好几层祖先节点**上（祖先是整屏宽），必须取面积最小那块。
//   3) **全程一次加载、不刷新**：换页走底部标签栏。刷新会撞另一码事
//      （Web 端"刚写完就刷新"有丢写窗口，见交接文档 §六），别让它干扰这一屏的判定。
const http = require('http');
const fs = require('fs');
const path = require('path');
const {chromium} = require('playwright-core');

const ROOT = path.resolve(__dirname, '..');
const WEB = path.join(ROOT, 'app', 'build', 'web');
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const OUT = path.join(ROOT, 'dist', 'allergen_previews');
const THEMES = (process.argv[2] || 'indigo,night,shihong,rouge,stone').split(',');
const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.woff2': 'font/woff2',
  '.wasm': 'application/wasm', '.svg': 'image/svg+xml', '.json': 'application/json',
  '.otf': 'font/otf', '.bin': 'application/octet-stream', '.map': 'text/plain',
};

if (!fs.existsSync(path.join(WEB, 'index.html'))) {
  console.log('没有 app/build/web 产物，先跑 app/tool/build_web.ps1');
  process.exit(1);
}
fs.mkdirSync(OUT, {recursive: true});

const srv = http.createServer((req, res) => {
  const rel = decodeURIComponent(req.url.split('?')[0]);
  const abs = path.join(WEB, rel === '/' ? '/index.html' : rel);
  if (!abs.startsWith(WEB) || !fs.existsSync(abs) || fs.statSync(abs).isDirectory()) {
    res.writeHead(404); res.end('nope'); return;
  }
  res.writeHead(200, {'Content-Type': MIME[path.extname(abs).toLowerCase()] || 'application/octet-stream'});
  fs.createReadStream(abs).pipe(res);
});

srv.listen(0, '127.0.0.1', async () => {
  const base = 'http://127.0.0.1:' + srv.address().port + '/index.html';
  const browser = await chromium.launch({executablePath: CHROME, args: ['--no-sandbox']});
  const errs = [];
  let failed = 0;

  for (const theme of THEMES) {
    const ctx = await browser.newContext({viewport: {width: 430, height: 930}, deviceScaleFactor: 2});
    const page = await ctx.newPage();
    page.on('pageerror', e => errs.push(theme + ' pageerror: ' + String(e).slice(0, 140)));
    page.on('console', m => {
      const t = m.text();
      if (m.type() === 'error' && !/404|\/api\/sync|Failed to load resource/.test(t)) {
        errs.push(theme + ' console: ' + t.slice(0, 140));
      }
    });

    const txt = () => page.evaluate(() => (document.body.innerText || '').replace(/\s+/g, ' '));
    const check = (label, cond, note) => {
      console.log((cond ? '  ok   ' : '  FAIL ') + label + (cond || !note ? '' : '  ⟵ ' + note));
      if (!cond) failed++;
    };
    const shot = (name) => page.screenshot({path: path.join(OUT, theme + '__' + name + '.png')});

    const rectOfText = (t, q, sel) => page.evaluate(([t, q, sel]) => {
      const hits = Array.from(document.querySelectorAll(sel))
        .filter(e => (e.textContent || '').trim())
        .filter(e => q ? e.textContent.trim().includes(t) : e.textContent.trim() === t)
        .map(e => e.getBoundingClientRect())
        .sort((a, b) => (a.width * a.height) - (b.width * b.height));
      return hits.length ? {x: hits[0].x + hits[0].width / 2, y: hits[0].y + hits[0].height / 2} : null;
    }, [t, q, sel || 'flt-semantics,[role=button],[role=checkbox],[role=group]']);

    const tap = async (label, {partial = false} = {}) => {
      const box = await rectOfText(label, partial);
      if (!box) { console.log('  ·    没找到语义节点：' + label); return false; }
      await page.mouse.click(box.x, box.y);
      await page.waitForTimeout(800);
      return true;
    };
    // 文本喂进输入框：真实鼠标聚焦 + insertText（等价输入法提交）
    const type = async (ariaContains, text) => {
      const box = await page.evaluate((t) => {
        const i = Array.from(document.querySelectorAll('input,textarea'))
          .find(e => (e.getAttribute('aria-label') || '').includes(t));
        if (!i) return null;
        const r = i.getBoundingClientRect();
        return {x: r.x + r.width / 2, y: r.y + r.height / 2, right: r.right};
      }, ariaContains);
      if (!box) { console.log('  ·    没找到输入框：' + ariaContains); return null; }
      for (let i = 0; i < 3; i++) {
        await page.mouse.click(box.x, box.y);
        await page.waitForTimeout(350);
        const focused = await page.evaluate((t) => {
          const a = document.activeElement;
          return !!a && (a.getAttribute('aria-label') || '').includes(t);
        }, ariaContains);
        if (focused) break;
      }
      await page.keyboard.insertText(text);
      await page.waitForTimeout(500);
      return box;
    };
    // 词框右边那枚"加词"图标按钮：语义里没有文案，只能按几何位置找
    const tapAddWord = async (inputBox) => {
      const ok = await page.evaluate(([b]) => {
        const cands = Array.from(document.querySelectorAll('[role=button],flt-semantics'))
          .map(e => ({e, r: e.getBoundingClientRect()}))
          .filter(({e, r}) => !(e.textContent || '').trim()
            && Math.abs(r.y + r.height / 2 - b.y) < 30 && r.x > b.right - 6 && r.width > 8 && r.width < 120);
        cands.sort((a, c) => (a.r.width * a.r.height) - (c.r.width * c.r.height));
        if (!cands.length) return false;
        window.__pt = {x: cands[0].r.x + cands[0].r.width / 2, y: cands[0].r.y + cands[0].r.height / 2};
        return true;
      }, [inputBox]);
      if (!ok) { console.log('  ·    没找到「加词」按钮'); return false; }
      const pt = await page.evaluate(() => window.__pt);
      await page.mouse.click(pt.x, pt.y);
      await page.waitForTimeout(600);
      return true;
    };

    console.log('\n──── 主题 ' + theme + ' ────');
    await page.goto(base + '?a11y=1&theme=' + theme + '#/members', {waitUntil: 'load'});
    await page.waitForFunction(() => (document.body.innerText || '').length > 12, null, {timeout: 60000}).catch(() => {});
    await page.waitForTimeout(4000);

    /* 1 · 成员页空态 */
    let t = await txt();
    check('成员页能深链直达', t.includes('家庭成员与过敏原'));
    check('没有成员时不塞假家人，只给一个入口', t.includes('还没有添加家人'));
    check('没人时不摆"警示设置"（开关都是空谈）', !t.includes('警示设置'));
    await shot('1-members-empty');

    /* 2 · 建档弹层 */
    await tap('添加第一位家人');
    await page.waitForTimeout(1500);
    t = await txt();
    check('弹层打开（标题「添加家人」）', t.includes('添加家人'));
    const nameBox = await type('称呼', '小宝');
    check('称呼真的进了框架（头像预览跟着变）', !!nameBox && (await txt()).includes('小'));
    const wordBox = await type('如 虾', '虾');
    check('过敏词框可寻址', !!wordBox);
    // 加词走输入框的回车（onSubmitted 就是加词）：那枚"+"图标按钮在语义里
    // 没有文案，只能按几何找，五套主题下弹层滚动位置不同 → 回车比它稳
    await page.keyboard.press('Enter');
    await page.waitForTimeout(700);
    t = await txt();
    check('加进去的词回显在「已填过敏」里', t.includes('已填过敏'));
    await shot('2-member-sheet');
    await tap('保存');
    await page.waitForTimeout(1500);
    if ((await txt()).includes('添加家人')) { await tap('保存'); await page.waitForTimeout(1500); }
    t = await txt();
    check('保存后卡列表出现「小宝」', t.includes('小宝'));
    check('顶部冲突汇总数出含虾的菜', /道菜和家里的成员冲突/.test(t));
    check('冲突汇总写明谁、对什么、哪几道菜', /对\s*「虾」\s*过敏/.test(t) && t.includes('蒜蓉粉丝蒸虾'),
      (/小宝.{0,60}/.exec(t) || [''])[0]);
    check('有人之后才摆出「警示设置」这一组', t.includes('警示设置'));
    await shot('3-member-card');

    /* 3 · 菜谱详情：横幅 + 命中食材行（不刷新，走底部标签栏过去） */
    // 成员页是被 push 上去的独立页，没有底部标签栏——先返回外壳再换 tab
    await tap('Back');
    await page.waitForTimeout(1500);

    /* 2.5 · 先排一餐：加菜单的拦截要有个目标餐次 */
    await tap('菜单', {partial: true});
    await page.waitForTimeout(1500);
    await tap('新建餐次', {partial: true}) || await tap('排第一餐', {partial: true});
    await page.waitForTimeout(1800);
    if (!await tap('晚餐', {partial: true})) {
      // 弹层里那排餐次 chip 可能还在视口外：滚到它再点
      await page.evaluate(() => {
        const el = Array.from(document.querySelectorAll('[role=button],[role=checkbox]'))
          .find(e => (e.textContent || '').trim().includes('晚餐'));
        if (el) el.scrollIntoView({block: 'center'});
      });
      await page.waitForTimeout(700);
      await tap('晚餐', {partial: true});
    }
    await tap('就这么安排', {partial: true}) || await tap('保存', {partial: true});
    await page.waitForTimeout(1800);
    t = await txt();
    check('先排好了一餐（菜单页有晚餐）', t.includes('晚餐'), t.slice(0, 60));

    await tap('菜谱', {partial: true});
    await page.waitForTimeout(1800);
    const search = await rectOfText('', false, '[role=textfield]')
      || await page.evaluate(() => {
        const f = Array.from(document.querySelectorAll('flt-semantics,[role=textfield]'))
          .map(e => ({e, r: e.getBoundingClientRect()}))
          .filter(({r}) => r.width > 200 && r.height > 14 && r.height < 60 && r.y < 200)
          .sort((a, b) => (a.r.width * a.r.height) - (b.r.width * b.r.height))[0];
        return f ? {x: f.r.x + f.r.width / 2, y: f.r.y + f.r.height / 2} : null;
      });
    check('搜索框找得到', !!search);
    await page.mouse.click(search.x, search.y);
    await page.waitForTimeout(500);
    await page.keyboard.insertText('蒜蓉粉丝蒸虾');
    await page.waitForTimeout(1800);
    // 卡片名不在语义树里（整张卡合成一个 group），按几何点第一张
    const card = await page.evaluate(() => {
      const c = Array.from(document.querySelectorAll('[role=group],flt-semantics'))
        .map(e => ({e, r: e.getBoundingClientRect()}))
        .filter(({r}) => r.width > 120 && r.width < 300 && r.height > 120 && r.y > 150)
        .sort((a, b) => a.r.y - b.r.y)[0];
      return c ? {x: c.r.x + c.r.width / 2, y: c.r.y + c.r.height / 2} : null;
    });
    check('搜索后筛出一张卡片', !!card);
    if (!card) { await shot('4-no-card'); await ctx.close(); continue; }
    await page.mouse.click(card.x, card.y);
    await page.waitForTimeout(2000);
    t = await txt();
    check('进到了那道菜的详情', t.includes('蒜蓉粉丝蒸虾'));
    check('详情横幅「这道菜含过敏原，注意分餐」', t.includes('这道菜含过敏原，注意分餐'));
    check('横幅落到具体食材（基围虾）', /对「虾」过敏/.test(t) && t.includes('基围虾'));
    check('食材行标注「小宝 过敏 · 虾」', t.includes('小宝 过敏 · 虾'));
    check('没命中的食材不被连带标注', !t.includes('龙口粉丝 小宝'));
    await shot('4-recipe-detail');

    /* 4 · 排菜单拦截 */
    await tap('加入菜单');
    await page.waitForTimeout(1000);
    await tap('晚餐', {partial: true});
    await page.waitForTimeout(1400);
    t = await txt();
    check('加菜单先问一次（确认框带菜名）', t.includes('蒜蓉粉丝蒸虾 含过敏原'), t.slice(0, 70));
    await shot('5-confirm-add');
    await tap('仍然加入');
    await page.waitForTimeout(1400);
    check('确认之后确认框收干净', !(await txt()).includes('仍然加入'));

    await ctx.close();
  }

  await browser.close();
  srv.close();
  console.log('\n产物在 ' + OUT);
  if (errs.length) console.log('控制台错误 ' + errs.length + ' 条：\n  ' + errs.slice(0, 6).join('\n  '));
  console.log(failed ? '\n走查失败 ' + failed + ' 项' : '\n走查全部通过');
  process.exit(failed ? 1 : 0);
});
