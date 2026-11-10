import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/usage_charts.dart';
import 'package:zcode_pocket/ui/usage_page.dart';

void main() {
  testWidgets('每日 Token 柱图：真实点按回调选中下标', (tester) async {
    int? tapped;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            child: UsageBarChartView(
              values: const [10, 20, 30],
              xLabels: const ['2026-10-24', '2026-10-25', '2026-10-26'],
              valueFormatter: (v) => '$v',
              selectedIndex: 0,
              onBarTap: (i) => tapped = i,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(UsageBarChartView));
    expect(tapped, isNotNull, reason: '柱图必须能被点中');
    expect(tapped, 1);
  });

  testWidgets('按模型趋势折线：真实点按回调选中下标', (tester) async {
    int? tapped;
    final series = [
      ChartSeries(
        name: 'glm',
        color: const Color(0xFF0B7FFF),
        values: const [1, 2, 3],
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 300,
            child: UsageLineChartView(
              series: series,
              xLabels: const ['2026-10-24', '2026-10-25', '2026-10-26'],
              valueFormatter: (v) => '$v',
              selectedIndex: 0,
              onPointTap: (i) => tapped = i,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(UsageLineChartView));
    expect(tapped, isNotNull, reason: '折线图必须能被点中');
    expect(tapped, 1);
  });
}
