import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// Web：文本 → Blob → 隐形 `<a download>` 点一下，浏览器落地成文件。
///
/// 不碰服务端、不碰局域网地址（FR-SHARE-07 红线在文本生成那层就把住了）。
void downloadTextFile(String filename, String content) {
  final blob = web.Blob(
    [content.toJS].toJS,
    web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final a = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = filename;
  web.document.body!.appendChild(a);
  a.click();
  web.document.body!.removeChild(a);
  web.URL.revokeObjectURL(url);
}
