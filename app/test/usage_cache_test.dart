import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/ui/usage_page.dart';

/// 用量数据短缓存（2026-10-26 真机验收④）：旧实现按档永久命中——进页
/// 拉一次后统计不再更新（"不是实时的"根因），只有手动下拉能绕过。
/// 修复=60s TTL 的 SWR 缓存（get 看时效供刷新判定 / peek 永远给旧值
/// 供渲染兜底不闪空页）。
void main() {
  final t0 = DateTime(2026, 10, 26, 12, 0, 0);

  test('TTL 内命中；过期后 get 返回 null（触发重拉）', () {
    final c = UsageSnapshotCache<String>(const Duration(seconds: 60));
    c.put('30d', 'v1', t0);
    expect(c.get('30d', t0.add(const Duration(seconds: 30))), 'v1');
    expect(c.get('30d', t0.add(const Duration(seconds: 60))), isNull,
        reason: 'TTL 边界=过期（>=），必须重拉——修复前此处永远命中 v1');
    expect(c.peek('30d'), 'v1', reason: '渲染兜底：刷新完成前继续显示旧值');
  });

  test('缺失键 get/peek 均 null；put 覆盖旧值并重置时效', () {
    final c = UsageSnapshotCache<String>(const Duration(seconds: 60));
    expect(c.get('7d', t0), isNull);
    expect(c.peek('7d'), isNull);
    c.put('7d', 'a', t0);
    c.put('7d', 'b', t0.add(const Duration(seconds: 50)));
    expect(c.get('7d', t0.add(const Duration(seconds: 80))), 'b',
        reason: '覆盖写入重置时间戳——不是首写时刻');
  });

  test('档位键隔离（30d/7d/Today 各自命中与过期）', () {
    final c = UsageSnapshotCache<String>(const Duration(seconds: 60));
    c.put('30d', 'old-range', t0);
    c.put('7d', 'week', t0.add(const Duration(seconds: 10)));
    expect(c.get('30d', t0.add(const Duration(seconds: 61))), isNull);
    expect(c.get('7d', t0.add(const Duration(seconds: 61))), 'week');
  });
}
