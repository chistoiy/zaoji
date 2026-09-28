// R39 · 真产物逐主题走查：把 build/web 那份 Flutter 产物在五套主题下各截一张。
//
// 为什么还要这一遍：原型审计证明的是"设计侧没退化"，widget 测试证明的是
// "令牌接上了"。但 400 多处调用点机械迁移之后，**只剩眼睛能看出
// "某处还钉着白底"**——所以直接截真产物。
//
// 用法：node tool/app_theme_shots.cjs        （产物存在才跑：app/build/web）
const http = require('http');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright-core');

const ROOT = path.resolve(__dirname, '..');
const WEB = path.join(ROOT, 'app', 'build', 'web');
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const THEMES = (process.argv[2] || 'shihong,indigo,rouge,night,stone').split(',');
const ROUTES = ['', '#/calendar'];   // 传第二个参数可只截首页
const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript',
  '.css': 'text/css', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.woff2': 'font/woff2', '.wasm': 'application/wasm',
  '.svg': 'image/svg+xml', '.json': 'application/json',
  '.otf': 'font/otf', '.bin': 'application/octet-stream',
};

if (!fs.existsSync(path.join(WEB, 'index.html'))) {
  console.log('没有 app/build/web 产物，先跑 app/tool/build_web.ps1');
  process.exit(1);
}

const srv = http.createServer((req, res) => {
  const rel = decodeURIComponent(req.url.split('?')[0]);
  const abs = path.join(WEB, rel === '/' ? '/index.html' : rel);
  if (!abs.startsWith(WEB) || !fs.existsSync(abs) || fs.statSync(abs).isDirectory()) {
    res.writeHead(404); res.end('nope'); return;
  }
  res.writeHead(200, { 'Content-Type': MIME[path.extname(abs).toLowerCase()] || 'application/octet-stream' });
  fs.createReadStream(abs).pipe(res);
});

srv.listen(0, '127.0.0.1', async () => {
  const base = 'http://127.0.0.1:' + srv.address().port + '/index.html';
  const out = path.join(ROOT, 'dist', 'theme_previews');
  fs.mkdirSync(out, { recursive: true });
  const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] });
  const page = await browser.newPage({ viewport: { width: 430, height: 930 }, deviceScaleFactor: 2 });
  // 注意：这里会稳定出现一批 `HTTP 404 /api/sync/config` ——那是同步引擎开机探活
  // 在跟一个只会发静态文件的服务器说话，属正常噪音，不是产物缺陷（真服务端上它是 200）。
  const errs = [];
  page.on('pageerror', (e) => errs.push(String(e).slice(0, 120)));
  page.on('response', (r) => {
    if (r.status() >= 400) errs.push('HTTP ' + r.status() + ' ' + r.url().slice(-70));
  });
  page.on('console', (m) => { if (m.type() === 'error') errs.push(m.text().slice(0, 120)); });

  for (const theme of THEMES) {
    for (const route of ROUTES) {
      const url = base + '?a11y=1&theme=' + theme + route;
      await page.goto(url, { waitUntil: 'load' });
      // 首帧信号：语义树里出现任一已知文案（?a11y=1 会把语义挂进 DOM）
      await page.waitForFunction(() => {
        const t = document.body.innerText || '';
        return /菜谱|日历|我的|菜单/.test(t);
      }, null, { timeout: 60000 }).catch(() => {});
      await page.waitForTimeout(2500);
      const shot = path.join(out, 'app__' + theme + (route ? '__cal' : '__home') + '.png');
      await page.screenshot({ path: shot });
      const text = await page.evaluate(() => (document.body.innerText || '').replace(/\s+/g, ' ').slice(0, 60));
      console.log('  ' + theme + (route || '  ') + ' → ' + path.basename(shot) + '   语义文本: ' + text);
    }
  }
  await browser.close();
  srv.close();
  console.log(errs.length ? '控制台错误 ' + errs.length + ' 条：' + errs.slice(0, 4).join(' / ') : '无控制台错误');
});
