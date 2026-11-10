import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/state/cache_policy.dart';

/// 「对话历史丢失」回归（2026-10-23 真机实锤，用户反馈"提问和回复
/// 对不上"——列表最老行冻结在最新一条用户消息，「加载更早消息」入口
/// 永久消失）。
///
/// 根因链（三条脆弱路径共同致损，服务端 wire 语义经 refs 实证健康：
/// window=尾部 60 行、totalCount=全量、firstRowId=全序最老、rowsRange
/// 返回 hasMore）：
/// 1) 快照 rows/window 形状异常时旧实现清空 rows+计数清零；
/// 2) 随后 row.appended 无条件把 firstRowId 设为追加行（本轮 turnHeader
///    冒充全会话最老行）；
/// 3) canLoadOlder 只看 totalCount>rows.length，任何计数损坏即永久藏起
///    入口；且损坏计数被缓存原样保存，delta-resume 路径固化。
void main() {
  ConversationState state() => ConversationState();

  Map<String, dynamic> row(int id, [String kind = 'assistantText']) =>
      {'rowId': id, 'kind': kind, 'text': 't$id'};

  Map<String, dynamic> snapshotFrame({
    required Map<String, dynamic> snap,
    int toSeq = 10,
  }) => {
    'toSeq': toSeq,
    'payload': {'kind': 'snapshot', 'snapshot': snap},
  };

  Map<String, dynamic> healthySnap({
    required List<Map<String, dynamic>> window,
    required int totalCount,
    required int? firstRowId,
  }) => {
    'logEpoch': 'e1',
    'rows': {
      'window': window,
      'totalCount': totalCount,
      'firstRowId': firstRowId,
    },
  };

  Map<String, dynamic> deltaFrame({
    required int fromSeq,
    required int toSeq,
    required List<Map<String, dynamic>> deltas,
  }) => {
    'fromSeq': fromSeq,
    'toSeq': toSeq,
    'payload': {'kind': 'deltas', 'deltas': deltas},
  };

  Map<String, dynamic> appendedDelta(Map<String, dynamic> row) =>
      {'op': 'row.appended', 'row': row};

  void apply(ConversationState s, Map<String, dynamic> frame) {
    s.applyFrame(frame, onGap: () => fail('不应 gap'));
  }

  group('健康路径不受影响', () {
    test('尾部窗口+全量计数 → canLoadOlder=true（入口在）', () {
      final s = state();
      apply(
        s,
        snapshotFrame(
          snap: healthySnap(window: [row(94), row(95)], totalCount: 300, firstRowId: 1),
        ),
      );
      expect(s.canLoadOlder, true,
          reason: '窗口头 94 ≠ 全序最老 1，官方判据说明还有更早历史');
    });

    test('小会话全量在手 → canLoadOlder=false（不露假入口）', () {
      final s = state();
      apply(
        s,
        snapshotFrame(
          snap: healthySnap(window: [row(1), row(2)], totalCount: 2, firstRowId: 1),
        ),
      );
      expect(s.canLoadOlder, false,
          reason: 'window[0].rowId===firstRowId 且计数相等=已到顶');
    });

    test('从零建会话：首行充当当全序游标', () {
      final s = state();
      apply(
        s,
        snapshotFrame(
          snap: healthySnap(window: <Map<String, dynamic>>[], totalCount: 0, firstRowId: null),
        ),
      );
      apply(
        s,
        deltaFrame(fromSeq: 10, toSeq: 11, deltas: [
          appendedDelta(row(1, 'turnHeader')),
          appendedDelta(row(2, 'userInput')),
        ]),
      );
      expect(s.firstRowId, 1);
      expect(s.totalCount, 2);
      expect(s.canLoadOlder, false);
    });
  });

  group('快照形状异常不再清空（修复 1）', () {
    test('rows 对象缺席：保留既有行与计数 + 哨兵日志', () {
      final s = state();
      apply(
        s,
        snapshotFrame(
          snap: healthySnap(window: [row(50)], totalCount: 100, firstRowId: 1),
        ),
      );
      final logs = <String>[];
      s.applyFrame(
        snapshotFrame(snap: {'logEpoch': 'e1'}),
        onGap: () => fail('不应 gap'),
        onLog: logs.add,
      );
      expect(s.rows.length, 1, reason: '旧实现清零——历史视图整屏蒸发');
      expect(s.totalCount, 100);
      expect(s.firstRowId, 1);
      expect(s.canLoadOlder, true);
      expect(logs.any((l) => l.contains('[snapshot-shape]')), true);
    });

    test('window 非 List：同样保留', () {
      final s = state();
      apply(
        s,
        snapshotFrame(
          snap: healthySnap(window: [row(50)], totalCount: 100, firstRowId: 1),
        ),
      );
      s.applyFrame(
        snapshotFrame(snap: {
          'logEpoch': 'e1',
          'rows': {'window': '???', 'totalCount': 100, 'firstRowId': 1},
        }),
        onGap: () => fail('不应 gap'),
      );
      expect(s.rows.length, 1);
      expect(s.canLoadOlder, true);
    });
  });

  group('追加行不冒充全序游标（修复 2）', () {
    test('形状异常后的追加：firstRowId 不被本轮行覆写', () {
      final s = state();
      // 事故序列：健康快照 → 异常快照（旧行保留）→ 本轮行追加。
      apply(
        s,
        snapshotFrame(
          snap: healthySnap(window: [row(50)], totalCount: 100, firstRowId: 1),
        ),
      );
      s.applyFrame(
        snapshotFrame(snap: {'logEpoch': 'e1'}),
        onGap: () => fail('不应 gap'),
      );
      apply(
        s,
        deltaFrame(fromSeq: 10, toSeq: 12, deltas: [
          appendedDelta(row(101, 'turnHeader')),
          appendedDelta(row(102, 'userInput')),
          appendedDelta(row(103, 'assistantText')),
        ]),
      );
      expect(s.firstRowId, isNot(101),
          reason: '旧行为把本轮 turnHeader 当全会话最老行——入口永藏');
      expect(s.canLoadOlder, true,
          reason: '全序未知（或窗口头≠firstRowId）→ 允许向服务端求真');
    });

    test('种子行非空时的追加同样不覆写（v1 缓存自愈路径）', () {
      final s = state();
      s.applySeed(ConversationSeed(
        rows: [row(60), row(61)],
        logEpoch: 'e1',
        seq: 10,
        firstRowId: null, // v1 条目历史游标不信任
        totalCount: 0,
        snapshot: null,
      ));
      apply(
        s,
        deltaFrame(fromSeq: 10, toSeq: 11, deltas: [appendedDelta(row(90))]),
      );
      expect(s.firstRowId, isNull);
      expect(s.canLoadOlder, true, reason: '全序未知→入口露出，hasMore 定真');
    });
  });

  group('rowsRange hasMore 终局信号（修复 3）', () {
    test('hasMore=false → historyExhausted 收口', () {
      final s = state();
      apply(
        s,
        snapshotFrame(
          snap: healthySnap(window: [row(50)], totalCount: 100, firstRowId: 1),
        ),
      );
      s.prependOlderRows(
        [row(1), row(2)],
        null,
        hasMore: false,
      );
      expect(s.historyExhausted, true);
      expect(s.canLoadOlder, false);
    });

    test('空页且无 hasMore=true → 视为到顶（防自旋）', () {
      final s = state();
      apply(
        s,
        snapshotFrame(
          snap: healthySnap(window: [row(50)], totalCount: 100, firstRowId: 1),
        ),
      );
      s.prependOlderRows(<Map<String, dynamic>>[], null);
      expect(s.historyExhausted, true);
    });

    test('hasMore=true 不收口，可继续翻页', () {
      final s = state();
      apply(
        s,
        snapshotFrame(
          snap: healthySnap(window: [row(50)], totalCount: 100, firstRowId: 1),
        ),
      );
      s.prependOlderRows([row(48), row(49)], null, hasMore: true);
      expect(s.historyExhausted, false);
      expect(s.canLoadOlder, true);
      expect(s.rows.first['rowId'], 48);
    });
  });

  group('缓存 schema v2（修复 4：存量损坏自愈）', () {
    Map<String, dynamic> entryJson({required int schemaVersion}) => {
      'schemaVersion': schemaVersion,
      'deviceSid': 'd',
      'sessionId': 's1',
      'logEpoch': 'e1',
      'lastSeq': 9,
      'firstRowId': 88, // 可能已损坏的游标
      'totalCount': 3,  // 可能已损坏的计数
      'snapshotControl': null,
      'rows': [row(88), row(89), row(90)],
      'savedAt': 1,
      'byteSize': 1,
    };

    test('v1 条目 historyTrusted=false', () {
      final e = SessionCacheEntry.fromJson(entryJson(schemaVersion: 1))!;
      expect(e.historyTrusted, false);
      expect(e.firstRowId, 88, reason: '字段保留，信任门控在装配层');
    });

    test('v2 条目 historyTrusted=true', () {
      final e = SessionCacheEntry.fromJson(entryJson(schemaVersion: 2))!;
      expect(e.historyTrusted, true);
    });

    test('写出的条目带 v2 版本号', () {
      final e = SessionCacheEntry.fromJson(entryJson(schemaVersion: 1))!;
      expect(e.toJson()['schemaVersion'], SessionCacheEntry.schemaVersion);
    });
  });

  group('快照整体替换（修复 5：2026-10-23 用户二次实锤"问答错位"）', () {
    test('陈旧水位触发的尾窗快照：行=窗口本身，旧段不再拼接', () {
      final s = state();
      // 缓存旧段停在早间水位（例：心跳提示区），服务端保留窗已滚过——
      // 重订阅只能改发"最后 60 行"快照（官方 subscribeReserved 判据）。
      s.applySeed(ConversationSeed(
        rows: [row(60), row(61), row(62)],
        logEpoch: 'e1',
        seq: 9,
        firstRowId: 60,
        totalCount: 3,
        snapshot: null,
      ));
      apply(
        s,
        snapshotFrame(
          snap: healthySnap(
            window: [row(940), row(941)],
            totalCount: 900,
            firstRowId: 1,
          ),
          toSeq: 400,
        ),
      );
      expect(s.rows.map((r) => r['rowId']), [940, 941],
          reason: '旧段(60..62)与尾窗(940..)之间的 63..939 不被任何机制拉取'
              '——旧实现拼接它们=中间对话蒸发、心跳提示下直接接最终回复');
      expect(s.totalCount, 900);
      expect(s.firstRowId, 1);
      expect(s.canLoadOlder, true, reason: '快照游标重判，入口露出可翻页补齐');
    });

    test('分页过的更早历史随新快照整体让位（官方规则 1），入口重露', () {
      final s = state();
      apply(
        s,
        snapshotFrame(
          snap: healthySnap(window: [row(940)], totalCount: 900, firstRowId: 1),
        ),
      );
      s.prependOlderRows([row(700), row(701)], null, hasMore: true);
      expect(s.rows.length, 3);
      apply(
        s,
        snapshotFrame(
          snap: healthySnap(window: [row(950)], totalCount: 901, firstRowId: 1),
          toSeq: 11,
        ),
      );
      expect(s.rows.map((r) => r['rowId']), [950]);
      expect(s.canLoadOlder, true, reason: '被丢弃的分页历史可经 rowsRange 重翻');
    });

    test('新快照重置 historyExhausted——翻到顶旧态不压住新窗口入口', () {
      final s = state();
      apply(
        s,
        snapshotFrame(
          snap: healthySnap(window: [row(50)], totalCount: 100, firstRowId: 1),
        ),
      );
      s.prependOlderRows(<Map<String, dynamic>>[], null, hasMore: false);
      expect(s.historyExhausted, true);
      apply(
        s,
        snapshotFrame(
          snap: healthySnap(
            window: [row(940), row(941)],
            totalCount: 900,
            firstRowId: 1,
          ),
          toSeq: 11,
        ),
      );
      expect(s.historyExhausted, false);
      expect(s.canLoadOlder, true);
    });

    test('订阅 base 携带当前水位：空/未知 epoch 不带 base', () {
      expect(conversationSubscribeArgs('s1', null, 0), {
        'sessionId': 's1',
      }, reason: '无 epoch（未收到任何帧）→ 不带 base，服务端发全量快照');
      expect(conversationSubscribeArgs('s1', '', 400)['base'], isNull,
          reason: '空 epoch 同样不带 base');
      expect(conversationSubscribeArgs('s1', 'e1', 400), {
        'sessionId': 's1',
        'base': {'logEpoch': 'e1', 'seq': 400},
      }, reason: '重连用当前水位——保留窗内 resume 续传，不强制快照');
    });

    test('状态水位随帧前进（base 的数据源契约）', () {
      final s = state();
      s.applySeed(ConversationSeed(
        rows: [row(60)],
        logEpoch: 'e1',
        seq: 9,
        firstRowId: null,
        totalCount: 0,
        snapshot: null,
      ));
      apply(
        s,
        deltaFrame(fromSeq: 9, toSeq: 12, deltas: [appendedDelta(row(61))]),
      );
      expect(s.seq, 12, reason: '重订阅 base 的 seq 必须是推进后的水位');
      expect(s.logEpoch, 'e1');
    });
  });

  group('rowsRange 陈旧响应守卫（官方 loadOlder 同义）', () {
    test('同 state 纪元、同游标、响应纪元一致才允许合并', () {
      expect(
        shouldAcceptOlderRows(
          requestLogEpoch: 'e1', currentLogEpoch: 'e1', responseLogEpoch: 'e1',
          requestCursor: 60, currentCursor: 60,
        ),
        isTrue,
      );
    });

    test('CLI 重启或响应纪元不匹配时整页丢弃', () {
      expect(
        shouldAcceptOlderRows(
          requestLogEpoch: 'e1', currentLogEpoch: 'e2', responseLogEpoch: 'e1',
          requestCursor: 60, currentCursor: 60,
        ),
        isFalse,
      );
      expect(
        shouldAcceptOlderRows(
          requestLogEpoch: 'e1', currentLogEpoch: 'e1', responseLogEpoch: 'e2',
          requestCursor: 60, currentCursor: 60,
        ),
        isFalse,
      );
    });

    test('在途快照替换使游标失效时不得复活旧历史', () {
      expect(
        shouldAcceptOlderRows(
          requestLogEpoch: 'e1', currentLogEpoch: 'e1', responseLogEpoch: 'e1',
          requestCursor: 60, currentCursor: 940,
        ),
        isFalse,
      );
    });

    test('缺少协议要求的响应纪元时不冒险合并', () {
      expect(
        shouldAcceptOlderRows(
          requestLogEpoch: 'e1', currentLogEpoch: 'e1', responseLogEpoch: null,
          requestCursor: 60, currentCursor: 60,
        ),
        isFalse,
      );
    });
  });
}
