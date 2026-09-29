import 'package:flutter/material.dart';

import '../data/sync/sync_scope.dart';
import '../theme.dart';
import 'ai_prompts_page.dart';
import 'ai_runs_page.dart';

/// 大模型能力配置页（R27，FR-AI-01~11）。对齐原型「大模型能力」屏。
///
/// **模型拍板（与需求 v1.1 的一处刻意偏离，理由写进服务端 ai.dart 头注）**：
/// Key 统一存自家服务端，Android 与 Web 走同一条代理——
/// 家庭局域网拓扑下，「本机存 Key 直连」的隐私收益趋近于零，
/// 换来的是两套配置/错误/存储路径。配置不跨端、结果跨端这条纪律不变。
class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key});

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  final _urlCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();

  bool _loading = true;
  bool _busy = false;
  bool _enabled = false;
  bool _flagNutrition = true;
  bool _flagRecipe = true;
  bool _flagRecommend = true;
  String _provider = 'deepseek';
  List<Map<String, Object?>> _providers = const [];
  String _keyMasked = '';
  bool _configured = false;
  Map<String, Object?> _usage = const {};
  String? _testResult; // null=没测；以 ✓/✗ 开头做人话文案
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final engine = SyncScope.of(context);
    try {
      final s = await engine.aiCall('/api/ai/status');
      if (!mounted) return;
      setState(() {
        _enabled = s['enabled'] == true;
        _provider = '${s['provider'] ?? 'deepseek'}';
        _urlCtrl.text = '${s['baseUrl'] ?? ''}';
        _modelCtrl.text = '${s['model'] ?? ''}';
        _configured = s['configured'] == true;
        _keyMasked = '${s['keyMasked'] ?? ''}';
        final flags = (s['flags'] as Map?)?.cast<String, Object?>() ?? const {};
        _flagNutrition = flags['nutrition'] != false;
        _flagRecipe = flags['recipe'] != false;
        _flagRecommend = flags['recommend'] != false;
        _usage = (s['usage'] as Map?)?.cast<String, Object?>() ?? const {};
        _providers = (s['providers'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => e.cast<String, Object?>())
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读不到服务端配置：$e';
      });
    }
  }

  Future<void> _post(Map<String, Object?> body,
      {String path = '/api/ai/config'}) async {
    setState(() => _busy = true);
    try {
      final engine = SyncScope.of(context);
      final res = await engine.aiCall(path, body);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _configured = res['configured'] == true;
        _keyMasked = '${res['keyMasked'] ?? _keyMasked}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$e';
      });
    }
  }

  Future<void> _save() async {
    await _post({
      'enabled': _enabled,
      'provider': _provider,
      'baseUrl': _urlCtrl.text.trim(),
      'model': _modelCtrl.text.trim(),
      if (_keyCtrl.text.trim().isNotEmpty) 'key': _keyCtrl.text.trim(),
      'flagNutrition': _flagNutrition,
      'flagRecipe': _flagRecipe,
      'flagRecommend': _flagRecommend,
    });
    if (!mounted) return;
    _keyCtrl.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已保存到自家服务端'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _testResult = null;
    });
    try {
      final engine = SyncScope.of(context);
      final res = await engine.aiCall('/api/ai/test', {
        'baseUrl': _urlCtrl.text.trim(),
        'model': _modelCtrl.text.trim(),
        if (_keyCtrl.text.trim().isNotEmpty) 'key': _keyCtrl.text.trim(),
      });
      if (!mounted) return;
      setState(() {
        _busy = false;
        _testResult = res['ok'] == true
            ? '✓ 连通正常'
            : '✗ ${res['message'] ?? res['error']}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        final s = '$e';
        _testResult = s.contains('auth')
            ? '✗ API Key 被服务商拒绝'
            : s.contains('model')
                ? '✗ 模型名不存在'
                : s.contains('network')
                    ? '✗ 地址连不通（检查 Base URL 与网络）'
                    : s.contains('timeout')
                        ? '✗ 响应超时'
                        : '✗ $s';
      });
    }
  }

  void _pickProvider(Map<String, Object?> p) {
    setState(() {
      _provider = '${p['k']}';
      final url = '${p['url'] ?? ''}';
      final model = '${p['model'] ?? ''}';
      if (url.isNotEmpty) _urlCtrl.text = url;
      if (model.isNotEmpty) _modelCtrl.text = model;
    });
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _modelCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.zj.paper,
      appBar: AppBar(title: const Text('大模型能力')),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(
                  strokeWidth: 2.5, color: context.zj.accent))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _masterCard(),
                const SizedBox(height: 22),
                _sectionTitle('01', '服务商', '都兼容 OpenAI 协议'),
                _providerGrid(),
                const SizedBox(height: 22),
                _sectionTitle('02', '连接参数', '存在自家服务端'),
                _field('接口地址 Base URL', _urlCtrl,
                    hint: 'https://api.deepseek.com/v1'),
                _field('模型名', _modelCtrl, hint: 'deepseek-flash'),
                _keyField(),
                const SizedBox(height: 14),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _test,
                      icon: const Icon(Icons.wifi_tethering, size: 16),
                      label: Text(_busy ? '处理中…' : '测试连接'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _testResult == null
                          ? SizedBox.shrink()
                          : Text(
                              _testResult!,
                              style: TextStyle(
                                fontSize: 12,
                                color: _testResult!.startsWith('✓')
                                    ? context.zj.tagIngredient
                                    : context.zj.accent,
                              ),
                            ),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!,
                      style: TextStyle(
                          fontSize: 11.5, color: context.zj.accent)),
                ],
                const SizedBox(height: 22),
                _sectionTitle('03', '用哪些能力', '可单独关'),
                _switchRow('卡路里估算', '详情页手动触发',
                    _flagNutrition, (v) => setState(() => _flagNutrition = v)),
                _switchRow('AI 生成菜谱', '输入菜名自动填好整份菜谱',
                    _flagRecipe, (v) => setState(() => _flagRecipe = v)),
                _switchRow('AI 推荐菜品', '按库存推荐（下一轮接入）',
                    _flagRecommend,
                    (v) => setState(() => _flagRecommend = v)),
                const SizedBox(height: 22),
                _sectionTitle('04', '用量与费用', '本月 · 服务端记账'),
                Text(
                  '调用 ${_usage['calls'] ?? 0} 次 · '
                  'token ${_usage['inTok'] ?? 0} / ${_usage['outTok'] ?? 0}',
                  style: TextStyle(
                      fontSize: 12.5, color: context.zj.ink2),
                ),
                const SizedBox(height: 22),
                _sectionTitle('05', '提示词与执行记录', ''),
                _navTile(
                  keyName: 'ai-nav-prompts',
                  icon: Icons.tune,
                  title: '提示词管理',
                  sub: '逐能力编辑 / 恢复默认',
                  page: const AiPromptsPage(),
                ),
                _navTile(
                  keyName: 'ai-nav-runs',
                  icon: Icons.history,
                  title: 'AI 执行记录',
                  sub: '输入输出留痕 · 可查可删',
                  page: const AiRunsPage(),
                ),
                const SizedBox(height: 26),
                FilledButton(
                  onPressed: _busy ? null : _save,
                  style: FilledButton.styleFrom(
                      backgroundColor: context.zj.accent),
                  child: const Text('保存配置'),
                ),
                const SizedBox(height: 16),
                Text(
                  'Key 与开关存在自家服务端、不参与同步；估算结果和 AI 生成的菜谱'
                  '照常跨端同步。',
                  style: TextStyle(
                      fontSize: 11.5,
                      height: 1.7,
                      color: context.zj.muted),
                ),
              ],
            ),
    );
  }

  Widget _masterCard() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.zj.surface,
        borderRadius: BorderRadius.circular(ZaojiRadius.lg),
        border: Border.all(
            color: _enabled
                ? context.zj.aiBg
                : context.zj.line),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(15),
              color: _enabled ? context.zj.ai : context.zj.paper2,
            ),
            child: Icon(Icons.auto_awesome,
                size: 22,
                color: _enabled ? context.zj.onAccent : context.zj.muted),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_enabled ? '已启用' : (_configured ? '已配置未启用' : '未配置'),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text(
                  _configured
                      ? _modelCtrl.text
                      : '不配置也完全能用，只是没有 AI',
                  style: TextStyle(
                      fontSize: 11.5, color: context.zj.muted),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Switch(
            value: _enabled,
            activeThumbColor: context.zj.accent,
            onChanged: (v) => setState(() => _enabled = v),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String num, String title, String more) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Text(num,
              style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: context.zj.accent)),
          const SizedBox(width: 8),
          Text(title,
              style: const TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          Expanded(
              child: Divider(
                  color: context.zj.line, thickness: 1)),
          const SizedBox(width: 10),
          Text(more,
              style: TextStyle(
                  fontSize: 11, color: context.zj.muted)),
        ],
      ),
    );
  }

  /// R44：设置页里跳子页（提示词管理 / 执行记录）的一行入口。
  Widget _navTile({
    required String keyName,
    required IconData icon,
    required String title,
    required String sub,
    required Widget page,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: context.zj.surface,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        child: ListTile(
          key: ValueKey(keyName),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => page)),
          leading: Icon(icon, size: 20, color: context.zj.accent),
          title: Text(title, style: const TextStyle(fontSize: 13.5)),
          subtitle: Text(sub,
              style: TextStyle(fontSize: 11.5, color: context.zj.muted)),
          trailing: Icon(Icons.chevron_right, size: 18, color: context.zj.muted),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        ),
      ),
    );
  }

  Widget _providerGrid() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final p in _providers)
          ChoiceChip(
            label: Text('${p['n']}'),
            selected: _provider == '${p['k']}',
            onSelected: (_) => _pickProvider(p),
            selectedColor: context.zj.aiBg,
          ),
      ],
    );
  }

  Widget _field(String label, TextEditingController c, {String? hint}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.zj.ink2)),
          const SizedBox(height: 6),
          TextField(
            controller: c,
            style: const TextStyle(fontSize: 13.5),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle: TextStyle(
                  fontSize: 12.5, color: context.zj.muted),
              isDense: true,
              filled: true,
              fillColor: context.zj.surface,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(ZaojiRadius.md),
                borderSide: BorderSide(color: context.zj.line),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(ZaojiRadius.md),
                borderSide: BorderSide(color: context.zj.line),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _keyField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('API Key',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: context.zj.ink2)),
        const SizedBox(height: 6),
        if (_configured)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('已保存 $_keyMasked（重填即替换）',
                style: TextStyle(
                    fontSize: 11.5, color: context.zj.tagIngredient)),
          ),
        TextField(
          key: const ValueKey('ai-key-field'),
          controller: _keyCtrl,
          obscureText: true,
          style: const TextStyle(fontSize: 13.5),
          decoration: InputDecoration(
            hintText: _configured ? '留空 = 保持已存的 Key' : '必填',
            hintStyle:
                TextStyle(fontSize: 12.5, color: context.zj.muted),
            isDense: true,
            filled: true,
            fillColor: context.zj.surface,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ZaojiRadius.md),
              borderSide: BorderSide(color: context.zj.line),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(ZaojiRadius.md),
              borderSide: BorderSide(color: context.zj.line),
            ),
          ),
        ),
      ],
    );
  }

  Widget _switchRow(String title, String sub, bool value,
      ValueChanged<bool> onChanged) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      activeThumbColor: context.zj.accent,
      value: value,
      onChanged: onChanged,
      title: Text(title, style: const TextStyle(fontSize: 13.5)),
      subtitle: Text(sub, style: const TextStyle(fontSize: 11.5)),
    );
  }
}
