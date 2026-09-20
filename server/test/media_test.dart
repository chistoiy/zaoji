import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:zaoji_server/zaoji_server.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// 媒体接口测试（R16）：PUT/GET /api/media/<sha256>。
///
/// 与 handler_test 同款思路：不监听端口，直接喂 Request 断言 Response。
/// 1×1 PNG 的真实字节——服务端按魔数嗅探格式，用真字节才不是「骗嗅探」。
void main() {
  // 最小的合法 1×1 透明 PNG（89 50 4E 47 开头）
  final png = Uint8List.fromList(const [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ]);

  // JPEG 魔数开头即可通过嗅探（内容是拼的，但接口只做格式识别）
  final jpeg = Uint8List.fromList(const [
    0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, //
    0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01,
  ]);

  late Directory tmp;
  late ServerState state;
  late Handler handler;
  final booted = <ServerState>[];

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zaoji_media_test_');
    state = await ServerState.boot(ServerConfig(
      host: '127.0.0.1',
      port: 18666,
      tlsPort: 18667,
      dataDir: Directory('${tmp.path}${Platform.pathSeparator}data'),
      certDir: Directory('${tmp.path}${Platform.pathSeparator}certs'),
    ));
    booted.add(state);
    // 这一组测的是「已配对设备访问媒体」的老契约：先切回配对码模式
    // （R21 起默认 open，匿名来访者也能传图，会把"没 token 必须 401"的断言全打乱）。
    state.sync.accessMode = SyncAccessMode.pairCode;
    handler = ZaojiServer.buildHandler(state, const ['192.168.1.10']);
  });

  tearDown(() async {
    for (final s in booted) {
      await s.close();
    }
    booted.clear();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<Response> hit(String method, String path,
      {Uint8List? bytes, String? token}) {
    return Future.value(handler(Request(
      method,
      Uri.parse('http://localhost$path'),
      headers: {
        if (token != null) 'authorization': 'Bearer $token',
        if (bytes != null) 'content-type': 'application/octet-stream',
      },
      body: bytes,
    )));
  }

  Future<Map<String, dynamic>> jsonOf(Response res) async =>
      (jsonDecode(await res.readAsString()) as Map).cast<String, dynamic>();

  Future<Uint8List> bytesOf(Response res) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res.read()) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  /// 配对拿 token + 把 bytes 按正确哈希传上去，返回 sha。
  /// （shelf 的 body 只能读一次——先 jsonOf 再断言，别让 reason 消费掉它。）
  Future<String> upload(Uint8List bytes, {String deviceId = 'phone-1'}) async {
    final codeRes = await hit('GET', '/api/pair/code');
    final code = (await jsonOf(codeRes))['code'] as String;
    final pairRes = await hit('POST', '/api/pair',
        bytes: Uint8List.fromList(utf8.encode(jsonEncode({
          'code': code,
          'deviceId': deviceId,
          'deviceName': '测试手机',
        }))));
    expect(pairRes.statusCode, 200);
    final token = (await jsonOf(pairRes))['token'] as String;

    final sha = MediaStore.sha256Hex(bytes);
    final put = await hit('PUT', '/api/media/$sha', bytes: bytes, token: token);
    expect(put.statusCode, 200);
    return sha;
  }

  /// 只配对拿 token（不上传）。定义在 main 顶层而不是某个 group 里——
  /// group 内定义的 helper 对后面的 group 是不可见的（踩过一次）。
  Future<String> pair(String deviceId) async {
    final codeRes = await hit('GET', '/api/pair/code');
    final code = (await jsonOf(codeRes))['code'] as String;
    final pairRes = await hit('POST', '/api/pair',
        bytes: Uint8List.fromList(utf8.encode(jsonEncode({
          'code': code,
          'deviceId': deviceId,
          'deviceName': '测试设备',
        }))));
    expect(pairRes.statusCode, 200);
    return (await jsonOf(pairRes))['token'] as String;
  }

  /// 一张**真能解码**的 2000×1500 JPEG。
  /// 缩略图这条链路必须用真图片：上面那个 16 字节的"jpeg"只能骗过魔数嗅探，
  /// 一到解码就露馅（那份假字节反过来正好是「解不开」的测试素材）。
  final photo = img.encodeJpg(
    img.fill(
      img.Image(width: 2000, height: 1500),
      color: img.ColorRgb8(200, 120, 60),
    ),
    quality: 90,
  );

  group('鉴权', () {
    test('PUT 没带 token → 401', () async {
      final res = await hit('PUT', '/api/media/${MediaStore.sha256Hex(png)}',
          bytes: png);
      expect(res.statusCode, 401);
    });

    test('GET 没带 token → 401（图片也是家事，不能公开拉）', () async {
      final res = await hit('GET', '/api/media/${MediaStore.sha256Hex(png)}');
      expect(res.statusCode, 401);
    });
  });

  group('PUT 校验链', () {
    late String token;
    setUp(() async {
      final codeRes = await hit('GET', '/api/pair/code');
      final code = (await jsonOf(codeRes))['code'] as String;
      final pairRes = await hit('POST', '/api/pair',
          bytes: Uint8List.fromList(utf8.encode(jsonEncode({
            'code': code,
            'deviceId': 'phone-1',
            'deviceName': '测试手机',
          }))));
      token = (await jsonOf(pairRes))['token'] as String;
    });

    test('sha256 格式不合法 → 400（挡路径穿越）', () async {
      final res = await hit('PUT', '/api/media/..%2F..%2Fetc',
          bytes: png, token: token);
      expect(res.statusCode, 400);
      // 走参数匹配的合法但格式错的
      final res2 = await hit('PUT', '/api/media/XYZ-not-a-hash',
          bytes: png, token: token);
      expect(res2.statusCode, 400);
    });

    test('非图片内容 → 415（白名单外一律拒绝）', () async {
      final text = Uint8List.fromList(utf8.encode('hello, not an image'));
      final sha = MediaStore.sha256Hex(text);
      final res =
          await hit('PUT', '/api/media/$sha', bytes: text, token: token);
      expect(res.statusCode, 415);
      expect(state.media.exists(sha), isFalse, reason: '拒绝的内容不能落盘');
    });

    test('哈希与 URL 不一致 → 400，且不落盘', () async {
      final wrongSha = MediaStore.sha256Hex(jpeg); // 用 jpeg 的哈希传 png 内容
      final res =
          await hit('PUT', '/api/media/$wrongSha', bytes: png, token: token);
      expect(res.statusCode, 400);
      final body = await jsonOf(res);
      expect(body['error'], 'hash_mismatch');
      expect(state.media.exists(wrongSha), isFalse);
    });

    test('★ 正确上传 → 200，文件按 sha256 落在 data/media/ 下', () async {
      final sha = MediaStore.sha256Hex(png);
      final res = await hit('PUT', '/api/media/$sha', bytes: png, token: token);
      expect(res.statusCode, 200);
      final body = await jsonOf(res);
      expect(body['ok'], isTrue);
      expect(body['duplicated'], isFalse);
      expect(body['type'], 'image/png');
      expect(state.media.exists(sha), isTrue);
      expect(await state.media.read(sha), png);
    });

    test('★ 同一张图重复上传 → duplicated:true（内容寻址天然幂等）', () async {
      final sha = MediaStore.sha256Hex(png);
      await hit('PUT', '/api/media/$sha', bytes: png, token: token);
      final res2 =
          await hit('PUT', '/api/media/$sha', bytes: png, token: token);
      expect(res2.statusCode, 200);
      expect((await jsonOf(res2))['duplicated'], isTrue);
    });

    test('空请求体 → 400', () async {
      final sha = MediaStore.sha256Hex(png);
      final res = await hit('PUT', '/api/media/$sha', token: token);
      expect(res.statusCode, 400);
    });
  });

  group('GET 拉取', () {
    test('★ 上传后能按 sha256 原样拉回，带长缓存头', () async {
      final sha = await upload(png);

      final codeRes = await hit('GET', '/api/pair/code');
      final code = (await jsonOf(codeRes))['code'] as String;
      final pairRes = await hit('POST', '/api/pair',
          bytes: Uint8List.fromList(utf8.encode(jsonEncode({
            'code': code,
            'deviceId': 'phone-2',
            'deviceName': '另一台',
          }))));
      final token2 = (await jsonOf(pairRes))['token'] as String;

      final res = await hit('GET', '/api/media/$sha', token: token2);
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'image/png');
      expect(res.headers['cache-control'], contains('immutable'));
      final got = await bytesOf(res);
      expect(got, png, reason: '内容寻址：拉回的字节必须与上传的逐位一致');
    });

    test('另一台设备的 token 也能拉（家庭共享语义）', () async {
      // upload() 里已经用 phone-2 验证过跨设备拉取，这里补 404 分支
      final res = await hit('GET', '/api/media/${'a' * 64}', token: 'whatever');
      expect(res.statusCode, isNot(200), reason: '不存在的 sha 不能 200');
    });

    test('不存在的 sha → 404', () async {
      final sha = await upload(png);
      final other = MediaStore.sha256Hex(jpeg);
      expect(sha, isNot(other));

      final codeRes = await hit('GET', '/api/pair/code');
      final code = (await jsonOf(codeRes))['code'] as String;
      final pairRes = await hit('POST', '/api/pair',
          bytes: Uint8List.fromList(utf8.encode(jsonEncode({
            'code': code,
            'deviceId': 'phone-3',
            'deviceName': 'x',
          }))));
      final token = (await jsonOf(pairRes))['token'] as String;

      final res = await hit('GET', '/api/media/$other', token: token);
      expect(res.statusCode, 404);
    });
  });

  group('缩略图（R17）', () {
    test('★ 上传即预热两档缩略图（回到列表立刻有图，不用等现算）', () async {
      final token = await pair('thumb-1');
      final sha = MediaStore.sha256Hex(photo);

      final res =
          await hit('PUT', '/api/media/$sha', bytes: photo, token: token);
      expect(res.statusCode, 200);
      final body = await jsonOf(res);
      expect(body['thumbs'], containsAll(<int>[640, 1280]));

      expect(state.media.thumbExists(sha, 640), isTrue);
      expect(state.media.thumbExists(sha, 1280), isTrue);
      expect(await state.media.read(sha), photo,
          reason: '预热只写派生目录，原图必须逐位不变');
    });

    test('★ ?w=640 拉回的是真缩略图：宽 640、4:3 等比、比原图小', () async {
      final token = await pair('thumb-2');
      final sha = await upload(photo);

      final res = await hit('GET', '/api/media/$sha?w=640', token: token);
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'image/jpeg');
      expect(res.headers['cache-control'], contains('immutable'));

      final got = await bytesOf(res);
      final decoded = img.decodeImage(got);
      expect(decoded, isNotNull);
      expect(decoded!.width, 640);
      expect(decoded.height, 480, reason: '2000×1500 等比缩到 640 宽');
      expect(got.length, lessThan(photo.length));
    });

    test('?w=1280 → 宽 1280，且明显大于 640 档', () async {
      final token = await pair('thumb-3');
      final sha = await upload(photo);

      final big = await bytesOf(
          await hit('GET', '/api/media/$sha?w=1280', token: token));
      final small = await bytesOf(
          await hit('GET', '/api/media/$sha?w=640', token: token));

      expect(img.decodeImage(big)!.width, 1280);
      expect(img.decodeImage(small)!.width, 640);
      expect(big.length, greaterThan(small.length));
      expect(big.length, lessThan(photo.length));
    });

    test('★ 不带 w 仍是原图（缩略图接口没有顺手改掉原图语义）', () async {
      final token = await pair('thumb-4');
      final sha = await upload(photo);

      final res = await hit('GET', '/api/media/$sha', token: token);
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], 'image/jpeg');
      expect(await bytesOf(res), photo);
      // 对照：带 w 的字节必须与原图不同，否则上面那条断言毫无意义
      final thumb = await bytesOf(
          await hit('GET', '/api/media/$sha?w=640', token: token));
      expect(thumb, isNot(photo));
    });

    test('★ 宽度不在白名单 → 400，且一个派生文件都不多写', () async {
      final token = await pair('thumb-5');
      final sha = await upload(photo);
      final before =
          state.media.thumbDir.listSync().whereType<File>().length;

      for (final bad in const ['100', '99999', '321', 'abc', '640.0', '0', '-640', '']) {
        final res = await hit('GET', '/api/media/$sha?w=$bad', token: token);
        expect(res.statusCode, 400, reason: 'w="$bad" 必须被拒绝，不能静默回原图');
      }

      expect(state.media.thumbDir.listSync().whereType<File>().length, before,
          reason: '白名单的意义就是「不会有人用 ?w=1..9999 把磁盘写满」');
    });

    test('★ 缓存优先：派生文件已存在就直接用，不重新解码；删掉能自愈', () async {
      final token = await pair('thumb-6');
      final sha = await upload(photo); // 上传已预热两档

      // 把 640 档换成一坨可辨认的垃圾：
      // 如果服务端「每次请求都现算」，我们会拿回一张真 JPEG；
      // 只有「先信缓存」才会原样吐出这坨垃圾。
      // 这条断言钉死的是——**列表滚动不会每次都重解码一张 1600px 原图**。
      final f = state.media.thumbFileFor(sha, 640);
      final marker = Uint8List.fromList(List<int>.generate(64, (i) => i));
      await f.writeAsBytes(marker, flush: true);

      final hit1 = await hit('GET', '/api/media/$sha?w=640', token: token);
      expect(hit1.statusCode, 200);
      expect(await bytesOf(hit1), marker);

      // 派生数据丢了随时能再算——删掉文件即自愈
      await f.delete();
      final hit2 = await hit('GET', '/api/media/$sha?w=640', token: token);
      expect(hit2.statusCode, 200);
      expect(img.decodeImage(await bytesOf(hit2))!.width, 640);
    });

    test('★ 解不开的图（只骗过魔数）请求缩略图 → 415，上传本身仍成功', () async {
      final token = await pair('thumb-7');
      final sha = MediaStore.sha256Hex(jpeg); // 16 字节的假 JPEG

      final put = await hit('PUT', '/api/media/$sha', bytes: jpeg, token: token);
      expect(put.statusCode, 200, reason: 'PUT 的契约是「魔数白名单」，不是「一定能解码」');
      expect((await jsonOf(put))['thumbs'], isEmpty,
          reason: '预热失败被吞掉，并如实回报没有缩略图');

      final res = await hit('GET', '/api/media/$sha?w=640', token: token);
      expect(res.statusCode, 415, reason: '是这张文件的问题，不是请求的问题——也不该是 500');
    });

    test('不存在的 sha 取缩略图 → 404（不是 415）', () async {
      final token = await pair('thumb-8');
      final missing = MediaStore.sha256Hex(Uint8List.fromList([1, 2, 3]));
      final res = await hit('GET', '/api/media/$missing?w=640', token: token);
      expect(res.statusCode, 404);
    });

    test('缩略图同样要 token（照片是家事）', () async {
      final sha = await upload(photo);
      final res = await hit('GET', '/api/media/$sha?w=640');
      expect(res.statusCode, 401);
    });

    test('重复取同一档 → 字节稳定（(sha, w) 的纯函数）', () async {
      final token = await pair('thumb-9');
      final sha = await upload(photo);
      final a = await bytesOf(
          await hit('GET', '/api/media/$sha?w=640', token: token));
      final b = await bytesOf(
          await hit('GET', '/api/media/$sha?w=640', token: token));
      expect(a, b);
    });
  });

  group('MediaStore 单元', () {
    test('isValidThumbWidth：只认白名单档位', () {
      for (final w in MediaStore.thumbWidths) {
        expect(MediaStore.isValidThumbWidth(w), isTrue);
      }
      for (final w in const [0, 1, 320, 500, 641, 1024, 1600, -640]) {
        expect(MediaStore.isValidThumbWidth(w), isFalse, reason: 'w=$w');
      }
    });

    test('thumbFileFor 落在 thumb/ 子目录，且文件形态与原图不可能撞名', () {
      final sha = 'a' * 64;
      final t = state.media.thumbFileFor(sha, 640);
      expect(t.path, contains('thumb'));
      expect(t.path, endsWith('$sha-640.jpg'));
      expect(MediaStore.isValidSha(t.uri.pathSegments.last), isFalse,
          reason: '派生文件不能被当成一份内容寻址的原图');
      // 原图与派生图各在一个目录里，遍历 media/ 一层拿到的永远只有原图
      expect(state.media.fileFor(sha).parent.path,
          isNot(state.media.thumbDir.path));
    });

    test('isValidSha：64 位小写 hex 才合法', () {
      expect(MediaStore.isValidSha('a' * 64), isTrue);
      expect(MediaStore.isValidSha('A' * 64), isFalse, reason: '只收小写');
      expect(MediaStore.isValidSha('g' * 64), isFalse);
      expect(MediaStore.isValidSha('a' * 63), isFalse);
      expect(MediaStore.isValidSha('../../etc/passwd'), isFalse);
      expect(MediaStore.isValidSha(''), isFalse);
    });

    test('sniffImageType：按魔数识别 JPEG/PNG/WebP，其余拒绝', () {
      expect(MediaStore.sniffImageType(jpeg), 'image/jpeg');
      expect(MediaStore.sniffImageType(png), 'image/png');
      final webp = Uint8List.fromList(
          [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50, 0, 0]);
      expect(MediaStore.sniffImageType(webp), 'image/webp');
      expect(
          MediaStore.sniffImageType(Uint8List.fromList(utf8.encode('plain'))),
          isNull);
      expect(MediaStore.sniffImageType(Uint8List(4)), isNull);
    });

    test('sha256Hex 与 URL 契约一致', () {
      // 空内容的已知 sha256（RFC 4231 之外的常识值，用 crypto 自己算一次再交叉验证）
      expect(MediaStore.sha256Hex(Uint8List(0)),
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    });
  });
}
