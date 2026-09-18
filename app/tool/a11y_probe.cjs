// 语义树探针：看 ?a11y=1 下 DOM 里到底有哪些可寻址节点。
const { chromium } = require('playwright-core');

(async () => {
  const ctx = await chromium.launchPersistentContext(
    'D:/dev_workplace/flutter_te/babyco/app/tool/_e2e-profiles-probe',
    {
      executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe',
      headless: true,
      viewport: { width: 390, height: 844 },
      args: ['--no-first-run'],
    },
  );
  const page = ctx.pages()[0] ?? (await ctx.newPage());
  page.on('pageerror', (e) => console.log('[pageerror]', e.message));
  page.on('console', (m) => {
    const t = m.text();
    if (t.length > 400) t = t.slice(0, 400) + '…';
    console.log(`[console.${m.type()}]`, t);
  });
  await page.goto('http://127.0.0.1:8666/', { waitUntil: 'load', timeout: 30000 });
  await page.waitForTimeout(8000);
  console.log('=== 普通加载（无 a11y）下的错误 ===');
  await page.goto('http://127.0.0.1:8666/?a11y=1', { waitUntil: 'load', timeout: 30000 });
  await page.waitForTimeout(12000);
  console.log('=== 带 ?a11y=1 的错误 ===');

  const info = await page.evaluate(() => {
    const buttons = [...document.querySelectorAll('[role="button"]')].map(
      (b) => b.getAttribute('aria-label'),
    );
    const inputs = document.querySelectorAll('input').length;
    const allAria = [...document.querySelectorAll('[aria-label]')]
      .slice(0, 40)
      .map((b) => `${b.tagName}:${b.getAttribute('aria-label')}`);
    return {
      buttons: buttons.slice(0, 30),
      buttonCount: buttons.length,
      inputs,
      allAria,
      bodySnippet: document.body.innerText.slice(0, 200),
      title: document.title,
    };
  });
  console.log(JSON.stringify(info, null, 2));
  await page.screenshot({ path: 'D:/dev_workplace/flutter_te/babyco/app/screenshots/_probe.png' }).catch(() => {});
  await ctx.close().catch(() => {});
})();
