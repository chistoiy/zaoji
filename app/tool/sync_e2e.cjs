// 灶记 R15 两端真实 E2E：真 exe 服务端 + 真 Chrome 驱动 Web 产物。
//
// 在 R13 的「配对 → 推/拉种子」之上，覆盖 R14/R15 最关键的**写路径**：
//   设备 A（独立 profile）：UI 配对 → 新建一道菜 → 3 秒防抖自动推上服务端
//   设备 B（另一个 profile，全新 IndexedDB）：UI 配对 → 拉到全量 → 主页渲染「共 N 道」
//   （N = 起始种子数 + 1，服务端 /api/health 的 rowCounts 与 maxSeq 作仲裁证据）
//
// 为什么走 ?a11y=1：CanvasKit 渲染下 DOM 没有节点，启用语义树后
// 标签栏/按钮/输入框才有可点的 ARIA 节点（见 main.dart）。
// 为什么用 launchPersistentContext：沙箱只允许写项目目录；两个 profile 目录
// 顺便天然隔离 IndexedDB（= 两台独立设备）。
// ★ 每次 run 都先删 profile：上次 run 留下的配对态会让「配对」表单根本不出现
//   （已配对的设备显示的是「解除配对」）。
const { chromium } = require('playwright-core');
const fs = require('fs');

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

// R21：准入默认是「免配对开放」，配对接口在非 pairCode 模式下 409。
// E2E 验的是配对链路 → 先把服务端切到 pairCode，跑完恢复 open（真实默认态）。
// /api/admin/settings 只认本机请求，这个脚本正好跑在服务端那台电脑上。
async function setAccess(accessMode) {
  const res = await fetch(`${BASE}/api/admin/settings`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ accessMode }),
  });
  const j = await res.json();
  if (!res.ok) throw new Error(`切换准入模式失败: ${JSON.stringify(j)}`);
  console.log(`[准入] accessMode = ${j.accessMode}`);
}

(async () => {
  try {
    await setAccess('pairCode');
    process.exitCode = (await run()) ? 1 : 0;
  } catch (e) {
    console.error('E2E 脚本异常:', e);
    process.exitCode = 1;
  }
  // 无论成败都恢复开放模式：半途失败把服务端钉在 pairCode 会影响家里其它人
  await setAccess('open').catch((e) => console.log('[准入] 恢复 open 失败:', e.message));
  process.exit(process.exitCode ?? 0);
})();

async function run() {
  const h0 = await health();
  console.log(
    `服务端 ${h0.version} · schema v${h0.db.schemaVersionInDb} · ` +
      `rowCounts = ${JSON.stringify(h0.db.rowCounts)} · maxSeq = ${h0.db.maxSeq}`,
  );

  for (const d of ['a', 'b']) {
    fs.rmSync(`${PROFILE_ROOT}-${d}`, { recursive: true, force: true });
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
    // ★ 配对两个雷（R19② 探针实测，同步修 R15 脚本里的同款潜伏问题）：
    //   ① 第二个输入框 click 后首字符会被吞 → 读回 DOM 值、不对重打；
    //   ② 「配对」文字在分段标题与按钮上各出现一次，getByText 会点错 → 锚定 role=button；
    //   ③ R21 起地址框**已预填当前 origin**——预填值不在 hint 里（aria-label 不再是
    //     "http…"，改用 input[type=url] 锚定），且直接敲键会把新值**接在后面**，
    //     所以每次输入前一律 Control+A 覆盖旧值。
    const inputValues = () =>
      page.evaluate(() => [...document.querySelectorAll('input')].map((i) => i.value));
    const typedInto = async (locator, text, which) => {
      for (let attempt = 1; attempt <= 3; attempt++) {
        if (attempt === 1) await locator.click({ timeout: 20000 });
        await page.keyboard.press('Control+A');
        await page.keyboard.type(text, { delay: 60 });
        await page.waitForTimeout(300);
        const v = (await inputValues())[which] ?? '';
        if (v === text) return true;
        console.log(`[${label}] 字段#${which} 读到 "${v}" ≠ "${text}"，重打`);
      }
      throw new Error(`${label}: 字段#${which} 三次都打不进 "${text}"`);
    };

    try {
      const meTab = page
        .locator('[role="button"]')
        .filter({ hasText: /^我的/ })
        .first();
      await meTab.click({ timeout: 20000 });
    } catch (e) {
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

    // ★ 不能用 fill()：它设 value 不一定走 Flutter 的编辑通道（实测引擎收不到）。
    await typedInto(page.locator('input[type="url"]'), 'http://127.0.0.1:8666', 0);
    const code = await pairCode();
    await typedInto(page.locator('input[aria-label*="YE28Z4"]'), code, 1);
    console.log(`[${label}] 配对码 = ${code}`);
    await page
      .locator('[role="button"]', { hasText: /^配对$/ })
      .first()
      .click({ timeout: 20000 });

    await page.waitForTimeout(1500);
    const errText = await page.evaluate(() => document.body.innerText);
    if (errText.includes('地址不对') || errText.includes('配对码是') || errText.includes('连不上')) {
      console.log(`[${label}] 引擎报错:`, errText.split('\n').filter((l) => l.includes('地址') || l.includes('配对码') || l.includes('连不上')).join(' | '));
    }
  };

  // ★ 切 tab 必须用锚定正则：R14 在「我的」页加了回收站入口，其副标题
  //   「删除的菜谱可以在这里恢复」包含「菜谱」——hasText 子串匹配会先命中
  //   回收站卡片（DOM 序在 tab bar 之前），把脚本带进回收站页
  //   （R15 实测：E2E 卡死在这一步）。^锚定后只有 tab bar 的「菜谱 菜谱」命中。
  const goTab = (page, tab) =>
    page.locator('[role="button"]').filter({ hasText: new RegExp(`^${tab}`) }).first()
      .click({ timeout: 20000 });

  // ── 设备 A：配对 → 新建一道菜 → 3 秒防抖自动推 ──
  const A = await mkDevice('a');
  await A.page.goto(`${BASE}/?a11y=1`, { waitUntil: 'load', timeout: 30000 });
  await A.page.waitForTimeout(25000); // wasm + worker + 建库 + 种子（冷 profile 更慢）

  await pairAndSync(A.page, 'A');

  // 等服务端安静（maxSeq 连续两轮不变）：A 配对后的首轮 sync（推种子或拉数据）
  // 与下面的写路径断言解耦——起始基数以「安静后」为准，空库/有库两种起点都成立。
  let lastSeq = -1;
  let hQuiet = await health();
  for (let i = 0; i < 15; i++) {
    await new Promise((r) => setTimeout(r, 2000));
    hQuiet = await health();
    if (hQuiet.db.maxSeq === lastSeq) break;
    lastSeq = hQuiet.db.maxSeq;
  }
  const base = hQuiet.db.rowCounts.recipe ?? 0;
  const expectedRecipes = base + 1;
  console.log(`[A] 配对后服务端安静：recipe=${base} · maxSeq=${hQuiet.db.maxSeq} · 期望写路径后 recipe=${expectedRecipes}`);

  // 切回菜谱 tab，点「新建菜品」FAB。
  // R15 起 FAB 带 Semantics(label: '新建菜品', onTap)——语义树可寻址、可触发。
  await goTab(A.page, '菜谱');
  await A.page.waitForTimeout(1500);
  const fab = A.page.locator('[role="button"][aria-label*="新建"]').first();
  try {
    await fab.click({ timeout: 10000 });
  } catch (_) {
    console.log('[A] 语义树里没找到新建按钮，退回坐标点击（右下角 FAB 中心 ≈ 342,734）');
    await A.page.mouse.click(342, 734);
  }
  await A.page.waitForTimeout(3000);

  // 填表。实测约束：
  // ① 字段一旦聚焦，语义 label 从 hint 变成 value（空值即 null）——点过的字段别再按 hint 找；
  // ② ★ 单行字段是 <input>，多行字段（maxLines>1）是 <textarea>——步骤/备注要用 textarea 选择器
  //    （它们一直在 DOM 里，不需要滚动到可见）。
  try {
    const nameInput = A.page.locator('input[aria-label="例：番茄炒蛋"]');
    await nameInput.click({ timeout: 20000 });
    await A.page.keyboard.type('E2E 写路径测试菜', { delay: 15 });
    const ingInput = A.page.locator('input[aria-label="食材名"]').first();
    await ingInput.click({ timeout: 20000 });
    await A.page.keyboard.type('鸡蛋', { delay: 15 });
    const stepInput = A.page
      .locator('textarea[aria-label^="描述这一步"]')
      .first();
    await stepInput.click({ timeout: 20000 });
    await A.page.keyboard.type('小火煎 3 分钟', { delay: 15 });
  } catch (e) {
    const dump = await A.page.evaluate(() => ({
      buttons: [...document.querySelectorAll('[role="button"]')].map(
        (b) => b.getAttribute('aria-label'),
      ),
      inputs: [...document.querySelectorAll('input')].map(
        (i) => i.getAttribute('aria-label'),
      ),
      body: document.body.innerText.slice(0, 200),
    }));
    console.log('[A] 填表失败，语义树诊断:', JSON.stringify(dump, null, 2));
    throw e;
  }

  // 保存（AppBar 的文字按钮「保存」；底部大按钮是「保存菜品」，exact 匹配不会混）
  await A.page.getByText('保存', { exact: true }).first().click({ timeout: 20000 });
  console.log('[A] 已点保存，等 3 秒防抖 + 自动推送…');

  let aOk = false;
  for (let i = 0; i < 15; i++) {
    await new Promise((r) => setTimeout(r, 2000));
    const h = await health();
    if ((h.db.rowCounts.recipe ?? 0) >= expectedRecipes) { aOk = true; break; }
  }
  const hAfterA = await health();
  console.log(`[A] 写路径后 rowCounts = ${JSON.stringify(hAfterA.db.rowCounts)} · maxSeq = ${hAfterA.db.maxSeq}`);
  console.log(`[A] 新建菜 3 秒防抖自动推送: ${aOk ? 'PASS' : 'FAIL'}`);
  if (A.errors.length) console.log(`[A] pageerror: ${A.errors.join(' | ')}`);
  await A.page.screenshot({ path: 'D:/dev_workplace/flutter_te/babyco/app/screenshots/06-设备A-新建菜保存后.png' }).catch(() => {});
  await A.ctx.close().catch(() => {});

  // ── 设备 B：全新存储，配对后应拉到 种子 + A 新建的菜 ──
  const B = await mkDevice('b');
  await B.page.goto(`${BASE}/?a11y=1`, { waitUntil: 'load', timeout: 30000 });
  await B.page.waitForTimeout(25000);

  await pairAndSync(B.page, 'B');

  // 配对时停在「我的」tab——IndexedStack 只把活跃 child 放进语义树，
  // 必须切回菜谱 tab 才能看到「共 N 道」（★ 见 goTab 的回收站陷阱注释）
  await goTab(B.page, '菜谱');
  await B.page.waitForTimeout(1500);

  let bOk = false;
  try {
    await B.page.getByText(new RegExp(`共 ${expectedRecipes} 道`)).first().waitFor({ timeout: 30000 });
    bOk = true;
  } catch (_) {
    bOk = false;
  }
  console.log(`[B] 拉到全量并渲染主页（共 ${expectedRecipes} 道）: ${bOk ? 'PASS' : 'FAIL'}`);
  if (B.errors.length) console.log(`[B] pageerror: ${B.errors.join(' | ')}`);

  await B.page.screenshot({ path: 'D:/dev_workplace/flutter_te/babyco/app/screenshots/05-设备B-同步后主页.png' }).catch(() => {});
  await B.ctx.close().catch(() => {});

  const failed = !aOk || !bOk;
  console.log(failed ? '=== E2E FAIL ===' : '=== E2E PASS ===');
  return failed;
}
