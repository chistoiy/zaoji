// 灶记 Web 启动体检（临时诊断脚本，用完即删）。
//
// 背景：headless Chrome 的 --virtual-time-budget 与 web worker 的真实异步
// （OPFS/IndexedDB/WebLocks）合不来——虚拟时间跑完了，worker 的真实异步还没回来，
// 截图永远停在启动页。这个脚本用 playwright-core 驱动真实 Chrome、等**真实时间**，
// 才能回答「Web 端的本地库到底能不能打开」。
//
// 判定依据：
//   · console 里有 drift 的「Using ... due to missing browser features」→ 打开成功（降级实现）
//   · pageerror → 真 bug
//   · 截图：全纸色 = 还在启动屏；有卡片 = 主页渲染成功
const { chromium } = require('playwright-core');

(async () => {
  const browser = await chromium.launch({
    executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
    headless: true,
  });
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });

  const logs = [];
  page.on('console', (m) => logs.push(`[console.${m.type()}] ${m.text()}`));
  page.on('pageerror', (e) => logs.push(`[pageerror] ${e.message}`));
  page.on('requestfailed', (r) =>
    logs.push(`[requestfailed] ${r.url()} — ${r.failure()?.errorText}`));

  await page.goto('http://127.0.0.1:8666/', { waitUntil: 'load', timeout: 30000 });

  // 等 20 秒真实时间：wasm 编译 + worker 握手 + 建库 + 灌种子
  await page.waitForTimeout(20000);
  await page.screenshot({ path: 'C:/dev_workplace_placeholder.png' }).catch(() => {});
  await page.screenshot({ path: 'D:/dev_workplace/flutter_te/babyco/app/screenshots/04-主页-数据库版-真实浏览器.png' });

  console.log('=== console / errors ===');
  for (const l of logs) console.log(l);
  if (logs.length === 0) console.log('(no console output)');

  await browser.close();
})();
