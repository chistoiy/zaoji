import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';
import 'package:zaoji_server/zaoji_server.dart';

/// 带轮转的文件日志（R19③）。
///
/// 存在的理由：注册成 Windows 服务后**没有控制台**，stdout 重定向到文件又是
/// 块缓冲（R5 坑 6）——进程被强杀时唯一的痕一起消失。日志必须自己保证
/// 「每一行写完就能在盘上看到」，所以这里所有测试都在 write 之后**立刻**读文件。
void main() {
  final sep = Platform.pathSeparator;
  late Directory tmp;
  late Directory logDir;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zaoji_log_test_');
    logDir = Directory('${tmp.path}${sep}logs');
  });

  tearDown(() async {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  File mainLog() => File('${logDir.path}${sep}zaoji.log');

  group('基础写入', () {
    test('write 落盘且立即可读，行带 ISO 时间戳前缀', () async {
      final log = FileLog(logDir);
      await log.write('你好，日志');
      final f = mainLog();
      expect(f.existsSync(), isTrue);
      final c = f.readAsStringSync();
      expect(c, contains('你好，日志'));
      expect(c, matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}')),
          reason: '时间戳是日志的第一信息；缺了它，多行之间无法排序对时');
      expect(c.endsWith('\n'), isTrue);
    });

    test('目录不存在时自动创建（首次启动没有 logs/ 是常态）', () async {
      expect(logDir.existsSync(), isFalse);
      await FileLog(logDir).write('first');
      expect(mainLog().existsSync(), isTrue);
    });

    test('含换行的内容按行拆开，每一行都带时间戳', () async {
      await FileLog(logDir).write('第一行\n第二行');
      final lines = mainLog().readAsLinesSync();
      expect(lines, hasLength(2));
      for (final l in lines) {
        expect(l, matches(RegExp(r'^\d{4}-\d{2}-\d{2}T')),
            reason: '半行无时间戳的日志在 grep 里是孤儿');
      }
    });

    test('echo 回调收到与文件一致的每一行（控制台 + 文件双写不分叉）', () async {
      final echoed = <String>[];
      final log = FileLog(logDir, echo: echoed.add);
      await log.write('甲\n乙');
      expect(echoed, ['甲', '乙']);
      final c = mainLog().readAsStringSync();
      expect(c, contains('甲'));
      expect(c, contains('乙'));
    });
  });

  group('轮转', () {
    test('超过 maxBytes 时轮转：旧内容整体进 .1，主文件从触发行重新开始',
        () async {
      final log = FileLog(logDir, maxBytes: 400, keep: 3);
      // 每行约 40+ 字节（含时间戳），10 行必然越过 400
      for (var i = 1; i <= 10; i++) {
        await log.write('row-$i ${'x' * 30}');
      }
      final rolled = File('${logDir.path}${sep}zaoji.log.1');
      expect(rolled.existsSync(), isTrue, reason: '越过上限必须留下 .1');
      final r = rolled.readAsLinesSync();
      expect(r.any((l) => l.endsWith('row-1 ' + 'x' * 30)), isTrue,
          reason: '轮转是搬家，不是删除——最先那行必须在 .1 里');
      final m = mainLog().readAsLinesSync();
      expect(m.any((l) => l.endsWith('row-1 ' + 'x' * 30)), isFalse,
          reason: '已进 .1 的行不该还留在主文件（那是重复记账）。'
              '★ 必须整行精确匹配——用子串 contains("row-1") 会撞上 row-10，红得毫无意义');
      expect(m.any((l) => l.endsWith('row-10 ' + 'x' * 30)), isTrue,
          reason: '触发本轮的那行必须写进新主文件');
    });

    test('保留份数封顶：第 keep+1 次轮转时最旧一份被删除', () async {
      final log = FileLog(logDir, maxBytes: 100, keep: 2);
      // 每写一行都越界 → 每次都轮转，制造至少 4 次轮转
      for (var i = 1; i <= 20; i++) {
        await log.write('r$i ${'y' * 80}');
      }
      expect(File('${logDir.path}${sep}zaoji.log').existsSync(), isTrue);
      expect(File('${logDir.path}${sep}zaoji.log.1').existsSync(), isTrue);
      expect(File('${logDir.path}${sep}zaoji.log.2').existsSync(), isTrue);
      expect(File('${logDir.path}${sep}zaoji.log.3').existsSync(), isFalse,
          reason: 'keep=2 意味着最多两份历史；没有上限的轮转等于换一种方式涨满磁盘');
    });
  });

  group('日志与事实一致（§六-7 的回归防线）', () {
    late ServerState state;
    late Directory dataDir;
    late Directory webDir;

    setUp(() async {
      dataDir = Directory('${tmp.path}${sep}data');
      webDir = Directory('${tmp.path}${sep}web')..createSync(recursive: true);
      File('${webDir.path}${sep}main.dart.js').writeAsStringSync('js');
      state = await ServerState.boot(ServerConfig(
        host: '127.0.0.1',
        port: 18970,
        tlsPort: 18971,
        dataDir: dataDir,
        certDir: Directory('${tmp.path}${sep}certs'),
        logsDir: logDir,
        webRoot: webDir,
      ));
    });

    tearDown(() async {
      await state.close();
    });

    Future<Response> call(String method, String path) async {
      final handler = ZaojiServer.buildHandler(state, const ['192.168.1.10']);
      return handler(Request(method, Uri.parse('http://localhost$path')));
    }

    test('★ 静态资源：客户端拿 200，日志必须记 200（R9 那个 bug 的钉）',
        () async {
      final res = await call('GET', '/main.dart.js');
      expect(res.statusCode, 200);
      final logged = mainLog().readAsStringSync();
      expect(logged, contains('/main.dart.js → 200'),
          reason: 'R9 的事故：日志中间件只包住 router，静态资源全记成 404 而客户端拿到 200。'
              '日志记的必须是最终响应，不是某一层的中间状态');
      expect(logged, isNot(contains('/main.dart.js → 404')));
    });

    test('★ 真 404 也如实记录（防止改成只记成功）', () async {
      final res = await call('GET', '/no-such-page');
      expect(res.statusCode, 404);
      expect(mainLog().readAsStringSync(), contains('/no-such-page → 404'));
    });

    test('/api/health 报出日志路径与大小（不报内容）', () async {
      await call('GET', '/api/ping');
      final h = await state.healthPayload();
      expect(h['logPath'], mainLog().path);
      expect((h['logBytes'] as int) > 0, isTrue);
      expect(h.containsKey('logContent'), isFalse,
          reason: '日志内容不进健康载荷：状态页局域网任何人可开，日志里有路径等环境信息');
    });
  });
}
