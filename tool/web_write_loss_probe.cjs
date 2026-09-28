// R41 · Web 端「写完就刷新丢写」取证 + 回归闸门（跑真产物，不动业务代码）
//
// ## 这颗探针量过什么（读数记在交接文档 §六-12①）
//
// Web 上没有原生 sqlite 文件，drift 的 `WasmDatabase` 要在浏览器里模拟文件系统。
// 本机 Chromium 缺 `sharedArrayBuffer` 与 `dedicatedWorkersInSharedWorkers`，
// 拿到的是 `WasmStorageImplementation.sharedIndexedDb`：IndexedDB 里一个叫 `zaoji` 的库，
// `files` store 记 `{name:"/database", length:...}`，`blocks` store 按 4096 字节一块存文件内容。
// **OPFS 在这条路上一个文件都没有**，所以别去找 OPFS。
//
// 修复前的实测（同一 origin、持久 profile、无头）：
//   · `db.transaction` 提交完：界面「共 9 道 → 10 道」，而 IDB 的 blocks 六秒内
//     一直停在 66 块 / 270336 字节，marker 一个字节都没出现 → 刷新、整浏览器重启都回到 9 道；
//   · 不套事务的单条写（createMember）：marker 当场就在块里，活过刷新；
//   · 事务写完之后再点一记收藏（也是单条写）：事务的那些块**跟着一起下盘**了。
//   → 结论：这条模拟文件系统的写回只在「非事务语句」这条路上走，COMMIT 自己不会冲盘。
//
// 修复（`app/lib/data/zaoji_db.dart` 的 transaction 收口）之后的**期望**就是本脚本的断言：
//   A 事务写完 ~1 秒内 marker 必须在 IDB 的块里
//   B 保存后**零等待**直接刷新，「共 N 道」不能掉
//   C 整个浏览器关掉再开，还是那道数
//   D 同 origin 双开第二个页面，读到的是同一份
//
// 用法：
//   node tool/web_write_loss_probe.cjs                 # 无头
//   node tool/web_write_loss_probe.cjs --headed        # 真浏览器窗口（非无头）
//   node tool/web_write_loss_probe.cjs --keep-profile   # 复用上一次的库（不当基线用）
// 前提：先出 app/build/web（powershell -ExecutionPolicy Bypass -File app/tool/build_web.ps1）
// 退出码：断言没过就是 1，可以直接当发版前的闸门跑。
const http = require('http');
const fs = require('fs');
const path = require('path');
const {chromium} = require('playwright-core');

const ROOT = path.resolve(__dirname, '..');
const WEB = path.join(ROOT, 'app', 'build', 'web');
const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 8791; // ★ 固定端口：随机端口 = 每次一个新 origin = 一个新库，跨刷新无从对比
const PROFILE = path.join(ROOT, 'dist', 'web_probe_profile');
const HEADED = process.argv.includes('--headed');
if (!process.argv.includes('--keep-profile') && fs.existsSync(PROFILE)) {
  fs.rmSync(PROFILE, {recursive: true, force: true});
}
if (!fs.existsSync(path.join(WEB, 'index.html'))) {
  console.log('没有 app/build/web 产物，先跑 app/tool/build_web.ps1');
  process.exit(1);
}

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.woff2': 'font/woff2',
  '.wasm': 'application/wasm', '.svg': 'image/svg+xml', '.json': 'application/json',
  '.otf': 'font/otf', '.bin': 'application/octet-stream', '.map': 'text/plain',
};
const srv = http.createServer((req, res) => {
  const rel = decodeURIComponent(req.url.split('?')[0]);
  const abs = path.join(WEB, rel === '/' ? '/index.html' : rel);
  if (!abs.startsWith(WEB) || !fs.existsSync(abs) || fs.statSync(abs).isDirectory()) {
    res.writeHead(404); res.end('nope'); return;
  }
  res.writeHead(200, {'Content-Type': MIME[path.extname(abs).toLowerCase()] || 'application/octet-stream'});
  fs.createReadStream(abs).pipe(res);
});
const BASE = 'http://127.0.0.1:' + PORT + '/index.html';

/* ───────── 落盘读数（在页面里跑） ─────────
   ★ 要交给 page.evaluate 的必须是**真函数**：传字符串表达式时 playwright 不会替你调用它
     （第一版写成字符串，返回值直接 undefined，探针当场崩）。
   ★ 不能引用 Node 作用域里的任何东西，入参只有 marker。
   ★ blocks 是 4096 字节一块分开的，只翻前 30 行会得出假的「没落盘」；
     而且 marker 可能横跨两块，所以逐块找完还要拼起来再找一遍。 */
async function readStorage(marker) {
  const enc = new TextEncoder();
  const mb = marker ? enc.encode(marker) : null;
  const hit = (u8) => {
    if (!mb || !u8 || u8.length < mb.length) return false;
    outer: for (let i = 0; i + mb.length <= u8.length; i++) {
      for (let j = 0; j < mb.length; j++) if (u8[i + j] !== mb[j]) continue outer;
      return true;
    }
    return false;
  };
  const toU8 = (v) => {
    if (v instanceof ArrayBuffer) return new Uint8Array(v);
    if (ArrayBuffer.isView(v)) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
    return null;
  };
  const out = {origin: location.origin, opfs: [], idb: [], notes: [], t: Date.now()};
  try { out.persisted = await navigator.storage.persisted(); } catch (e) { out.notes.push('persisted: ' + e); }
  try {
    const root = await navigator.storage.getDirectory();
    const walk = async (dir, pre) => {
      for await (const [name, h] of dir.entries()) {
        const p = pre + '/' + name;
        if (h.kind === 'directory') { await walk(h, p); continue; }
        const f = await h.getFile();
        out.opfs.push({p, size: f.size, mtime: f.lastModified,
          hit: mb ? hit(new Uint8Array(await f.arrayBuffer())) : false});
      }
    };
    await walk(root, '');
  } catch (e) { out.notes.push('opfs: ' + e); }
  try {
    for (const d of await indexedDB.databases()) {
      if (!d.name) continue;
      const db = await new Promise((res, rej) => {
        const r = indexedDB.open(d.name);
        r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error);
      });
      for (const s of Array.from(db.objectStoreNames)) {
        const rec = {db: d.name, store: s, count: 0, bytes: 0, hitKeys: [], sample: [], notes: []};
        const rows = await new Promise((res, rej) => {
          const rq = db.transaction(s, 'readonly').objectStore(s).openCursor();
          const acc = [];
          rq.onsuccess = () => {
            const c = rq.result;
            if (!c) return res(acc);
            acc.push([String(c.key), c.value]);
            c.continue();
          };
          rq.onerror = () => rej(rq.error);
        }).catch(e => { rec.notes.push(String(e)); return []; });
        for (const [key, v] of rows) {
          const u8 = toU8(v);
          const size = u8 ? u8.length : (v instanceof Blob ? v.size : (typeof v === 'string' ? enc.encode(v).length : 0));
          rec.count++;
          rec.bytes += size;
          if (mb) {
            if (u8 && hit(u8)) rec.hitKeys.push(key);
            else if (typeof v === 'string' && v.includes(marker)) rec.hitKeys.push(key);
            else if (v && typeof v === 'object') {
              try { if (JSON.stringify(v).includes(marker)) rec.hitKeys.push(key); } catch (e) { /* 循环引用 */ }
            }
          }
          if (rec.sample.length < 3) {
            let extra = '';
            if (v && typeof v === 'object' && !u8 && !(v instanceof Blob)) {
              try { extra = ' ' + JSON.stringify(v).slice(0, 90); } catch (e) { /* 同上 */ }
            }
            rec.sample.push(key + ':' + ((v && v.constructor && v.constructor.name) || typeof v) + ':' + size + extra);
          }
        }
        // 跨块：把 blocks 按偏移拼成整份文件再找一次
        if (mb && !rec.hitKeys.length && s === 'blocks') {
          const pairs = rows.filter(([, v]) => toU8(v));
          pairs.sort((a, b) => Number(String(a[0]).split(',')[1]) - Number(String(b[0]).split(',')[1]));
          const all = new Uint8Array(pairs.reduce((n, [, v]) => n + toU8(v).length, 0));
          let off = 0;
          for (const [, v] of pairs) { const u = toU8(v); all.set(u, off); off += u.length; }
          if (hit(all)) rec.hitKeys.push('〈跨块命中〉');
        }
        out.idb.push(rec);
      }
      db.close();
    }
  } catch (e) { out.notes.push('idb: ' + e); }
  return out;
}

function line(s, marker) {
  const L = [];
  L.push('  ┌ 落盘 t=' + new Date(s.t).toISOString().slice(11, 23) + (marker ? ' 找「' + marker + '」' : ''));
  L.push('  │ origin=' + s.origin + '  storage.persisted=' + s.persisted +
    '  ← persisted=false 意味着浏览器在空间紧张时有权清掉整个库（另一条尾巴）');
  if (!s.opfs.length) L.push('  │ OPFS：空（sharedIndexedDb 这条路不写 OPFS，正常）');
  for (const f of s.opfs) L.push('  │ OPFS ' + f.p + ' ' + f.size + 'B 含marker=' + (f.hit ? '★是' : '否'));
  for (const r of s.idb) {
    L.push('  │ IDB ' + r.db + '/' + r.store + ' 记录=' + r.count + ' 字节=' + r.bytes +
      (marker ? ' 含marker=' + (r.hitKeys.length ? '★' + r.hitKeys.slice(0, 2).join(',') : '否') : '') +
      ' 样例[' + r.sample.join(' | ') + ']' + (r.notes || []).map(n => ' note:' + n).join(''));
  }
  (s.notes || []).forEach(n => L.push('  │ note ' + n));
  L.push('  └');
  return L.join('\n');
}

/** 一个页面一组工具：点语义节点、喂字、读「共 N 道」 */
function harness(p) {
  const txt = () => p.evaluate(() => (document.body.innerText || '').replace(/\s+/g, ' '));
  const peek = (marker) => p.evaluate(readStorage, marker || null);
  const show = async (tag, marker) => console.log(line(await peek(marker), marker));
  // 语义文本可能挂在 textContent、aria-label 或 placeholder 上，三个都得算
  // （上一版只认前两个 → 菜名框找不到、写盘动作根本没发生，整轮读数作废）
  const rect = (t, partial) => p.evaluate(([t, partial]) => {
    const sel = 'flt-semantics,[role=button],[role=checkbox],[role=group],[role=textfield],[role=textbox],input,textarea';
    const hits = Array.from(document.querySelectorAll(sel))
      .map(e => ({r: e.getBoundingClientRect(), s: [
          e.textContent || '', e.getAttribute('aria-label') || '',
          e.getAttribute('placeholder') || '', e.getAttribute('aria-placeholder') || ''].join(' ').trim()}))
      .filter(({s, r}) => s && (partial ? s.includes(t) : s === t) && r.width > 1 && r.height > 1)
      .sort((a, b) => (a.r.width * a.r.height) - (b.r.width * b.r.height));
    return hits.length ? {x: hits[0].r.x + hits[0].r.width / 2, y: hits[0].r.y + hits[0].r.height / 2} : null;
  }, [t, !!partial]);
  const tap = async (label, {partial = false} = {}) => {
    const box = await rect(label, partial);
    if (!box) { console.log('  ·    没找到节点：' + label); return false; }
    await p.mouse.click(box.x, box.y);
    await p.waitForTimeout(700);
    return true;
  };
  const type = async (hint, text) => {
    const box = await rect(hint, true);
    if (!box) { console.log('  ·    没找到输入区：' + hint); return false; }
    await p.mouse.click(box.x, box.y);
    await p.waitForTimeout(600);
    await p.keyboard.press('Control+a');
    await p.keyboard.press('Delete');
    if (text) await p.keyboard.insertText(text);
    await p.waitForTimeout(400);
    return true;
  };
  const boot = async (url, fresh) => {
    if (fresh) await p.goto(url, {waitUntil: 'load'});
    else await p.reload({waitUntil: 'commit'});
    await p.waitForFunction(() => (document.body.innerText || '').length > 12, null, {timeout: 60000}).catch(() => {});
    await p.waitForTimeout(6000);
  };
  /** 界面真相：列表页头部的「共 N 道」——R40 报的就是这个数掉回基线 */
  const dishCount = async () => {
    const m = /共\s*(\d+)\s*道/.exec(await txt());
    return m ? Number(m[1]) : null;
  };
  const dumpFields = (note) => p.evaluate(() => {
    const sel = 'input,textarea,[role=textfield],[role=textbox],flt-semantics';
    return Array.from(document.querySelectorAll(sel))
      .map(e => {
        const r = e.getBoundingClientRect();
        return {tag: e.tagName.toLowerCase(), al: e.getAttribute('aria-label') || '',
          ph: e.getAttribute('placeholder') || '', tc: (e.textContent || '').trim().slice(0, 30),
          vis: r.width > 1 && r.height > 1, y: Math.round(r.y)};
      })
      .filter(f => f.vis && (f.al || f.ph || f.tc)).slice(0, 12);
  }).then(fs => {
    console.log('  ·    可输入节点 @ ' + note);
    fs.forEach(f => console.log('      <' + f.tag + '> aria-label="' + f.al + '" placeholder="' + f.ph +
      '" text="' + f.tc.replace(/\n/g, '⏎') + '" y=' + f.y));
    return fs;
  });
  /** 建一道菜（走 createRecipe = db.transaction） */
  const newRecipe = async (name) => {
    if (!await tap('新建菜品')) return false;
    await p.waitForTimeout(1600);
    if (!await type('番茄炒蛋', name)) return false;
    return await tap('保存', {partial: true});
  };
  return {p, txt, peek, show, tap, type, rect, boot, dishCount, dumpFields, newRecipe};
}

srv.listen(PORT, '127.0.0.1', async () => {
  const opts = {
    executablePath: CHROME, headless: !HEADED,
    viewport: {width: 430, height: 930}, deviceScaleFactor: 2, args: ['--no-sandbox'],
  };
  const logs = [];
  const wire = (pg, tag) => {
    pg.on('console', m => { const t = m.text(); if (!/favicon|Failed to load resource/.test(t)) logs.push('[' + tag + m.type() + '] ' + t.slice(0, 190)); });
    pg.on('pageerror', e => logs.push('[' + tag + 'pageerror] ' + String(e).slice(0, 190)));
  };
  const t = HEADED ? 'H' : 'X';
  const M1 = '探针甲事务' + t, M2 = '探针乙第二笔' + t, M3 = '探针丙成员' + t;
  const fails = [];
  const check = (label, cond, note) => {
    console.log('  ' + (cond ? 'PASS ' : 'FAIL ') + label + (cond ? '' : '  ⟵ ' + (note || '')));
    if (!cond) fails.push(label);
    return cond;
  };
  const blocksOf = (s) => s.idb.find(r => r.store === 'blocks');
  const onDisk = (s, marker) => {
    const b = blocksOf(s);
    return !!(b && b.hitKeys.length);
  };

  console.log('\n════ R41 丢写取证 + 闸门 · ' + (HEADED ? '真浏览器（headed）' : '无头 Chromium') + ' · ' + BASE + ' ════');

  let ctx = await chromium.launchPersistentContext(PROFILE, opts);
  let h = harness(ctx.pages()[0] || await ctx.newPage());
  wire(h.p, '');

  console.log('\n〔0〕冷启动');
  await h.boot(BASE + '?a11y=1#/', true);
  const base0 = await h.dishCount();
  console.log('  ·    基线「共 ' + base0 + ' 道」');
  await h.show('冷启动', null);

  console.log('\n〔1〕新建菜谱「' + M1 + '」（createRecipe = db.transaction）——★ 修复的核心断言 A');
  if (!await h.newRecipe(M1)) { console.log('  ✘ 新建流程走不通，中止'); await ctx.close(); srv.close(); process.exit(1); }
  let landed = null;
  let prev = 0;
  for (const at of [0, 300, 700, 1200, 2000, 4000]) {
    await h.p.waitForTimeout(at - prev);
    prev = at;
    const s = await h.peek(M1);
    const b = blocksOf(s);
    console.log('  ·    +' + at + 'ms 块=' + (b ? b.count : '?') + '/' + (b ? b.bytes : '?') +
      'B 含marker=' + (onDisk(s, M1) ? '★是' : '否'));
    if (onDisk(s, M1)) { landed = at; break; }
  }
  const sA = await h.peek(M1);
  check('A 事务写入 4 秒内落进 IndexedDB 的块里' + (landed === null ? '' : '（+' + landed + 'ms）'),
    onDisk(sA, M1),
    '块数=' + (blocksOf(sA) ? blocksOf(sA).count : '?') + '——COMMIT 自己没冲盘，补丁那条直写也没生效');
  await h.show('事务写完', M1);
  check('写完界面「共 N 道」+1', (await h.dishCount()) === base0 + 1, '实际 ' + (await h.dishCount()));

  console.log('\n〔2〕保存后**零等待**直接刷新（★ 断言 B：最狠的时机）');
  if (!await h.newRecipe(M2)) { console.log('  ✘ 第二笔没建成，中止'); await ctx.close(); srv.close(); process.exit(1); }
  await h.p.reload({waitUntil: 'commit'});
  await h.p.waitForFunction(() => (document.body.innerText || '').length > 12, null, {timeout: 60000}).catch(() => {});
  await h.p.waitForTimeout(6000);
  const c2 = await h.dishCount();
  check('B 零等待刷新后仍是「共 ' + (base0 + 2) + ' 道」', c2 === base0 + 2, '掉到「共 ' + c2 + ' 道」= 丢写');
  await h.show('零等待刷新后', M2);

  console.log('\n〔3〕整个浏览器关掉再开（★ 断言 C：区分「刷新竞态」与「永不落盘」）');
  await ctx.close();
  ctx = await chromium.launchPersistentContext(PROFILE, opts);
  h = harness(ctx.pages()[0] || await ctx.newPage());
  wire(h.p, '重启');
  await h.boot(BASE + '?a11y=1#/', true);
  const c3 = await h.dishCount();
  check('C 重启后仍是「共 ' + (base0 + 2) + ' 道」', c3 === base0 + 2, '实际 ' + c3);
  await h.show('重启后', M1);

  console.log('\n〔4〕不套事务的单条写（createMember）同条件对照');
  await h.boot(BASE + '?a11y=1#/members', true);
  await h.tap('添加第一位家人', {partial: true}) || await h.tap('添加家人', {partial: true});
  await h.p.waitForTimeout(1600);
  await h.dumpFields('成员弹层');
  await h.type('称呼', M3);
  await h.tap('保存', {partial: true});
  await h.p.reload({waitUntil: 'commit'});
  await h.p.waitForFunction(() => (document.body.innerText || '').length > 12, null, {timeout: 60000}).catch(() => {});
  await h.p.waitForTimeout(6000);
  const sD = await h.peek(M3);
  check('D 单条写零等待刷新后也在盘上', onDisk(sD, M3), '这条修复前就一直是通的，当对照组用');

  console.log('\n〔5〕同 origin 双开第二个页面（★ 断言 E：读到的是同一份吗）');
  const p3 = await ctx.newPage();
  wire(p3, '双开');
  const h3 = harness(p3);
  await h3.boot(BASE + '?a11y=1#/', true);
  const c5 = await h3.dishCount();
  check('E 第二页「共 ' + c5 + ' 道」与第一页一致', c5 === base0 + 2, '第一页是 ' + c3);
  await h3.show('双开新页', M1);

  console.log('\n──── 控制台（截 40 条）────');
  logs.slice(0, 40).forEach(l => console.log('  ' + l));
  await ctx.close();
  srv.close();
  console.log('\n════ 判定 ' + (fails.length ? '✘ ' + fails.length + ' 条没过：' + fails.join(' / ') : '✔ 全过') + ' ════');
  console.log('profile 留在 ' + PROFILE + '（--keep-profile 可复用）');
  process.exitCode = fails.length ? 1 : 0;
});
