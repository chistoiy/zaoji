// 灶记 R13 两端真实 E2E：真 exe 服务端 + 真 Chrome 驱动 Web 产物。
//
// 验证什么（引擎↔真服务端的完整链路，模拟服务端测不了的那段）：
//   设备 A（独立浏览器 profile）：UI 配对 → 引擎自动同步 → 种子推上服务端
//   设备 B（另一个 profile，全新 IndexedDB）：UI 配对 → 引擎拉到全部数据 → 主页显示 9 道
//   服务端 /api/health 的 rowCounts 与 seq 作为仲裁证据。
//
// 为什么走 ?a11y=1：CanvasKit 渲染下 DOM 没有节点，启用语义树后
// 标签栏/按钮才有可点的 ARIA 节点（见 main.dart）。
// 为什么用 launchPersistentContext：沙箱只允许写项目目录，
// Chrome 的默认 profile 目录（%LOCALAPPDATA%）写不了——两个设备用两个 profile 目录，
// 顺便天然隔离了 IndexedDB（= 两台独立设备）。
const { chromium } = require('playwright-core');

const BASE = 'http://127.0.0.1:8666';
const CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const PROFILE_ROOT = 'D:/dev_workplace/flutter_te/babyco/app/tool/_e2e-profiles';

async function health() {
  const res = await fetch(`${BASE}/api/health`);
  return res.json();
}

async function pairCode() {
  const res = await fetch(`${BASE}/api/pair/code`);
  return (await res.json()).code;
}

(async () => {
  const h0 = await health();
  const before = h0.db.rowCounts;
  console.log(`服务端 ${h0.version} · schema v${h0.db.schemaVersionInDb} · rowCounts = ${JSON.stringify(before)}`);
  const serverHasData = (before.recipe ?? 0) > 0;
  if (serverHasData) {
    console.log('ℹ️ 服务端已有数据（真实设备已首推）——本轮跳过设备A，只验设备B的配对+拉取+渲染');
  }

  const mkDevice = async (name) => {
    const ctx = await chromium.launchPersistentContext(`${PROFILE_ROOT}-${name}`, {
      executablePath: CHROME,
      headless: true,
      viewport: { width: 390, height: 844 },
      args: ['--no-first-run', '--disable-features=DialPlayback'],
    });
    const page = ctx.pages()[0] ?? (await ctx.newPage());
    const errors = [];
    page.on('pageerror', (e) => errors.push(`[pageerror] ${e.message}`));
    return { ctx, page, errors };
  };

  const pairAndSync = async (page, label) => {
    try {
      // 不依赖 aria-label（fresh profile 下语义节点可能还没带 label）——
      // 语义节点里有真实文本，用 role=button + hasText 定位
      const meTab = page
        .locator('[role="button"]')
        .filter({ hasText: '我的' })
        .first();
      await meTab.click({ timeout: 20000 });
    } catch (e) {
      // 失败诊断：语义树里到底有什么
      const dump = await page.evaluate(() => ({
        buttons: [...document.querySelectorAll('[role="button"]')].map(
          (b) => b.getAttribute('aria-label'),
        ),
        inputs: document.querySelectorAll('input').length,
        body: document.body.innerText.slice(0, 300),
      }));
      console.log(`[${label}] 点击「我的」失败，语义树诊断:`, JSON.stringify(dump, null, 2));
      throw e;
    }

    // Flutter Web 的 TextField 就是真实 <input>，aria-label = hint 文案。
    // ★ 不能用 fill()：它设 value 不一定走 Flutter 的编辑通道（实测引擎收不到）。
    //   必须聚焦后用真实键盘事件输入。
    const urlInput = page.locator('input[aria-label^="http"]');
    await urlInput.click({ timeout: 20000 });
    await page.keyboard.type('http://127.0.0.1:8666', { delay: 10 });
    const code = await pairCode();
    const codeInput = page.locator('input[aria-label*="YE28Z4"]');
    await codeInput.click({ timeout: 20000 });
    await page.keyboard.type(code, { delay: 10 });
    console.log(`[${label}] 配对码 = ${code}`);
    await page.getByText('配对', { exact: true }).first().click({ timeout: 20000 });

    // 点击后看一眼页面上的错误条（引擎的 _fail 会显示在这里），便于诊断
    await page.waitForTimeout(1500);
    const errText = await page.evaluate(() => document.body.innerText);
    if (errText.includes('地址不对') || errText.includes('配对码是') || errText.includes('连不上')) {
      console.log(`[${label}] 引擎报错:`, errText.split('\n').filter((l) => l.includes('地址') || l.includes('配对码') || l.includes('连不上')).join(' | '));
    }
  };

  // ── 设备 A：配对 + 首推种子（仅当服务端为空）──
  let aOk = true;
  if (!serverHasData) {
    const A = await mkDevice('a');
    await A.page.goto(`${BASE}/?a11y=1`, { waitUntil: 'load', timeout: 30000 });
    await A.page.waitForTimeout(25000); // wasm + worker + 建库 + 种子（冷 profile 更慢）

    await pairAndSync(A.page, 'A');

    aOk = false;
    let hA = await health();
    for (let i = 0; i < 25; i++) {
      await new Promise((r) => setTimeout(r, 2000));
      hA = await health();
      if ((hA.db.rowCounts.recipe ?? 0) >= 9) { aOk = true; break; }
    }
    console.log(`[A] 推送后 rowCounts = ${JSON.stringify(hA.db.rowCounts)} · maxSeq = ${hA.db.maxSeq}`);
    console.log(`[A] 首推种子到服务端: ${aOk ? 'PASS' : 'FAIL'}`);
    if (A.errors.length) console.log(`[A] pageerror: ${A.errors.join(' | ')}`);
    await A.ctx.close().catch(() => {});
  }

  // ── 设备 B：全新存储，配对后应把 9 道菜全拉下来 ──
  const B = await mkDevice('b');
  await B.page.goto(`${BASE}/?a11y=1`, { waitUntil: 'load', timeout: 30000 });
  await B.page.waitForTimeout(18000);

  await pairAndSync(B.page, 'B');

  // ★ 配对时停在「我的」tab——IndexedStack 只把活跃 child 放进语义树，
  //   必须切回菜谱 tab 才能在 DOM 里看到「共 9 道」
  await B.page.locator('[role="button"]').filter({ hasText: '菜谱' }).first()
    .click({ timeout: 20000 }).catch(() => {});

  let bOk = false;
  try {
    await B.page.getByText(/共 9 道/).first().waitFor({ timeout: 30000 });
    bOk = true;
  } catch (_) {
    bOk = false;
  }
  console.log(`[B] 拉到全量数据并渲染主页: ${bOk ? 'PASS' : 'FAIL'}`);
  if (B.errors.length) console.log(`[B] pageerror: ${B.errors.join(' | ')}`);

  await B.page.screenshot({ path: 'D:/dev_workplace/flutter_te/babyco/app/screenshots/05-设备B-同步后主页.png' }).catch(() => {});

  await B.ctx.close().catch(() => {});

  const failed = !aOk || !bOk;
  console.log(failed ? '=== E2E FAIL ===' : '=== E2E PASS ===');
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('E2E 脚本异常:', e);
  process.exit(1);
});
