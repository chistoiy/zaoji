import 'package:zaoji_shared/zaoji_shared.dart';

/// 冲突箱的展示形态（R22）。
///
/// 数据本体是同步下来的 `conflict_item` 行（服务端一行一字段一条），
/// 这里只做两件 UI 直接需要的事：**按行分组** 与 **把机器名/列名翻译成人话**。
class ConflictField {
  const ConflictField({
    required this.id,
    required this.field,
    required this.localValue,
    required this.remoteValue,
    required this.localBy,
    required this.remoteBy,
    required this.localHlc,
    required this.remoteHlc,
  });

  /// conflict_item.id——提交裁决时认的就是它。
  final String id;
  final String field;
  final Object? localValue;
  final Object? remoteValue;
  final String localBy;
  final String remoteBy;
  final String localHlc;
  final String remoteHlc;
}

class ConflictGroup {
  const ConflictGroup({
    required this.tbl,
    required this.rowId,
    required this.title,
    required this.fields,
  });

  final String tbl;
  final String rowId;

  /// 这行属于哪道菜（找不到行时退化为 id 片段——墓碑行也可能有冲突）。
  final String title;
  final List<ConflictField> fields;
}

/// 列名 → 中文。只覆盖会进同步白名单的业务字段；
/// 认不出的原样显示列名——**宁可看见英文列名，也不要显示一个错的名字**。
String fieldLabel(String tbl, String field) {
  const labels = <String, Map<String, String>>{
    'recipe': {
      'name': '菜名',
      'sub': '副标题',
      'difficulty': '难度',
      'self_time': '自定义耗时',
      'servings': '份数',
      'notes': '注意事项',
      'tags': '标签',
      'cover_sha256': '封面',
    },
    'step': {'seq': '步骤序号', 'text': '步骤内容', 'time_desc': '步骤时间'},
    'ingredient': {'name': '食材', 'amount': '用量', 'note': '备注'},
    'member': {'name': '成员', 'allergens': '过敏原'},
    'menu': {'title': '菜单标题', 'planned_at': '计划时间'},
    'menu_item': {'recipe_id': '菜品', 'slot': '餐次'},
    'cook_session': {'started_at': '开始时间', 'finished_at': '完成时间'},
    'pantry_item': {'name': '食材', 'amount': '库存量'},
    'nutrition': {'kcal': '热量', 'protein_g': '蛋白质', 'fat_g': '脂肪', 'carb_g': '碳水'},
  };
  if (field == 'deleted_at') return '删除状态';
  return labels[tbl]?[field] ?? field;
}

/// HLC 串 → 「M月d日 HH:mm」。解不开就返回空串（不显示乱码时间戳）。
String hlcClock(String hlc) {
  final decoded = Hlc.tryDecode(hlc);
  if (decoded == null) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(decoded.physicalMs);
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  return '${t.month}月${t.day}日 $hh:$mm';
}

/// 设备标识的尾巴四位——完整 nodeId 太长，前缀又全是时间戳没有区分度。
String deviceTail(String nodeId) =>
    nodeId.length <= 4 ? nodeId : nodeId.substring(nodeId.length - 4);

/// 值的显示文本。null 显示「（空）」——它和空字符串在冲突里是两种不同的决定。
String valueText(Object? v) => v == null ? '（空）' : '$v';
