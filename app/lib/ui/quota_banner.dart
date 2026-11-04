import 'package:flutter/material.dart' hide Text;
import '../core/localized_text.dart';

import '../core/theme.dart';

/// 配额横幅（阶段 3 第三段，对照官方 sessionQuotaBannerState.ts /
/// startPlanQuotaBuckets.ts 的手机端实现；2026-10-24 修复批 PF-1 补
/// 官方总门、reminderKey 有效性与模型过滤）。
///
/// 官方语义要点：
/// - 总门（sessionQuotaBannerState.ts:205-211）：仅 Start Plan 套餐
///   （account:zai-start-plan / account:bigmodel-start-plan）且快照
///   provider.id 与会话活跃 provider 一致才走桶式横幅——Coding Pro 的
///   quota 载荷（TIME_LIMIT/TOKENS_LIMIT）被整路拦截，耗尽红条与低额
///   琥珀条共用此门；
/// - 桶过滤（getActiveModelBuckets）：meter 缺省或 model_usage，且时间
///   窗有效（nextResetTime>now ‖ 缺省；periodStart<=now ‖ 缺省；
///   periodEnd>now ‖ 缺省），now = serverTime ?? generatedAt；
/// - 比例 = remaining/number（number>0），否则 percentage 回退——不能拿
///   available（预占后额度）当剩余；
/// - 全桶耗尽（remaining 全 ≤0，未知值不当 0）→ 不可关闭的耗尽横幅；
/// - 低额度提醒仅对匹配当前模型的桶（bucketMatchesModel）且 reminderKey
///   有效（bucketId 非空+周期有限，官方 bucketReminderKey），0<比例≤10%
///   （sessionQuotaBannerState.ts:243-253）。

class QuotaBannerState {
  final bool exhausted;
  final String bucketId;
  final int periodStart;
  final int periodEnd;
  final double ratio; // 低额度桶的剩余比例（exhausted 时无意义）
  final int? reminderExpiresAt; // 去重到期=min(periodEnd, nextResetTime)，快照时间毫秒
  final int? referenceTime; // 与桶有效性一致的快照时间——去重判据不信任设备时钟

  const QuotaBannerState({
    required this.exhausted,
    required this.bucketId,
    required this.periodStart,
    required this.periodEnd,
    this.ratio = 0,
    this.reminderExpiresAt,
    this.referenceTime,
  });

  /// 官方 reminderKey=[bucketId, periodStart, periodEnd]（去重键）。
  String get reminderKey => '$bucketId/$periodStart/$periodEnd';
}

/// 官方 BUILTIN_MODEL_PROVIDER_IDS 的 Start Plan 两家
/// （model-provider-types.ts:10-13；isStartPlanModelProviderId:43-48）。
const _startPlanProviderIds = {
  'account:zai-start-plan',
  'account:bigmodel-start-plan',
};

bool _finite(num? v) => v is num && v.isFinite;

/// 两类载荷口径差异（PF-1 复核注；逻辑=官方 bucketRemainingRatio 逐字
/// 对齐，不动）：Start Plan 桶的 remaining/number 与 percentage 回退都是
/// 0-1 剩余比例；Coding Pro quota 接口的 percentage 是 0-100 已用占比
/// （官方 usage-quota.ts:69-72"展示端负责反转"）——口径相反，但被
/// provider 总门挡在桶扫描之外，永不进入本函数。
double? _remainingRatio(Map bucket) {
  final remaining = bucket['remaining'];
  final number = bucket['number'];
  if (_finite(remaining) &&
      _finite(number) &&
      number > 0 &&
      remaining is num &&
      number is num) {
    return remaining / number;
  }
  final pct = bucket['percentage'];
  return _finite(pct) ? (pct as num).toDouble() : null;
}

/// 官方 normalizeQuotaModel（startPlanQuotaBuckets.ts:3-9）。
String _normalizeQuotaModel(String v) => v
    .trim()
    .toLowerCase()
    .replaceFirst(RegExp('^model:'), '')
    .replaceAll('_', '-');

/// 官方 bucketMatchesModel（startPlanQuotaBuckets.ts:11-15）。
bool _bucketMatchesModel(Map bucket, String modelId) {
  final details = bucket['usageDetails'];
  if (details is! List) return false;
  final target = _normalizeQuotaModel(modelId);
  if (target.isEmpty) return false;
  return details.any(
    (d) =>
        d is Map && _normalizeQuotaModel('${d['modelCode'] ?? ''}') == target,
  );
}

/// 官方 bucketReminderKey 的有效性判据（startPlanQuotaBuckets.ts:52-63）：
/// bucketId 非空 + 周期有限且起止合法；无效键的桶不出低额提醒
/// （TOKENS_LIMIT 类无 bucketId 载荷在此被拦）。
bool _hasValidReminderKey(Map b) {
  final bucketId = (b['bucketId'] ?? '').toString().trim();
  final ps = b['periodStart'];
  final pe = b['periodEnd'];
  if (bucketId.isEmpty || !_finite(ps) || !_finite(pe)) return false;
  return (ps as num) >= 0 && (pe as num) > ps;
}

/// 纯函数：从 entitlement 快照推导横幅状态（无横幅=null）。
/// [activeProviderId]=会话活跃 provider（config.provider）；
/// [modelId]=会话当前模型（缺省时官方语义=不出低额提醒）。
QuotaBannerState? buildQuotaBannerState(
  Map<String, dynamic>? snapshot, {
  String? activeProviderId,
  String? modelId,
}) {
  if (snapshot == null) return null;
  // 官方总门：仅 Start Plan 家族，且快照与会话活跃 provider 一致
  // （sessionQuotaBannerState.ts:205-211 早退）。
  final provider = snapshot['provider'];
  final snapshotProviderId =
      provider is Map ? (provider['id'] ?? '').toString() : '';
  final active = (activeProviderId ?? '').toString();
  if (active.isEmpty || !_startPlanProviderIds.contains(active)) return null;
  if (snapshotProviderId != active) return null;
  final quota = snapshot['quota'];
  if (quota is! Map) return null;
  final limits = quota['limits'];
  if (limits is! List || limits.isEmpty) return null;
  final nowRaw = snapshot['serverTime'] ?? snapshot['generatedAt'];
  final now = _finite(nowRaw) ? (nowRaw as num).toInt() : null;

  final buckets = <Map>[];
  for (final b in limits) {
    if (b is! Map) continue;
    final meter = '${b['meter'] ?? ''}';
    if (meter.isNotEmpty && meter != 'model_usage') continue;
    if (now != null) {
      final nextReset = b['nextResetTime'];
      if (_finite(nextReset) && (nextReset as num) <= now) continue;
      final ps = b['periodStart'];
      if (_finite(ps) && (ps as num) > now) continue;
      final pe = b['periodEnd'];
      if (_finite(pe) && (pe as num) <= now) continue;
    }
    buckets.add(b);
  }
  if (buckets.isEmpty) return null;

  var allExhausted = true;
  for (final b in buckets) {
    final remaining = b['remaining'];
    final ratio = _remainingRatio(b);
    if (_finite(remaining)) {
      if ((remaining as num) > 0) allExhausted = false;
    } else if (ratio == null || ratio > 0) {
      allExhausted = false;
    }
  }
  if (allExhausted) {
    return QuotaBannerState(
      exhausted: true,
      bucketId: '',
      periodStart: 0,
      periodEnd: 0,
    );
  }
  // 低额度提醒（官方 sessionQuotaBannerState.ts:243-268）：仅匹配当前
  // 模型的桶、reminderKey 有效、0<比例≤10%；取首个命中（官方顺序）。
  final model = (modelId ?? '').toString().trim();
  if (model.isEmpty) return null;
  for (final b in buckets) {
    if (!_bucketMatchesModel(b, model)) continue;
    final ratio = _remainingRatio(b);
    if (ratio == null || ratio <= 0 || ratio > 0.1) continue;
    if (!_hasValidReminderKey(b)) continue;
    var expiresAt = (b['periodEnd'] as num?)?.toInt() ?? 0;
    final nrt = b['nextResetTime'];
    if (_finite(nrt)) {
      final e = (nrt as num).toInt();
      if (e < expiresAt) expiresAt = e;
    }
    return QuotaBannerState(
      exhausted: false,
      bucketId: (b['bucketId'] ?? '').toString().trim(),
      periodStart: (b['periodStart'] as num?)?.toInt() ?? 0,
      periodEnd: (b['periodEnd'] as num?)?.toInt() ?? 0,
      ratio: ratio,
      reminderExpiresAt: expiresAt,
      referenceTime: now,
    );
  }
  return null;
}

/// 横幅本体：耗尽（红、不可关）/ 低额度（琥珀、可关，按官方按桶周期去重）。
class QuotaBanner extends StatelessWidget {
  final QuotaBannerState state;
  final Set<String> dismissedKeys;
  final VoidCallback onDismiss;

  const QuotaBanner({
    super.key,
    required this.state,
    required this.dismissedKeys,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    if (!state.exhausted && dismissedKeys.contains(state.reminderKey)) {
      return const SizedBox.shrink();
    }
    final destructive = state.exhausted;
    final color = destructive ? context.colors.destructive : context.colors.warning;
    final percent = (state.ratio * 100).round();
    return Container(
      key: ValueKey(
        destructive ? 'quota-banner-exhausted' : 'quota-banner-low',
      ),
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: AppAlpha.light),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: color.withValues(alpha: AppAlpha.mid)),
      ),
      child: Row(
        children: [
          Icon(
            destructive ? Icons.block_outlined : Icons.battery_2_bar,
            size: 15,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              destructive
                  ? '当前账户额度已用完——发送可能失败，升级或调整套餐后继续'
                  : '套餐额度剩余 $percent%（低额度提醒）',
              style: TextStyle(
                fontSize: AppType.uiCaption,
                color: context.colors.foregroundSubtle,
              ),
            ),
          ),
          if (!destructive)
            // 批次4 触控目标（2026-10-19 审查）：15×15 裸 InkWell → IconButton
            // （ripple+tooltip 无障碍标签）。
            // 批次A（设计审计 6.3）：44→48——外层 tight SizedBox 会压掉
            // IconButton 默认 48 最小盒（批次4 注释"自带最小交互尺寸"的认知
            // 只在不加 tight 约束时成立），去掉 tight 约束即恢复。
            IconButton(
              padding: EdgeInsets.zero,
              iconSize: 16,
              tooltip: tr('关闭额度提醒'),
              onPressed: onDismiss,
              icon: Icon(
                Icons.close,
                size: 15,
                color: context.colors.foregroundSubtlest,
              ),
            ),
        ],
      ),
    );
  }
}
