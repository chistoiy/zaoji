import 'package:flutter/material.dart';

import '../data/sync/sync_scope.dart';
import '../data/sync/sync_transport.dart';
import '../theme.dart';

/// R44 · 提示词管理页（FR-AI-50~53）。
///
/// 逐能力编辑 system + user 双模板。模板里用 `{{占位符}}` 指代运行时数据
/// （菜名、食材清单……），保存时服务端做白名单校验：缺必填 / 写了不认识的
/// 占位符都拒存，并把服务端原话回显。恢复默认 = 删覆盖行回落内置模板。
///
/// 只有**已接入服务端**时才谈得上编辑：读不到就按各能力的失败态显示，
/// 入口本身（从设置页来）已经保证了可达性。
class AiPromptsPage extends StatefulWidget {
  const AiPromptsPage({super.key});

  @override
  State<AiPromptsPage> createState() => _AiPromptsPageState();
}

const Map<String, String> _featureName = {
  'calories': '热量估算',
  'recipe_fill': '菜谱补全',
  'recommend': '菜品推荐',
};

class _AiPromptsPageState extends State<AiPromptsPage> {
  bool _loading = true;
  String? _error;
  List<_PromptEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final res = await SyncScope.of(context).aiCall('/api/ai/prompts');
      final list = (res['prompts'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => _PromptEntry.fromWire(e.cast<String, Object?>()))
          .toList();
      if (!mounted) return;
      setState(() {
        _entries = list;
        _error = null;
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

  /// 保存一个能力。服务端拒存（bad_placeholder）时回显原话。
  Future<void> _save(_PromptEntry e) async {
    setState(() => e.busy = true);
    try {
      final res = await SyncScope.of(context).aiCall('/api/ai/prompts', {
        'feature': e.feature,
        'system': e.systemCtrl.text,
        'user': e.userCtrl.text,
      });
      if (!mounted) return;
      setState(() {
        e.busy = false;
        e.error = res['ok'] == true ? null : '${res['message'] ?? '保存失败'}';
        if (res['ok'] == true) {
          e.system = e.systemCtrl.text;
          e.user = e.userCtrl.text;
          e.modified = true;
        }
      });
      if (res['ok'] == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('已保存'), duration: Duration(seconds: 1)));
      }
    } catch (err) {
      if (!mounted) return;
      // 校验失败服务端回的是 400 → aiCall 抛 SyncTransportException；
      // 回显它 payload 里的原话（message），不是异常类的 toString。
      final msg = err is SyncTransportException ? err.message : '$err';
      setState(() {
        e.busy = false;
        e.error = msg;
      });
    }
  }

  Future<void> _reset(_PromptEntry e) async {
    setState(() => e.busy = true);
    try {
      await SyncScope.of(context)
          .aiCall('/api/ai/prompts/reset', {'feature': e.feature});
      if (!mounted) return;
      await _load(); // 回落默认：整页重读，编辑框文本跟着换回内置模板
    } catch (err) {
      if (!mounted) return;
      // 校验失败服务端回的是 400 → aiCall 抛 SyncTransportException；
      // 回显它 payload 里的原话（message），不是异常类的 toString。
      final msg = err is SyncTransportException ? err.message : '$err';
      setState(() {
        e.busy = false;
        e.error = msg;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.zj.paper,
      appBar: AppBar(title: const Text('提示词管理')),
      body: _loading
          ? Center(
              child:
                  CircularProgressIndicator(strokeWidth: 2.5, color: context.zj.accent))
          : _error != null
              ? _loadFail()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 32),
                  children: [
                    for (final e in _entries) ...[
                      _card(e),
                      const SizedBox(height: 18),
                    ],
                  ],
                ),
    );
  }

  Widget _loadFail() {
    return ListView(children: [
      const SizedBox(height: 90),
      Center(
          child: Text('读不到提示词：$_error',
              style: TextStyle(fontSize: 13, color: context.zj.muted))),
      Center(
          child: TextButton(onPressed: _load, child: const Text('重试'))),
    ]);
  }

  Widget _card(_PromptEntry e) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(_featureName[e.feature] ?? e.feature,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            if (e.modified)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                    color: context.zj.aiBg,
                    borderRadius: BorderRadius.circular(999)),
                child: Text('已修改',
                    style: TextStyle(fontSize: 10.5, color: context.zj.ai)),
              ),
            const Spacer(),
            if (e.modified)
              TextButton(
                key: ValueKey('prompt-reset-${e.feature}'),
                onPressed: e.busy ? null : () => _reset(e),
                child: const Text('恢复默认'),
              ),
          ],
        ),
        const SizedBox(height: 4),
        _phRow(e),
        _editor(e, e.systemCtrl, 'System 提示词', 'prompt-system-${e.feature}'),
        const SizedBox(height: 8),
        _editor(e, e.userCtrl, 'User 提示词', 'prompt-user-${e.feature}'),
        if (e.error != null) ...[
          const SizedBox(height: 6),
          Text(e.error!,
              style: TextStyle(fontSize: 12, color: context.zj.warn)),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton(
            key: ValueKey('prompt-save-${e.feature}'),
            onPressed: e.busy ? null : () => _save(e),
            style: FilledButton.styleFrom(
                backgroundColor: context.zj.accent),
            child: Text(e.busy ? '保存中…' : '保存'),
          ),
        ),
      ],
    );
  }

  /// 占位符清单：点一下插到光标处。纯功能标签，不写解释文案。
  Widget _phRow(_PromptEntry e) {
    final all = [...e.required, ...e.optional];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final ph in all)
          ActionChip(
            key: ValueKey('ph-${e.feature}-$ph'),
            label: Text(ph, style: const TextStyle(fontSize: 11)),
            visualDensity: VisualDensity.compact,
            backgroundColor: context.zj.paper2,
            onPressed: () => _insert(e, ph),
          ),
      ],
    );
  }

  void _insert(_PromptEntry e, String token) {
    final c = e.focusedCtrl ?? e.userCtrl;
    final text = c.text;
    final sel = c.selection.isValid ? c.selection.start : text.length;
    final next = text.replaceRange(sel, sel, token);
    c.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: sel + token.length),
    );
    setState(() {});
  }

  Widget _editor(_PromptEntry e, TextEditingController c, String label, String key) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(fontSize: 12, color: context.zj.muted)),
        const SizedBox(height: 4),
        TextField(
          key: ValueKey(key),
          controller: c,
          maxLines: null,
          minLines: 3,
          focusNode: c == e.systemCtrl ? e.systemNode : e.userNode,
          onTapOutside: (_) {
            e.systemNode.unfocus();
            e.userNode.unfocus();
          },
          style: const TextStyle(fontSize: 13, height: 1.5),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: context.zj.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: context.zj.line),
            ),
          ),
        ),
      ],
    );
  }
}

/// 一个能力的编辑态。控制器与脏标记都挂在这里，页面重读时整批重建。
class _PromptEntry {
  final String feature;
  String system;
  String user;
  bool modified;
  final List<String> required;
  final List<String> optional;

  final TextEditingController systemCtrl;
  final TextEditingController userCtrl;
  final FocusNode systemNode = FocusNode();
  final FocusNode userNode = FocusNode();
  bool busy = false;
  String? error;

  _PromptEntry({
    required this.feature,
    required this.system,
    required this.user,
    required this.modified,
    required this.required,
    required this.optional,
  })  : systemCtrl = TextEditingController(text: system),
        userCtrl = TextEditingController(text: user);

  _PromptEntry.fromWire(Map<String, Object?> j)
      : feature = '${j['feature']}',
        system = '${j['system'] ?? ''}',
        user = '${j['user'] ?? ''}',
        modified = j['modified'] == true,
        required = ((j['placeholders'] as Map?)?['required'] as List? ?? const [])
            .map((e) => '$e')
            .toList(),
        optional = ((j['placeholders'] as Map?)?['optional'] as List? ?? const [])
            .map((e) => '$e')
            .toList(),
        systemCtrl = TextEditingController(text: '${j['system'] ?? ''}'),
        userCtrl = TextEditingController(text: '${j['user'] ?? ''}');

  /// 当前聚焦（或最后编辑）的那个框——插占位符的目标。
  TextEditingController? get focusedCtrl =>
      systemNode.hasFocus ? systemCtrl : userNode.hasFocus ? userCtrl : null;

  void dispose() {
    systemCtrl.dispose();
    userCtrl.dispose();
    systemNode.dispose();
    userNode.dispose();
  }
}
