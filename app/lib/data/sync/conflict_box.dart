import 'dart:convert';

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

/// 列名 → 中文。覆盖同步白名单里**全部业务列**（五列公共列除外）。
/// 认不出的原样显示列名——**宁可看见英文列名，也不要显示一个错的名字**；
/// 但"认不出"本身是缺陷，`conflict_box_test` 有闸钉着：
/// 加/改同步列时必须同步这里补词，否则那条测试当场红。
String fieldLabel(String tbl, String field) {
  const labels = <String, Map<String, String>>{
    'recipe': {
      'name': '菜名',
      'sub': '一句话描述',
      'art': '封面插画',
      'pal': '插画配色',
      'difficulty': '难度',
      'self_time': '自定义耗时',
      'cooked_count': '做过次数',
      'servings': '份数',
      'notes': '注意事项',
      'tags': '标签',
      'source': '来源',
      'source_model': '来源模型',
      'source_at': 'AI 生成时间',
      'last_cooked_at': '最近做过',
      'cover_sha256': '封面照片',
      'photos': '照片墙',
      'created_at': '入册时间',
    },
    'ingredient': {
      'recipe_id': '所属菜品',
      'sort': '食材顺序',
      'name': '食材',
      'qty_text': '用量',
      'qty_value': '用量数值',
      'qty_unit': '用量单位',
      'is_main': '主食材',
      'alias_key': '归一名称',
    },
    'step': {
      'recipe_id': '所属菜品',
      'idx': '步骤序号',
      'text': '步骤内容',
      'art': '步骤插画',
      'image_sha256': '步骤照片',
      'images': '步骤照片组',
    },
    'member': {
      'name': '成员',
      'avatar': '头像',
      'allergens': '过敏原',
      'dislikes': '不爱吃',
    },
    'menu': {
      'day': '日期',
      'meal': '餐次',
      'serve_at': '开饭时间',
      'note': '备注',
    },
    'menu_item': {
      'menu_id': '所属菜单',
      'recipe_id': '菜品',
      'sort': '排列顺序',
    },
    'cook_session': {
      'recipe_id': '菜品',
      'started_at': '开始时间',
      'finished_at': '完成时间',
      'current_step': '进行到第几步',
      'servings_used': '实际份数',
      'state': '会话状态',
    },
    'pantry_item': {
      'name': '食材',
      'alias_key': '归一名称',
      'category': '分类',
      'qty_value': '库存量数值',
      'qty_unit': '库存单位',
      'have': '有库存',
      'expire_at': '保质期',
      'is_staple': '常备食材',
      'storage': '存放方式',
      'bought_at': '入册时间',
      'note': '备注',
      'stock_status': '库存状态',
    },
    'shopping_item': {
      'name': '食材',
      'qty_text': '要买量',
      'source': '来源',
      'recipe_id': '关联菜品',
      'bought': '已买',
    },
    'nutrition': {
      'recipe_id': '所属菜品',
      'per_serving_kcal': '每份热量',
      'total_kcal': '总热量',
      'protein_g': '蛋白质（克）',
      'fat_g': '脂肪（克）',
      'carb_g': '碳水（克）',
      'basis': '计算依据',
      'confidence': '把握度',
      'source': '来源',
      'model': '模型',
      'servings_basis': '份数依据',
    },
  };
  if (field == 'deleted_at') return '删除状态';
  return labels[tbl]?[field] ?? field;
}

/// JSON 数组字符串 → 元素列表；解不动回 null（原样显示兜底）。
List<String>? _jsonStrings(String raw) {
  try {
    final d = jsonDecode(raw);
    if (d is List) return d.map((e) => '$e').toList();
  } catch (_) {}
  return null;
}

/// 冲突值的人话显示（原型冲突屏的口径：「15 分钟」「微辣」「3 张照片」，
/// 不是 64 位哈希和裸 JSON）。[dishName] 把 recipe_id 这类引用翻成菜名，
/// 查不到（行已删）就回 null，退化成"有/没有"。
String valueTextFor(String tbl, String field, Object? v,
    {String? Function(String id)? dishName}) {
  if (v == null) return '（空）';
  final s = '$v';

  // 图片引用：哈希对用户没有可比性——说"有没有、几张"。
  if (field == 'cover_sha256' || field == 'image_sha256') {
    return s.isEmpty ? '没有照片' : '有照片';
  }
  if (field == 'photos' || field == 'images') {
    final list = _jsonStrings(s);
    if (list != null) {
      return list.isEmpty ? '没有照片' : '${list.length} 张照片';
    }
  }
  // 菜名引用。
  if (field == 'recipe_id') {
    final name = dishName?.call(s);
    return name != null && name.isNotEmpty ? name : '（一道已删的菜）';
  }
  // JSON 列表/字典 → 顿号串。
  if (field == 'allergens' || field == 'dislikes' || field == 'basis') {
    final list = _jsonStrings(s);
    if (list != null) return list.isEmpty ? '（无）' : list.join('、');
  }
  if (field == 'tags') {
    try {
      final d = jsonDecode(s);
      if (d is Map) {
        final parts = [
          for (final e in d.values)
            if (e is List) ...e.map((x) => '$x'),
        ];
        return parts.isEmpty ? '（无）' : parts.join('、');
      }
    } catch (_) {}
  }
  // 枚举与布尔。
  if (field == 'difficulty') {
    const byValue = {'1': '微辣', '2': '正常辣', '3': '重辣'};
    return byValue[s] ?? '难度 $s';
  }
  if (field == 'stock_status') {
    const byCode = {'have': '充足', 'low': '快没了', 'none': '没有'};
    return byCode[s] ?? s;
  }
  if (field == 'is_main' || field == 'is_staple' || field == 'have' || field == 'bought') {
    return s == '1' || s == 'true' ? '是' : '否';
  }
  if (field == 'confidence') {
    const byValue = {'0.9': '高', '0.6': '中', '0.3': '低'};
    return byValue[s] ?? s;
  }
  if (field == 'source' && tbl != 'shopping_item') {
    const byValue = {'manual': '手动录入', 'ai': 'AI 生成', 'import': '导入'};
    return byValue[s] ?? s;
  }
  // 带单位的数值。
  if (field == 'servings' || field == 'servings_used') return '$s 份';
  if (field == 'self_time') return '$s 分钟';
  if (field == 'cooked_count') return '$s 次';
  if (field == 'idx' || field == 'current_step' || field == 'sort') {
    return '第 $s';
  }
  // 时间戳：ISO 串翻成「今天 19:42」式读数；解不动原样给。
  if (field.endsWith('_at')) {
    final t = DateTime.tryParse(s);
    if (t != null) return _clock(t);
  }
  return s;
}

String _clock(DateTime t) {
  final now = DateTime.now();
  final hm = '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';
  final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
  final y = now.subtract(const Duration(days: 1));
  final yesterday = t.year == y.year && t.month == y.month && t.day == y.day;
  if (sameDay) return '今天 $hm';
  if (yesterday) return '昨天 $hm';
  return '${t.month}月${t.day}日 $hm';
}

/// HLC 串 → 「今天/昨天 HH:mm」（跨天给「M月d日 HH:mm」）。解不开返回空串。
String hlcClock(String hlc) {
  final decoded = Hlc.tryDecode(hlc);
  if (decoded == null) return '';
  return _clock(DateTime.fromMillisecondsSinceEpoch(decoded.physicalMs));
}

/// 设备标识的尾巴四位——完整 nodeId 太长，前缀又全是时间戳没有区分度。
String deviceTail(String nodeId) =>
    nodeId.length <= 4 ? nodeId : nodeId.substring(nodeId.length - 4);

/// 值的显示文本。null 显示「（空）」——它和空字符串在冲突里是两种不同的决定。
String valueText(Object? v) => v == null ? '（空）' : '$v';
