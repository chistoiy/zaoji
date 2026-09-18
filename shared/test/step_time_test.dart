import 'package:test/test.dart';
import 'package:zaoji_shared/zaoji_shared.dart';

void main() {
  group('parseStepTimes · 基础识别', () {
    test('阿拉伯数字 + 双字单位', () {
      final hits = parseStepTimes('小火炖 20 分钟');
      expect(hits, hasLength(1));
      expect(hits.first.text, '20 分钟');
      expect(hits.first.suggestedSeconds, 1200);
    });

    test('无空格紧凑写法', () {
      final hits = parseStepTimes('中火炒40秒');
      expect(hits, hasLength(1));
      expect(hits.first.text, '40秒');
      expect(hits.first.suggestedSeconds, 40);
    });

    test('小时', () {
      final hits = parseStepTimes('加盖焖 1 小时');
      expect(hits, hasLength(1));
      expect(hits.first.suggestedSeconds, 3600);
    });

    test('中文数字', () {
      final hits = parseStepTimes('煮五分钟');
      expect(hits, hasLength(1));
      expect(hits.first.text, '五分钟');
      expect(hits.first.suggestedSeconds, 300);
    });

    test('半', () {
      final hits = parseStepTimes('再炖半个小时');
      expect(hits, hasLength(1));
      expect(hits.first.suggestedSeconds, 1800);
    });

    test('量词不能挡住数值（回归用例）', () {
      // 「再炖半个小时」曾经返回空：向左回看到「个」就断了，
      // 而「半个 小时」是中文菜谱里最自然的写法之一。
      expect(parseStepTimes('再炖半个小时').first.suggestedSeconds, 1800);
      expect(parseStepTimes('炖三个钟头').first.suggestedSeconds, 10800);
      expect(parseStepTimes('焖2个半小时').first.suggestedSeconds, 9000);
    });

    test('小数', () {
      final hits = parseStepTimes('小火煨 1.5 小时');
      expect(hits, hasLength(1));
      expect(hits.first.suggestedSeconds, 5400);
    });

    test('全角数字（中文输入法高频）', () {
      final hits = parseStepTimes('炖２０分钟');
      expect(hits, hasLength(1));
      expect(hits.first.suggestedSeconds, 1200);
    });
  });

  group('parseStepTimes · 区间', () {
    test('半角连字符', () {
      final hits = parseStepTimes('炖 5-6 分钟');
      expect(hits, hasLength(1));
      expect(hits.first.isRange, isTrue);
      expect(hits.first.minSeconds, 300);
      expect(hits.first.maxSeconds, 360);
      // 区间取上限：做菜宁多勿少，提前关火容易，糊了没法救
      expect(hits.first.suggestedSeconds, 360);
      expect(hits.first.text, '5-6 分钟');
    });

    test('波浪号', () {
      final hits = parseStepTimes('小火 30～40 分钟');
      expect(hits.first.minSeconds, 1800);
      expect(hits.first.maxSeconds, 2400);
    });

    test('「到」字连接', () {
      final hits = parseStepTimes('煮 10 到 15 分钟');
      expect(hits.first.minSeconds, 600);
      expect(hits.first.maxSeconds, 900);
      expect(hits.first.text, '10 到 15 分钟');
    });

    test('区间文字标签', () {
      final hits = parseStepTimes('炖 5-6 分钟');
      expect(hits.first.label, '5 分钟–6 分钟');
    });
  });

  group('parseStepTimes · 复合时长', () {
    test('小时 + 分钟应合并为一颗胶囊', () {
      final hits = parseStepTimes('小火炖 1 小时 30 分钟');
      // 关键：不合并的话用户会看到两颗胶囊，点哪个都不对——他要的是 90 分钟
      expect(hits, hasLength(1));
      expect(hits.first.suggestedSeconds, 5400);
      expect(hits.first.text, '1 小时 30 分钟');
    });

    test('顿号分隔也能合并', () {
      final hits = parseStepTimes('焖 2 小时、10 分钟');
      expect(hits, hasLength(1));
      expect(hits.first.suggestedSeconds, 7800);
    });

    test('句子中间的停顿不该被合并', () {
      final hits = parseStepTimes('先焯水 2 分钟，再大火收汁 30 秒');
      expect(hits, hasLength(2));
      expect(hits[0].text, '2 分钟');
      expect(hits[1].text, '30 秒');
    });
  });

  group('parseStepTimes · 误判防护（错了比漏了更糟）', () {
    test('「三分之一个」不是 3 分钟', () {
      expect(parseStepTimes('放三分之一个洋葱'), isEmpty);
    });

    test('「八成熟」不是时间', () {
      expect(parseStepTimes('油温七成热，八成熟悉后捞出判断'), isEmpty);
    });

    test('只有温度没有时间时不误报', () {
      final hits = parseStepTimes('180 度烤 20 分钟');
      expect(hits, hasLength(1));
      expect(hits.first.text, '20 分钟');
    });

    test('「至」前面没有数字时不影响', () {
      final hits = parseStepTimes('泡 30 分钟至 1 小时');
      expect(hits, hasLength(2));
      expect(hits[0].text, '30 分钟');
      expect(hits[1].text, '1 小时');
    });

    test('空文本与无时间文本', () {
      expect(parseStepTimes(''), isEmpty);
      expect(parseStepTimes('翻炒均匀后装盘'), isEmpty);
    });
  });

  group('parseStepTimes · 区间索引可用于高亮', () {
    test('索引精确且原文未被改写', () {
      const src = '小火炖 20 分钟至软烂';
      final hits = parseStepTimes(src);
      expect(hits, hasLength(1));
      expect(hits.first.start, 4);
      expect(hits.first.end, 9);
      expect(src.substring(hits.first.start, hits.first.end), '20 分钟');
    });

    test('紧凑写法索引正确', () {
      const src = '炖20分钟';
      final hits = parseStepTimes(src);
      expect(hits.first.start, 1);
      expect(hits.first.end, 5);
      expect(src.substring(1, 5), '20分钟');
    });

    test('多次命中互不重叠且顺序正确', () {
      const src = '先炒 30 秒，再炖 20 分钟，最后收汁 5 分钟';
      final hits = parseStepTimes(src);
      expect(hits.map((h) => h.text).toList(), ['30 秒', '20 分钟', '5 分钟']);
      for (var i = 1; i < hits.length; i++) {
        expect(hits[i].start, greaterThanOrEqualTo(hits[i - 1].end));
      }
    });

    test('全角数字的索引仍映射回原文', () {
      const src = '炖２０分钟';
      final hits = parseStepTimes(src);
      expect(src.substring(hits.first.start, hits.first.end), '２０分钟');
    });

    test('★ 数字与量词之间有空格时，区间必须把数字一起圈进去', () {
      // 这一条是给前端做高亮用的，踩过一次：
      // 「再焖 1 个半小时」被圈成「个半小时」——数字 1 落在胶囊外面，
      // 界面上显示成「1 [个半小时]」。
      // 更糟的是**时长也错了**：回看时只拿到「个半」，
      // 数值解析器又容忍了那个孤零零的「个」并返回 0.5，
      // 于是 90 分钟被静默算成 30 分钟。差 3 倍且不报错。
      const src = '再焖 1 个半小时';
      final hits = parseStepTimes(src);
      expect(hits, hasLength(1));
      expect(src.substring(hits.first.start, hits.first.end), '1 个半小时');
      expect(hits.first.suggestedSeconds, 5400, reason: '1.5 小时 = 5400 秒');
    });

    test('★ 各种「N 个半」写法的区间与时长', () {
      // 区间必须以数字开头 —— 胶囊圈不住数字的话，用户看到的是一句断掉的话
      const cases = {
        '焖2个半小时': ('2个半小时', 9000),
        '再焖 1 个半小时': ('1 个半小时', 5400),
        '两个半小时': ('两个半小时', 9000),
        '炖半个小时': ('半个小时', 1800),
        '炖 1.5 小时': ('1.5 小时', 5400),
      };
      cases.forEach((src, expected) {
        final hits = parseStepTimes(src);
        expect(hits, hasLength(1), reason: src);
        expect(src.substring(hits.first.start, hits.first.end), expected.$1, reason: src);
        expect(hits.first.suggestedSeconds, expected.$2, reason: src);
      });
    });

    test('跨空格回看不会把上一句的数字也吞进来', () {
      // 放宽了跨空格回看之后必须确认没有反向副作用：
      // 「先炒 3 分钟，再炖 20 分钟」里的 3 与 20 不能互相牵连
      const src = '先炒 3 分钟，再炖 20 分钟';
      final hits = parseStepTimes(src);
      expect(hits.map((h) => h.text).toList(), ['3 分钟', '20 分钟']);
      for (final h in hits) {
        expect(src.substring(h.start, h.end), h.text);
      }
    });
  });

  group('hasStepTimes', () {
    test('快速判断', () {
      expect(hasStepTimes('小火炖 20 分钟'), isTrue);
      expect(hasStepTimes('翻炒均匀'), isFalse);
    });
  });
}
