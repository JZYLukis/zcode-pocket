/// 通用重试退避（批次 1，2026-10-19 外部审查）：失败后的下次尝试
/// 间隔 = 1min → 2min → 4min → 封顶 5min。
///
/// 用法约定：调用方保留自身的"新鲜判据"与"在途守卫"，本函数只叠加
/// 失败时间戳维度（回归防护 7.1：不动 stale 判定与守卫结构）。
library;

Duration backoffAfterFailures(int failCount) {
  // failCount<=0 无失败不退避；1,2,4 之后封顶 5。failCount≥63 时 1<<62
  // 起溢出（Dart 64 位 int 位移回绕为负/0，clamp 后错得 1 分钟）——
  // 先行封顶保证语义恒为 5（需连续失败 4h+，纯边界）。
  final minutes = failCount <= 0
      ? 0
      : failCount >= 4
          ? 5
          : (1 << (failCount - 1)).clamp(1, 5);
  return Duration(minutes: minutes);
}

/// 额度快照是否应重拉（conversation_page 配额横幅）：
/// - 新鲜判据（原样保留）：loadedAt 距 now ≤10min 不拉；
/// - 失败退避（新增）：上次尝试失败后，距 lastAttemptAt 不足退避间隔
///   不再拉——原实现失败即复位 loading，最坏每次状态通知都重试一次。
bool entitlementShouldReload({
  required DateTime now,
  DateTime? loadedAt,
  DateTime? lastAttemptAt,
  int failCount = 0,
}) {
  final fresh = loadedAt != null &&
      now.difference(loadedAt) <= const Duration(minutes: 10);
  if (fresh) return false;
  if (failCount > 0 && lastAttemptAt != null) {
    if (now.difference(lastAttemptAt) < backoffAfterFailures(failCount)) {
      return false;
    }
  }
  return true;
}
