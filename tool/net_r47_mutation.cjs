// R47 第七段（网络恢复即同步）的反向验证：摘掉三处**判定**，看测试是否真的红。
//
// 这一路没有算术可摘——它全部是判定，所以三刀都砍在决策上（§7.10：摘算术谁都会红）：
//   firstEvent —— 「第一个事件只记录不触发」。摘了它，每次开 App 都多打一轮同步，
//                 而启动路径本来就已经同步过一次。
//   edge       —— 「只有离线→在线的上升沿才算恢复」。摘了它，wifi 切移动网络
//                 （用户根本没断过）也会触发同步，"恢复"变成"任何变化"。
//   merge      —— 「窗口内的多次上升沿合并成一次」。摘了它（去抖窗口归零），
//                 刚通的那一秒会连环打服务端。
// 用法：node tool/net_r47_mutation.cjs firstEvent|edge|merge|restore
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const TARGET = path.join(ROOT, 'app', 'lib', 'data', 'net_wake.dart');
const SNAP = path.join(ROOT, 'dist', 'net_wake_pristine_r47net.dart');

const mode = process.argv[2];
const guard = (label, cond, extra) => {
  if (!cond) { console.error('✘ ' + label + (extra ? '  [' + extra + ']' : '')); process.exit(1); }
  console.log('✔ ' + label);
};

if (mode === 'restore') {
  guard('快照在', fs.existsSync(SNAP));
  const s = fs.readFileSync(SNAP, 'utf8');
  guard('快照里是原逻辑（首事件）', s.includes('    final previous = lastResults;'));
  guard('快照里是原逻辑（上升沿）', s.includes('    if (!isOffline(previous) || isOffline(results)) return;'));
  guard('快照里是原逻辑（合并窗口）', s.includes('    _timer = Timer(_debounce, () async {'));
  fs.writeFileSync(TARGET, s);
  guard('装回后与快照逐字节一致', fs.readFileSync(TARGET).equals(fs.readFileSync(SNAP)));
  console.log('✔ 装回 app/lib/data/net_wake.dart');
  process.exit(0);
}

const MUT = {
  // ★ 锚在声明那一行，不摘 `if (previous == null) return;` 本身：
  //   那一行同时是 previous 的**空安全提升**，直接摘掉会编译不过
  //   （List<ConnectivityResult>? 传给 List<ConnectivityResult>），变异就变成"假红"。
  //   改成「首事件把上一次当成离线」——类型照旧提升，被摘掉的才是行为。
  firstEvent: {
    from: '    final previous = lastResults;',
    to: '    // ★ 变异：首事件不再「只记录」，把上一次当成离线 = 开 App 就补一轮同步\n    final previous = lastResults ?? const [ConnectivityResult.none];',
  },
  edge: {
    from: '    if (!isOffline(previous) || isOffline(results)) return;',
    to: '    // ★ 变异：不看上一次读数，任何"现在在线"都算恢复\n    if (isOffline(results)) return;',
  },
  merge: {
    from: '    _timer = Timer(_debounce, () async {',
    to: '    // ★ 变异：去抖窗口归零，一次恢复里的每条上升沿都立刻同步一遍\n    _timer = Timer(Duration.zero, () async {',
  },
};
const m = MUT[mode];
if (!m) { console.error('✘ 模式只能是 firstEvent / edge / merge / restore，收到：' + mode); process.exit(1); }

const src = fs.readFileSync(TARGET, 'utf8');
if (!fs.existsSync(SNAP)) { fs.writeFileSync(SNAP, src); console.log('✔ 改前快照已存 dist/net_wake_pristine_r47net.dart'); }
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
console.log('✔ 变异[' + mode + ']已写入 app/lib/data/net_wake.dart（跑完记得 restore）');
