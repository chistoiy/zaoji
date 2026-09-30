// R46 · 快赢包：搜索要命中标签（FR-REC-10「按名称、食材、标签搜索」）。
// 先改原型（口径的唯一来源），再动实现。
const fs = require('fs');
const path = require('path');
const file = path.resolve(__dirname, '../zaoji-prototype.html');
const snap = path.resolve(__dirname, '../dist/proto_before_r46tagsearch.html');
const src = fs.readFileSync(file, 'utf8');
fs.writeFileSync(snap, src);

const FROM = `  if (q) list = list.filter(function (r) {
    return r.name.toLowerCase().indexOf(q) >= 0 ||
      r.sub.toLowerCase().indexOf(q) >= 0 ||
      r.ings.some(function (i) { return i.n.toLowerCase().indexOf(q) >= 0; });
  });`.replace(/\n/g, '\r\n'); // ★ 原型整文件 CRLF，多行锚点必须跟着换行风格走
const TO = `  if (q) list = list.filter(function (r) {
    // FR-REC-10：菜名 / 副标题 / 食材 / **标签**都算命中——
    // 标签是用户自己贴的分类词，搜「红烧」搜不到自己的红烧菜是说不过去的
    return r.name.toLowerCase().indexOf(q) >= 0 ||
      r.sub.toLowerCase().indexOf(q) >= 0 ||
      r.ings.some(function (i) { return i.n.toLowerCase().indexOf(q) >= 0; }) ||
      Object.keys(r.tags || {}).some(function (k) {
        return (r.tags[k] || []).some(function (t) { return t.toLowerCase().indexOf(q) >= 0; });
      });
  });`.replace(/\n/g, '\r\n');

const n = src.split(FROM).length - 1;
if (n !== 1) throw new Error('锚点命中 ' + n + ' 次，应为 1');
const out = src.replace(FROM, TO);
if (out.length <= src.length) throw new Error('体积未增长，替换没生效');
fs.writeFileSync(file, out);
console.log(`✔ 原型搜索补标签命中，${src.length} -> ${out.length}；快照 ${snap}`);
