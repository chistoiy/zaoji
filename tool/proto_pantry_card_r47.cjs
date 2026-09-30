// R47 第五段 · 原型：厨房 tab 顶部的「到期 / 快没了」告警卡（FR-PAN-06）。
//
// 用户拍的落点：**厨房 tab 顶部**（不是菜谱那屏）。理由记在这儿，下一个人别又去猜：
// 打开 App 的触达已经由 FR-PAN-04 的通知那一路负责（开 App / 回前台时告诉你），
// 这张卡要解决的是「你人已经在厨房页了，一眼看到该先处理谁」——域一致，零新增导航。
//
// 顺手摘掉库存子段里那句教学文案（「有 N 样快过期了，点下面的…」）：
// 卡本身就是那个提示 + 那个去处，UI 只留功能标签与状态（用户定的口径）。
//
// 写法：整行前缀定位 + 命中断言 + 体积校验 + 改前快照；行尾跟随目标行（这份是混合 CRLF）。
// 用法：node tool/proto_pantry_card_r47.cjs
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const P = path.join(ROOT, 'zaoji-prototype.html');
const SNAP = path.join(ROOT, 'dist', 'zaoji-prototype_pre_r47pancard.html');

const guard = (label, cond, extra) => {
  if (!cond) { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); process.exit(1); }
  console.log('✔ ' + label);
};

const before = fs.readFileSync(P, 'utf8');
fs.writeFileSync(SNAP, before);
const lines = before.split('\n');
const bare = (l) => l.replace(/\r$/, '');
guard('快照已存且含原逻辑', before.includes('function kitchenSeg(cur)'), '');

// 找唯一一行（按去 \r 后的前缀）
const findOne = (prefix) => {
  const hits = lines.map((l, i) => [bare(l), i]).filter(([l]) => l.startsWith(prefix));
  guard('锚唯一：' + prefix.slice(0, 42), hits.length === 1, 'n=' + hits.length);
  return hits[0][1];
};
const eolOf = (i) => (lines[i].endsWith('\r') ? '\r' : '');

/* ——— ① 卡函数本体：插在 §27 食材库存那段注释之前 ——— */
const CARD_FN = [
  "/* 厨房 tab 顶部的库存告警卡（FR-PAN-06 · R47 第五段）。",
  "   口径与通知那一路（App 的 PantryWatch）逐字对齐：",
  "     · 「没有」的条目不算到期——家里本来就没有，提醒它没意义；",
  "     · 过期（expState warn）与三天内（soon）各一行，快没了（level low）一行；",
  "     · 名字按到期日近的排前，只列 3 个，多的写成「等 N 样」；",
  "     · 三组都空 → 整卡不渲染（需求书 FR-PAN-06 的验收判据就是「有数据时出现」）。",
  "   cur='recommend' 时不给「按库存找菜」那颗按钮：已经在目的地了，按钮就是假的。 */",
  "function pantryWatchCard(cur) {",
  "  const live = function (p) { return p.level !== 'out'; };",
  "  const byExp = function (a, b) { return String(a.exp || '9999').localeCompare(String(b.exp || '9999')); };",
  "  const bad = PANTRY.filter(function (p) { return live(p) && p.expState === 'warn'; }).sort(byExp);",
  "  const soon = PANTRY.filter(function (p) { return live(p) && p.expState === 'soon'; }).sort(byExp);",
  "  const low = PANTRY.filter(function (p) { return p.level === 'low'; });",
  "  if (!bad.length && !soon.length && !low.length) return '';",
  "  const names = function (arr) {",
  "    const head = arr.slice(0, 3).map(function (p) { return p.name; }).join('、');",
  "    return arr.length > 3 ? head + ' 等 ' + arr.length + ' 样' : head;",
  "  };",
  "  const row = function (kw, cls, label, arr) {",
  "    if (!arr.length) return '';",
  "    return '<div class=\"pw-row\" data-kw=\"' + kw + '\" style=\"display:flex;align-items:baseline;gap:8px;margin-top:9px\">' +",
  "      '<span class=\"badge ' + cls + '\"><i></i>' + label + ' ' + arr.length + '</span>' +",
  "      '<span style=\"flex:1;min-width:0;font-size:12px;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis\">' + esc(names(arr)) + '</span>' +",
  "    '</div>';",
  "  };",
  "  return '<div class=\"px\" style=\"margin-top:12px\"><div class=\"synccard\" id=\"pw-card\" style=\"padding:14px 15px\">' +",
  "    '<div style=\"display:flex;align-items:center;gap:8px\">' + ic('alert', 15) +",
  "      '<span style=\"font-size:13px;font-weight:700\">食材要处理</span></div>' +",
  "    row('bad', 'badge-err', '已过期', bad) +",
  "    row('soon', 'badge-warn', '三天内', soon) +",
  "    row('low', 'badge-idle', '快没了', low) +",
  "    (cur === 'recommend' ? '' :",
  "      '<button type=\"button\" class=\"btn btn-ghost btn-sm btn-block\" style=\"margin-top:11px\" id=\"pw-to-reco\" data-act=\"kitchen-go\" data-k=\"recommend\">' +",
  "        ic('sparkle', 14) + '按库存找菜</button>') +",
  "  '</div></div>';",
  "}",
  "",
];
const atInsert = findOne("/* ═══════════════════ 27 · 食材库存（v1.2）");
lines.splice(atInsert, 0, ...CARD_FN.map((l) => l + eolOf(atInsert)));
guard('卡函数已插入', lines.some((l) => bare(l).startsWith('function pantryWatchCard(cur) {')));

/* ——— ② 三个厨房子段顶部各挂一次 ——— */
for (const k of ['prep', 'pantry', 'recommend']) {
  const i = findOne("    kitchenSeg('" + k + "') +");
  lines.splice(i + 1, 0, "    pantryWatchCard('" + k + "') + " + eolOf(i));
  guard("厨房段 " + k + " 顶部挂上卡", bare(lines[i + 1]).includes('pantryWatchCard'));
}

/* ——— ③ 摘掉库存子段里那句教学文案（整块四行） ——— */
{
  const i = findOne("        (soonN || badN");
  const blk = [
    "        (soonN || badN",
    "          ? '<p style=\"font-size:11px;color:var(--muted);margin-top:11px;line-height:1.7\">' +",
    "            ic('alert', 11) + ' 有 ' + (soonN + badN) + ' 样快过期了，点下面的「按库存找菜」能优先消耗掉它们。</p>'",
    "          : '') +",
  ];
  for (let j = 0; j < 4; j++) {
    guard('待删第 ' + (j + 1) + ' 行对得上', bare(lines[i + j]) === blk[j], bare(lines[i + j]));
  }
  lines.splice(i, 4);
  guard('那句教学文案没了', !lines.join('\n').includes('能优先消耗掉它们'));
}

const after = lines.join('\n');
guard('只变长', after.length > before.length, before.length + ' → ' + after.length);
guard('三处挂卡', (after.match(/pantryWatchCard\('/g) || []).length === 3, (after.match(/pantryWatchCard\('/g) || []).length);
guard('括号没乱：函数体闭合', /function pantryWatchCard\(cur\) \{[\s\S]*?\n\}\r?\n/.test(after));

fs.writeFileSync(P, after);
console.log('✔ 已写入 zaoji-prototype.html（快照：dist/zaoji-prototype_pre_r47pancard.html）');
