// R46 · 收尾：只处理新加的那段 kEndpoints 条目（从 /status 行到列表结尾），
// 把 JSON.stringify 留下的双引号改回单引号。范围外一字不动。
const fs = require('fs');
const file = 'D:/dev_workplace/flutter_te/babyco/server/lib/src/server_state.dart';
const lines = fs.readFileSync(file, 'utf8').split('\n');

const start = lines.findIndex((l) => l.includes("'path': '/status'"));
if (start < 0) throw new Error('未找到 /status 起点');
let end = -1;
for (let i = start; i < lines.length; i++) {
  if (lines[i] === '];') { end = i; break; }
}
if (end < 0) throw new Error('未找到列表结尾');
// 往回退到该条目的 '{' 行
let from = start;
while (from > 0 && lines[from].trim() !== '{') from--;

let n = 0;
for (let i = from; i < end; i++) {
  if (!lines[i].includes('"')) continue;
  const next = lines[i].replace(/"([^"]*)"/g, (m, g) => {
    if (g.includes("'")) return m;
    n++;
    return "'" + g + "'";
  });
  lines[i] = next;
}
if (n < 30) throw new Error('替换命中过少（' + n + '），范围或内容有出入，未写入');
const out = lines.join('\n');
fs.writeFileSync(file, out);
console.log('✔ 处理区间 ' + (from + 1) + '~' + end + ' 行，双引号→单引号 ' + n + ' 处');
