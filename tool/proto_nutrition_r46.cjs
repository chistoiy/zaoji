/* eslint-disable */
/**
 * R46 · 原型做实「热量手动填写 / AI 结果二次编辑」（FR-AI-69~74）
 *
 * 原型里原来只有**假保存**：「手动改」弹层能填，但 nutri-edit-save 只关层 + toast，
 * 数值不落、份数不折算、来源不翻转、AI 原值不留痕；而且**没算过时只有「估算」一条入口**，
 * 未配置 AI 就完全没有手填入口（FR-AI-69 的洞）。这一版把它做实。
 *
 * 五条护栏（§7.5 的规矩）：快照 · 每个锚点恰好命中一次 · 体积区间 · 改完把内联脚本
 * 抽出来过一遍 vm 语法检查 · 失败就整体不写盘。原型全文 CRLF。
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.resolve(__dirname, '..');
const target = path.join(root, 'zaoji-prototype.html');
const snap = path.join(root, 'dist', 'proto_before_r46.html');

const src = fs.readFileSync(target, 'utf8');
if ((src.match(/\r?\n/g) || []).length !== (src.match(/\n/g) || []).length) {
  console.error('ABORT: 行尾不统一，先查清楚再动'); process.exit(1);
}
fs.writeFileSync(snap, src, 'utf8');
const beforeBytes = Buffer.byteLength(src, 'utf8');
let L = src.split(/\r?\n/);

const assert1 = (pred, what) => {
  const hits = [];
  L.forEach((l, i) => { if (pred(l, i)) hits.push(i); });
  if (hits.length !== 1) {
    console.error(`ABORT: 锚点「${what}」命中 ${hits.length} 次（要恰好 1 次），文件未改动。`);
    process.exit(1);
  }
  return hits[0];
};
const closeBrace = (from) => {
  for (let i = from; i < L.length; i++) if (L[i] === '}') return i;
  console.error('ABORT: 找不到函数收尾的 }'); process.exit(1);
};

/* ══ P3：列表徽标按来源换 title（手填的不该挂着「AI 估算」的牌子）══ */
{
  const i = assert1((l) => l.startsWith("      (nu ? '<span class=\"art-kcal\""), '列表热量徽标');
  L[i] =
    "      (nu ? '<span class=\"art-kcal\" title=\"' + (nu.src === 'manual' ? '手动填写' : 'AI 估算，仅供参考') + '\">' + " +
    "ic(nu.src === 'manual' ? 'edit' : 'sparkle', 10) +";
}

/* ══ P2：未算过时也要有手填入口（FR-AI-69），两枚按钮同排、不跳版 ══ */
{
  const s = assert1((l) => l.startsWith("  const nutriBlock = '<div class=\"px\""), 'nutriBlock');
  const END = "'</div>';";
  let e = s;
  while (e < L.length && L[e].trim() !== END) e++;
  if (e >= L.length) { console.error('ABORT: nutriBlock 收尾没找到'); process.exit(1); }
  const block = [
    "  const nutriBlock = '<div class=\"px\" style=\"margin-top:14px\">' +",
    "      (nutri",
    "        ? nutritionCard(r, nutri)",
    "        // 没算过：只显示入口，绝不显示灰色占位数字（FR-AI-27）；",
    "        // 但**手填入口恒在**（FR-AI-69）——未配置 AI 的人不该被挡在热量之外。",
    "        : '<div class=\"nutri-entries\">' +",
    "            '<button type=\"button\" class=\"btn btn-ghost btn-sm\" data-act=\"' +",
    "              (aiReady('nutrition') ? 'nutri-calc' : 'nutri-calc') + '\" data-id=\"' + r.id + '\">' +",
    "              ic('sparkle', 15) + '估算热量' +",
    "              (aiReady('nutrition') ? '' : '<span class=\"ai-mini-lock\">' + ic('lock', 9) + '未配置</span>') +",
    "            '</button>' +",
    "            '<button type=\"button\" class=\"btn btn-quiet btn-sm\" data-act=\"nutri-edit\" data-id=\"' + r.id + '\">' +",
    "              ic('edit', 15) + '手动填写热量</button>' +",
    "          '</div>') +",
    "    '</div>';",
  ];
  L.splice(s, e - s + 1, ...block);
}

/* ══ P1：热量卡本体 + 表单工具函数（来源双态 / AI 原值留痕 / 份数折算）══ */
{
  const s = assert1((l) => l.startsWith('/* 热量卡片：必须标注不确定性'), 'nutritionCard');
  const e = closeBrace(s);
  const block = [
    "/* ═══════════ R46 · 热量：AI 估算与手动填写共用一张卡（FR-AI-24/25 + FR-AI-69~74）═══════════",
    "   三条口径写死在这里：",
    "   ① 来源只有 ai / manual 两态——手改过的 AI 值 = manual + 结构里留着 ai 原值，不加第三种枚举；",
    "   ② 份数基数默认跟菜谱的份数走，手改后自己记住（估算基数 ≠ 菜谱属性，Q6）；",
    "   ③ 数值手填路径与 AI 路径写的是同一份数据，同步照常带走（FR-AI-51），配置不参与同步。 */",
    "function nutriServ(n, r) {",
    "  if (n && n.serv) return n.serv;",
    "  return (r && r.serv) || 4;",
    "}",
    "function nutriFmt(v) { return v == null ? '—' : String(Math.round(v * 10) / 10); }",
    "",
    "/* 热量卡片：AI 估算 / 手动填写**同一张卡的两种状态**，位置与尺寸一致，只是来源标、免责行与第三枚按钮不同 */",
    "function nutritionCard(r, n) {",
    "  const manual = n.src === 'manual';",
    "  const conf = n.conf === 'high' ? ['高', 'badge-ok'] : n.conf === 'medium' ? ['中', 'badge-warn'] : ['低', 'badge-idle'];",
    "  const chip = manual",
    "    ? '<span class=\"ai-chip\" style=\"background:var(--surface-2);color:var(--ink-2)\">' + ic('edit', 10) + '手动填写</span>'",
    "    : '<span class=\"ai-chip\">' + ic('sparkle', 10) + 'AI 估算</span>';",
    "  const confChip = manual",
    "    ? '<span class=\"badge badge-idle\">按 ' + nutriServ(n, r) + ' 人份</span>'",
    "    : '<span class=\"badge ' + conf[1] + '\">把握度 ' + conf[0] + '</span>';",
    "  // 手改过的：hero 那行追一句 AI 原值，让人一眼知道现在的数是谁说的（FR-AI-71）",
    "  const aiEcho = manual && n.aiPer != null",
    "    ? '<span class=\"nutri-ai-echo\">AI 原估 ' + n.aiPer + '</span>' : '';",
    "  const third = manual",
    "    ? (aiReady('nutrition')",
    "        ? '<button type=\"button\" class=\"btn btn-quiet btn-sm\" data-act=\"nutri-calc\" data-id=\"' + r.id + '\">' + ic('sparkle', 13) + '用 AI 重算</button>'",
    "        : '<button type=\"button\" class=\"btn btn-quiet btn-sm\" data-act=\"ai-need-setup\">' + ic('sparkle', 13) + '用 AI 重算<span class=\"ai-mini-lock\">' + ic('lock', 9) + '未配置</span></button>')",
    "    : '<button type=\"button\" class=\"btn btn-quiet btn-sm\" data-act=\"nutri-calc\" data-id=\"' + r.id + '\">' + ic('sparkle', 13) + '重新估算</button>';",
    "  const foot = manual",
    "    ? esc(n.at) + ' 手填 · 来源：手动填写'",
    "    : esc(n.model) + ' · ' + esc(n.at) + '<b> AI 估算，仅供参考，不能用于医疗或饮食处方。</b>';",
    "  return '<div class=\"nutri' + (manual ? ' is-manual' : '') + '\">' +",
    "    '<div class=\"nutri-head\">' + chip + '<span style=\"flex:1\"></span>' + confChip + '</div>' +",
    "    '<div class=\"nutri-hero\">' +",
    "      '<span class=\"nutri-v num\">≈ ' + n.per + '</span>' +",
    "      '<span class=\"nutri-u\">千卡 / 每份　·　整锅约 ' + n.total + ' 千卡</span>' + aiEcho +",
    "    '</div>' +",
    "    '<div class=\"nutri-grid\">' +",
    "      '<div><div class=\"nutri-gv num\">' + nutriFmt(n.p) + '<small>g</small></div><div class=\"nutri-gk\">蛋白质</div></div>' +",
    "      '<div><div class=\"nutri-gv num\">' + nutriFmt(n.f) + '<small>g</small></div><div class=\"nutri-gk\">脂肪</div></div>' +",
    "      '<div><div class=\"nutri-gv num\">' + nutriFmt(n.c) + '<small>g</small></div><div class=\"nutri-gk\">碳水</div></div>' +",
    "    '</div>' +",
    "    '<div class=\"nutri-foot\">' +",
    "      '<span style=\"font-size:10.5px;color:var(--muted);flex:1;min-width:120px\">' + foot + '</span>' +",
    "      '<button type=\"button\" class=\"btn btn-quiet btn-sm\" data-act=\"nutri-basis\" data-id=\"' + r.id + '\">' + ic('list', 13) + '看依据</button>' +",
    "      '<button type=\"button\" class=\"btn btn-quiet btn-sm\" data-act=\"nutri-edit\" data-id=\"' + r.id + '\">' + ic('edit', 13) + '手动改</button>' + third +",
    "    '</div>' +",
    "    (n.note ? '<p class=\"nutri-note\">' + ic('alert', 10) + ' ' + esc(n.note) + '</p>' : '') +",
    "  '</div>';",
    "}",
    "",
    "/* 编辑表单：份数改动**总量不变、每份重算**（FR-AI-72）；总/每份谁后改谁说话（Q5） */",
    "function nutriFormCalc(f, changed) {",
    "  const serv = Math.max(1, Math.round(f.serv || 1));",
    "  if (changed === 'per') { f.total = Math.round((f.per || 0) * serv); }",
    "  else if (changed === 'total') { f.per = Math.round((f.total || 0) / serv); }",
    "  else if (changed === 'serv') { f.per = Math.round((f.total || 0) / serv); }",
    "  f.serv = serv;",
    "  return f;",
    "}",
    "function sheetNutriEdit(rid) {",
    "  const f = S.nutriForm;",
    "  const r = R_MAP[rid];",
    "  const n = nutritionOf(rid);",
    "  const field = function (k, label, val, hint) {",
    "    return '<div class=\"field\"><div class=\"field-label\">' + label + (hint ? '<span class=\"field-hint\">' + hint + '</span>' : '') + '</div>' +",
    "      '<input class=\"input num\" type=\"text\" inputmode=\"decimal\" data-act=\"input-nf\" data-nf=\"' + k + '\" value=\"' + (val == null ? '' : val) + '\"></div>';",
    "  };",
    "  return sheet(n ? '手动调整热量' : '手动填写热量',",
    "    '<div class=\"nutri-preview\">每份 ≈ ' + (f.per || 0) + ' 千卡　·　整锅约 ' + (f.total || 0) + ' 千卡　·　按 ' + f.serv + ' 人份</div>' +",
    "    '<div style=\"display:grid;grid-template-columns:1fr 1fr;gap:10px\">' +",
    "      field('per', '每份（千卡）', f.per) + field('total', '整锅（千卡）', f.total) +",
    "    '</div>' +",
    "    field('serv', '份数基数', f.serv, '改份数：整锅不变，每份重算') +",
    "    '<div style=\"display:grid;grid-template-columns:repeat(3,1fr);gap:10px\">' +",
    "      field('p', '蛋白质 g', f.p) + field('f', '脂肪 g', f.f) + field('c', '碳水 g', f.c) +",
    "    '</div>' +",
    "    (n && n.src === 'ai'",
    "      ? '<p class=\"nutri-keep\">AI 原估 每份 ' + (n.aiPer != null ? n.aiPer : n.per) + ' 千卡会留在「看依据」里对照，不会覆盖掉。</p>'",
    "      : '') +",
    "    (f.warn",
    "      ? '<div class=\"confirm-inline\">' + ic('alert', 14) + '<span style=\"flex:1\">每份 ' + f.per + ' 千卡，超过 20000 的上限线——确定是这个数？</span>' +",
    "        '<button type=\"button\" class=\"btn btn-primary btn-sm\" data-act=\"nutri-edit-save\">确定保存</button></div>'",
    "      : ''),",
    "    '<button type=\"button\" class=\"btn btn-ghost\" style=\"flex:1\" data-act=\"sheet-close\">取消</button>' +",
    "    '<button type=\"button\" class=\"btn btn-primary\" style=\"flex:1.4\" data-act=\"nutri-edit-save\">' + ic('check', 16) + '保存</button>');",
    "}",
  ];
  L.splice(s, e - s + 1, ...block);
}

/* ══ P4：动作处理器（估算 / 看依据两段对照 / 打开编辑 / 保存真落数据）══ */
{
  const s = assert1((l) => l.trim() === '/* —— v1.2：热量估算 —— */', '热量动作块起点');
  let e = s;
  while (e < L.length && L[e].trim() !== '/* —— v1.2：分享 —— */') e++;
  if (e >= L.length) { console.error('ABORT: 热量动作块终点（分享注释）没找到'); process.exit(1); }
  const block = [
    "  /* —— R46：热量估算 / 手填 / 二次编辑 —— */",
    "  if (act === 'nutri-calc') {",
    "    const rid = el.dataset.id;",
    "    if (!aiReady('nutrition')) { aiNeedSetup(); return; }",
    "    const r = R_MAP[rid];",
    "    const prev = nutritionOf(rid);",
    "    el.setAttribute('aria-disabled', 'true');",
    "    el.innerHTML = '<span class=\"ai-spin\"></span> 正在让 ' + esc(S.ai.model) + ' 估算…';",
    "    setTimeout(function () {",
    "      const per = 186 + (r.diff * 24);",
    "      const serv = nutriServ(prev, r);",
    "      S.nutriEdit[rid] = {",
    "        per: per, total: per * serv, serv: serv,",
    "        p: 12.4, f: 9.1, c: 21.6, conf: r.diff >= 3 ? 'medium' : 'high',",
    "        model: S.ai.model, at: '刚刚', src: 'ai',",
    "        basis: r.ings.slice(0, 4).map(function (i, k) { return { n: i.n, q: i.q, k: 40 + k * 36 }; }),",
    "        note: '按 ' + serv + ' 人份估算。实际用油量对结果影响最大。'",
    "      };",
    "      if (S.route.name === 'recipe-detail') renderScreen(false);",
    "      toast('估算完成 · 每份 ≈ ' + per + ' 千卡');",
    "    }, 1500);",
    "    return;",
    "  }",
    "  if (act === 'nutri-basis') {",
    "    const n = nutritionOf(el.dataset.id);",
    "    if (!n) return;",
    "    const r = R_MAP[el.dataset.id];",
    "    const manual = n.src === 'manual';",
    "    // 手改过的 AI 值：两段都在，并写明**现在生效的是哪一段**（FR-AI-71）",
    "    const echo = manual && n.aiPer != null",
    "      ? '<div class=\"card pad\" style=\"margin-bottom:14px\">' +",
    "          '<div class=\"spec\"><span class=\"spec-k\">AI 原估 · 每份</span><span class=\"spec-v\" style=\"color:var(--muted)\">≈ ' + n.aiPer + ' 千卡</span></div>' +",
    "          '<div class=\"spec\"><span class=\"spec-k\">AI 原估 · 整锅</span><span class=\"spec-v\" style=\"color:var(--muted)\">≈ ' + (n.aiTotal || (n.aiPer * nutriServ(n, r))) + ' 千卡</span></div>' +",
    "          '<div class=\"divider\"></div>' +",
    "          '<div class=\"spec\"><span class=\"spec-k\"><b>现在生效 · 每份（手填）</b></span><span class=\"spec-v\" style=\"color:var(--accent);font-weight:700\">≈ ' + n.per + ' 千卡</span></div>' +",
    "        '</div>'",
    "      : '';",
    "    S.sheet = sheet('热量是怎么算出来的',",
    "      echo +",
    "      '<p style=\"font-size:12px;color:var(--ink-2);line-height:1.85;margin-bottom:14px\">' +",
    "      '模型按每样食材的常见热量密度逐项折算再求和。<b>估得准不准，主要取决于用油量</b>——这部分模型只能猜。</p>' +",
    "      '<div class=\"card pad\">' + (n.basis || []).map(function (b) {",
    "        return '<div class=\"spec\"><span class=\"spec-k\">' + esc(b.n) + ' · ' + esc(b.q) + '</span>' +",
    "          '<span class=\"spec-v\">≈ ' + b.k + ' 千卡</span></div>';",
    "      }).join('') +",
    "      '<div class=\"divider\"></div>' +",
    "      '<div class=\"spec\"><span class=\"spec-k\">合计（整锅）</span><span class=\"spec-v\">≈ ' + n.total + ' 千卡</span></div>' +",
    "      '<div class=\"spec\"><span class=\"spec-k\">每份（按 ' + nutriServ(n, r) + ' 人份）</span>' +",
    "        '<span class=\"spec-v\" style=\"color:var(--ai);font-weight:700\">≈ ' + n.per + ' 千卡</span></div>' +",
    "      '</div>' +",
    "      (n.note ? '<div class=\"card pad\" style=\"margin-top:14px;background:var(--amber-bg);border-color:var(--amber-line);padding:12px 14px\">' +",
    "        '<p style=\"font-size:11px;color:var(--amber);line-height:1.75\">' + esc(n.note) + '</p></div>' : ''),",
    "      '<button type=\"button\" class=\"btn btn-primary btn-block\" data-act=\"sheet-close\">知道了</button>');",
    "    renderOverlays();",
    "    return;",
    "  }",
    "  if (act === 'nutri-edit') {",
    "    const rid = el.dataset.id;",
    "    const r = R_MAP[rid];",
    "    const n = nutritionOf(rid);",
    "    S.nutriForm = {",
    "      rid: rid,",
    "      per: n ? n.per : '', total: n ? n.total : '',",
    "      serv: nutriServ(n, r), p: n ? n.p : '', f: n ? n.f : '', c: n ? n.c : '',",
    "      warn: false,",
    "    };",
    "    S.sheet = sheetNutriEdit(rid);",
    "    renderOverlays();",
    "    return;",
    "  }",
    "  if (act === 'input-nf') {",
    "    const f = S.nutriForm;",
    "    if (!f) return;",
    "    const k = el.dataset.nf;",
    "    const raw = el.value.trim();",
    "    f[k] = raw === '' ? null : (Number(raw) || 0);",
    "    nutriFormCalc(f, k);",
    "    f.warn = k === 'per' && f.per > 20000;",
    "    S.sheet = sheetNutriEdit(f.rid);",
    "    renderOverlays();",
    "    const back = document.querySelector('[data-nf=\"' + k + '\"]');",
    "    if (back) { back.focus(); try { back.setSelectionRange(back.value.length, back.value.length); } catch (err) {} }",
    "    return;",
    "  }",
    "  if (act === 'nutri-edit-save') {",
    "    const f = S.nutriForm;",
    "    if (!f) return;",
    "    if (f.per == null || f.per <= 0) { toast('每份千卡得填个正数'); return; }",
    "    if (!f.warn && f.per > 20000) { f.warn = true; S.sheet = sheetNutriEdit(f.rid); renderOverlays(); return; }",
    "    const rid = f.rid;",
    "    const prev = nutritionOf(rid);",
    "    const r = R_MAP[rid];",
    "    const out = {",
    "      per: Math.round(f.per), total: Math.round(f.total || f.per * f.serv), serv: f.serv,",
    "      p: f.p, f: f.f, c: f.c,",
    "      conf: null, model: prev ? prev.model : null, at: '刚刚', src: 'manual',",
    "      basis: prev ? prev.basis : null, note: null,",
    "    };",
    "    // AI 原值留痕：第一次手改时把 AI 那版的每份/整锅抄下来，之后手改不再覆盖它",
    "    if (prev && prev.src === 'ai') { out.aiPer = prev.per; out.aiTotal = prev.total; }",
    "    else if (prev && prev.aiPer != null) { out.aiPer = prev.aiPer; out.aiTotal = prev.aiTotal; }",
    "    S.nutriEdit[rid] = out;",
    "    S.nutriForm = null; S.sheet = null;",
    "    renderScreen(false); renderOverlays();",
    "    toast('已保存 · 每份 ≈ ' + out.per + ' 千卡，来源：手动填写');",
    "    return;",
    "  }",
    "",
  ];
  L.splice(s, e - s, ...block);
}

/* ══ 样式：手填态徽标/预览/对照行/内联确认（不新开视觉语言，全用既有令牌）══ */
{
  const i = assert1((l) => l.startsWith('.art-kcal{'), '热量徽标样式块');
  const css = [
    "/* R46 · 热量手填与二次编辑 */",
    ".nutri.is-manual{border-color:var(--line)}",
    ".nutri-entries{display:flex;gap:8px;align-items:center}",
    ".nutri-entries .btn{flex:1}",
    ".nutri-ai-echo{font-size:10.5px;color:var(--muted);align-self:flex-end;padding-bottom:5px;",
    "  text-decoration:line-through;text-decoration-color:var(--line)}",
    ".nutri-preview{font-size:12.5px;font-weight:650;color:var(--ink);background:var(--surface-2);",
    "  border-radius:10px;padding:9px 12px;margin-bottom:14px}",
    ".nutri-keep{font-size:11px;color:var(--muted);line-height:1.7;margin:2px 0 10px}",
    ".confirm-inline{display:flex;gap:10px;align-items:center;background:var(--amber-bg);",
    "  border:1px solid var(--amber-line);border-radius:12px;padding:10px 12px;font-size:11.5px;color:var(--amber)}",
  ];
  L.splice(i, 0, ...css);
}

/* ══ 出盘前：内联脚本语法自检（改 448KB 单文件，语法塌了不能靠肉眼）══ */
const outLines = L;
const out = outLines.join('\r\n');
{
  const scripts = [];
  const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g;
  let m;
  while ((m = re.exec(out))) scripts.push(m[1]);
  if (!scripts.length) { console.error('ABORT: 一个内联脚本都没抓到，工装本身有问题'); process.exit(1); }
  scripts.forEach(function (body, k) {
    if (!/\S/.test(body)) return;
    try { new vm.Script(body, { filename: 'inline#' + k }); }
    catch (err) {
      console.error('ABORT: 内联脚本 #' + k + ' 语法不过：' + err.message);
      const ln = (err.stack.match(/inline#\d+:(\d+)/) || [])[1];
      if (ln) {
        const arr = body.split(/\r?\n/);
        console.error('   附近：' + (arr[ln - 1] || '').slice(0, 120));
      }
      process.exit(1);
    }
  });
  console.log(`内联脚本语法自检：${scripts.length} 段通过`);
}

const afterBytes = Buffer.byteLength(out, 'utf8');
if (!(afterBytes > beforeBytes && afterBytes - beforeBytes < 60000)) {
  console.error(`ABORT: 体积异常 ${beforeBytes} → ${afterBytes}（+${afterBytes - beforeBytes}）`);
  process.exit(1);
}
fs.writeFileSync(target, out, 'utf8');
console.log(`OK  ${beforeBytes} → ${afterBytes} B（+${afterBytes - beforeBytes}）`);
console.log(`行数 ${src.split(/\r?\n/).length} → ${outLines.length}`);
console.log(`快照 ${path.relative(root, snap)}`);
