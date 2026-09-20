/// 灶记 ZAOJI 服务端
///
/// 部署形态：AOT 编译成单个 exe，跑在家里那台常年开机的笔记本上，
/// 同时承担三件事：
/// ① 与 Android App 双向同步数据；
/// ② 托管 Flutter Web 产物（iPhone / 平板的入口）；
/// ③ 代理大模型调用（Web 端前端不持有 API Key）。
library;

export 'src/config.dart';
export 'src/db.dart';
export 'src/media.dart';
export 'src/media_gc.dart';
export 'src/server.dart';
export 'src/server_state.dart';
export 'src/sqlite_loader.dart';
export 'src/sync.dart';
export 'src/web_pages.dart';
