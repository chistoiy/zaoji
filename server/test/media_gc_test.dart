import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:zaoji_server/zaoji_server.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// 孤儿媒体回收（R18）。
///
/// 这里**不需要真图片**：回收只看「文件名 + mtime + 库里的引用」，
/// 不看内容。（要看内容的是缩略图派生，那个在 media_test 里用真图验过。）
void main() {
  final shaA = 'a' * 64;
  final shaB = 'b' * 64;
  final shaC = 'c' * 64;
  final sep = Platform.pathSeparator;

  late Directory tmp;
  late MediaStore media;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zaoji_gc_test_');
    media = MediaStore(Directory('${tmp.path}${sep}media'));
  });

  tearDown(() async {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 三天前 = 一定过了宽限期。必须在测试体内取，不能在收集期算。
  DateTime old() => DateTime.now().subtract(const Duration(days: 3));

  Future<File> putOriginal(String sha, {DateTime? modified}) async {
    await media.dir.create(recursive: true);
    final f = File('${media.dir.path}${sep}$sha');
    await f.writeAsBytes(Uint8List(2048), flush: true);
    if (modified != null) await f.setLastModified(modified);
    return f;
  }

  Future<File> putThumb(String sha, int width, {DateTime? modified}) async {
    await media.thumbDir.create(recursive: true);
    final f = media.thumbFileFor(sha, width);
    await f.writeAsBytes(Uint8List(512), flush: true);
    if (modified != null) await f.setLastModified(modified);
    return f;
  }

  group('判据（plan）', () {
    test('无引用的旧图 → 可回收', () async {
      await putOriginal(shaA, modified: old());
      final p = MediaGc.plan(media: media, referenced: const {});
      expect(p.orphanShas, [shaA]);
      expect(p.orphanFileCount, 1);
      expect(p.reclaimableBytes, 2048);
    });

    test('★ 被引用的图不回收', () async {
      await putOriginal(shaA, modified: old());
      await putOriginal(shaB, modified: old());
      final p = MediaGc.plan(media: media, referenced: {shaA});
      expect(p.orphanShas, [shaB]);
      expect(p.referencedCount, 1);
      expect(p.onDiskCount, 2);
    });

    test('★ 宽限期内的一律保住（刚上传、引用行还没推上来，那不是垃圾）', () async {
      await putOriginal(shaA); // mtime = 现在
      final p = MediaGc.plan(media: media, referenced: const {});
      expect(p.orphanShas, isEmpty);
      expect(p.protectedFresh, [shaA]);
      expect(p.reclaimableBytes, 0,
          reason: '上线第一天就把刚拍的照片删掉，是这类功能最典型的翻车方式');
    });

    test('★ 整组按最新成员判定：老原图 + 刚派生的缩略图 → 整组保住', () async {
      await putOriginal(shaA, modified: old());
      await putThumb(shaA, 640); // 刚刚被某台设备拉取时派生出来
      final p = MediaGc.plan(media: media, referenced: const {});
      expect(p.orphanShas, isEmpty,
          reason: '不能只删原图、留下一个没有源头的缩略图——那比不删更糟');
      expect(p.protectedFresh, [shaA]);
    });

    test('原图 + 派生图都过期 → 整组回收，派生图不单列（避免重复删）', () async {
      await putOriginal(shaA, modified: old());
      await putThumb(shaA, 640, modified: old());
      await putThumb(shaA, 1280, modified: old());
      final p = MediaGc.plan(media: media, referenced: const {});
      expect(p.orphanShas, [shaA]);
      expect(p.orphanThumbs, isEmpty);
      expect(p.reclaimableBytes, 2048 + 512 * 2);
    });

    test('只剩派生图（原图早就没了）→ 归入 orphanThumbs', () async {
      await putThumb(shaC, 640, modified: old());
      final p = MediaGc.plan(media: media, referenced: const {});
      expect(p.orphanShas, isEmpty);
      expect(p.orphanThumbs.map((t) => '${t.sha}-${t.width}'), ['$shaC-640']);
    });

    test('有引用但盘上没文件 → danglingRefs（只报告，不"修复"）', () async {
      final p = MediaGc.plan(media: media, referenced: {shaA});
      expect(p.danglingRefs, [shaA]);
      expect(p.orphanShas, isEmpty);
      expect(p.orphanFileCount, 0);
    });

    test('★ 不认识的文件一律不碰（写一半的 .tmp、名字不对的派生文件）', () async {
      await putOriginal(shaA, modified: old());
      await media.thumbDir.create(recursive: true);
      final stray1 = File('${media.dir.path}${sep}$shaA.tmp')
        ..writeAsBytesSync([1, 2, 3]);
      final stray2 = File('${media.thumbDir.path}${sep}not-a-thumb.jpg')
        ..writeAsBytesSync([1, 2, 3]);

      final r = await MediaGc.run(media: media, referenced: const {}, dryRun: false);

      expect(r.plan.orphanShas, [shaA], reason: '只有真正的原图才算数');
      expect(stray1.existsSync(), isTrue, reason: '不是我们的数据就不动手');
      expect(stray2.existsSync(), isTrue);
    });

    test('目录不存在也不炸（全新安装时 media/ 还没建）', () {
      final p = MediaGc.plan(media: media, referenced: const {});
      expect(p.orphanFileCount, 0);
      expect(p.onDiskCount, 0);
    });
  });

  group('执行（run）', () {
    test('★ dry-run 一个文件都不动，但仍要报出"打算删什么"', () async {
      await putOriginal(shaA, modified: old());
      final r = await MediaGc.run(media: media, referenced: const {});
      expect(r.dryRun, isTrue);
      expect(r.deletedFiles, 0);
      expect(r.freedBytes, 0);
      expect(r.plan.orphanShas, [shaA]);
      expect(media.fileFor(shaA).existsSync(), isTrue);
    });

    test('★ 真删：孤儿连同它的派生图一起走，被引用的一张不动', () async {
      await putOriginal(shaA, modified: old());
      await putThumb(shaA, 640, modified: old());
      await putOriginal(shaB, modified: old());

      final r = await MediaGc.run(
          media: media, referenced: {shaB}, dryRun: false);

      expect(r.deletedFiles, 2, reason: '原图 + 1 张派生图');
      expect(r.freedBytes, 2048 + 512);
      expect(r.failures, isEmpty);
      expect(media.fileFor(shaA).existsSync(), isFalse);
      expect(media.thumbFileFor(shaA, 640).existsSync(), isFalse);
      expect(media.fileFor(shaB).existsSync(), isTrue);
    });

    test('只剩派生图的孤儿也能清掉', () async {
      await putThumb(shaC, 1280, modified: old());
      final r = await MediaGc.run(media: media, referenced: const {}, dryRun: false);
      expect(r.deletedFiles, 1);
      expect(r.plan.orphanThumbs, hasLength(1));
      expect(media.thumbFileFor(shaC, 1280).existsSync(), isFalse);
    });

    test('第二轮无可回收（幂等，不会因为重复执行误删）', () async {
      await putOriginal(shaA, modified: old());
      final first = await MediaGc.run(media: media, referenced: const {}, dryRun: false);
      expect(first.deletedFiles, 1);
      final second = await MediaGc.run(media: media, referenced: const {}, dryRun: false);
      expect(second.deletedFiles, 0);
      expect(second.plan.isEmpty, isTrue);
    });
  });

  group('stats', () {
    test('统计的是盘上真实文件，不是库里的引用', () async {
      await putOriginal(shaA, modified: old());
      await putThumb(shaA, 640, modified: old());
      final s = media.stats();
      expect(s.originals, 1);
      expect(s.originalBytes, 2048);
      expect(s.thumbs, 1);
      expect(s.thumbBytes, 512);
      expect(s.totalBytes, 2048 + 512);
      expect(s.avgOriginalBytes, 2048);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // 下面走**真 HTTP 层**：回收的判据来自库里的引用，而引用是客户端推上来的。
  // 用一个假的库自己造引用，测不出「推送链路写进去的到底算不算数」。
  // ══════════════════════════════════════════════════════════════════

  group('引用判定（走真实推送链路）', () {
    late Directory tmp2;
    late ServerState state;
    late Handler handler;

    setUp(() async {
      tmp2 = await Directory.systemTemp.createTemp('zaoji_gc_http_');
      state = await ServerState.boot(ServerConfig(
        host: '127.0.0.1',
        port: 18960,
        tlsPort: 18961,
        dataDir: Directory('${tmp2.path}${sep}data'),
        certDir: Directory('${tmp2.path}${sep}certs'),
      ));
      // 本组走的是"真配对 + 推送"链路：R21 起默认 open，先切回配对码模式
      state.sync.accessMode = SyncAccessMode.pairCode;
      handler = ZaojiServer.buildHandler(state, const ['192.168.1.10']);
    });

    tearDown(() async {
      await state.close();
      try {
        tmp2.deleteSync(recursive: true);
      } catch (_) {}
    });

    Future<Response> call(String method, String path,
            {Object? body, String? token}) =>
        Future.value(handler(Request(
          method,
          Uri.parse('http://localhost$path'),
          headers: {if (token != null) 'authorization': 'Bearer $token'},
          body: body == null ? null : jsonEncode(body),
        )));

    Future<String> pairUp() async {
      final codeRes = await call('GET', '/api/pair/code');
      final code = (jsonDecode(await codeRes.readAsString()) as Map)['code'];
      final res = await call('POST', '/api/pair',
          body: {'code': code, 'deviceId': 'phone-1', 'deviceName': '测试手机'});
      return (jsonDecode(await res.readAsString()) as Map)['token'] as String;
    }

    /// 一条**完整**的 recipe 行。协议要求每次变更都带完整行
    /// （缺列会被整条拒绝，因为「未提供」和「改成 null」在冲突判定里分不清）——
    /// **delete 也一样**，客户端的墓碑就是整行推上来的。
    Map<String, Object?> recipeRow(
      String id, {
      String? cover,
      String? deletedAt,
      int rev = 1,
    }) =>
        {
          'id': id,
          'updated_at': rev == 1 ? 'h-1' : 'h-$rev',
          'updated_by': 'phone-1',
          'rev': rev,
          'deleted_at': deletedAt,
          'name': '番茄炒蛋',
          'sub': null,
          'art': null,
          'pal': null,
          'difficulty': 2,
          'self_time': null,
          'cooked_count': 0,
          'servings': 2,
          'notes': null,
          'tags': null,
          'source': 'manual',
          'source_model': null,
          'source_at': null,
          'last_cooked_at': null,
          'cover_sha256': cover,
        };

    Future<void> push(String token, List<Map<String, Object?>> changes,
        String mutationId) async {
      final res = await call('POST', '/api/changes',
          token: token,
          body: {
            'mutationId': mutationId,
            'protocolVersion': kSyncProtocolVersion,
            'changes': changes,
          });
      expect(res.statusCode, 200, reason: await res.readAsString());
    }

    test('★ 推上来的菜谱引用了封面 → 这张图免于回收', () async {
      final token = await pairUp();
      await push(token, [
        {
          'tbl': 'recipe',
          'rowId': 'r1',
          'op': 'upsert',
          'row': recipeRow('r1', cover: shaA),
        }
      ], 'm1');

      expect(state.db.referencedCoverShas(), contains(shaA));
    });

    test('★★ 回收站里的菜谱（软删除）仍算引用——恢复后封面必须还在', () async {
      final token = await pairUp();
      await push(token, [
        {
          'tbl': 'recipe',
          'rowId': 'r1',
          'op': 'upsert',
          'row': recipeRow('r1', cover: shaA),
        }
      ], 'm1');
      // 用户把它删了（进回收站，不是真删）。
      // 墓碑是**整行**推上来的——协议里 delete 也要带 row，所以这里照客户端的样子发。
      await push(token, [
        {
          'tbl': 'recipe',
          'rowId': 'r1',
          'op': 'delete',
          'row': recipeRow('r1', cover: shaA, deletedAt: 'h-2', rev: 2),
        }
      ], 'm2');

      final row = state.db.db
          .select("SELECT deleted_at, cover_sha256 FROM recipe WHERE id = 'r1'")
          .single;
      expect(row['deleted_at'], isNotNull, reason: '前提：它确实进了回收站');

      expect(
        state.db.referencedCoverShas(),
        contains(shaA),
        reason: '★ 这一条要是挂了，用户从回收站恢复菜谱时会发现封面被系统吃掉了，'
            '而且删除不可逆——判据宁可宽松：多留一张几十 KB，胜过丢一张再也没有的照片',
      );
    });

    test('未配对的推送进不来（引用判定不可能被匿名请求污染）', () async {
      final res = await call('POST', '/api/changes',
          body: {'mutationId': 'm-x', 'changes': const []});
      expect(res.statusCode, 401);
      expect(state.db.referencedCoverShas(), isEmpty);
    });

    test('/api/health 带得动媒体占用（状态页据此显示磁盘情况）', () async {
      final res = await call('GET', '/api/health');
      final body = (jsonDecode(await res.readAsString()) as Map)
          .cast<String, Object?>();
      final media = (body['media'] as Map).cast<String, Object?>();
      expect(media['originals'], 0);
      expect(media['totalBytes'], 0);
    });
  });

  group('本机来源判定（回收接口的闸门）', () {
    test('回环地址放行', () {
      expect(ZaojiServer.isLocalAddress('127.0.0.1'), isTrue);
      expect(ZaojiServer.isLocalAddress('::1'), isTrue);
      expect(ZaojiServer.isLocalAddress('localhost'), isTrue);
      expect(ZaojiServer.isLocalAddress(null), isTrue, reason: '测试环境没有连接信息');
    });

    test('局域网地址一律拒绝', () {
      for (final a in const ['192.168.31.141', '10.0.0.7', '172.16.3.9']) {
        expect(ZaojiServer.isLocalAddress(a), isFalse, reason: a);
      }
    });
  });
}
