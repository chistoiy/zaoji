/// 灶记 ZAOJI · 共用层
///
/// 这里放的是**两端必须逐字节一致**的纯逻辑：
/// 时间关键词解析、单位换算、食材合并、冲突判定、HLC 时钟。
///
/// 判断某个函数该不该放这里的标准只有一条：
/// **如果 Android 端和 Web 端各写一份，会不会出现行为差异？**
/// 会，就放这里，并且必须有单测。
library;

export 'src/cn_number.dart';
export 'src/conflict.dart';
export 'src/hlc.dart';
export 'src/ingredient.dart';
export 'src/schema.dart';
export 'src/step_time.dart';
export 'src/sync_access.dart';
export 'src/ulid.dart';
export 'src/units.dart';
