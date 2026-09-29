import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';

import '../data/recipe_store.dart';
import '../data/sync/sync_engine.dart' show MediaWidth;
import '../data/store_scope.dart';
import '../data/sync/sync_scope.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/cover_image.dart';
import 'ai_settings_page.dart';

/// 菜谱新建/编辑页。
///
/// 对照 prototype `SCREENS['recipe-edit']` 逐块实现。
/// 一个页面两种模式：`recipe` 参数为 null 时 = 新建，非 null = 编辑。
///
/// ## 设计取舍（第一版）
///
/// - 封面插画：第一版固定 palette + 默认 art（后续做封面重选）
/// - 标签分组：prototype 有四组（菜系/食材/口味/操作方式），第一版先简化
///   操作方式快捷选择
/// - 图片/分量/单位换算：延后（R14 核心是打通写路径 + 同步）
class RecipeEditPage extends StatefulWidget {
  const RecipeEditPage({super.key, this.recipe});

  /// 非 null = 编辑模式。null = 新建。
  final Recipe? recipe;

  bool get isNew => recipe == null;

  @override
  State<RecipeEditPage> createState() => _RecipeEditPageState();
}

class _RecipeEditPageState extends State<RecipeEditPage> {
  final _formKey = GlobalKey<FormState>();

  // 临时表单状态
  late final TextEditingController _nameCtrl;
  late final TextEditingController _subCtrl;
  late final TextEditingController _timeCtrl;
  late final TextEditingController _servingsCtrl;
  late final TextEditingController _notesCtrl;

  late int _difficulty;
  late List<_IngredientRow> _ingredients;
  late List<TextEditingController> _stepCtrls;

  bool _saving = false;
  bool _saved = false;

  // R27：AI 补全（FR-AI-30~36）。入口恒定显示（配没配都在、布局不跳变）；
  // 补全成功后表单顶上出现「AI 生成内容」标记条，用户手改任一字段它就还在——
  // **来源标记按整份草稿走**：只要保存时仍带着 AI 填过的内容就记 ai，
  // 「改后撤标记」需要逐字段 diff，收益配不上成本，尾巴记进交接文档。
  bool _aiFilled = false;
  String? _aiModel;
  bool _aiBusy = false;

  // 封面（R16）：_coverBytes 是新选的照片（已压缩、待上传）；
  // _coverSha 是当前生效的封面哈希（原有封面，或新上传后由引擎返回）。
  Uint8List? _coverBytes;
  String? _coverSha;
  bool _coverBusy = false;

  // R29 照片墙 / 步骤图。**已上传的存 sha，新选的存在内存等保存时一起传**——
  // 和封面同一套「选图即压缩、保存才上传」的既有节拍，失败降级口径也统一。
  List<String> _photos = [];
  final List<Uint8List> _pendingPhotos = [];
  final Map<int, List<String>> _stepPhotoShas = {};
  final Map<int, List<Uint8List>> _pendingStepPhotos = {};
  bool _wallBusy = false;

  // 快捷操作方式标签
  static const _quickMethods = ['爆炒', '水煮', '清蒸', '红烧', '烧烤', '凉拌', '烘焙', '火锅'];
  final Set<String> _selectedMethods = {};

  @override
  void initState() {
    super.initState();
    final r = widget.recipe;
    _nameCtrl = TextEditingController(text: r?.name ?? '');
    _subCtrl = TextEditingController(text: r?.sub ?? '');
    _timeCtrl = TextEditingController(text: r?.selfTime.toString() ?? '');
    _servingsCtrl = TextEditingController(text: r?.servings.toString() ?? '2');
    _notesCtrl = TextEditingController(text: r?.notes ?? '');

    _difficulty = r?.difficulty ?? 1;

    _ingredients = [
      for (final ing in r?.ingredients ?? const [])
        _IngredientRow(
          nameCtrl: TextEditingController(text: ing.name),
          qtyCtrl: TextEditingController(text: ing.qty),
          isMain: ing.isMain,
        ),
      // 新建时给 2 个空行
      if (r == null) ...[
        _IngredientRow(
          nameCtrl: TextEditingController(),
          qtyCtrl: TextEditingController(),
        ),
        _IngredientRow(
          nameCtrl: TextEditingController(),
          qtyCtrl: TextEditingController(),
        ),
      ],
    ];

    _stepCtrls = [
      for (final s in r?.steps ?? const []) TextEditingController(text: s.text),
      if (r == null) ...[TextEditingController(), TextEditingController()],
    ];

    if (r != null) {
      _selectedMethods.addAll(r.methods);
      _coverSha = r.coverSha256; // 编辑模式：保留原有封面，除非用户重选/移除
      _photos = List.of(r.photos);
      for (var i = 0; i < r.steps.length; i++) {
        if (r.steps[i].images.isNotEmpty) {
          _stepPhotoShas[i] = List.of(r.steps[i].images);
        }
      }
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _subCtrl.dispose();
    _timeCtrl.dispose();
    _servingsCtrl.dispose();
    _notesCtrl.dispose();
    for (final row in _ingredients) {
      row.nameCtrl.dispose();
      row.qtyCtrl.dispose();
    }
    for (final c in _stepCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    // 收集 draft
    final ingredients = <IngredientDraft>[
      for (final row in _ingredients)
        if (row.nameCtrl.text.trim().isNotEmpty ||
            row.qtyCtrl.text.trim().isNotEmpty)
          IngredientDraft(
            name: row.nameCtrl.text.trim().isEmpty
                ? '食材'
                : row.nameCtrl.text.trim(),
            qty: row.qtyCtrl.text.trim(),
            isMain: row.isMain,
          ),
    ];

    // 步骤过滤空行时，步骤图必须跟着**原下标**走——按下标重排而不是靠位置记忆
    final steps = <String>[];
    final stepImages = <List<String>>[];
    final keptIdx = <int>[]; // 过滤后位置 → 原控件下标（步骤图要按原下标跟行）
    for (var i = 0; i < _stepCtrls.length; i++) {
      final t = _stepCtrls[i].text.trim();
      if (t.isEmpty) continue;
      steps.add(t);
      stepImages.add(_stepPhotoShas[i] ?? const []);
      keptIdx.add(i);
    }

    final tags = <String, List<String>>{};
    if (_selectedMethods.isNotEmpty) {
      tags['method'] = _selectedMethods.toList();
    }

    setState(() => _saving = true);
    try {
      final engine = SyncScope.of(context);
      final store = StoreScope.of(context);

      // 封面：选了新照片就先上传（内容寻址）；上传失败不阻塞保存，
      // 退回原封面哈希（没有就干脆无封面），并在保存后提示。
      String? coverSha = _coverSha;
      String? coverWarning;
      if (_coverBytes != null) {
        try {
          coverSha = await engine.uploadMedia(_coverBytes!);
        } catch (e) {
          coverSha = _coverSha;
          coverWarning = '封面上传失败（$e），已保存菜谱但没有封面';
        }
      }

      // R29：先传照片墙的新增张，再传各步新增图——全部**内容寻址、失败不阻塞保存**
      // （与封面同一降级口径：图没传上菜照样存住，提示里说清楚）。
      final photos = List<String>.of(_photos);
      String? wallWarning;
      if (_pendingPhotos.isNotEmpty) {
        try {
          for (final b in _pendingPhotos) {
            photos.add(await engine.uploadMedia(b));
          }
        } catch (e) {
          wallWarning = '部分成品照上传失败（$e）';
        }
      }
      final uploadedStepImages = <int, List<String>>{};
      for (final e in _pendingStepPhotos.entries) {
        for (final b in e.value) {
          try {
            (uploadedStepImages[e.key] ??= []).add(await engine.uploadMedia(b));
          } catch (_) {
            wallWarning ??= '有步骤图上传失败';
          }
        }
      }
      for (final e in uploadedStepImages.entries) {
        _stepPhotoShas[e.key] = [...(_stepPhotoShas[e.key] ?? const []), ...e.value];
      }
      // 上传回来的 sha 按**原控件下标**并进对应步骤的图列表（过滤后的行对回原位）
      for (var k = 0; k < stepImages.length; k++) {
        final up = uploadedStepImages[keptIdx[k]];
        if (up != null && up.isNotEmpty) {
          stepImages[k] = [...stepImages[k], ...up];
        }
      }

      final draft = RecipeDraft(
        name: _nameCtrl.text.trim(),
        sub: _subCtrl.text.trim(),
        difficulty: _difficulty,
        selfTime: int.tryParse(_timeCtrl.text.trim()) ?? 0,
        servings: int.tryParse(_servingsCtrl.text.trim()) ?? 2,
        notes: _notesCtrl.text.trim(),
        ingredients: ingredients,
        steps: steps,
        art: DishArtKind.plate,
        palette: const [],
        tags: tags,
        coverSha256: coverSha,
        source: _aiFilled && widget.isNew ? 'ai' : 'manual',
        sourceModel: _aiFilled && widget.isNew ? _aiModel : null,
        photos: photos,
        stepImages: stepImages,
      );

      if (widget.isNew) {
        await store.createRecipe(draft);
      } else {
        await store.updateRecipe(widget.recipe!.id, draft);
      }
      if (mounted) {
        setState(() {
          _saved = true;
          _saving = false;
        });
        if (coverWarning != null || wallWarning != null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text([
              ?coverWarning,
              ?wallWarning,
            ].join('；'))),
          );
        }
        Navigator.of(context).pop(true); // 告诉上一页保存成功
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 选封面照片：压到 1600px / q82 再入库上传（计划书 §6 的约定）。
  /// 压缩用纯 Dart 的 package:image——Web 上没有 Isolate，就在主线程做；
  /// 一张手机照片约 1~2 秒，用 _coverBusy 挡住重复点击。
  Future<void> _pickCover() async {
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (x == null) return;

      setState(() => _coverBusy = true);
      final raw = await x.readAsBytes();
      final decoded = img.decodeImage(raw);
      if (decoded == null) throw const FormatException('无法解码这张图片');
      final resized = decoded.width > 1600
          ? img.copyResize(decoded, width: 1600)
          : decoded;
      final jpg = Uint8List.fromList(img.encodeJpg(resized, quality: 82));

      if (!mounted) return;
      setState(() {
        _coverBytes = jpg;
        _coverSha = null; // 新照片上传成功后由引擎返回新哈希
        _coverBusy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _coverBusy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('图片处理失败：$e')));
    }
  }

  void _removeCover() {
    setState(() {
      _coverBytes = null;
      _coverSha = null; // draft 里会是 null → 落库清除封面引用
    });
  }

  Future<void> _confirmPop() async {
    // 简单：直接弹确认 dialog，第一版不做「有改动才提示」
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('放弃编辑？'),
        content: const Text('当前的内容不会保存。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('继续编辑'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.zj.accent),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _saved || _saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmPop();
      },
      child: Scaffold(
        backgroundColor: context.zj.paper,
        appBar: AppBar(
          title: Text(widget.isNew ? '新建菜品' : '编辑菜品'),
          actions: [
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text(
                      '保存',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
            ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
            children: [
              _coverField(),
              _photoWallField(),
              const SizedBox(height: 18),
              _basicFields(),
              const SizedBox(height: 14),
              _aiFillBar(),
              const SizedBox(height: 18),
              _difficultyField(),
              const SizedBox(height: 18),
              _servingsField(),
              const SizedBox(height: 22),
              // 标签区
              const _SectionHead(num: '01', title: '操作方式'),
              _tagChips(),
              const SizedBox(height: 22),
              // 食材区
              const _SectionHead(num: '02', title: '食材与分量'),
              _ingredientEditor(),
              const SizedBox(height: 22),
              // 步骤区
              const _SectionHead(num: '03', title: '做法步骤'),
              _stepEditor(),
              const SizedBox(height: 22),
              // 注意事项
              const _SectionHead(num: '04', title: '注意事项'),
              _notesField(),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : _confirmPop,
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: context.zj.accent,
                    ),
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: context.zj.onAccent,
                            ),
                          )
                        : const Text('保存菜品'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ─────────── 各区块 ───────────

  /// 封面选择。预览优先级：新选的字节 > 原有封面（按 sha 异步拉取）> 虚线占位。
  /// R27 · AI 自动补全提示条（FR-AI-30）。位置与高度恒定：
  /// 未配置时按钮写成「去配置」，点它跳配置页——入口不因配置状态消失。
  Widget _aiFillBar() {
    final engine = SyncScope.of(context);
    final notConfigured = engine.aiStatusCache != null &&
        engine.aiStatusCache!['configured'] != true;
    return Container(
      key: const ValueKey('ai-fill-bar'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.zj.aiBg,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(color: context.zj.aiBg),
      ),
      child: Row(
        children: [
          Icon(Icons.auto_awesome, size: 18, color: context.zj.ai),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _aiFilled
                  ? 'AI 已填好草稿（$_aiModel），逐项可改'
                  : notConfigured
                      ? '用 AI 自动补全（未配置）'
                      : '用 AI 自动补全',
              style: TextStyle(
                  fontSize: 12.5, height: 1.5, color: context.zj.ai),
            ),
          ),
          const SizedBox(width: 8),
          _aiBusy
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: context.zj.ai))
              : TextButton(
                  onPressed: notConfigured ? _gotoAiSettings : _aiFill,
                  child: Text(notConfigured ? '去配置' : '补全',
                      style: TextStyle(
                          fontSize: 13, color: context.zj.ai)),
                ),
        ],
      ),
    );
  }

  void _gotoAiSettings() {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => const AiSettingsPage()));
  }

  Future<void> _aiFill() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先填菜名，AI 才知道做哪道'),
            duration: Duration(seconds: 2)),
      );
      return;
    }
    setState(() => _aiBusy = true);
    try {
      final engine = SyncScope.of(context);
      final res =
          await engine.aiCall('/api/ai/recipe-fill', {'name': name});
      if (!mounted) return;
      final u = (res['usage'] as Map?)?.cast<String, Object?>() ?? const {};
      StoreScope.of(context).logAiRun(
        feature: 'recipe_fill',
        ok: res['ok'] == true,
        model: '${res['model'] ?? ''}',
        promptTokens: (u['prompt_tokens'] as num?)?.toInt() ?? 0,
        completionTokens: (u['completion_tokens'] as num?)?.toInt() ?? 0,
        runRef: res['runId'] == null ? null : '${res['runId']}',
        summary: name,
      );
      if (res['ok'] != true) {
        if (!mounted) return;
        setState(() => _aiBusy = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${res['message'] ?? 'AI 补全失败'}'),
            duration: const Duration(seconds: 3)));
        return;
      }
      final r = (res['result'] as Map).cast<String, Object?>();
      if (!mounted) return;
      setState(() {
        _aiBusy = false;
        _aiFilled = true;
        _aiModel = '${res['model'] ?? ''}';
        // 只填**没动过的**字段——用户已经手打的内容永远优先（FR-AI-34）
        if (_subCtrl.text.trim().isEmpty && '${r['sub'] ?? ''}'.isNotEmpty) {
          _subCtrl.text = '${r['sub']}';
        }
        if (int.tryParse(_timeCtrl.text.trim()) == null &&
            r['self_time'] is num) {
          _timeCtrl.text = '${(r['self_time'] as num).round()}';
        }
        if (r['servings'] is num) {
          _servingsCtrl.text = '${(r['servings'] as num).round()}';
        }
        if (r['difficulty'] is num) {
          _difficulty = (r['difficulty'] as num).round().clamp(1, 3);
        }
        if (_notesCtrl.text.trim().isEmpty && '${r['notes'] ?? ''}'.isNotEmpty) {
          _notesCtrl.text = '${r['notes']}';
        }
        final ings = (r['ingredients'] as List? ?? const [])
            .whereType<Map>()
            .toList();
        if (_ingredients.every((e) => e.nameCtrl.text.trim().isEmpty) &&
            ings.isNotEmpty) {
          for (final c in _ingredients) {
            c.nameCtrl.dispose();
            c.qtyCtrl.dispose();
          }
          _ingredients = [
            for (final i in ings)
              _IngredientRow(
                nameCtrl:
                    TextEditingController(text: '${i['name'] ?? ''}'),
                qtyCtrl: TextEditingController(text: '${i['amount'] ?? ''}'),
                isMain: '${i['kind']}' == 'main',
              ),
          ];
        }
        final steps = (r['steps'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => '${e['text'] ?? ''}')
            .where((t) => t.isNotEmpty)
            .toList();
        if (steps.isNotEmpty) {
          for (final c in _stepCtrls) {
            c.dispose();
          }
          _stepCtrls = [for (final t in steps) TextEditingController(text: t)];
        }
        final tags = r['tags'];
        if (tags is List) {
          for (final t in tags.whereType<String>()) {
            if (_quickMethods.contains(t)) _selectedMethods.add(t);
          }
        }
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('AI 已填好草稿，逐项检查后保存'),
          duration: Duration(seconds: 2)));
    } catch (e) {
      if (!mounted) return;
      StoreScope.of(context).logAiRun(
          feature: 'recipe_fill', ok: false, summary: name);
      setState(() => _aiBusy = false);
      final s = '$e';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: s.contains('401') || s.contains('StateError')
              ? const Text('还没配置大模型，先去「我的 → 大模型能力」')
              : Text('AI 补全失败：$s'),
          duration: const Duration(seconds: 3)));
    }
  }

  // ───────────────────── R29 · 照片墙 / 步骤图 ─────────────────────

  /// 选图 → 压到 1600px/q82（与封面同一口径、同一实现）。
  Future<Uint8List?> _compressPhoto(XFile x) async {
    final raw = await x.readAsBytes();
    final decoded = img.decodeImage(raw);
    if (decoded == null) return null;
    final resized =
        decoded.width > 1600 ? img.copyResize(decoded, width: 1600) : decoded;
    return Uint8List.fromList(img.encodeJpg(resized, quality: 82));
  }

  Future<void> _pickWallPhotos() async {
    setState(() => _wallBusy = true);
    try {
      final picked = await ImagePicker().pickMultiImage();
      for (final x in picked.take(8 - _pendingPhotos.length - _photos.length)) {
        final c = await _compressPhoto(x);
        if (c != null) _pendingPhotos.add(c);
      }
    } catch (_) {
      // 相册不可用/用户取消：和封面同口径——不弹错误，墙保持原样
    } finally {
      if (mounted) setState(() => _wallBusy = false);
    }
  }

  Future<void> _pickStepPhotos(int i) async {
    final room = 4 -
        ((_stepPhotoShas[i]?.length ?? 0) +
            (_pendingStepPhotos[i]?.length ?? 0));
    if (room <= 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('一步最多 4 张，先移掉一张再加'),
            duration: Duration(seconds: 2)));
      }
      return;
    }
    setState(() => _wallBusy = true);
    try {
      final picked = await ImagePicker().pickMultiImage();
      for (final x in picked.take(room)) {
        final c = await _compressPhoto(x);
        if (c != null) (_pendingStepPhotos[i] ??= []).add(c);
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _wallBusy = false);
    }
  }

  Widget _miniThumb(
      {required Widget child, VoidCallback? onLongPress, VoidCallback? onTap}) {
    return Padding(
      padding: const EdgeInsets.only(right: 6, top: 6),
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(ZaojiRadius.xs),
          child: SizedBox(width: 56, height: 56, child: child),
        ),
      ),
    );
  }

  /// 成品照片墙（FR-REC-06）：封面之下、基础字段之上。长按缩略图 = 设为封面/移出。
  Widget _photoWallField() {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        key: const ValueKey('photo-wall'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('成品照片',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: context.zj.ink2)),
              SizedBox(width: 8),
              Text('长按可设为封面',
                  style: TextStyle(fontSize: 10.5, color: context.zj.muted)),
            ],
          ),
          const SizedBox(height: 2),
          Wrap(
            children: [
              for (final sha in _photos)
                _miniThumb(
                  child: CoverImage(sha: sha, width: MediaWidth.card),
                  onTap: () => _showFullPhoto(sha),
                  onLongPress: () => _wallMenu(sha),
                ),
              for (final _ in _pendingPhotos) const _MiniThumbPending(),
              if (_photos.length + _pendingPhotos.length < 8)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: GestureDetector(
                    onTap: _wallBusy ? null : _pickWallPhotos,
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        border: Border.all(color: context.zj.line),
                        borderRadius: BorderRadius.circular(ZaojiRadius.xs),
                        color: context.zj.paper2,
                      ),
                      child: _wallBusy
                          ? Center(
                              child: SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2)))
                          : Icon(Icons.add_photo_alternate_outlined,
                              size: 20, color: context.zj.muted),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _wallMenu(String sha) async {
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('这张照片…', style: const TextStyle(fontSize: 15)),
        children: [
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('设为封面'),
            onTap: () => Navigator.pop(ctx, 'cover'),
          ),
          ListTile(
            leading: Icon(Icons.delete_outline, color: context.zj.muted),
            title: const Text('移出照片墙'),
            onTap: () => Navigator.pop(ctx, 'remove'),
          ),
        ],
      ),
    );
    if (action == null || !mounted) return;
    setState(() {
      if (action == 'cover') {
        // 封面是「选出来的那一张」：墙里去掉它，旧封面回墙头（不丢引用）
        final old = _coverSha;
        _coverSha = sha;
        _photos.remove(sha);
        if (old != null && !_photos.contains(old)) _photos.insert(0, old);
        _coverBytes = null;
      } else if (action == 'remove') {
        _photos.remove(sha);
      }
    });
  }

  void _showFullPhoto(String sha) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(18),
        backgroundColor: Colors.black,
        child: InteractiveViewer(
          child: CoverImage(sha: sha, fit: BoxFit.contain),
        ),
      ),
    );
  }

  /// 某一步的实拍条（FR-REC-07：0–4 张）。
  Widget _stepPhotoStrip(int i) {
    final shas = _stepPhotoShas[i] ?? const <String>[];
    final pending = _pendingStepPhotos[i] ?? const <Uint8List>[];
    if (shas.isEmpty && pending.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      key: ValueKey('step-photos-$i'),
      children: [
        for (final sha in shas)
          _miniThumb(
            child: CoverImage(sha: sha, width: MediaWidth.card),
            onTap: () => _showFullPhoto(sha),
            onLongPress: () => setState(() => _stepPhotoShas[i] =
                shas.where((x) => x != sha).toList()),
          ),
        for (final _ in pending) const _MiniThumbPending(),
        if (shas.length + pending.length < 4)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: GestureDetector(
              key: ValueKey('step-photo-add-$i'),
              onTap: _wallBusy ? null : () => _pickStepPhotos(i),
              child: Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  border: Border.all(color: context.zj.line),
                  borderRadius: BorderRadius.circular(ZaojiRadius.xs),
                  color: context.zj.paper2,
                ),
                child: Icon(Icons.add_a_photo_outlined,
                    size: 18, color: context.zj.muted),
              ),
            ),
          ),
      ],
    );
  }

  Widget _coverField() {
    if (_coverBytes != null || _coverSha == null) {
      return CoverPickerBox(
        preview: _coverBytes,
        onPick: _coverBusy ? null : _pickCover,
        onRemove: (_coverBytes != null || _coverSha != null)
            ? _removeCover
            : null,
      );
    }
    return FutureBuilder(
      future: SyncScope.of(context).fetchMediaCached(_coverSha!),
      builder: (context, snap) => CoverPickerBox(
        preview: snap.data,
        onPick: _coverBusy ? null : _pickCover,
        onRemove: _removeCover,
      ),
    );
  }

  Widget _basicFields() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel('菜品名称', required: true),
        TextFormField(
          controller: _nameCtrl,
          decoration: _inputDeco('例：番茄炒蛋'),
          validator: (v) => (v == null || v.trim().isEmpty) ? '菜名不能为空' : null,
        ),
        const SizedBox(height: 14),
        _fieldLabel('一句话描述'),
        TextFormField(
          controller: _subCtrl,
          decoration: _inputDeco('例：十五分钟的家常底味'),
        ),
      ],
    );
  }

  Widget _difficultyField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _fieldLabel('难度'),
        Row(
          children: [
            for (var d = 1; d <= 3; d++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: IconButton(
                  onPressed: () => setState(() => _difficulty = d),
                  icon: Icon(
                    Icons.local_fire_department,
                    color: d <= _difficulty
                        ? context.zj.accent
                        : context.zj.muted,
                    size: 26,
                  ),
                ),
              ),
            Text(
              ['简单', '中等', '较难'][_difficulty - 1],
              style: TextStyle(fontSize: 13, color: context.zj.ink2),
            ),
          ],
        ),
      ],
    );
  }

  Widget _servingsField() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _fieldLabel('分量（人）'),
              TextFormField(
                controller: _servingsCtrl,
                keyboardType: TextInputType.number,
                decoration: _inputDeco('2'),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _fieldLabel('耗时（分钟）'),
              TextFormField(
                controller: _timeCtrl,
                keyboardType: TextInputType.number,
                decoration: _inputDeco('15'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _tagChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final m in _quickMethods)
          FilterChip(
            label: Text(m),
            selected: _selectedMethods.contains(m),
            onSelected: (v) => setState(() {
              if (v) {
                _selectedMethods.add(m);
              } else {
                _selectedMethods.remove(m);
              }
            }),
          ),
      ],
    );
  }

  Widget _ingredientEditor() {
    return Column(
      children: [
        for (var i = 0; i < _ingredients.length; i++) ...[
          Row(
            children: [
              SizedBox(
                width: 16,
                child: Checkbox(
                  value: _ingredients[i].isMain,
                  onChanged: (v) =>
                      setState(() => _ingredients[i].isMain = v ?? false),
                  visualDensity: VisualDensity.compact,
                ),
              ),
              Expanded(
                flex: 3,
                child: TextFormField(
                  controller: _ingredients[i].nameCtrl,
                  decoration: _inputDeco('食材名'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: _ingredients[i].qtyCtrl,
                  decoration: _inputDeco('2 个'),
                ),
              ),
              IconButton(
                iconSize: 18,
                tooltip: '删除这行',
                onPressed: () => setState(() => _ingredients.removeAt(i)),
                icon: Icon(
                  Icons.remove_circle_outline,
                  color: context.zj.muted,
                ),
              ),
            ],
          ),
        ],
        OutlinedButton.icon(
          onPressed: () => setState(
            () => _ingredients.add(
              _IngredientRow(
                nameCtrl: TextEditingController(),
                qtyCtrl: TextEditingController(),
              ),
            ),
          ),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('添加食材'),
        ),
      ],
    );
  }

  Widget _stepEditor() {
    return Column(
      children: [
        for (var i = 0; i < _stepCtrls.length; i++) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              border: Border.all(color: context.zj.lineSoft),
              borderRadius: BorderRadius.circular(ZaojiRadius.md),
            color: context.zj.surface,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: context.zj.accent.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: context.zj.accent,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '步骤',
                      style: TextStyle(fontSize: 12, color: context.zj.muted),
                    ),
                    const Spacer(),
                    IconButton(
                      iconSize: 16,
                      tooltip: '删除',
                      onPressed: () => setState(() => _stepCtrls.removeAt(i)),
                      icon: Icon(
                        Icons.delete_outline,
                        color: context.zj.muted,
                      ),
                    ),
                  ],
                ),
                TextFormField(
                  controller: _stepCtrls[i],
                  maxLines: 3,
                  minLines: 2,
                  decoration: _inputDeco('描述这一步，直接写时间关键词（如「小火炖 20 分钟」）'),
                ),
                _stepPhotoStrip(i),
              ],
            ),
          ),
        ],
        OutlinedButton.icon(
          onPressed: () =>
              setState(() => _stepCtrls.add(TextEditingController())),
          icon: const Icon(Icons.add, size: 16),
          label: const Text('添加步骤'),
        ),
      ],
    );
  }

  Widget _notesField() {
    return TextFormField(
      controller: _notesCtrl,
      maxLines: 4,
      minLines: 3,
      decoration: _inputDeco('记录翻车点、替代食材、火候提醒…'),
    );
  }

  // ── 样式助手 ──

  InputDecoration _inputDeco(String hint) {
    return InputDecoration(
      isCollapsed: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ZaojiRadius.sm),
        borderSide: BorderSide(color: context.zj.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ZaojiRadius.sm),
        borderSide: BorderSide(color: context.zj.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(ZaojiRadius.sm),
        borderSide: BorderSide(color: context.zj.accent),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      hintText: hint,
      hintStyle: TextStyle(fontSize: 13, color: context.zj.muted),
    );
  }

  Widget _fieldLabel(String text, {bool required = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(
            text,
            style: ZaojiText.bodyOf(context, 
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: context.zj.ink2,
            ),
          ),
          if (required)
            Text(
              ' *',
              style: TextStyle(
                color: context.zj.accent,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionHead extends StatelessWidget {
  const _SectionHead({required this.num, required this.title});
  final String num;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(
            num,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: context.zj.accent,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: ZaojiText.displayOf(context, fontSize: 17, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _IngredientRow {
  final TextEditingController nameCtrl;
  final TextEditingController qtyCtrl;
  bool isMain;

  _IngredientRow({
    required this.nameCtrl,
    required this.qtyCtrl,
    this.isMain = false,
  });
}

/// 已选未传的占位缩略：只表达「这张在路上」，不做进度数字。
class _MiniThumbPending extends StatelessWidget {
  const _MiniThumbPending();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(right: 6, top: 6),
      child: SizedBox(
        width: 56,
        height: 56,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.zj.paper2,
            borderRadius: BorderRadius.all(Radius.circular(ZaojiRadius.xs)),
          ),
          child: Center(
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
    );
  }
}
