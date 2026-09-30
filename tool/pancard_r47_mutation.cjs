// R47 第五段（厨房告警卡）的反向验证：把两条口径各摘一次，看测试是否真的红。
//
// 为什么要这道工序：「测试全绿」只说明测试跑过了，不说明测试咬得动。
// 这张卡有两处是**决策**而不是算术，摘掉必须响：
//   empty  —— 「有数据才出现」（FR-PAN-06 的验收判据）。摘了就是空库存也挂一张空卡。
//   button —— 「已经在目的地了就不给按钮」。摘了「能做什么」段上那颗按钮变成点了没反应。
// 用法：node tool/pancard_r47_mutation.cjs empty|button|restore
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const TARGET = path.join(ROOT, 'app', 'lib', 'ui', 'kitchen_page.dart');
const SNAP = path.join(ROOT, 'dist', 'kitchen_page_pristine_r47card.dart');

const mode = process.argv[2];
const guard = (label, cond, extra) => {
  if (!cond) { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); process.exit(1); }
  console.log('✔ ' + label);
};

if (mode === 'restore') {
  guard('快照在', fs.existsSync(SNAP));
  const s = fs.readFileSync(SNAP, 'utf8');
  guard('快照里是原逻辑', s.includes('if (a.isEmpty) return const SizedBox.shrink();'));
  fs.writeFileSync(TARGET, s);
  console.log('✔ 装回 ' + path.relative(ROOT, TARGET));
  process.exit(0);
}

const MUT = {
  empty: {
    from: '    if (a.isEmpty) return const SizedBox.shrink();',
    to: '    // ★ 变异：摘掉「有数据才出现」这道判据（空库存也挂卡）\n    if (false) return const SizedBox.shrink();',
  },
  button: {
    from: '            if (segment != 1)',
    to: '            // ★ 变异：摘掉「已在目的地就不给按钮」，让它在推荐段也挂着\n            if (true)',
  },
};
const m = MUT[mode];
if (!m) { console.error('✘ 模式只能是 empty / button / restore，收到：' + mode); process.exit(1); }

const src = fs.readFileSync(TARGET, 'utf8');
if (!fs.existsSync(SNAP)) { fs.writeFileSync(SNAP, src); console.log('✔ 改前快照已存'); }
const snap = fs.readFileSync(SNAP, 'utf8');
guard('快照里是原逻辑', snap.includes(m.from), mode);

// 行尾跟随目标文件（记过的坑：LF 锚在 CRLF 文件里一条都命不中）
const crlf = src.includes('\r\n');
const join = (s) => (crlf ? s.replace(/\n/g, '\r\n') : s);
const from = join(m.from), to = join(m.to);
guard('锚唯一命中', src.split(from).length - 1 === 1, 'n=' + (src.split(from).length - 1));

const out = src.replace(from, to);
guard('变异已落盘', out.includes(to) && !out.includes(from));
fs.writeFileSync(TARGET, out);
console.log('✔ 变异[' + mode + ']已写入 app\\lib\\ui\\kitchen_page.dart（跑完记得 restore）');
