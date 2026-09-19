import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/sync/sync_scope.dart';
import '../theme.dart';

/// 封面照片（按 sha256 从服务端按需拉取，引擎内存缓存）。
///
/// [width] 决定拉原图还是哪一档缩略图（见 `MediaWidth`）：
/// **列表传 `MediaWidth.card`，详情传 `MediaWidth.detail`**。
/// 默认 null = 原图——只有在"看到的尺寸确实接近原图"时才该用，
/// 否则就是在为一张会被缩小显示的图付全额的流量、解码和内存。
///
/// **任何失败都退化为透明**：这个组件叠在封面插画（DishArt）之上，
/// 未配对 / 不存在 / 网络失败时插画自然透出来，调用方不需要写任何分支——
/// 「没有照片的菜」是常态而不是错误。
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.sha,
    this.width,
    this.fit = BoxFit.cover,
  });

  final String sha;

  /// 缩略图档位（`MediaWidth.card` / `MediaWidth.detail`）；null = 原图。
  final int? width;

  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder(
      // 引擎有内存缓存：同一 (sha, 档位) 重复 build 不会重复发请求
      future: SyncScope.of(context).fetchMediaCached(sha, width: width),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null) return const SizedBox.shrink();
        return Image.memory(
          bytes,
          fit: fit,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        );
      },
    );
  }
}

/// 编辑页的封面选择框：虚线占位 / 已选照片预览 / 重选 / 移除。
/// 上传发生在保存时（编辑页 _save），这里只管「选」与「看」。
class CoverPickerBox extends StatelessWidget {
  const CoverPickerBox({
    super.key,
    required this.preview,
    this.onPick,
    this.onRemove,
  });

  /// 当前预览字节（已选的新照片，或原有的封面）。null = 虚线占位。
  final Uint8List? preview;

  final VoidCallback? onPick;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final hasPreview = preview != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: hasPreview
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(ZaojiRadius.md),
                      child: Image.memory(preview!, fit: BoxFit.cover),
                    )
                  : _DashedPlaceholder(onTap: onPick),
            ),
            if (hasPreview) ...[
              Positioned(
                top: 8,
                right: 8,
                child: _RoundIconBtn(
                  tooltip: '重新选择',
                  icon: Icons.photo_library_outlined,
                  onTap: onPick,
                ),
              ),
              Positioned(
                top: 8,
                right: 52,
                child: _RoundIconBtn(
                  tooltip: '移除封面',
                  icon: Icons.delete_outline,
                  onTap: onRemove,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 6),
        const Text(
          '照片只存在自己家的服务端上，保存前会压缩到 1600px',
          style: TextStyle(fontSize: 11.5, color: ZaojiColors.muted),
        ),
      ],
    );
  }
}

class _DashedPlaceholder extends StatelessWidget {
  const _DashedPlaceholder({this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ZaojiColors.paper,
      borderRadius: BorderRadius.circular(ZaojiRadius.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(ZaojiRadius.md),
            border: Border.all(color: ZaojiColors.line),
          ),
          alignment: Alignment.center,
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.add_a_photo_outlined,
                size: 20,
                color: ZaojiColors.muted,
              ),
              SizedBox(width: 8),
              Text(
                '选一张照片当封面',
                style: TextStyle(fontSize: 13, color: ZaojiColors.muted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundIconBtn extends StatelessWidget {
  const _RoundIconBtn({required this.tooltip, required this.icon, this.onTap});

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xE6FFFFFF),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 20, color: ZaojiColors.ink),
        ),
      ),
    );
  }
}
