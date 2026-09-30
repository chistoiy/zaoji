// R47 · recipe_store：接上 KitchenPrefs（本机偏好，local_pref 一行 JSON）。
// 三处改动都用行级唯一锚点：字段、_doInit 里的加载、setter + 落库。
// ★ 加载必须挂在 _doInit 而不是只挂在 reload()——R45 那个洞就是这么来的
//   （冷启动没有增量 → 内存表恒空）。这条注释写在这里是为了下一个人不重犯。
const fs = require('fs');
const path = require('path');
const p = path.resolve(__dirname, '../app/lib/data/recipe_store.dart');
const src = fs.readFileSync(p, 'utf8');
fs.writeFileSync(path.resolve(__dirname, '../dist/recipe_store_before_r47prefs.dart'), src);
const NL = src.includes('\r\n') ? '\r\n' : '\n';
const lines = src.split(NL);

function lineWith(sub, msg) {
  const hits = lines.map((l, i) => ({ l, i })).filter(({ l }) => l.includes(sub));
  if (hits.length !== 1) throw new Error(`${msg}：命中 ${hits.length} 次，应为 1 → ${sub.slice(0, 44)}`);
  return hits[0].i;
}

// ① 字段：紧挨着 themeId 的声明放，两类本机偏好同一处读
const themeField = lineWith('String themeId = ZaojiTokens.fallback.id;', 'themeId 字段');
lines.splice(themeField + 1, 0, [
  '',
  '  /// R47 · 厨房现场偏好（FR-SET-01/02/03）：开饭前提醒与提前量、悬浮窗、震动/声音。',
  '  /// 与主题同一条立场——**只在启动时读一次**，同步增量不该改这台设备的开关。',
  '  KitchenPrefs kitchenPrefs = const KitchenPrefs();',
  '',
  '  /// 设置页与计时台都读这个 getter（越界的值当场夹回来，不把脏值交给 UI）。',
  '  int get mealLeadMinutes => kitchenPrefs.leadMinutesClamped;',
].join(NL));

// ② _doInit 里的加载：跟在 _loadTheme 之后
const loadTheme = lineWith('    await _loadTheme(db); // R39', '_loadTheme 调用');
lines.splice(loadTheme + 1, 0, [
  '    // ★ R47：本机厨房偏好同样必须在 _doInit 里读。只挂 reload() 的话，',
  '    //   冷启动没有增量时开关会全部显示默认值——用户昨天关掉的悬浮窗今天又冒出来。',
  '    await _loadKitchenPrefs(db);',
].join(NL));

// ③ setter + 落库：紧跟 _persistTheme
const persistThemeEnd = lineWith("      variables: [Variable(_themeKey), Variable(jsonEncode(themeId))],", '_persistTheme 变量行');
const closeIdx = (() => {
  for (let i = persistThemeEnd; i < lines.length; i++) {
    if (lines[i] === '  }') return i;
  }
  throw new Error('找不到 _persistTheme 结尾');
})();
lines.splice(closeIdx + 1, 0, [
  '',
  '  // ── R47 · 厨房现场偏好（FR-SET-01/02/03）──────────────────────────',
  '',
  "  static const _kitchenPrefsKey = 'kitchen_prefs';",
  '',
  '  Future<void> _loadKitchenPrefs(ZaojiDb db) async {',
  '    final cols = kLocalPrefTable.columnNames;',
  '    final rows = await db',
  '        .customSelect(',
  "          'SELECT ${cols[1]} FROM ${kLocalPrefTable.name} WHERE ${cols[0]} = ?',",
  '          variables: [Variable(_kitchenPrefsKey)],',
  '        )',
  '        .get();',
  '    if (rows.isEmpty) return;',
  '    kitchenPrefs = KitchenPrefs.decode(rows.first.data[cols[1]]) ?? kitchenPrefs;',
  '  }',
  '',
  '  /// 改厨房偏好：内存态立即生效并通知（开关要有当场反馈），落库异步。',
  '  ///',
  '  /// 与主题/收藏同款处理：写库失败不打断操作——最坏是下次启动回到旧值，',
  '  /// 而「拨了没反应」是用户当场就能感觉到的。',
  '  void setKitchenPrefs(KitchenPrefs next) {',
  '    if (next == kitchenPrefs) return;',
  '    kitchenPrefs = next;',
  '    notifyListeners();',
  '    final db = _db;',
  '    if (db == null) return;',
  '    unawaited(_persistKitchenPrefs(db).then((_) {},',
  "        onError: (Object e) => debugPrint('厨房偏好写库失败：$e'));",
  '  }',
  '',
  '  /// 只改其中一路的便捷入口（设置页每行一个开关）。',
  '  void updateKitchenPrefs(KitchenPrefs Function(KitchenPrefs) change) =>',
  '      setKitchenPrefs(change(kitchenPrefs));',
  '',
  '  Future<void> _persistKitchenPrefs(ZaojiDb db) {',
  '    final cols = kLocalPrefTable.columnNames;',
  '    return db.customInsert(',
  "      'INSERT INTO ${kLocalPrefTable.name} (${cols.join(\\', \\')}) '",
  "      'VALUES (?, ?) ON CONFLICT(${cols[0]}) DO UPDATE SET ${cols[1]} = excluded.${cols[1]}',",
  '      variables: [',
  '        Variable(_kitchenPrefsKey),',
  '        Variable(jsonEncode(kitchenPrefs.toJson())),',
  '      ],',
  '    );',
  '  }',
].join(NL));

const out = lines.join(NL);
if (out.length <= src.length) throw new Error('体积没增长');
fs.writeFileSync(p, out);
console.log('✔ recipe_store 接上 KitchenPrefs：' + src.length + ' -> ' + out.length);
