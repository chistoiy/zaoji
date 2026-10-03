// 同步/AI 通道默认 HTTP 客户端的编译期分派。
//
// 原生端（Android/桌面）需要 `dart:io` 的 HttpClient 才能设 connectionTimeout；
// Web 端没有 dart:io，浏览器自己管连接。姿势同 share_sheet.dart 的条件导入。
export 'sync_http_client_io.dart'
    if (dart.library.js_interop) 'sync_http_client_web.dart';
