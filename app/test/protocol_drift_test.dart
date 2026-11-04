// 协议漂移哨兵纯函数测试（开源审查 R1 P3-1/R2 P3-4）：noteProtocolDrift
// 是 ADR 0033"桌面协议变化从静默坏变 logcat 可见"的防线，此前零测试——
// 哨兵自身失效模式恰是静默（只打日志不拦截），用 onLog 缝钉三分支。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/protocol_drift.dart';

void main() {
  test('载荷整体缺席（source=null）→ 一条整体缺席日志', () {
    final lines = <String>[];
    noteProtocolDrift('test.ctx', null, const ['sid'], onLog: lines.add);
    expect(lines, hasLength(1));
    expect(lines.single, contains('test.ctx'));
    expect(lines.single, contains('整体缺席'));
  });

  test('骨架字段缺席 → 逐字段一行日志；齐套 → 零日志', () {
    final missing = <String>[];
    noteProtocolDrift(
      'wire.session',
      {'sid': 's1'},
      const ['sid', 'state', 'updatedAt'],
      onLog: missing.add,
    );
    expect(missing, hasLength(2), reason: '在场的 sid 不打；缺席的各一行');
    expect(missing[0], contains('字段缺席 state'));
    expect(missing[1], contains('字段缺席 updatedAt'));

    final quiet = <String>[];
    noteProtocolDrift(
      'wire.session',
      {'sid': 's1', 'state': 'running', 'updatedAt': 1},
      const ['sid', 'state', 'updatedAt'],
      onLog: quiet.add,
    );
    expect(quiet, isEmpty, reason: '骨架齐套是常态，零输出');
  });

  test('值为 null 的键算在场（containsKey 语义，不误报）', () {
    final lines = <String>[];
    noteProtocolDrift(
      'wire.x',
      {'a': null, 'b': 1},
      const ['a', 'b'],
      onLog: lines.add,
    );
    expect(lines, isEmpty,
        reason: '哨兵只看骨架键缺席与否——值为 null 是消费点宽松解析的'
            '既有职责，不在此处误报');
  });
}
