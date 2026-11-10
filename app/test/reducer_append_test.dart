import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/conversation.dart';

/// 等价性对拍（回归防护 7.2 第 5 条）：同一 delta 帧序列，
/// 新实现（帧内缓冲、帧尾物化）vs 旧实现（逐条立即拼接）产出的
/// rows/snapshot/totalCount 必须完全一致。旧实现按 2026-10-19 改造前
/// 源码原样拷贝于此作参照。

class _LegacyState {
  List<Map<String, dynamic>> rows = [];
  Map<String, dynamic>? snapshot;
  int totalCount = 0;
  int? firstRowId;
}

Map<String, dynamic> _legacyAppendToRow(
  Map<String, dynamic> row,
  String? path,
  String append,
) {
  switch (path) {
    case 'text':
      if (row['kind'] == 'assistantText' || row['kind'] == 'reasoning') {
        return {...row, 'text': '${row['text'] ?? ''}$append'};
      }
      return row;
    case 'inputText':
      if (row['kind'] == 'toolCall') {
        return {...row, 'inputText': '${row['inputText'] ?? ''}$append'};
      }
      return row;
    case 'output.text':
      if (row['kind'] == 'toolCall' && row['output'] is Map) {
        final output = (row['output'] as Map).cast<String, dynamic>();
        return {
          ...row,
          'output': {...output, 'text': '${output['text'] ?? ''}$append'},
        };
      }
      return row;
    case 'summaryText':
      if (row['kind'] == 'subagent') {
        return {...row, 'summaryText': '${row['summaryText'] ?? ''}$append'};
      }
      return row;
    default:
      return row;
  }
}

void _legacyApplyDelta(_LegacyState s, Map<String, dynamic> delta) {
  switch (delta['op']) {
    case 'row.appended':
      final row = (delta['row'] as Map).cast<String, dynamic>();
      s.rows.add(row);
      s.totalCount += 1;
      s.firstRowId ??= (row['rowId'] as num?)?.toInt();
      break;
    case 'row.upserted':
      final row = (delta['row'] as Map).cast<String, dynamic>();
      final id = (row['rowId'] as num?)?.toInt();
      final index = s.rows.indexWhere(
        (r) => (r['rowId'] as num?)?.toInt() == id,
      );
      if (index != -1) s.rows[index] = row;
      break;
    case 'row.removed':
      final fromRowId = (delta['fromRowId'] as num?)?.toInt() ?? 0;
      final kept = s.rows
          .where((r) => ((r['rowId'] as num?)?.toInt() ?? 0) < fromRowId)
          .toList();
      final removed = s.rows.length - kept.length;
      s.rows = kept;
      if (s.firstRowId != null && fromRowId <= s.firstRowId!) {
        s.totalCount = 0;
        s.firstRowId = null;
      } else {
        s.totalCount = (s.totalCount - removed).clamp(0, 1 << 31);
      }
      break;
    case 'row.delta':
      final rowId = (delta['rowId'] as num?)?.toInt();
      final path = delta['path'] as String?;
      final append = delta['append'] as String? ?? '';
      final index = s.rows.indexWhere(
        (r) => (r['rowId'] as num?)?.toInt() == rowId,
      );
      if (index != -1) {
        s.rows[index] = _legacyAppendToRow(s.rows[index], path, append);
      }
      break;
    case 'state.updated':
      final patch = delta['patch'];
      if (patch is Map && s.snapshot != null) {
        s.snapshot = {...s.snapshot!, ...patch.cast<String, dynamic>()};
      }
      break;
  }
}

Map<String, dynamic> _frame(List<Map<String, dynamic>> deltas,
        {required int from, required int to}) =>
    {
      'payload': {
        'kind': 'deltas',
        'deltas': deltas,
      },
      'fromSeq': from,
      'toSeq': to,
    };

void main() {
  test('C3 对拍：随机帧序列下新旧实现产出完全一致', () {
    final random = Random(20261019);
    final state = ConversationState();
    final legacy = _LegacyState();

    // 初始快照（两侧行数据同源）。
    final seedRows = [
      {'rowId': 1, 'kind': 'assistantText', 'text': '你好'},
      {
        'rowId': 2,
        'kind': 'toolCall',
        'inputText': 'ls',
        'output': {'text': 'a\nb'},
      },
      {'rowId': 3, 'kind': 'subagent', 'summaryText': '探员'},
    ];
    state.applyFrame({
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'logEpoch': 'e1',
          'rows': {'window': seedRows, 'totalCount': 3, 'firstRowId': 1},
        },
      },
      'toSeq': 10,
    }, onGap: () => fail('gap 不应发生'));
    legacy.rows = [
      for (final r in seedRows) Map<String, dynamic>.of(r),
    ];
    legacy.totalCount = 3;
    legacy.firstRowId = 1;
    legacy.snapshot = {
      'logEpoch': 'e1',
      'rows': {'window': seedRows, 'totalCount': 3, 'firstRowId': 1},
    };

    var nextRowId = 4;
    for (var f = 0; f < 40; f++) {
      final deltas = <Map<String, dynamic>>[];
      final n = 1 + random.nextInt(6);
      for (var i = 0; i < n; i++) {
        final existingIds = [
          for (final r in state.rows) (r['rowId'] as num).toInt(),
        ];
        final pick = random.nextInt(10);
        if (pick == 0 || existingIds.isEmpty) {
          // 新行（kind 覆盖四种合法+一种无 path 规则的）
          final kind = [
            'assistantText',
            'reasoning',
            'toolCall',
            'subagent',
            'userInput',
          ][random.nextInt(5)];
          deltas.add({
            'op': 'row.appended',
            'row': {'rowId': nextRowId, 'kind': kind},
          });
          nextRowId++;
        } else if (pick <= 4) {
          // 追加（合法与非法 path/kind 组合都试）
          final path = [
            'text',
            'inputText',
            'output.text',
            'summaryText',
            'bogus',
          ][random.nextInt(5)];
          final chunk = [
            '流式片段',
            'abc ',
            '多字节✓',
            '\n',
          ][random.nextInt(4)];
          deltas.add({
            'op': 'row.delta',
            'rowId': existingIds[random.nextInt(existingIds.length)],
            'path': path,
            'append': chunk,
          });
        } else if (pick <= 6) {
          // 整行替换（kind 可能变化——验证 flush 时序）
          final id = existingIds[random.nextInt(existingIds.length)];
          deltas.add({
            'op': 'row.upserted',
            'row': {
              'rowId': id,
              'kind': ['assistantText', 'toolCall'][random.nextInt(2)],
              'text': '替换后的行 $f',
            },
          });
        } else if (pick <= 8) {
          // 移除（fromRowId 取现有 id——half 开区间语义）
          final existing = [
            for (final r in state.rows) (r['rowId'] as num).toInt(),
          ]..sort();
          if (existing.isNotEmpty) {
            deltas.add({
              'op': 'row.removed',
              'fromRowId': existing[random.nextInt(existing.length)],
            });
          }
        } else {
          deltas.add({
            'op': 'state.updated',
            'patch': {'patch$f': f},
          });
        }
      }
      if (deltas.isEmpty) continue;
      final from = state.seq;
      final frame = _frame(deltas, from: from, to: from + 1);
      state.applyFrame(frame, onGap: () => fail('gap 不应发生'));
      for (final d in deltas) {
        _legacyApplyDelta(legacy, d);
      }
      expect(
        jsonEncode(state.rows),
        jsonEncode(legacy.rows),
        reason: '第 $f 帧后 rows 不一致',
      );
      expect(state.totalCount, legacy.totalCount, reason: '第 $f 帧后 totalCount');
      expect(state.firstRowId, legacy.firstRowId, reason: '第 $f 帧后 firstRowId');
    }
    // snapshot（state.updated 累积）一致
    expect(
      jsonEncode(state.snapshot?..remove('rows')),
      jsonEncode(legacy.snapshot?..remove('rows')),
    );
  });

  test('C3 特征场景：追加后同帧整行替换——旧追加必须落在旧行（丢弃）', () {
    final state = ConversationState();
    state.applyFrame({
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'logEpoch': 'e1',
          'rows': {
            'window': [
              {'rowId': 1, 'kind': 'assistantText', 'text': 'A'},
            ],
            'totalCount': 1,
            'firstRowId': 1,
          },
        },
      },
      'toSeq': 1,
    }, onGap: () => fail('gap'));
    // 同帧：追加 → 替换（替换后 text 应为替换值，不含追加内容）
    state.applyFrame(_frame([
      {'op': 'row.delta', 'rowId': 1, 'path': 'text', 'append': 'TAIL'},
      {
        'op': 'row.upserted',
        'row': {'rowId': 1, 'kind': 'assistantText', 'text': 'NEW'},
      },
    ], from: 1, to: 2), onGap: () => fail('gap'));
    expect(state.rows.first['text'], 'NEW');
  });

  test('C3 特征场景：移除后同帧再追加同 id——追加不得落到新行外的旧缓冲', () {
    final state = ConversationState();
    state.applyFrame({
      'payload': {
        'kind': 'snapshot',
        'snapshot': {
          'logEpoch': 'e1',
          'rows': {
            'window': [
              {'rowId': 1, 'kind': 'assistantText', 'text': 'A'},
              {'rowId': 5, 'kind': 'assistantText', 'text': 'B'},
            ],
            'totalCount': 2,
            'firstRowId': 1,
          },
        },
      },
      'toSeq': 1,
    }, onGap: () => fail('gap'));
    // 同帧：对 5 追加 → 移除 >=5 → 重加 5（新行）。旧追加必须随旧行消亡。
    state.applyFrame(_frame([
      {'op': 'row.delta', 'rowId': 5, 'path': 'text', 'append': 'TAIL'},
      {'op': 'row.removed', 'fromRowId': 5},
      {
        'op': 'row.appended',
        'row': {'rowId': 5, 'kind': 'assistantText', 'text': 'REBORN'},
      },
      {'op': 'row.delta', 'rowId': 5, 'path': 'text', 'append': '!'},
    ], from: 1, to: 2), onGap: () => fail('gap'));
    expect(state.rows.last['text'], 'REBORN!');
    expect(state.rows.length, 2);
  });

  group('F2 optimistic dataVersion 不变式（当前语义钉死）', () {
    test('optimistic 系列不递增 dataVersion', () {
      final state = ConversationState();
      state.applyFrame({
        'payload': {
          'kind': 'snapshot',
          'snapshot': {
            'logEpoch': 'e1',
            'rows': {
              'window': [
                {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
              ],
              'totalCount': 1,
              'firstRowId': 1,
            },
            'queue': {
              'items': [
                {'queueItemId': 'q1'},
              ],
            },
          },
        },
        'toSeq': 1,
      }, onGap: () => fail('gap'));
      final before = state.dataVersion;
      state.optimisticPatch({'config': {'model': 'x'}});
      state.optimisticRowUpdate(1, {'feedback': 'like'});
      state.optimisticRemoveQueueItem('q1');
      expect(state.dataVersion, before,
          reason: 'optimistic 不进投影输入，不得递增 dataVersion'
              '（若未来进入投影，必须同步递增并更新本断言——F2 防守）');
      expect(state.rows.first['feedback'], 'like');
      expect(state.queueItems, isEmpty);
    });
  });
}
