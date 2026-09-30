// R48 补正 · 原型：时间线「看更早」要有看得见的读数 + 耗时过小时要转小时。
//
// 真机走查抓到的两条（装机量到的，不是猜的）：
//  ① 点「看更早」在没更早记录可翻时**什么都不变**——控件点了必须有看得见的变化；
//  ② 一趟挂了一夜的会话显示成「实际耗时 966 分钟」——数字真，但没人读得动。
// 口径：翻页是**追加**（已看过的留着），每次点完给一行诚实读数；
//       ≥60 分钟转「H 小时 M 分」，为 0 分不写「0 小时」。
//
// 用法：node tool/proto_timeline_r48b.cjs [--check]
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const FILE = path.join(ROOT, 'zaoji-prototype.html');
const SNAP = path.join(ROOT, 'dist', 'zaoji-prototype_before_r48b.html');

const must = (cond, msg) => { if (!cond) throw new Error('护栏：' + msg); };

const EDITS = [
  {
    name: 'S 加翻页状态',
    from: "  tlKind:'all',          // R48：时间线的分段过滤器（all/cook/menu/recipe），是真的在筛",
    to: "  tlKind:'all',          // R48：时间线的分段过滤器（all/cook/menu/recipe），是真的在筛\n" +
        "  tlPages:1,             // R48 补正：一页 90 天，「看更早」是**追加**一页（已看过的留着）\n" +
        "  tlNoEarlier:'',        // 上一次往前推没带来任何新记录 → 给一行诚实读数，不假装到底了",
  },
  {
    name: 'durLabel + timelineWindow 两个公共小函数',
    from: "function timelineEvents(kind) {",
    to: "// 耗时读数：<60 只写分钟；≥60 写「H 小时 M 分」，整小时不补「0 分」。\n" +
        "function durLabel(m) {\n" +
        "  const n = Math.max(0, Math.round(m || 0));\n" +
        "  if (n < 60) return n + ' 分钟';\n" +
        "  const h = Math.floor(n / 60), r = n % 60;\n" +
        "  return r ? (h + ' 小时 ' + r + ' 分') : (h + ' 小时');\n" +
        "}\n" +
        "// 窗口：从演示「今天」往前 90 × 页数 天。**追加**不是平移——起点退、终点始终是今天。\n" +
        "function timelineWindow(kind, pages) {\n" +
        "  const span = 90 * (pages || 1);\n" +
        "  return timelineEvents(kind).filter(function (e) {\n" +
        "    return (new Date(TODAY) - new Date(e.date)) / 86400000 < span;\n" +
        "  });\n" +
        "}\n\n" +
        "function timelineEvents(kind) {",
  },
  {
    name: '做菜那行改用 durLabel',
    from: "        desc: l[1] + ' · 实际耗时 ' + l[3] + ' 分钟 · 第 ' + (logs.length - i) + ' 次'",
    to: "        desc: l[1] + ' · 实际耗时 ' + durLabel(l[3]) + ' · 第 ' + (logs.length - i) + ' 次'",
  },
  {
    name: 'SCREENS.timeline：吃窗口 + 底部读数 + 空态去掉教学第二行',
    from: "  const list = timelineEvents(S.tlKind);",
    to: "  const list = timelineWindow(S.tlKind, S.tlPages);",
  },
  {
    name: '底部「看更早」与读数',
    from: "      : '<div class=\"card pad\" id=\"tlEmpty\" style=\"text-align:center;color:var(--muted);font-size:12.5px;padding:28px 16px;line-height:1.8\">这一类还没有记录<br>换个类型看看</div>') +\n    '</div>' +\n  '</div>';\n};",
    to: "      : '<div class=\"card pad\" id=\"tlEmpty\" style=\"text-align:center;color:var(--muted);font-size:12.5px;padding:28px 16px;line-height:1.8\">这一类还没有记录</div>') +\n    '</div>' +\n    // ★ 翻页读数：点一次必有一行变化（要么覆盖天数变大，要么说实话：往前没有）\n" +
        "    '<div class=\"px\" style=\"text-align:center;padding:2px 0 16px\">' +\n" +
        "      '<button type=\"button\" class=\"btn btn-ghost btn-sm\" id=\"tlEarlier\" data-act=\"tl-earlier\">看更早</button>' +\n" +
        "      (S.tlPages > 1\n" +
        "        ? '<div id=\"tlSpan\" style=\"margin-top:4px;font-size:12px;color:var(--muted)\">' +\n" +
        "          (S.tlNoEarlier ? '再往前 90 天没有记录' : ('已看到最近 ' + (90 * S.tlPages) + ' 天')) + '</div>'\n" +
        "        : '') +\n" +
        "    '</div>' +\n" +
        "  '</div>';\n};",
  },
  {
    name: "dispatch：tl-earlier 追加一页并记下有没有带来新记录",
    from: "  /* —— 时间线分段过滤：切的是数据源，不是按钮样式 —— */\n  if (act === 'tl-kind') {",
    to: "  /* —— 时间线往前翻：追加一页 90 天，点了必须有看得见的读数变化 —— */\n" +
        "  if (act === 'tl-earlier') {\n" +
        "    const p = (S.tlPages || 1) + 1;\n" +
        "    const grew = timelineWindow(S.tlKind, p).length >\n" +
        "      timelineWindow(S.tlKind, S.tlPages || 1).length;\n" +
        "    S.tlPages = p;\n" +
        "    S.tlNoEarlier = grew ? '' : '1';\n" +
        "    renderScreen(true);\n" +
        "    return;\n" +
        "  }\n\n" +
        "  /* —— 时间线分段过滤：切的是数据源，不是按钮样式 —— */\n  if (act === 'tl-kind') {",
  },
];

const raw = fs.readFileSync(FILE, 'utf8');
const eol = raw.includes('\r\n') ? '\r\n' : '\n';
const j = (s) => s.split('\n').map((x) => x.replace(/\r$/, '')).join(eol);
must(Buffer.compare(Buffer.from(raw, 'utf8'), fs.readFileSync(FILE)) === 0, '读写编码与磁盘一致（utf8）');

let text = raw;
for (const e of EDITS) {
  const from = j(e.from), to = j(e.to);
  const hits = text.split(from).length - 1;
  must(hits === 1, `${e.name} 命中 ${hits} 次（要正好 1）`);
  text = text.replace(from, to);
  const left = text.split(to).length - 1;
  must(left === 1, `${e.name} 落地后自检 ${left} 次`);
  console.log(`OK ${e.name}`);
}

// 反向自检：旧写法必须一处不剩
for (const gone of ["' 分钟 · 第 '", '换个类型看看', 'const list = timelineEvents(S.tlKind)']) {
  must(!text.includes(j(gone)), `旧写法还在：${gone}`);
}
must(Buffer.byteLength(text) > Buffer.byteLength(raw), '体积只增不减');
Buffer.from(text, 'utf8').toString('utf8'); // 非法字节会在写盘后由读方暴露，这里再过一遍

if (process.argv.includes('--check')) { console.log('\n--check：全部命中，未写盘。'); process.exit(0); }

fs.mkdirSync(path.dirname(SNAP), { recursive: true });
if (!fs.existsSync(SNAP)) fs.writeFileSync(SNAP, raw, 'utf8');
fs.writeFileSync(FILE, text, 'utf8');
console.log(`\n写盘 zaoji-prototype.html：+${Buffer.byteLength(text) - Buffer.byteLength(raw)} bytes`);
console.log(`改前快照：dist/zaoji-prototype_before_r48b.html`);
