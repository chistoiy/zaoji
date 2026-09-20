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

  const Ingredient(this.name, this.qty, {this.isMain = false});
}

class Step {
  /// 步骤原文。**一个字都不要改写**——时间胶囊是渲染时按区间高亮的，
  /// 见 `shared/lib/src/step_time.dart`。
  final String text;

  const Step(this.text);
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
