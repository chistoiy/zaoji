// R46 · 划账第三半：计划书 §二十二 标上落地状态（立项 ≠ 做完，接手的人要看得到这条界线）。
const fs = require('fs');
const file = 'D:/dev_workplace/flutter_te/babyco/灶记-开发计划书.md';
const src = fs.readFileSync(file, 'utf8');
fs.writeFileSync('D:/dev_workplace/flutter_te/babyco/dist/before_r46plan.md', src);
const NL = src.includes('\r\n') ? '\r\n' : '\n';
const E = (t) => (NL === '\r\n' ? t.replace(/\n/g, '\r\n') : t);

let out = src;

// ① 细则标题打勾
const h = '### R46 · 冷启动修复 + 热量手动编辑 + 快赢（P0，零改列，可随热修走）';
if (out.split(h).length - 1 !== 1) throw new Error('R46 标题命中异常');
out = out.replace(h, E('### R46 · 冷启动修复 + 热量手动编辑 + 快赢（P0，零改列，可随热修走） ✅ **2026-09-29 已完成实现与验证 · 未发行**'));

// ② 总表后面补一行状态说明（不动表格本身，避免列数踩坑）
const anchor = '| **R53** | 运维与安全收口 |';
const i = out.indexOf(anchor);
if (i < 0) throw new Error('找不到总表最后一行');
const lineEnd = out.indexOf('\n', i);
if (lineEnd < 0) throw new Error('行尾找不到');
const note = E('\n\n' +
  '> **落地状态（2026-09-29 更新）**：**R46 已完成实现与验证，但没有发行**——零 schema 改动所以不欠' +
  '「apk + exe 同发」那笔账，产物/版本号/push 都留着（发版要用户点头）。' +
  '基线变化：shared 160→**177** · server 315→**320** · app 311→**329**，三处 `flutter analyze` 全 0。' +
  '取证工装新增两件可复用：`tool/dead_columns_r46.cjs`（找「有列零代码」的摆设列）、' +
  '`server/test/endpoint_registry_r46_test.dart` 的「解析路由表 ↔ 手写清单」双向比对写法。' +
  'R47~R53 未开始。');
out = out.slice(0, lineEnd + 1) + note + out.slice(lineEnd + 1);

if (out.length <= src.length) throw new Error('体积没增长');
fs.writeFileSync(file, out);
console.log('✔ 计划书 §二十二 状态已标注：' + src.length + ' -> ' + out.length + '（' + (NL === '\r\n' ? 'CRLF' : 'LF') + '）');
