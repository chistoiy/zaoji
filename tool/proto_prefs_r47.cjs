// R47 · 原型补「提醒与计时」三组偏好（FR-SET-01/02/03）：
// 现在的三行 switch 是**装饰**（aria-checked 就地翻，没有状态、也没有提前量），
// App 端已经把它做成真开关 + 就地提前量档位，规格必须回到原型里来。
const fs = require('fs');
const path = require('path');
const file = path.resolve(__dirname, '../zaoji-prototype.html');
const src = fs.readFileSync(file, 'utf8');
fs.writeFileSync(path.resolve(__dirname, '../dist/proto_before_r47prefs.html'), src);
const NL = src.includes('\r\n') ? '\r\n' : '\n';
const lines = src.split(NL);

function findOnce(sub, msg) {
  const hits = lines.map((l, i) => ({ l, i })).filter(({ l }) => l.includes(sub));
  if (hits.length !== 1) throw new Error(`${msg}：命中 ${hits.length} 次，应为 1 → ${sub.slice(0, 40)}`);
  return hits[0].i;
}

/* ① 状态：prefs 对象 */
{
  const i = findOnce('  timerSeq:0,', 'timerSeq 行');
  lines.splice(i + 1, 0, [
    '  prefs:{',
    '    mealReminderOn:true,   // FR-SET-01 开饭前提醒',
    '    mealLead:90,           // FR-SET-01 提前量（分钟）',
    '    timerFloatOn:true,     // FR-SET-02 计时器悬浮窗',
    '    vibrateOn:false,       // FR-SET-03 计时结束震动（原型默认关，跟 App 一致见需求书）',
    '  },                      // R47：本机偏好，App 落 local_pref、不参与同步',
  ].join(NL));
}

/* ② 三行改成有 id 的真开关，并给「开饭前提醒」补就地提前量档位 */
{
  const i = findOnce('<span class="row-title">开饭前提醒</span>', '开饭前提醒行');
  // 这一行 + 它后面的 switch 行 + 结束 div
  const j = findOnce('<span class="row-title">计时器悬浮窗</span>', '计时器悬浮窗行');
  lines.splice(i, j - i + 2, [
    "      (function () {",
    "        var leadLabel = function (m) {",
    "          return m < 60 ? (m + ' 分钟') : ((m / 60) % 1 === 0 ? (m / 60) + ' 小时' : (m / 60).toFixed(1) + ' 小时');",
    "        };",
    "        var steps = [30, 45, 60, 90, 120, 180];",
    "        return '<div class=\"row\"><span class=\"row-ico\">' + ic('bell', 18) + '</span>' +",
    "          '<span class=\"row-main\"><span class=\"row-title\">开饭前提醒</span><span class=\"row-sub\">' +",
    "            (S.prefs.mealReminderOn ? ('提前 ' + leadLabel(S.prefs.mealLead) + '把备菜与制作投进待办') : '不开待办，只在菜单里看') +",
    "          '</span></span>' +",
    "          '<span class=\"switch\" role=\"switch\" tabindex=\"0\" data-act=\"pref-switch\" data-pref=\"mealReminderOn\" aria-checked=\"' + (S.prefs.mealReminderOn ? 'true' : 'false') + '\"></span></div>' +",
    "          /* 提前量就地一排档：不做「点一下→再弹一层」的两段式（项目定了的交互口径） */",
    "          (S.prefs.mealReminderOn",
    "            ? '<div class=\"px\"><div class=\"lead-row\">' + steps.map(function (m) {",
    "                return '<button type=\"button\" class=\"lead-chip' + (S.prefs.mealLead === m ? ' is-on' : '') + '\" data-act=\"lead-pick\" data-min=\"' + m + '\" aria-pressed=\"' + (S.prefs.mealLead === m) + '\">' + leadLabel(m) + '</button>';",
    "              }).join('') + '</div></div>'",
    "            : '') +",
    "          '<div class=\"row\"><span class=\"row-ico\">' + ic('maximize', 18) + '</span>' +",
    "          '<span class=\"row-main\"><span class=\"row-title\">计时器悬浮窗</span><span class=\"row-sub\">离开菜谱页后继续显示，可拖动</span></span>' +",
    "          '<span class=\"switch\" role=\"switch\" tabindex=\"0\" data-act=\"pref-switch\" data-pref=\"timerFloatOn\" aria-checked=\"' + (S.prefs.timerFloatOn ? 'true' : 'false') + '\"></span></div>';",
    "      })() +",
  ].join(NL));
}

/* ③ 震动那行同样接状态 */
{
  const i = findOnce('<span class="row-title">计时结束震动</span>', '震动行');
  lines.splice(i + 1, 1,
    "        '<span class=\"switch\" role=\"switch\" tabindex=\"0\" data-act=\"pref-switch\" data-pref=\"vibrateOn\" aria-checked=\"' + (S.prefs.vibrateOn ? 'true' : 'false') + '\"></span></div>' +");
}

/* ④ 处理器：pref-switch / lead-pick */
{
  const i = findOnce("  if (act === 'toggle-on') {", 'toggle-on 处理');
  lines.splice(i, 0, [
    "  /* R47 · 厨房偏好：真状态在 S.prefs，翻了要重渲染（就地改文字与档位） */",
    "  if (act === 'pref-switch') {",
    "    var k = el.dataset.pref;",
    "    if (!(k in S.prefs)) return;",
    "    S.prefs[k] = !S.prefs[k];",
    "    renderScreen();",
    "    return;",
    "  }",
    "  if (act === 'lead-pick') {",
    "    S.prefs.mealLead = parseInt(el.dataset.min, 10) || 90;",
    "    renderScreen();",
    "    return;",
    "  }",
  ].join(NL));
}

/* ⑤ 样式：就地档位 */
{
  const i = (() => { const hits = lines.map((l, k) => ({ l, k })).filter(({ l }) => l.startsWith('.switch{')); if (hits.length !== 1) throw new Error('switch 样式锚命中 ' + hits.length + ' 次'); return hits[0].k; })();
  lines.splice(i, 0, [
    '/* R47：提前量就地档位（不是弹层里的第二步操作） */',
    '.lead-row{display:flex;flex-wrap:wrap;gap:7px;margin:-4px 0 12px}',
    '.lead-chip{padding:6px 12px;border-radius:999px;border:1px solid var(--line);background:var(--paper-2);',
    '  font-size:12.5px;color:var(--ink-2);cursor:pointer}',
    '.lead-chip.is-on{border-color:var(--accent);background:var(--accent-softer);color:var(--accent-deep);font-weight:600}',
    '',
  ].join(NL));
}

const out = lines.join(NL);
if (out.length <= src.length) throw new Error('体积没增长');
for (const marker of ['pref-switch', 'lead-pick', 'lead-chip', 'S.prefs.mealLead']) {
  if (!out.includes(marker)) throw new Error('缺少标记：' + marker);
}
fs.writeFileSync(file, out);
console.log('✔ 原型偏好三组做实：' + src.length + ' -> ' + out.length);
