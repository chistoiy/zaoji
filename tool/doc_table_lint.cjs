/* eslint-disable */
// 表格体检：给规划文档找「列数不齐 / 缺分隔行 / 脱离主表的孤儿行」。
// 背景：这个仓库反复踩 Edit 插表格行吞行首的坑（见用户级记忆 markdown-table-edit-eats-next-row），
// 而四份规划文档不进 git（.gitignore 的 /灶记-*.md），没有 diff 可对照——只能靠 lint 兜。
// 算法：按行扫，连续的以 | 开头的行算一个表块；列数用「转义感知的切分」（\| 不算分隔符）。
// 用法：node tool/doc_table_lint.cjs [文件...]   不传参数就扫仓库根的四份 灶记-*.md
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const args = process.argv.slice(2);
const files = args.length
  ? args.map((f) => path.resolve(root, f))
  : fs
      .readdirSync(root)
      .filter((f) => f.startsWith('灶记-') && f.endsWith('.md'))
      .map((f) => path.join(root, f));

// "a \| b | c" → 2 列（\| 是内容里的竖线）
const cols = (line) => {
  let n = 0;
  let esc = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (esc) { esc = false; continue; }
    if (ch === '\\') { esc = true; continue; }
    if (ch === '|') n++;
  }
  // 首尾各一根 → 分隔符数 = n-1，列数 = n-1
  return Math.max(n - 1, 0);
};

const isSep = (line) => /^\|[\s:|-]+\|$/.test(line.trim());
let totalProblems = 0;

for (const file of files) {
  if (!fs.existsSync(file)) { console.warn(`跳过（不存在）：${file}`); continue; }
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  const problems = [];
  let i = 0;
  while (i < lines.length) {
    if (!/^\|/.test(lines[i])) { i++; continue; }
    let j = i;
    while (j < lines.length && /^\|/.test(lines[j])) j++;
    const block = lines.slice(i, j);
    // 上一行必须是空行或表格之外的内容，否则说明表格被上文粘住（少见，记一笔）
    if (block.length === 1) {
      problems.push(`${i + 1}: 孤立的单行表格（多半是插行时脱开了主表）`);
    } else if (!isSep(block[1])) {
      problems.push(`${i + 2}: 第二行不是分隔行 →「${block[1].slice(0, 40)}」`);
    } else {
      const want = cols(block[0]);
      block.forEach((l, k) => {
        const got = cols(l);
        if (got !== want) problems.push(`${i + k + 1}: 列数 ${got}，表头是 ${want} →「${l.slice(0, 46)}」`);
      });
    }
    i = j;
  }
  totalProblems += problems.length;
  const rel = path.relative(root, file);
  if (problems.length) {
    console.log(`✗ ${rel} —— ${problems.length} 处`);
    problems.forEach((p) => console.log(`   ${p}`));
  } else {
    console.log(`✓ ${rel}`);
  }
}
console.log(totalProblems ? `\n合计 ${totalProblems} 处待修` : '\n全部表格列数一致');
process.exit(totalProblems ? 1 : 0);
