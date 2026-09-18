/// 封面插画「编号 ↔ 视觉」的注册表。
///
/// **为什么需要这一层**：schema 里 `recipe.art` / `recipe.pal` 存的是
/// `INTEGER` 编号（设计上的意图：离线封面不存图片，只存「取景编号 + 配色板编号」，
/// 视觉由客户端自己长出来）。UI 那边要的是枚举 + hex 色板，DB 那边要的是 int——
/// 两者的翻译只在这里发生一次。
///
/// **编号是持久化数据，列表只增不改**：改一个编号的顺序，等于把所有老库里的
/// 封面全换掉。新构图/新色板一律**追加到末尾**，绝不插入中间。
library;

import '../models.dart';

/// `recipe.art` 的取景编号 → 构图。顺序即编号。
const List<DishArtKind> kDishArtKinds = [
  DishArtKind.wok, // 0 炒锅
  DishArtKind.bowl, // 1 碗
  DishArtKind.plate, // 2 盘
  DishArtKind.soup, // 3 汤
  DishArtKind.bake, // 4 烤
  DishArtKind.noodle, // 5 面
  DishArtKind.board, // 6 砧板
  DishArtKind.heat, // 7 灶火
];

/// `recipe.pal` 的配色板编号 → 五色板 `[背景亮, 背景深, 主A, 主B, 主C]`。
///
/// 与高保真原型的种子调色板一一对应（见 `zaoji-prototype.html` 的 `RECIPES`）。
const List<List<String>> kPalettes = [
  ['#F2CE96', '#D9823E', '#D2491C', '#F0B429', '#4B7A3F'], // 0 柿红（番茄炒蛋）
  ['#E7B87A', '#9C5A2A', '#6B2A14', '#B5763A', '#3E6B4F'], // 1 酱色（红烧肉）
  ['#F0D6C0', '#C4795E', '#E8623F', '#F5EBD8', '#4B7A3F'], // 2 虾橙（蒜蓉粉丝蒸虾）
  ['#EBAE7E', '#B1461E', '#C9300F', '#E0A32E', '#3E6B4F'], // 3 辣红（麻婆豆腐）
  ['#EFE2CC', '#C9A57E', '#F3E6D2', '#E8C88A', '#B9A184'], // 4 甜汤（银耳莲子羹）
  ['#E9CE9A', '#B98A45', '#8A5A24', '#E8C86A', '#3E6B4F'], // 5 酱油（葱油拌面）
  ['#F5DFC0', '#D9A96E', '#E8C88A', '#FFF3E0', '#C4681F'], // 6 蛋黄（戚风蛋糕）
  ['#D8E3B8', '#7FA54E', '#5E8C36', '#A8C46A', '#F0F5E0'], // 7 菜绿（蚝油生菜）
  ['#F2CE96', '#D98F4E', '#E8623F', '#F0B429', '#4B7A3F'], // 8 暖橙（虾仁滑蛋）
];

/// 取景编号 → 构图。越界（脏数据 / 未来版本的新编号落到旧客户端）时回退到盘子——
/// 宁可画错构图也不能崩。
DishArtKind dishArtOfCode(int? code) {
  if (code == null || code < 0 || code >= kDishArtKinds.length) {
    return DishArtKind.plate;
  }
  return kDishArtKinds[code];
}

/// 色板编号 → 五色板。越界时回退到 0 号——同上，不能崩。
List<String> paletteOfCode(int? code) {
  if (code == null || code < 0 || code >= kPalettes.length) {
    return kPalettes[0];
  }
  return kPalettes[code];
}

/// 构图 → 编号（写库时用）。未知构图写 2（盘），不抛异常——
/// 封面只是装饰，不值得让一次保存因为枚举对不上而失败。
int artCodeOf(DishArtKind kind) {
  final i = kDishArtKinds.indexOf(kind);
  return i < 0 ? 2 : i;
}

/// 色板 → 编号（写库时用）。按内容比对，未知色板写 0。
int paletteCodeOf(List<String> palette) {
  final key = palette.join('|');
  for (var i = 0; i < kPalettes.length; i++) {
    if (kPalettes[i].join('|') == key) return i;
  }
  return 0;
}
