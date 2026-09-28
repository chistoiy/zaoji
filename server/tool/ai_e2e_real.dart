// R27 AI 真上游 E2E（DeepSeek）。凭据从环境读，不进仓库。
// 跑法（server/ 目录）：source ../.secrets/externals.local.env && dart run tool/ai_e2e_real.dart
import 'dart:io';

import 'package:zaoji_server/zaoji_server.dart';

Future<void> main() async {
  final key = Platform.environment['DEEPSEEK_API_KEY'];
  final base =
      Platform.environment['DEEPSEEK_BASE_URL'] ?? 'https://api.deepseek.com/v1';
  final model = Platform.environment['DEEPSEEK_MODEL'] ?? 'deepseek-flash';
  if (key == null || key.isEmpty) {
    stderr.writeln('缺 DEEPSEEK_API_KEY');
    exit(64);
  }
  final tmp = await Directory.systemTemp.createTemp('zaoji_ai_e2e_');
  final state = await ServerState.boot(ServerConfig(
    host: '127.0.0.1',
    port: 1,
    tlsPort: 2,
    dataDir: Directory('${tmp.path}/data'),
    certDir: Directory('${tmp.path}/certs'),
  ));
  var bad = 0;
  void check(bool ok, String what) {
    stdout.writeln('${ok ? '✓' : '✗'} $what');
    if (!ok) bad++;
  }
  try {
    await state.ai.saveConfig(AiConfig(
        enabled: true, baseUrl: base, model: model, key: key));
    String? t;
    try {
      await state.ai.testConnection(baseUrl: base, model: model, key: key);
    } catch (e) {
      t = '$e';
    }
    check(t == null, '连通测试：${t ?? 'ok'}');

    final c = await state.ai.calories(
        name: '番茄炒蛋',
        servings: 2,
        ingredients: const [
          {'name': '番茄', 'amount': '2个(约300g)', 'kind': 'main'},
          {'name': '鸡蛋', 'amount': '3个(约180g)', 'kind': 'main'},
          {'name': '食用油', 'amount': '2汤匙', 'kind': 'side'},
        ]);
    final cr = c['result'] as Map;
    check(cr['kcal_per_serving'] is num && (cr['kcal_per_serving'] as int) > 0,
        '热量：${cr['kcal_per_serving']} kcal/份，总 ${cr['total_kcal']}，'
            '置信 ${cr['confidence']}（cached=${c['cached'] == true}）');

    final f = await state.ai.recipeFill(name: '红烧狮子头');
    final fr = f['result'] as Map;
    final steps = fr['steps'] as List? ?? const [];
    final timeInText = steps.any((s) =>
        '${(s as Map)['text'] ?? ''}'.contains(RegExp(r'\d+\s*(分钟|小时|秒)')));
    check(steps.length >= 3, '菜谱补全：${steps.length} 步，'
        '食材 ${(fr['ingredients'] as List?)?.length ?? 0} 行，'
        '难度 ${fr['difficulty']}，耗时 ${fr['self_time']} 分');
    check(timeInText, '步骤文本里确实带了时间关键词（时间胶囊能识别）');

    final rec = await state.ai.recommend(
        pantry: const [
          {'name': '豆腐', 'amount': '1盒'},
          {'name': '鸡蛋', 'amount': '3个'},
          {'name': '葱'},
        ],
        existingRecipeNames: const ['番茄炒蛋', '紫菜蛋花汤']);
    final dishes = (rec['result'] as Map)['dishes'] as List? ?? const [];
    final first = dishes.isNotEmpty ? dishes.first as Map : const {};
    check(dishes.isNotEmpty, 'AI 推荐：出了 ${dishes.length} 道，'
        '首道「${first['name']}」还要买：'
        '${(first['extra_needed'] as List? ?? const []).join('、')} '
        '（缓存=${rec['cached'] == true}）');

    final u = state.ai.usage();
    // 只记**能力调用**（热量+补全=2 次）；连通测试不计费——它是配置动作不是能力
    check((u['calls'] as int? ?? 0) >= 2, '用量记账：$u');
  } finally {
    await state.close();
    state.ai.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  }
  if (bad > 0) exit(1);
  stdout.writeln('AI 真上游 E2E 全过');
}
