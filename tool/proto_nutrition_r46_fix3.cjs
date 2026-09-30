/* eslint-disable */
/**
 * R46 第三刀：把「超限」改成真正的**二次确认**。
 * 上一版在输入时就点亮确认条，于是底部「保存」一按就直接落库——
 * 「要二次确认」（FR-AI-74）变成了「看一眼就能存」。改成：
 * 输入只负责把之前点亮的确认条**收回**（数值改回正常范围就不该再拦人），
 * 第一次点保存 → 只点亮确认条、不落库；再点「确定保存」才落。
 * 护栏同前：快照 + 锚点恰好一次 + vm 语法自检。
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const root = path.resolve(__dirname, '..');
const target = path.join(root, 'zaoji-prototype.html');
const snap = path.join(root, 'dist', 'proto_before_r46_fix3.html');
const src = fs.readFileSync(target, 'utf8');
fs.writeFileSync(snap, src, 'utf8');
const L = src.split(/\r?\n/);

const OLD = "  f.warn = (k === 'per' || k === 'total') && f.per > 20000;";
const NEW = "  // 只在**已经点亮**时负责收回：数值改回正常范围就不该再拦人。",
    NEW2 = "  // 点亮由「保存」那一步负责——点一次只确认、再点才落库（FR-AI-74 的二次确认）。",
    NEW3 = "  if (f.warn && !(f.per > 20000)) f.warn = false;";
const hits = [];
L.forEach((l, i) => { if (l === OLD) hits.push(i); });
if (hits.length !== 1) { console.error(`ABORT: 锚点命中 ${hits.length} 次，未改动。`); process.exit(1); }
L.splice(hits[0], 1, NEW, NEW2, NEW3);

const out = L.join('\r\n');
const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/g;
let m, k = 0;
while ((m = re.exec(out))) {
  k++;
  if (!/\S/.test(m[1])) continue;
  try { new vm.Script(m[1], { filename: 'inline#' + k }); }
  catch (err) { console.error('ABORT: 语法不过 ' + err.message); process.exit(1); }
}
fs.writeFileSync(target, out, 'utf8');
console.log(`OK 内联脚本 ${k} 段通过；${Buffer.byteLength(src, 'utf8')} → ${Buffer.byteLength(out, 'utf8')} B`);
