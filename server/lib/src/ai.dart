import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'db.dart';
import 'file_log.dart';

/// AI 代理（R27）。
///
/// **模型一句话：Key 统一存在自家服务端，所有端经它转发。**
/// 需求 v1.1 原稿是「Android 存本机 Keystore、Web 走服务端代理」双模。
/// 实施拍板合并为单模，理由：
/// ① 这套系统本来就只在家庭局域网用——「本地存 Key 直连」换来的隐私收益
///    在「所有请求先经过家里这台笔记本」的拓扑里几乎为零；
/// ② 双模要两套配置、两套错误路径、两套密钥存储，一半代码为差异服务；
/// ③ Key 的隐私要害是**不出仓库、不进同步**——单模两条都守得住：
///    `ai_config` 存 server_setting（非同步表），Key 用派生密钥流加密后存，
///    任何接口只回掩码（后 4 位），日志只写长度。
///
/// 能力面（本轮）：`calories` 热量估算、`recipe_fill` 按菜名补全整份菜谱、
/// `test` 连通测试。推荐（AI-40~49）与 OCR 导入不在本轮。

/// 服务商预设（FR-AI-02）。一键填 Base URL + 模型名；Ollama 标「零外发」。
const List<Map<String, String>> kAiProviders = [
  {'k': 'deepseek', 'n': 'DeepSeek', 'url': 'https://api.deepseek.com/v1',
    'model': 'deepseek-flash', 'note': '国内直连 · 默认'},
  {'k': 'dashscope', 'n': '通义千问', 'url': 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    'model': 'qwen-plus', 'note': '阿里云'},
  {'k': 'glm', 'n': '智谱 GLM', 'url': 'https://open.bigmodel.cn/api/paas/v4',
    'model': 'glm-4-flash', 'note': ''},
  {'k': 'siliconflow', 'n': '硅基流动', 'url': 'https://api.siliconflow.cn/v1',
    'model': 'deepseek-ai/DeepSeek-V3', 'note': '聚合'},
  {'k': 'volc', 'n': '火山方舟', 'url': 'https://ark.cn-beijing.volces.com/api/v3',
    'model': 'doubao-pro-32k', 'note': '豆包'},
  {'k': 'minimax', 'n': 'MiniMax', 'url': 'https://api.minimax.chat/v1',
    'model': 'abab6.5s-chat', 'note': ''},
  {'k': 'moonshot', 'n': 'Moonshot', 'url': 'https://api.moonshot.cn/v1',
    'model': 'moonshot-v1-8k', 'note': 'Kimi'},
  {'k': 'openai', 'n': 'OpenAI', 'url': 'https://api.openai.com/v1',
    'model': 'gpt-4o-mini', 'note': '需科学网络'},
  {'k': 'ollama', 'n': 'Ollama', 'url': 'http://127.0.0.1:11434/v1',
    'model': 'qwen2.5:7b', 'note': '本机跑 · 零外发'},
  {'k': 'custom', 'n': '自定义中转', 'url': '', 'model': '', 'note': 'OpenAI 兼容均可'},
];

/// AI 配置。序列化进 `server_setting.ai_config`，Key 字段单独加密存放。
class AiConfig {
  bool enabled; // 总开关（关 = 所有能力入口返回 503，但入口仍在）
  String provider;
  String baseUrl;
  String model;
  String key; // 明文只在内存；落库前加密
  bool flagNutrition;
  bool flagRecipe;
  bool flagRecommend;

  AiConfig({
    this.enabled = false,
    this.provider = 'deepseek',
    this.baseUrl = 'https://api.deepseek.com/v1',
    this.model = 'deepseek-flash',
    this.key = '',
    this.flagNutrition = true,
    this.flagRecipe = true,
    this.flagRecommend = true,
  });

  bool get configured => key.trim().isNotEmpty && baseUrl.trim().isNotEmpty;

  /// 掩码：只露后 4 位（FR-AI-04）。
  String get keyMasked =>
      key.length <= 4 ? (key.isEmpty ? '' : '••••') : '••••${key.substring(key.length - 4)}';

  Map<String, Object?> redacted() => {
        'enabled': enabled,
        'provider': provider,
        'baseUrl': baseUrl,
        'model': model,
        'keyMasked': keyMasked,
        'configured': configured,
        'flags': {
          'nutrition': flagNutrition,
          'recipe': flagRecipe,
          'recommend': flagRecommend,
        },
      };

  Map<String, Object?> toJsonFull() => {
        ...redacted(),
        'key': key, // 仅存储路径用；任何响应体不得用到
      };

  factory AiConfig.fromJson(Map<String, Object?> j) => AiConfig(
        enabled: j['enabled'] == true,
        provider: '${j['provider'] ?? 'deepseek'}',
        baseUrl: '${j['baseUrl'] ?? ''}',
        model: '${j['model'] ?? ''}',
        key: '${j['key'] ?? ''}',
        flagNutrition: j['flags'] is Map
            ? (j['flags'] as Map)['nutrition'] != false
            : true,
        flagRecipe:
            j['flags'] is Map ? (j['flags'] as Map)['recipe'] != false : true,
        flagRecommend: j['flags'] is Map
            ? (j['flags'] as Map)['recommend'] != false
            : true,
      );

  /// 部分更新：没出现的键保持原值；key 给掩码/空 = 不改（R26 同族纪律）。
  AiConfig mergedWith(Map<String, Object?> body) {
    final c = AiConfig(
      enabled: body['enabled'] is bool ? body['enabled'] as bool : enabled,
      provider: '${body['provider'] ?? provider}',
      baseUrl: body['baseUrl'] != null ? '${body['baseUrl']}'.trim() : baseUrl,
      model: body['model'] != null ? '${body['model']}'.trim() : model,
      key: key,
      flagNutrition: body['flagNutrition'] is bool
          ? body['flagNutrition'] as bool
          : flagNutrition,
      flagRecipe:
          body['flagRecipe'] is bool ? body['flagRecipe'] as bool : flagRecipe,
      flagRecommend: body['flagRecommend'] is bool
          ? body['flagRecommend'] as bool
          : flagRecommend,
    );
    if (body.containsKey('key')) {
      final k = '${body['key'] ?? ''}'.trim();
      if (k.isNotEmpty && !k.startsWith('••••')) c.key = k;
    }
    return c;
  }
}

class AiUpstreamException implements Exception {
  /// 'network' | 'timeout' | 'auth' | 'model' | 'http'
  final String kind;
  final String detail;
  AiUpstreamException(this.kind, this.detail);
  @override
  String toString() => 'AiUpstreamException($kind): $detail';
}

/// `server_setting` 的窄接口（SyncService 提供实现；测试可用内存版）。
abstract class SettingStore {
  String? get(String key);
  void set(String key, String value);
}

/// 用 ZaojiDb 的 server_setting 表实现 SettingStore。
/// 与 R21 准入配置同一张 kv 表——**server_setting 不在同步白名单里**，
/// 这就是「Key 不参与同步」（FR-AI-07）在现有地基上的天然落点，零新表。
class DbSettingStore implements SettingStore {
  final ZaojiDb db;
  DbSettingStore(this.db);

  @override
  String? get(String key) {
    final r =
        db.db.select('SELECT v FROM server_setting WHERE k = ?', [key]);
    return r.isEmpty ? null : r.first['v'] as String?;
  }

  @override
  void set(String key, String value) {
    db.db.execute(
      'INSERT INTO server_setting (k, v) VALUES (?, ?) '
      'ON CONFLICT(k) DO UPDATE SET v = excluded.v',
      [key, value],
    );
  }
}

class AiService {
  final SettingStore settings;
  final FileLog log;
  final String serverId;
  final HttpClient _client;
  AiService({
    required this.settings,
    required this.log,
    required this.serverId,
    HttpClient? client,
  }) : _client = client ?? HttpClient();

  static const _settingsKey = 'ai_config';
  static const _usageKey = 'ai_usage';
  static const timeout = Duration(seconds: 60);

  // ── 配置存取（Key 加密落库）──

  AiConfig config() {
    final raw = settings.get(_settingsKey);
    if (raw == null || raw.isEmpty) return AiConfig();
    try {
      final j = jsonDecode(raw) as Map<String, Object?>;
      final enc = '${j['key_enc'] ?? ''}';
      final c = AiConfig.fromJson(j..remove('enc')..remove('key_enc'));
      if (enc.isNotEmpty) c.key = _decKey(enc);
      return c; // 没有 key_enc = 没配过 Key（或手工写的裸配置），照单收下
    } catch (_) {
      return AiConfig(); // 坏配置不炸服务（与 BackupConfig.load 同一立场）
    }
  }

  Future<void> saveConfig(AiConfig c) async {
    final j = c.toJsonFull();
    final enc = _encKey(c.key);
    await _saveJson(_settingsKey, {...j..remove('key'), 'key_enc': enc});
    await log.write('[ai] 配置已保存 provider=${c.provider} model=${c.model} '
        'enabled=${c.enabled} key长度=${c.key.length}'); // 只写长度，不写内容
  }

  // ── 用量（FR-AI-12 的最小实现：本月调用次数与 token）──

  Map<String, Object?> usage() {
    final month = _monthKey();
    try {
      final j = jsonDecode(settings.get(_usageKey) ?? '{}');
      if (j is Map && j[month] is Map) {
        return (j[month] as Map).cast<String, Object?>();
      }
    } catch (_) {}
    return {'calls': 0, 'inTok': 0, 'outTok': 0};
  }

  Future<void> _bumpUsage(int inTok, int outTok) async {
    final month = _monthKey();
    Map<String, Object?> all = {};
    try {
      final j = jsonDecode(settings.get(_usageKey) ?? '{}');
      if (j is Map) all = j.cast<String, Object?>();
    } catch (_) {}
    final u = (all[month] as Map?)?.cast<String, Object?>() ?? {};
    int n(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;
    all[month] = {
      'calls': n(u['calls']) + 1,
      'inTok': n(u['inTok']) + inTok,
      'outTok': n(u['outTok']) + outTok,
    };
    await _saveJson(_usageKey, all);
  }

  static String _monthKey() {
    final d = DateTime.now();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}';
  }

  Future<void> _saveJson(String key, Map<String, Object?> v) async {
    settings.set(key, jsonEncode(v));
  }

  // ── 结果缓存（FR-AI-14：相同输入不重复请求）──

  final Map<String, Map<String, Object?>> _cache = {};
  static const _cacheCap = 64;
  static String _cacheKey(String feature, Map<String, Object?> input) =>
      '$feature|${sha256.convert(utf8.encode(jsonEncode(input))).toString()}';

  // ── 上游调用 ──

  /// 调 OpenAI 兼容 /chat/completions，要求只回 JSON。
  /// [system]/[userPrompt] 组 prompt；返回解析后的 JSON + 用量。
  Future<Map<String, Object?>> chatJson(String system, String userPrompt,
      {int maxTokens = 2048}) async {
    final cfg = config();
    final url = cfg.baseUrl.trim();
    final normalized = url.endsWith('/v1') ? '$url/chat/completions' : '$url/chat/completions';
    HttpClientResponse res;
    try {
      final req = await _client.openUrl('POST', Uri.parse(normalized))
          .timeout(const Duration(seconds: 10));
      req.headers.contentType = ContentType.json;
      req.headers.set('authorization', 'Bearer ${cfg.key}');
      final body = jsonEncode({
        'model': cfg.model,
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': userPrompt},
        ],
        'max_tokens': maxTokens,
        'temperature': 0.2,
        'response_format': {'type': 'json_object'},
        // deepseek-flash 是推理模型：实测重任务里 reasoning 能把 max_tokens
        // 全部吃光、content 返回空串（推荐场景真发过）。我们的三类任务
        // （热量/补全/推荐）要的是**稳定的结构化输出**不是深度推理，
        // 统一 thinking=disabled——09-28 验证记录：关思考 0.9s 出合规 JSON。
        'thinking': {'type': 'disabled'},
      });
      req.write(body);
      res = await req.close().timeout(timeout);
    } on TimeoutException {
      throw AiUpstreamException('timeout', '上游 $url 超时（>${timeout.inSeconds}s）');
    } on SocketException catch (e) {
      throw AiUpstreamException('network', '连不上上游：${e.osError ?? e.message}');
    } on FormatException {
      throw AiUpstreamException('network', '上游地址不合法：$url');
    }
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode == 401 || res.statusCode == 403) {
      throw AiUpstreamException('auth', '上游拒绝该 Key（HTTP ${res.statusCode}）');
    }
    if (res.statusCode != 200) {
      // 模型名不存在在多家上游都表现 400/404 + 文案，按 auth/model 分类给 UI
      final kind = res.statusCode == 404 || text.contains('model')
          ? 'model'
          : 'http';
      throw AiUpstreamException(kind, 'HTTP ${res.statusCode}：${_clip(text, 180)}');
    }
    Object? parsed;
    try {
      parsed = jsonDecode(text);
    } catch (_) {
      throw AiUpstreamException('http', '上游返回的不是 JSON');
    }
    if (parsed is! Map) throw AiUpstreamException('http', '上游响应结构不认识');
    final u = (parsed['usage'] as Map?)?.cast<String, Object?>();
    int n(Object? v) => v is int ? v : int.tryParse('$v') ?? 0;
    final choices = parsed['choices'] as List?;
    final first = (choices == null || choices.isEmpty) ? null : choices.first;
    final content = first is Map
        ? ((first['message'] as Map?)?['content'] ?? '')
        : '';
    await _bumpUsage(n(u?['prompt_tokens']), n(u?['completion_tokens']));
    final $ = _jsonFromContent('$content');
    if ($ == null) {
      throw AiUpstreamException('http', '模型没按约定返回 JSON（拿到 ${_clip(content.toString(), 120)}）');
    }
    return {'result': $, 'usage': u ?? {}, 'model': parsed['model'] ?? cfg.model};
  }

  /// 从 content 里抠 JSON：容忍 ```json 围栏与前后寒暄（推理模型偶尔会加）。
  static Map<String, Object?>? _jsonFromContent(String content) {
    var s = content.trim();
    final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```');
    if (fence.hasMatch(s)) s = fence.firstMatch(s)!.group(1)!.trim();
    final v = jsonTryDecode(s);
    if (v is Map<String, Object?>) return v;
    final brace = s.indexOf('{');
    final end = s.lastIndexOf('}');
    if (brace >= 0 && end > brace) {
      final v2 = jsonTryDecode(s.substring(brace, end + 1));
      if (v2 is Map<String, Object?>) return v2;
    }
    return null;
  }

  static Object? jsonTryDecode(String s) {
    try {
      return jsonDecode(s);
    } catch (_) {
      return null;
    }
  }

  // ── 能力 ──

  /// 热量估算（FR-AI-20~28）。输入是**服务端现读的真数据**还是客户端传来的？
  /// 决策：客户端把主料/辅料与分量传上来（它本来就在内存里），
  /// 服务端只负责 prompt 与转发——服务端不碰库，保持 AI 层无状态。
  Future<Map<String, Object?>> calories({
    required String name,
    required int servings,
    required List<Map<String, Object?>> ingredients,
  }) async {
    final cfg = config();
    if (!cfg.enabled || !cfg.flagNutrition) {
      throw AiUpstreamException('off', 'AI 或「卡路里估算」能力未启用');
    }
    final ck = _cacheKey('calories', {
      'n': name, 's': servings, 'i': ingredients
    });
    if (_cache[ck] != null) return {..._cache[ck]!, 'cached': true};
    final lines = ingredients
        .map((e) => '${e['kind'] == 'main' ? '主料' : '配料'}：'
            '${e['name']}${(e['amount'] ?? '').toString().isEmpty ? '' : ' ${e['amount']}'}')
        .join('\n');
    final r = await chatJson(
      '你是家庭菜谱的热量估算器。按常见食物营养数据估算，只输出 JSON，'
      '不要任何解释文字或围栏。字段：'
      '{"kcal_per_serving":int,"total_kcal":int,"protein_g":int,"fat_g":int,'
      '"carb_g":int,"per_ingredient":[{"name":str,"kcal":int}],'
      '"confidence":"low|medium|high","note":str}',
      '菜名：$name（$servings 人份）\n食材：\n$lines',
    );
    _putCache(ck, r);
    return r;
  }

  /// 按菜名补全整份菜谱（FR-AI-30~38）。
  Future<Map<String, Object?>> recipeFill({
    required String name,
    String? hint,
  }) async {
    final cfg = config();
    if (!cfg.enabled || !cfg.flagRecipe) {
      throw AiUpstreamException('off', 'AI 或「AI 生成菜谱」能力未启用');
    }
    final ck = _cacheKey('recipe_fill', {'n': name, 'h': hint ?? ''});
    if (_cache[ck] != null) return {..._cache[ck]!, 'cached': true};
    final r = await chatJson(
      '你是中式家常菜菜谱写手。为用户生成一道真实可做的家常菜，'
      '只输出 JSON，不要任何解释文字或围栏。字段：'
      '{"sub":str(一句话描述,≤24字),"difficulty":1|2|3,"self_time":int(总分钟),'
      '"servings":int,"tags":[str],"ingredients":[{"name":str,"amount":str,"kind":"main"|"side"}],'
      '"steps":[{"text":str,"minutes":int或null}],"notes":str}'
      '要求：步骤 4~8 条；带等待的步骤必须把时间写进步骤文本（如「小火炖 20 分钟」）'
      '以便应用识别时间胶囊；食材分量用家庭习惯（个/勺/克）。',
      hint == null || hint.isEmpty ? '菜名：$name' : '菜名：$name\n补充要求：$hint',
      maxTokens: 3000,
    );
    _putCache(ck, r);
    return r;
  }

  /// AI 推荐菜品（R31 · FR-AI-40~48）：按家里现有食材推能做的菜。
  ///
  /// 与本地匹配（shared PantryMatch）的关系不是替代是补集：本地匹「库里有记录的」，
  /// AI 推「库里没有但你现在做得成的」——所以 prompt 里把已有菜谱名一起给模型，
  /// **推重复菜是最伤信任的**（用户会以为 AI 没在听）。
  /// 「优先不新增食材或新增 ≤2 样」（FR-AI-43）写在要求里；
  /// 是否标注「不在你的菜谱中」由客户端比对决定（服务端不掌握全库）。
  Future<Map<String, Object?>> recommend({
    required List<Map<String, Object?>> pantry,
    required List<String> existingRecipeNames,
    int want = 5,
  }) async {
    final cfg = config();
    if (!cfg.enabled || !cfg.flagRecommend) {
      throw AiUpstreamException('off', 'AI 或「AI 推荐菜品」能力未启用');
    }
    final ck = _cacheKey('recommend', {
      'p': pantry, 'e': existingRecipeNames, 'w': want,
    });
    if (_cache[ck] != null) return {..._cache[ck]!, 'cached': true};
    final lines = pantry
        .map((e) => '${e['name']}${(e['amount'] ?? '').toString().isEmpty ? '' : ' ${e['amount']}'}')
        .join('、');
    final r = await chatJson(
      '你是家庭厨师。根据家里现有食材推荐家常菜，只输出 JSON，不要解释文字或围栏。'
      '字段：{"dishes":[{"name":str,"sub":str,"difficulty":1|2|3,"self_time":int,'
      '"servings":int,"ingredients":[{"name":str,"amount":str}],'
      '"steps":[str],"reason":str(为什么推荐：用上了哪些现有食材),'
      '"extra_needed":[str](还需要买的食材，尽量空)]}]} '
      '硬性要求：优先做现有食材就能完成的菜，最多 $want 道，'
      '每道菜需要新买的食材不超过 2 样（extra_needed 里列出来）；'
      'steps 里带等待的步骤必须写时间（如「炖 40 分钟」）；不要推荐与已有菜谱同名或高度相似的菜。',
      '家里现有食材：$lines\n'
      '已有菜谱（不要重复推荐）：${existingRecipeNames.join('、')}',
      maxTokens: 3000,
    );
    _putCache(ck, r);
    return r;
  }

  /// 连通测试（FR-AI-03）：用**待保存或已存的**参数发一条最小请求，
  /// 四类失败各有 kind：auth / model / network / timeout。
  Future<void> testConnection({String? baseUrl, String? model, String? key}) async {
    final cfg = config();
    final url = (baseUrl ?? cfg.baseUrl).trim();
    final useKey = (key != null && key.isNotEmpty && !key.startsWith('••••'))
        ? key
        : cfg.key;
    if (url.isEmpty) throw AiUpstreamException('network', 'Base URL 还没填');
    final normalized = '$url/chat/completions';
    try {
      final req = await _client.openUrl('POST', Uri.parse(normalized))
          .timeout(const Duration(seconds: 10));
      req.headers.contentType = ContentType.json;
      req.headers.set('authorization', 'Bearer $useKey');
      req.write(jsonEncode({
        'model': (model ?? cfg.model).trim(),
        'messages': [
          {'role': 'user', 'content': 'ping'}
        ],
        'max_tokens': 16,
      }));
      final res = await req.close().timeout(const Duration(seconds: 30));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode == 401 || res.statusCode == 403) {
        throw AiUpstreamException('auth', 'Key 被拒（HTTP ${res.statusCode}）');
      }
      if (res.statusCode != 200) {
        throw AiUpstreamException(
            res.statusCode == 404 || body.contains('model') ? 'model' : 'http',
            'HTTP ${res.statusCode}：${_clip(body, 160)}');
      }
    } on AiUpstreamException {
      rethrow;
    } on TimeoutException {
      throw AiUpstreamException('timeout', '地址不可达或太慢（>30s）');
    } on SocketException catch (e) {
      throw AiUpstreamException('network', '连不上：${e.osError ?? e.message}');
    } on FormatException {
      throw AiUpstreamException('network', '地址格式不对：$url');
    }
  }

  void _putCache(String k, Map<String, Object?> v) {
    if (_cache.length >= _cacheCap) _cache.remove(_cache.keys.first);
    _cache[k] = v;
  }

  // ── 配置字段的防尘加密（HMAC-SHA256 计数器流 XOR）──
  //
  // 诚实的威胁模型：这不是军事级保密——真正的泄密面是「进仓库」和「进同步」，
  // 那两条都已掐死（server_setting 非同步表；本文件无任何默认 Key）。
  // 这一层只挡「有人翻到 data 目录随手看到明文 Key」这一件事，
  // 密钥流派生自 serverId + 固定盐。写清定位，好过造一个假的安全感。

  List<int> get _secret =>
      Hmac(sha256, utf8.encode('zaoji-ai-key|v1|$serverId'))
          .convert(utf8.encode('stream-root'))
          .bytes;

  List<int> _keystream(int length) {
    final mac = Hmac(sha256, _secret);
    final out = <int>[];
    var counter = 0;
    while (out.length < length) {
      out.addAll(mac.convert([counter]).bytes);
      counter++;
    }
    return out;
  }

  String _encKey(String plain) {
    if (plain.isEmpty) return '';
    final data = utf8.encode(plain);
    final ks = _keystream(data.length);
    return base64Encode(List<int>.generate(data.length, (i) => data[i] ^ ks[i]));
  }

  String _decKey(String b64) {
    if (b64.isEmpty) return '';
    try {
      final data = base64Decode(b64);
      final ks = _keystream(data.length);
      return utf8.decode(List<int>.generate(data.length, (i) => data[i] ^ ks[i]));
    } catch (_) {
      return ''; // 解不开 = 没配过（或库被挪到了另一台 serverId），不炸
    }
  }

  static String _clip(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';

  void close() => _client.close(force: true);
}
