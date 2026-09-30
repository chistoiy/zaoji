// R46 · 修我自己踩的坑：为「表格单元里不能写竖线」写的说明行，
// 自己因为含竖线把列数打乱了（lint 报「列数 4，表头是 2」）。
// 改法：整行重写，单元里**一个裸竖线都不留**（要提它就写「竖线」二字）。
const fs = require('fs');
const file = 'D:/dev_workplace/flutter_te/babyco/灶记-交接文档.md';
const NL = '\r\n';
const lines = fs.readFileSync(file, 'utf8').split(NL);
const i = lines.findIndex((l) => l.startsWith('| ★ **表格单元里写竖线'));
if (i < 0) throw new Error('找不到待修行');
if (lines.filter((l) => l.startsWith('| ★ **表格单元里写竖线')).length !== 1) {
  throw new Error('待修行不唯一');
}
lines[i] =
  '| ★ **表格单元里不能出现裸竖线，裹在反引号里也不行** | 想在一个单元里写「带查询串的两档宽度」，那个分隔符正好是表格的列分隔符，' +
  'Markdown 先按它切列、反引号救不了，`doc_table_lint` 当场报「列数与表头不符」（本轮连踩两次：一次热量清单行、一次这条说明行，第二次是**为这条坑写的行自己中招**）。' +
  '要么转义，要么拆成两个 code span 用「与」连——本轮取后者 |';
const bare = lines.filter((l) => /^[ ]+\|/.test(l));
if (bare.length) throw new Error('有残行');
fs.writeFileSync(file, lines.join(NL));
console.log('✔ 第 ' + (i + 1) + ' 行已重写');
