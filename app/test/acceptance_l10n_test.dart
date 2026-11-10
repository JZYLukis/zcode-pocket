import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/core/usage_format.dart';
import 'package:zcode_pocket/ui/usage_charts.dart';

void main() {
  tearDown(L10n.resetForTest);

  test('英文动态参数在拼接前完成本地化，不出现半翻译', () {
    L10n.setTestLocale('en-US');
    expect(tr(formatTokens(400000)), '400K');
    expect(tr(formatTokens(1200000)), '1.2M');
    expect(formatDurationMs(3600000), '1 hr');
    expect(formatDurationMs(2520000), '42 min');
    expect(formatDurationMs(3723000), '1 hr 2 min');
    expect(formatBillingCycle('monthly'), 'Monthly');
    expect(tr('重置${tr('5 小时')}？'), 'Reset 5 hours?');
    expect(
      L10n.resolvedLocale == 'en-US'
          ? '${tr('活跃度统计')} (${tr('近 30 天')})'
          : '${tr('活跃度统计')}（${tr('近 30 天')}）',
      'Activity stats (Last 30 days)',
    );

    final detail = linePointDetailLine(
      date: '2026-10-26',
      index: 1,
      series: [
        ChartSeries(
          name: 'glm-5.3',
          color: const Color(0xFF000000),
          values: [800000, 1200000],
        ),
        ChartSeries(
          name: 'k3.1-pro',
          color: const Color(0xFF000001),
          values: [200000, 400000],
        ),
      ],
      formatter: formatTokens,
    );
    expect(detail, 'Oct 26 · Total 1.6M\nglm-5.3 1.2M, k3.1-pro 400K');
    expect(detail.contains('万'), isFalse);

    final day = barDayDetailLine(
      date: '2026-10-26',
      total: 1700000,
      topModels: const [
        (name: 'glm-5.3', tokens: 1200000),
        (name: 'k3.1-pro', tokens: 400000),
      ],
      formatter: formatTokens,
    );
    expect(day, 'Oct 26 · Total 1.7M\nglm-5.3 1.2M, k3.1-pro 400K');
  });

  test('中文明细排版保持日期合计一行、模型拆分一行', () {
    L10n.setTestLocale('zh-CN');
    final detail = linePointDetailLine(
      date: '2026-10-26',
      index: 1,
      series: [
        ChartSeries(
          name: 'glm-5.3',
          color: const Color(0xFF000000),
          values: [800000, 1200000],
        ),
      ],
      formatter: formatTokens,
    );
    expect(detail, '10月26日 · 共 120万\nglm-5.3 120万');
  });
}
