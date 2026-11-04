import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/usage_format.dart';

/// ③用量页纯函数层（对照 refs/ZCode codingPlanQuotaPresentation 官方口径）。
void main() {
  group('findQuotaLimit（官方 TOKEN/CREDIT 等价集合 + unit/number 匹配）', () {
    final limits = [
      {'type': 'TOKENS_LIMIT', 'unit': 3, 'number': 5, 'percentage': 23},
      {'type': 'TOKENS_LIMIT', 'unit': 6, 'percentage': 40},
      {'type': 'TIME_LIMIT', 'percentage': 42},
      {'type': 'OTHER', 'unit': 3, 'number': 5},
    ];
    test('5 小时窗口：TOKENS_LIMIT unit3 number5', () {
      final l = findQuotaLimit(limits, tokenKind: true, unit: 3, number: 5);
      expect(l?['type'], 'TOKENS_LIMIT');
      expect(l?['unit'], 3);
    });
    test('zai CREDIT_LIMIT 与 TOKENS_LIMIT 等价命中', () {
      final zai = [
        {'type': 'CREDIT_LIMIT', 'unit': 3, 'number': 5, 'percentage': 10},
      ];
      expect(findQuotaLimit(zai, tokenKind: true, unit: 3, number: 5),
          isNotNull);
    });
    test('每周窗口：unit6 不带 number', () {
      final l = findQuotaLimit(limits, tokenKind: true, unit: 6);
      expect(l?['unit'], 6);
    });
    test('工具调用：TIME_LIMIT', () {
      final l = findQuotaLimit(limits, tokenKind: false);
      expect(l?['type'], 'TIME_LIMIT');
    });
    test('OTHER 类型不参与 token 匹配', () {
      final l = findQuotaLimit(limits, tokenKind: true, unit: 3, number: 99);
      expect(l, isNull);
    });
  });

  group('quotaRemainingPercent（percentage=已用占比 → 剩余反转）', () {
    test('已用 23% → 剩余 77%（示例数值）', () {
      expect(
        quotaRemainingPercent({'percentage': 23}),
        closeTo(77, 0.01),
      );
    });
    test('缺失/非数值 → 0', () {
      expect(quotaRemainingPercent(null), 0);
      expect(quotaRemainingPercent({}), 0);
    });
    test('越界钳制', () {
      expect(quotaRemainingPercent({'percentage': 130}), 0);
      expect(quotaRemainingPercent({'percentage': -5}), 100);
    });
  });

  group('quotaUsageFraction', () {
    test('官方口径 currentValue=已用 / usage=总量（示例 425/1000）', () {
      final f = quotaUsageFraction({
        'usage': 1000,
        'currentValue': 425,
        'number': 1,
      });
      expect(f, isNotNull);
      expect(f!.$1, '425');
      expect(f.$2, '1000');
    });
    test('总量缺失/为 0（5h 窗口只有百分比）→ null', () {
      expect(quotaUsageFraction({'percentage': 25}), isNull);
      expect(quotaUsageFraction({'usage': 0, 'currentValue': 0}), isNull);
    });
  });

  group('formatTokens', () {
    test('亿/万/整数', () {
      expect(formatTokens(2150000000), '21.5亿');
      expect(formatTokens(85620000), '8562万');
      expect(formatTokens(999), '999');
    });

    test('9.7 亿不会被格式化成 9 亿（时区归桶才是问题根因）', () {
      expect(formatTokens(969950049), '9.7亿');
      expect(formatTokens(918630614), '9.2亿');
      expect(formatTokens(900000000), '9亿');
      expect(formatTokens(100000000), '1亿');
    });
  });

  group('formatDurationMs', () {
    test('11 小时 45 分钟（示例）', () {
      expect(formatDurationMs((11 * 60 + 45) * 60000), '11 小时 45 分钟');
    });
    test('分钟级与不足 1 分钟', () {
      expect(formatDurationMs(42 * 60000), '42 分钟');
      expect(formatDurationMs(30000), '不足 1 分钟');
    });
  });

  group('formatResetTime（官方 adaptive：当日 HH:mm）', () {
    test('非当日 → MM-dd HH:mm', () {
      final t = DateTime.now().subtract(const Duration(days: 1));
      final s = formatResetTime(t.millisecondsSinceEpoch);
      expect(s, matches(RegExp(r'^\d{2}-\d{2} \d{2}:\d{2}$')));
    });
    test('非法输入 → 空', () {
      expect(formatResetTime(null), '');
      expect(formatResetTime('x'), '');
    });
  });

  group('formatPlanName（官方 bigmodelUsageQuotaMapper.ts:81-84）', () {
    test('level 非空 → GLM Coding + 首字母大写其余小写', () {
      expect(formatPlanName(level: 'pro', productName: 'x'), 'GLM Coding Pro');
      expect(formatPlanName(level: 'PRO'), 'GLM Coding Pro');
      expect(formatPlanName(level: 'Max'), 'GLM Coding Max');
    });
    test('level 空 → productName 原样回退（不加前缀）', () {
      expect(
        formatPlanName(level: null, productName: 'GLM Coding Lite'),
        'GLM Coding Lite',
      );
      expect(formatPlanName(level: ' ', productName: 'Lite 计划'), 'Lite 计划');
    });
    test('两者皆空 → null', () {
      expect(formatPlanName(level: null, productName: null), isNull);
      expect(formatPlanName(level: '', productName: ''), isNull);
      expect(formatPlanName(level: '', productName: ' '), isNull);
    });
  });

  group('formatBillingCycle（常见值中文映射，未知原样）', () {
    test('monthly/quarterly/yearly', () {
      expect(formatBillingCycle('monthly'), '按月');
      expect(formatBillingCycle('quarterly'), '按季');
      expect(formatBillingCycle('yearly'), '按年');
    });
    test('未知值原样；空/非字符串 → 空', () {
      expect(formatBillingCycle('weekly'), 'weekly');
      expect(formatBillingCycle(''), '');
      expect(formatBillingCycle(null), '');
      expect(formatBillingCycle(3), '');
    });
  });

  group('formatSubscriptionDate（ISO string / 毫秒时间戳双兼容）', () {
    test('ISO 字符串 → 截取 yyyy-MM-dd', () {
      expect(formatSubscriptionDate('2026-11-01T00:00:00Z'), '2026-11-01');
      expect(formatSubscriptionDate('2026-11-01'), '2026-11-01');
    });
    test('毫秒时间戳（num / 数字串）→ 本地 yyyy-MM-dd', () {
      final ms = DateTime(2026, 10, 20, 12).millisecondsSinceEpoch;
      expect(formatSubscriptionDate(ms), startsWith('2026-10-2'));
      expect(formatSubscriptionDate('$ms'), startsWith('2026-10-2'));
    });
    test('空/非法/伪时间戳 → 空', () {
      expect(formatSubscriptionDate(null), '');
      expect(formatSubscriptionDate(''), '');
      expect(formatSubscriptionDate('x'), '');
      // 8 位压缩日期不是毫秒时间戳，不得误当 epoch 解析。
      expect(formatSubscriptionDate('20261101'), '');
    });
  });

  group('subscriptionDetailLines（官方 details[] 载体 + 徽标命名规则）', () {
    final sub = {
      'details': [
        {
          'productName': 'Pro 套餐(年付)',
          'billingCycle': 'yearly',
          'renewTime': '2026-11-01T00:00:00Z',
          'expireTime': '2026-11-01T00:00:00Z',
        },
        {'productName': 'Lite Plan', 'billingCycle': 'monthly',
            'expireTime': '2026-12-01'},
        {'productName': 'Third', 'billingCycle': 'quarterly'},
      ],
    };
    test('首条 level 命名 + 周期 + 续费/到期；多条取前 2；报告总数', () {
      final r = subscriptionDetailLines('pro', sub);
      expect(r.lines.length, 2);
      expect(r.totalCount, 3);
      expect(r.lines[0], 'GLM Coding Pro · 按年 · 续费 2026-11-01 · 到期 2026-11-01');
      expect(r.lines[1], 'Lite Plan · 按月 · 到期 2026-12-01');
    });
    test('level 空 → 首条回退 productName 原样', () {
      final r = subscriptionDetailLines(null, sub);
      expect(r.lines[0], startsWith('Pro 套餐(年付)'));
    });
    test('details 缺失 → 顶层 renewTime/expireTime + level 兜底（旧行为保留）', () {
      final r = subscriptionDetailLines(
        'pro',
        {'renewTime': '2027-01-01T00:00:00Z', 'expireTime': '2027-01-01'},
      );
      expect(r.lines, ['GLM Coding Pro · 续费 2027-01-01 · 到期 2027-01-01']);
    });
    test('全空 → 空行（订阅行不渲染）', () {
      expect(subscriptionDetailLines(null, {}).lines, isEmpty);
      expect(subscriptionDetailLines(null, {'details': []}).lines, isEmpty);
      expect(subscriptionDetailLines('pro', {'details': []}).totalCount, 1);
    });
  });
}
