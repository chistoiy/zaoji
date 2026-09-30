// 修正 meal_reminder_r47_test.dart 里写错的 expect 第三参数：
// flutter_test 的 expect 只有 (actual, matcher, {reason, skip})，第三个位置参数是编译错误。
const fs = require('fs');
const p = 'test/meal_reminder_r47_test.dart';
let s = fs.readFileSync(p, 'utf8');
const EOL = s.includes('\r\n') ? '\r\n' : '\n';
const pairs = [
  ["      expect(sent.single.title, '18:15 夜宵 · 还剩 45 分钟开饭', sent.single.title);",
    "      expect(sent.single.title, '18:15 夜宵 · 还剩 45 分钟开饭');"],
  ["      expect(sent.single.title.startsWith('18:00 晚餐'), isTrue, sent.single.title);",
    "      expect(sent.single.title.startsWith('18:00 晚餐'), isTrue, reason: sent.single.title);"],
  ["      expect(again.single.title.startsWith('18:30 夜宵'), isTrue, again.single.title);",
    "      expect(again.single.title.startsWith('18:30 夜宵'), isTrue, reason: again.single.title);"],
  ["      expect(digest.summary, contains('道菜'), digest.summary);",
    "      expect(digest.summary, contains('道菜'), reason: digest.summary);"],
  ["      expect(digest.summary, contains('备菜'), digest.summary);",
    "      expect(digest.summary, contains('备菜'), reason: digest.summary);"],
  ["      expect(digest.summary, contains('步骤'), digest.summary);",
    "      expect(digest.summary, contains('步骤'), reason: digest.summary);"],
  ["      expect(sent.single.title, contains('测试晚餐'), sent.single.title);",
    "      expect(sent.single.title, contains('测试晚餐'), reason: sent.single.title);"],
];
for (const [from, to] of pairs) {
  const f = from.split('\n').join(EOL), t = to.split('\n').join(EOL);
  const n = s.split(f).length - 1;
  if (n !== 1) { console.error('✘ 锚命中 ' + n + ' 次：' + from); process.exit(1); }
  s = s.replace(f, t);
  console.log('✔ ' + from.slice(6, 60));
}
fs.writeFileSync(p, s);
console.log('✔ 全部落盘');
