import 'dart:io';

import 'package:test/test.dart';
import 'package:zaoji_server/zaoji_server.dart';

/// R46 · 快赢包：状态页接口清单 ↔ 真实路由表 一致性。
///
/// 为什么要这条测试：[kEndpoints] 是**手写**的展示清单，路由表写在
/// `server.dart` 的 `buildHandler` 里。R44 加了七条 AI 接口，清单一条没跟上，
/// 状态页于是继续宣传那条根本不存在的 `/api/ai/{feature}`——
/// 「文档说有能力、代码没有」正是本轮查漏补缺要堵的洞（判定口径第 2 条）。
///
/// 为什么比对源码而不是打请求：`handler` 对没注册的 GET 也回 404 HTML、
/// 业务处理器自己也会回 404「记录不存在」，**状态码分不出「路由不存在」和
/// 「资源不存在」**；只有拿注册本身当事实才没有歧义。
void main() {
  /// 两边共用的一套归一：占位符 `<sha>` / `{sha256}` 都当 `*`，查询串丢掉。
  String norm(String path) =>
      path.split('?').first.replaceAll(RegExp(r'<[^>]*>|\{[^}]*\}'), '*');

  Set<String> fromRouterSource() {
    final f = File('lib/src/server.dart');
    if (!f.existsSync()) {
      throw StateError('读不到 ${f.absolute.path}——flutter test 的工作目录必须是包根目录');
    }
    final re = RegExp(r"\.(get|post|put|delete|patch)\(\s*'([^']+)'");
    return {
      for (final m in re.allMatches(f.readAsStringSync()))
        '${m.group(1)!.toUpperCase()} ${norm(m.group(2)!)}'
    };
  }

  Set<String> fromRegistry() => {
        for (final e in kEndpoints)
          for (final verb in (e['method'] as String).split('/'))
            '${verb.toUpperCase()} ${norm(e['path'] as String)}'
      };

  group('接口清单与路由表对齐', () {
    test('路由表里每条接口都在清单上（状态页不藏能力）', () {
      final missing = fromRouterSource().difference(fromRegistry());
      expect(missing, isEmpty,
          reason: '新接口没登记到 kEndpoints，状态页会少说——去 server_state.dart 补一条');
    });

    test('清单上每条接口都真在路由表里（不宣传幻影）', () {
      final ghost = fromRegistry().difference(fromRouterSource());
      expect(ghost, isEmpty,
          reason: 'kEndpoints 写了路由表里没有的接口，这是 R44 留下的漂移样本');
    });

    test('清单不再留「规划中」占位：要么实现要么删掉', () {
      final planned = kEndpoints.where((e) => e['status'] != 'ready').toList();
      expect(planned, isEmpty, reason: 'planned 项只会被读成「已有能力」，别挂半成品');
    });

    test('R44 的 AI 记录与提示词接口、R27 的三条代理接口都在清单上', () {
      final registry = fromRegistry();
      for (final path in [
        'POST /api/ai/calories',
        'POST /api/ai/recommend',
        'POST /api/ai/recipe-fill',
        'GET /api/ai/runs',
        'GET /api/ai/runs/*',
        'DELETE /api/ai/runs/*',
        'DELETE /api/ai/runs',
        'GET /api/ai/prompts',
        'POST /api/ai/prompts',
        'POST /api/ai/prompts/reset',
        'GET /status',
      ]) {
        expect(registry, contains(path), reason: '$path 必须对外可见');
      }
    });

    test('清单里不许出现 {feature} 这类假通配', () {
      expect(kEndpoints.map((e) => e['path']), isNot(contains('/api/ai/{feature}')));
    });
  });
}
