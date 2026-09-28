import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zaoji/data/recipe_store.dart';
import 'package:zaoji/data/zaoji_db.dart';

/// R41 · Web 端「事务写完活不过刷新」的连接层补丁。
///
/// 现场取证（`tool/web_write_loss_probe.cjs`，读数记在交接文档 §六-12①）钉死的事实：
/// drift 的 `sharedIndexedDb` 存储实现只在**非事务语句**上把脏页写回 IndexedDB，
/// `db.transaction` 提交完并不冲盘——界面立刻看得到（共 9 道 → 10 道），
/// 但 IDB 的块 6 秒内一格没动，刷新、乃至整个浏览器重启都回到 9 道，那一笔从没落过盘。
/// 事务之后再补一记单条写（点收藏），事务的那些块就跟着下盘了 —— 补丁就是这么来的。
///
/// **这个文件测的是接线，不是浏览器行为**：真产物上的落盘由那颗探针断言。
/// 接线最容易错的三处：嵌套事务里白补一次、原生端多写一行垃圾、事务返回值被吞。
void main() {
  late ZaojiDb db;

  setUp(() {
    ZaojiDb.forceFlushAfterTransaction = false;
    db = ZaojiDb(NativeDatabase.memory());
  });
  tearDown(() async {
    await db.close();
    ZaojiDb.forceFlushAfterTransaction = false;
  });

  Future<String?> readTick() async {
    final rows = await db.customSelect(
      'SELECT pref_value FROM local_pref WHERE pref_key = ?',
      variables: [Variable(ZaojiDb.kWebFlushTickKey)],
    ).get();
    if (rows.isEmpty) return null;
    return '${rows.single.data['pref_value']}';
  }

  Future<int> prefRows() async {
    final r = await db
        .customSelect('SELECT COUNT(*) AS c FROM local_pref')
        .getSingle();
    return r.read<int>('c');
  }

  /// recipe 的 name / updated_at / updated_by 是 NOT NULL，随手 INSERT 会撞约束。
  Future<void> insertRecipe(ZaojiDb d, String id) => d.customStatement(
      "INSERT INTO recipe (id, name, updated_at, updated_by) "
      "VALUES (?, '测试菜', 'hlc:1', 'dev')",
      [id]);

  test('开了补写：事务提交后 local_pref 里出现心跳键', () async {
    ZaojiDb.forceFlushAfterTransaction = true;
    await db.transaction(() => insertRecipe(db, 't1'));
    expect(await readTick(), isNotNull,
        reason: '事务后必须紧跟一记自动提交的写入，否则攒着的脏页永远不下盘');
  });

  test('每笔最外层事务补一次，心跳递增', () async {
    ZaojiDb.forceFlushAfterTransaction = true;
    await db.transaction(() => insertRecipe(db, 'a'));
    final first = int.parse((await readTick())!.replaceAll('"', ''));
    await db.transaction(() => insertRecipe(db, 'b'));
    final second = int.parse((await readTick())!.replaceAll('"', ''));
    expect(second, greaterThan(first),
        reason: '第二笔事务也得补一次；心跳值只是逼一记写的载体，递增即可');
  });

  test('嵌套事务只在最外层补一次', () async {
    ZaojiDb.forceFlushAfterTransaction = true;
    final before = await prefRows();
    await db.transaction(() async {
      await db.transaction(() => insertRecipe(db, 'outer'));
    });
    expect(await prefRows(), before + 1,
        reason: '内层那次还在事务里，补了也冲不下去，只是白写一行');
  });

  test('事务抛异常照样补：回滚后的库也得落盘', () async {
    ZaojiDb.forceFlushAfterTransaction = true;
    await expectLater(
      db.transaction(() async {
        await insertRecipe(db, 'boom');
        throw StateError('故意失败');
      }),
      throwsStateError,
      reason: '补丁不能把业务异常吞掉——吞了界面就显示"保存成功"',
    );
    expect(await readTick(), isNotNull);
  });

  test('事务的返回值原样透传（详情页/列表都靠它拿新数据）', () async {
    ZaojiDb.forceFlushAfterTransaction = true;
    final out = await db.transaction(() async {
      await insertRecipe(db, 'ret');
      return 42;
    });
    expect(out, 42);
  });

  test('默认不补：VM 上 local_pref 一行垃圾都不多', () async {
    // 这台设备上 kIsWeb=false，走的就是原生 sqlite 那条不需要逼写的路
    final before = await prefRows();
    await db.transaction(() => insertRecipe(db, 'native'));
    expect(await prefRows(), before);
    expect(await readTick(), isNull);
  });

  test('补写不搅动既有偏好：整条 store 启动链照常跑', () async {
    ZaojiDb.forceFlushAfterTransaction = true;
    final store = RecipeStore(executor: NativeDatabase.memory());
    await store.ready();
    expect(store.recipes.length, greaterThan(0));
    final id = store.recipes.first.id;
    // 示例菜里本来就带收藏（isFav 的种子里有True），所以断言按翻转来写而不是"变已收藏"
    final before = store.isFav(id);
    store.toggleFav(id);
    expect(store.isFav(id), isNot(before),
        reason: '心跳键与收藏同表不同键，读偏好的那几处按具体键取，不该被多出来的键带偏');
    store.dispose();
  });
}
