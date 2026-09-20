import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

import '../data/sync/sync_engine.dart';
import '../data/sync/sync_scope.dart';
import '../theme.dart';
import 'trash_page.dart';

/// 「我的」页（R13 最小可用版）：设备信息 + 同步配对与状态。
///
/// 这是从 `_ComingSoon` 占位升级来的第一块真实内容——
/// 同步引擎需要一个入口（填地址、输配对码、看状态、手动同步），
/// 完整的设置页（FR-SET-01~09）等 M2+ 再扩。
class MePage extends StatefulWidget {
  const MePage({super.key});

  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> {
  final _urlCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _passcodeCtrl = TextEditingController();
  String? _pairedUrl;
  String? _pairedServerId;
  String? _nodeIdShort;
  bool _loaded = false;
  bool _joined = false;

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
      if (knownUrl != null) _urlCtrl.text = knownUrl;
    });
    // 准入模式决定未配对时给哪一种接入区块（三态互斥）。读不到就保持
    // "未知"，UI 回退配对码版式；重跑一次 loading 让模式上屏。
    await engine.refreshAccessConfig();
    if (!mounted) return;
    setState(() {});
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
                  child: ListTile(
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
                ),
                const SizedBox(height: 20),
                const Text(
                  '冲突箱、AI 配置、备份都会在后续版本出现在这里。',
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
            enableSuggestions: false,
            style: const TextStyle(fontSize: 14, color: ZaojiColors.ink),
            cursorColor: ZaojiColors.accent,
            decoration: _inputDecoration('http://192.168.31.141:8666'),
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
