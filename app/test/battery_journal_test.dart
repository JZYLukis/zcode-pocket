import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/battery_journal.dart';

void main() {
  group('电量日志行格式（batteryJournalLine）', () {
    test('基础字段与顺序；开关/回合缺省省略', () {
      final line = jsonDecode(
        batteryJournalLine(
          t: 1792400000000,
          level: 87,
          charging: false,
          stateCode: 'bg-conn',
          fgService: true,
          runningTurns: 2,
          cpuSeconds: 123.456,
          rxKb: 4567,
          txKb: 89,
          seq: 42,
        ),
      ) as Map<String, dynamic>;
      expect(line['t'], 1792400000000);
      expect(line['lvl'], 87);
      expect(line['chg'], 0);
      expect(line['st'], 'bg-conn');
      expect(line['fgs'], 1);
      expect(line['run'], 2);
      expect(line['cpu'], 123.5); // 一位小数
      expect(line['rx'], 4567);
      expect(line['tx'], 89);
      expect(line['n'], 42);
      // 缺省省略（fgs/run 不出现）
      final minimal = jsonDecode(
        batteryJournalLine(
          t: 1,
          level: 50,
          charging: true,
          stateCode: 'fg-disc',
          fgService: false,
          runningTurns: 0,
          cpuSeconds: -1,
          rxKb: 0,
          txKb: 0,
          seq: 1,
        ),
      ) as Map<String, dynamic>;
      expect(minimal.containsKey('fgs'), isFalse);
      expect(minimal.containsKey('run'), isFalse);
      expect(minimal.containsKey('cpu'), isFalse); // 读不到 cpu 时省略
      expect(minimal['chg'], 1);
    });
  });

  group('写入判定（batteryShouldWrite）', () {
    test('首样本恒写', () {
      expect(
        batteryShouldWrite(
          prevLevel: null,
          prevCharging: null,
          prevStateCode: null,
          prevFgService: null,
          level: 90,
          charging: false,
          stateCode: 'fg-conn',
          fgService: false,
          tick: 1,
        ),
        isTrue,
      );
    });

    test('电量/充电沿/状态沿/开关沿立即写', () {
      var base = (
        prevLevel: 90,
        prevCharging: false,
        prevStateCode: 'fg-conn',
        prevFgService: false,
      );
      bool write({
        required int level,
        required bool charging,
        required String stateCode,
        required bool fgService,
        required int tick,
      }) => batteryShouldWrite(
        prevLevel: base.prevLevel,
        prevCharging: base.prevCharging,
        prevStateCode: base.prevStateCode,
        prevFgService: base.prevFgService,
        level: level,
        charging: charging,
        stateCode: stateCode,
        fgService: fgService,
        tick: tick,
      );
      expect(write(level: 89, charging: false, stateCode: 'fg-conn', fgService: false, tick: 3), isTrue); // 电量变
      expect(write(level: 90, charging: true, stateCode: 'fg-conn', fgService: false, tick: 3), isTrue); // 充电沿
      expect(write(level: 90, charging: false, stateCode: 'bg-conn', fgService: false, tick: 3), isTrue); // 前后台沿
      expect(write(level: 90, charging: false, stateCode: 'fg-conn', fgService: true, tick: 3), isTrue); // 开关沿
      // 无变化：非心跳 tick 不写
      expect(write(level: 90, charging: false, stateCode: 'fg-conn', fgService: false, tick: 3), isFalse);
      // 心跳 tick 写
      expect(write(level: 90, charging: false, stateCode: 'fg-conn', fgService: false, tick: 10), isTrue);
    });
  });

  group('体积截断（trimJournalHead）', () {
    test('小于阈值原样返回；超限从头丢整行', () {
      final lines = [for (var i = 0; i < 100; i++) '{"n":$i,"x":"${'a' * 50}}'];
      final content = lines.join('\n');
      expect(trimJournalHead(content, 10000), content);
      final trimmed = trimJournalHead(content, 2000);
      // 保留的是尾部行
      final trimmedLines = trimmed.split('\n');
      expect(trimmedLines.first.startsWith('{"n"'), isTrue);
      expect(int.parse(trimmedLines.first.split(',')[0].split(':')[1]),
          greaterThan(50));
      expect(trimmedLines.last, lines.last);
      // 每行完整（行首是 { 行尾是 }）
      for (final l in trimmedLines) {
        expect(l.startsWith('{'), isTrue);
        expect(l.endsWith('}'), isTrue);
      }
    });
  });
}
