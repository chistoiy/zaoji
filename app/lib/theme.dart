import 'package:flutter/material.dart';

/// 灶记的设计令牌。
///
/// **这些值不是随便定的**：原型（`zaoji-prototype.html`）与需求说明书里已经定死，
/// 客户端只负责实现，不要在页面里另写颜色字面量——否则改一次主色要翻遍所有文件。
///
/// 概念是「灶台边的厨房手账」：暖纸底、墨色字、**唯一强调色是柿红**。
/// 强调色唯一这条很关键：当页面上只有一个东西是红的，用户一眼就知道该点哪儿。
class ZaojiColors {
  const ZaojiColors._();

  /// 暖纸。整个 App 的底色。
  static const paper = Color(0xFFFBF6EC);

  /// 次级纸面：卡片、输入框、分组底。
  static const paper2 = Color(0xFFF4EDE0);

  /// 墨。正文颜色。
  static const ink = Color(0xFF231C15);

  /// 次级墨：描述、辅助信息。
  static const ink2 = Color(0xFF4A3F33);

  /// 弱化文字：时间戳、单位、提示。
  static const muted = Color(0xFF8A7D6C);

  /// **唯一强调色：柿红。** 一处页面上只应出现一次。
  static const accent = Color(0xFFD2491C);

  /// 时间胶囊的琥珀。做菜时「可以点起计时」的东西都用它。
  static const amber = Color(0xFFB8801A);
  static const amberBg = Color(0xFFFBF0DA);

  /// AI 相关的功能区隔色。与柿红刻意拉开，避免和「主操作」混淆。
  static const ai = Color(0xFF6E4468);
  static const aiBg = Color(0xFFF2EAF1);

  /// 分隔线。
  static const line = Color(0xFFE3D9C8);
  static const lineSoft = Color(0xFFEDE4D5);

  /// 过敏原警示。**不单独依赖颜色**——配图标与文字，见 allergen 相关组件。
  static const warn = Color(0xFF8C2F1A);
  static const warnBg = Color(0xFFFBE7DE);

  /// 难度辣椒。刻意比柿红暗一档：
  /// 「唯一强调色」这条规矩的意思是**一屏之内只有一个东西是纯柿红**，
  /// 那个位置留给主操作按钮。难度刻度是一片纹理，不该跟它抢。
  static const chili = Color(0xFFB5532A);

  /// ── 标签组颜色（与原型 `--t-*` 一一对应）──
  /// **这不是随手挑的**：五组标签各占一个色相，用户靠颜色区分
  /// 「这是菜系还是口味」。改任何一个都要五个一起看。
  static const tagCuisine = Color(0xFFA83C22); // 菜系
  static const tagIngredient = Color(0xFF37634A); // 食材
  static const tagTaste = Color(0xFF6F4269); // 口味
  static const tagMethod = Color(0xFF2A5F6B); // 操作方式
  static const tagCustom = Color(0xFF836127); // 自定义
}

/// 圆角。原型里定的是 6/10/14/20/26/pill 六档。
class ZaojiRadius {
  const ZaojiRadius._();

  static const double xs = 6;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 26;
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
  /// 实测它覆盖了 117 个高频烹饪用字的 **117 个**。
  static const String body = 'Noto Sans SC';

  /// 展示族：菜名、大标题。有衬线才像手账。
  ///
  /// 子集档位只到 **GB2312**（7996 字形）——它只负责标题，且挂了回退链，
  /// 缺字会落到 [body]。这样省下约 4 MB。
  static const String display = 'Noto Serif SC';

  /// 展示族的回退链。
  ///
  /// **这不是装饰，是修 bug 的。** Serif 只切到 GB2312，实测缺「藠、粿」这类
  /// 口语字（藠头、粿条）；而正文族切到 GBK 是全的。少了这条链，
  /// 「藠头炒腊肉」这种菜名会变成方块——而且只有用户真输入那个字才暴露。
  static const List<String> displayFallback = <String>[body];
}

/// 文字样式工厂。
///
/// **不要在页面里手写 `fontFamily: ZaojiFonts.display`**：那样很容易只写了族名、
/// 漏掉 `fontFamilyFallback`，而漏掉的后果只在稀有汉字上出现，很难测出来。
/// 展示字一律走 [ZaojiText.display]，回退链就不可能漏。
class ZaojiText {
  const ZaojiText._();

  /// 展示字：菜名、区块标题、计时器读数。
  static TextStyle display({
    required double fontSize,
    FontWeight fontWeight = FontWeight.w400,
    Color color = ZaojiColors.ink,
    double? height,
    double? letterSpacing,
    List<FontFeature>? fontFeatures,
  }) =>
      TextStyle(
        fontFamily: ZaojiFonts.display,
        fontFamilyFallback: ZaojiFonts.displayFallback,
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
        fontFeatures: fontFeatures,
      );

  /// 正文：步骤、说明、食材用量。
  static TextStyle body({
    required double fontSize,
    FontWeight fontWeight = FontWeight.w400,
    Color color = ZaojiColors.ink,
    double? height,
    double? letterSpacing,
  }) =>
      TextStyle(
        fontFamily: ZaojiFonts.body,
        fontSize: fontSize,
        fontWeight: fontWeight,
        color: color,
        height: height,
        letterSpacing: letterSpacing,
      );
}

ThemeData buildZaojiTheme() {
  const scheme = ColorScheme.light(
    primary: ZaojiColors.accent,
    onPrimary: Colors.white,
    secondary: ZaojiColors.amber,
    surface: ZaojiColors.paper,
    onSurface: ZaojiColors.ink,
    error: ZaojiColors.warn,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: ZaojiColors.paper,
    fontFamily: ZaojiFonts.body,
    // 注意：这里不能是 const —— ZaojiText.display 是普通静态方法，
    // 它存在的意义就是把「展示字一定要带回退链」这件事收在一处。
    appBarTheme: AppBarTheme(
      backgroundColor: ZaojiColors.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: ZaojiText.display(
        fontSize: 20,
        fontWeight: FontWeight.w500,
      ),
      iconTheme: IconThemeData(color: ZaojiColors.ink),
    ),
    dividerTheme: const DividerThemeData(color: ZaojiColors.lineSoft, thickness: 1),
    cardTheme: const CardThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
    ),
  );
}
