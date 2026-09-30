// R46 · 找「有列、零代码」的摆设列（查漏补缺判定口径第 2 类的取证工装）。
//
// ⚠️ 第一版只按 snake_case 匹配，误报了 5 列：ai_config 的 base_url/key_hint 等
//    在代码里以 **camelCase** 出现（`cfg.baseUrl`、`'baseUrl': ...`）。
//    教训：**工装先自证**——凡是报「零引用」，必须把 snake / camel / 生成的
//    drift 属性名三种写法都试过才许写进结论。
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const read = (p) => fs.readFileSync(path.join(root, p), 'utf8');
const schema = read('shared/lib/src/schema.dart');

function walk(dir, out = []) {
  for (const f of fs.readdirSync(path.join(root, dir), { withFileTypes: true })) {
    const p = `${dir}/${f.name}`;
    if (f.isDirectory()) walk(p, out);
    else if (p.endsWith('.dart')) out.push(p);
  }
  return out;
}
// schema.dart 自己不算「引用」；其余源码 + 测试 + 原型都算能力已接线的证据。
const sources = [
  ...walk('app/lib'), ...walk('app/test'),
  ...walk('server/lib'), ...walk('server/test'),
  ...walk('shared/lib').filter((p) => !p.endsWith('schema.dart')),
  ...walk('shared/test'),
].map(read);
sources.push(fs.readFileSync(path.join(root, 'zaoji-prototype.html'), 'utf8'));
const hay = sources.join('\n');

const cols = [...new Set([...schema.matchAll(/ColumnSpec\('([a-z0-9_]+)'/g)].map((m) => m[1]))];
const camel = (c) => c.replace(/_([a-z0-9])/g, (_, ch) => ch.toUpperCase());

const dead = [];
for (const c of cols) {
  const forms = [c, camel(c), c.replace(/^is_/, ''), 'is' + camel(c)[0].toUpperCase() + camel(c).slice(1)];
  const hit = forms.some((f) =>
    new RegExp(`['"\`.\\[\\s(]${f}\\b|\\b${f}['"\\]\\[\\s(]`).test(hay) || hay.includes(`'${f}'`));
  if (!hit) dead.push(c);
}
console.log(`列总数 ${cols.length}｜snake/camel/drift 全零引用 ${dead.length}`);
for (const c of dead) console.log('  · ' + c + '  →  camel: ' + camel(c));
