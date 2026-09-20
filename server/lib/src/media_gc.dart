import 'dart:io';

import 'media.dart';

/// 孤儿媒体回收（R18）。
///
/// **为什么需要它**：内容寻址的存储天生只会增——换封面、从回收站里永久删除菜谱之后，
/// 原来的原图与派生图都还躺在盘上。家里那台笔记本没人看着，磁盘只涨不跌，
/// 而且**此前没有任何反馈**（状态页只显示数据库行数，看不出盘上有多少照片）。
///
/// 三条安全设计，每一条都对应一种「把用户照片删掉」的翻车方式：
///
/// 1. **引用判定包含软删除的行**（见 `ZaojiDb.referencedCoverShas`）：
///    回收站里的菜谱是可以恢复的，它的封面必须还在。
/// 2. **宽限期（默认 24 小时）**：客户端是「先传字节、再推 recipe 行」两步动作，
///    中间可能隔着一次崩溃 / 断网 / 重装。**刚传上来还没被引用的图不是垃圾**。
///    宽限期同时也吸收了多台设备之间的时钟偏差。
/// 3. **按 sha 分组，整组一起删或一起留**：一张原图和它的所有派生图是**不可分割**的
///    回收单位。逐文件判断会制造「原图删了、缩略图还在」这种半删状态——
///    那比不删更糟：它会被下一轮统计算成另一类垃圾，问题只是被推迟。
///
/// 默认只做 **dry-run**，真实删除必须显式要求。
class MediaGc {
  const MediaGc._();

  /// 宽限期。24 小时远大于「传完图片到 recipe 行推上来」的正常间隔（秒级），
  /// 也覆盖任何一次断网重试的窗口，同时不至于让垃圾长期滞留。
  static const Duration defaultGrace = Duration(hours: 24);

  /// 算出**打算**删什么，不碰任何文件。
  ///
  /// 判据只来自两处真实事实：盘上实际存在的文件、库里实际存在的引用。
  /// 不做任何猜测（比如「文件名看着不像我们的就删掉」）。
  static MediaGcPlan plan({
    required MediaStore media,
    required Set<String> referenced,
    Duration grace = defaultGrace,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();

    final originals = media.listOriginals().toSet();
    final thumbsBySha = <String, List<MediaThumb>>{};
    for (final t in media.listThumbs()) {
      thumbsBySha.putIfAbsent(t.sha, () => []).add(t);
    }

    // 盘上出现过的所有 sha（原图 / 或只剩派生图）
    final allShas = <String>{...originals, ...thumbsBySha.keys};

    final orphanShas = <String>[];
    final orphanThumbs = <MediaThumb>[];
    final protectedFresh = <String>[];
    final danglingRefs = <String>[];
    var reclaimable = 0;

    // 反向检查：库里有引用、盘上没有文件。**只报告，不动手**——
    // 这是「客户端引用了不存在的图」或「有人手动删过盘」的信号，
    // 属于需要人看一眼的异常，不是可以自动"修复"的东西。
    for (final sha in referenced) {
      if (!allShas.contains(sha)) danglingRefs.add(sha);
    }

    final sorted = allShas.toList()..sort();
    for (final sha in sorted) {
      if (referenced.contains(sha)) continue;

      final group = <File>[
        if (originals.contains(sha)) media.fileFor(sha),
        for (final t in thumbsBySha[sha] ?? const <MediaThumb>[]) t.file,
      ];

      // 整组按**最新成员**判定。取最新 = 取最保守：
      // 一个刚被派生的缩略图不该让整组被删，也不该让这一组被拆成半删。
      var newest = DateTime.fromMillisecondsSinceEpoch(0);
      var bytes = 0;
      var statFailed = false;
      for (final f in group) {
        final FileStat st;
        try {
          st = f.statSync();
        } on FileSystemException {
          // 列表与 stat 之间文件被别人删了（并发的上传/回收都可能）。
          // 这一组本轮直接跳过：宁可少回收一轮，也不要在信息不全的判断下动手。
          statFailed = true;
          break;
        }
        if (st.modified.isAfter(newest)) newest = st.modified;
        bytes += st.size;
      }
      if (statFailed) continue;

      if (at.difference(newest) < grace) {
        protectedFresh.add(sha);
        continue;
      }

      reclaimable += bytes;
      if (originals.contains(sha)) {
        orphanShas.add(sha); // 交给 MediaStore.delete：它连派生图一起删
      } else {
        orphanThumbs.addAll(thumbsBySha[sha]!); // 原图早已不在，只剩派生图
      }
    }

    return MediaGcPlan(
      orphanShas: orphanShas,
      orphanThumbs: orphanThumbs,
      protectedFresh: protectedFresh,
      danglingRefs: danglingRefs,
      reclaimableBytes: reclaimable,
      referencedCount: referenced.length,
      onDiskCount: allShas.length,
    );
  }

  /// 执行回收。`dryRun` 为 true（默认）时只返回计划，一个文件都不动。
  ///
  /// 单条失败不中断整轮：能回收多少回收多少，失败的记录在 `failures` 里
  /// （最典型的原因是文件正被另一个进程占用——那下次再来即可）。
  static Future<MediaGcResult> run({
    required MediaStore media,
    required Set<String> referenced,
    bool dryRun = true,
    Duration grace = defaultGrace,
    DateTime? now,
  }) async {
    final p = plan(media: media, referenced: referenced, grace: grace, now: now);
    if (dryRun) return MediaGcResult(plan: p, dryRun: true);

    var files = 0;
    var freed = 0;
    final failures = <String>[];

    for (final sha in p.orphanShas) {
      try {
        final r = await media.delete(sha);
        files += r.files;
        freed += r.bytes;
      } catch (e) {
        failures.add('$sha: $e');
      }
    }
    for (final t in p.orphanThumbs) {
      try {
        if (!t.file.existsSync()) continue;
        freed += await t.file.length();
        await t.file.delete();
        files++;
      } catch (e) {
        failures.add('${t.sha}-${t.width}: $e');
      }
    }

    return MediaGcResult(
      plan: p,
      dryRun: false,
      deletedFiles: files,
      freedBytes: freed,
      failures: failures,
    );
  }
}

/// 一次回收的**计划**（dry-run 的产物），也是执行结果的依据。
class MediaGcPlan {
  const MediaGcPlan({
    required this.orphanShas,
    required this.orphanThumbs,
    required this.protectedFresh,
    required this.danglingRefs,
    required this.reclaimableBytes,
    required this.referencedCount,
    required this.onDiskCount,
  });

  /// 有原图、且无人引用的 sha（删除时会连派生图一起删）。
  final List<String> orphanShas;

  /// 只剩派生图、无人引用的档位文件（原图早就没了）。
  final List<MediaThumb> orphanThumbs;

  /// 无人引用但**在宽限期内**，被保住的 sha。
  final List<String> protectedFresh;

  /// 有引用但盘上没有文件（只报告）。
  final List<String> danglingRefs;

  /// 可回收字节数（dry-run 时是估算，执行后是实际）。
  final int reclaimableBytes;

  /// 库里的引用数 / 盘上的图片数——两个数字放在一起就能看出比例。
  final int referencedCount;
  final int onDiskCount;

  bool get isEmpty => orphanShas.isEmpty && orphanThumbs.isEmpty;

  int get orphanFileCount => orphanShas.length + orphanThumbs.length;

  Map<String, Object?> toJson() => {
        'orphanOriginals': orphanShas,
        'orphanThumbFiles': [
          for (final t in orphanThumbs) '${t.sha}-${t.width}',
        ],
        'orphanFileCount': orphanFileCount,
        'reclaimableBytes': reclaimableBytes,
        'protectedFresh': protectedFresh,
        'danglingRefs': danglingRefs,
        'referencedCount': referencedCount,
        'onDiskCount': onDiskCount,
      };
}

class MediaGcResult {
  const MediaGcResult({
    required this.plan,
    required this.dryRun,
    this.deletedFiles = 0,
    this.freedBytes = 0,
    this.failures = const [],
  });

  final MediaGcPlan plan;
  final bool dryRun;
  final int deletedFiles;
  final int freedBytes;
  final List<String> failures;

  Map<String, Object?> toJson() => {
        'ok': failures.isEmpty,
        'dryRun': dryRun,
        'deletedFiles': deletedFiles,
        'freedBytes': freedBytes,
        'failures': failures,
        ...plan.toJson(),
      };
}
