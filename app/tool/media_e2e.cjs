// 灶记 R19② 图片上传真实 E2E：真 exe 服务端 + 真 Chrome，覆盖 R16/R17 没被 E2E 钉住的链路——
// 「做菜拍照 → 选封面 → 保存 → 上传 → 另一台设备看到这张照片」。
//
// 与 sync_e2e.cjs 同一套路（真 exe + a11y 语义树 + 持久 profile = 两台独立设备），
// 这里额外要破的是 R16/R17 记的那条「playwright 对 image_picker 支持有限」：
// image_picker_for_web 会动态挂一个隐藏 <input type=file> 并程序化 click()。
// **破法 = page.waitForEvent('filechooser') + fileChooser.setFiles()**——
// Chrome 把程序化点击的对话框也交给监听器，谁动态挂的 input 反而不重要了。
// 兜底路径：直接对 DOM 里的 input[type=file] setInputFiles（input 点过一次后仍在）。
//
// 断言链（每一环都是「最终事实」，不信脚本的"我以为"）：
//   A：PUT /api/media/<sha> 响应 200  →  服务端盘上出现该 sha 文件  →  recipe 行数 +1
//   B：拉到 A 新建的菜（共 N+1 道）   →  B 浏览器发出 GET /api/media/<sha>?w=640 且 200
//      （缩略图档位由服务端派生——B 从来没上传过这张图，它能显示就是整条管线的证明）
// 佐证：服务端 logs/zaoji.log（R19③）里能看到 PUT 与 GET 的逐条请求行。
const { chromium } = require('playwright-core');
const fs = require('fs');

const BASE = 'http://127.0.0.1:8666';
const CHROME = 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const PROFILE_ROOT = 'D:/dev_workplace/flutter_te/babyco/app/tool/_e2e-profiles';
const PHOTO = 'D:/dev_workplace/flutter_te/babyco/app/tool/_e2e-photo.jpg';
const MEDIA_DIR = 'D:/dev_workplace/flutter_te/babyco/server/data/media';
const SHOT = 'D:/dev_workplace/flutter_te/babyco/app/screenshots';

async function health() {
  const res = await fetch(`${BASE}/api/health`);
  return res.json();
}

async function pairCode() {
  const res = await fetch(`${BASE}/api/pair/code`);
  return (await res.json()).code;
}

(async () => {
  if (!fs.existsSync(PHOTO)) {
    console.error(`测试照片不存在：先跑 server/tool/make_sample_photo.dart gen 到该路径`);
    process.exit(1);
  }
  const h0 = await health();
  console.log(
    `服务端 ${h0.version} · media ${h0.media.originals} 张 / ` +
      `${h0.media.totalBytes} B · recipe ${h0.db.rowCounts.recipe ?? 0} · maxSeq ${h0.db.maxSeq}`,
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

  // ★ 实测（R19②）：**每个输入框的首字符都可能被吞**（配对码、菜名都中过招——
  //   菜名被吞后库里出现「2E 封面测试菜」，搜索断言当场对不上）。
  //   对策统一为「打 → 读回 value → 不对重打」。读回用 elementHandle：
  //   字段聚焦后 aria-label 从 hint 变 null（R15 坑 3），locator 二次解析会失效，
  //   但 handle 指向的 DOM 节点不变。
  const typeVerified = async (page, locator, text, label) => {
    const el = await locator.elementHandle({ timeout: 20000 });
    for (let attempt = 1; attempt <= 3; attempt++) {
      // 点击并**确认真的聚焦到了目标字段**（实测：食材行的点击有概率没挪焦点，
      // 文字全打进了上一个字段，目标读回空串）
      let focused = false;
      for (let c = 0; c < 3 && !focused; c++) {
        await locator.click({ timeout: 20000 }).catch(() => {});
        focused = await page.evaluate((e) => document.activeElement === e, el);
      }
      if (!focused) {
        console.log(`[${label}] 第 ${attempt} 次聚不上焦，重试`);
        continue;
      }
      await page.keyboard.press('Control+A'); // 清掉可能的残值（首次输入时是空选择，无害）
      await page.keyboard.type(text, { delay: 60 });
      await page.waitForTimeout(300);
      const v = await el.evaluate((e) => e.value).catch(() => null);
      if (v === text) return true;
      console.log(`[${label}] "${text}" 第 ${attempt} 次打进为 "${v}"，重打`);
    }
    throw new Error(`[${label}] 三次都打不进 "${text}"`);
  };

  const pairAndSync = async (page, label) => {
    const meTab = page.locator('[role="button"]').filter({ hasText: /^我的/ }).first();
    await meTab.click({ timeout: 20000 });
    await typeVerified(page, page.locator('input[aria-label^="http"]'), 'http://127.0.0.1:8666', `${label}/地址`);
    const code = await pairCode();
    await typeVerified(page, page.locator('input[aria-label*="YE28Z4"]'), code, `${label}/配对码`);
    console.log(`[${label}] 配对码 = ${code}`);
    // 「配对」在页面上出现两处（分段标题 + 按钮），getByText 会点错——锚定 role=button
    await page
      .locator('[role="button"]', { hasText: /^配对$/ })
      .first()
      .click({ timeout: 20000 });
    await page.waitForTimeout(1500);
  };

  const goTab = (page, tab) =>
    page.locator('[role="button"]').filter({ hasText: new RegExp(`^${tab}`) }).first()
      .click({ timeout: 20000 });

  // ── 设备 A：新建带封面的菜 ──
  const A = await mkDevice('a');
  await A.page.goto(`${BASE}/?a11y=1`, { waitUntil: 'load', timeout: 30000 });
  await A.page.waitForTimeout(25000);

  await pairAndSync(A.page, 'A');

  // 等服务端安静（同 sync_e2e：起始基数以两轮 maxSeq 不变为准）
  let lastSeq = -1;
  let hQuiet = await health();
  for (let i = 0; i < 15; i++) {
    await new Promise((r) => setTimeout(r, 2000));
    hQuiet = await health();
    if (hQuiet.db.maxSeq === lastSeq) break;
    lastSeq = hQuiet.db.maxSeq;
  }
  const base = hQuiet.db.rowCounts.recipe ?? 0;
  const baseMedia = hQuiet.media.originals;
  console.log(`[A] 安静基线：recipe=${base} · media=${baseMedia}`);

  await goTab(A.page, '菜谱');
  await A.page.waitForTimeout(1500);
  await A.page.locator('[role="button"][aria-label*="新建"]').first().click({ timeout: 20000 });
  await A.page.waitForTimeout(3000);

  // 点「选一张照片当封面」→ filechooser 弹到脚本手里
  const chooserPromise = A.page
    .waitForEvent('filechooser', { timeout: 15000 })
    .catch(() => null);
  await A.page.getByText('选一张照片当封面').first().click({ timeout: 20000 });
  const chooser = await chooserPromise;
  if (chooser) {
    await chooser.setFiles(PHOTO);
    console.log('[A] filechooser 命中，已喂图');
  } else {
    // 兜底：直接对动态挂出的 <input type=file> setInputFiles
    const inp = A.page.locator('input[type="file"]').last();
    await inp.setInputFiles(PHOTO, { timeout: 15000 });
    console.log('[A] filechooser 没等到，走 input[type=file] 兜底喂图');
  }
  // 纯 Dart 压缩（2000×1500 → 1600px/q82）在主线程要 1~2 秒；
  // 预览出现的标志：移除/重选按钮的语义（Tooltip 提供 aria-label）出现
  await A.page
    .waitForSelector('[aria-label*="移除封面"], [aria-label*="重新选择"]', { timeout: 20000 })
    .then(() => console.log('[A] 封面预览已出现（压缩完成）'))
    .catch(() => console.log('[A] ⚠ 没观察到预览语义节点，继续保存（PUT 断言才是硬证据）'));

  await typeVerified(A.page, A.page.locator('input[aria-label="例：番茄炒蛋"]'), 'E2E 封面测试菜', 'A/菜名');
  await typeVerified(A.page, A.page.locator('input[aria-label="食材名"]').first(), '番茄', 'A/食材');

  // 保存触发的上传 = PUT；行推送 = 之后的 POST /api/changes。先挂监听再点保存。
  const putPromise = A.page
    .waitForResponse(
      (r) => r.url().includes('/api/media/') && r.request().method() === 'PUT',
      { timeout: 40000 },
    )
    .catch(() => null);
  await A.page.getByText('保存', { exact: true }).first().click({ timeout: 20000 });
  const put = await putPromise;
  const putOk = !!put && put.status() === 200;
  const sha = put ? put.url().match(/media\/([0-9a-f]{64})/)?.[1] : null;
  console.log(`[A] PUT /api/media: ${put ? `${put.status()} sha=${sha?.slice(0, 12)}…` : '没发生'}`);

  let synced = false;
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 2000));
    const h = await health();
    if ((h.db.rowCounts.recipe ?? 0) >= base + 1) { synced = true; break; }
  }
  const hAfter = await health();
  const onDisk = sha ? fs.existsSync(`${MEDIA_DIR}/${sha}`) : false;
  const mediaGrew = hAfter.media.originals >= baseMedia + 1;
  console.log(`[A] recipe +1: ${synced} · 盘上落文件: ${onDisk} · health media ${baseMedia} → ${hAfter.media.originals}`);
  await A.page.screenshot({ path: `${SHOT}/07-A-封面上传后.png` }).catch(() => {});
  if (A.errors.length) console.log(`[A] pageerror: ${A.errors.join(' | ')}`);
  await A.ctx.close().catch(() => {});

  // ── 设备 B：全新设备，拉到的菜必须能把这张图显示出来 ──
  const B = await mkDevice('b');
  const thumbGets = [];
  B.page.on('response', (r) => {
    if (sha && r.url().includes(`/api/media/${sha}?w=640`)) {
      thumbGets.push(r.status());
    }
  });
  await B.page.goto(`${BASE}/?a11y=1`, { waitUntil: 'load', timeout: 30000 });
  await B.page.waitForTimeout(25000);
  await pairAndSync(B.page, 'B');
  await goTab(B.page, '菜谱');

  let bRendered = false;
  try {
    await B.page.getByText(new RegExp(`共 ${base + 1} 道`)).first().waitFor({ timeout: 30000 });
    bRendered = true;
  } catch (_) {}

  // ★ GridView 懒构建：新建的菜没做过、按「最近做过」排在**视口外**，
  //   卡片不 build 就不会有 CoverImage 的 GET。mouse.wheel 在 CanvasKit 下不滚动（实测），
  //   所以用搜索框过滤——列表只剩这张卡，必然进视口、必然触发拉图。
  let cardVisible = false;
  try {
    await typeVerified(B.page, B.page.locator('input[aria-label^="搜菜名"]'), 'E2E', 'B/搜索');
    await B.page.getByText('E2E 封面测试菜').first().waitFor({ timeout: 15000 });
    cardVisible = true;
  } catch (_) {}
  console.log(`[B] 新菜卡片进入视口: ${cardVisible}`);

  // 卡片渲染后 CoverImage 会按 card 档拉缩略图（等它，最多 30 秒）
  let bThumb = thumbGets.includes(200);
  for (let i = 0; i < 15 && !bThumb; i++) {
    await B.page.waitForTimeout(2000);
    bThumb = thumbGets.includes(200);
  }
  console.log(`[B] 拉到含新菜的列表: ${bRendered} · 640 档缩略图 GET 200: ${bThumb}（B 从未上传过这张图）`);
  if (B.errors.length) console.log(`[B] pageerror: ${B.errors.join(' | ')}`);
  await B.page.screenshot({ path: `${SHOT}/08-设备B-封面显示.png` }).catch(() => {});
  await B.ctx.close().catch(() => {});

  const failed = !(putOk && sha && synced && onDisk && mediaGrew && bRendered && bThumb);
  console.log(failed ? '=== MEDIA E2E FAIL ===' : '=== MEDIA E2E PASS ===');
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('E2E 脚本异常:', e);
  process.exit(1);
});
