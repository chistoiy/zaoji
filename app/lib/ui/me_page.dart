import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import '../data/alert_scope.dart';
import '../data/meal_reminder.dart';
import '../data/recipe_store.dart';
import '../data/timer_alert.dart';
import '../data/sync/sync_engine.dart';
import '../data/sync/sync_scope.dart';
import '../data/store_scope.dart';
import '../models.dart';
import '../theme.dart';
import 'ai_settings_page.dart';
import 'conflict_box_page.dart';
import 'health_page.dart';
import 'members_page.dart';
import 'theme_page.dart';
import 'trash_page.dart';

/// 「我的」页（R13 最小可用版）：设备信息 + 同步配对与状态。
///
/// 这是从 `_ComingSoon` 占位升级来的第一块真实内容——
/// 同步引擎需要一个入口（填地址、输配对码、看状态、手动同步）。
/// R47 起再加一段「提醒与计时」偏好（FR-SET-02/03，落 local_pref 只影响本机）；
/// 剩下的 FR-SET-01（开饭前提醒）与 FR-SET-04~09 随各自的落点补齐，
/// **不提前摆死开关**（口径见 `_KitchenPrefsCard` 头注）。
class MePage extends StatefulWidget {
  const MePage({super.key, this.defaultServerUrl = kDefaultServerUrl});

  /// 未配对时地址框的预置值（同时也是占位提示）。
  /// 暴露成入参只为测试可注入假服务端地址——生产一律用 [kDefaultServerUrl]。
  final String defaultServerUrl;

  @override
  State<MePage> createState() => _MePageState();
}

/// 未配对时地址框的**预置值**：家里那台服务端电脑的局域网地址。
///
/// 它同时充当占位提示与初始文本——之前只当提示，于是 Android 上用户得
/// 把这一串**手打一遍**才能连上（而提示里已经写着它了）。占位与预填同源，
/// 就不会出现「提示是 A、框里是 B」的漂移。换服务器时直接改框里的字即可。
const String kDefaultServerUrl = 'http://192.168.31.141:8666';

class _MePageState extends State<MePage> {
  final _urlCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _passcodeCtrl = TextEditingController();
  String? _pairedUrl;
  String? _pairedServerId;
  String? _nodeIdShort;
  bool _loaded = false;
  bool _joined = false;

  /// 地址边改边探（防抖）：准入模式决定下面给哪套接入区块。
  Timer? _probeDebounce;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // InheritedWidget 的依赖必须在这里取（initState 里取是非法的）；
    // _loaded 挡住重复加载。
    if (!_loaded) _loadPaired();
  }

  @override
  void dispose() {
    _probeDebounce?.cancel();
    _urlCtrl.dispose();
    _codeCtrl.dispose();
    _passcodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadPaired() async {
    // 在 await 之前把 InheritedWidget 依赖取完（不能跨 async gap 用 context）
    final engine = SyncScope.of(context);
    final url = await engine.pairedServerUrl();
    final serverId = await engine.pairedServerId();
    final nodeId = await engine.nodeId();
    final joined = await engine.isPaired();
    if (!mounted) return;
    // 地址框预填：已配对的地址优先，否则网页端直接填当前访问地址（R21）——
    // 从服务器上看到的就是这台服务器，没有第二个答案值得让人手输。
    final knownUrl = url ?? await engine.serverUrlOrWebOrigin();
    if (!mounted) return;
    setState(() {
      _pairedUrl = url;
      _pairedServerId = serverId;
      _joined = joined;
      _nodeIdShort = nodeId.length > 8 ? nodeId.substring(0, 8) : nodeId;
      _loaded = true;
      _urlCtrl.text = knownUrl ?? widget.defaultServerUrl;
    });
    // 策略与准入模式都是「进页面先对齐一次」的只读态：不这么做，
    // 常驻策略会一直显示成默认的双向，即使本机早就存过「仅下载」。
    await engine.loadSyncMode();
    // 准入模式决定未配对时给哪一种接入区块（三态互斥）。读不到就保持
    // "未知"，UI 回退配对码版式；重跑一次 loading 让模式上屏。
    // ★ 用**框里的地址**探（已保存的 or 预置的）：只认偏好的话，
    //   未配对的 Android 永远探不到模式，open 服务端也会显示成配对码版式。
    await engine.refreshAccessConfig(urlOverride: _urlCtrl.text);
    // 进页面就把「那台电脑活着没有」和「两端差多少」都问一遍——
    // 之前这两件事全靠用户点按钮试出来，点了没反应就只能瞎猜。
    await engine.pingServer(urlOverride: _urlCtrl.text);
    await engine.computeDiff(urlOverride: _urlCtrl.text);
    if (!mounted) return;
    setState(() {});
  }

  /// 地址一改就重新探（防抖 400 ms）：模式 + 存活 + 差异。
  /// 不然未配对设备上偏好里还没有地址，什么都探不到。
  void _onUrlChanged(SyncEngine engine, String raw) {
    _probeDebounce?.cancel();
    _probeDebounce = Timer(const Duration(milliseconds: 400), () async {
      await engine.refreshAccessConfig(urlOverride: raw);
      await engine.pingServer(urlOverride: raw);
      await engine.computeDiff(urlOverride: raw);
      if (mounted) setState(() {});
    });
  }

  /// 手动「测试连接」：探活 + 重算差异（差异要问服务端，顺带一次）。
  Future<void> _probe(SyncEngine engine) async {
    await engine.pingServer(urlOverride: _urlCtrl.text);
    await engine.computeDiff(urlOverride: _urlCtrl.text);
    if (mounted) setState(() {});
  }

  /// 跑一次方向动作，回来把差异刷新——不然按钮上还挂着同步前的旧数字。
  Future<void> _act(SyncEngine engine, Future<void> op) async {
    await op;
    await engine.computeDiff(urlOverride: _urlCtrl.text);
    if (mounted) setState(() {});
  }

  /// 按钮文案带差异数：`上传改动 · 12`。数不出来就只留动作名，
  /// 摆个假的 0 比不摆更糟（会让人以为真没东西可传而不敢点）。
  String _actLabel(String name, int? n) =>
      (n == null || n < 0) ? name : '$name · $n';

  /// 存活徽标。三种状态一眼分得清：没探过 / 通 / 不通（附原话）。
  Widget _connBadge(SyncEngine engine) {
    final p = engine.serverPing;
    final color = p == null
        ? context.zj.muted
        : p.ok
            ? context.zj.ok
            : context.zj.accent;
    final text = p == null ? '未检测连接' : p.label;
    return Row(
      children: [
        Container(
          key: const ValueKey('conn-dot'),
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: color)),
        ),
      ],
    );
  }

  Future<void> _pair() async {
    final engine = SyncScope.of(context);
    final url = _urlCtrl.text;
    final code = _codeCtrl.text;
    await engine.pair(serverUrl: url, code: code);
    if (!mounted) return;
    await _loadPaired();
  }

  /// 口令接入（R21 模式二）：固定口令换本机专属 token，成功后转已接入版式。
  Future<void> _join() async {
    final engine = SyncScope.of(context);
    await engine.join(serverUrl: _urlCtrl.text, passcode: _passcodeCtrl.text);
    if (!mounted) return;
    await _loadPaired();
  }

  Future<void> _unpair() async {
    final engine = SyncScope.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解除配对？'),
        content: const Text(
          '本机的菜谱会保留，但会清掉同步进度；'
          '重新配对后会从服务端重新拉全量数据。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: context.zj.accent),
            child: const Text('解除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await engine.unpair();
    if (!mounted) return;
    setState(() {
      _pairedUrl = null;
      _pairedServerId = null;
      _joined = false;
      _codeCtrl.clear();
      _passcodeCtrl.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final engine = SyncScope.of(context);
    return Scaffold(
      backgroundColor: context.zj.paper,
      appBar: AppBar(title: const Text('我的')),
      body: !_loaded
          ? Center(
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: context.zj.accent,
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _sectionTitle('同步'),
                _SyncCard(
                  child: ListenableBuilder(
                    listenable: engine,
                    builder: (context, _) => _syncBody(engine),
                  ),
                ),
                const SizedBox(height: 20),
                _sectionTitle('设备'),
                _SyncCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _kv('设备标识（nodeId）', '$_nodeIdShort…', mono: true),
                      const SizedBox(height: 8),
                      Text(
                        '这是本机在家庭同步里的身份。换设备 = 新身份，各自配对到同一台服务端即可。',
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.6,
                          color: context.zj.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _sectionTitle('家庭'),
                _SyncCard(
                  child: ListenableBuilder(
                    listenable: StoreScope.of(context),
                    builder: (context, _) => Column(
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          key: const ValueKey('me-members'),
                          leading: Icon(
                            Icons.family_restroom,
                            color: context.zj.muted,
                          ),
                          title: const Text('家庭成员与过敏原',
                              style: TextStyle(fontSize: 14)),
                          subtitle: Text(
                            // 副标题只报事实：有人就列名字和限制条数，没人就说还没加
                            StoreScope.of(context).members.isEmpty
                                ? '还没有添加家人'
                                : StoreScope.of(context)
                                    .members
                                    .map((m) => '${m.name}·'
                                        '${m.totalRestrictions == 0 ? '无限制' : '${m.totalRestrictions}项'}')
                                    .join('  '),
                            style: const TextStyle(fontSize: 12),
                          ),
                          trailing: Icon(
                            Icons.chevron_right,
                            color: context.zj.muted,
                          ),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const MembersPage(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                _sectionTitle('数据'),
                _SyncCard(
                  child: Column(
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.rule_folder_outlined,
                          color: context.zj.muted,
                        ),
                        title: const Text('冲突箱', style: TextStyle(fontSize: 14)),
                        subtitle: const Text(
                          '两端改了同一处时，逐字段选保留哪版',
                          style: TextStyle(fontSize: 12),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _ConflictBadge(store: StoreScope.of(context)),
                            Icon(
                              Icons.chevron_right,
                              color: context.zj.muted,
                            ),
                          ],
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const ConflictBoxPage(),
                          ),
                        ),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        key: const ValueKey('me-health'),
                        leading: Icon(
                          Icons.monitor_heart_outlined,
                          color: context.zj.muted,
                        ),
                        title: const Text('数据体检', style: TextStyle(fontSize: 14)),
                        subtitle: const Text(
                          '缺料缺步骤、过期库存、挂起的锅——一页看账',
                          style: TextStyle(fontSize: 12),
                        ),
                        trailing: Icon(
                          Icons.chevron_right,
                          color: context.zj.muted,
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const HealthPage(),
                          ),
                        ),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        key: const ValueKey('me-theme'),
                        leading: Icon(
                          Icons.contrast,
                          color: context.zj.muted,
                        ),
                        title: const Text('主题', style: TextStyle(fontSize: 14)),
                        subtitle: Text(
                          '${StoreScope.of(context).tokens.label} · '
                          '${StoreScope.of(context).tokens.hint} · 只影响这台设备',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: Icon(
                          Icons.chevron_right,
                          color: context.zj.muted,
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const ThemePage(),
                          ),
                        ),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          Icons.delete_outline,
                          color: context.zj.muted,
                        ),
                        title: const Text('回收站', style: TextStyle(fontSize: 14)),
                        subtitle: const Text(
                          '删除的菜谱可以在这里恢复',
                          style: TextStyle(fontSize: 12),
                        ),
                        trailing: Icon(
                          Icons.chevron_right,
                          color: context.zj.muted,
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const TrashPage()),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _sectionTitle('大模型'),
                _SyncCard(
                  child: ListenableBuilder(
                    listenable: engine,
                    builder: (context, _) => _AiEntryCard(engine: engine),
                  ),
                ),
                const SizedBox(height: 20),
                _sectionTitle('提醒与计时'),
                // R47 · 这里只放**真接线**的几路（FR-SET-01/02/03）：
                // 悬浮窗那行控制计时球上不上屏，震动那行进 TimerBoard 的提醒闸门，
                // 开饭前提醒那行进 MealReminderWatch 的投递闸门（FR-PLAN-09：派生摘要投一条通知）。
                // 语音提醒（FR-SET-03 第三路）还没有落点，继续不上死开关。
                _KitchenPrefsCard(),
                const SizedBox(height: 20),
                Text(
                  '备份能力在服务端状态页（http://127.0.0.1:8666/）配置。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.6,
                    color: context.zj.muted,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _syncBody(SyncEngine engine) {
    final paired = _joined;
    // 差异取一次存本地：既是给按钮用，也避开 `?.` 与 `??` 混在一处
    // （analyzer 3.x 的 use_build_context_synchronously 在这种式子上会崩）。
    final diff = engine.diff;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 存活状态放在最上面，且**不管模式读到没读到**：
        // 探不通的时候恰恰最需要这句实话（不然界面只会显示一套凭猜测画出来的配对码）。
        Row(
          children: [
            Expanded(child: _connBadge(engine)),
            TextButton(
              key: const ValueKey('conn-test'),
              onPressed: engine.isBusy ? null : () => _probe(engine),
              child: const Text('测试连接', style: TextStyle(fontSize: 12.5)),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (!paired) ...[
          Text(
            '服务端地址',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: context.zj.ink2,
            ),
          ),
          const SizedBox(height: 6),
          TextField(
            controller: _urlCtrl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            // ★ 不要写 enableSuggestions: false：Flutter 会把它翻成 Android 的
            //   IME_FLAG_NO_PERSONALIZED_LEARNING，HyperOS / MIUI 见到这个标志
            //   就切到「安全键盘」（没有云输入、长得像密码框），用户以为
            //   地址框被当成了密码输入。autocorrect: false 已经够挡住自动纠错。
            onChanged: (v) => _onUrlChanged(engine, v),
            style: TextStyle(fontSize: 14, color: context.zj.ink),
            cursorColor: context.zj.accent,
            decoration: _inputDecoration(kDefaultServerUrl),
          ),
          const SizedBox(height: 12),
          // 接入区块由服务端准入模式决定（R21 三态互斥）。
          // 还没读到模式（读不到 = 没连上/旧服务端）时按配对码版式回退。
          ...switch (engine.accessMode) {
            SyncAccessMode.open => _openAccess(engine),
            SyncAccessMode.passcode => _passcodeAccess(engine),
            _ => _pairCodeAccess(engine),
          },
        ] else ...[
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _kv('服务端', _pairedUrl!, mono: true),
                    const SizedBox(height: 6),
                    _kv('服务端身份', '$_pairedServerId…', mono: true),
                  ],
                ),
              ),
              TextButton(
                onPressed: _unpair,
                child: Text(
                  '解除配对',
                  style: TextStyle(fontSize: 12, color: context.zj.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton.icon(
                onPressed: engine.isBusy ? null : () => engine.sync(),
                icon: engine.isBusy
                    ? SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: context.zj.onAccent,
                        ),
                      )
                    : const Icon(Icons.sync, size: 16),
                label: Text(engine.isBusy ? '同步中…' : '立即同步'),
                style: FilledButton.styleFrom(
                  backgroundColor: context.zj.accent,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: _statusLine(engine)),
            ],
          ),
        ],
        // ── 手动方向 + 常驻策略（FR-DATA-05）──────────────────────────
        // 「配好地址之后就该看见上传/下载的入口」——之前只有双向一条路，
        // 免配对模式下更是只挂一个「自动同步」徽标，用户没有任何可点的东西。
        // 现在：存活探测 + 差异计数 + 两个一次性方向动作 + 常驻策略 + 进度。
        // 能谈上话（已接入 / 免配对）才摆出来，未接入时点了只会报错。
        if (_joined || engine.accessMode == SyncAccessMode.open) ...[
          // 进度条：一轮同步走到哪、第几批/第几页。没这个就是"点了没反应"。
          if (engine.progress != null) ...[
            const SizedBox(height: 2),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                key: const ValueKey('sync-progress'),
                value: engine.progress!.ratio,
                minHeight: 4,
                backgroundColor: context.zj.paper2,
                valueColor: AlwaysStoppedAnimation(context.zj.accent),
              ),
            ),
            const SizedBox(height: 4),
            Text(engine.progress!.label,
                style: TextStyle(
                    fontSize: 11.5, color: context.zj.muted)),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('sync-push'),
                  // 差异为 0 就禁用：空推一遍没有意义，
                  // 而「点了没反应」最容易被读成按钮坏了。
                  onPressed: engine.isBusy || (diff != null && diff.nothingToPush)
                      ? null
                      : () => _act(engine, engine.pushNow()),
                  icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                  label: Text(_actLabel('上传改动', diff?.localPending),
                      style: const TextStyle(fontSize: 12.5)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('sync-pull'),
                  onPressed: engine.isBusy ||
                          (diff != null && diff.remoteKnown && diff.nothingToPull)
                      ? null
                      : () => _act(engine, engine.pullNow()),
                  icon: const Icon(Icons.cloud_download_outlined, size: 16),
                  label: Text(_actLabel('拉取更新', diff?.remotePending),
                      style: const TextStyle(fontSize: 12.5)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              for (final m in SyncMode.values)
                FilterChip(
                  key: ValueKey('sync-mode-${m.wire}'),
                  label: Text(m.label, style: const TextStyle(fontSize: 12)),
                  selected: engine.syncMode == m,
                  onSelected: (_) => engine.setSyncMode(m),
                ),
            ],
          ),
        ],
        if (engine.lastError != null) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: context.zj.accentSoft,
              borderRadius: BorderRadius.circular(ZaojiRadius.md),
            ),
            child: Text(
              engine.lastError!,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.55,
                color: context.zj.accent,
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// 模式一「免配对开放」：本机什么都不用填，直接接入。
  /// 服务端可要求手动同步（visitorManualSync）——那时给「立即同步」入口。
  List<Widget> _openAccess(SyncEngine engine) {
    if (engine.visitorManualSync) {
      return [
        Row(
          children: [
            FilledButton.icon(
              onPressed: engine.isBusy ? null : () => engine.sync(),
              icon: const Icon(Icons.sync, size: 16),
              label: Text(engine.isBusy ? '同步中…' : '立即同步'),
              style: FilledButton.styleFrom(
                backgroundColor: context.zj.accent,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: _statusLine(engine)),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '免配对接入：点「立即同步」上传与下载数据。',
          style: TextStyle(fontSize: 11.5, height: 1.6, color: context.zj.muted),
        ),
      ];
    }
    return [
      Row(
        children: [
          Text(
            '免配对接入',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: context.zj.ok,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: context.zj.okBg,
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '自动同步',
              style: TextStyle(fontSize: 11, color: context.zj.ok),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        '无需配对；改动自动上传，打开页面自动下载。',
        style: TextStyle(fontSize: 11.5, height: 1.6, color: context.zj.muted),
      ),
    ];
  }

  /// 模式二「固定口令」：填一次家里的连接口令，换本机专属 token。
  List<Widget> _passcodeAccess(SyncEngine engine) {
    return [
      Text(
        '连接口令',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.zj.ink2,
        ),
      ),
      const SizedBox(height: 6),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _passcodeCtrl,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              style: TextStyle(fontSize: 14, color: context.zj.ink),
              cursorColor: context.zj.accent,
              decoration: _inputDecoration('向家里管服务器的人要'),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: engine.isBusy ? null : _join,
            style: FilledButton.styleFrom(
              backgroundColor: context.zj.accent,
              padding: const EdgeInsets.symmetric(
                horizontal: 22,
                vertical: 14,
              ),
            ),
            child: Text(engine.isBusy ? '连接中…' : '连接'),
          ),
        ],
      ),
    ];
  }

  /// 模式三「配对码」（also 未读到模式时的保守回退）：既有 6 位一次性配对码。
  List<Widget> _pairCodeAccess(SyncEngine engine) {
    return [
      Text(
        '配对码（5 分钟有效，一次性）',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.zj.ink2,
        ),
      ),
      const SizedBox(height: 6),
      Row(
        children: [
          Expanded(
            child: TextField(
              controller: _codeCtrl,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z]')),
                LengthLimitingTextInputFormatter(6),
              ],
              style: TextStyle(
                fontSize: 18,
                letterSpacing: 4,
                color: context.zj.ink,
              ),
              cursorColor: context.zj.accent,
              decoration: _inputDecoration('如 YE28Z4'),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: engine.isBusy ? null : _pair,
            style: FilledButton.styleFrom(
              backgroundColor: context.zj.accent,
              padding: const EdgeInsets.symmetric(
                horizontal: 22,
                vertical: 14,
              ),
            ),
            child: Text(engine.isBusy ? '配对中…' : '配对'),
          ),
        ],
      ),
      const SizedBox(height: 10),
      Text(
        '配对码在服务端那台电脑上取：浏览器打开 http://127.0.0.1:8666/api/pair/code（只能本机取，这是刻意的安全设计）。',
        style: TextStyle(
          fontSize: 11.5,
          height: 1.6,
          color: context.zj.muted,
        ),
      ),
    ];
  }

  Widget _statusLine(SyncEngine engine) {
    final last = engine.lastSyncAt;
    final lastText = last == null
        ? '还没同步过'
        : '上次 ${last.month}/${last.day} ${last.hour.toString().padLeft(2, '0')}:${last.minute.toString().padLeft(2, '0')}';
    return Text(switch (engine.phase) {
      SyncPhase.syncing => '正在同步…',
      SyncPhase.error => lastText,
      _ => lastText,
    }, style: TextStyle(fontSize: 11.5, color: context.zj.muted));
  }

  InputDecoration _inputDecoration(String hint) => InputDecoration(
    isDense: true,
    filled: true,
    fillColor: context.zj.surface,
    hintText: hint,
    hintStyle: TextStyle(fontSize: 13, color: context.zj.muted),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(ZaojiRadius.md),
      borderSide: BorderSide(color: context.zj.line),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(ZaojiRadius.md),
      borderSide: BorderSide(color: context.zj.accent, width: 1.4),
    ),
  );

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8, left: 4),
    child: Text(
      text,
      style: ZaojiText.displayOf(context, fontSize: 15, fontWeight: FontWeight.w600),
    ),
  );

  Widget _kv(String k, String v, {bool mono = false}) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 108,
        child: Text(
          k,
          style: TextStyle(fontSize: 12, color: context.zj.muted),
        ),
      ),
      Expanded(
        child: Text(
          v,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            color: context.zj.ink,
            fontFamily: mono ? 'monospace' : null,
          ),
        ),
      ),
    ],
  );
}

/// 未裁决冲突数的徽标。监听 store——同步落库（reload）后数字自动跟上，
/// 不为它单开任何刷新通道（R12 铺的路：store 是唯一的变更事实源）。
/// R27 · 大模型入口卡（FR-AI-10：入口恒定存在，未配置只是少一枚状态徽记）。
///
/// 状态来自服务端 `/api/ai/status`——**配置在自家服务端，两端看到的是同一份**。
/// 读不到（没接入/服务端旧）按「未配置」渲染，布局不跳变。
class _AiEntryCard extends StatefulWidget {
  const _AiEntryCard({required this.engine});

  final SyncEngine engine;

  @override
  State<_AiEntryCard> createState() => _AiEntryCardState();
}

class _AiEntryCardState extends State<_AiEntryCard> {
  Map<String, Object?>? _status;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final s = await widget.engine.aiCall('/api/ai/status');
      if (mounted) setState(() => _status = s);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _status ?? widget.engine.aiStatusCache;
    final configured = s?['configured'] == true;
    final enabled = s?['enabled'] == true;
    final state = !configured
        ? '未配置'
        : enabled
            ? '已启用 · ${s?['model'] ?? ''}'
            : '已配置未启用';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.auto_awesome,
          color: context.zj.ai, size: 22),
      title: const Text('大模型能力', style: TextStyle(fontSize: 14)),
      subtitle: Text(
        _error != null && s == null
            ? '连到服务端后可配置'
            : '$state。Key 存在自家服务端，不随同步外发',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!configured)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: context.zj.paper2,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text('未配置',
                  style: TextStyle(
                      fontSize: 10.5, color: context.zj.muted)),
            ),
          const SizedBox(width: 6),
          Icon(Icons.chevron_right, color: context.zj.muted),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const AiSettingsPage()),
      ),
    );
  }
}

class _ConflictBadge extends StatefulWidget {
  const _ConflictBadge({required this.store});

  final RecipeStore store;

  @override
  State<_ConflictBadge> createState() => _ConflictBadgeState();
}

class _ConflictBadgeState extends State<_ConflictBadge> {
  int _count = 0;

  @override
  void initState() {
    super.initState();
    widget.store.addListener(_refresh);
    _refresh();
  }

  @override
  void dispose() {
    widget.store.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _refresh() async {
    final n = await widget.store.openConflictCount();
    if (mounted) setState(() => _count = n);
  }

  @override
  Widget build(BuildContext context) {
    if (_count == 0) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: context.zj.accentSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$_count',
        key: const ValueKey('conflict-badge'),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: context.zj.accent,
        ),
      ),
    );
  }
}

/// 提醒与计时开关（R47 · 悬浮窗 FR-SET-02、震动与声音 FR-SET-03、通知 FR-COOK-14）。
///
/// 落 `local_pref`：**只影响这台设备**（同主题、同备菜板口径）。
///
/// ★ **通知这一行的措辞跟着系统授权态走**（unknown / granted / denied 三样），
/// 而且「通知带声音」只在**通知开着且已授权**时才出现——
/// 没授权就摆一枚能点的声音开关，等于又造一个「能打开但什么都不发生」的控件。
/// 授权入口（`prefs-notify-access`）拿到之后就自己收掉，不反复劝。
///
/// ★ **FR-SET-01「开饭前提醒」在 R47 第六段接上了**：投递去处是通知（`MealReminderWatch`），
/// 摘要与那一行列出的内容吃同一个 `digestOfMenu`，所以这一行不是装饰——
/// 打开这页就能看见今天会投给哪一餐、投出去是几个字，或者为什么一趟都不投。
/// 档位**就地一排**（六颗 chip），不做「点一下→再弹一层」的两段式。
class _KitchenPrefsCard extends StatelessWidget {
  const _KitchenPrefsCard();

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final alert = AlertScope.of(context);
    return ListenableBuilder(
      // 两个事实源都要听：偏好翻转改文案，授权态回来也要改文案（不重进页面就该看见）。
      listenable: Listenable.merge([store, alert]),
      builder: (context, _) {
        final p = store.kitchenPrefs;
        final granted = alert.permission == NotifyPermission.granted;
        final denied = alert.permission == NotifyPermission.denied;
        return _SyncCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── 开饭前投待办（FR-SET-01 + FR-PLAN-09）──
              _prefSwitch(
                context,
                key: 'prefs-meal-reminder',
                title: '开饭前提醒',
                sub: p.mealReminderOn
                    ? '提前 ${mealLeadLabel(p.leadMinutesClamped)}把备菜与制作投进待办'
                    : '不开待办，只在菜单里看',
                value: p.mealReminderOn,
                onChanged: (v) => store
                    .updateKitchenPrefs((x) => x.copyWith(mealReminderOn: v)),
              ),
              if (p.mealReminderOn) ...[
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 8),
                  child: Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final m in KitchenPrefs.leadSteps)
                        FilterChip(
                          key: ValueKey('prefs-lead-$m'),
                          label: Text(mealLeadLabel(m),
                              style: const TextStyle(fontSize: 12)),
                          selected: p.leadMinutesClamped == m,
                          onSelected: (_) => store.updateKitchenPrefs(
                              (x) => x.copyWith(mealLeadMinutes: m)),
                        ),
                    ],
                  ),
                ),
                ..._mealTodoLines(context, store),
              ],
              Divider(height: 22, color: context.zj.lineSoft),
              _prefSwitch(
                context,
                key: 'prefs-timer-float',
                title: '计时器悬浮窗',
                sub: '离开菜谱页后继续显示，可拖动',
                value: p.timerFloatOn,
                onChanged: (v) =>
                    store.updateKitchenPrefs((x) => x.copyWith(timerFloatOn: v)),
              ),
              Divider(height: 22, color: context.zj.lineSoft),
              _prefSwitch(
                context,
                key: 'prefs-vibrate',
                title: '计时结束震动',
                sub: '静音时只剩视觉提示',
                value: p.vibrateOn,
                onChanged: (v) =>
                    store.updateKitchenPrefs((x) => x.copyWith(vibrateOn: v)),
              ),
              Divider(height: 22, color: context.zj.lineSoft),
              _prefSwitch(
                context,
                key: 'prefs-notify',
                title: '计时结束通知',
                sub: !p.notifyOn
                    ? '不开通知，只剩震动与视觉'
                    : granted
                        ? '到点在通知栏提醒一次'
                        : denied
                            ? '系统已拒绝，去系统设置里开'
                            : '还没拿到系统授权',
                value: p.notifyOn,
                onChanged: (v) =>
                    store.updateKitchenPrefs((x) => x.copyWith(notifyOn: v)),
              ),
              if (p.notifyOn && !granted)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const ValueKey('prefs-notify-access'),
                      onPressed: () => denied
                          ? alert.openSystemSettings()
                          : alert.requestAccess(),
                      child: Text(denied ? '去系统设置里改' : '开启系统通知授权'),
                    ),
                  ),
                ),
              if (p.notifyOn && granted) ...[
                Divider(height: 22, color: context.zj.lineSoft),
                _prefSwitch(
                  context,
                  key: 'prefs-sound',
                  title: '通知带声音',
                  sub: p.soundOn ? '跟着系统的音量与静音档走' : '静音：通知栏只落一条横幅',
                  value: p.soundOn,
                  onChanged: (v) =>
                      store.updateKitchenPrefs((x) => x.copyWith(soundOn: v)),
                ),
              ],
              Divider(height: 22, color: context.zj.lineSoft),
              // 库存到期这一路与计时器那两枚开关各管各的（FR-PAN-04）：
              // 想关的是「别提醒我菜过期」，不该把灶上的到点提醒一起掐掉。
              _prefSwitch(
                context,
                key: 'prefs-expiry',
                title: '库存到期提醒',
                sub: '打开 App 时提醒一次，同一天不重复',
                value: p.expiryNotifyOn,
                onChanged: (v) =>
                    store.updateKitchenPrefs((x) => x.copyWith(expiryNotifyOn: v)),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 今天会投给谁、投出去多长（与通知正文同一个 [MealDigest.summary]）。
  ///
  /// 列在这里有两个用处：一是开关不是装饰（点完能看见它会投什么）；
  /// 二是今天压根没有定了开饭时间的餐次时，**如实说出来**，
  /// 而不是留一枚看起来坏掉的开关。数据是实况——菜单一改这几行当场跟着变。
  List<Widget> _mealTodoLines(BuildContext context, RecipeStore store) {
    final today = mealDay(DateTime.now());
    final targets = store.menus
        .where((m) => m.day == today && mealServeTime(m) != null)
        .toList();
    if (targets.isEmpty) {
      return [
        Text(
          kMealNoTargetText,
          key: const ValueKey('prefs-meal-none'),
          style: TextStyle(fontSize: 12, color: context.zj.muted),
        ),
      ];
    }
    return [
      for (final m in targets)
        Padding(
          key: ValueKey('prefs-meal-today-${m.id}'),
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(
            '${m.serveAt} ${m.meal} · ${digestOfMenu(store, m).summary}',
            style: TextStyle(
              fontSize: 12,
              height: 1.6,
              color: m.recipeIds.isEmpty ? context.zj.muted : context.zj.ink2,
            ),
          ),
        ),
    ];
  }

  Widget _prefSwitch(
    BuildContext context, {
    required String key,
    required String title,
    required String sub,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      key: ValueKey(key),
      contentPadding: EdgeInsets.zero,
      dense: true,
      value: value,
      onChanged: onChanged,
      activeThumbColor: context.zj.accent,
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(sub, style: TextStyle(fontSize: 12, color: context.zj.muted)),
    );
  }
}

class _SyncCard extends StatelessWidget {
  const _SyncCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.zj.surface,
        borderRadius: BorderRadius.circular(ZaojiRadius.lg),
        border: Border.all(color: context.zj.lineSoft),
      ),
      child: child,
    );
  }
}
