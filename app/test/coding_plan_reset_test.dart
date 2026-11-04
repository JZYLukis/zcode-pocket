import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/coding_plan_reset.dart';

/// 套餐「重置额度」纯逻辑（2026-10-26 用户："手机端现在是看不见重置的"）
/// ——解析/倒计时/徽标文案/幂等键四件。通道四方法（status/use/opportunity/
/// markHistoryRead）已在协议矩阵登记；WebView/真机旅程无——纯通道 RPC。
void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(1_800_000_000_000);

  group('parseCodingPlanResetStatus（通道 camelCase 快照）', () {
    test('两类机会解析；形状不符按空处理', () {
      final s = CodingPlanResetStatus.parse({
        'availableFiveHourResets': [
          {'expireAt': 1800000100000},
          {'expireAt': 1800000200000},
        ],
        'availableWeekResets': [
          {'expireAt': 1800500000000},
        ],
        'latestFiveHourResetHistory': null,
        'hasUnreadHistory': false,
      });
      expect(s.fiveHourCount, 2);
      expect(s.weekCount, 1);
      expect(s.totalCount, 3);
      expect(s.soonestExpireAt, 1800000100000);
    });

    test('畸形载荷（非数组/缺字段/元素残缺）→ 空状态不抛', () {
      for (final bad in [
        <String, dynamic>{},
        {'availableFiveHourResets': 'oops'},
        {'availableFiveHourResets': [null, 42, {}]},
      ]) {
        final s = CodingPlanResetStatus.parse(bad);
        expect(s.hasAny, isFalse, reason: '载荷 $bad');
      }
    });
  });

  group('formatResetCountdown（官方 zh-CN 四档措辞逐字）', () {
    test('天时/天/时分/时/分秒/秒 六形态', () {
      expect(formatResetCountdown(2 * 86400 + 3 * 3600 + 120), '2 天 3 小时');
      expect(formatResetCountdown(2 * 86400), '2 天');
      expect(formatResetCountdown(3 * 3600 + 5 * 60), '3 小时 5 分');
      expect(formatResetCountdown(3 * 3600), '3 小时');
      expect(formatResetCountdown(5 * 60 + 9), '5 分 9 秒');
      expect(formatResetCountdown(42), '42 秒');
    });

    test('负数钳 0', () {
      expect(formatResetCountdown(-5), '0 秒');
    });
  });

  group('resetBadgeLabel / resetRowSubtitle（官方徽标措辞）', () {
    test('多机会=获得 N 次；单机会=次数+剩余倒计时', () {
      final multi = CodingPlanResetStatus(
        fiveHourExpireAts: [now.millisecondsSinceEpoch + 90 * 1000],
        weekExpireAts: [now.millisecondsSinceEpoch + 86400000],
      );
      expect(resetBadgeLabel(multi, now), '获得2次重置额度');

      final single = CodingPlanResetStatus(
        fiveHourExpireAts: [now.millisecondsSinceEpoch + 90 * 1000],
        weekExpireAts: const [],
      );
      expect(resetBadgeLabel(single, now), '1 次重置额度 · 剩余 1 分 30 秒');

      expect(
        resetBadgeLabel(const CodingPlanResetStatus(fiveHourExpireAts: [], weekExpireAts: []), now),
        '',
      );
    });

    test('弹层行副标题=次数+最快过期', () {
      expect(
        resetRowSubtitle(2, [
          now.millisecondsSinceEpoch + 86400000,
          now.millisecondsSinceEpoch + 3 * 3600 * 1000,
        ], now),
        '2 次 · 最快 3 小时后过期',
      );
      expect(resetRowSubtitle(0, const [], now), '0 次');
    });
  });

  test('幂等键：UUIDv4 形态、64 字符上限内、两次生成不重复', () {
    final r = Random(42);
    final a = createResetIdempotencyKey(r, now);
    final b = createResetIdempotencyKey(r, now);
    expect(a, isNot(b));
    expect(a, matches(RegExp(r'^[0-9a-z-]+$')),
        reason: 'hex 主体+base36 时间戳后缀（官方 fallback 同构，全小写）');
    expect(a.length, lessThan(64));
    expect(a.split('-').length, greaterThanOrEqualTo(5));
  });
}
