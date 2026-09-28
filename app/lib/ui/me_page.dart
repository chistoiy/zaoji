import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import '../data/recipe_store.dart';
import '../data/sync/sync_engine.dart';
import '../data/sync/sync_scope.dart';
import '../data/store_scope.dart';
import '../theme.dart';
import 'ai_settings_page.dart';
import 'conflict_box_page.dart';
import 'health_page.dart';
import 'trash_page.dart';

/// 「我的」页（R13 最小可用版）：设备信息 + 同步配对与状态。
///
/// 这是从 `_ComingSoon` 占位升级来的第一块真实内容——
/// 同步引擎需要一个入口（填地址、输配对码、看状态、手动同步），
/// 完整的设置页（FR-SET-01~09）等 M2+ 再扩。
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
    if (!mounted) return;
    setState(() {});
  }

  /// 地址一改就重新探模式（防抖 400 ms）——不然未配对设备上偏好里还没有地址，
  /// 探不到模式就永远显示配对码版式，而服务端其实开着免配对。
  void _onUrlChanged(SyncEngine engine, String raw) {
    _probeDebounce?.cancel();
    _probeDebounce = Timer(const Duration(milliseconds: 400), () async {
      await engine.refreshAccessConfig(urlOverride: raw);
      if (mounted) setState(() {});
    });
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
            style: FilledButton.styleFrom(backgroundColor: ZaojiColors.accent),
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
      backgroundColor: ZaojiColors.paper,
      appBar: AppBar(title: const Text('我的')),
      body: !_loaded
          ? const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: ZaojiColors.accent,
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
                      const Text(
                        '这是本机在家庭同步里的身份。换设备 = 新身份，各自配对到同一台服务端即可。',
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.6,
                          color: ZaojiColors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _sectionTitle('数据'),
                _SyncCard(
                  child: Column(
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.rule_folder_outlined,
                          color: ZaojiColors.muted,
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
                            const Icon(
                              Icons.chevron_right,
                              color: ZaojiColors.muted,
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
                        leading: const Icon(
                          Icons.monitor_heart_outlined,
                          color: ZaojiColors.muted,
                        ),
                        title: const Text('数据体检', style: TextStyle(fontSize: 14)),
                        subtitle: const Text(
                          '缺料缺步骤、过期库存、挂起的锅——一页看账',
                          style: TextStyle(fontSize: 12),
                        ),
                        trailing: const Icon(
                          Icons.chevron_right,
                          color: ZaojiColors.muted,
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const HealthPage(),
                          ),
                        ),
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.delete_outline,
                          color: ZaojiColors.muted,
                        ),
                        title: const Text('回收站', style: TextStyle(fontSize: 14)),
                        subtitle: const Text(
                          '删除的菜谱可以在这里恢复',
                          style: TextStyle(fontSize: 12),
                        ),
                        trailing: const Icon(
                          Icons.chevron_right,
                          color: ZaojiColors.muted,
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
                const Text(
                  '备份能力在服务端状态页（http://127.0.0.1:8666/）配置。',
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.6,
                    color: ZaojiColors.muted,
                  ),
                ),
              ],
            ),
    );
  }

  Widget _syncBody(SyncEngine engine) {
    final paired = _joined;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!paired) ...[
          const Text(
            '服务端地址',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: ZaojiColors.ink2,
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
            style: const TextStyle(fontSize: 14, color: ZaojiColors.ink),
            cursorColor: ZaojiColors.accent,
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
                child: const Text(
                  '解除配对',
                  style: TextStyle(fontSize: 12, color: ZaojiColors.muted),
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
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.sync, size: 16),
                label: Text(engine.isBusy ? '同步中…' : '立即同步'),
                style: FilledButton.styleFrom(
                  backgroundColor: ZaojiColors.accent,
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
        // 现在：两个一次性方向动作（按一次走一次）+ 常驻策略（决定自动同步
        // 与「立即同步」的方向）。能谈上话（已接入 / 免配对）才摆出来，
        // 未接入时这两排按钮点了也是报错，不该出现在界面上。
        if (_joined || engine.accessMode == SyncAccessMode.open) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('sync-push'),
                  onPressed: engine.isBusy ? null : engine.pushNow,
                  icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                  label: const Text('上传改动',
                      style: TextStyle(fontSize: 12.5)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('sync-pull'),
                  onPressed: engine.isBusy ? null : engine.pullNow,
                  icon: const Icon(Icons.cloud_download_outlined, size: 16),
                  label: const Text('拉取更新',
                      style: TextStyle(fontSize: 12.5)),
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
              color: const Color(0x14D2491C),
              borderRadius: BorderRadius.circular(ZaojiRadius.md),
            ),
            child: Text(
              engine.lastError!,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.55,
                color: ZaojiColors.accent,
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
                backgroundColor: ZaojiColors.accent,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: _statusLine(engine)),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          '免配对接入：点「立即同步」上传与下载数据。',
          style: TextStyle(fontSize: 11.5, height: 1.6, color: ZaojiColors.muted),
        ),
      ];
    }
    return [
      Row(
        children: [
          const Text(
            '免配对接入',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF2E7D32),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0x142E7D32),
              borderRadius: BorderRadius.circular(999),
            ),
            child: const Text(
              '自动同步',
              style: TextStyle(fontSize: 11, color: Color(0xFF2E7D32)),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      const Text(
        '无需配对；改动自动上传，打开页面自动下载。',
        style: TextStyle(fontSize: 11.5, height: 1.6, color: ZaojiColors.muted),
      ),
    ];
  }

  /// 模式二「固定口令」：填一次家里的连接口令，换本机专属 token。
  List<Widget> _passcodeAccess(SyncEngine engine) {
    return [
      const Text(
        '连接口令',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: ZaojiColors.ink2,
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
              style: const TextStyle(fontSize: 14, color: ZaojiColors.ink),
              cursorColor: ZaojiColors.accent,
              decoration: _inputDecoration('向家里管服务器的人要'),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: engine.isBusy ? null : _join,
            style: FilledButton.styleFrom(
              backgroundColor: ZaojiColors.accent,
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
      const Text(
        '配对码（5 分钟有效，一次性）',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: ZaojiColors.ink2,
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
              style: const TextStyle(
                fontSize: 18,
                letterSpacing: 4,
                color: ZaojiColors.ink,
              ),
              cursorColor: ZaojiColors.accent,
              decoration: _inputDecoration('如 YE28Z4'),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: engine.isBusy ? null : _pair,
            style: FilledButton.styleFrom(
              backgroundColor: ZaojiColors.accent,
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
      const Text(
        '配对码在服务端那台电脑上取：浏览器打开 http://127.0.0.1:8666/api/pair/code（只能本机取，这是刻意的安全设计）。',
        style: TextStyle(
          fontSize: 11.5,
          height: 1.6,
          color: ZaojiColors.muted,
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
    }, style: const TextStyle(fontSize: 11.5, color: ZaojiColors.muted));
  }

  InputDecoration _inputDecoration(String hint) => InputDecoration(
    isDense: true,
    filled: true,
    fillColor: Colors.white,
    hintText: hint,
    hintStyle: const TextStyle(fontSize: 13, color: ZaojiColors.muted),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(ZaojiRadius.md),
      borderSide: const BorderSide(color: ZaojiColors.line),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(ZaojiRadius.md),
      borderSide: const BorderSide(color: ZaojiColors.accent, width: 1.4),
    ),
  );

  Widget _sectionTitle(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8, left: 4),
    child: Text(
      text,
      style: ZaojiText.display(fontSize: 15, fontWeight: FontWeight.w600),
    ),
  );

  Widget _kv(String k, String v, {bool mono = false}) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SizedBox(
        width: 108,
        child: Text(
          k,
          style: const TextStyle(fontSize: 12, color: ZaojiColors.muted),
        ),
      ),
      Expanded(
        child: Text(
          v,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12.5,
            color: ZaojiColors.ink,
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
      leading: const Icon(Icons.auto_awesome,
          color: ZaojiColors.ai, size: 22),
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
                color: ZaojiColors.paper2,
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text('未配置',
                  style: TextStyle(
                      fontSize: 10.5, color: ZaojiColors.muted)),
            ),
          const SizedBox(width: 6),
          const Icon(Icons.chevron_right, color: ZaojiColors.muted),
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
        color: const Color(0x14D2491C),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$_count',
        key: const ValueKey('conflict-badge'),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: ZaojiColors.accent,
        ),
      ),
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
        color: Colors.white,
        borderRadius: BorderRadius.circular(ZaojiRadius.lg),
        border: Border.all(color: ZaojiColors.lineSoft),
      ),
      child: child,
    );
  }
}
