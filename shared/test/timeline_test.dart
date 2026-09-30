import 'package:test/test.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

/// R48 · 时间线（FR-LOG-01）的排序 / 分组 / 过滤与「没有的时刻」。
///
/// 这一套钉的全是**决策**，不是格式：
/// ① 菜单事件没有创建时刻 → 显示「全天」，且它落在那天**最后**（不是最早）；
/// ② `created_at` 为空/脏 → 这条事件根本不该存在（不猜日子，日历上也不许多一个点）；
/// ③ 同刻两条不许在刷新之间互换位置（Dart 的 `List.sort` 不稳定，这里靠原序 tie-break）；
/// ④ 分段过滤器必须真的改条数（只切按下态的过滤器是装饰）。
void main() {
  TimelineItem cook(String day, String time, String name, {int? minutes}) =>
      TimelineItem(
        day: day,
        time: time,
        kind: TimelineKind.cook,
        title: name,
        detail: minutes == null ? '' : '实际耗时 $minutes 分钟',
        refId: 'r-$name',
      );
  TimelineItem menu(String day, String meal) =>
      TimelineItem(day: day, kind: TimelineKind.menu, title: meal, refId: 'm-$meal');
  TimelineItem added(String day, String time, String name) => TimelineItem(
      day: day, time: time, kind: TimelineKind.recipe, title: name, refId: 'r-$name');

  group('没有的时刻', () {
    test('★ 菜单事件没有时刻：时间位是「全天」，不是 00:00 也不是空白', () {
      final m = menu('2026-09-17', '晚餐');
      expect(m.time, isEmpty, reason: '空串 = 没有这个事实，和 00:00 是两回事');
      expect(timelineTimeLabel(m), '全天');
    });

    test('★ 无时刻的那条排在当天最后（当成 00:00 就会跑到当天最前）', () {
      final sorted = timelineSorted([
        menu('2026-09-17', '晚餐'),
        cook('2026-09-17', '08:00', '早餐粥'),
        cook('2026-09-17', '21:30', '葱油拌面'),
      ]);
      expect(sorted.map((e) => e.title).toList(), ['葱油拌面', '早餐粥', '晚餐']);
    });

    test('同一天里两条菜单事件彼此保持取数顺序', () {
      final sorted = timelineSorted([
        menu('2026-09-19', '午餐'),
        menu('2026-09-18', '早餐'),
        menu('2026-09-19', '晚餐'),
      ]);
      expect(
        sorted.where((e) => e.day == '2026-09-19').map((e) => e.title).toList(),
        ['午餐', '晚餐'],
      );
    });
  });

  group('不猜日子', () {
    test('★ created_at 为空 / 脏值 / 太短 → 日期是 null（这条事件因此不存在）', () {
      expect(timelineDayOf(''), isNull);
      expect(timelineDayOf('2026-09'), isNull, reason: '长度不够，不补一个"月初"糊上去');
      expect(timelineDayOf('unknown'), isNull);
      expect(timelineDayOf('2026/09/16'), isNull, reason: '形状不对就不认，不顺手换分隔符');
      expect(timelineDayOf('2026-13-05'), isNull, reason: '没有 13 月');
      expect(timelineDayOf('2026-09-32'), isNull, reason: '没有 32 日');
    });

    test('ISO8601 与纯日期两种写法都认，取前 10 位', () {
      expect(timelineDayOf('2026-09-16T20:15:00.123'), '2026-09-16');
      expect(timelineDayOf('2026-09-16'), '2026-09-16');
    });

    test('★ 时刻取不到是空串（= 没有时刻），不是 00:00', () {
      expect(timelineTimeOf('2026-09-16T20:15:00'), '20:15');
      expect(timelineTimeOf('2026-09-16'), '');
      expect(timelineTimeOf('2026-09-16XX:XX'), '', reason: '形状不对就当没有');
    });
  });

  group('排序与分组', () {
    test('★ 日期倒序：新的一天在前', () {
      final sorted = timelineSorted([
        cook('2026-09-14', '19:20', '番茄炒蛋'),
        cook('2026-09-17', '21:30', '葱油拌面'),
        cook('2026-09-15', '18:45', '蒜蓉粉丝蒸虾'),
      ]);
      expect(sorted.map((e) => e.day).toList(),
          ['2026-09-17', '2026-09-15', '2026-09-14']);
    });

    test('同日按时刻倒序（晚上在前，夜宵不会掉到早上后面）', () {
      final sorted = timelineSorted([
        cook('2026-09-17', '07:30', '早点'),
        cook('2026-09-17', '22:40', '夜宵'),
        cook('2026-09-17', '12:10', '午饭'),
      ]);
      expect(sorted.map((e) => e.time).toList(), ['22:40', '12:10', '07:30']);
    });

    test('★ 同一分钟两条不抖：Dart 的 sort 不稳定，这里必须按原序 tie-break', () {
      final a = cook('2026-09-17', '18:45', '蒜蓉粉丝蒸虾');
      final b = cook('2026-09-17', '18:45', '蚝油生菜');
      for (final input in [
        [a, b],
        [b, a],
      ]) {
        final out = timelineSorted(input).map((e) => e.title).toList();
        expect(out, input.map((e) => e.title).toList(),
            reason: '输入顺序不同就该输出不同顺序；被排成同一序说明丢了原序，列表会抖');
      }
    });

    test('分组：组间倒序、组内保序，一天一组不多不少', () {
      final days = timelineGrouped(timelineSorted([
        cook('2026-09-16', '22:40', '银耳莲子羹'),
        menu('2026-09-17', '晚餐'),
        cook('2026-09-17', '21:30', '葱油拌面'),
        added('2026-09-16', '20:15', '蒜蓉粉丝蒸虾'),
      ]));
      expect(days.map((d) => d.day).toList(), ['2026-09-17', '2026-09-16']);
      expect(days.first.items.map((e) => e.title).toList(), ['葱油拌面', '晚餐']);
      expect(days.last.items.map((e) => e.title).toList(), ['银耳莲子羹', '蒜蓉粉丝蒸虾']);
    });

    test('空列表：排序、分组、日历点三处都是空，不抛', () {
      expect(timelineSorted(const []), isEmpty);
      expect(timelineGrouped(const []), isEmpty);
      expect(timelineMarks(const []), isEmpty);
    });
  });

  group('分段过滤器', () {
    final all = [
      cook('2026-09-17', '21:30', '葱油拌面'),
      menu('2026-09-17', '晚餐'),
      added('2026-09-16', '20:15', '蒜蓉粉丝蒸虾'),
      cook('2026-09-16', '22:40', '银耳莲子羹'),
    ];

    test('★ 每种过滤都必须真的改条数（只切按下态的过滤器是装饰）', () {
      expect(timelineFiltered(all).length, 4);
      expect(timelineFiltered(all, kind: TimelineKind.cook).length, 2);
      expect(timelineFiltered(all, kind: TimelineKind.menu).length, 1);
      expect(timelineFiltered(all, kind: TimelineKind.recipe).length, 1);
      for (final k in TimelineKind.values) {
        final one = timelineFiltered(all, kind: k);
        expect(one.every((e) => e.kind == k), isTrue, reason: k.name);
        expect(one.length, lessThan(all.length), reason: '筛完还全量等于没筛');
      }
    });

    test('筛完仍然排序（过滤不许把倒序弄乱）', () {
      final out = timelineFiltered(all, kind: TimelineKind.cook);
      expect(out.map((e) => e.day).toList(), ['2026-09-17', '2026-09-16']);
    });

    test('类型字符串认不出是 null，不猜成某一类', () {
      expect(timelineKindOf('cook'), TimelineKind.cook);
      expect(timelineKindOf('menu'), TimelineKind.menu);
      expect(timelineKindOf('recipe'), TimelineKind.recipe);
      expect(timelineKindOf('shopping'), isNull);
      expect(timelineKindOf(''), isNull);
    });

    test('三个字的说法只有一份（徽标与过滤器共用）', () {
      expect(timelineKindLabel(TimelineKind.cook), '做菜');
      expect(timelineKindLabel(TimelineKind.menu), '菜单');
      expect(timelineKindLabel(TimelineKind.recipe), '菜品');
    });
  });

  group('日历的点与时间线同源', () {
    test('★ 日历画的日期集合 == 时间线出现的日期集合', () {
      final marks = timelineMarks(timelineSorted([
        cook('2026-09-15', '18:45', '蒜蓉粉丝蒸虾'),
        menu('2026-09-17', '晚餐'),
        added('2026-09-15', '20:15', '新菜'),
      ]));
      expect(marks.keys.toSet(), {'2026-09-15', '2026-09-17'});
      expect(marks['2026-09-15'], [TimelineKind.cook, TimelineKind.recipe]);
      expect(marks['2026-09-17'], [TimelineKind.menu]);
    });

    test('同一天同类型只记一个点（做两道菜不该画两个圈）', () {
      final marks = timelineMarks([
        cook('2026-09-15', '18:45', 'A'),
        cook('2026-09-15', '18:47', 'B'),
      ]);
      expect(marks['2026-09-15'], [TimelineKind.cook]);
    });
  });

  group('日期头文字', () {
    test('今天那组写「今天」，其余写 09/17', () {
      expect(timelineDayLabel('2026-09-17', today: '2026-09-17'), '今天');
      expect(timelineDayLabel('2026-09-16', today: '2026-09-17'), '09/16');
    });

    test('★ 不读 DateTime.now()：today 由调用方给（纯函数才能做真重载回归）', () {
      expect(timelineDayLabel('2026-09-17'), '09/17', reason: '没给 today 就不该自称今天');
    });

    test('短串原样返回，不越界截', () {
      expect(timelineDayLabel('9-17'), '9-17');
    });
  });

  group('耗时读数', () {
    test('< 60 只写分钟，不硬凑小时', () {
      expect(timelineDurationLabel(0), '0 分钟');
      expect(timelineDurationLabel(1), '1 分钟');
      expect(timelineDurationLabel(14), '14 分钟');
      expect(timelineDurationLabel(59), '59 分钟');
    });

    test('★ ≥ 60 转小时：966 分钟那趟是 16 小时 6 分，不是 966 分钟', () {
      // 真机走查量到的：会话挂了一夜，数字是真的但没人读得动。
      expect(timelineDurationLabel(60), '1 小时');
      expect(timelineDurationLabel(61), '1 小时 1 分');
      expect(timelineDurationLabel(90), '1 小时 30 分');
      expect(timelineDurationLabel(966), '16 小时 6 分');
    });

    test('整点不补「0 分」', () {
      expect(timelineDurationLabel(120), '2 小时');
      expect(timelineDurationLabel(1440), '24 小时');
    });

    test('★ 挂钟倒流（改系统时间/跨时区）画不出负数', () {
      expect(timelineDurationLabel(-30), '0 分钟');
    });
  });
}
