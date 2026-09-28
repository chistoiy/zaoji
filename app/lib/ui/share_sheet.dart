import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import '../utils/download_stub.dart'
    if (dart.library.js_interop) '../utils/download_web.dart';

/// 分享面板（R34 · FR-SHARE-03/04/06 的文字载体一半）。
///
/// 立场与计划书 §17 一致：**只搬内容，不搬链接**——产物是一段结构化纯文本，
/// 复制走剪贴板（Android/iOS Web 都吃），Web 端另给一个「存 .txt」。
/// **图片载体与系统分享面板本轮有意不做**：前者要服务端出图（§17.2 的
/// `GET /api/share/card`，牵扯字体子集与渲染进程，值得单独一轮），
/// 后者要 `share_plus` 原生通道，都得在真机上验收，不该在家里过夜时半推半就。
///
/// 勾选区（FR-SHARE-04）传进来的是一组「开关名 → 文案」，
/// 文案由 [buildText] 现场重算——面板不知道菜谱是什么，也不碰 store，
/// 所以三种对象（菜 / 菜单 / 清单）共用这一张脸。
class ShareToggle {
  final String key;
  final String label;
  final bool initial;

  const ShareToggle(this.key, this.label, {this.initial = true});
}

Future<void> showShareSheet(
  BuildContext context, {
  required String title,
  required String filename,
  required List<ShareToggle> toggles,
  required String Function(Set<String> on) buildText,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: context.zj.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _ShareSheet(
      title: title,
      filename: filename,
      toggles: toggles,
      buildText: buildText,
    ),
  );
}

class _ShareSheet extends StatefulWidget {
  const _ShareSheet({
    required this.title,
    required this.filename,
    required this.toggles,
    required this.buildText,
  });

  final String title;
  final String filename;
  final List<ShareToggle> toggles;
  final String Function(Set<String> on) buildText;

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  late final Set<String> _on = {
    for (final t in widget.toggles)
      if (t.initial) t.key,
  };

  /// 复制成功的提示挂在 sheet 内部（SnackBar 在模态弹层里挂不上去，R30 的坑）。
  bool _copied = false;

  @override
  Widget build(BuildContext context) {
    final text = widget.buildText(_on);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title,
                key: const ValueKey('share-title'),
                style: ZaojiText.displayOf(context, 
                    fontSize: 15, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            if (widget.toggles.isNotEmpty)
              Wrap(
                key: const ValueKey('share-toggles'),
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in widget.toggles)
                    FilterChip(
                      key: ValueKey('share-t-${t.key}'),
                      label: Text(t.label, style: const TextStyle(fontSize: 12)),
                      selected: _on.contains(t.key),
                      onSelected: (v) => setState(() {
                        if (v) {
                          _on.add(t.key);
                        } else {
                          _on.remove(t.key);
                        }
                        _copied = false;
                      }),
                    ),
                ],
              ),
            const SizedBox(height: 10),
            Flexible(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: context.zj.paper,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: context.zj.lineSoft),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    text,
                    key: const ValueKey('share-preview'),
                    style: const TextStyle(
                        fontSize: 12.5, height: 1.6, fontFamily: 'monospace'),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('share-copy'),
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: text));
                      if (mounted) setState(() => _copied = true);
                    },
                    child: Text(_copied ? '已复制' : '复制文字'),
                  ),
                ),
                if (kIsWeb) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton(
                      key: const ValueKey('share-save'),
                      onPressed: () =>
                          downloadTextFile(widget.filename, text),
                      child: const Text('存 .txt'),
                    ),
                  ),
                ],
              ],
            ),
            if (_copied)
              Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('粘贴进微信 / 短信 / 备忘录就能发',
                    key: ValueKey('share-hint'),
                    style: TextStyle(fontSize: 11.5, color: context.zj.muted)),
              ),
          ],
        ),
      ),
    );
  }
}
