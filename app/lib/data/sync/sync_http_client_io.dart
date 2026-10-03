import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 原生端默认客户端：**连接超时 5 秒**。
///
/// 病灶（2026-10-03 真机）：手机在家庭网外打开「大模型能力」，
/// 到家里局域网 IP 的 TCP 连接永远握不上，裸 `http.Client()` 不设
/// connectionTimeout 时请求可以挂几分钟都不回话——页面钉死在转圈。
/// 这里只掐「连接建立」这一段；连上之后等多久由调用方的超时闸门
/// （SyncEngine._aiTimed / refreshAccessConfig 等）负责，
/// 慢模型、慢同步大包不受影响。
http.Client newSyncHttpClient() => IOClient(
      HttpClient()..connectionTimeout = const Duration(seconds: 5),
    );
