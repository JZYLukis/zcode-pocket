import 'package:flutter/services.dart';

/// 用量统计时区（2026-10-27 用户⑩）：服务端缺省按 UTC 归日，导致
/// 本地今天缺失、峰值日期与峰值 tokens 偏移。原生通道只读系统 IANA id。
const MethodChannel _timeZoneChannel = MethodChannel('companion/timezone');

/// 只接受 IANA 名称（Asia/Shanghai、America/New_York、Etc/UTC 等）与
/// UTC/GMT 两个特殊值；拒绝 CST/GMT+8 等歧义缩写，绝不拿去做服务端归日。
String? normalizeIanaTimeZone(String? raw) {
  final value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  if (value == 'UTC' || value == 'GMT') return value;
  final valid = RegExp(
    r'^[A-Za-z][A-Za-z0-9_+\-]*(/[A-Za-z0-9_+\-]+)+$',
  );
  return valid.hasMatch(value) ? value : null;
}

Future<String?> readDeviceTimeZone() async {
  try {
    final raw = await _timeZoneChannel.invokeMethod<String>('get');
    return normalizeIanaTimeZone(raw);
  } catch (_) {
    // 测试/桌面无通道：回退旧行为（服务端缺省），不阻断用量页。
    return null;
  }
}

Map<String, dynamic> appUsageParams(String range, String? timeZone) {
  final normalized = normalizeIanaTimeZone(timeZone);
  return {
    'range': range,
    if (normalized != null) 'timeZone': normalized,
  };
}

/// 套餐来源 scope（官方 usage-stats getEntitlementSnapshot 对位）：
/// 个人套餐=individual-coding-plan；Start Plan=start-plan。
Map<String, dynamic> codingPlanScope(String family, String planKind) => {
  'preferredProviderId': 'account:$family-$planKind',
  'accountAccess': {
    'type': 'zhipu-account',
    'accountType': family,
    'mode': planKind,
    'entitled': true,
  },
};

/// 缓存必须按时区分桶，系统时区改变后不能复用旧自然日数据。
String usageCacheKey(String range, String? timeZone) =>
    '$range|${normalizeIanaTimeZone(timeZone) ?? ''}';
