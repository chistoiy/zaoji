import 'package:http/http.dart' as http;

/// Web 端默认客户端：浏览器自己管连接（同源请求，连不上时页面本身也打不开），
/// 没有可配置的 connectionTimeout，保持裸 Client。
http.Client newSyncHttpClient() => http.Client();
