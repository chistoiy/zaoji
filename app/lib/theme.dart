import 'package:flutter/material.dart';

/// 灶记的设计令牌。
///
/// **两条纪律，改这个文件前先读完：**
///
/// 1. 色值不在 Dart 里"重新设计"。五套调色板与 `zaoji-prototype.html` 头部
///    那五个 `[data-theme]` 块**一一对应**（同名同值），原型是设计源。
///    两边漂移的后果不是"颜色差一点"，而是评审时看到的和装到手机上不一样。
///    改任何一套，两边一起改；`tool/proto_theme_audit.cjs` 会量原型那一侧，
///    `app/test/theme_test.dart` 会钉这一侧的对应关系。
///
/// 2. 页面里**不要写颜色字面量**。以前是 `ZaojiColors.paper`（编译期常量，
///    所以随手就能用在 const 里），R39 起换成 [ZaojiTokens]——
///    一个挂在 `Theme` 上的 [ThemeExtension]，因为常量做不到"跟着主题翻"。
///    取法：`final zj = context.zj;` 然后 `zj.paper`。
///    漏了这一步的代价不是报错，是**深色主题下某个界面看不见**。
class ZaojiTokens extends ThemeExtension<ZaojiTokens> {
  const ZaojiTokens({
    required this.id,
    required this.label,
    required this.hint,
    required this.brightness,
    required this.paper,
    required this.paper2,
    required this.paper3,
    required this.surface,
    required this.surface2,
    required this.tint,
    required this.tint2,
    required this.ink,
    required this.ink2,
    required this.muted,
    required this.line,
    required this.lineSoft,
    required this.accent,
    required this.accentDeep,
    required this.accentSoft,
    required this.accentSofter,
    required this.onAccent,
    required this.amber,
    required this.amber2,
    required this.amberBg,
    required this.ai,
    required this.aiBg,
    required this.warn,
    required this.warnBg,
    required this.ok,
    required this.okBg,
    required this.chili,
    required this.tagCuisine,
    required this.tagIngredient,
    required this.tagTaste,
    required this.tagMethod,
    required this.tagCustom,
    required this.onScrim,
  });

  /// 主题标识，落 `local_pref` 的就是它（改名 = 用户存的偏好失效，慎动）。
  final String id;

  /// 界面用语：主题名与那行副标题。
  final String label;
  final String hint;

  /// 明暗。**必须由调色板自己说**——Material 组件（弹窗、菜单、滚动条）
  /// 按它决定默认前景色；写错的结果是"深色主题上弹出白底白字"。
  final Brightness brightness;

  /// 暖纸。整个 App 的底色。paper2/3 是更深的两级分组底。
  final Color paper;
  final Color paper2;
  final Color paper3;

  /// 卡片面。surface2 是卡片里再分一层小组件时的底。
  final Color surface;
  final Color surface2;

  /// 淡染：给"这一条和别的不一样"用的小面积底色。
  final Color tint;
  final Color tint2;

  /// 墨。ink 正文、ink2 次级、muted 弱化（时间戳、单位、提示）。
  final Color ink;
  final Color ink2;
  final Color muted;

  /// 分隔线。
  final Color line;
  final Color lineSoft;

  /// **唯一强调色。** 一屏之内只有一个东西是纯强调色，那个位置留给主操作。
  final Color accent;

  /// 强调色的深一档（渐变末端、按下态）与两级淡底。
  final Color accentDeep;
  final Color accentSoft;
  final Color accentSofter;

  /// 压在 [accent] 上的字/图标色。
  ///
  /// ★ 深色主题下它是**近黑**：强调色在暗底上会提亮（柿红 D2491C → E2653A），
  ///   这时白字压在亮橙上只有 3.1:1，黑字才有 5.8:1。
  ///   所以这个值必须随主题翻——它和 [onScrim] 是两回事，别混用。
  final Color onAccent;

  /// 时间胶囊的琥珀（做菜时"可以点起计时"的东西都用它）。amber2 是填充档。
  final Color amber;
  final Color amber2;
  final Color amberBg;

  /// AI 功能区隔色。与强调色刻意拉开，避免和"主操作"混淆。
  final Color ai;
  final Color aiBg;

  /// 警示（过期、冲突、过敏原文字侧）。
  final Color warn;
  final Color warnBg;

  /// "充足/正常"侧：库存三态的第一个点、日历的第三种点。
  final Color ok;
  final Color okBg;

  /// 难度辣椒。刻意比强调色暗一档：难度刻度是一片纹理，不该跟主操作抢。
  final Color chili;

  /// ── 标签组颜色（与原型 `--t-*` 一一对应）──
  /// **不是随手挑的**：五组标签各占一个色相，用户靠颜色区分"这是菜系还是口味"。
  /// 改任何一个都要五个一起看。
  final Color tagCuisine;
  final Color tagIngredient;
  final Color tagTaste;
  final Color tagMethod;
  final Color tagCustom;

  /// 压在**照片/沉浸面**上的字色：封面图上的菜名、全屏计时器、悬浮计时球。
  ///
  /// ★ 它**故意不随主题翻**（五套主题里都是同一个暖白）。理由：这些文字下面
  ///   是图片或者固定的深色沉浸面，不是纸。跟着主题翻成深色，
  ///   深色主题下封面图上的菜名就没了。
  final Color onScrim;

  // ══════════════════════ 五套调色板（与原型逐字对应）══════════════════════

  /// 1 · 柿红暖纸：设计定调那一套，也是默认。
  static const ZaojiTokens shihong = ZaojiTokens(
    id: 'shihong',
    label: '柿红暖纸',
    hint: '暖纸底 · 柿红',
    brightness: Brightness.light,
    paper: Color(0xFFFBF6EC),
    paper2: Color(0xFFF4ECDD),
    paper3: Color(0xFFEBE0CC),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFFDFBF6),
    tint: Color(0xFFFFF7E9),
    tint2: Color(0xFFFFF3E8),
    ink: Color(0xFF231C15),
    ink2: Color(0xFF5A4E42),
    muted: Color(0xFF726658),
    line: Color(0x21231C15),
    lineSoft: Color(0x11231C15),
    accent: Color(0xFFD2491C),
    accentDeep: Color(0xFFA8350F),
    accentSoft: Color(0x1AD2491C),
    accentSofter: Color(0x0BD2491C),
    onAccent: Color(0xFFFFF3EA),
    amber: Color(0xFF8E5F0C),
    amber2: Color(0xFFB8801A),
    amberBg: Color(0x38E0A32E),
    ai: Color(0xFF6E4468),
    aiBg: Color(0x176E4468),
    warn: Color(0xFF8C2F0E),
    warnBg: Color(0x1AD2491C),
    ok: Color(0xFF3E6B4F),
    okBg: Color(0x1F3E6B4F),
    chili: Color(0xFFB5532A),
    tagCuisine: Color(0xFFA83C22),
    tagIngredient: Color(0xFF37634A),
    tagTaste: Color(0xFF6F4269),
    tagMethod: Color(0xFF2A5F6B),
    tagCustom: Color(0xFF836127),
    onScrim: Color(0xFFFBF6EC),
  );

  /// 2 · 蓝染粗布：冷调浅底。强调色让给靛蓝，绿色完整留给"充足"。
  static const ZaojiTokens indigo = ZaojiTokens(
    id: 'indigo',
    label: '蓝染粗布',
    hint: '冷白底 · 靛蓝',
    brightness: Brightness.light,
    paper: Color(0xFFF2F5F8),
    paper2: Color(0xFFE7EDF3),
    paper3: Color(0xFFDAE3EC),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFFAFCFE),
    tint: Color(0xFFF7FAFD),
    tint2: Color(0xFFEEF4F9),
    ink: Color(0xFF16202B),
    ink2: Color(0xFF43535F),
    muted: Color(0xFF5B6A76),
    line: Color(0x2416202B),
    lineSoft: Color(0x1216202B),
    accent: Color(0xFF2B5D8C),
    accentDeep: Color(0xFF1B4266),
    accentSoft: Color(0x1A2B5D8C),
    accentSofter: Color(0x0D2B5D8C),
    onAccent: Color(0xFFF2F7FB),
    amber: Color(0xFF7A5A10),
    amber2: Color(0xFFA87C1E),
    amberBg: Color(0x33C89B3C),
    ai: Color(0xFF5B4A8A),
    aiBg: Color(0x175B4A8A),
    warn: Color(0xFF9E2F1E),
    warnBg: Color(0x1A9E2F1E),
    ok: Color(0xFF2A6049),
    okBg: Color(0x212A6049),
    chili: Color(0xFF8C4A2A),
    tagCuisine: Color(0xFF9A3B2E),
    tagIngredient: Color(0xFF2F6B52),
    tagTaste: Color(0xFF6B4A8A),
    tagMethod: Color(0xFF1F5F72),
    tagCustom: Color(0xFF7A5A10),
    onScrim: Color(0xFFFBF6EC),
  );

  /// 3 · 胭脂米白：暖调浅底，强调色是胭脂。
  static const ZaojiTokens rouge = ZaojiTokens(
    id: 'rouge',
    label: '胭脂米白',
    hint: '暖白底 · 胭脂',
    brightness: Brightness.light,
    paper: Color(0xFFFAF4F1),
    paper2: Color(0xFFF3E8E4),
    paper3: Color(0xFFEADAD4),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFFDF9F7),
    tint: Color(0xFFFDF6F3),
    tint2: Color(0xFFF8ECE7),
    ink: Color(0xFF26191A),
    ink2: Color(0xFF59484A),
    muted: Color(0xFF766262),
    line: Color(0x2126191A),
    lineSoft: Color(0x1126191A),
    accent: Color(0xFFB03A52),
    accentDeep: Color(0xFF8A2439),
    accentSoft: Color(0x1AB03A52),
    accentSofter: Color(0x0DB03A52),
    onAccent: Color(0xFFFDF2F0),
    amber: Color(0xFF7E5A12),
    amber2: Color(0xFFA87C1E),
    amberBg: Color(0x38D6A440),
    ai: Color(0xFF6E4468),
    aiBg: Color(0x176E4468),
    warn: Color(0xFF93321F),
    warnBg: Color(0x1A93321F),
    ok: Color(0xFF2F6247),
    okBg: Color(0x212F6247),
    chili: Color(0xFFA8443C),
    tagCuisine: Color(0xFFA83C22),
    tagIngredient: Color(0xFF37634A),
    tagTaste: Color(0xFF7A3F63),
    tagMethod: Color(0xFF2A5F6B),
    tagCustom: Color(0xFF836127),
    onScrim: Color(0xFFFBF6EC),
  );

  /// 4 · 夜灶暖光：夜里在灶台前打开它不刺眼。
  static const ZaojiTokens night = ZaojiTokens(
    id: 'night',
    label: '夜灶暖光',
    hint: '夜里开火不刺眼',
    brightness: Brightness.dark,
    paper: Color(0xFF17120E),
    paper2: Color(0xFF211A14),
    paper3: Color(0xFF2B231B),
    surface: Color(0xFF1F1913),
    surface2: Color(0xFF241D16),
    tint: Color(0xFF26201A),
    tint2: Color(0xFF2E261E),
    ink: Color(0xFFF2E8D9),
    ink2: Color(0xFFC9B9A5),
    muted: Color(0xFFB5A48D),
    line: Color(0x26F2E8D9),
    lineSoft: Color(0x13F2E8D9),
    accent: Color(0xFFE2653A),
    accentDeep: Color(0xFFF08255),
    accentSoft: Color(0x2BE2653A),
    accentSofter: Color(0x17E2653A),
    onAccent: Color(0xFF1A0F09),
    amber: Color(0xFFD9A441),
    amber2: Color(0xFFB8801A),
    amberBg: Color(0x2BD9A441),
    ai: Color(0xFFB98BC4),
    aiBg: Color(0x26B98BC4),
    warn: Color(0xFFF0805E),
    warnBg: Color(0x26F0805E),
    ok: Color(0xFF7FBF92),
    okBg: Color(0x267FBF92),
    chili: Color(0xFFD97A4A),
    tagCuisine: Color(0xFFE08A6A),
    tagIngredient: Color(0xFF7FBF92),
    tagTaste: Color(0xFFC79AD0),
    tagMethod: Color(0xFF6FB6C9),
    tagCustom: Color(0xFFDBB86A),
    onScrim: Color(0xFFFBF6EC),
  );

  /// 5 · 青石夜色：冷调深色，夜里厨房的灯是白的。
  static const ZaojiTokens stone = ZaojiTokens(
    id: 'stone',
    label: '青石夜色',
    hint: '夜色冷调 · 青蓝',
    brightness: Brightness.dark,
    paper: Color(0xFF101416),
    paper2: Color(0xFF182024),
    paper3: Color(0xFF212B31),
    surface: Color(0xFF161C20),
    surface2: Color(0xFF1A2126),
    tint: Color(0xFF1C252A),
    tint2: Color(0xFF232E35),
    ink: Color(0xFFE3EBEA),
    ink2: Color(0xFFB4C2C4),
    muted: Color(0xFF95A9AD),
    line: Color(0x26E3EBEA),
    lineSoft: Color(0x13E3EBEA),
    accent: Color(0xFF6FA8C9),
    accentDeep: Color(0xFF8FC2DE),
    accentSoft: Color(0x2B6FA8C9),
    accentSofter: Color(0x176FA8C9),
    onAccent: Color(0xFF0C1418),
    amber: Color(0xFFD3AE63),
    amber2: Color(0xFFA8874A),
    amberBg: Color(0x29D3AE63),
    ai: Color(0xFFA99AD8),
    aiBg: Color(0x26A99AD8),
    warn: Color(0xFFE8896F),
    warnBg: Color(0x26E8896F),
    ok: Color(0xFF74B98D),
    okBg: Color(0x2674B98D),
    chili: Color(0xFFC98A63),
    tagCuisine: Color(0xFFDE8E74),
    tagIngredient: Color(0xFF74B98D),
    tagTaste: Color(0xFFB4A3DE),
    tagMethod: Color(0xFF6FA8C9),
    tagCustom: Color(0xFFD3AE63),
    onScrim: Color(0xFFFBF6EC),
  );

  /// 全部可选主题。**顺序就是设置页里的顺序。**
  static const List<ZaojiTokens> all = [
    shihong,
    indigo,
    rouge,
    night,
    stone,
  ];

  /// 找不到 extension 时的兜底（例如 widget 测试里手搓的 ThemeData），
  /// 也是**没选过主题时的默认那套**。
  ///
  /// ★ R39 收尾由用户拍板：默认从「柿红暖纸」换成「蓝染粗布」。
  ///   理由不只是偏好——靛蓝把强调色让出来之后，绿色能完整留给"充足"
  ///   这个状态语义（原来强调色和状态色都是红/绿系，一屏里打架）；
  ///   而且主按钮的反白对比过了 AA（柿红那套只有 4.09，要修就得动品牌色）。
  ///   ★ 改默认主题要一起改的四处：原型的 DEFAULT_THEME、图标纸底、
  ///     manifest 的 background/theme-color、审计脚本 THEMES 的第一个（基线）。
  static const ZaojiTokens fallback = indigo;

  static ZaojiTokens of(BuildContext context) =>
      Theme.of(context).extension<ZaojiTokens>() ?? fallback;

  @override
  ZaojiTokens copyWith({
    String? id,
    String? label,
    String? hint,
    Brightness? brightness,
    Color? paper,
    Color? paper2,
    Color? paper3,
    Color? surface,
    Color? surface2,
    Color? tint,
    Color? tint2,
    Color? ink,
    Color? ink2,
    Color? muted,
    Color? line,
    Color? lineSoft,
    Color? accent,
    Color? accentDeep,
    Color? accentSoft,
    Color? accentSofter,
    Color? onAccent,
    Color? amber,
    Color? amber2,
    Color? amberBg,
    Color? ai,
    Color? aiBg,
    Color? warn,
    Color? warnBg,
    Color? ok,
    Color? okBg,
    Color? chili,
    Color? tagCuisine,
    Color? tagIngredient,
    Color? tagTaste,
    Color? tagMethod,
    Color? tagCustom,
    Color? onScrim,
  }) {
    return ZaojiTokens(
      id: id ?? this.id,
      label: label ?? this.label,
      hint: hint ?? this.hint,
      brightness: brightness ?? this.brightness,
      paper: paper ?? this.paper,
      paper2: paper2 ?? this.paper2,
      paper3: paper3 ?? this.paper3,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      tint: tint ?? this.tint,
      tint2: tint2 ?? this.tint2,
      ink: ink ?? this.ink,
      ink2: ink2 ?? this.ink2,
      muted: muted ?? this.muted,
      line: line ?? this.line,
      lineSoft: lineSoft ?? this.lineSoft,
      accent: accent ?? this.accent,
      accentDeep: accentDeep ?? this.accentDeep,
      accentSoft: accentSoft ?? this.accentSoft,
      accentSofter: accentSofter ?? this.accentSofter,
      onAccent: onAccent ?? this.onAccent,
      amber: amber ?? this.amber,
      amber2: amber2 ?? this.amber2,
      amberBg: amberBg ?? this.amberBg,
      ai: ai ?? this.ai,
      aiBg: aiBg ?? this.aiBg,
      warn: warn ?? this.warn,
      warnBg: warnBg ?? this.warnBg,
      ok: ok ?? this.ok,
      okBg: okBg ?? this.okBg,
      chili: chili ?? this.chili,
      tagCuisine: tagCuisine ?? this.tagCuisine,
      tagIngredient: tagIngredient ?? this.tagIngredient,
      tagTaste: tagTaste ?? this.tagTaste,
      tagMethod: tagMethod ?? this.tagMethod,
      tagCustom: tagCustom ?? this.tagCustom,
      onScrim: onScrim ?? this.onScrim,
    );
  }

  /// 主题切换**不做逐帧插值**：五套调色板是五种"纸"，中间态既不是这张纸
  /// 也不是那张纸，糊过去反而像 bug。所以这里原样返回自己——
  /// 换肤由外层整棵子树重建完成（见 main.dart 的 themeMode 分支）。
  @override
  ZaojiTokens lerp(ThemeExtension<ZaojiTokens>? other, double t) => this;
}

/// 便捷取法：`context.zj.paper`。
extension ZaojiTokensContext on BuildContext {
  ZaojiTokens get zj => ZaojiTokens.of(this);
}

/// 圆角。原型里定的是 6/10/14/20/26/pill 六档。
class ZaojiRadius {
  const ZaojiRadius._();

  static const double xs = 6;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 26;

  /// 药丸（原型 `--r-pill`）：过敏原标签、状态 chips 用它。
  static const double pill = 999;
}

/// 动画时长。原型的动效规范：170 / 340 / 680 ms，
/// 缓动用 `cubic-bezier(.16,1,.3,1)`——这条曲线收尾很轻，适合「纸片落下」的手感。
class ZaojiMotion {
  const ZaojiMotion._();

  static const Duration fast = Duration(milliseconds: 170);
  static const Duration base = Duration(milliseconds: 340);
  static const Duration slow = Duration(milliseconds: 680);

  static const Curve ease = Cubic(0.16, 1, 0.3, 1);
}

/// 字体族。
///
/// 字体**随产物一起打包**（`app/assets/fonts/*.woff2`，构建方式见
/// `app/tool/build_fonts.py` 与交接文档），不用系统字体，也不在运行时联网取。
///
/// 为什么必须打包：Flutter Web 的 CanvasKit 自带一套字体栈，它**不读系统字体**。
/// 文字要么来自这里声明的字体，要么由引擎的字体回退机制去
/// `https://fonts.gstatic.com/s/` 现拉——连拉丁字母的默认字体都在那张表里。
/// 而这个项目部署在家里一台**可能没有外网**的笔记本上，
/// 「运行时去 Google 拉字体」等于断网时全屏方块。
class ZaojiFonts {
  const ZaojiFonts._();

  /// 正文族。同族下声明了 Regular(400) 与 Medium(500) 两个字重，
  /// 所以 `FontWeight.w500` 会真的用到 Medium，而不是合成出来的假粗体。
  ///
  /// 子集档位是 **GBK**（22810 码点，22272 字形）——正文是最终兜底，
  /// 用户输入的菜名、食材、备注全靠它，缺一个字就是一个方块。
  static const String body = 'Noto Sans SC';

  /// 展示族：菜名、大标题。有衬线才像手账。
  static const String display = 'Noto Serif SC';

  /// 展示族的回退链。
  ///
  /// **这不是装饰，是修 bug 的。** Serif 只切到 GB2312，实测缺「藠、粿」这类
  /// 口语字；而正文族切到 GBK 是全的。少了这条链，「藠头炒腊肉」就是方块。
  static const List<String> displayFallback = <String>[body];
}

/// 文字样式工厂。
///
/// **不要在页面里手写 `fontFamily: ZaojiFonts.display`**：那样很容易只写了族名、
/// 漏掉 `fontFamilyFallback`，而漏掉的后果只在稀有汉字上出现，很难测出来。
///
/// R39 起颜色入参改成可空：不传 = 用主题的正文色（[ZaojiTokens.ink]）。
/// 之前默认值是编译期常量 `ZaojiColors.ink`，换到深色主题就是"深底上写深字"。
class ZaojiText {
  const ZaojiText._();

  /// 展示字：菜名、区块标题、计时器读数。
  static TextStyle display({
    required double fontSize,
    FontWeight fontWeight = FontWeight.w400,
    Color? color,
    double? height,
    double? letterSpacing,
    List<FontFeature>? fontFeatures,
  }) =>
      TextStyle(
        fontFamily: ZaojiFonts.display,
        fontFamilyFallback: ZaojiFonts.displayFallback,
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color ?? ZaojiTokens.fallback.ink,
        height: height,
        letterSpacing: letterSpacing,
        fontFeatures: fontFeatures,
      );

  /// 正文：步骤、说明、食材用量。
  static TextStyle body({
    required double fontSize,
    FontWeight fontWeight = FontWeight.w400,
    Color? color,
    double? height,
    double? letterSpacing,
  }) =>
      TextStyle(
        fontFamily: ZaojiFonts.body,
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color ?? ZaojiTokens.fallback.ink,
        height: height,
        letterSpacing: letterSpacing,
      );

  /// ★ 带 context 的两个版本：**页面一律用这两个**。
  ///
  /// 上面两个不带 context 的版本，`color` 不传时会落到"默认那套的墨色"——
  /// 在深色主题下就是深底压深字。真产物逐主题截图时，夜灶暖光的菜名几乎看不见
  /// 就是这个原因（`ZaojiText.display` 不传 color 的 15 处调用点）。
  /// 所以带 context 的版本把默认色改成**当前主题的 ink**，漏传 color 也不再出事。
  static TextStyle displayOf(
    BuildContext context, {
    required double fontSize,
    FontWeight fontWeight = FontWeight.w400,
    Color? color,
    double? height,
    double? letterSpacing,
    List<FontFeature>? fontFeatures,
  }) =>
      display(
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color ?? context.zj.ink,
        height: height,
        letterSpacing: letterSpacing,
        fontFeatures: fontFeatures,
      );

  static TextStyle bodyOf(
    BuildContext context, {
    required double fontSize,
    FontWeight fontWeight = FontWeight.w400,
    Color? color,
    double? height,
    double? letterSpacing,
  }) =>
      body(
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color ?? context.zj.ink,
        height: height,
        letterSpacing: letterSpacing,
      );
}

/// 用一整套令牌拼出 Material 的 [ThemeData]。
///
/// 传进来的 [tokens] 同时决定明暗：`brightness` 写错会让 Material 自带的
/// 弹层/菜单用错前景色（深色主题上弹白底白字）。
ThemeData buildZaojiTheme(ZaojiTokens tokens) {
  final scheme = ColorScheme(
    brightness: tokens.brightness,
    primary: tokens.accent,
    onPrimary: tokens.onAccent,
    secondary: tokens.amber,
    onSecondary: tokens.onAccent,
    surface: tokens.paper,
    onSurface: tokens.ink,
    error: tokens.warn,
    onError: tokens.onAccent,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: tokens.brightness,
    colorScheme: scheme,
    extensions: <ThemeExtension<dynamic>>[tokens],
    scaffoldBackgroundColor: tokens.paper,
    fontFamily: ZaojiFonts.body,
    // 注意：这里不能是 const —— ZaojiText.display 是普通静态方法，
    // 它存在的意义就是把「展示字一定要带回退链」这件事收在一处。
    appBarTheme: AppBarTheme(
      backgroundColor: tokens.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: ZaojiText.display(
        fontSize: 20,
        fontWeight: FontWeight.w500,
        color: tokens.ink,
      ),
      iconTheme: IconThemeData(color: tokens.ink),
    ),
    dividerTheme: DividerThemeData(color: tokens.lineSoft, thickness: 1),
    cardTheme: CardThemeData(
      color: tokens.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
    ),
    // 深色主题下这些"系统画的"部件（滚动条、下拉菜单、对话框底色）
    // 全靠 brightness + colorScheme 跟着翻，这里不逐个覆盖。
  );
}
