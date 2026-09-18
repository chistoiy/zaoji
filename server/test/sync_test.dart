import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zaoji_server/src/db.dart';
import 'package:zaoji_server/src/sqlite_loader.dart';
import 'package:zaoji_server/src/sync.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// 同步服务的测试。
///
/// 三条主线：**配对**（能不能连上）、**鉴权**（谁能连）、
/// **拉取与推送**（连上之后数据的正确性）。
///
/// 这一层最容易出的事都不是崩溃，而是**安静地做错**：
/// 漏了一列、多了一列、重放做两遍、冲突被静默覆盖。
/// 所以断言写得比较死——列必须严格相等，而不是"包含"。
void main() {
  setUpAll(loadSqlite);

  late Directory tmp;
  late ZaojiDb db;
  late SyncService sync;
  late DateTime fakeNow;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zaoji_sync');
    db = ZaojiDb.open('${tmp.path}${Platform.pathSeparator}zaoji.db');
    fakeNow = DateTime(2026, 9, 18, 9, 0, 0);
    // 固定时钟：配对码有 5 分钟有效期，不注入时间就没法测过期
    sync = SyncService(db, 'server-node', now: () => fakeNow);
  });
  tearDown(() {
    db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 走一遍完整配对，返回能用的设备。
  Device pairDevice({String id = 'phone-1', String name = '我的手机'}) {
    final code = sync.issuePairCode();
    final out = sync.redeem(code: code.code, deviceId: id, deviceName: name);
    expect(out.ok, isTrue, reason: out.failure?.message);
    final d = sync.authenticate('Bearer ${out.token}');
    expect(d, isNotNull, reason: '刚配对的 token 就应该能用');
    return d!;
  }

  /// 构造一份完整合法的 recipe 行。
  /// 列名与 `syncWhitelist['recipe']` 严格一致——有测试盯着这一点。
  Map<String, Object?> recipeRow({
    required String id,
    required String name,
    String hlc = 'h-1',
    String by = 'phone-1',
    int rev = 1,
    String? notes,
    String? deletedAt,
  }) =>
      {
        'id': id,
        'updated_at': hlc,
        'updated_by': by,
        'rev': rev,
        'deleted_at': deletedAt,
        'name': name,
        'sub': null,
        'art': null,
        'pal': null,
        'difficulty': 1,
        'self_time': null,
        'cooked_count': 0,
        'servings': 2,
        'notes': notes,
        'tags': null,
        'source': 'manual',
        'source_model': null,
        'source_at': null,
        'last_cooked_at': null,
        'cover_sha256': null,
      };

  Map<String, Object?> upsert(String tbl, Map<String, Object?> row, {Map<String, Object?>? base}) =>
      {'tbl': tbl, 'rowId': row['id'], 'op': 'upsert', 'row': row, if (base != null) 'base': base};

  Map<String, Object?>? rowOf(String id) {
    final rs = db.db.select('SELECT * FROM recipe WHERE id = ?', [id]);
    return rs.isEmpty ? null : rs.first;
  }

  // ══════════════════════ 配对 ══════════════════════

  group('配对码', () {
    test('生成 6 位，且不含容易抄错的字符', () {
      for (var i = 0; i < 30; i++) {
        final c = sync.issuePairCode();
        expect(c.code, hasLength(6));
        // 0/O、1/I/L 是抄写错误的主要来源，字母表里必须没有它们
        expect(RegExp(r'^[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{6}$').hasMatch(c.code), isTrue,
            reason: '出现了不该有的字符：${c.code}');
        expect(c.expiresAt.difference(c.createdAt), SyncService.pairCodeTtl);
      }
    });

    test('配对成功，拿到的 token 立刻可用', () {
      final code = sync.issuePairCode();
      final out = sync.redeem(code: code.code, deviceId: 'phone-1', deviceName: '我的手机');

      expect(out.ok, isTrue);
      expect(out.token, isNotEmpty);
      expect(out.deviceId, 'phone-1');
      expect(out.serverId, 'server-node');
      expect(out.protocolVersion, kSyncProtocolVersion);
      expect(sync.authenticate('Bearer ${out.token}')?.id, 'phone-1');
    });

    test('配对码大小写不敏感、首尾空格可忽略', () {
      final code = sync.issuePairCode();
      final out = sync.redeem(
        code: '  ${code.code.toLowerCase()}  ',
        deviceId: 'phone-1',
        deviceName: 'x',
      );
      expect(out.ok, isTrue, reason: '用户在手机上照着输，大小写不该成为门槛');
    });

    test('★ token 不落明文（库被看到也换不回 token）', () {
      final code = sync.issuePairCode();
      final token = sync.redeem(code: code.code, deviceId: 'phone-1', deviceName: 'x').token!;

      final stored = db.db.select('SELECT token_hash FROM device').first['token_hash'] as String;
      expect(stored, isNot(token));
      expect(stored, SyncService.hashToken(token));
      expect(stored, hasLength(64)); // sha256 hex
    });

    test('码错 / 过期 / 用过，三种失败要能分开', () {
      expect(sync.redeem(code: 'ZZZZZZ', deviceId: 'd', deviceName: 'x').failure,
          PairFailure.unknownCode);
      expect(sync.redeem(code: '   ', deviceId: 'd', deviceName: 'x').failure,
          PairFailure.emptyCode);
      expect(sync.redeem(code: 'ABCDEF', deviceId: '', deviceName: 'x').failure,
          PairFailure.missingDeviceId);

      final code = sync.issuePairCode();
      sync.redeem(code: code.code, deviceId: 'd1', deviceName: 'x');
      expect(sync.redeem(code: code.code, deviceId: 'd2', deviceName: 'y').failure,
          PairFailure.codeAlreadyUsed);

      final code2 = sync.issuePairCode();
      fakeNow = fakeNow.add(SyncService.pairCodeTtl).add(const Duration(seconds: 1));
      expect(sync.redeem(code: code2.code, deviceId: 'd', deviceName: 'x').failure,
          PairFailure.codeExpired);
    });

    test('每种失败都有给人看的话，且不是同一句', () {
      final msgs = PairFailure.values.map((f) => f.message).toSet();
      expect(msgs, hasLength(PairFailure.values.length));
      for (final m in msgs) {
        expect(m, isNotEmpty);
      }
    });

    test('同一设备重新配对会换新 token（旧的作废）', () {
      final c1 = sync.issuePairCode();
      final t1 = sync.redeem(code: c1.code, deviceId: 'phone-1', deviceName: '旧名').token!;

      final c2 = sync.issuePairCode();
      final t2 = sync.redeem(code: c2.code, deviceId: 'phone-1', deviceName: '新名').token!;

      expect(t2, isNot(t1));
      expect(sync.authenticate('Bearer $t1'), isNull, reason: '旧 token 应当失效');
      expect(sync.authenticate('Bearer $t2')?.name, '新名');
      expect(sync.devices(), hasLength(1), reason: '同一台设备不该出现两行');
    });

    test('设备表里记下配对时间与最后活动时间', () {
      final d = pairDevice();
      final rs = db.db.select('SELECT paired_at, last_seen_at FROM device WHERE id = ?', [d.id]);
      expect('${rs.first['paired_at']}', isNotEmpty);
      expect('${rs.first['last_seen_at']}', isNotEmpty, reason: 'authenticate 会顺手更新它');
    });
  });

  // ══════════════════════ 鉴权 ══════════════════════

  group('鉴权', () {
    test('缺 token / 格式不对 / token 错，一律认不出', () {
      final d = pairDevice();

      expect(sync.authenticate(null), isNull);
      expect(sync.authenticate(''), isNull);
      expect(sync.authenticate('Bearer'), isNull);
      expect(sync.authenticate('Bearer '), isNull);
      expect(sync.authenticate('Basic abc'), isNull);
      expect(sync.authenticate('Bearer 乱码'), isNull);
      // 拿别人的哈希当 token 也不行
      final hash = db.db.select('SELECT token_hash FROM device WHERE id = ?', [d.id]).first['token_hash'];
      expect(sync.authenticate('Bearer $hash'), isNull);
    });

    test('scheme 大小写不敏感（Bearer / bearer 都行）', () {
      final code = sync.issuePairCode();
      final token = sync.redeem(code: code.code, deviceId: 'p', deviceName: 'x').token!;
      expect(sync.authenticate('bearer $token'), isNotNull);
    });

    test('被吊销的设备进不来', () {
      final d = pairDevice();
      final code = sync.issuePairCode();
      final token = sync.redeem(code: code.code, deviceId: d.id, deviceName: 'x').token!;
      db.db.execute('UPDATE device SET revoked_at = ? WHERE id = ?', ['2026-01-01', d.id]);
      expect(sync.authenticate('Bearer $token'), isNull);
    });
  });

  // ══════════════════════ 拉取 ══════════════════════

  group('拉取', () {
    test('空库：0 条，游标也是 0', () {
      final r = sync.pull(since: 0);
      expect(r.changes, isEmpty);
      expect(r.nowSeq, 0);
      expect(r.lastSeq, 0);
      expect(r.hasMore, isFalse);
      expect(r.protocolVersion, kSyncProtocolVersion);
      expect(r.serverId, 'server-node');
    });

    test('★ 每一行的载荷，列必须严格等于同步白名单', () {
      final d = pairDevice();
      sync.push(device: d, mutationId: 'm1', changes: [upsert('recipe', recipeRow(id: 'r1', name: '番茄炒蛋'))]);

      final r = sync.pull(since: 0);
      expect(r.changes, hasLength(1));

      final c = r.changes.single;
      expect(c['tbl'], 'recipe');
      expect(c['rowId'], 'r1');
      expect(c['op'], 'upsert');
      expect((c['row'] as Map).keys.toSet(), syncWhitelist['recipe']!.toSet(),
          reason: '多一列会漏数据，少一列客户端落不了库');
    });

    test('★★ 本机私有表永远不会被下发（AI Key 就在那张表里）', () {
      // 直接往库里塞一行 AI 配置，并且——故意——给它记一条变更日志，
      // 模拟"将来某处不小心把 ai_config 也 logChange 了"。
      db.db.execute(
        'INSERT INTO ai_config (id, enabled, api_key_enc, flags, saved_at) '
        "VALUES ('singleton', 1, 'sk-secret-abcdefg', '{}', '2026-09-18T00:00:00')",
      );
      db.logChange(
        tbl: 'ai_config', rowId: 'singleton', op: 'upsert',
        rowUpdatedAt: 'h', rowUpdatedBy: 'server-node',
      );

      final r = sync.pull(since: 0);
      final json = jsonEncode(r.toJson());

      // 整条都不该下发：客户端连"有这么一张表"都不该知道
      expect(r.changes, isEmpty);
      expect(json, isNot(contains('ai_config')));
      expect(json, isNot(contains('sk-secret')));
      expect(json, isNot(contains('api_key')));
      expect(json, isNot(contains('singleton')));

      // 但游标要推进过去，否则客户端会卡在这里反复拉同一批
      expect(r.lastSeq, 1, reason: '被跳过的条目也要算进游标');
      expect(sync.pull(since: r.lastSeq).changes, isEmpty);
    });

    test('非白名单表在白名单里查不到（结构层面就查不到）', () {
      expect(syncWhitelist['ai_config'], isNull);
      expect(syncWhitelist['ai_usage'], isNull);
      expect(syncWhitelist['ai_cache'], isNull);
      expect(syncWhitelist['change_log'], isNull);
      expect(syncWhitelist['device'], isNull);
    });

    test('按游标拉：since 之后才给，且能分页', () {
      final d = pairDevice();
      sync.push(device: d, mutationId: 'm', changes: [
        for (var i = 0; i < 5; i++) upsert('recipe', recipeRow(id: 'r$i', name: '菜$i')),
      ]);

      final page1 = sync.pull(since: 0, limit: 2);
      expect(page1.changes.map((c) => c['seq']), [1, 2]);
      expect(page1.hasMore, isTrue);
      expect(page1.nowSeq, 5);

      final page2 = sync.pull(since: page1.lastSeq, limit: 2);
      expect(page2.changes.map((c) => c['seq']), [3, 4]);
      expect(page2.hasMore, isTrue);

      final page3 = sync.pull(since: page2.lastSeq, limit: 2);
      expect(page3.changes.map((c) => c['seq']), [5]);
      expect(page3.hasMore, isFalse);

      expect(sync.pull(since: 5).changes, isEmpty);
      expect(sync.pull(since: 5).hasMore, isFalse);
    });

    test('软删除的行仍然带载荷（客户端要拿到墓碑），op 标记为 delete', () {
      final d = pairDevice();
      sync.push(device: d, mutationId: 'a', changes: [upsert('recipe', recipeRow(id: 'r1', name: 'X'))]);
      sync.push(device: d, mutationId: 'b', changes: [
        {'tbl': 'recipe', 'rowId': 'r1', 'op': 'delete', 'row': recipeRow(id: 'r1', name: 'X')},
      ]);

      final r = sync.pull(since: 0);
      expect(r.changes, hasLength(2));
      final del = r.changes.last;
      expect(del['op'], 'delete');
      expect(del.containsKey('row'), isTrue, reason: '软删除的行还在，载荷要给出去');
      expect((del['row'] as Map)['deleted_at'], isNotNull);
    });

    test('noteCursor 只往上走，不会把游标写回去', () {
      final d = pairDevice();
      sync.noteCursor(d.id, 10);
      sync.noteCursor(d.id, 3); // 迟到的旧请求
      expect(sync.devices().single.syncCursor, 10);
    });
  });

  // ══════════════════════ 推送 ══════════════════════

  group('推送', () {
    test('新行插得进去，并留下变更日志', () {
      final d = pairDevice();
      final r = sync.push(device: d, mutationId: 'm1', changes: [
        upsert('recipe', recipeRow(id: 'r1', name: '番茄炒蛋')),
      ]);

      expect(r.ok, isTrue);
      expect(r.replayed, isFalse);
      expect(r.appliedCount, 1);
      expect(r.results.single['outcome'], 'inserted');
      expect(r.results.single['seq'], 1);

      final row = rowOf('r1')!;
      expect(row['name'], '番茄炒蛋');
      expect(row['rev'], 1);
      // 服务端盖章：updated_at 必须是能解析的 HLC，而不是客户端随便给的一串
      expect(Hlc.tryDecode('${row['updated_at']}'), isNotNull);
      expect(row['updated_by'], 'phone-1', reason: '要记"谁促成的"');
      expect(db.maxSeq, 1);
    });

    test('★★ 同一个 mutationId 重放：返回上次的结果，不重做', () {
      final d = pairDevice();
      final changes = [upsert('recipe', recipeRow(id: 'r1', name: '第一次'))];

      final first = sync.push(device: d, mutationId: 'm1', changes: changes);
      expect(first.replayed, isFalse);
      expect(db.maxSeq, 1);

      // 客户端超时没收到响应，于是重试完全一样的批次
      final again = sync.push(device: d, mutationId: 'm1', changes: changes);

      expect(again.replayed, isTrue, reason: '客户端要能知道"上次其实成功了"');
      expect(again.results, first.results, reason: '结果必须一模一样');
      expect(db.maxSeq, 1, reason: '★ 不能产生第二条变更日志，否则别的设备会收到重复变更');
      expect(rowOf('r1')!['name'], '第一次');
    });

    test('mutationId 为空直接拒绝（没有它就没有幂等）', () {
      final d = pairDevice();
      final r = sync.push(device: d, mutationId: '  ', changes: []);
      expect(r.ok, isFalse);
      expect(r.error, contains('mutationId'));
    });

    test('★ 未知表被拒（客户端比服务端新时会遇到）', () {
      final d = pairDevice();
      final r = sync.push(device: d, mutationId: 'm', changes: [
        {'tbl': 'recipe_v2', 'rowId': 'r1', 'op': 'upsert', 'row': {'id': 'r1'}},
        {'tbl': 'ai_config', 'rowId': 'singleton', 'op': 'upsert', 'row': {'id': 'singleton'}},
      ]);
      expect(r.results[0]['outcome'], 'rejected');
      expect(r.results[0]['reason'], contains('recipe_v2'));
      expect(r.results[1]['outcome'], 'rejected');
      expect(r.results[1]['reason'], contains('ai_config'));
    });

    test('★ 来件里多出未登记的列 → 整条拒绝（挡住不小心外发的字段）', () {
      final d = pairDevice();
      final row = recipeRow(id: 'r1', name: 'X')..['api_key_enc'] = 'sk-leak';
      final r = sync.push(device: d, mutationId: 'm', changes: [upsert('recipe', row)]);

      expect(r.results.single['outcome'], 'rejected');
      expect(r.results.single['reason'], contains('api_key_enc'));
      expect(rowOf('r1'), isNull, reason: '被拒绝的条目不该写进库');
    });

    test('缺 id 被拒', () {
      final d = pairDevice();
      final r = sync.push(device: d, mutationId: 'm', changes: [
        {'tbl': 'recipe', 'op': 'upsert', 'row': {'name': '没有 id'}},
      ]);
      expect(r.results.single['outcome'], 'rejected');
      expect(r.results.single['reason'], contains('id'));
    });

    test('★★ upsert 必须带完整行（缺列会静默清空字段，所以直接拒绝）', () {
      // 容忍缺列的代价是：更新时把客户端没提到的字段清成 null，
      // 而且冲突判定里"未提供"与"改成 null"长得一模一样。
      // 所以宁可直接拒绝，并明确列出缺了哪些列。
      final d = pairDevice();
      final partial = recipeRow(id: 'r1', name: 'X')
        ..remove('notes')
        ..remove('servings');

      final r = sync.push(device: d, mutationId: 'm', changes: [upsert('recipe', partial)]);

      expect(r.results.single['outcome'], 'rejected');
      expect(r.results.single['reason'], contains('完整行'));
      expect(r.results.single['reason'], contains('notes'));
      expect(r.results.single['reason'], contains('servings'));
      expect(rowOf('r1'), isNull);
    });

    test('★ 被数据库拒绝的条目逐条报告，不带走整批', () {
      // difficulty 是 NOT NULL。给 null 应当只让这一条失败，
      // 同批里好的那条照常写入 —— 否则客户端只要有一条脏数据就永远推不上去。
      final d = pairDevice();
      final bad = recipeRow(id: 'bad', name: 'X')..['difficulty'] = null;
      final r = sync.push(device: d, mutationId: 'm', changes: [
        upsert('recipe', bad),
        upsert('recipe', recipeRow(id: 'good', name: '好的')),
      ]);

      expect(r.results[0]['outcome'], 'rejected');
      expect(r.results[0]['reason'], contains('数据库拒绝'));
      expect(r.results[1]['outcome'], 'inserted');
      expect(rowOf('good'), isNotNull, reason: '好的那条必须写进去');
      expect(rowOf('bad'), isNull);
    });

    test('一批里有一条坏的，其余照常应用（并且逐条报告）', () {
      // 这是刻意的语义：坏条目单独报告，不让整批陪着失败——
      // 否则客户端只要有一条脏数据就永远推不上去。
      final d = pairDevice();
      final r = sync.push(device: d, mutationId: 'm', changes: [
        upsert('recipe', recipeRow(id: 'r1', name: '好的')),
        {'tbl': '没有这张表', 'rowId': 'x', 'op': 'upsert', 'row': {'id': 'x'}},
        upsert('recipe', recipeRow(id: 'r2', name: '也是好的')),
      ]);

      expect(r.results.map((x) => x['outcome']), ['inserted', 'rejected', 'inserted']);
      expect(rowOf('r1'), isNotNull);
      expect(rowOf('r2'), isNotNull);
      expect(db.maxSeq, 2, reason: '只有真正写入的两条产生变更');
    });

    test('删除是软删除：写墓碑、推进 HLC、rev+1，并记一条 delete', () {
      final d = pairDevice();
      sync.push(device: d, mutationId: 'a', changes: [upsert('recipe', recipeRow(id: 'r1', name: 'X'))]);
      final before = rowOf('r1')!;

      final r = sync.push(device: d, mutationId: 'b', changes: [
        {'tbl': 'recipe', 'rowId': 'r1', 'op': 'delete', 'row': recipeRow(id: 'r1', name: 'X')},
      ]);

      expect(r.results.single['outcome'], 'deleted');
      final after = rowOf('r1')!;
      expect(after['deleted_at'], isNotNull);
      expect(after['rev'], (before['rev'] as int) + 1);
      expect('${after['updated_at']}'.compareTo('${before['updated_at']}') > 0, isTrue,
          reason: 'HLC 字典序 == 时间序，新的一定更大');
      expect(db.changesSince(1).single.op, 'delete');
    });

    test('删一个不存在 / 已删的行 → skipped，不产生变更', () {
      final d = pairDevice();
      var r = sync.push(device: d, mutationId: 'a', changes: [
        {'tbl': 'recipe', 'rowId': '不存在', 'op': 'delete', 'row': recipeRow(id: '不存在', name: 'x')},
      ]);
      expect(r.results.single['outcome'], 'skipped');
      expect(db.maxSeq, 0);

      sync.push(device: d, mutationId: 'b', changes: [upsert('recipe', recipeRow(id: 'r1', name: 'X'))]);
      sync.push(device: d, mutationId: 'c', changes: [
        {'tbl': 'recipe', 'rowId': 'r1', 'op': 'delete', 'row': recipeRow(id: 'r1', name: 'X')},
      ]);
      r = sync.push(device: d, mutationId: 'd', changes: [
        {'tbl': 'recipe', 'rowId': 'r1', 'op': 'delete', 'row': recipeRow(id: 'r1', name: 'X')},
      ]);
      expect(r.results.single['outcome'], 'skipped');
      expect(r.results.single['reason'], contains('删除态'));
    });

    test('完全相同的内容 → skipped', () {
      final d = pairDevice();
      final row = recipeRow(id: 'r1', name: 'X', hlc: 'same');
      sync.push(device: d, mutationId: 'a', changes: [upsert('recipe', row)]);
      final r = sync.push(device: d, mutationId: 'b', changes: [upsert('recipe', row)]);

      expect(r.results.single['outcome'], 'skipped');
      expect(db.maxSeq, 1);
    });
  });

  // ══════════════════════ 冲突 ══════════════════════

  group('冲突（这一节是项目的灵魂，别静默覆盖）', () {
    test('★ 两边改同一字段 → 写冲突箱，让用户选', () {
      final d = pairDevice();
      // 服务端已有：name = 服务端改的
      sync.push(device: d, mutationId: 'a', changes: [
        upsert('recipe', recipeRow(id: 'r1', name: '服务端改的', hlc: 'h-2')),
      ]);

      // 客户端基于更早的版本，也改了 name
      final r = sync.push(device: d, mutationId: 'b', changes: [
        upsert(
          'recipe',
          recipeRow(id: 'r1', name: '客户端改的', hlc: 'h-3'),
          base: recipeRow(id: 'r1', name: '原本的', hlc: 'h-1'),
        ),
      ]);

      expect(r.results.single['outcome'], 'conflict');
      expect(r.results.single['conflictingFields'], ['name']);

      final tickets = db.db.select('SELECT * FROM conflict_item WHERE row_id = ?', ['r1']);
      expect(tickets, hasLength(1), reason: '一行一字段一条记录，用户要能逐字段裁决');
      expect(tickets.first['field'], 'name');
      expect(tickets.first['local_value'], '服务端改的');
      expect(tickets.first['remote_value'], '客户端改的');
      expect(tickets.first['resolved_at'], isNull, reason: '待用户处理');
      expect(tickets.first['local_by'], isNotNull);
      expect(tickets.first['remote_by'], 'phone-1');
    });

    test('★ 两边改不同字段 → 自动合并，不打扰用户', () {
      // 这条是产品判断：A 改了耗时、B 改了注意事项，这是协作不是冲突。
      final d = pairDevice();
      sync.push(device: d, mutationId: 'a', changes: [
        upsert('recipe', recipeRow(id: 'r1', name: '服务端改的', notes: '原始注意', hlc: 'h-2')),
      ]);

      final r = sync.push(device: d, mutationId: 'b', changes: [
        upsert(
          'recipe',
          recipeRow(id: 'r1', name: '原本的', notes: '客户端补的注意', hlc: 'h-3'),
          base: recipeRow(id: 'r1', name: '原本的', notes: '原始注意', hlc: 'h-1'),
        ),
      ]);

      expect(r.results.single['outcome'], 'merged');
      expect(db.db.select('SELECT * FROM conflict_item'), isEmpty, reason: '不该打扰用户');

      final row = rowOf('r1')!;
      expect(row['name'], '服务端改的', reason: '服务端这次的改动要保住');
      expect(row['notes'], '客户端补的注意', reason: '客户端的改动也要保住');
    });

    test('没有 base 时不能自动合并，只能人工裁决（保守但不丢数据）', () {
      // shared 里写得很清楚：没有基线时无法区分"字段被删除"和"字段从未存在过"，
      // 于是凡是两边不一致的字段都当作双方都动过。
      // 后果是退化成人工资格，但**绝不会静默丢数据**。这条断言把这个取舍钉住。
      final d = pairDevice();
      sync.push(device: d, mutationId: 'a', changes: [
        upsert('recipe', recipeRow(id: 'r1', name: '服务端的', notes: '服务端的注意', hlc: 'h-2')),
      ]);

      final r = sync.push(device: d, mutationId: 'b', changes: [
        upsert('recipe', recipeRow(id: 'r1', name: '服务端的', notes: '客户端的注意', hlc: 'h-3')),
      ]);

      expect(r.results.single['outcome'], 'conflict');
      expect(r.results.single['conflictingFields'], ['notes']);
      expect(db.db.select('SELECT * FROM conflict_item').length, 1);
    });

    test('冲突时非冲突字段的改动不会跟着被搁置', () {
      final d = pairDevice();
      sync.push(device: d, mutationId: 'a', changes: [
        upsert('recipe', recipeRow(id: 'r1', name: 'S', notes: 'S注意', hlc: 'h-2')),
      ]);

      sync.push(device: d, mutationId: 'b', changes: [
        upsert(
          'recipe',
          recipeRow(id: 'r1', name: 'S', notes: 'C注意', hlc: 'h-3'),
          base: recipeRow(id: 'r1', name: 'S', notes: '原始', hlc: 'h-1'),
        ),
      ]);

      // notes 有争议，但客户端改了 servings，这个不该被连坐
      // （注意：要改的是 row 里的 servings，不是外层 change 对象）
      final changed = recipeRow(id: 'r1', name: 'S', notes: '原始', hlc: 'h-4')..['servings'] = 4;
      final r = sync.push(device: d, mutationId: 'c', changes: [
        upsert('recipe', changed, base: recipeRow(id: 'r1', name: 'S', notes: '原始', hlc: 'h-1')),
      ]);

      final row = rowOf('r1')!;
      expect(row['servings'], 4, reason: '用户改的每个字段都不该因为别的字段有争议而被搁置');
      expect(r.results.single['outcome'], anyOf('merged', 'updated'));
    });

    test('两人改成同一个值不算冲突', () {
      final d = pairDevice();
      sync.push(device: d, mutationId: 'a', changes: [
        upsert('recipe', recipeRow(id: 'r1', name: '都改成这个', hlc: 'h-2')),
      ]);
      final r = sync.push(device: d, mutationId: 'b', changes: [
        upsert(
          'recipe',
          recipeRow(id: 'r1', name: '都改成这个', hlc: 'h-3'),
          base: recipeRow(id: 'r1', name: '原本', hlc: 'h-1'),
        ),
      ]);

      // 双方都动过 name，但改成了同一个值 —— shared 里明确写了这不算冲突。
      // 结果是 autoMerged（合成一个双方都认可的版本），不是 skipped：
      // skipped 是"没有任何新变化"，这里确实有变化，只是没分歧。
      expect(r.results.single['outcome'], 'merged');
      expect(db.db.select('SELECT * FROM conflict_item'), isEmpty);
      expect(rowOf('r1')!['name'], '都改成这个');
    });

    test('upsert 不会因为 deleted_at 不同就凭空复活一行', () {
      // deleted_at 不在冲突判定的字段集里（它不属于「业务字段」），
      // 所以一个还没收到删除通知的旧客户端推上来的行，不会把已删除的菜谱复活。
      final d = pairDevice();
      sync.push(device: d, mutationId: 'a', changes: [upsert('recipe', recipeRow(id: 'r1', name: 'X'))]);
      sync.push(device: d, mutationId: 'b', changes: [
        {'tbl': 'recipe', 'rowId': 'r1', 'op': 'delete', 'row': recipeRow(id: 'r1', name: 'X')},
      ]);

      final r = sync.push(device: d, mutationId: 'c', changes: [
        upsert('recipe', recipeRow(id: 'r1', name: 'X')),
      ]);

      expect(r.results.single['outcome'], 'skipped');
      expect(rowOf('r1')!['deleted_at'], isNotNull, reason: '已经删掉的就不该活过来');
    });
  });

  // ══════════════════════ 端到端 ══════════════════════

  group('两端来回', () {
    test('配一次 → 推三条 → 另一端从 0 拉起，内容一致', () {
      final phone = pairDevice(id: 'phone-1', name: '手机');
      final ipad = pairDevice(id: 'ipad-1', name: '平板');

      sync.push(device: phone, mutationId: 'm1', changes: [
        upsert('recipe', recipeRow(id: 'r1', name: '番茄炒蛋')),
        upsert('recipe', recipeRow(id: 'r2', name: '蒜蓉粉丝蒸虾')),
        {'tbl': 'recipe', 'rowId': 'r2', 'op': 'delete', 'row': recipeRow(id: 'r2', name: '蒜蓉粉丝蒸虾')},
      ]);

      final r = sync.pull(since: 0, limit: 100);
      expect(r.changes, hasLength(3));

      // 平板按顺序落库：最后应该是 r2 处于删除态、r1 活着
      final byId = {for (final c in r.changes) c['rowId']: c};
      expect((byId['r1']!['row'] as Map)['deleted_at'], isNull);
      expect((byId['r2']!['row'] as Map)['deleted_at'], isNotNull);

      // 平板同步完了，报一下游标
      sync.noteCursor(ipad.id, r.lastSeq);
      expect(sync.devices().firstWhere((d) => d.id == 'ipad-1').syncCursor, 3);
      expect(sync.devices().firstWhere((d) => d.id == 'phone-1').syncCursor, 0,
          reason: '手机只推不拉，游标自然是 0');
    });
  });

  // ══════════════════════ R12：安全加固 ══════════════════════

  group('推送的值类型（R12）', () {
    test('★ row 值是数组/对象/布尔 → 该条 rejected，其余照常应用', () {
      // 这些类型绑定 SQLite 参数时抛 ArgumentError（不是 SqliteException），
      // R12 之前它冒泡出去把整批变成 500——和 R6 修过的「一条坏数据带走整批」同源。
      final d = pairDevice();
      final good = recipeRow(id: 'r-ok', name: '好行');
      final r = sync.push(device: d, mutationId: 'm1', changes: [
        upsert('recipe', {...recipeRow(id: 'r-bad-list', name: '坏行'), 'notes': ['数组']}),
        upsert('recipe', {...recipeRow(id: 'r-bad-bool', name: '坏行'), 'difficulty': true}),
        upsert('recipe', good),
      ]);

      expect(r.ok, isTrue, reason: '批次本身是成功的——坏条目被逐条拒绝，不是 500');
      expect(r.results[0]['outcome'], 'rejected');
      expect('${r.results[0]['reason']}', contains('notes'));
      expect(r.results[1]['outcome'], 'rejected');
      expect('${r.results[1]['reason']}', contains('difficulty'));
      expect(r.results[2]['outcome'], 'inserted', reason: '其余条目照常应用');
      expect(rowOf('r-ok'), isNotNull);
      expect(rowOf('r-bad-list'), isNull);
      expect(rowOf('r-bad-bool'), isNull);
    });
  });

  group('配对限流（R12）', () {
    test('窗口内失败满 5 次就暂时拒绝，换窗口后恢复', () {
      for (var i = 0; i < 5; i++) {
        expect(sync.pairBlocked('192.168.1.66'), isFalse, reason: '第 ${i + 1} 次失败前不该被拦');
        sync.redeem(code: 'WRONG1', deviceId: 'd', deviceName: 'x');
        sync.recordPairFail('192.168.1.66');
      }
      expect(sync.pairBlocked('192.168.1.66'), isTrue,
          reason: '5 次失败后必须拦住，否则配对码可以在窗口内被枚举');

      // 别的来源不受牵连
      expect(sync.pairBlocked('192.168.1.99'), isFalse);

      // 窗口滑过去就恢复
      fakeNow = fakeNow.add(const Duration(seconds: 61));
      expect(sync.pairBlocked('192.168.1.66'), isFalse);
    });

    test('成功配对清空失败记录（不惩罚手滑）', () {
      sync.recordPairFail('p');
      sync.recordPairFail('p');
      sync.recordPairFail('p');
      sync.recordPairFail('p');
      sync.clearPairFails('p');
      expect(sync.pairBlocked('p'), isFalse);
    });

    test('过期的失败记录不再计数（滑动窗口）', () {
      sync.recordPairFail('p');
      sync.recordPairFail('p');
      sync.recordPairFail('p');
      fakeNow = fakeNow.add(const Duration(minutes: 2));
      // 旧记录滑出窗口后，新失败从头计
      sync.recordPairFail('p');
      expect(sync.pairBlocked('p'), isFalse);
    });
  });

  group('数据清理（R12）', () {
    test('过期的配对码被清掉，窗口内的还在', () {
      sync.issuePairCode();
      fakeNow = fakeNow.add(const Duration(hours: 25));
      final keep = sync.issuePairCode(); // 新码不能误删

      final n = sync.cleanup();

      expect(n, greaterThanOrEqualTo(1));
      final left = db.db.select('SELECT COUNT(*) AS c FROM pair_code').first['c'] as int;
      expect(left, 1, reason: '只剩未过期的那一个');
      expect(db.db.select('SELECT code FROM pair_code').first['code'], keep.code);
    });

    test('★ applied_mutation 超过保留期被清；change_log 不被清理动过', () {
      final d = pairDevice();
      sync.push(device: d, mutationId: 'm1', changes: [
        upsert('recipe', recipeRow(id: 'r1', name: '番茄炒蛋')),
      ]);
      expect(db.db.select('SELECT COUNT(*) AS c FROM applied_mutation').first['c'], 1);
      expect(db.maxSeq, 1);

      fakeNow = fakeNow.add(const Duration(days: 8));
      sync.cleanup();

      expect(db.db.select('SELECT COUNT(*) AS c FROM applied_mutation').first['c'], 0,
          reason: '7 天保留期已过');
      expect(db.maxSeq, 1,
          reason: '★ change_log 一行都不能少：裁剪它需要先有快照拉取，'
              '否则新设备配对后从 seq 0 就拉不到被裁掉的变更');
    });

    test('刚应用的幂等记录不受清理影响', () {
      final d = pairDevice();
      sync.push(device: d, mutationId: 'm1', changes: [
        upsert('recipe', recipeRow(id: 'r1', name: '番茄炒蛋')),
      ]);
      sync.cleanup();
      expect(db.db.select('SELECT COUNT(*) AS c FROM applied_mutation').first['c'], 1,
          reason: '7 天内的重放还必须能命中');
    });
  });
}
