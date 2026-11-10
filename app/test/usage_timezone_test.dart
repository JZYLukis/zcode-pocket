import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/usage_timezone.dart';

void main() {
  test('IANA 时区校验：接受地区名/UTC，拒绝歧义缩写', () {
    expect(normalizeIanaTimeZone('Asia/Shanghai'), 'Asia/Shanghai');
    expect(normalizeIanaTimeZone('America/New_York'), 'America/New_York');
    expect(normalizeIanaTimeZone('Etc/UTC'), 'Etc/UTC');
    expect(normalizeIanaTimeZone('UTC'), 'UTC');
    expect(normalizeIanaTimeZone(' GMT '), 'GMT');
    expect(normalizeIanaTimeZone('CST'), isNull,
        reason: 'CST 在 Intl 可歧义为美洲中部时间，禁止原样上行');
    expect(normalizeIanaTimeZone('GMT+8'), isNull);
    expect(normalizeIanaTimeZone(''), isNull);
    expect(normalizeIanaTimeZone(null), isNull);
  });

  test('应用用量请求带合法 timeZone；非法值保持缺省', () {
    expect(appUsageParams('30d', 'Asia/Shanghai'), {
      'range': '30d',
      'timeZone': 'Asia/Shanghai',
    });
    expect(appUsageParams('7d', 'CST'), {'range': '7d'});
    expect(appUsageParams('all', null), {'range': 'all'});
  });

  test('Start Plan scope 与个人套餐 scope 使用不同 providerId/planKind', () {
    expect(codingPlanScope('zai', 'start-plan')['preferredProviderId'],
        'account:zai-start-plan');
    expect(
      (codingPlanScope('zai', 'start-plan')['accountAccess'] as Map)['mode'],
      'start-plan',
    );
    expect(codingPlanScope('bigmodel', 'individual-coding-plan')['preferredProviderId'],
        'account:bigmodel-individual-coding-plan');
    expect(
      (codingPlanScope('bigmodel', 'individual-coding-plan')['accountAccess'] as Map)['mode'],
      'individual-coding-plan',
    );
  });

  test('缓存键按时区隔离', () {
    expect(usageCacheKey('30d', 'Asia/Shanghai'),
        isNot(usageCacheKey('30d', 'UTC')));
    expect(usageCacheKey('30d', 'Asia/Shanghai'),
        isNot(usageCacheKey('7d', 'Asia/Shanghai')));
  });
}
