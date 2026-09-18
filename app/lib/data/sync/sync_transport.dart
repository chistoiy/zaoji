import 'dart:convert';

import 'package:http/http.dart' as http;

/// 同步接口的 HTTP 传输层。
///
/// 独立成抽象层的理由：引擎测试要能脱离真网络跑（fake transport），
/// 而协议语义（状态码、错误载荷的形状）必须在这里**原样**暴露给引擎——
/// 409（协议不匹配）、401（token 失效）、413/429 这几类响应引擎要区分对待，
/// 不能被包成一句"网络错误"。
abstract class SyncTransport {
  Future<Map<String, Object?>> get(String path, {String? token});
  Future<Map<String, Object?>> post(String path, Map<String, Object?> body,
      {String? token});
  void close();
}

/// 服务端返回了非 2xx。**载荷原样带上**——`protocol_mismatch`、
/// `too_many_attempts` 这些错误码是客户端要做分支决策的依据。
class SyncTransportException implements Exception {
  const SyncTransportException(this.statusCode, this.payload);

  final int statusCode;

  /// 服务端的 JSON 载荷（error / message / serverProtocolVersion…）。
  final Map<String, Object?> payload;

  String get errorCode => '${payload['error'] ?? ''}';
  String get message => '${payload['message'] ?? 'HTTP $statusCode'}';

  @override
  String toString() => 'SyncTransportException($statusCode, $errorCode)';
}

/// 网络层本身失败（连不上、超时、响应不是 JSON）。
class SyncNetworkException implements Exception {
  const SyncNetworkException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() => 'SyncNetworkException: $message'
      '${cause == null ? '' : ' ($cause)'}';
}

class HttpSyncTransport implements SyncTransport {
  HttpSyncTransport(this.baseUrl, {http.Client? client})
      : _client = client ?? http.Client();

  /// 形如 `http://192.168.31.141:8666`。收发都用它拼接路径。
  final Uri baseUrl;

  final http.Client _client;

  Map<String, String> _headers(String? token) => {
        'content-type': 'application/json; charset=utf-8',
        if (token != null && token.isNotEmpty) 'authorization': 'Bearer $token',
      };

  Uri _uri(String path) => baseUrl.resolve(path);

  @override
  Future<Map<String, Object?>> get(String path, {String? token}) async {
    final res = await _guard(() => _client.get(_uri(path), headers: _headers(token)));
    return res;
  }

  @override
  Future<Map<String, Object?>> post(String path, Map<String, Object?> body,
      {String? token}) async {
    final res = await _guard(
      () => _client.post(_uri(path), headers: _headers(token),
          body: jsonEncode(body)),
    );
    return res;
  }

  Future<Map<String, Object?>> _guard(
      Future<http.Response> Function() send) async {
    final http.Response res;
    try {
      res = await send();
    } catch (e) {
      throw SyncNetworkException('连不上服务端', e);
    }
    final Map<String, Object?> payload;
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      payload = decoded is Map ? decoded.map((k, v) => MapEntry('$k', v)) : {};
    } catch (e) {
      throw SyncNetworkException('服务端响应不是 JSON（HTTP ${res.statusCode}）', e);
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw SyncTransportException(res.statusCode, payload);
    }
    return payload;
  }

  @override
  void close() => _client.close();
}
