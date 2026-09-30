// R47 第八段（悬浮球两态 / 占场互斥 / 到点振动 / 全屏含通知栏）的反向验证。
//
// 这一轮没有算术可摘——四刀全砍在**决策**上（§7.10：摘算术谁都会红）：
//   occupy  —— 「计时界面占场时球必须让位」。摘了它，全屏页右下角还压着一颗球，
//              而面板里的「全屏/关闭」按钮会被球吃掉（点不到才是症状）。
//   snap    —— 「靠边松手才收成耳朵」。摘了它，吸边收起这件用户要的事没了。
//   vibrate —— 「振动跟着 vibrateOn 传到通知本身」。摘了它，开关变成装饰，
//              而且回到那条老路：只剩 HapticFeedback，被系统「触摸反馈」一关就没感觉。
//   overlay —— 「这一屏声明浅色状态栏图标」。摘了它，深色全屏页顶上是深色图标，
//              通知栏那一条看着就不属于这页（需求原话：「全屏要包含通知栏的」）。
//
// 用法：node tool/r47tf_mutation.cjs            （四刀全跑：变异→测红→装回→逐字节比）
//       node tool/r47tf_mutation.cjs occupy     （只跑一刀）
//       node tool/r47tf_mutation.cjs restore    （手动装回全部）
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const APP = path.join(ROOT, 'app');
const SNAPDIR = path.join(ROOT, 'dist');

const rel = (...p) => path.join(APP, ...p);
const MUTS = {
  occupy: {
    file: rel('lib', 'ui', 'timer_overlay.dart'),
    snap: path.join(SNAPDIR, 'timer_overlay_pristine_r47tf.dart'),
    from: '        board.count > 0 && !board.screenOccupied && (visible?.call() ?? true);',
    to: '        // ★ 变异：占场判定被摘掉——球在谁上面都照样挂着\n' +
        '        board.count > 0 && (visible?.call() ?? true);',
    mustKeep: ['screenOccupied', '_TimerEar'],
    test: 'test/timer_ball_r47_test.dart',
    name: '全屏独占',
    expect: '全屏页开着：球与耳朵都不该在屏幕上',
  },
  snap: {
    file: rel('lib', 'ui', 'timer_overlay.dart'),
    snap: path.join(SNAPDIR, 'timer_overlay_pristine_r47tf.dart'),
    from: '                  _collapsed = true;',
    to: '                  // ★ 变异：靠边松手也不收成耳朵（吸边白做了）',
    mustKeep: ['screenOccupied', '_TimerEar'],
    test: 'test/timer_ball_r47_test.dart',
    name: '吸边与耳朵',
    expect: '拖到右边缘松手：收成耳朵，完整球消失',
  },
  vibrate: {
    file: rel('lib', 'main.dart'),
    snap: path.join(SNAPDIR, 'main_pristine_r47tf.dart'),
    from: '    unawaited(_alert.fire(fired,\n' +
        '        sound: _store.kitchenPrefs.soundOn, vibrate: _store.kitchenPrefs.vibrateOn));',
    to: '    // ★ 变异：振动不再跟开关走（回到只靠 HapticFeedback 的老路）\n' +
        '    unawaited(_alert.fire(fired, sound: _store.kitchenPrefs.soundOn));',
    mustKeep: ['vibrate: _store.kitchenPrefs.vibrateOn'],
    test: 'test/notify_r47_test.dart',
    name: '振动那一路',
    expect: '开关跟着 vibrateOn 传到**通知本身**',
  },
  overlay: {
    file: rel('lib', 'ui', 'timer_full_page.dart'),
    snap: path.join(SNAPDIR, 'timer_full_page_pristine_r47tf.dart'),
    from: '  statusBarIconBrightness: Brightness.light,',
    to: '  // ★ 变异：不转浅色 → 深色页顶上是深色状态栏图标，通知栏看着不归这页管\n' +
        '  statusBarIconBrightness: Brightness.dark,',
    mustKeep: ['appOverlayStyle', '_kTimerFullOverlay', '_underlying'],
    test: 'test/timer_ball_r47_test.dart',
    name: '浅色状态栏图标',
    expect: '这一屏声明浅色状态栏图标',
  },
  // ★ 这一刀验的是**收尾**：框架在读不到注解时直接 return，不会替你把样式还原，
  //   所以退出全屏必须显式设回"底下那屏该有的"。摘掉它（这里改成"设回自己那套"，
  //   等价于没收尾但字段仍被读，不会被 unused_field 混进证据），
  //   症状是「退出全屏后整个 App 的状态栏图标都是白的」。
  noRestore: {
    file: rel('lib', 'ui', 'timer_full_page.dart'),
    snap: path.join(SNAPDIR, 'timer_full_page_pristine_r47tf.dart'),
    from: '    SystemChrome.setSystemUIOverlayStyle(appOverlayStyle(_underlying));',
    to: '    // ★ 变异：收尾设成了"这一屏自己那套"，等于没恢复\n' +
        '    SystemChrome.setSystemUIOverlayStyle(_kTimerFullOverlay);',
    mustKeep: ['appOverlayStyle', '_kTimerFullOverlay', '_underlying'],
    test: 'test/timer_ball_r47_test.dart',
    name: '系统栏样式',
    expect: '退出这屏要显式推一记',
  },
};

const guard = (label, cond, extra) => {
  if (!cond) {
    console.error('✘ ' + label + (extra ? '  [' + extra + ']' : ''));
    process.exit(1);
  }
  console.log('✔ ' + label);
};

/** 变异过程中的硬校验：抛出去，让 finally 有机会把源码装回（不能直接 exit）。 */
function must(label, cond, extra) {
  if (!cond) throw new Error(label + (extra ? '  [' + extra + ']' : ''));
  console.log('✔ ' + label);
}

/** 行尾跟随目标文件（记过的坑：LF 锚在 CRLF 文件里一条都命不中）。 */
function join(s, crlf) {
  return crlf ? s.replace(/\n/g, '\r\n') : s;
}

function applyMutation(m) {
  const src = fs.readFileSync(m.file, 'utf8');
  if (!fs.existsSync(m.snap)) {
    fs.writeFileSync(m.snap, src);
    console.log('✔ 改前快照已存 ' + path.relative(ROOT, m.snap));
  }
  const snap = fs.readFileSync(m.snap, 'utf8');
  const crlf = src.includes('\r\n');
  const from = join(m.from, crlf), to = join(m.to, crlf);
  must('快照里是原逻辑', snap.includes(from), m.name);
  must('锚唯一命中', src.split(from).length - 1 === 1, 'n=' + (src.split(from).length - 1));
  const out = src.replace(from, to);
  fs.writeFileSync(m.file, out);
  must('变异已落盘', fs.readFileSync(m.file, 'utf8').includes(to));
}

function restore(m) {
  guard('快照在', fs.existsSync(m.snap), path.relative(ROOT, m.snap));
  const snap = fs.readFileSync(m.snap, 'utf8');
  // ★ 快照是**某一时刻**的原样：如果打完快照之后又往这个文件里加了新代码，
  //   直接写回快照就会把新代码一起抹掉（本会话真就这么丢过一次 dispose 收尾）。
  //   所以装回前后都验一遍"这个文件必须还有的东西"，缺了就拒绝装回而不是静默覆盖。
  const missing = (m.mustKeep || []).filter((k) => !snap.includes(k));
  guard('快照不是过期版本（含全部 mustKeep 标记）', missing.length === 0,
    '快照里缺：' + missing.join(' / ') + ' → 说明快照打得太早，删掉 dist 里那份快照重跑');
  fs.writeFileSync(m.file, snap);
  guard('装回后与快照逐字节一致', fs.readFileSync(m.file).equals(fs.readFileSync(m.snap)),
    path.relative(ROOT, m.file));
}

/** 跑一个筛出来的用例；返回是否**如预期地红**。 */
function runCase(m) {
  const env = { ...process.env };
  for (const k of ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy']) delete env[k];
  env.no_proxy = 'localhost,127.0.0.1,::1';
  env.NO_PROXY = env.no_proxy;
  const r = spawnSync('flutter', ['test', m.test, '--plain-name', m.name], {
    cwd: APP, env, encoding: 'utf8', shell: process.platform === 'win32',
  });
  const out = (r.stdout || '') + (r.stderr || '');
  const red = r.status !== 0;
  const hitExpected = out.includes(m.expect);
  return { red, hitExpected, tail: out.split(/\r?\n/).filter((l) => /^\d\d:\d\d/.test(l)).slice(-3).join(' | ') };
}

const mode = process.argv[2];
if (mode === 'restore') {
  const seen = new Set();
  for (const m of Object.values(MUTS)) {
    if (seen.has(m.file)) continue;
    seen.add(m.file);
    if (!fs.existsSync(m.snap)) {
      console.log('· ' + path.relative(ROOT, m.file) + ' 没有快照（本轮没动过它），跳过');
      continue;
    }
    restore(m);
  }
  console.log('✔ 全部装回');
  process.exit(0);
}

const keys = mode ? [mode] : Object.keys(MUTS);
guard('模式合法', keys.every((k) => MUTS[k]), '可选：' + Object.keys(MUTS).join(' / ') + ' / restore');

// ★ 变异跑中途**绝不能 process.exit**：那样 finally 不执行，源码会留在变异态
//   （第一版就栽过一次，靠手动 restore 才收回来）。所以这里只用软检查记账。
let bad = 0;
const check = (label, cond, extra) => {
  if (cond) {
    console.log('✔ ' + label);
  } else {
    console.error('✘ ' + label + (extra ? '  [' + extra + ']' : ''));
    bad++;
  }
};
for (const k of keys) {
  const m = MUTS[k];
  console.log('\n—— 变异 ' + k + '（期望红：' + m.expect + '）');
  try {
    applyMutation(m);
    const r = runCase(m);
    check('摘掉这条决策后测试真的红', r.red, r.tail);
    check('红的就是这一条（不是编译错或别的用例）', r.hitExpected);
  } catch (e) {
    console.error('✘ 变异 ' + k + ' 没做成：' + e.message);
    bad++;
  } finally {
    restore(m);
  }
}
console.log('\n' + (bad ? '有 ' + bad + ' 处没验到（说明用例没真的钉住这条决策）' : '全部验到：摘决策必红、装回必绿'));
process.exit(bad ? 1 : 0);
