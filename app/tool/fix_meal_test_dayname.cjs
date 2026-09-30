// 顶层函数里没有 `this`，测试里的日期常量改名 dayStamp：
// 只需要把插值 `$day#` 全量换成 `$dayStamp#`（一处正则，避免锚互相吃掉）。
const fs = require('fs');
const p = 'test/meal_reminder_r47_test.dart';
const s = fs.readFileSync(p, 'utf8');
const before = (s.match(/\$day#/g) || []).length;
if (before === 0) { console.error('✘ 一处 $day# 都没命中——脚本别白跑'); process.exit(1); }
const out = s.replace(/\$day#/g, '$dayStamp#');
if (/\$day#/.test(out)) { console.error('✘ 还有残留'); process.exit(1); }
fs.writeFileSync(p, out);
console.log(`✔ 换了 ${before} 处插值；this.day 那处由 Edit 单独改`);
