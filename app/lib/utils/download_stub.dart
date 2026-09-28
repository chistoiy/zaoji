/// 把文本交给浏览器下载（Web 载体的落地）。
///
/// 条件导出的一部分：非 Web 端调用是 no-op——面板在 `kIsWeb` 之外
/// 根本不渲染这个按钮，这里的空实现只为让编译图完整。
library;

void downloadTextFile(String filename, String content) {}
