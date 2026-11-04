import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/retry_backoff.dart';

void main() {
  group('backoffAfterFailures', () {
    test('1→2→4→封顶 5 分钟', () {
      expect(backoffAfterFailures(1), const Duration(minutes: 1));
      expect(backoffAfterFailures(2), const Duration(minutes: 2));
      expect(backoffAfterFailures(3), const Duration(minutes: 4));
      expect(backoffAfterFailures(4), const Duration(minutes: 5));
      expect(backoffAfterFailures(9), const Duration(minutes: 5));
      expect(backoffAfterFailures(0), Duration.zero);
    });
  });

  group('entitlementShouldReload（A4 退避）', () {
    final now = DateTime(2026, 10, 19, 12, 0, 0);

    test('无快照无失败：立即拉', () {
      expect(entitlementShouldReload(now: now, loadedAt: null), isTrue);
    });

    test('快照 10 分钟内新鲜：不拉（原 stale 判据不动）', () {
      expect(
        entitlementShouldReload(
          now: now,
          loadedAt: now.subtract(const Duration(minutes: 9)),
        ),
        isFalse,
      );
      expect(
        entitlementShouldReload(
          now: now,
          loadedAt: now.subtract(const Duration(minutes: 11)),
        ),
        isTrue,
      );
    });

    test('失败后未到退避间隔：不拉', () {
      expect(
        entitlementShouldReload(
          now: now,
          lastAttemptAt: now.subtract(const Duration(seconds: 30)),
          failCount: 1,
        ),
        isFalse,
      );
      // 第 2 次失败后退避 2 分钟
      expect(
        entitlementShouldReload(
          now: now,
          lastAttemptAt: now.subtract(const Duration(minutes: 1)),
          failCount: 2,
        ),
        isFalse,
      );
    });

    test('失败后退避期满：拉', () {
      expect(
        entitlementShouldReload(
          now: now,
          lastAttemptAt: now.subtract(const Duration(seconds: 61)),
          failCount: 1,
        ),
        isTrue,
      );
      expect(
        entitlementShouldReload(
          now: now,
          lastAttemptAt: now.subtract(const Duration(minutes: 5, seconds: 1)),
          failCount: 9, // 封顶 5min
        ),
        isTrue,
      );
    });

    test('失败但有新鲜快照（近期成功过）：不拉', () {
      expect(
        entitlementShouldReload(
          now: now,
          loadedAt: now.subtract(const Duration(minutes: 3)),
          lastAttemptAt: now.subtract(const Duration(seconds: 10)),
          failCount: 1,
        ),
        isFalse,
      );
    });
  });
}
