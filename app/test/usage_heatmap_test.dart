// 热力图几何回归（问题② 2026-10-25 真机实锤）：触控命中盒扩到 22px
// （B4）后，外层 SizedBox 高仍按视觉格 11px 计（94.5），实际内容
// 7×(22+2.5)=171.5——横向滚动视图不裁纵向溢出，格子盖到下方明细行
// 与后续区块。修复=容器高按命中盒计。本测试锁死「内容高 == 容器高」。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/usage_charts.dart' show buildModelTrendSeries;
import 'package:zcode_pocket/ui/usage_page.dart';

Map<String, dynamic> _heatmap(int weeks) => {
      'startDate': '2026-09-13',
      'endDate': '2026-10-18',
      'maxTokens': 398765432,
      'weeks': [
        for (var w = 0; w < weeks; w++)
          {
            'weekIndex': w,
            'days': [
              for (var d = 0; d < 7; d++)
                (w + d) % 11 == 0 && d == 6
                    ? null
                    : {
                        'date': '2026-10-$d',
                        'level': (w + d) % 5,
                        'totalTokens': 1000,
                        'turnCount': 2,
                        'toolCallCount': 1,
                      },
            ],
          },
      ],
    };

Future<void> _pump(WidgetTester tester, Map<String, dynamic> heatmap) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 390,
          child: UsageHeatmapView(heatmap),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('热力图不纵向溢出（应用用量 5 周形态）', (tester) async {
    await _pump(tester, _heatmap(5));
    // 修复前：7 行 22px 命中盒挤进 94.5px 盒子 → RenderFlex overflow 异常。
    expect(tester.takeException(), isNull,
        reason: '热力图内容不得纵向溢出容器');
    final grid = tester.renderObject<RenderBox>(
      find.byType(SingleChildScrollView).first,
    );
    // 容器高 = 命中盒 22×7 + 缝 2.5×7 = 171.5（按视觉格 11 计的 94.5 是
    // 修复前的错误值）。
    expect(grid.size.height, closeTo(171.5, 0.1));
    final contentRow = tester.renderObject<RenderBox>(find.byType(Row).first);
    expect(contentRow.size.width, 390,
        reason: '少周数热力图必须铺满可用宽度，不再只占左侧');
  });

  testWidgets('热力图不纵向溢出（个人套餐 53 周形态，横向滚动）',
      (tester) async {
    await _pump(tester, _heatmap(53));
    expect(tester.takeException(), isNull);
    final grid = tester.renderObject<RenderBox>(
      find.byType(SingleChildScrollView).first,
    );
    expect(grid.size.height, closeTo(171.5, 0.1));
    // 53 周内容宽超出视口 → 横向可滚（这是设计行为，非溢出）。
    expect(
      tester.renderObject<RenderBox>(find.byType(Row).first).size.width,
      greaterThan(390),
    );
  });

  testWidgets('空周数据：降级提示不溢出', (tester) async {
    await _pump(tester, {
      'startDate': null,
      'endDate': null,
      'maxTokens': 0,
      'weeks': [],
    });
    expect(tester.takeException(), isNull);
    expect(find.text('暂无活动数据'), findsOneWidget);
  });

  testWidgets('点选格子出明细行且不遮挡（命中盒 22 触达）', (tester) async {
    await _pump(tester, _heatmap(5));
    // 点首列首格（offset 在格子中心）→ 选中描边 + 明细行文案出现。
    await tester.tap(
      find.byType(GestureDetector).first,
      warnIfMissed: false,
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('轮'), findsOneWidget,
        reason: '明细行应显示「N 轮 · N 次工具调用」格式');
  });

  testWidgets('无用量格=可辨识淡灰（不再与背景融合，②a 2026-10-26）',
      (tester) async {
    await _pump(tester, _heatmap(5));
    // 夹具 level=(w+d)%5：必有 0 级格；null 空格也在。二者都应渲染为
    // 非透明的淡灰底（修复前 0 级=深色近背景/空格=全透明）。
    final decorations = tester
        .widgetList<Container>(find.byType(Container))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.borderRadius == BorderRadius.circular(2))
        .toList();
    expect(decorations.length, greaterThan(0), reason: '格子容器在场');
    for (final d in decorations) {
      expect(
        d.color,
        isNotNull,
        reason: '无用量格不得透明（深色模式下与背景融合=不可见，真机实锤）',
      );
      expect(d.color!.a, greaterThan(0), reason: '格子底色非全透明');
    }
  });

  testWidgets('初始滚动停在最右（最近几天可见，②b 2026-10-26）',
      (tester) async {
    await _pump(tester, _heatmap(53));
    await tester.pump(const Duration(milliseconds: 50));
    final scroll = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(SingleChildScrollView).first,
        matching: find.byType(Scrollable),
      ),
    );
    expect(scroll.position.maxScrollExtent, greaterThan(0),
        reason: '53 周必有横向余量');
    expect(
      scroll.position.pixels,
      closeTo(scroll.position.maxScrollExtent, 0.1),
      reason: '时间轴左旧右新——默认应见最近用量（修复前停最左）',
    );
  });

  testWidgets('档位切换：总用量/按模型两档（2026-11-04 拍板；协议无来源档）',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360, // 窄屏：验证切换条不溢出
            child: UsageHeatmapView(
              _heatmap(2),
              dailyModelUsage: [
                {
                  'date': '2026-10-1',
                  'models': [
                    {'modelId': 'glm-5.3', 'totalTokens': 900000},
                    {'modelId': 'k3.1-pro', 'totalTokens': 300000},
                  ],
                },
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 两档在场且默认总用量选中；来源档不伪造（协议无字段）。
    expect(find.byKey(const ValueKey('heat-mode-total')), findsOneWidget);
    expect(find.byKey(const ValueKey('heat-mode-model')), findsOneWidget);
    expect(find.byKey(const ValueKey('heat-mode-source')), findsNothing);
    expect(find.text('色=当日用量最高模型'), findsNothing, reason: '总用量档不显示模型图例');

    await tester.tap(find.byKey(const ValueKey('heat-mode-model')));
    await tester.pump();
    expect(find.text('色=当日用量最高模型'), findsOneWidget,
        reason: '按模型档显示图例说明');
    expect(tester.takeException(), isNull, reason: '窄屏切换不得溢出');
  });

  testWidgets('点选日明细带按模型拆分（拍板④，dailyModelUsage 传入）',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: UsageHeatmapView(
              _heatmap(2),
              dailyModelUsage: [
                {
                  // 夹具日期形如 2026-10-<d>（首格 d=0 → 2026-10-0）。
                  'date': '2026-10-0',
                  'models': [
                    {'modelId': 'glm-5.3', 'totalTokens': 900000},
                    {'modelId': 'k3.1-pro', 'totalTokens': 300000},
                  ],
                },
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // 夹具首格 date=2026-10-1、level=(0+0)%5=0——点它出明细+模型行。
    await tester.tap(find.byType(GestureDetector).first,
        warnIfMissed: false);
    await tester.pump();
    expect(find.textContaining('glm-5.3'), findsOneWidget,
        reason: '当日按模型明细行在场（top3）');
    expect(find.textContaining('k3.1-pro'), findsOneWidget);
  });

  test('按模型趋势序列构建（拍板④B，官方 Top6 对位）', () {
    final built = buildModelTrendSeries(
      models: [
        {'modelId': 'glm-5.3', 'totalTokens': 100},
        {'modelId': 'k3.1-pro', 'totalTokens': 50},
        {'modelId': null, 'totalTokens': 10},
      ],
      dailyModelUsage: [
        {
          'date': '10-01',
          'models': [
            {'modelId': 'glm-5.3', 'totalTokens': 60},
            {'modelId': 'k3.1-pro', 'totalTokens': 20},
          ],
        },
        {
          'date': '10-02',
          'models': [
            {'modelId': 'glm-5.3', 'totalTokens': 40},
          ],
        },
      ],
      palette: const [Color(0xFF0000FF), Color(0xFF00FF00)],
    );
    expect(built.dates, ['10-01', '10-02']);
    expect(built.series.length, 3, reason: '全部 >0 模型入列（≤6）');
    expect(built.series.first.name, 'glm-5.3', reason: '按总量降序');
    expect(built.series.first.values, [60.0, 40.0]);
    expect(built.series[1].values, [20.0, 0.0], reason: '缺日补 0');
    expect(built.series[2].color, const Color(0xFF0000FF),
        reason: '色板循环（第 3 个回绕第 1 色）');
    expect(built.legend.first.total, 100);
  });
}
