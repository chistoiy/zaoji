// 修 R47 第八段原型里「球的默认状态被写四遍」的漂移：
// S 的初始化写了一份形状，三处重置又各写一份 `{x:null,y:null}`——
// 新加的 side/collapsed 会被重置抹掉（起第二张表时耳朵态直接失效）。
// 用法：node tool/proto_fab_default_r47.cjs
const fs = require('fs');
const path = require('path');
const ROOT = path.resolve(__dirname, '..');
const TARGET = path.join(ROOT, 'zaoji-prototype.html');
const SNAP = path.join(ROOT, 'dist', 'zaoji-prototype_before_r47fabdefault.html');

const before = fs.readFileSync(TARGET, 'utf8');
if (!fs.existsSync(SNAP)) fs.writeFileSync(SNAP, before);
const EOL = before.includes('\r\n') ? '\r\n' : '\n';
const j = (s) => s.replace(/\n/g, EOL);
let out = before;

// 1) 三处整体重置 → 统一走 fabDefault()
const resetFrom = "  S.fab = { x:null, y:null };";
const resetTo = "  S.fab = fabDefault();";
const hits = out.split(j(resetFrom)).length - 1;
if (hits !== 3) { console.error('✘ 重置点应是 3 处，实际 ' + hits); process.exit(1); }
out = out.split(j(resetFrom)).join(j(resetTo));
console.log('✔ 三处 S.fab 重置改走 fabDefault()');

// 2) 工厂函数放在计时器那组 helper 之前（activeTimer 上面）
const anchor = "function activeTimer() {";
if (out.split(j(anchor)).length - 1 !== 1) { console.error('✘ activeTimer 锚不唯一'); process.exit(1); }
out = out.replace(j(anchor), j(
  "/* 悬浮球的默认状态：位置未定（用 CSS 默认右下角）、贴右、不收起。\n" +
  "   ★ 只这一份：以前初始化与三处重置各写一遍形状，加字段时漏改一处就会静默丢态。 */\n" +
  "function fabDefault() { return { x:null, y:null, side:'right', collapsed:false }; }\n\n" +
  anchor));
console.log('✔ 加了 fabDefault()');

// 3) S 的初始化指向同一份口径（注释留个钩子，防止有人再抄一份）
const defFrom = "  fab:{ x:null, y:null, side:'right', collapsed:false },";
const defTo = "  fab:{ x:null, y:null, side:'right', collapsed:false }, // = fabDefault() 的形状，改这里要一起改它";
if (out.split(j(defFrom)).length - 1 !== 1) { console.error('✘ S.fab 初始化锚不对'); process.exit(1); }
out = out.replace(j(defFrom), j(defTo));
console.log('✔ S.fab 初始化处标了同步钩子');

// 4) 走查出口把 fabDefault 也交出去（期望值要从这份口径现算，不抄字面量）
const hook = "  deviceSize: deviceSize,\n";
if (out.split(j(hook)).length - 1 !== 1) { console.error('✘ deviceSize 出口锚不对'); process.exit(1); }
out = out.replace(j(hook), j(hook) + j("  fabDefault: fabDefault,\n"));
console.log('✔ __zaoji 暴露 fabDefault');

if (out.includes(j(resetFrom))) { console.error('✘ 还有残留的整体重置'); process.exit(1); }
fs.writeFileSync(TARGET, out);
console.log(`✔ 已落盘（${before.length} → ${out.length} 字节）`);
