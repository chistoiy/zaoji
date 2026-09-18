import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../models.dart';

/// 菜品封面插画。
///
/// **不是自己另画一套**，而是把高保真原型（`zaoji-prototype.html` 的 `dishArt()`）
/// 的 SVG 逐字移植过来：同样的 8 种构图、同样的 5 色调色板、同样的几何与渐变。
/// 原因很直接——「高保真」的价值就在于 App 不用再猜一遍视觉，
/// 如果这里改成"画个大概意思"，主页和原型对不上的时候，没人说得清哪边是对的。
///
/// 实现方式：拼出与原型完全相同的 SVG 字符串，交给 flutter_svg 渲染。
/// 这样以后原型改了构图，这边只需要同步那一段字符串，不用重推一遍画法。
class DishArt extends StatelessWidget {
  const DishArt({super.key, required this.kind, required this.palette});

  final DishArtKind kind;

  /// `[背景亮, 背景深, 主色A, 主色B, 主色C]`，hex **带不带 # 都行**。
  final List<String> palette;

  static const String _fallbackBg1 = '#F2CE96';
  static const String _fallbackBg2 = '#D98F4E';
  static const String _fallbackA = '#D2491C';
  static const String _fallbackB = '#E8A03A';
  static const String _fallbackC = '#3E6B4F';

  String get _bg1 => _hex(palette, 0) ?? _fallbackBg1;
  String get _bg2 => _hex(palette, 1) ?? _fallbackBg2;
  String get _a => _hex(palette, 2) ?? _fallbackA;
  String get _b => _hex(palette, 3) ?? _fallbackB;
  String get _c => _hex(palette, 4) ?? _fallbackC;

  static String? _hex(List<String> p, int i) {
    if (i >= p.length) return null;
    final v = p[i].trim();
    if (v.isEmpty) return null;
    return v.startsWith('#') ? v : '#$v';
  }

  String get _svg {
    // ID 只要在**这一份文档里**唯一即可——flutter_svg 按字符串各自解析。
    const g = 'za';
    final defs = '<defs>'
        '<linearGradient id="${g}bg" x1="0" y1="0" x2=".55" y2="1">'
        '<stop offset="0" stop-color="$_bg1"/><stop offset="1" stop-color="$_bg2"/>'
        '</linearGradient>'
        '<radialGradient id="${g}gl" cx=".26" cy=".1" r=".78">'
        '<stop offset="0" stop-color="#FFF7E9" stop-opacity=".72"/>'
        '<stop offset="1" stop-color="#FFF7E9" stop-opacity="0"/></radialGradient>'
        '</defs>';

    final inner = switch (kind) {
      DishArtKind.wok => _wok,
      DishArtKind.bowl => _bowl,
      DishArtKind.plate => _plate,
      DishArtKind.soup => _soup,
      DishArtKind.bake => _bake,
      DishArtKind.noodle => _noodle,
      DishArtKind.board => _board,
      DishArtKind.heat => _heat,
    };

    return '<svg viewBox="0 0 400 300" preserveAspectRatio="xMidYMid slice" '
        'xmlns="http://www.w3.org/2000/svg">'
        '$defs'
        '<rect width="400" height="300" fill="url(#${g}bg)"/>'
        '<rect width="400" height="300" fill="$_a" opacity=".07"/>'
        '<rect width="400" height="300" fill="url(#${g}gl)"/>'
        '<g transform="translate(-16,-42) scale(1.08)">$inner</g></svg>';
  }

  String get _wok => '<rect y="214" width="400" height="86" fill="#2A1A0C" opacity=".13"/>'
      '<ellipse cx="200" cy="240" rx="152" ry="26" fill="#2A1A0C" opacity=".2"/>'
      '<ellipse cx="200" cy="198" rx="158" ry="50" fill="#241C16"/>'
      '<ellipse cx="200" cy="190" rx="146" ry="42" fill="#3A302A"/>'
      '<ellipse cx="200" cy="187" rx="136" ry="36" fill="#1F1915"/>'
      '<ellipse cx="152" cy="184" rx="54" ry="26" fill="$_a"/>'
      '<ellipse cx="250" cy="188" rx="48" ry="23" fill="$_b"/>'
      '<ellipse cx="204" cy="171" rx="44" ry="21" fill="$_c"/>'
      '<ellipse cx="196" cy="166" rx="34" ry="14" fill="#FFFFFF" opacity=".15"/>'
      '<circle cx="130" cy="171" r="6.5" fill="$_c" opacity=".9"/>'
      '<circle cx="266" cy="177" r="5.5" fill="$_c" opacity=".9"/>'
      '<circle cx="213" cy="198" r="5" fill="$_b" opacity=".8"/>'
      '<g stroke="#FFF7E9" stroke-opacity=".24" stroke-width="6" fill="none" stroke-linecap="round">'
      '<path d="M164 140c8-16 0-30 6-44"/><path d="M212 134c8-16 0-28 6-42"/>'
      '<path d="M256 142c8-14 0-26 6-38"/></g>';

  String get _bowl => '<ellipse cx="200" cy="266" rx="126" ry="20" fill="#2A1A0C" opacity=".2"/>'
      '<path d="M82 150C82 216 136 262 200 262s118-46 118-112Z" fill="#FDFAF4"/>'
      '<path d="M82 150C82 216 136 262 200 262s118-46 118-112Z" fill="none" stroke="#E2D6C4" stroke-width="2"/>'
      '<ellipse cx="200" cy="150" rx="118" ry="27" fill="#F2E8D8"/>'
      '<ellipse cx="200" cy="152" rx="104" ry="21" fill="$_a"/>'
      '<ellipse cx="176" cy="147" rx="34" ry="10" fill="#FFFFFF" opacity=".2"/>'
      '<circle cx="164" cy="146" r="13" fill="$_b"/>'
      '<circle cx="230" cy="153" r="11" fill="$_c"/>'
      '<circle cx="196" cy="159" r="9" fill="$_b" opacity=".9"/>'
      '<circle cx="250" cy="142" r="7" fill="$_c" opacity=".85"/>'
      '<path d="M100 150q100-14 200 0" fill="none" stroke="#FFF" stroke-opacity=".28" stroke-width="3"/>';

  String get _plate => '<ellipse cx="200" cy="254" rx="150" ry="24" fill="#2A1A0C" opacity=".16"/>'
      '<circle cx="200" cy="182" r="122" fill="#FDFBF7" stroke="#E7DECD" stroke-width="2"/>'
      '<circle cx="200" cy="182" r="102" fill="#F5F1E8"/>'
      '<circle cx="200" cy="182" r="102" fill="none" stroke="#E7DECD" stroke-width="1" '
      'stroke-dasharray="3 6" opacity=".75"/>'
      '<path d="M148 176q22-30 46-6 16 16-8 26-30 12-38-20Z" fill="$_c"/>'
      '<path d="M212 158q28-18 44 6 10 18-14 24-28 8-30-30Z" fill="$_b"/>'
      '<circle cx="196" cy="208" r="18" fill="$_a"/>'
      '<circle cx="234" cy="206" r="12" fill="$_c" opacity=".9"/>'
      '<circle cx="164" cy="212" r="10" fill="$_b" opacity=".9"/>'
      '<circle cx="212" cy="182" r="5" fill="#2E2620" opacity=".5"/>'
      '<circle cx="176" cy="186" r="4" fill="#2E2620" opacity=".42"/>';

  String get _soup => '<ellipse cx="200" cy="266" rx="120" ry="19" fill="#2A1A0C" opacity=".2"/>'
      '<path d="M88 146C88 212 138 258 200 258s112-46 112-112Z" fill="#FDFAF4"/>'
      '<path d="M88 146C88 212 138 258 200 258s112-46 112-112Z" fill="none" stroke="#E2D6C4" stroke-width="2"/>'
      '<ellipse cx="200" cy="146" rx="112" ry="25" fill="#F7EEDD"/>'
      '<ellipse cx="200" cy="148" rx="98" ry="19" fill="$_a"/>'
      '<path d="M126 148q20 8 40 0t40 0 40 0 34 0" fill="none" stroke="#FFF7E9" '
      'stroke-opacity=".3" stroke-width="3"/>'
      '<circle cx="168" cy="146" r="10" fill="$_c" opacity=".85"/>'
      '<circle cx="228" cy="150" r="8" fill="$_b" opacity=".85"/>'
      '<g stroke="#FFF7E9" stroke-opacity=".22" stroke-width="5" fill="none" stroke-linecap="round">'
      '<path d="M162 114c7-14 0-26 5-38"/><path d="M234 110c7-14 0-24 5-36"/></g>';

  String get _bake => '<ellipse cx="200" cy="258" rx="132" ry="22" fill="#2A1A0C" opacity=".18"/>'
      '<rect x="94" y="158" width="212" height="94" rx="14" fill="$_a"/>'
      '<rect x="94" y="158" width="212" height="94" rx="14" fill="#2A1A0C" opacity=".1"/>'
      '<ellipse cx="200" cy="158" rx="106" ry="22" fill="$_b"/>'
      '<ellipse cx="200" cy="156" rx="86" ry="14" fill="#FFF7E9" opacity=".22"/>'
      '<path d="M96 172q14 22 28 2 12 22 28 0 14 22 28 0 14 22 28 0 12 20 26-2 6-8 12-2v-14H96Z" '
      'fill="#FFF8EC" opacity=".82"/>'
      '<circle cx="150" cy="144" r="9" fill="$_c"/>'
      '<circle cx="252" cy="144" r="9" fill="$_c"/>';

  String get _noodle => '<ellipse cx="200" cy="268" rx="122" ry="20" fill="#2A1A0C" opacity=".2"/>'
      '<path d="M84 148C84 214 136 260 200 260s116-46 116-112Z" fill="#FDFAF4"/>'
      '<path d="M84 148C84 214 136 260 200 260s116-46 116-112Z" fill="none" stroke="#E2D6C4" stroke-width="2"/>'
      '<ellipse cx="200" cy="148" rx="116" ry="26" fill="#F2E8D8"/>'
      '<ellipse cx="200" cy="150" rx="102" ry="21" fill="$_a"/>'
      '<g fill="none" stroke="$_b" stroke-width="7" stroke-linecap="round">'
      '<path d="M132 152q22-18 42 0t42 0 42 0"/><path d="M136 164q22-16 42 0t42 0 40 0"/>'
      '<path d="M144 176q20-14 40 0t40 0 36 0"/></g>'
      '<circle cx="150" cy="146" r="7" fill="$_c"/><circle cx="256" cy="150" r="6" fill="$_c"/>'
      '<circle cx="204" cy="140" r="5" fill="$_c"/>';

  String get _board => '<rect y="196" width="400" height="104" fill="#2A1A0C" opacity=".1"/>'
      '<rect x="46" y="152" width="308" height="118" rx="16" fill="#C79A63"/>'
      '<rect x="46" y="152" width="308" height="118" rx="16" fill="none" stroke="#A87C46" stroke-width="2"/>'
      '<circle cx="130" cy="198" r="34" fill="$_a"/>'
      '<ellipse cx="128" cy="188" rx="20" ry="11" fill="#FFF" opacity=".15"/>'
      '<rect x="228" y="170" width="58" height="58" rx="6" fill="$_c" transform="rotate(-8 257 199)"/>'
      '<circle cx="212" cy="230" r="16" fill="$_b"/>'
      '<g stroke="#8E8274" stroke-width="3" stroke-linecap="round" opacity=".5">'
      '<path d="M206 178l34 34"/><path d="M302 178v34"/></g>';

  String get _heat => '<rect y="210" width="400" height="90" fill="#2A1A0C" opacity=".14"/>'
      '<ellipse cx="200" cy="242" rx="140" ry="26" fill="#241C16" opacity=".28"/>'
      '<ellipse cx="200" cy="202" rx="144" ry="46" fill="#2E2620"/>'
      '<ellipse cx="200" cy="195" rx="132" ry="38" fill="#1F1915"/>'
      '<ellipse cx="200" cy="193" rx="88" ry="24" fill="$_a"/>'
      '<ellipse cx="186" cy="186" rx="30" ry="10" fill="#FFF" opacity=".17"/>'
      '<path d="M150 216q10-30 24-44-6 26 8 40Z" fill="$_b" opacity=".9"/>'
      '<path d="M232 218q8-28 22-42-4 24 10 38Z" fill="$_b" opacity=".78"/>'
      '<g stroke="#FFF7E9" stroke-opacity=".22" stroke-width="5" fill="none" stroke-linecap="round">'
      '<path d="M170 130c7-14 0-26 5-38"/><path d="M238 126c7-14 0-24 5-36"/></g>';

  @override
  Widget build(BuildContext context) {
    return SvgPicture.string(_svg, fit: BoxFit.cover);
  }
}

/// 卡片封面上的暗部遮罩。原型 `.art-veil`：
/// 从底部 62% 的深棕向上渐隐——徽章文字全靠它才读得清。
class ArtVeil extends StatelessWidget {
  const ArtVeil({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          stops: [0, 0.42, 0.70],
          colors: [
            Color(0x9E18110B), // rgba(24,17,11,.62)
            Color(0x1F18110B), // rgba(24,17,11,.12)
            Color(0x0018110B), // transparent
          ],
        ),
      ),
      child: SizedBox.expand(),
    );
  }
}
