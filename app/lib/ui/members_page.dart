import 'package:flutter/material.dart';

import '../data/recipe_store.dart';
import '../data/store_scope.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/allergen_bits.dart';

/// 家庭成员与过敏原（R40 · FR-SET-04/05）。
///
/// 布局照原型 `SCREENS.members`：顶部一条**命中汇总**（不是介绍文字，
/// 是"当前有 N 道菜和你家人冲突"这个事实），下面按人一张卡，
/// 每人两行 chips：过敏（警告档）与不吃（提示档）。
///
/// 两处刻意的取舍：
///  · **不预置成员**。种子数据里塞三个假家人，用户第一眼看到的就是别人的故事，
///    而且他会去删——空态 + 一个明确的"添加第一位家人"更诚实；
///  · **类名展开只对过敏生效**。"爸爸不吃贝类"不该拦住每一道扇贝，
///    忌口误报的代价是提示多了没人看，那时真正的过敏也一起被无视
///    （判定本身在 `shared/allergen.dart`，这里只负责把它摆出来）。
class MembersPage extends StatelessWidget {
  const MembersPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    // 整屏跟着 store 重画：加完人弹层收起后，卡列表必须立刻多一张——
    // 只读一次 members 的话，页面会一直停在"还没有添加家人"，
    // 用户以为没存上，回头又建一个重名的。
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => _scaffold(context, store),
    );
  }

  Widget _scaffold(BuildContext context, RecipeStore store) {
    final zj = context.zj;
    final total =
        store.members.fold<int>(0, (a, m) => a + m.allergens.length);
    final conflicts = store.conflictingRecipeCount();

    return Scaffold(
      backgroundColor: zj.paper,
      appBar: AppBar(
        title: const Text('家庭成员与过敏原'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(22),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, bottom: 10),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${store.members.length} 位成员 · $total 项过敏原'
                '${conflicts > 0 ? ' · $conflicts 道菜有冲突' : ''}',
                style: TextStyle(fontSize: 12, color: zj.muted),
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: store.members.isEmpty
          ? null
          : FloatingActionButton(
              key: const ValueKey('member-add'),
              backgroundColor: zj.accent,
              foregroundColor: zj.onAccent,
              onPressed: () => _MemberSheet.show(context),
              child: const Icon(Icons.add),
            ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
        children: [
          if (store.members.isEmpty) ...[
            const SizedBox(height: 48),
            Icon(Icons.family_restroom, size: 40, color: zj.line),
            const SizedBox(height: 12),
            Center(
              child: Text('还没有添加家人',
                  style: TextStyle(fontSize: 14, color: zj.ink2)),
            ),
            const SizedBox(height: 6),
            Center(
              child: Text('填上谁对什么过敏，含这些食材的菜会全程标出来',
                  style: TextStyle(fontSize: 12, color: zj.muted)),
            ),
            const SizedBox(height: 18),
            Center(
              child: FilledButton.icon(
                key: const ValueKey('member-first-add'),
                style: FilledButton.styleFrom(
                    backgroundColor: zj.accent,
                    foregroundColor: zj.onAccent),
                onPressed: () => _MemberSheet.show(context),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加第一位家人'),
              ),
            ),
          ] else ...[
            if (conflicts > 0) const _ConflictBanner(),
            const SizedBox(height: 14),
            for (final m in store.members) _MemberCard(member: m),
          ],
          if (store.members.isNotEmpty) ...[
            const SizedBox(height: 22),
            Text('警示设置',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: zj.ink2)),
            const SizedBox(height: 4),
            _SwitchRow(
              keyName: 'warn-switch',
              title: '菜谱中显示过敏原警示',
              sub: '食材行条纹高亮并写明是谁',
              value: store.allergenWarnInRecipes,
              onChanged: store.setAllergenWarnInRecipes,
            ),
            _SwitchRow(
              keyName: 'confirm-switch',
              title: '排菜单时先确认',
              sub: '命中过敏原的菜要再点一次才进菜单',
              value: store.allergenConfirmOnMenu,
              onChanged: store.setAllergenConfirmOnMenu,
            ),
          ],
        ],
      ),
    );
  }
}

/// 顶部那条命中汇总：谁 对 什么 过敏 → 哪几道菜。
///
/// 它是**事实清单**不是提示语——数字和菜名都从库里现算，
/// 加一个过敏原，这条立刻变长；删掉人，它自己消失。
class _ConflictBanner extends StatelessWidget {
  const _ConflictBanner();

  @override
  Widget build(BuildContext context) {
    final store = StoreScope.of(context);
    final zj = context.zj;
    final lines = <Widget>[];
    for (final m in store.members) {
      final hits = <String>{};
      final dishes = store.conflictingRecipeNames(m.id);
      if (m.allergens.isEmpty || dishes.isEmpty) continue;
      hits.addAll(m.allergens);
      lines.add(Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Text.rich(TextSpan(
          children: [
            TextSpan(
                text: m.name,
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: zj.accentDeep)),
            // 词加书名号（与原型一致）：一行里连着好几个词时，
            // 「虾」「贝类」靠引号才分得开，光靠顿号会读成一串
            TextSpan(
                text: ' 对 ${[for (final w in m.allergens) '「$w」'].join('、')} 过敏 → ',
                style: TextStyle(color: zj.ink2)),
            TextSpan(
                text: dishes.join('、'),
                style: TextStyle(color: zj.ink2)),
          ],
        )),
      ));
    }
    if (lines.isEmpty) return const SizedBox.shrink();
    return AllergenBanner(
      title: '${store.conflictingRecipeCount()} 道菜和家里的成员冲突',
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines),
    );
  }
}

class _MemberCard extends StatelessWidget {
  const _MemberCard({required this.member});
  final Member member;

  @override
  Widget build(BuildContext context) {
    final zj = context.zj;
    return Container(
      key: ValueKey('member-${member.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: zj.surface,
        borderRadius: BorderRadius.circular(ZaojiRadius.md),
        border: Border.all(color: zj.lineSoft),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AvatarChip(name: member.avatarChar, index: member.avatar),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(member.name,
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(
                  '已排除 ${member.totalRestrictions} 项食材',
                  style: TextStyle(fontSize: 11.5, color: zj.muted),
                ),
                if (member.allergens.isNotEmpty) ...[
                  const SizedBox(height: 7),
                  _WordRow(
                      label: '过敏', words: member.allergens, allergy: true),
                ],
                if (member.dislikes.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  _WordRow(
                      label: '不吃', words: member.dislikes, allergy: false),
                ],
              ],
            ),
          ),
          IconButton(
            key: ValueKey('member-edit-${member.id}'),
            icon: const Icon(Icons.edit_outlined, size: 18),
            color: zj.muted,
            onPressed: () => _MemberSheet.show(context, member: member),
          ),
        ],
      ),
    );
  }
}

/// 一行词：左边写明是「过敏」还是「不吃」，右边只放词本身。
///
/// 「谁」不在标签里重复——头像和名字就在这张卡上，再写一遍
/// 「小明 过敏 · 虾」会把这行撑成三行，读起来反而找不到重点。
class _WordRow extends StatelessWidget {
  const _WordRow({
    required this.label,
    required this.words,
    required this.allergy,
  });

  final String label;
  final List<String> words;
  final bool allergy;

  @override
  Widget build(BuildContext context) {
    final zj = context.zj;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 32,
          child: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(label,
                style: TextStyle(fontSize: 10.5, color: zj.muted)),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 5,
            children: [
              for (final w in words)
                AllergenTag(word: w, allergy: allergy, mode: AllergenTagMode.word),
            ],
          ),
        ),
      ],
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.keyName,
    required this.title,
    required this.sub,
    required this.value,
    required this.onChanged,
  });

  final String keyName;
  final String title;
  final String sub;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final zj = context.zj;
    return SwitchListTile(
      key: ValueKey(keyName),
      contentPadding: EdgeInsets.zero,
      dense: true,
      activeThumbColor: zj.accent,
      title: Text(title, style: const TextStyle(fontSize: 13.5)),
      subtitle: Text(sub, style: TextStyle(fontSize: 11.5, color: zj.muted)),
      value: value,
      onChanged: onChanged,
    );
  }
}

/// 新增 / 编辑成员的弹层。
///
/// 词是**自由输入**的（过敏原只有用户自己知道家里的医嘱），
/// 但下面给一排常见词一点就加——包括"贝类/坚果/麸质"这类**类名**，
/// 因为类名能连带命中扇贝、腰果、面条这些字面上不含类名的食材，
/// 让用户自己想到"还得逐个填扇贝花甲干贝"是不现实的。
class _MemberSheet extends StatefulWidget {
  const _MemberSheet({this.member});

  final Member? member;

  static Future<void> show(BuildContext context, {Member? member}) =>
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: context.zj.paper,
        showDragHandle: true,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
              top: Radius.circular(ZaojiRadius.xl)),
        ),
        builder: (_) => _MemberSheet(member: member),
      );

  @override
  State<_MemberSheet> createState() => _MemberSheetState();
}

class _MemberSheetState extends State<_MemberSheet> {
  static const _suggested = [
    '花生', '坚果', '牛奶', '鸡蛋', '大豆', '小麦', '麸质',
    '鱼', '虾', '蟹', '贝类', '芝麻', '芒果', '香菜',
  ];

  late final _nameCtrl =
      TextEditingController(text: widget.member?.name ?? '');
  late final _wordCtrl = TextEditingController();
  late List<String> _allergens = [...?widget.member?.allergens];
  late List<String> _dislikes = [...?widget.member?.dislikes];
  late int _avatar = widget.member?.avatar ?? 0;

  /// 重名提示就地挂在称呼框下面，不用 SnackBar：
  /// 弹层盖着页面时，页面 Scaffold 的提示条要么被遮要么压在弹层外面看不见。
  String? _nameError;

  /// 正在编辑哪一组：'allergy' / 'dislike'。两组的词是不同性质的东西，
  /// 合成一个输入框就会有人把"不吃香菜"填进过敏里。
  String _target = 'allergy';

  @override
  void dispose() {
    _nameCtrl.dispose();
    _wordCtrl.dispose();
    super.dispose();
  }

  List<String> get _pool => _target == 'allergy' ? _allergens : _dislikes;

  void _addWord(String w) {
    final t = w.trim();
    if (t.isEmpty) return;
    setState(() {
      final list = _target == 'allergy' ? _allergens : _dislikes;
      if (!list.contains(t)) {
        if (_target == 'allergy') {
          _allergens = [..._allergens, t];
        } else {
          _dislikes = [..._dislikes, t];
        }
      }
      _wordCtrl.clear();
    });
  }

  void _removeWord(String w) {
    setState(() {
      if (_target == 'allergy') {
        _allergens = _allergens.where((e) => e != w).toList();
      } else {
        _dislikes = _dislikes.where((e) => e != w).toList();
      }
    });
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return; // 保存按钮此时是禁用的；这里只是兜底
    final store = StoreScope.of(context);
    if (store.memberNameTaken(name, exceptId: widget.member?.id)) {
      setState(() => _nameError = '已经有位「$name」了');
      return;
    }
    if (widget.member == null) {
      await store.createMember(
          name: name,
          allergens: _allergens,
          dislikes: _dislikes,
          avatar: _avatar);
    } else {
      await store.updateMember(widget.member!.id,
          name: name,
          allergens: _allergens,
          dislikes: _dislikes,
          avatar: _avatar);
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final member = widget.member;
    if (member == null) return;
    final store = StoreScope.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${member.name}」？'),
        content: Text(member.totalRestrictions == 0
            ? '删除后这位家人不再参与过敏原判断。'
            : '这位家人名下 ${member.totalRestrictions} 项过敏原与忌口会一并停用，菜谱上的警示随之消失。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await store.deleteMember(member.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final zj = context.zj;
    final nameEmpty = _nameCtrl.text.trim().isEmpty;
    return Padding(
      key: const ValueKey('member-sheet'),
      padding: EdgeInsets.fromLTRB(20, 4, 20, 24 + MediaQuery.of(context).viewInsets.bottom),
      // 与餐次弹层同一套：内容包在 SingleChildScrollView 里。
      // 常见词 + 已填词 + 头像行加起来比一屏高，不滚的话保存按钮会被
      // 顶到屏幕外（真机上就是"填完了却点不到保存"）。
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Text(widget.member == null ? '添加家人' : '编辑「${widget.member!.name}」',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('member-name'),
            controller: _nameCtrl,
            style: TextStyle(fontSize: 14, color: zj.ink),
            decoration: InputDecoration(
              labelText: '称呼',
              errorText: _nameError,
              isDense: true,
              filled: true,
              fillColor: zj.surface,
            ),
            onChanged: (_) {
              // 每次改字都要 setState：保存按钮的可点状态看的是这个文本，
              // 只在有报错时才刷新的话，名字填好了按钮还是灰的
              setState(() => _nameError = null);
            },
          ),
          const SizedBox(height: 12),
          Text('头像色', style: TextStyle(fontSize: 12, color: zj.muted)),
          const SizedBox(height: 6),
          Row(
            children: [
              for (var i = 0; i < avatarColors(context).length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => setState(() => _avatar = i),
                    child: AvatarChip(
                      name: _nameCtrl.text.trim().isEmpty
                          ? '?'
                          : String.fromCharCode(_nameCtrl.text.trim().runes.first),
                      index: i,
                      ring: _avatar == i,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),
          // 两组分开填：过敏走警告、忌口走提示，混成一列就等于把警告降级
          Row(
            children: [
              for (final e in const [('allergy', '过敏'), ('dislike', '不吃')])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    key: ValueKey('member-target-${e.$1}'),
                    label: Text(e.$2),
                    selected: _target == e.$1,
                    onSelected: (_) => setState(() => _target = e.$1),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('member-word'),
                  controller: _wordCtrl,
                  style: TextStyle(fontSize: 14, color: zj.ink),
                  decoration: InputDecoration(
                    hintText: _target == 'allergy' ? '如 虾 / 贝类 / 花生' : '如 香菜 / 苦瓜',
                    isDense: true,
                    filled: true,
                    fillColor: zj.surface,
                  ),
                  onSubmitted: _addWord,
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filledTonal(
                key: const ValueKey('member-word-add'),
                onPressed: () => _addWord(_wordCtrl.text),
                icon: const Icon(Icons.add, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text('常见', style: TextStyle(fontSize: 11.5, color: zj.muted)),
          const SizedBox(height: 5),
          Wrap(
            spacing: 6,
            runSpacing: 5,
            children: [
              for (final w in _suggested)
                if (!_pool.contains(w))
                  ActionChip(
                    label: Text(w, style: const TextStyle(fontSize: 12)),
                    onPressed: () => _addWord(w),
                  ),
            ],
          ),
          if (_pool.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(_target == 'allergy' ? '已填过敏' : '已填不吃',
                style: TextStyle(fontSize: 11.5, color: zj.muted)),
            const SizedBox(height: 5),
            Wrap(
              key: ValueKey('member-pool-$_target'),
              spacing: 6,
              runSpacing: 5,
              children: [
                for (final w in _pool)
                  InputChip(
                    key: ValueKey('member-word-$w'),
                    label: Text(w, style: const TextStyle(fontSize: 12)),
                    onDeleted: () => _removeWord(w),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              if (widget.member != null)
                TextButton(
                  key: const ValueKey('member-delete'),
                  onPressed: _delete,
                  child: Text('删除', style: TextStyle(color: zj.muted)),
                ),
              const Spacer(),
              FilledButton(
                key: const ValueKey('member-save'),
                onPressed: nameEmpty ? null : _save,
                style:
                    FilledButton.styleFrom(backgroundColor: zj.accent),
                child: const Text('保存'),
              ),
            ],
          ),
          ],
        ),
      ),
    );
  }

}
