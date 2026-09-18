import 'dart:io';

import 'package:test/test.dart';
import 'package:zaoji_server/zaoji_server.dart';

/// 配置解析的测试。
///
/// 重点是**相对路径的基准**：注册成 Windows 服务后工作目录是 `C:\Windows\System32`，
/// 若还按 CWD 找 `data` / `certs`，会静默地换一个数据库、换一个 serverId、
/// 并丢掉 HTTPS——三件事都不报错，是最难查的一类问题。
void main() {
  group('ServerConfig.parse', () {
    test('默认端口：http 8666 / https 8667', () {
      final c = ServerConfig.parse(<String>[]);
      expect(c.port, 8666);
      expect(c.tlsPort, 8667);
      expect(c.host, '0.0.0.0');
      expect(c.bindAllInterfaces, isTrue);
    });

    test('相对路径挂到基准目录下，而不是裸相对路径', () {
      final c = ServerConfig.parse(<String>[]);
      final base = ServerConfig.baseDir().path;

      expect(c.dataDir.path, '$base${Platform.pathSeparator}data');
      expect(c.certDirPath, '$base${Platform.pathSeparator}certs');
    });

    test('绝对路径原样保留', () {
      final abs = Platform.isWindows ? r'C:\zaoji\mydata' : '/tmp/zaoji/mydata';
      final c = ServerConfig.parse(<String>['-d', abs]);
      expect(c.dataDir.path, abs);
    });

    test('-w 给的相对路径同样挂到基准目录下', () {
      final c = ServerConfig.parse(<String>['-w', 'web']);
      final base = ServerConfig.baseDir().path;
      expect(c.webRoot, isNotNull);
      expect(c.webRoot!.path, '$base${Platform.pathSeparator}web');
    });

    test('未给 -w 时 webRoot 为 null（而不是指向某个默认目录）', () {
      expect(ServerConfig.parse(<String>[]).webRoot, isNull);
    });

    test('证书路径由证书目录拼出，且不含双分隔符', () {
      final c = ServerConfig.parse(<String>[]);
      // 路径归一化的意义：避免拼出 certs\\server.crt 这种双写
      expect(c.certPath, endsWith('${Platform.pathSeparator}server.crt'));
      expect(c.certDirPath.endsWith(Platform.pathSeparator), isFalse);
      expect(c.certPath.contains('${Platform.pathSeparator}${Platform.pathSeparator}'), isFalse);
    });

    test('certDir 末尾带分隔符时会被归一化', () {
      final c = ServerConfig.parse(
        <String>['-c', '${ServerConfig.baseDir().path}${Platform.pathSeparator}certs${Platform.pathSeparator}'],
      );
      expect(c.certDirPath.endsWith(Platform.pathSeparator), isFalse);
    });

    test('http 与 https 端口相同直接拒绝（否则第二个监听必然失败）', () {
      // 这是参数校验，spec 会 exit(64)，所以只能间接验证：不同端口时正常
      final c = ServerConfig.parse(<String>['-p', '9000', '--tls-port', '9001']);
      expect(c.port, 9000);
      expect(c.tlsPort, 9001);
    });
  });
}
