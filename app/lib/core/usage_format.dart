/// 用量页纯函数层（③重构，2026-10-17）。
///
/// 全部对照 refs/ZCode 官方实现落地：
/// - 限额查找/百分比反转：packages/ui/src/lib/codingPlanQuotaPresentation.ts
///   （服务端 percentage 为**已使用占比**，展示端须反转为剩余）。
/// - zai team 用 CREDIT_LIMIT、bigmodel 用 TOKENS_LIMIT，二者等价（同文件注释）。
/// - 热力图 levels 0-4：packages/shared/src/usage-stats.ts appUsageHeatmapCellSchema。
library;

import 'l10n.dart';

/// Token/Credit 类配额的等价 type 集合（官方 TOKEN_LIMIT_TYPES）。
const _tokenLimitTypes = {'TOKENS_LIMIT', 'CREDIT_LIMIT'};

/// 工具类配额 type（官方 TOOL_LIMIT_TYPES）。
const _toolLimitTypes = {'TIME_LIMIT'};

Map<String, dynamic>? findQuotaLimit(
  List<dynamic>? limits, {
  required bool tokenKind,
  int? unit,
  int? number,
}) {
  if (limits == null) return null;
  final kinds = tokenKind ? _tokenLimitTypes : _toolLimitTypes;
  for (final raw in limits) {
    if (raw is! Map) continue;
    final type = '${raw['type'] ?? ''}';
    if (!kinds.contains(type)) continue;
    if (unit != null && (raw['unit'] as num?)?.toInt() != unit) continue;
    if (number != null && (raw['number'] as num?)?.toInt() != number) continue;
    return raw.cast<String, dynamic>();
  }
  return null;
}

/// 服务端 percentage=已使用占比 → 剩余占比（官方 getQuotaRemainingPercentage）。
double quotaRemainingPercent(Map<String, dynamic>? limit) {
  final used = (limit?['percentage'] as num?)?.toDouble();
  if (used == null || !used.isFinite) return 0;
  return (100 - used).clamp(0, 100);
}

/// 「已用/总量」展示行（实测定案：usage=总额度、currentValue=已用；
/// 5h 窗口无计数只有百分比→null）。
(String, String)? quotaUsageFraction(Map<String, dynamic>? limit) {
  if (limit == null) return null;
  final total = limit['usage'] as num?;
  final used = limit['currentValue'] as num?;
  if (total == null || used == null || total <= 0) return null;
  return (_fmtNum(used), _fmtNum(total));
}

String _fmtNum(num v) {
  if (v >= 1e8) return _fmtScaled(v / 1e8, '亿');
  if (v >= 1e4) return _fmtScaled(v / 1e4, '万');
  final i = v.toInt();
  return i == v ? '$i' : v.toStringAsFixed(1);
}

/// 保留至多 1 位小数，整数值不带 .0（官方 22.4亿 口径）。
String _fmtScaled(double v, String unit) {
  final s = v.toStringAsFixed(1);
  return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s}$unit';
}

/// Token 量格式化（22.4亿 / 3.7亿 / 8562万）。
String formatTokens(num v) => _fmtNum(v);

/// 时长格式化（13 小时 5 分钟 / 42 分钟 / <1 分钟）。
String formatDurationMs(num ms) {
  final totalMin = (ms / 60000).floor();
  if (totalMin <= 0) return tr('不足 1 分钟');
  if (totalMin < 60) return '$totalMin ${tr('分钟')}';
  final h = totalMin ~/ 60;
  final m = totalMin % 60;
  return m == 0 ? '$h ${tr('小时')}' : '$h ${tr('小时')} $m ${tr('分钟')}';
}

/// 额度重置时间（官方 adaptive 口径：当日仅 HH:mm，非当日 MM-dd HH:mm）。
String formatResetTime(Object? millis) {
  if (millis is! num) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(millis.toInt()).toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  final now = DateTime.now();
  final sameDay =
      t.year == now.year && t.month == now.month && t.day == now.day;
  final hm = '${two(t.hour)}:${two(t.minute)}';
  return sameDay ? hm : '${two(t.month)}-${two(t.day)} $hm';
}

// ── 订阅行（个人套餐 tab）─────────────────────────────────────────

/// 官方套餐名规则（refs/ZCode/packages/services/src/usage-stats/providers/
/// bigmodelUsageQuotaMapper.ts:81-84 formatPlanName）：
/// "GLM Coding " + 首字母大写、其余小写。level 空时回退 productName 原样
/// （命名优先级同官方徽标 refs/ZCode/packages/ui/src/
/// WorkspaceSidebarFooterPlanBadgeHelpers.ts:51-53：quota.level 优先、
/// details[0].productName 回退）；两者皆空 → null。
String? formatPlanName({String? level, String? productName}) {
  final l = level?.trim() ?? '';
  if (l.isNotEmpty) {
    return 'GLM Coding ${l[0].toUpperCase()}${l.substring(1).toLowerCase()}';
  }
  final p = productName?.trim() ?? '';
  return p.isEmpty ? null : p;
}

/// billingCycle 常见值中文映射，未知值原样返回
/// （官方类型 string | null，refs usage-stats.ts:141）。
String formatBillingCycle(Object? cycle) {
  if (cycle is! String) return '';
  return switch (cycle.trim()) {
    'monthly' => tr('按月'),
    'quarterly' => tr('按季'),
    'yearly' => tr('按年'),
    final v => v,
  };
}

/// 订阅时间字段 → yyyy-MM-dd。官方类型为 ISO 日期 string
/// （refs usage-stats.ts:137-143），实际通道也可能回传毫秒时间戳
/// （num 或数字串），均兼容；无法解析 → ''。
String formatSubscriptionDate(Object? v) {
  if (v is num) return _epochToYmd(v.toInt());
  if (v is String) {
    final s = v.trim();
    if (s.isEmpty) return '';
    final ms = int.tryParse(s);
    if (ms != null) return _epochToYmd(ms);
    return s.length >= 10 ? s.substring(0, 10) : '';
  }
  return '';
}

String _epochToYmd(int ms) {
  // 防御：裸数字串（如压缩日期 20261101）不是毫秒时间戳——
  // 真实订阅时间戳毫秒值恒大于 1e11（1973 年之后）。
  if (ms < 100000000000) return '';
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

/// 订阅行逐条文案：details 数组是 productName/billingCycle/renewTime/
/// expireTime 的官方载体（refs/ZCode/packages/shared/src/usage-stats.ts:132-152
/// UsageEntitlementSubscription/UsageEntitlementSubscriptionDetail），逐条
/// 列出、最多 [maxLines] 条；totalCount=details 总数（供"等 N 项"提示）。
/// 首条套餐名按官方徽标规则取 quota.level 优先、productName 回退，其余条
/// 仅 productName。details 缺失时退回顶层 renewTime/expireTime + level
/// （旧数据形态兜底，保持既有"续费/到期"展示不回退）。
({List<String> lines, int totalCount}) subscriptionDetailLines(
  Object? quotaLevel,
  Map<String, dynamic> subscription, {
  int maxLines = 2,
}) {
  final raw = subscription['details'];
  final details = raw is List
      ? raw.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList()
      : const <Map<String, dynamic>>[];
  if (details.isEmpty) {
    final name = formatPlanName(
      level: quotaLevel is String ? quotaLevel : null,
    );
    final renew = formatSubscriptionDate(subscription['renewTime']);
    final expire = formatSubscriptionDate(subscription['expireTime']);
    final line = [
      ?name,
      if (renew.isNotEmpty) '${tr('续费')} $renew',
      if (expire.isNotEmpty) '${tr('到期')} $expire',
    ].join(' · ');
    return (
      lines: line.isEmpty ? const <String>[] : [line],
      totalCount: line.isEmpty ? 0 : 1,
    );
  }
  final lines = <String>[];
  for (var i = 0; i < details.length && lines.length < maxLines; i++) {
    final d = details[i];
    final productName = d['productName'];
    final name = formatPlanName(
      level: i == 0 && quotaLevel is String ? quotaLevel : null,
      productName: productName is String ? productName : null,
    );
    final cycle = formatBillingCycle(d['billingCycle']);
    final renew = formatSubscriptionDate(d['renewTime']);
    final expire = formatSubscriptionDate(d['expireTime']);
    final line = [
      ?name,
      if (cycle.isNotEmpty) cycle,
      if (renew.isNotEmpty) '${tr('续费')} $renew',
      if (expire.isNotEmpty) '${tr('到期')} $expire',
    ].join(' · ');
    if (line.isNotEmpty) lines.add(line);
  }
  return (lines: lines, totalCount: details.length);
}
