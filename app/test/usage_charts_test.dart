import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/usage_charts.dart';

ChartSeries _s(String name, List<double> v) => ChartSeries(
      name: name,
      color: const Color(0xFF2563EB),
      values: v,
    );

BarChartPainter _bar(List<double> values, {int? selectedIndex}) =>
    BarChartPainter(
      values: values,
      xLabels: const ['2026-10-17', '2026-10-18', '2026-10-19'],
      valueFormatter: (n) => '$n',
      labelStyle: const TextStyle(fontSize: 10),
      barColor: const Color(0xFF16A34A),
      selectedIndex: selectedIndex,
      selectedColor: const Color(0xFF262626),
      gridColor: const Color(0x1A0D0D0D),
      textScaler: TextScaler.noScaling,
    );

LineChartPainter _line(List<ChartSeries> series) => LineChartPainter(
      series: series,
      xLabels: const ['2026-10-17', '2026-10-18', '2026-10-19'],
      valueFormatter: (n) => '$n',
      labelStyle: const TextStyle(fontSize: 10),
      gridColor: const Color(0x1A0D0D0D),
      textScaler: TextScaler.noScaling,
    );

void main() {
  group('A6 柱状图 shouldRepaint（原实现为长度比较，同天数数据刷新漏重绘）', () {
    // 批3 复扫 B-1：Bar 颜色族回归靶（55c55e8 修复当时漏配靶，与 Line 对称）。
    test('柱图颜色参数变化（barColor/selectedColor/gridColor/labelStyle）：重绘', () {
      BarChartPainter mk(Color c1, Color c2, Color c3, TextStyle st) =>
          BarChartPainter(
            values: const [1, 2, 3],
            xLabels: const ['d1', 'd2', 'd3'],
            valueFormatter: (n) => '$n',
            barColor: c1,
            selectedColor: c2,
            gridColor: c3,
            labelStyle: st,
            textScaler: TextScaler.noScaling,
          );
      final base = mk(const Color(0xFF16A34A), const Color(0xFF262626),
          const Color(0x1A0D0D0D), const TextStyle(fontSize: 10));
      expect(base.shouldRepaint(mk(const Color(0xFF46BF72),
              const Color(0xFF262626), const Color(0x1A0D0D0D),
              const TextStyle(fontSize: 10))), isTrue,
          reason: 'barColor 变化须重绘');
      expect(base.shouldRepaint(mk(const Color(0xFF16A34A),
              const Color(0xFFD4D4D4), const Color(0x1A0D0D0D),
              const TextStyle(fontSize: 10))), isTrue,
          reason: 'selectedColor 变化须重绘');
      expect(base.shouldRepaint(mk(const Color(0xFF16A34A),
              const Color(0xFF262626), const Color(0x1AFFFFFF),
              const TextStyle(fontSize: 10))), isTrue,
          reason: 'gridColor 变化须重绘');
      expect(base.shouldRepaint(mk(const Color(0xFF16A34A),
              const Color(0xFF262626), const Color(0x1A0D0D0D),
              const TextStyle(fontSize: 10, color: Color(0xFFD4D4D4)))), isTrue,
          reason: 'labelStyle 变化须重绘');
      expect(base.shouldRepaint(mk(const Color(0xFF16A34A),
              const Color(0xFF262626), const Color(0x1A0D0D0D),
              const TextStyle(fontSize: 10))), isFalse,
          reason: '全等不重绘');
    });

    test('同长度不同值：必须重绘（修复主断言）', () {
      // 旧谓词 `old.values.length != values.length` 对此返回 false——
      // 图表停留旧数据，本断言钉死该回归口。
      expect(_bar([1, 2, 3]).shouldRepaint(_bar([1, 2, 4])), isTrue);
    });

    test('等值（不同实例）：不重绘', () {
      expect(_bar([1, 2, 3]).shouldRepaint(_bar([1, 2, 3])), isFalse);
    });

    test('长度变化：重绘', () {
      expect(_bar([1, 2, 3]).shouldRepaint(_bar([1, 2])), isTrue);
    });
  });

  group('A6 折线图 shouldRepaint（原实现引用比较=恒重绘，改值比较）', () {
    test('等值不同实例：不重绘', () {
      expect(
        _line([_s('a', [1, 2, 3])]).shouldRepaint(_line([_s('a', [1, 2, 3])])),
        isFalse,
      );
    });

    test('值变化：重绘', () {
      expect(
        _line([_s('a', [1, 2, 3])]).shouldRepaint(_line([_s('a', [1, 2, 5])])),
        isTrue,
      );
    });

    // 深色模式批1 对抗审查路A2 A-1 回归靶：labelStyle/gridColor 随主题
    // 变化（数据不变）必须重绘，否则深浅切换图表标签残留旧主题色。
    test('颜色参数变化（labelStyle/gridColor/主题切换）：重绘', () {
      final a = LineChartPainter(
        series: [_s('a', [1, 2, 3])],
        xLabels: const ['d1', 'd2', 'd3'],
        valueFormatter: (n) => '$n',
        labelStyle: const TextStyle(fontSize: 10, color: Color(0xFF262626)),
        gridColor: const Color(0x1A0D0D0D),
        textScaler: TextScaler.noScaling,
      );
      final b = LineChartPainter(
        series: [_s('a', [1, 2, 3])],
        xLabels: const ['d1', 'd2', 'd3'],
        valueFormatter: (n) => '$n',
        labelStyle: const TextStyle(fontSize: 10, color: Color(0xFFD4D4D4)),
        gridColor: const Color(0x1AFFFFFF),
        textScaler: TextScaler.noScaling,
      );
      expect(a.shouldRepaint(b), isTrue);
    });

    test('序列增减：重绘', () {
      expect(
        _line([_s('a', [1]), _s('b', [2])])
            .shouldRepaint(_line([_s('a', [1])])),
        isTrue,
      );
    });
  });

  group('A6 环形图 shouldRepaint', () {
    test('等值不同实例：不重绘', () {
      expect(
        DonutPainter(series: [_s('a', [3]), _s('b', [7])])
            .shouldRepaint(DonutPainter(series: [_s('a', [3]), _s('b', [7])])),
        isFalse,
      );
    });

    test('份额变化：重绘', () {
      expect(
        DonutPainter(series: [_s('a', [3]), _s('b', [7])])
            .shouldRepaint(DonutPainter(series: [_s('a', [4]), _s('b', [6])])),
        isTrue,
      );
    });
  });

  group('ChartSeries 值相等', () {
    test('name/color/values 逐项相等即相等', () {
      expect(_s('a', [1, 2]), _s('a', [1, 2]));
      expect(_s('a', [1, 2]).hashCode, _s('a', [1, 2]).hashCode);
      expect(_s('a', [1, 2]), isNot(_s('a', [1, 3])));
      expect(_s('a', [1, 2]), isNot(_s('b', [1, 2])));
    });
  });

  group('BarChartPainter selectedIndex shouldRepaint', () {
    test('选中变化：重绘', () {
      expect(
        _bar([1, 2, 3], selectedIndex: 1).shouldRepaint(_bar([1, 2, 3])),
        isTrue,
      );
      expect(
        _bar([1, 2, 3], selectedIndex: 1)
            .shouldRepaint(_bar([1, 2, 3], selectedIndex: 2)),
        isTrue,
      );
    });

    test('选中不变：不重绘', () {
      expect(
        _bar([1, 2, 3], selectedIndex: 1)
            .shouldRepaint(_bar([1, 2, 3], selectedIndex: 1)),
        isFalse,
      );
    });
  });

  group('barHitIndex（slot=width/n，与 painter 同款公式）', () {
    test('slot 边界：首柱含 dx=0；dx=slot 落入次柱', () {
      // width=300、n=3 → slot=100。
      expect(barHitIndex(0, 300, 3), 0);
      expect(barHitIndex(99.9, 300, 3), 0);
      expect(barHitIndex(100, 300, 3), 1);
      expect(barHitIndex(299.9, 300, 3), 2);
    });

    test('越界钳制：负 dx → 首柱；超宽 dx → 末柱', () {
      expect(barHitIndex(-5, 300, 3), 0);
      expect(barHitIndex(350, 300, 3), 2);
      expect(barHitIndex(1e9, 300, 3), 2);
    });

    test('n<=0 或宽<=0 → null', () {
      expect(barHitIndex(10, 300, 0), isNull);
      expect(barHitIndex(10, 0, 3), isNull);
      expect(barHitIndex(10, -1, 3), isNull);
    });
  });

  group('chartDayLabel（M月d日，不补零）', () {
    test('yyyy-MM-dd → M月d日（含带时间后缀）', () {
      expect(chartDayLabel('2026-10-18'), '10月18日');
      expect(chartDayLabel('2026-01-05'), '1月5日');
      expect(chartDayLabel('2026-10-18T00:00:00Z'), '10月18日');
    });

    test('非日期原样返回', () {
      expect(chartDayLabel('n/a'), 'n/a');
      expect(chartDayLabel(''), '');
    });
  });

  group('柱图明细文案 barDayDetailLine / barRangeTotalText', () {
    String fmt(num n) => '<$n>';
    test('日期 + 总量 + top 模型（、连接）', () {
      expect(
        barDayDetailLine(
          date: '2026-10-18',
          total: 123,
          topModels: const <({String name, num tokens})>[
            (name: 'glm-4.7', tokens: 100),
            (name: 'glm-4.6', tokens: 23),
          ],
          formatter: fmt,
        ),
        '10月18日 · 共 <123>\nglm-4.7 <100>、glm-4.6 <23>',
      );
    });

    test('无模型 → 只有日期与总量', () {
      expect(
        barDayDetailLine(
          date: '2026-10-18',
          total: 0,
          topModels: const [],
          formatter: fmt,
        ),
        '10月18日 · 共 <0>',
      );
    });

    test('取消选中 → 区间合计', () {
      expect(barRangeTotalText(456, fmt), '区间合计 · 共 <456>');
    });
  });

  group('buildModelPieSlices（官方 appUsageModelPieChartViewModel.ts 范式）', () {
    final palette = List<Color>.generate(5, (i) => Color(0xFF000000 + i));
    final otherColor = const Color(0xFF999999);

    ModelPieData build(List<Map<String, dynamic>> models) =>
        buildModelPieSlices(models, palette: palette, otherColor: otherColor);

    test('零消耗过滤 + 降序 + 切片值=totalTokens 实际量', () {
      final pie = build([
        {'modelId': 'b', 'totalTokens': 20},
        {'modelId': 'a', 'totalTokens': 100},
        {'modelId': 'zero', 'totalTokens': 0},
      ]);
      expect(pie.slices.map((s) => s.name).toList(), ['a', 'b']);
      expect(pie.slices.first.values, [100.0]);
      expect(pie.totalTokens, 120);
    });

    test('6 片不合并；7 片 → 前 5 + "其他"（值=余量和）', () {
      List<Map<String, dynamic>> gen(int n) => List.generate(
            n,
            (i) => {'modelId': 'm$i', 'totalTokens': 10.0 * (i + 1)},
          );
      final p6 = build(gen(6));
      expect(p6.slices.length, 6);
      expect(p6.slices.any((s) => s.name == '其他'), isFalse);

      final p7 = build(gen(7));
      expect(p7.slices.length, 6);
      final otherSlice = p7.slices.last;
      expect(otherSlice.name, '其他');
      // 降序后余量=最小的两片：m1(20) + m0(10)。
      expect(otherSlice.values.first, 20.0 + 10.0);
      expect(p7.totalTokens, 280);
    });

    test('占比按过滤后总量重算（其他 = 余量和/过滤后总量）', () {
      final pie = build([
        for (var i = 0; i < 7; i++) {'modelId': 'm$i', 'totalTokens': 10.0},
      ]);
      // 全等值 7 片：前 5 片各 10，其他 = 20；总量 70 → 其他占比 2/7。
      expect(pie.slices.last.values.first / pie.totalTokens, closeTo(20 / 70, 1e-9));
    });

    test('modelId null/空白 → "未知"；全零 → 空切片', () {
      final pie = build([
        {'modelId': null, 'totalTokens': 5},
        {'modelId': '  ', 'totalTokens': 3},
      ]);
      expect(pie.slices.map((s) => s.name), everyElement('未知'));
      expect(
        build([
          {'modelId': 'a', 'totalTokens': 0},
        ]).slices,
        isEmpty,
      );
    });
  });

  // ── 2026-10-23 用户反馈批①：图表可点选（折线/饼图/热力图）─────────
  group('批① donutHitIndex（角度弧段+环带判定）', () {
    final slices = [
      _s('a', [100]), // -90° 起 120°：正上→右下
      _s('b', [200]), // 其余 240°
    ];
    test('右方点（0°）命中第一片', () {
      // size 150 高：center(75,75)，radius=69，stroke 18。取半径 69 右侧。
      final p = Offset(75 + 69, 75);
      expect(donutHitIndex(p, const Size(150, 150), slices), 0);
    });
    test('正下方点（90°）命中第二片', () {
      final p = Offset(75, 75 + 69);
      expect(donutHitIndex(p, const Size(150, 150), slices), 1);
    });
    test('中心空洞/环外远点不命中', () {
      expect(donutHitIndex(const Offset(75, 75), const Size(150, 150), slices), isNull);
      expect(donutHitIndex(const Offset(2, 2), const Size(150, 150), slices), isNull);
    });
  });

  group('批① 折线点选', () {
    test('linePointHitIndex 与柱状同式', () {
      expect(linePointHitIndex(0, 300, 3), 0);
      expect(linePointHitIndex(150, 300, 3), 1);
      expect(linePointHitIndex(299, 300, 3), 2);
      expect(linePointHitIndex(10, 300, 0), isNull);
    });
    test('linePointDetailLine 含日期/合计/各序列值', () {
      final t = linePointDetailLine(
        date: '2026-10-18',
        index: 1,
        series: [_s('glm-4.7', [10, 8000, 1]), _s('glm-4.6', [0, 562, 1])],
        formatter: (n) => n.round().toString(),
      );
      expect(t, '10月18日 · 共 8562\nglm-4.7 8000、glm-4.6 562');
    });
    test('lineRangeTotal 全点求和', () {
      expect(lineRangeTotal([_s('a', [1, 2]), _s('b', [3, 4])]), 10);
    });
    test('LineChartPainter 点选参数变化应重绘', () {
      final a = LineChartPainter(
        series: [_s('a', [1, 2])], xLabels: const ['d1', 'd2'],
        valueFormatter: (n) => '$n',
        labelStyle: const TextStyle(fontSize: 10),
        gridColor: const Color(0x1A0D0D0D),
        textScaler: TextScaler.noScaling,
      );
      final b = LineChartPainter(
        series: [_s('a', [1, 2])], xLabels: const ['d1', 'd2'],
        valueFormatter: (n) => '$n',
        labelStyle: const TextStyle(fontSize: 10),
        gridColor: const Color(0x1A0D0D0D),
        selectedIndex: 1,
        selectedColor: const Color(0xFF262626),
        textScaler: TextScaler.noScaling,
      );
      expect(a.shouldRepaint(b), isTrue);
    });
  });

  group('批① DonutPainter', () {
    test('DonutPainter selectedIndex 变化应重绘', () {
      final a = DonutPainter(series: [_s('a', [1])]);
      final b = DonutPainter(series: [_s('a', [1])], selectedIndex: 0);
      expect(a.shouldRepaint(b), isTrue);
      expect(a.shouldRepaint(DonutPainter(series: [_s('a', [1])])), isFalse);
    });
    // heatDayDetailLine 已随生产代码删除（ N1 P3-2：18074
    // 结构化明细卡替代后全仓零调用的死代码）。
  });
}
