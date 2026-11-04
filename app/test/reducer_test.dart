import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/conversation.dart';

/// ConversationState / SessionsIndexState reducer 单元测试。
/// 帧结构依据 protocol-notes §2.4/§3.2（v4 规范 apply 三分支：
/// snapshot 整体替换 / toSeq<=本地seq 迟到重复丢弃 / fromSeq!=本地seq gap→resync）。
void main() {
  ConversationState state() => ConversationState();

  Map<String, dynamic> snapshotFrame({
    int toSeq = 5,
    List<Map<String, dynamic>>? rows,
    Map<String, dynamic>? snap,
    String logEpoch = 'e1',
  }) {
    final s =
        snap ??
        {
          'logEpoch': logEpoch,
          'revision': 5,
          'rows': {
            'window': rows ?? [],
            'totalCount': rows?.length ?? 0,
            'firstRowId': (rows != null && rows.isNotEmpty)
                ? rows.first['rowId']
                : null,
          },
        };
    return {
      'toSeq': toSeq,
      'payload': {'kind': 'snapshot', 'snapshot': s},
    };
  }

  Map<String, dynamic> deltaFrame({
    required int fromSeq,
    required int toSeq,
    required List<Map<String, dynamic>> deltas,
  }) => {
    'fromSeq': fromSeq,
    'toSeq': toSeq,
    'payload': {'kind': 'deltas', 'deltas': deltas},
  };

  test('snapshot：rows/revision/ready/seq 落位', () {
    final s = state();
    s.applyFrame(
      snapshotFrame(
        rows: [
          {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
          {'rowId': 2, 'kind': 'assistantText', 'text': 'hello'},
        ],
      ),
      onGap: () => fail('不应 gap'),
    );
    expect(s.ready, true);
    expect(s.rows.length, 2);
    expect(s.revision, 5);
    expect(s.seq, 5);
    expect(s.logEpoch, 'e1');
  });

  test('row.appended 增量：行追加 + totalCount 增长', () {
    final s = state()
      ..applyFrame(
        snapshotFrame(
          toSeq: 5,
          rows: [
            {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
          ],
        ),
        onGap: () => fail('不应 gap'),
      );
    s.applyFrame(
      deltaFrame(
        fromSeq: 5,
        toSeq: 6,
        deltas: [
          {
            'op': 'row.appended',
            'row': {'rowId': 2, 'kind': 'assistantText', 'text': ''},
          },
        ],
      ),
      onGap: () => fail('不应 gap'),
    );
    expect(s.rows.length, 2);
    expect(s.totalCount, 2);
    expect(s.firstRowId, 1);
  });

  test(
    'row.delta 流式追加：assistantText.text / toolCall.inputText / output.text',
    () {
      final s = state()
        ..applyFrame(
          snapshotFrame(
            toSeq: 5,
            rows: [
              {'rowId': 1, 'kind': 'assistantText', 'text': '你'},
              {
                'rowId': 2,
                'kind': 'toolCall',
                'toolName': 'Bash',
                'inputText': 'ec',
                'output': {'text': 'ou'},
              },
            ],
          ),
          onGap: () => fail('不应 gap'),
        );
      s.applyFrame(
        deltaFrame(
          fromSeq: 5,
          toSeq: 6,
          deltas: [
            {'op': 'row.delta', 'rowId': 1, 'path': 'text', 'append': '好'},
            {
              'op': 'row.delta',
              'rowId': 2,
              'path': 'inputText',
              'append': 'ho',
            },
            {
              'op': 'row.delta',
              'rowId': 2,
              'path': 'output.text',
              'append': 't',
            },
          ],
        ),
        onGap: () => fail('不应 gap'),
      );
      expect(s.rows[0]['text'], '你好');
      expect(s.rows[1]['inputText'], 'echo');
      expect((s.rows[1]['output'] as Map)['text'], 'out');
    },
  );

  test('row.removed：保留 rowId < fromRowId 的行（规范语义）', () {
    final s = state()
      ..applyFrame(
        snapshotFrame(
          toSeq: 5,
          rows: [
            {'rowId': 1, 'kind': 'userInput', 'text': 'a'},
            {'rowId': 2, 'kind': 'assistantText', 'text': 'b'},
            {'rowId': 3, 'kind': 'userInput', 'text': 'c'},
          ],
        ),
        onGap: () => fail('不应 gap'),
      );
    s.applyFrame(
      deltaFrame(
        fromSeq: 5,
        toSeq: 6,
        deltas: [
          {'op': 'row.removed', 'fromRowId': 2},
        ],
      ),
      onGap: () => fail('不应 gap'),
    );
    expect(s.rows.length, 1);
    expect(s.rows[0]['rowId'], 1);
  });

  test('gap：fromSeq != 本地 seq 触发 onGap 且不应用增量', () {
    final s = state()
      ..applyFrame(snapshotFrame(toSeq: 5), onGap: () => fail('不应 gap'));
    var gaps = 0;
    s.applyFrame(
      deltaFrame(
        fromSeq: 4,
        toSeq: 6,
        deltas: [
          {
            'op': 'row.appended',
            'row': {'rowId': 9, 'kind': 'userInput', 'text': 'x'},
          },
        ],
      ),
      onGap: () => gaps++,
    );
    expect(gaps, 1);
    expect(s.rows.length, 0, reason: 'gap 帧不应用');
    expect(s.seq, 5, reason: 'gap 帧不推进 seq');
  });

  test('迟到/重复帧（toSeq <= 本地 seq）静默丢弃——规范 §2.4 三分支之二', () {
    final s = state()
      ..applyFrame(
        snapshotFrame(
          toSeq: 5,
          rows: [
            {'rowId': 1, 'kind': 'assistantText', 'text': '你好'},
          ],
        ),
        onGap: () => fail('不应 gap'),
      );
    // 同 toSeq 的迟到增量：若不丢弃，文本会被重复拼接
    s.applyFrame(
      deltaFrame(
        fromSeq: 4,
        toSeq: 5,
        deltas: [
          {'op': 'row.delta', 'rowId': 1, 'path': 'text', 'append': '好'},
        ],
      ),
      onGap: () => fail('重复帧不算 gap'),
    );
    expect(s.seq, 5);
    expect(s.rows[0]['text'], '你好', reason: '重复帧不得二次应用');
    // 迟到的重复快照同样丢弃
    s.applyFrame(snapshotFrame(toSeq: 5), onGap: () => fail('不应 gap'));
    expect(s.seq, 5);
  });

  test('epoch 变更的 snapshot 必须接受（resync forceSnapshot 场景）', () {
    final s = state()
      ..applyFrame(
        snapshotFrame(
          toSeq: 100,
          rows: [
            {'rowId': 1, 'kind': 'userInput', 'text': 'old'},
          ],
        ),
        onGap: () => fail('不应 gap'),
      );
    // CLI 重启：epoch 换代，服务端发的 snapshot toSeq 可能 <= 本地 seq
    s.applyFrame(
      snapshotFrame(
        toSeq: 3,
        logEpoch: 'e2',
        rows: [
          {'rowId': 1, 'kind': 'userInput', 'text': 'new-epoch'},
        ],
      ),
      onGap: () => fail('新 epoch 快照不算 gap'),
    );
    expect(s.logEpoch, 'e2');
    expect(s.seq, 3);
    expect(s.rows[0]['text'], 'new-epoch', reason: '换代快照须整体替换');
  });

  test('state.updated 在快照前到达：patch 缓冲、快照落地后合并', () {
    final s = state();
    s.applyFrame(
      deltaFrame(
        fromSeq: 0,
        toSeq: 1,
        deltas: [
          {
            'op': 'state.updated',
            'patch': {
              'control': {'phase': 'running'},
            },
          },
        ],
      ),
      onGap: () => fail('首帧前 patch 走缓冲不应 gap'),
    );
    expect(s.ready, false);
    s.applyFrame(snapshotFrame(toSeq: 5), onGap: () => fail('不应 gap'));
    expect(s.phase, 'running', reason: '缓冲的 patch 应合并进快照');
  });

  test('prependOlderRows：按 rowId 去重且不重排已有行', () {
    final s = state()
      ..applyFrame(
        snapshotFrame(
          toSeq: 5,
          rows: [
            {'rowId': 10, 'kind': 'userInput', 'text': 'new'},
          ],
        ),
        onGap: () => fail('不应 gap'),
      );
    s.prependOlderRows([
      {'rowId': 5, 'kind': 'userInput', 'text': 'old'},
      {'rowId': 10, 'kind': 'userInput', 'text': 'dup'},
    ], 1);
    expect(s.rows.length, 2);
    expect(s.rows[0]['rowId'], 5);
    expect(s.rows[1]['text'], 'new', reason: '重复 row 不得覆盖较新本地行');
  });
}

// （开源审查 R1 P3-4：删除尾部占位空函数 sessionsIndexTests——注释承诺
// 的 SessionsIndexState 同构覆盖从未兑现，实际由 task_list/notify 等间接
// 驱动；占位只会误导读者以为有直测。）
