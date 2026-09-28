/// 菜谱的数据模型。
///
/// **字段名刻意与 `shared/lib/src/schema.dart` 里的列名对齐**，
/// 这样下一轮接上 Drift 与同步时，映射层几乎是直译，不需要再做一次脑内翻译
/// （每次翻译都是一次出错机会）。
library;

class Ingredient {
  final String name;

  /// 原始分量文本。**展示永远用这个**——用户写的「半个」不该被显示成「0.5 个」。
  final String qty;

  /// 主食材。推荐算法里缺主食材要 ×0.5，所以这个标记有用。
  final bool isMain;

  /// 归一键（R23 备菜合并用）：西红柿 → 番茄。null = 未算，由合并现场兜底。
  final String? aliasKey;

  const Ingredient(this.name, this.qty, {this.isMain = false, this.aliasKey});
}

class Step {
  /// 步骤原文。**一个字都不要改写**——时间胶囊是渲染时按区间高亮的，
  /// 见 `shared/lib/src/step_time.dart`。
  final String text;

  /// R29：步骤实拍（至多 4 张的 sha256 列表，schema v5 `images` 列）。
  final List<String> images;

  const Step(this.text, {this.images = const []});
}

enum RecipeSource { manual, imported, ai }

/// 封面插画的画法。
///
/// **与高保真原型（zaoji-prototype.html 的 `dishArt()`）逐字对齐**：
/// 同样的 8 种构图（wok 炒锅 / bowl 碗 / plate 盘 / soup 汤 / bake 烤 / noodle 面 /
/// board 砧板 / heat 灶火）、同样的 5 色调色板、同样的 SVG 几何。
/// 见 `widgets/dish_art.dart`——那边负责把这套参数画出来。
enum DishArtKind { wok, bowl, plate, soup, bake, noodle, board, heat }

class Recipe {
  final String id;
  final String name;
  final String sub;
  final int difficulty; // 1~3，对应辣椒刻度
  final int selfTime; // 自报耗时（分钟）
  final int servings; // 分量基数，缩放全靠它
  final String notes;
  final List<Ingredient> ingredients;
  final List<Step> steps;
  final RecipeSource source;
  final String? sourceModel;
  final int cookedCount;

  /// 最近一次做这道菜的日期（`YYYY-MM-DD`）。
  ///
  /// 卡片上显示成 `09/17`，排序的默认档「最近做过」也按它排。
  final String lastCooked;

  /// 收藏。原型里是本机偏好（`S.fav`），不参与同步。
  final bool isFav;

  /// 封面插画。
  final DishArtKind art;

  /// 封面调色板：`[背景亮, 背景深, 主色A, 主色B, 主色C]`，hex 不带 #。
  final List<String> palette;

  /// 标签。键与原型 `TAG_GROUPS` 一致：
  /// `cuisine` 菜系 / `ingredient` 食材 / `taste` 口味 / `method` 操作方式。
  final Map<String, List<String>> tags;

  /// 封面照片的内容地址（sha256）。null = 还没拍照，显示插画。
  /// 字节本体不在同步流里，由显示端按 sha256 从服务端按需拉取（R16）。
  final String? coverSha256;

  /// R29：照片墙的 sha256 列表（多张成品照，schema v5 `photos` 列）。
  /// 封面是**单独选出来的那一张**（coverSha256），两者互不隐含。
  final List<String> photos;

  /// v7（FR-LOG-01）：入册时刻的 ISO8601 原文；**空串 = 不知道**。
  ///
  /// 空串不是偷懒：schema v6 及更早的 recipe 行没有这一列，升级时**故意不回填**
  /// ——用 updated_at 或 ULID 前缀倒推一个时间，日历上就会多出一个没发生过的日子。
  /// 日历遇到空串就不画「新增菜品」那个点。
  final String createdAt;

  const Recipe({
    required this.id,
    required this.name,
    required this.sub,
    required this.difficulty,
    required this.selfTime,
    required this.servings,
    this.notes = '',
    required this.ingredients,
    required this.steps,
    this.source = RecipeSource.manual,
    this.sourceModel,
    this.cookedCount = 0,
    this.lastCooked = '',
    this.isFav = false,
    this.art = DishArtKind.plate,
    this.palette = const [],
    this.tags = const {},
    this.coverSha256,
    this.photos = const [],
    this.createdAt = '',
  });

  bool get isAi => source == RecipeSource.ai;

  /// 主食材名。列表卡片上显示「番茄 · 鸡蛋 · 小葱」用。
  List<String> get mainNames =>
      ingredients.where((i) => i.isMain).map((i) => i.name).toList();

  /// `method` 标签——主页的快捷筛选 rail 用它。
  List<String> get methods => tags['method'] ?? const [];

  /// 最近做过，显示成 `09/17`。空串原样返回（AI 生成的还没做过）。
  String get lastCookedShort {
    if (lastCooked.length < 10) return lastCooked;
    return '${lastCooked.substring(5, 7)}/${lastCooked.substring(8, 10)}';
  }
}

/// 一次做菜会话（R20）。
///
/// 一台设备一次开火 = 一行。进行中 = [finishedAt] 为 null；
/// 「继续做菜」只认 [mine] 的未完成会话——进度是本机的事，记录才是全家的。
class CookSession {
  final String id;
  final String recipeId;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final int currentStep;

  /// 本机进度快照（食材勾选等），JSON 字符串。
  final String? state;

  /// 是否本设备发起的会话。
  final bool mine;

  const CookSession({
    required this.id,
    required this.recipeId,
    required this.startedAt,
    this.finishedAt,
    this.currentStep = 0,
    this.state,
    this.mine = false,
  });

  bool get active => finishedAt == null;

  /// 本次实际耗时（进行中就取到现在）。
  Duration get elapsed => (finishedAt ?? DateTime.now()).difference(startedAt);
}

/// 热量估算（R27，schema 的 nutrition 表）。与菜谱一对一。
///
/// `confidence` 在 schema 里是 REAL（0.9/0.6/0.3 ↔ 高/中/低）——
/// 存数值是为了将来能排序聚合；UI 按阈值翻回「高/中/低」。
/// **它是普通业务数据，跨端同步（FR-AI-51）；显示只取决于有没有值（FR-REC-23）。**
class Nutrition {
  final String id;
  final String recipeId;
  final double perServingKcal;
  final double totalKcal;
  final double? proteinG;
  final double? fatG;
  final double? carbG;

  /// 逐食材贡献（JSON 字符串，原样存取——UI 只在「看依据」里展开）。
  final String? basisJson;
  final double? confidence;
  final String source; // ai / manual
  final String? model;
  final int? servingsBasis;

  const Nutrition({
    required this.id,
    required this.recipeId,
    required this.perServingKcal,
    required this.totalKcal,
    this.proteinG,
    this.fatG,
    this.carbG,
    this.basisJson,
    this.confidence,
    this.source = 'ai',
    this.model,
    this.servingsBasis,
  });

  factory Nutrition.fromRow(Map<String, Object?> row) => Nutrition(
        id: '${row['id']}',
        recipeId: '${row['recipe_id']}',
        perServingKcal: (row['per_serving_kcal'] as num?)?.toDouble() ?? 0,
        totalKcal: (row['total_kcal'] as num?)?.toDouble() ?? 0,
        proteinG: (row['protein_g'] as num?)?.toDouble(),
        fatG: (row['fat_g'] as num?)?.toDouble(),
        carbG: (row['carb_g'] as num?)?.toDouble(),
        basisJson: row['basis'] as String?,
        confidence: (row['confidence'] as num?)?.toDouble(),
        source: '${row['source'] ?? 'ai'}',
        model: row['model'] as String?,
        servingsBasis: row['servings_basis'] as int?,
      );

  /// 把握度文案（对齐原型 badge：高/中/低）。
  String get confidenceLabel {
    final c = confidence;
    if (c == null) return '—';
    if (c >= 0.8) return '高';
    if (c >= 0.5) return '中';
    return '低';
  }

  int get perServingKcalRounded => perServingKcal.round();
  int get totalKcalRounded => totalKcal.round();
}

/// 库存条目（R28，schema 的 pantry_item 表）。
///
/// **「辅助决策，不是账本」**（schema 注释原话）——允许只记「有/没有」：
/// `qtyValue=null` 就是模糊库存，步进器只在有数值分量时出现。
/// 库存三态（schema v7 `stock_status`，FR-PAN-01）。
///
/// 为什么不是布尔：推荐和提醒要区分"还有"和"快见底"——`low` 是"今天不买明天就没"，
/// 这一档旧模型里根本没有位置。迁移时 `have=1` 一律落成 [have]，
/// **不猜 low**（见 shared 的 kSchemaV7AlterSql 注释）。
enum PantryStock {
  have('have', '充足'),
  low('low', '快没了'),
  none('none', '没有');

  const PantryStock(this.code, this.label);

  /// 落库值（也是同步流里的字符串），与 schema 注释一一对应。
  final String code;

  /// 界面用语。
  final String label;

  /// 认不出来的值按 [have] 处理：这一列 NOT NULL DEFAULT 'have'，
  /// 库里不可能有别的形状；真出现说明是别的端写的脏值，按"有"最保守
  /// （不会把用户手里的东西判成没有，也不会误报快没了）。
  static PantryStock ofCode(Object? raw) {
    final s = '$raw';
    return PantryStock.values.firstWhere((e) => e.code == s,
        orElse: () => PantryStock.have);
  }
}

class PantryItem {
  final String id;
  final String name;
  final String? aliasKey;
  final String? category; // 蔬菜/调料/肉类…（自由文本，UI 归组用）
  final double? qtyValue;
  final String? qtyUnit;

  /// v7：三态。[have] 是它的便捷读法（旧调用点一片 `p.have`，
  /// 留个 getter 比把它们全改成 `status != none` 更不容易漏）。
  final PantryStock status;

  final String? expireAt; // YYYY-MM-DD
  final bool isStaple; // 常备调料：不参与缺失判定（FR-PAN-05）

  /// v7：冷藏 / 冷冻 / 常温；null = 没填（不替用户猜）。
  final String? storage;

  /// v7：购入日期 YYYY-MM-DD。"在家躺了几天"是消耗判断的另一半。
  final String? boughtAt;

  /// v7：备注，如"给宝的那份少盐"。
  final String? note;

  const PantryItem({
    required this.id,
    required this.name,
    this.aliasKey,
    this.category,
    this.qtyValue,
    this.qtyUnit,
    this.status = PantryStock.have,
    this.expireAt,
    this.isStaple = false,
    this.storage,
    this.boughtAt,
    this.note,
  });

  /// 「还有没有」——三态里除了 none 都算有（推荐算法吃的就是这个值）。
  bool get have => status != PantryStock.none;

  factory PantryItem.fromRow(Map<String, Object?> row) => PantryItem(
        id: '${row['id']}',
        name: '${row['name']}',
        aliasKey: row['alias_key'] as String?,
        category: row['category'] as String?,
        qtyValue: (row['qty_value'] as num?)?.toDouble(),
        qtyUnit: row['qty_unit'] as String?,
        // 有 stock_status 就读它；没有（旧库/旧行）退回 have 的 0/1 语义
        status: row['stock_status'] == null
            ? ((row['have'] as int? ?? 1) == 1
                ? PantryStock.have
                : PantryStock.none)
            : PantryStock.ofCode(row['stock_status']),
        expireAt: row['expire_at'] as String?,
        isStaple: (row['is_staple'] as int? ?? 0) == 1,
        storage: row['storage'] as String?,
        boughtAt: row['bought_at'] as String?,
        note: row['note'] as String?,
      );

  /// 分量展示文案：`250 g` / `约` / 空。
  String get qtyLabel {
    if (!have) return '没有';
    final v = qtyValue;
    if (v == null) return '';
    final s = v == v.roundToDouble() ? v.round().toString() : '$v';
    return qtyUnit == null || qtyUnit!.isEmpty ? s : '$s $qtyUnit';
  }

  /// 保质期状态（FR-PAN-04）：过期 / 3 天内到期 / 其余不提示。
  /// 用**日期字符串比较**不做 now 减法——同一自然日内多次打开不跳变。
  String expState(DateTime now) {
    final e = expireAt;
    if (e == null || e.length < 10) return '';
    final d = DateTime.tryParse(e);
    if (d == null) return '';
    final today = DateTime(now.year, now.month, now.day);
    final dd = DateTime(d.year, d.month, d.day);
    final diff = dd.difference(today).inDays;
    if (diff <= 0) return 'bad';
    if (diff <= 3) return 'soon';
    return '';
  }
}

/// 购物清单条目（R30，schema v6 shopping_item）。
class ShoppingItem {
  final String id;
  final String name;
  final String? qtyText;
  final String source; // manual / reco / prep
  final String? recipeId;
  final bool bought;

  const ShoppingItem({
    required this.id,
    required this.name,
    this.qtyText,
    this.source = 'manual',
    this.recipeId,
    this.bought = false,
  });

  factory ShoppingItem.fromRow(Map<String, Object?> row) => ShoppingItem(
        id: '${row['id']}',
        name: '${row['name']}',
        qtyText: row['qty_text'] as String?,
        source: '${row['source'] ?? 'manual'}',
        recipeId: row['recipe_id'] as String?,
        bought: (row['bought'] as int? ?? 0) == 1,
      );

  String get sourceLabel => switch (source) {
        'reco' => '缺项',
        'prep' => '备菜',
        _ => '手动',
      };
}

/// 写热量用的草稿（saveNutrition 的入参）。
class NutritionDraft {
  final double perServingKcal;
  final double totalKcal;
  final double? proteinG;
  final double? fatG;
  final double? carbG;
  final String? basisJson;
  final double? confidence;
  final String source;
  final String? model;
  final int? servingsBasis;

  const NutritionDraft({
    required this.perServingKcal,
    required this.totalKcal,
    this.proteinG,
    this.fatG,
    this.carbG,
    this.basisJson,
    this.confidence,
    this.source = 'ai',
    this.model,
    this.servingsBasis,
  });

  /// AI 的 high/medium/low → 数值。
  static double? confidenceFromWire(String? c) => switch (c) {
        'high' => 0.9,
        'medium' => 0.6,
        'low' => 0.3,
        _ => null,
      };
}
