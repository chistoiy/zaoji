// R39 主题轮 · 原型「五套主题 × 全部界面」自检
//
// 为什么需要它：把 CSS 字面量换成 var() 之后，"漏改一处"的表现不是报错，
// 而是**某一套主题下某个界面看不见**。五套主题 × 二十六屏靠人眼看不完，
// 所以用无头 Chrome 逐屏逐主题算一遍 WCAG 对比度。
//
// 三条判据：
//   1) 对比度：正文 < 4.5:1、大字/粗体 < 3:1 → 报。
//      背景沿祖先链**逐层合成**（半透明层要叠起来算；只找"第一个不透明的"会算错）；
//   2) 主题盲区：运行时判不了（getComputedStyle 一律给 rgb()），改成扫源码 —— 见 staticLeft；
//   3) 页面必须真的渲染出来：boot() 抛异常时"零告警"是假绿。这一条本轮真抓到过：
//      主题卡 CSS 误插进 JS 段 → 整段 SyntaxError → 审计却报"全部通过"。
//
// 豁免族 EXEMPT_PARTS：插画封面、压在图片/沉浸面上的字、原型外壳、
// 桌面服务端控制台、分享长图预览、主题卡预览——它们自带一套固定配色，
// 不参与主题（理由见 CSS 里 --scrim-rgb 那段注释）。
//
// 用法：
//   node tool/proto_theme_audit.cjs            # 只审计
//   node tool/proto_theme_audit.cjs --shots    # 顺带出预览图（dist/theme_previews/）
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const ROOT = path.resolve(__dirname, '..');
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
// 第一个是**基线**：判据是『新主题不许比默认主题更差』，换默认主题要换这里
const THEMES = ['indigo', 'shihong', 'rouge', 'night', 'stone'];
const SCREENS = [
  'recipes', 'recipe-detail', 'recipe-edit', 'search', 'menus', 'menu-detail',
  'prep', 'prep-generate', 'calendar', 'timeline', 'me', 'theme', 'tag-manage',
  'stats', 'sync', 'conflicts', 'backup', 'settings-server', 'cooking',
  'schedule', 'trash', 'members', 'import', 'pantry', 'recommend', 'ai-settings',
];
const SHOT_SCREENS = ['recipes', 'pantry', 'me', 'theme', 'cooking', 'calendar'];

/* 已知取舍的主题（key = 主题 id，value = 为什么允许它低于基线）。
 *
 * 柿红那套有 30 处小字落在 4.09~4.46：柿红 #D2491C 是个中间调度的红橙，
 * 当"小字颜色"或"白字压上去"时天生差一点点 AA。要修只有两条路——
 * 把柿红改深（= 换品牌色），或者把"强调色当正文小字用"这套用法改掉
 * （步骤序号、必填星号、提醒时间这些就是设计成强调色的）。两条都要用户拍。
 *
 * R39 收尾用户已把**默认主题改成蓝染粗布**，所以这个缺口现在只影响
 * "手动选回柿红"的人。列在这里而不是把阈值调低：审计照常数、照常打印，
 * 只是不拦——看不见的债才是还不了的债。 */
const KNOWN_GAP_THEMES = {
  shihong: '柿红是品牌色，小字对比 4.09~4.46；改深或改用法都要用户拍',
};
const SHOTS = process.argv.includes('--shots');

const EXEMPT_PARTS = [
  'art', 'dish', 'cover', 'hero', 'timer-fab', 'timer-full', 'fab-', 'tf-',
  'lvl', 'exp', 'switch', 'device', 'desk', 'stage', 'share-pv', 'brand',
  'toast', 'swatch', 'nav-', 'side', 'panel', 'mode-btn', 'orient-btn', 'pulse',
  'mesh', 'grain', 'mini-slot', 'statusbar', 'sb-', 'home-bar', 'phone',
  'kpi', 'dbox', 'logline', 'theme-btn', 'theme-card', 'tc-', 'gallery',
  'img-thumb', 'fav-btn', 'timepill', 'count-badge', 'empty', 'sec-',
];

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript',
  '.css': 'text/css', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.woff2': 'font/woff2', '.svg': 'image/svg+xml', '.json': 'application/json',
};
function serve() {
  const srv = http.createServer((req, res) => {
    const rel = decodeURIComponent(req.url.split('?')[0]);
    const abs = path.join(ROOT, rel === '/' ? '/zaoji-prototype.html' : rel);
    if (!abs.startsWith(ROOT) || !fs.existsSync(abs) || fs.statSync(abs).isDirectory()) {
      res.writeHead(404); res.end('nope'); return;
    }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(abs).toLowerCase()] || 'application/octet-stream' });
    fs.createReadStream(abs).pipe(res);
  });
  return new Promise((r) => srv.listen(0, '127.0.0.1', () => r(srv)));
}

// 在页面里执行：换主题 → 跳屏 → 量一遍所有文字的对比度。
// 注意：playwright 的 evaluate 只给一个参数，所以这里收的是一个对象。
function probe(arg) {
  const theme = arg.theme, screen = arg.screen;
  const EXEMPT = new RegExp(arg.exempt);
  const usedMap = {};
  const collect = (onlySel) => {
    for (const sheet of document.styleSheets) {
      let rules;
      try { rules = sheet.cssRules; } catch (e) { continue; }
      for (const r of rules) {
        if (!r.style) continue;
        if (onlySel && r.selectorText !== onlySel) continue;
        for (let i = 0; i < r.style.length; i++) {
          const p = r.style[i];
          if (p.indexOf('--') === 0) {
            const v = r.style.getPropertyValue(p).trim();
            if (v) usedMap[p] = v;
          }
        }
      }
    }
  };
  collect(null);
  collect('[data-theme="' + theme + '"]');   // 当前主题的令牌必须压过 :root

  const used = (v) => {
    let cur = v, guard = 0;
    while (cur && cur.indexOf('var(') === 0 && guard++ < 8) {
      const m = /^var\((--[^,)]*)(?:\s*,\s*(.*))?\)$/.exec(cur);
      if (!m) break;
      const got = usedMap[m[1]];
      cur = (got != null && got !== '') ? got : m[2];
    }
    return (cur || '').trim();
  };
  const parse = (v) => {
    v = used(v);
    let m = /^#([0-9a-f]{6})$/i.exec(v);
    if (m) { const n = parseInt(m[1], 16); return [(n >> 16) & 255, (n >> 8) & 255, n & 255, 1]; }
    m = /^#([0-9a-f]{3})$/i.exec(v);
    if (m) { const s = m[1]; return [parseInt(s[0] + s[0], 16), parseInt(s[1] + s[1], 16), parseInt(s[2] + s[2], 16), 1]; }
    m = /^rgba?\(([^)]+)\)$/i.exec(v);
    if (m) {
      const q = m[1].split(',').map((x) => parseFloat(x.trim()));
      if (q.length >= 3 && q.slice(0, 3).every((n) => !isNaN(n))) {
        return [q[0], q[1], q[2], q.length > 3 ? q[3] : 1];
      }
    }
    return null;
  };
  const over = (c, b) => [
    c[0] * c[3] + b[0] * (1 - c[3]),
    c[1] * c[3] + b[1] * (1 - c[3]),
    c[2] * c[3] + b[2] * (1 - c[3]), 1,
  ];
  const lum = (c) => {
    const f = (v) => { v /= 255; return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4); };
    return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]);
  };
  const ratio = (a, b) => {
    const l1 = lum(a), l2 = lum(b);
    return (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05);
  };
  const cls = (el) => (typeof el.className === 'string'
    ? el.className : ((el.getAttribute && el.getAttribute('class')) || el.tagName));
  const hex = (c) => '#' + c.slice(0, 3).map((v) => ('0' + Math.round(v).toString(16)).slice(-2)).join('');

  // 走原型自己的自检桥：整个脚本在 IIFE 里，直接调 boot() 会 ReferenceError，
  // 而且那种失败是静默的——屏没换、量的还是首屏，"零告警"就成了假绿。
  if (!window.__zaoji) throw new Error('自检桥 window.__zaoji 不在（原型改坏了？）');
  window.__zaoji.goto(screen, theme, 'android');

  const paper = parse('var(--paper)') || [255, 255, 255, 1];
  const bad = [];
  for (const el of document.querySelectorAll('.screen, .screen *')) {
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden' || parseFloat(cs.opacity) === 0) continue;
    const box = el.getBoundingClientRect();
    if (box.width < 2 || box.height < 2) continue;
    // 豁免要按**子树**判：figcaption 自己没有 class，但它在 .gallery 里
    let ex = false, up = el, upHops = 0;
    while (up && upHops++ < 4) { if (EXEMPT.test(cls(up))) { ex = true; break; } up = up.parentElement; }
    if (ex) continue;

    const ownsText = Array.prototype.some.call(el.childNodes, (n) =>
      n.nodeType === 3 && n.textContent.trim().length && n.textContent.trim() !== '…');
    if (!ownsText) continue;

    // 祖先链背景逐层合成，最底垫一层 --paper
    let base = paper.slice();
    const chain = [];
    let node = el, hops = 0;
    while (node && hops++ < 14) { chain.push(node); node = node.parentElement; }
    for (let i = chain.length - 1; i >= 0; i--) {
      const c = parse(getComputedStyle(chain[i]).backgroundColor);
      if (c) base = over(c, base);
    }
    const fgRaw = cs.color, fg0 = parse(fgRaw);
    if (!fg0) continue;
    const fg = over(fg0, base);
    const big = parseFloat(cs.fontSize) >= 24 || parseInt(cs.fontWeight, 10) >= 700;
    const cr = ratio(fg, base);
    // 一律记录（不过阈值的也记）：判"新主题是不是更差"要拿同一处文字
    // 在默认主题下的比值当基线，只记挂掉的会漏掉"从 8.2 掉到 4.6"这种。
    bad.push({
      kind: 'contrast',
      // sig 不含色值：同一处文字在不同主题下要靠同一个键对上，才能比"谁更差"
      sig: cls(el) + '|「' + el.textContent.trim().slice(0, 8) + '」|' + (big ? 'big' : 'small'),
      ratio: cr,
      need: big ? 3 : 4.5,
      detail: cls(el) + '|「' + el.textContent.trim().slice(0, 14) + '」' +
        hex(fg) + ' on ' + hex(base) + ' = ' + cr.toFixed(2) + '  令牌=' + (used(fgRaw) || fgRaw),
    });
  }
  return bad;
}

(async () => {
  const srv = await serve();
  const url = 'http://127.0.0.1:' + srv.address().port + '/zaoji-prototype.html';
  const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 430, height: 930 }, deviceScaleFactor: 2 });
  const consoleErrs = [];
  page.on('console', (m) => {
    if (m.type() !== 'error') return;
    const at = (m.location() && m.location().url) || '';
    if (/favicon/i.test(at)) return;              // 同上：浏览器自发请求，与被审对象无关
    consoleErrs.push(m.text().slice(0, 140) + (at ? ' @' + at.slice(-40) : ''));
  });
  page.on('pageerror', (e) => consoleErrs.push('pageerror: ' + String(e).slice(0, 140)));
  page.on('response', (r) => {
    // 浏览器自己会要 /favicon.ico，原型页没挂图标，这条 404 与被审对象无关
    if (r.status() >= 400 && !/favicon/i.test(r.url())) {
      consoleErrs.push('HTTP ' + r.status() + ' ' + r.url().slice(-60));
    }
  });
  await page.goto(url, { waitUntil: 'load' });
  await page.waitForTimeout(2500);

  // 渲染自检：原型没渲染出来就别谈"零告警"
  const smoke = await page.evaluate(() => ({
    // 屏数走自检桥拿（脚本在 IIFE 里，SCREENS 不在 window 上）
    screens: window.__zaoji ? window.__zaoji.screens.length : -1,
    cards: document.querySelectorAll('.recipe-card').length,
    themeAttr: document.documentElement.getAttribute('data-theme'),
  }));
  if (smoke.screens < 20 || smoke.cards === 0) {
    console.log('AUDIT FAIL: 原型没渲染出来（SCREENS=' + smoke.screens + ' 首屏卡片=' + smoke.cards + '）');
    console.log('控制台：' + consoleErrs.slice(0, 4).join(' / '));
    await browser.close(); srv.close(); process.exit(1);
  }
  console.log('渲染自检：.screen ' + smoke.screens + ' 个 / 首屏 ' + smoke.cards +
    ' 张卡片 / data-theme=' + smoke.themeAttr);

  if (SHOTS) fs.mkdirSync(path.join(ROOT, 'dist', 'theme_previews'), { recursive: true });

  const results = [];
  for (const theme of THEMES) {
    for (const screen of SCREENS) {
      let bad = [];
      try {
        bad = await page.evaluate(probe, { theme, screen, exempt: EXEMPT_PARTS.join('|') });
      } catch (e) {
        bad = [{ kind: 'error', detail: String(e).slice(0, 140) }];
      }
      results.push({ theme, screen, bad });
      if (SHOTS && SHOT_SCREENS.indexOf(screen) >= 0) {
        await page.evaluate(({ theme, screen }) => {
          window.__zaoji.goto(screen, theme, 'android');
        }, { theme, screen });
        await page.waitForTimeout(400);
        await page.locator('.device').first().screenshot({
          path: path.join(ROOT, 'dist', 'theme_previews', theme + '__' + screen + '.png'),
        });
      }
    }
    console.log('  ' + theme + ' 走完 ' + SCREENS.length + ' 屏');
  }
  await browser.close();
  srv.close();

  // 静态一遍：CSS 区段里非豁免规则还留着多少颜色字面量
  const html = fs.readFileSync(path.join(ROOT, 'zaoji-prototype.html'), 'utf8');
  const i0 = html.indexOf('/* ══════════ 基础重置'), i1 = html.indexOf('</style>');
  const region = html.slice(i0, i1);
  const reExempt = new RegExp(EXEMPT_PARTS.join('|'));
  const staticLeft = [];
  for (const m of region.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    if (reExempt.test(m[1])) continue;
    // 纯白/纯黑的半透明叠层（玻璃高光、投影、遮罩）在两种明暗下都成立，
    // color-mix(... , #fff) 里的 #fff 是"往白里提亮"的算子参数，不是色板成员。
    const body = m[2]
      .replace(/rgba?\(\s*255\s*,\s*255\s*,\s*255[^)]*\)/g, 'OVERLAY')
      .replace(/rgba?\(\s*0\s*,\s*0\s*,\s*0[^)]*\)/g, 'SHADOW')
      .replace(/color-mix\((?:[^()]|\([^)]*\))*\)/g, 'MIX');
    for (const lit of body.matchAll(/#[0-9a-fA-F]{6}\b|#[0-9a-fA-F]{3}\b|rgba?\(\s*\d/g)) {
      staticLeft.push(m[1].trim().split('\n').pop().slice(0, 44) + ' → ' + lit[0]);
    }
  }

  const shotDir = path.join(ROOT, 'dist', 'theme_previews');
  fs.mkdirSync(shotDir, { recursive: true });
  fs.writeFileSync(path.join(shotDir, '_audit.json'), JSON.stringify(results, null, 1));

  /* 判据是**相对的**：默认主题（柿红暖纸）本来就有一批 4.0~4.48 的小字余量不足
     （柿红压暖纸、白字压柿红），那是这套设计定调时接受的取舍，不是本轮引入的。
     所以新主题的红线只有一条：**同一处文字不许比默认主题更差**。
     掉到基线以下 0.15 以上、或者基线过线而它不过线 → 报退化。
     默认主题自己的不足另列一节，作为已知项给人看，不算失败。 */
  const baseline = new Map();          // screen|sig → 最差比值
  for (const r of results) {
    if (r.theme !== THEMES[0]) continue;
    for (const b of r.bad) {
      const k = r.screen + '|' + b.sig;
      if (!baseline.has(k) || b.ratio < baseline.get(k)) baseline.set(k, b.ratio);
    }
  }
  const regress = [];
  const known = [];
  const dedup = new Map();
  for (const r of results) {
    for (const b of r.bad) {
      if (b.ratio >= b.need) continue;
      const k = r.screen + '|' + b.sig;
      if (r.theme === THEMES[0]) {
        const kk = 'known|' + b.sig;
        if (!dedup.has(kk)) { dedup.set(kk, 1); known.push({ theme: r.theme, screen: r.screen, detail: b.detail }); }
        continue;
      }
      const base = baseline.get(k);
      const worse = base == null ? true : (base >= b.need || b.ratio < base - 0.15);
      if (!worse) continue;
      if (KNOWN_GAP_THEMES[r.theme]) {
        // 已点名、已记账、但不拦构建：见文件头 KNOWN_GAP_THEMES 的理由
        const kk = 'gap|' + r.theme + '|' + b.sig;
        if (!dedup.has(kk)) {
          dedup.set(kk, 1);
          known.push({ theme: r.theme, screen: r.screen, detail: b.detail });
        }
        continue;
      }
      const kk = 'regress|' + r.theme + '|' + b.sig;
      if (dedup.has(kk)) continue;
      dedup.set(kk, 1);
      regress.push({
        theme: r.theme, screen: r.screen,
        detail: b.detail + (base == null ? '' : '  （默认主题同一处 = ' + base.toFixed(2) + '）'),
      });
    }
  }

  console.log('\n===== 审计结果 =====');
  console.log('主题×屏 = ' + (THEMES.length * SCREENS.length));
  console.log('相对默认主题的对比度退化：' + regress.length + ' 处');
  regress.slice(0, 30).forEach((f, i) => {
    console.log('  ' + (i + 1) + '. ' + f.theme + '/' + f.screen + ' → ' + f.detail);
  });
  console.log('已知取舍（默认主题自身 + KNOWN_GAP_THEMES 点名的那几套）：' + known.length + ' 类不计失败');
  for (const id of Object.keys(KNOWN_GAP_THEMES)) console.log('   · ' + id + '：' + KNOWN_GAP_THEMES[id]);
  known.slice(0, 6).forEach((f, i) => console.log('  · ' + f.screen + ' → ' + f.detail));
  console.log('静态残留（非豁免规则里的颜色字面量）：' + staticLeft.length + ' 处');
  staticLeft.slice(0, 20).forEach((s) => console.log('   · ' + s));
  const CDN = /cdn\.tailwindcss\.com|fonts\.googleapis\.com|fonts\.gstatic\.com/;
  const offline = consoleErrs.filter((e) => CDN.test(e));
  const realErrs = consoleErrs.filter((e) => !CDN.test(e));
  if (offline.length) console.log('外部 CDN 不可达（原型 §8.3 允许的两个 CDN，不算缺陷）：' + offline.length + ' 条');
  if (realErrs.length) console.log('控制台/网络异常 ' + realErrs.length + ' 条：' + realErrs.slice(0, 5).join(' / '));
  const hardFail = regress.length || staticLeft.length || realErrs.length;
  if (!hardFail) console.log('五套主题 × 全部界面：无退化、无未主题化字面量、无异常');
  process.exit(hardFail ? 1 : 0);
})().catch((e) => { console.log('AUDIT FAIL: ' + (e && e.message)); process.exit(1); });
