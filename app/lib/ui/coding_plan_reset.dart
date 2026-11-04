import 'dart:math';

import '../core/l10n.dart' show tr;

/// 套餐「重置额度」纯逻辑（2026-10-26 用户："手机端现在是看不见重置的"）
/// ——桌面端 quota-reset 礼包的手机复刻（usage-stats 通道四方法已透出，
/// refs usageStatsService.ts:133-160）。
///
/// 官方语义（packages/shared coding-plan-reset.ts + bigmodelUsageQuotaProvider
/// :78-110）：状态含 5 小时/周两类可用机会（各带 expire_at）、最近使用
/// 历史；使用=消耗一次机会立即重置对应窗口额度（幂等键防重）；机会=
/// 向服务端申领新礼包（服务端有冷却 next_try_at）。
/// 文案逐字对齐官方 zh-CN.ts:4228-4260。

/// 状态快照（getCodingPlanResetStatus 的手机侧模型）。
class CodingPlanResetStatus {
  /// 可用机会的过期时刻（毫秒 epoch）。
  final List<int> fiveHourExpireAts;
  final List<int> weekExpireAts;

  const CodingPlanResetStatus({
    required this.fiveHourExpireAts,
    required this.weekExpireAts,
  });

  int get fiveHourCount => fiveHourExpireAts.length;
  int get weekCount => weekExpireAts.length;
  int get totalCount => fiveHourCount + weekCount;
  bool get hasAny => totalCount > 0;

  /// 两类里最早过期的时刻（无机会为 null）。
  int? get soonestExpireAt {
    final all = [...fiveHourExpireAts, ...weekExpireAts];
    if (all.isEmpty) return null;
    return all.reduce((a, b) => a < b ? a : b);
  }

  /// 通道载荷 → 模型。服务层把 snake_case 映射成 camel 后经通道序列化
  /// （usageStatsService 透传 provider 的 camel 快照）：键为
  /// availableFiveHourResets/availableWeekResets，元素 {expireAt: ms}。
  /// 形状不符按空处理（徽标不显示，比崩溃诚实）。历史/未读位 v1 不消费。
  static CodingPlanResetStatus parse(Map<String, dynamic> data) {
    List<int> expireAts(String key) {
      final raw = data[key];
      if (raw is! List) return const [];
      return [
        for (final e in raw)
          if (e is Map && e['expireAt'] is num) (e['expireAt'] as num).toInt(),
      ];
    }

    return CodingPlanResetStatus(
      fiveHourExpireAts: expireAts('availableFiveHourResets'),
      weekExpireAts: expireAts('availableWeekResets'),
    );
  }
}

/// 倒计时人话（官方 codingPlan.quotaReset.countdown.* 四档措辞逐字）。
String formatResetCountdown(int remainingSeconds) {
  final s = remainingSeconds < 0 ? 0 : remainingSeconds;
  final days = s ~/ 86400;
  final hours = (s % 86400) ~/ 3600;
  final minutes = (s % 3600) ~/ 60;
  final seconds = s % 60;
  if (days > 0) {
    return hours > 0 ? '$days 天 $hours 小时' : '$days 天';
  }
  if (hours > 0) {
    return minutes > 0 ? '$hours 小时 $minutes 分' : '$hours 小时';
  }
  if (minutes > 0) {
    return '$minutes 分 $seconds 秒';
  }
  return '$seconds 秒';
}

/// 徽标文案：官方多机会用 openDialog 固定句「获得{count}次重置额度」，
/// 单机会用 opportunity 句「{count} 次重置额度」+「剩余 {time}」。
String resetBadgeLabel(CodingPlanResetStatus status, DateTime now) {
  if (!status.hasAny) return '';
  final count = status.totalCount;
  if (count > 1) return '获得$count次重置额度';
  final soonest = status.soonestExpireAt!;
  final remaining = (soonest - now.millisecondsSinceEpoch) ~/ 1000;
  // 开源审查 N1 P2-2：倒计时片段拼接前先 tr（pattern 锚点夹在串中间、
  // 占位不递归——预译后整串由 custom pattern 译出）。
  return '$count 次重置额度 · 剩余 ${tr(formatResetCountdown(remaining))}';
}

/// 弹层行副标题：{count} 次 · 最快 {time}后过期（官方 itemCount/expiresInSoonest）。
String resetRowSubtitle(int count, List<int> expireAts, DateTime now) {
  if (count <= 0) return '0 次';
  final soonest = expireAts.reduce((a, b) => a < b ? a : b);
  final remaining = (soonest - now.millisecondsSinceEpoch) ~/ 1000;
  return '$count 次 · 最快 ${tr(formatResetCountdown(remaining))}后过期';
}

/// 幂等键（官方 createIdempotencyKey 同构：UUIDv4 形态，crypto 不可用
/// 则时间戳+随机兜底）。64 字符上限内。
String createResetIdempotencyKey(Random random, DateTime now) {
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}'
      '-${now.millisecondsSinceEpoch.toRadixString(36)}';
}
