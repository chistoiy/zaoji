// R46 · 快赢包收尾：搜索框提示语要如实反映四个搜索面（FR-REC-10 菜名/食材/标签）。
// 原型两处 placeholder 本来就不一致（一处写了标签、一处没写），一起对齐；App 跟原型。
const fs = require('fs');
const path = require('path');

function patch(file, edits, snapName) {
  const p = path.resolve(__dirname, '..', file);
  const src = fs.readFileSync(p, 'utf8');
  fs.writeFileSync(path.resolve(__dirname, '../dist/' + snapName), src);
  let out = src;
  for (const [from, to] of edits) {
    const n = out.split(from).length - 1;
    if (n !== 1) throw new Error(`${file}：锚点命中 ${n} 次（应为 1）→ ${from.slice(0, 40)}`);
    out = out.replace(from, to);
  }
  if (out === src) throw new Error(`${file}：内容没变化，替换没生效`);
  fs.writeFileSync(p, out);
  console.log(`✔ ${file}：${edits.length} 处，${src.length} -> ${out.length}`);
}

patch('zaoji-prototype.html', [
  [`placeholder="搜菜名、食材，如「番茄」「虾」"`, `placeholder="搜菜名、食材、标签"`],
], 'proto_before_r46placeholder.html');

patch('app/lib/ui/recipe_list_page.dart', [
  [`                hintText: '搜菜名、食材，如「番茄」「虾」',`,
   `                hintText: '搜菜名、食材、标签',`],
], 'recipe_list_before_r46placeholder.dart');
