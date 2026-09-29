import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/store_scope.dart';
import '../data/sync/sync_scope.dart';
import '../theme.dart';

/// R44 · AI 执行记录页（FR-AI-54~57）。
///
/// 读的是**服务端的权威留痕**（`/api/ai/runs`）——AI 是服务端代理单模，
/// 只有那里拿得到完整 prompt 与上游原始输出，所以 Web 与安卓看到的是同一份。
/// 本机发起过的条目用 localOnly `ai_usage.run_ref` 比对叠一枚「本机」标记（FR-AI-62）。
///
/// 数据经 [SyncEngine.aiCall] 现取，不在 store 里做内存缓存：
/// 记录是会随时被别端删改的服务端状态，缓存只会让它过期。
class AiRunsPage extends StatefulWidget {
  const AiRunsPage({super.key});

  @override
  State<AiRunsPage> createState() => _AiRunsPageState();
}

const Map<String, String> _featureLabel = {
  'calories': '热量估算',
  'recipe_fill': '菜谱补全',
  'recommend': '菜品推荐',
  'test': '连通测试',
};

String _labelOf(String f) => _featureLabel[f] ?? f;

class _AiRunsPageState extends State<AiRunsPage> {
  static const _pageSize = 30;

  bool _loading = true;
  String? _error;
  List<Map<String, Object?>> _runs = const [];
  int _total = 0;

  String? _feature; // null = 全部能力
  bool? _ok; // null = 不限状态
  final _qCtrl = TextEditingController();

  /// 本机发起过的服务端记录 id（"本机"标记用）。
  Set<String> _localRefs = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadLocalRefs();
      _load(reset: true);
    });
  }

  @override
  void dispose() {
    _qCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadLocalRefs() async {
    try {
      final refs = await StoreScope.of(context).localAiRunRefs();
      if (mounted) setState(() => _localRefs = refs);
    } catch (_) {/* 标记是锦上添花，取不到不影响列表 */}
  }

  String _path({int offset = 0}) {
    final g = <String, String>{
      'feature': ?_feature,
      if (_ok case final o?) 'ok': o ? '1' : '0',
      if (_qCtrl.text.trim().isNotEmpty) 'q': _qCtrl.text.trim(),
      'limit': '$_pageSize',
      'offset': '$offset',
    };
    final q = g.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
    return '/api/ai/runs?$q';
  }

  Future<void> _load({required bool reset, int offset = 0}) async {
    if (reset) {
      setState(() => _loading = true);
    }
    try {
      final res = await SyncScope.of(context).aiCall(_path(offset: offset));
      if (!mounted) return;
      final rows = (res['runs'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, Object?>())
          .toList();
      setState(() {
        _error = null;
        _total = res['total'] is int ? res['total'] as int : rows.length;
        _runs = reset ? rows : [..._runs, ...rows];
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _deleteOne(Map<String, Object?> run) async {
    final id = run['id'];
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这条记录？'),
        content: const Text('只删这一条留痕，删掉恢复不了。'),
        actions: [
          TextButton(
              key: const ValueKey('run-del-cancel'),
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            key: const ValueKey('run-del-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await SyncScope.of(context).aiDelete('/api/ai/runs/$id');
      if (!mounted) return;
      setState(() {
        _runs = _runs.where((r) => r['id'] != id).toList();
        _total = (_total - 1).clamp(0, 1 << 31);
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _clearAll() async {
    if (_runs.isEmpty) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('清空${_feature != null ? '「${_labelOf(_feature!)}」' : '全部'}记录？'),
        content: const Text('服务端上的这些留痕会被删除，恢复不了。'),
        actions: [
          TextButton(
              key: const ValueKey('run-clear-cancel'),
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            key: const ValueKey('run-clear-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      final q = _feature == null ? '' : '?feature=${Uri.encodeQueryComponent(_feature!)}';
      await SyncScope.of(context).aiDelete('/api/ai/runs$q');
      if (!mounted) return;
      _load(reset: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.zj.paper,
      appBar: AppBar(
        title: const Text('AI 执行记录'),
        actions: [
          if (_runs.isNotEmpty)
            IconButton(
              key: const ValueKey('ai-runs-clear'),
              onPressed: _clearAll,
              icon: const Icon(Icons.delete_sweep_outlined, size: 22),
              tooltip: '清空',
            ),
        ],
      ),
      body: Column(
        children: [
          _filterBar(),
          const Divider(height: 1),
          Expanded(child: _list()),
        ],
      ),
    );
  }

  Widget _filterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Column(
        children: [
          SizedBox(
            height: 34,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _choice(value: null, label: '全部', group: 0),
                for (final f in _featureLabel.keys)
                  _choice(value: f, label: _featureLabel[f]!, group: 0),
                const SizedBox(width: 6),
                _choice(value: null, label: '不限结果', group: 1),
                _choice(value: 'ok', label: '成功', group: 1),
                _choice(value: 'fail', label: '失败', group: 1),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('ai-runs-search'),
            controller: _qCtrl,
            onSubmitted: (_) => _load(reset: true),
            style: const TextStyle(fontSize: 13),
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索提示词或输出',
              hintStyle: TextStyle(fontSize: 13, color: context.zj.muted),
              prefixIcon: Icon(Icons.search, size: 18, color: context.zj.muted),
              suffixIcon: _qCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () {
                        _qCtrl.clear();
                        _load(reset: true);
                      },
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: context.zj.line),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _choice({required Object? value, required String label, required int group}) {
    final selected = group == 0
        ? _feature == value
        : (value == null ? _ok == null : value == 'ok' ? _ok == true : _ok == false);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        key: ValueKey('chip-$group-$label'),
        label: Text(label, style: const TextStyle(fontSize: 12)),
        visualDensity: VisualDensity.compact,
        selected: selected,
        onSelected: (_) {
          setState(() {
            if (group == 0) {
              _feature = value as String?;
            } else {
              _ok = value == null ? null : value == 'ok';
            }
          });
          _load(reset: true);
        },
      ),
    );
  }

  Widget _list() {
    if (_loading) {
      return Center(
          child: CircularProgressIndicator(strokeWidth: 2.5, color: context.zj.accent));
    }
    if (_error != null) {
      return _emptyState(Icons.cloud_off_outlined, '读不到记录', _error!, retry: true);
    }
    if (_runs.isEmpty) {
      return _emptyState(Icons.history, '还没有执行记录', '用过一次 AI 能力后，这里会留下输入与输出。');
    }
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: _runs.length + (_runs.length < _total ? 1 : 0),
        separatorBuilder: (context, index) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          if (i >= _runs.length) {
            return Center(
              child: TextButton(
                key: const ValueKey('ai-runs-more'),
                onPressed: () => _load(reset: false, offset: _runs.length),
                child: Text('加载更多（还有 ${_total - _runs.length} 条）'),
              ),
            );
          }
          return _card(_runs[i]);
        },
      ),
    );
  }

  Widget _emptyState(IconData icon, String title, String sub, {bool retry = false}) {
    return ListView(
      children: [
        const SizedBox(height: 80),
        Icon(icon, size: 40, color: context.zj.muted),
        const SizedBox(height: 12),
        Center(child: Text(title, style: TextStyle(fontSize: 14, color: context.zj.ink))),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Center(
            child: Text(sub,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: context.zj.muted)),
          ),
        ),
        if (retry)
          Center(
            child: TextButton(
                onPressed: () => _load(reset: true), child: const Text('重试')),
          ),
      ],
    );
  }

  Widget _card(Map<String, Object?> r) {
    final feature = '${r['feature']}';
    final ok = r['ok'] == true;
    final cached = r['cached'] == true;
    final isLocal = _localRefs.contains('${r['id']}');
    final excerpt = '${r['outputExcerpt'] ?? r['promptExcerpt'] ?? ''}';
    return Material(
      color: context.zj.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        key: ValueKey('run-card-${r['id']}'),
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => _AiRunDetailPage(id: r['id'], seed: r))),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(_labelOf(feature),
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: context.zj.ink)),
                  const SizedBox(width: 6),
                  _badge(ok, cached),
                  if (isLocal) ...[
                    const SizedBox(width: 4),
                    _pill('本机', context.zj.aiBg, context.zj.ai),
                  ],
                  const Spacer(),
                  Text(_timeOf(r['at']),
                      style: TextStyle(fontSize: 11, color: context.zj.muted)),
                  IconButton(
                    key: ValueKey('run-del-${r['id']}'),
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.delete_outline, size: 18, color: context.zj.muted),
                    onPressed: () => _deleteOne(r),
                  ),
                ],
              ),
              if (excerpt.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(excerpt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: context.zj.ink2)),
              ],
              const SizedBox(height: 4),
              Text(_metaLine(r), style: TextStyle(fontSize: 11, color: context.zj.muted)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge(bool ok, bool cached) {
    if (!ok) return _pill('失败', context.zj.warnBg, context.zj.warn);
    if (cached) return _pill('缓存', context.zj.paper2, context.zj.muted);
    return _pill('成功', context.zj.okBg, context.zj.ok);
  }

  Widget _pill(String text, Color bg, Color fg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: TextStyle(fontSize: 10.5, color: fg)),
    );
  }

  String _metaLine(Map<String, Object?> r) {
    final parts = <String>[
      if ('${r['model'] ?? ''}'.isNotEmpty) '${r['model']}',
      if (r['inTok'] is int || r['outTok'] is int)
        '${r['inTok'] ?? 0} / ${r['outTok'] ?? 0} tok',
      if (r['durationMs'] is int && (r['durationMs'] as int) > 0)
        '${r['durationMs']}ms',
      if ('${r['errorKind'] ?? ''}'.isNotEmpty) '${r['errorKind']}',
    ];
    return parts.join(' · ');
  }

  String _timeOf(Object? atMs) {
    if (atMs is! int) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(atMs);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.month}/${d.day} ${two(d.hour)}:${two(d.minute)}';
  }
}

/// 详情：完整输入 / 输出 / 用量，分段可复制（FR-AI-56）。
class _AiRunDetailPage extends StatefulWidget {
  const _AiRunDetailPage({required this.id, required this.seed});

  final Object? id;
  final Map<String, Object?> seed;

  @override
  State<_AiRunDetailPage> createState() => _AiRunDetailPageState();
}

class _AiRunDetailPageState extends State<_AiRunDetailPage> {
  Map<String, Object?>? _full;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    try {
      final res = await SyncScope.of(context).aiCall('/api/ai/runs/${widget.id}');
      final run = (res['run'] as Map?)?.cast<String, Object?>();
      if (mounted) setState(() => _full = run ?? widget.seed);
    } catch (e) {
      // 拉全文失败就退回列表带来的摘要，不至于白屏
      if (mounted) setState(() => _full = widget.seed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _full ?? widget.seed;
    return Scaffold(
      backgroundColor: context.zj.paper,
      appBar: AppBar(title: Text(_labelOf('${r['feature']}'))),
      body: _error != null
          ? Center(child: Text(_error!, style: TextStyle(color: context.zj.muted)))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _kv('状态', r['ok'] == true ? (r['cached'] == true ? '成功（缓存）' : '成功') : '失败'),
                if ('${r['errorKind'] ?? ''}'.isNotEmpty) _kv('错误类型', '${r['errorKind']}'),
                _kv('模型', '${r['model'] ?? ''}'),
                _kv('时间', _fmtFull(r['at'])),
                _kv('用量', '${r['inTok'] ?? 0} 入 / ${r['outTok'] ?? 0} 出 tok'),
                if (r['durationMs'] is int) _kv('耗时', '${r['durationMs']} ms'),
                if ('${r['source'] ?? ''}'.isNotEmpty) _kv('来源', '${r['source']}'),
                const SizedBox(height: 16),
                _section('输入 · System', '${r['promptSystem'] ?? ''}'),
                _section('输入 · User', '${r['promptUser'] ?? ''}'),
                if (r['inputJson'] != null) _section('原始参数', '${r['inputJson']}'),
                _section('输出', '${r['output'] ?? ''}'),
              ],
            ),
    );
  }

  Widget _kv(String k, String v) {
    if (v.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
              width: 64,
              child: Text(k, style: TextStyle(fontSize: 12, color: context.zj.muted))),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _section(String title, String body) {
    if (body.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 12, fontWeight: FontWeight.w600, color: context.zj.accent)),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.copy, size: 15, color: context.zj.muted),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: body));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('已复制'), duration: Duration(seconds: 1)));
                },
              ),
            ],
          ),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                color: context.zj.surface, borderRadius: BorderRadius.circular(10)),
            child: SelectableText(body,
                style: const TextStyle(fontSize: 12.5, height: 1.4)),
          ),
        ],
      ),
    );
  }

  String _fmtFull(Object? atMs) {
    if (atMs is! int) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(atMs);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}
