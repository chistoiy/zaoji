import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:zaoji_server/zaoji_server.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// R26 · 备份能力。
///
/// 断言的重心是三件事：
/// ① 包必须**自描述且可校验**（manifest 的每个哈希都能对上，坏包拒绝恢复）；
/// ② 凭据**绝不进包、绝不回显**（备份配置存在 data 目录的独立文件里）；
/// ③ 保留策略只删自己的旧包（远端按时间序裁剪，本地同）。
///
/// 远端用进程内的假 WebDAV（dart:io 手搓 PUT/GET/DELETE/PROPFIND/MKCOL），
/// 协议形状与坚果云实测一致（见《外部服务验证记录》）——真云的脾气
/// （空目录删除 403）我们已经用「只删文件」规避了。
void main() {
  late Directory tmp;
  late ServerState state;
  late Handler handler;

  /// 假 WebDAV 的存储。
  final remote = <String, Uint8List>{};
  HttpServer? fake;
  late int fakePort;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zaoji_backup_');
    state = await ServerState.boot(ServerConfig(
      host: '127.0.0.1',
      port: 1,
      tlsPort: 2,
      dataDir: Directory('${tmp.path}${Platform.pathSeparator}data'),
      certDir: Directory('${tmp.path}${Platform.pathSeparator}certs'),
    ));
    handler = ZaojiServer.buildHandler(state, const ['192.168.1.10']);
    remote.clear();

    fake = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    fakePort = fake!.port;
    fake!.listen((req) async {
      final p = req.uri.path;
      if (req.method == 'MKCOL') {
        req.response.statusCode = remote.containsKey(p) ? 405 : 201;
        await req.response.close();
      } else if (req.method == 'PUT') {
        final body = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
        remote[p] = Uint8List.fromList(body);
        req.response.statusCode = 201;
        await req.response.close();
      } else if (req.method == 'GET') {
        final b = remote[p];
        if (b == null) {
          req.response.statusCode = 404;
        } else {
          req.response.add(b);
        }
        await req.response.close();
      } else if (req.method == 'DELETE') {
        req.response.statusCode = remote.remove(p) != null ? 204 : 404;
        await req.response.close();
      } else if (req.method == 'PROPFIND') {
        // 目录前缀：去掉最后一段。返回该前缀下所有已知 key（Depth:1 语义够用）。
        final dirPrefix = p.substring(0, p.lastIndexOf('/') + 1);
        final xml = StringBuffer(
            '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">');
        void href(String h) => xml.write(
            '<d:response><d:href>$h</d:href><d:propstat><d:prop/></d:propstat></d:response>');
        for (final k in remote.keys.where((k) => k.startsWith(dirPrefix))) {
          href(k);
        }
        xml.write('</d:multistatus>');
        req.response
          ..statusCode = 207
          ..headers.contentType = ContentType('xml', 'multistatus',
              charset: 'utf-8')
          ..write(xml.toString());
        await req.response.close();
      } else {
        req.response.statusCode = 405;
        await req.response.close();
      }
    });
  });

  tearDown(() async {
    await state.close();
    await fake?.close(force: true);
    fake = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Request local(String method, String path, [Object? body]) => Request(
        method,
        Uri.parse('http://127.0.0.1:8666$path'),
        body: body == null ? null : jsonEncode(body),
        headers: body == null ? null : {'content-type': 'application/json'},
      );

  Future<Map<String, Object?>> jsonOf(Response r) async =>
      jsonDecode(await r.readAsString()) as Map<String, Object?>;

  /// 塞一张真 JPEG 进媒体库（MediaStore 会嗅魔数，假字节混不过去）。
  Future<String> seedMedia(int w, int h) async {
    final jpg = Uint8List.fromList(
        img.encodeJpg(img.Image(width: w, height: h), quality: 80));
    final sha = sha256.convert(jpg).toString();
    await state.media.put(sha, jpg);
    return sha;
  }

  BackupConfig toFakeWebdav() => BackupConfig(
        enabled: true,
        intervalHours: 24,
        includeMedia: true,
        remoteKeep: 2,
        localKeep: 2,
        webdavUrl: 'http://127.0.0.1:$fakePort/dav/zaoji/',
        webdavUser: 'u',
        webdavPass: 'p',
      );

  group('打包与清单', () {
    test('runOnce 产出带 manifest 的 zip，本地落进 data/backups', () async {
      final sha = await seedMedia(8, 6);
      final r = await state.backup.runOnce(
          config: BackupConfig(includeMedia: true, localKeep: 5));
      expect(r.ok, isTrue, reason: r.error);
      expect(r.fileName, matches(r'^zaoji-backup-\d{8}-\d{6}-[0-9a-f]{4}\.zip$'));
      expect(r.mediaCount, 1);
      final zip = File('${state.backup.backupsDir.path}${Platform.pathSeparator}${r.fileName}');
      expect(await zip.exists(), isTrue);

      // 解包验证清单：db + 那张照片都在，哈希全部对得上
      final report =
          await BackupService.restore(zip.path, Directory('${tmp.path}/into'));
      expect(report['restoredFiles'], 2); // db.sqlite3 + media/<sha>
      final mediaOut = File(
          '${tmp.path}${Platform.pathSeparator}into${Platform.pathSeparator}media'
          '${Platform.pathSeparator}$sha');
      expect(await mediaOut.exists(), isTrue);

      // 恢复出的库能打开、schema 版本正确——「备份能不能用」的最终判据
      final db = ZaojiDb.open(
          '${tmp.path}${Platform.pathSeparator}into${Platform.pathSeparator}zaoji.db');
      try {
        expect(db.schemaVersionInDb, kSchemaVersion);
      } finally {
        db.close();
      }
    });

    test('includeMedia=false 时包里没有照片条目', () async {
      await seedMedia(6, 6);
      final r = await state.backup.runOnce(
          config: BackupConfig(includeMedia: false, localKeep: 5));
      expect(r.ok, isTrue, reason: r.error);
      expect(r.mediaCount, 0);
      final zip = File('${state.backup.backupsDir.path}${Platform.pathSeparator}${r.fileName}');
      await expectThrowsLater(zip); // manifest 只登记 db 一项
      final report =
          await BackupService.restore(zip.path, Directory('${tmp.path}/noimg'));
      expect(report['restoredFiles'], 1);
    });

    test('坏包拒绝恢复：混入未登记文件 → 完整性异常', () async {
      final r = await state.backup.runOnce(
          config: BackupConfig(includeMedia: false, localKeep: 5));
      final zip = File('${state.backup.backupsDir.path}${Platform.pathSeparator}${r.fileName}');
      // 重新打包：原条目 + 一个清单外的 evil.bin
      final bytes = zip.readAsBytesSync();
      final arch = ZipDecoder().decodeBytes(bytes);
      final rebuilt = Archive();
      for (final e in arch.files) {
        rebuilt.addFile(ArchiveFile(
            e.name, (e.content as List<int>).length,
                Uint8List.fromList(e.content as List<int>))
          ..compress = false);
      }
      rebuilt.addFile(ArchiveFile('evil.bin', 4,
              Uint8List.fromList([1, 2, 3, 4]))
          ..compress = false);
      File('${tmp.path}/evil.zip')
          .writeAsBytesSync(ZipEncoder().encode(rebuilt)!);
      await expectLater(
        BackupService.restore(
            '${tmp.path}${Platform.pathSeparator}evil.zip',
            Directory('${tmp.path}/into2')),
        throwsA(isA<BackupIntegrityException>()
            .having((e) => e.message, 'message', contains('evil.bin'))),
      );
    });
  });

  group('远端与保留', () {
    test('配了 WebDAV：zip 出现在远端；keep=2 裁掉最老的', () async {
      final cfg = toFakeWebdav();
      await cfg.save(state.config.dataDir);
      for (var i = 0; i < 3; i++) {
        final r = await state.backup.runOnce(config: cfg);
        expect(r.ok, isTrue, reason: r.error);
        expect(r.uploaded, isTrue, reason: r.error);
        if (i < 2) await Future.delayed(const Duration(seconds: 1));
      }
      final remoteZips = remote.keys.where((k) => k.endsWith('.zip')).toList();
      expect(remoteZips.length, 2, reason: '远端只该留最近 2 份：$remoteZips');
      // 本地同样裁到 2
      final locals = state.backup.backupsDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.zip'))
          .toList();
      expect(locals.length, 2);
      // 探测文件（testRemote 用的）不应残留——这里没调 test，只验证 zip 名格式
      for (final k in remoteZips) {
        expect(k.split('/').last,
            matches(r'^zaoji-backup-\d{8}-\d{6}-[0-9a-f]{4}\.zip$'));
      }
    });

    test('testRemote 走 PUT+DELETE 且不留残骸', () async {
      final cfg = toFakeWebdav();
      final err = await state.backup.testRemote(cfg);
      expect(err, isNull, reason: err);
      expect(remote.values, isEmpty);
    });

    test('远端挂了 runOnce 仍算本地成功，error 里写清上传失败', () async {
      final cfg = toFakeWebdav();
      // 指到一个没人监听的端口
      final dead = BackupConfig(
          webdavUrl: 'http://127.0.0.1:1/dav/x/',
          webdavUser: 'u',
          webdavPass: 'p');
      final r = await state.backup.runOnce(config: dead);
      expect(r.ok, isTrue);
      expect(r.uploaded, isFalse);
      expect(r.error, contains('上传失败'));
      cfg; // 保持引用避免 unused
    });
  });

  group('配置与接口', () {
    test('口令只进不出：接口与 toJson 里都不得出现明文', () async {
      final cfg = BackupConfig(
          webdavUrl: 'http://127.0.0.1:$fakePort/dav/zaoji/',
          webdavUser: 'u',
          webdavPass: 's3cret-pass');
      await cfg.save(state.config.dataDir);
      final res = await handler(local('GET', '/api/admin/backup'));
      final j = await jsonOf(res);
      expect(res.statusCode, 200);
      final text = jsonEncode(j);
      expect(text, isNot(contains('s3cret-pass')));
      expect((j['config'] as Map)['webdavUser'], 'u');
      expect(j['remoteConfigured'], true);
      expect((j['last'] as Map?)?['ok'], isNull); // 还没跑过
    });

    test('POST config 掩码提交不会覆盖真口令；空串也不覆盖', () async {
      await BackupConfig(webdavPass: 'keepme', webdavUser: 'u',
              webdavUrl: 'https://dav.example.com/dav/z/')
          .save(state.config.dataDir);
      final res = await handler(local('POST', '/api/admin/backup/config',
          {'webdavPass': BackupConfig.redacted, 'intervalHours': 12}));
      expect(res.statusCode, 200);
      final saved = BackupConfig.load(state.config.dataDir);
      expect(saved.webdavPass, 'keepme', reason: '掩码必须被当作「不改」');
      expect(saved.intervalHours, 12);
    });

    test('validate 拒绝没有 / 结尾的 WebDAV 地址', () {
      final bad = BackupConfig(
          webdavUrl: 'https://dav.example.com/dav/zaoji',
          webdavUser: 'u',
          webdavPass: 'p');
      expect(bad.validate(), contains('以 / 结尾'));
    });

    test('scheduler：到期即跑、没到期不跑', () async {
      final sched = BackupScheduler(
          dataDir: state.config.dataDir,
          service: state.backup,
          checkEvery: const Duration(days: 365)); // 只测手动 tick
      // 没配远端 → tick 什么都不做
      await sched.tick();
      expect(state.backup.last, isNull);

      await BackupConfig(
              webdavUrl: 'http://127.0.0.1:$fakePort/dav/zaoji/',
              webdavUser: 'u',
              webdavPass: 'p')
          .save(state.config.dataDir);
      await sched.tick(); // 从没跑过 = 到期
      expect(state.backup.last?.ok, isTrue);
      final at = state.backup.last!.at;
      await sched.tick(); // 间隔 24h 没到 → 不再跑
      expect(state.backup.last!.at, at);
    });
  });

  group('S3 第二通道（缤纷云形状）', () {
    // 假 S3：path-style PUT/GET/DELETE + list-type=2 的 XML。
    // 不验签名正确性（真云已验过），验的是**我们确实按 SigV4 发了头**、
    // 以及双通道各自记账、互不拖累。
    final s3store = <String, Uint8List>{};
    final s3auth = <String>[];
    HttpServer? s3fake;
    setUp(() async {
      s3store.clear();
      s3auth.clear();
      s3fake = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      s3fake!.listen((req) async {
        s3auth.add(req.headers.value('authorization') ?? '');
        final p = req.uri.path;
        if (req.method == 'PUT') {
          final body =
              await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
          s3store[p] = Uint8List.fromList(body);
          req.response.statusCode = 200;
          await req.response.close();
        } else if (req.method == 'DELETE') {
          s3store.remove(p);
          req.response.statusCode = 204;
          await req.response.close();
        } else if (req.method == 'GET' &&
            req.uri.queryParameters['list-type'] == '2') {
          final prefix = req.uri.queryParameters['prefix'] ?? '';
          final xml = StringBuffer(
              '<ListBucketResult><Contents>');
          for (final k in s3store.keys.where((k) => k.startsWith('/qoderwork/$prefix'))) {
            xml.write('<Contents><Key>${k.substring('/qoderwork/'.length)}</Key></Contents>');
          }
          xml.write('</Contents></ListBucketResult>');
          req.response.statusCode = 200;
          req.response.headers.contentType = ContentType('application', 'xml');
          req.response.write(xml.toString());
          await req.response.close();
        } else {
          req.response.statusCode = 404;
          await req.response.close();
        }
      });
    });
    tearDown(() async {
      await s3fake?.close(force: true);
    });

    BackupConfig s3cfg() => BackupConfig(
          webdavUrl: 'http://127.0.0.1:$fakePort/dav/zaoji/',
          webdavUser: 'u',
          webdavPass: 'p',
          s3Endpoint: 'http://127.0.0.1:${s3fake!.port}',
          s3Bucket: 'qoderwork',
          s3Region: 'auto',
          s3Ak: 'AKIAFAKE',
          s3Sk: 'secret-fake',
          s3Prefix: 'zaoji-backups/',
        );

    test('runOnce 双通道各传一份；结果各记各的账', () async {
      final r = await state.backup.runOnce(config: s3cfg());
      expect(r.ok, isTrue, reason: r.error);
      expect(r.uploaded, isTrue, reason: r.error);
      expect(r.uploadedS3, isTrue, reason: r.error);
      expect(
          s3store.keys.any((k) => k.endsWith('.zip') && k.startsWith('/qoderwork/zaoji-backups/')),
          isTrue);
      expect(s3auth.first, startsWith('AWS4-HMAC-SHA256 Credential=AKIAFAKE/'));
      expect(s3auth.first, contains('/auto/s3/aws4_request'));
    });

    test('一通道挂（S3 端口不通）另一通道照传，error 里点名 s3', () async {
      final cfg = s3cfg();
      cfg.s3Endpoint = 'http://127.0.0.1:1'; // 必挂
      final r = await state.backup.runOnce(config: cfg);
      expect(r.ok, isTrue);
      expect(r.uploaded, isTrue, reason: 'webdav 不受 s3 失败牵连');
      expect(r.uploadedS3, isFalse);
      expect(r.error, contains('s3 上传失败'));
    });

    test('s3Sk 只进不出：接口回显掩码、掩码提交不覆盖', () async {
      final cfg = s3cfg();
      await cfg.save(state.config.dataDir);
      final res = await handler(Request(
          'GET', Uri.parse('http://127.0.0.1:8666/api/admin/backup')));
      final text = await res.readAsString();
      expect(text, isNot(contains('secret-fake')));
      final j = jsonDecode(text) as Map<String, Object?>;
      expect((j['config'] as Map)['s3Endpoint'], contains('127.0.0.1'));

      final save = await handler(Request(
          'POST', Uri.parse('http://127.0.0.1:8666/api/admin/backup/config'),
          body: jsonEncode({'s3Sk': BackupConfig.redacted}),
          headers: {'content-type': 'application/json'}));
      expect(save.statusCode, 200);
      final disk = BackupConfig.load(state.config.dataDir);
      expect(disk.s3Sk, 'secret-fake', reason: '掩码提交必须被当作「不改」');
    });

    test('endpoint 配了但四件套不齐 → 400 且人话', () async {
      final save = await handler(Request(
          'POST', Uri.parse('http://127.0.0.1:8666/api/admin/backup/config'),
          body: jsonEncode({'s3Endpoint': 'https://s3.bitiful.net'}),
          headers: {'content-type': 'application/json'}));
      expect(save.statusCode, 400);
      expect(await save.readAsString(), contains('四件套'));
    });
  });

}

/// 独立小函数：断言 zip 的 manifest 只含 db.sqlite3（不放主流程里是为了错误信息聚焦）。
Future<void> expectThrowsLater(File zip) async {
  final arch = ZipDecoder().decodeBytes(zip.readAsBytesSync());
  final names = arch.files.map((e) => e.name).toList();
  expect(names, containsAll(<String>['manifest.json', 'db.sqlite3']));
  expect(names.where((n) => n.startsWith('media/')), isEmpty);
}
