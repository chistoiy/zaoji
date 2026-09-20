import 'media.dart';
import 'media_gc.dart';
import 'server_state.dart';
import 'config.dart';

/// 服务状态页。
///
/// 刻意**不引任何外部资源**（字体、CSS 全内联）：
/// 这台笔记本可能根本没连外网，页面必须离线也能正常渲染。
Future<String> statusPageHtml(ServerState st, List<String> ips) async {
  final h = await st.healthPayload();
  final writable = h['dataDirWritable'] == true;
  final webReady = h['webReady'] == true;
  final tls = h['tlsReady'] == true;
  final tlsPort = st.config.tlsPort;
  final uptime = formatUptime(st.uptime);

  // ── 数据底座摘要 ──
  // 表按「有数据的排前面」展示：空库时一眼看出是空的，
  // 有数据时一眼看出哪张表有多少行，不用去翻数据库。
  final db = (h['db'] as Map).cast<String, Object?>();
  final counts = (db['rowCounts'] as Map).cast<String, int>();
  final maxSeq = db['maxSeq'];
  final sqliteVer = '${db['sqliteVersion']}';
  final schemaVer = '${db['schemaVersion']}';
  final dbPath = '${db['path']}';
  final sizeBytes = db['sizeBytes'] as int?;
  final dbSize = sizeBytes == null
      ? ''
      : '${(sizeBytes / 1024).toStringAsFixed(sizeBytes > 1024 * 1024 ? 0 : 1)} KB';

  final sortedCounts = counts.entries.toList()
    ..sort((a, b) => b.value != a.value ? b.value.compareTo(a.value) : a.key.compareTo(b.key));

  const tablePurpose = {
    'recipe': '菜谱',
    'ingredient': '食材行',
    'step': '做法步骤',
    'member': '家庭成员与忌口',
    'menu': '某一餐的安排',
    'menu_item': '菜单里的菜',
    'cook_session': '做菜模式进度',
    'pantry_item': '食材库存',
    'nutrition': '热量估算',
    'conflict_item': '冲突箱（要用户选，不静默覆盖）',
  };

  final dataRows = sortedCounts.map((e) {
    final purpose = tablePurpose[e.key] ?? '';
    final dim = e.value == 0 ? ' style="color:var(--muted)"' : '';
    return '<tr$dim><td><code>${esc(e.key)}</code></td>'
        '<td style="text-align:right"><code>${e.value}</code></td>'
        '<td>${esc(purpose)}</td></tr>';
  }).join();

  // ── 媒体占用与孤儿（R18）──
  // 「库里的引用数」与「盘上的图片数」放在一起看才有意义：差额就是孤儿。
  // 这里顺便把 dry-run 的结果显示出来——**看得见的东西才会被处理**；
  // 但页面本身不提供删除按钮：删除不可逆，应当在命令行里由人显式执行。
  final mediaStats = MediaStats.fromJson(
      (h['media'] as Map?)?.cast<String, Object?>() ?? const {});
  final gcPlan = MediaGc.plan(
    media: st.media,
    referenced: st.db.referencedCoverShas(),
  );
  final orphanNote = gcPlan.isEmpty
      ? '<p class="hint">没有可回收的孤儿图片。</p>'
      : '<p class="hint">有 <b>${gcPlan.orphanFileCount}</b> 个文件无人引用，'
          '可回收约 <b>${formatBytes(gcPlan.reclaimableBytes)}</b>；另有 '
          '<b>${gcPlan.protectedFresh.length}</b> 张在 '
          '${MediaGc.defaultGrace.inHours} 小时宽限期内（刚上传、引用行还没推上来，不是垃圾）。<br>'
          '确认后在本机执行：<code>curl.exe --noproxy "*" -X POST '
          'http://127.0.0.1:${st.config.port}/api/admin/media-gc?dry=0</code></p>';
  // 反向异常：库里有引用、盘上没文件。只提示，不自动「修复」——
  // 自动修复会把线索一起抹掉，而这通常意味着有人手动删过盘，值得看一眼。
  final danglingNote = gcPlan.danglingRefs.isEmpty
      ? ''
      : '<p class="hint">⚠️ 有 <b>${gcPlan.danglingRefs.length}</b> 个封面被菜谱引用、'
          '但盘上找不到文件。这属于异常（有人手动删过 <code>media/</code>？），'
          '请检查后再决定怎么处理。</p>';

  // ── 已配对设备 ──
  // 刻意**不在这里显示配对码**：状态页在局域网内谁都能打开，
  // 配对码只能从服务端本机取（api/pair/code 会校验来源地址）。
  final devices = st.sync.devices();
  final deviceRows = devices.isEmpty
      ? '<p class="hint">还没有设备配对过。在服务端这台电脑上打开 '
          '<code>http://127.0.0.1:${st.config.port}/api/pair/code</code> 取一个配对码，'
          '然后在 App 里输入。</p>'
      : '<table><thead><tr><th>设备</th><th>已同步到</th><th>最后活动</th></tr></thead><tbody>'
          '${devices.map((d) => '<tr><td>${esc(d.name)}'
              '<br><code style="font-size:11px;color:var(--muted)">${esc(d.id)}</code></td>'
              '<td><code>${d.syncCursor}</code></td>'
              '<td>${esc(d.lastSeenAt ?? '—')}</td></tr>').join()}'
          '</tbody></table>';

  final httpChips = ips
      .map((ip) => '<a class="addr" href="http://$ip:${st.config.port}/">'
          'http://$ip:${st.config.port}/</a>')
      .join();

  final tlsChips = ips
      .map((ip) => '<a class="addr is-tls" href="https://$ip:$tlsPort/">'
          'https://$ip:$tlsPort/</a>')
      .join();

  final addrSection = ips.isEmpty
      ? '<span class="addr is-muted">未探测到局域网地址（可能只有回环）</span>'
      : tls
          ? '<h2>HTTPS — iPhone / iPad 用这些</h2>'
              '<div>$tlsChips</div>'
              '<p class="hint">首次访问前，iPhone 要先装并信任 <code>ca.crt</code>：'
              '设置 → 通用 → VPN与设备管理 → 安装；再到「通用 → 关于本机 → 证书信任设置」'
              '打开 <b>完全信任</b>。只做第一步不做第二步，Safari 仍会报不安全。</p>'
              '<h2>HTTP — Android App 同步 / 临时调试</h2>'
              '<div>$httpChips</div>'
          : '<h2>HTTP — 手机 / 平板 / 其他电脑</h2>'
              '<div>$httpChips</div>'
              '<div class="warn"><b>未启用 HTTPS。</b>'
              '后果是 iPhone / iPad 上「屏幕常亮、计时通知、PWA 离线、调相机」四样能力全部失效——'
              'Safari 只把 <code>https://</code>、<code>localhost</code>、<code>file://</code> 当安全上下文，'
              '<code>http://192.168.x.x</code> 不是。<br>'
              '生成证书：<code>powershell -ExecutionPolicy Bypass -File tool\\make-cert.ps1</code></div>';

  final rows = kEndpoints.map((e) {
    final ready = e['status'] == 'ready';
    return '''
      <tr class="${ready ? '' : 'is-planned'}">
        <td><code>${esc('${e['method']}')}</code></td>
        <td><code class="path">${esc('${e['path']}')}</code></td>
        <td>${esc('${e['title']}')}</td>
        <td>${ready ? '<span class="tag tag-ok">可用</span>' : '<span class="tag tag-idle">规划中</span>'}</td>
      </tr>''';
  }).join();

  return '''<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>灶记 ZAOJI · 服务状态</title>
<!-- 内联 SVG 图标：不额外发一次请求，也不会在日志里刷 /favicon.ico 404 -->
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><rect width='100' height='100' rx='24' fill='%23D2491C'/><text x='50' y='74' font-size='62' text-anchor='middle' fill='%23FFF3E8'>%E7%81%B6</text></svg>">
<style>
:root{
  --paper:#FBF6EC; --paper-2:#F5EEE0; --ink:#231C15; --ink-2:#4A4238;
  --muted:#8E8274; --line:#E6DCC9; --accent:#D2491C; --amber:#B8801A;
  --ok:#37634A;
}
*{box-sizing:border-box}
body{
  margin:0;padding:34px 20px 60px;background:var(--paper);color:var(--ink);
  font-family:system-ui,-apple-system,'PingFang SC','Microsoft YaHei',sans-serif;
  font-size:14px;line-height:1.65;-webkit-font-smoothing:antialiased;
}
.wrap{max-width:820px;margin:0 auto}
.brand{display:flex;align-items:center;gap:12px;margin-bottom:26px}
.seal{
  width:42px;height:42px;border-radius:13px;flex-shrink:0;
  display:grid;place-items:center;color:#FFF3E8;font-size:19px;
  background:linear-gradient(150deg,#E2571F,#C33F14);
  box-shadow:0 5px 14px rgba(195,63,20,.28);
}
.brand h1{
  margin:0;font-size:19px;letter-spacing:.01em;
  font-family:'Songti SC','Noto Serif SC',Georgia,serif;font-weight:700;
}
.brand .sub{font-size:11.5px;color:var(--muted);letter-spacing:.06em;text-transform:uppercase;margin-top:1px}
.hero{
  background:var(--paper-2);border:1px solid var(--line);border-radius:14px;
  padding:22px 24px;margin-bottom:16px;
}
.hero-top{display:flex;align-items:center;gap:10px;font-size:15px;font-weight:600}
.pulse{
  width:9px;height:9px;border-radius:50%;background:var(--ok);flex-shrink:0;
  box-shadow:0 0 0 0 rgba(55,99,74,.5);animation:pulse 2s infinite;
}
@keyframes pulse{
  0%{box-shadow:0 0 0 0 rgba(55,99,74,.45)}
  70%{box-shadow:0 0 0 9px rgba(55,99,74,0)}
  100%{box-shadow:0 0 0 0 rgba(55,99,74,0)}
}
.hero-top .up{margin-left:auto;font-size:12.5px;color:var(--muted);font-weight:500}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(158px,1fr));gap:1px;
  background:var(--line);border-radius:10px;overflow:hidden;margin-top:18px}
.cell{background:var(--paper-2);padding:12px 14px}
.cell .k{font-size:11px;color:var(--muted);letter-spacing:.02em}
.cell .v{
  font-size:13.5px;font-weight:600;margin-top:5px;word-break:break-all;
  font-variant-numeric:tabular-nums;
}
h2{
  font-size:12px;color:var(--muted);letter-spacing:.1em;text-transform:uppercase;
  margin:30px 0 12px;font-weight:600;
}
.addr{
  display:inline-block;margin:0 8px 8px 0;padding:9px 14px;border-radius:9px;
  background:#FFF;border:1px solid var(--line);color:var(--accent);
  text-decoration:none;font-size:13.5px;font-weight:600;
  font-variant-numeric:tabular-nums;transition:.17s;
}
.addr:hover{border-color:var(--accent);transform:translateY(-1px);
  box-shadow:0 4px 12px rgba(210,73,28,.13)}
.addr.is-muted{color:var(--muted);font-weight:400;font-size:12.5px}
.addr.is-tls{background:rgba(55,99,74,.07);border-color:rgba(55,99,74,.3);color:var(--ok)}
.addr.is-tls:hover{border-color:var(--ok);box-shadow:0 4px 12px rgba(55,99,74,.15)}
.addr.is-plain{color:var(--ink-2)}
.hint{font-size:11.5px;color:var(--muted);line-height:1.75;margin:2px 0 0}
.warn{
  margin-top:12px;padding:13px 15px;border-radius:11px;font-size:12.5px;line-height:1.8;
  background:rgba(210,73,28,.06);border:1px solid rgba(210,73,28,.24);color:#8A3413;
}
.warn b{color:#6E2A0F}
.warn code{background:rgba(210,73,28,.09);color:#8A3413}
table{width:100%;border-collapse:collapse;font-size:13px;
  background:#FFF;border:1px solid var(--line);border-radius:12px;overflow:hidden}
th,td{padding:10px 14px;text-align:left;border-bottom:1px solid var(--line)}
th{font-size:11px;color:var(--muted);letter-spacing:.05em;font-weight:600;
  background:var(--paper-2);text-transform:uppercase}
tr:last-child td{border-bottom:0}
tr.is-planned{opacity:.52}
code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12px;
  background:var(--paper-2);padding:2px 6px;border-radius:5px;color:var(--ink-2)}
code.path{background:transparent;padding:0;color:var(--ink);font-weight:500}
.tag{font-size:10.5px;padding:2.5px 8px;border-radius:999px;font-weight:600;white-space:nowrap}
.tag-ok{background:rgba(55,99,74,.11);color:var(--ok)}
.tag-idle{background:rgba(142,130,116,.14);color:var(--muted)}
.note{
  margin-top:16px;padding:14px 16px;border-radius:11px;
  background:rgba(184,128,26,.08);border:1px solid rgba(184,128,26,.26);
  font-size:12.5px;color:#7A5610;line-height:1.75;
}
.note b{color:#5E4009}
.foot{margin-top:32px;font-size:11.5px;color:var(--muted);line-height:1.9}
@media (max-width:520px){
  body{padding:22px 14px 40px}
  .hero{padding:18px}
  th:nth-child(1),td:nth-child(1){display:none}
}
</style>
</head>
<body>
<div class="wrap">

  <div class="brand">
    <div class="seal">灶</div>
    <div>
      <h1>灶记 ZAOJI</h1>
      <div class="sub">Kitchen Ledger · Server</div>
    </div>
  </div>

  <div class="hero">
    <div class="hero-top">
      <span class="pulse"></span>
      <span>服务正在运行</span>
      <span class="up">已运行 $uptime</span>
    </div>
    <div class="grid">
      <div class="cell"><div class="k">版本</div><div class="v">v${esc(ServerConfig.version)}</div></div>
      <div class="cell"><div class="k">监听</div><div class="v">${esc(st.config.host)}:${st.config.port}</div></div>
      <div class="cell"><div class="k">运行时长</div><div class="v">$uptime</div></div>
      <div class="cell"><div class="k">启动于</div><div class="v">${esc(_hhmm(st.startedAt))}</div></div>
    </div>
    <div class="grid" style="margin-top:1px">
      <div class="cell" style="grid-column:1/-1">
        <div class="k">Server ID（客户端用它识别"是不是同一台服务器"）</div>
        <div class="v" style="font-family:ui-monospace,Menlo,monospace">${esc(st.serverId)}</div>
      </div>
    </div>
  </div>

  $addrSection

  <h2>接口</h2>
  <table>
    <thead><tr><th>方法</th><th>路径</th><th>说明</th><th>状态</th></tr></thead>
    <tbody>$rows</tbody>
  </table>

  <h2>已配对的设备</h2>
  $deviceRows

  <h2>数据</h2>
  <table>
    <thead><tr><th>表</th><th style="text-align:right">行数</th><th>说明</th></tr></thead>
    <tbody>$dataRows</tbody>
  </table>

  <h2>媒体</h2>
  <table>
    <thead><tr><th>类型</th><th style="text-align:right">数量</th><th style="text-align:right">占用</th><th>说明</th></tr></thead>
    <tbody>
      <tr><td>原图</td>
        <td style="text-align:right"><code>${mediaStats.originals}</code></td>
        <td style="text-align:right"><code>${formatBytes(mediaStats.originalBytes)}</code></td>
        <td>客户端压到 1600px / q82 后上传，内容寻址（同图只存一份）</td></tr>
      <tr><td>缩略图</td>
        <td style="text-align:right"><code>${mediaStats.thumbs}</code></td>
        <td style="text-align:right"><code>${formatBytes(mediaStats.thumbBytes)}</code></td>
        <td>服务端按需派生（640 / 1280 两档），派生物随时可重算</td></tr>
      <tr><td>数据库</td><td style="text-align:right">—</td>
        <td style="text-align:right"><code>$dbSize</code></td>
        <td>文字数据（菜谱、步骤、库存…），远小于照片</td></tr>
    </tbody>
  </table>
  $orphanNote
  $danglingNote

  <div class="note">
    <b>现在可以做什么</b><br>
    · Android App 里填上面的任一个地址，点「测试连接」应当返回本页的版本号与 Server ID；<br>
    · 用浏览器打开 <code>/api/ping</code> 会看到一段 JSON——这是客户端判断地址对不对的依据；<br>
    · <b>数据同步已可用</b>：在本机取一个配对码（<code>/api/pair/code</code>），
    在 App 里输入即可双向同步；推送幂等、冲突进冲突箱；<br>
    · <b>照片已可用</b>：App 里给菜品选封面 → 压到 1600px 上传；列表/详情按档位拉取缩略图；<br>
    · Web 端（iPhone / 平板）由本机直接托管，打开上面的 HTTPS 地址即可。<br><br>
    <b>还没做的</b>：大模型代理（<code>/api/ai/*</code>，Web 端专用通道）、
    局域网自动发现（mDNS，省得手填 IP）、带轮转的文件日志。
  </div>

  <div class="foot">
    数据目录：<code>${esc(st.config.dataDir.path)}</code>
    ${writable ? '' : '　⚠️ <b style="color:#D2491C">不可写，请检查权限</b>'}<br>
    数据库：<code>${esc(dbPath)}</code>　${dbSize}　
    <code>schema v$schemaVer</code>　SQLite $sqliteVer<br>
    变更序号：<code>${esc('$maxSeq')}</code>（客户端同步游标就停在这个号上）<br>
    Web 产物：${webReady ? '<code>${esc(st.config.webRoot!.path)}</code>（已托管，<code>/</code> 会返回它）' : '未提供（用 -w 参数指定 Flutter Web 产物目录）'}<br>
    灶记 ZAOJI · 家庭菜谱手账 · 仅用于家庭局域网
  </div>

</div>
</body>
</html>''';
}

/// 人类可读的字节数。磁盘占用这种东西写「1.4 MB」比「1432082」有用得多——
/// 状态页的读者是家里那个人，不是日志分析器。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}

/// 未找到页面。
String notFoundHtml(String path) => '''<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>404 · 灶记 ZAOJI</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><rect width='100' height='100' rx='24' fill='%23D2491C'/><text x='50' y='74' font-size='62' text-anchor='middle' fill='%23FFF3E8'>%E7%81%B6</text></svg>">
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#FBF6EC;color:#231C15;
  font-family:system-ui,-apple-system,'PingFang SC','Microsoft YaHei',sans-serif;padding:20px}
.box{text-align:center;max-width:460px}
h1{font-family:'Songti SC','Noto Serif SC',Georgia,serif;font-size:44px;margin:0 0 6px;color:#D2491C}
p{color:#8E8274;font-size:13.5px;line-height:1.8;margin:0 0 18px}
code{font-family:ui-monospace,Menlo,monospace;background:#F5EEE0;padding:2px 7px;border-radius:5px;font-size:12.5px}
a{display:inline-block;padding:9px 18px;border-radius:9px;background:#D2491C;color:#FFF3E8;
  text-decoration:none;font-size:13px;font-weight:600}
a:hover{background:#B93D14}
</style></head><body>
<div class="box">
  <h1>404</h1>
  <p>这个地址上没有东西：<br><code>${esc(path)}</code></p>
  <a href="/">回到服务状态页</a>
</div>
</body></html>''';

String formatUptime(Duration d) {
  if (d.inSeconds < 60) return '${d.inSeconds} 秒';
  if (d.inMinutes < 60) {
    final s = d.inSeconds % 60;
    return s == 0 ? '${d.inMinutes} 分钟' : '${d.inMinutes} 分 $s 秒';
  }
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h < 24) return m == 0 ? '$h 小时' : '$h 小时 $m 分';
  return '${d.inDays} 天 ${h % 24} 小时';
}

String _hhmm(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// HTML 转义。服务端渲染任何用户可控内容之前都必须过这一道。
String esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
