import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';

/// 协议传输层修复批（2026-11-08，14 路双盲审查协议组）：
/// 本文件钉死 conversation.dart 的协议语义修复——createSession duplicate
/// 等价成功、stop 的 expectedForegroundExecutionId、workspace 主题键归一、
/// firstRowId nullable 落地、resync 丢弃 pre-snapshot patch、applied-base
/// 门、CAS 信封形状。全部用例按"修复前红/修复后绿"设计。
class _FixChannel extends ChannelClient {
  _FixChannel() : super(sendBody: (_) {});

  final calls = <(String, Map<String, dynamic>)>[];

  /// 帧监听器（按事件名）——模拟生产 addEventListener 的回调接线。
  final frameListeners = <String, void Function(dynamic event)>{};

  /// createSession 的应答（默认 accepted）；测试可换成 duplicate/rejected。
  Map<String, dynamic> createSessionReply = {
    'status': 'accepted',
    'result': {'type': 'createSession', 'sessionId': 'new-s-1'},
  };

  /// createSession 应答闸门（制造"已发出、未返回"的窗口）。
  Completer<void>? createSessionGate;

  /// conversation 订阅 ACK 的 mode（snapshot/resume）+ epoch。
  String conversationAckMode = 'snapshot';
  String conversationAckEpoch = 'e1';

  int _subAcks = 0;

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((
      method,
      args.isEmpty
          ? const <String, dynamic>{}
          : (args.first as Map).cast<String, dynamic>(),
    ));
    switch (method) {
      case 'helloConversationV4':
        return {'connectionId': 'conn-fix'};
      case 'initializeConversationV4':
        return {'ok': true};
      case 'subscribeConversationV4':
        _subAcks++;
        return {
          'ack': {
            'subscriptionId': 'sub-$_subAcks',
            'mode': conversationAckMode,
            'logEpoch': conversationAckEpoch,
          },
        };
      case 'subscribeSessionsIndexV4':
        return {
          'ack': {'subscriptionId': 'si-1', 'mode': 'snapshot'},
        };
      case 'subscribeTasksIndexV4':
        return {
          'ack': {'subscriptionId': 'ti-1', 'mode': 'snapshot'},
        };
      case 'sendConversationCommandV4':
        final envelope =
            (calls.last.$2['envelope'] as Map).cast<String, dynamic>();
        if (envelope['type'] == 'createSession') {
          final gate = createSessionGate;
          if (gate != null) {
            createSessionGate = null;
            await gate.future;
          }
          return createSessionReply;
        }
        return {'status': 'accepted'};
      default:
        return <String, dynamic>{};
    }
  }

  @override
  void Function() addEventListener(
    String channel,
    String event,
    void Function(dynamic event) onEvent, {
    Object? arg,
  }) {
    frameListeners[event] = onEvent;
    return () {
      frameListeners.remove(event);
    };
  }

  /// 向会话订阅注入一帧（v4 wire 包装 + topic 路由由本方法补齐）。
  void emitConversationFrame(String sessionId, Map<String, dynamic> inner) {
    frameListeners['onDynamicConversationFrame']?.call({
      'topic': 'conversation/$sessionId',
      'kind': 'complete',
      'frame': inner,
    });
  }

  int countOf(String method) => calls.where((c) => c.$1 == method).length;

  Map<String, dynamic> lastCommandEnvelope(String type) {
    for (final call in calls.reversed) {
      if (call.$1 != 'sendConversationCommandV4') continue;
      final envelope = call.$2['envelope'];
      if (envelope is Map && envelope['type'] == type) {
        return envelope.cast<String, dynamic>();
      }
    }
    throw StateError('未找到 $type 的 sendConversationCommandV4 信封');
  }
}

class _FixBridge implements BridgeSession {
  final _FixChannel channel = _FixChannel();

  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) async {}
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  RpcFrameTransport get transport => throw UnimplementedError();
  @override
  ChannelClient get channels => channel;
  @override
  String? get workspaceKey => 'ws-fix';
  @override
  String? get initialTaskId => null;
  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) => throw UnimplementedError();
  @override
  void dispose() {}
}

Map<String, dynamic> _snapshotFrame({
  required String logEpoch,
  List<Map<String, dynamic>> rows = const [],
  int? firstRowId,
  int totalCount = 0,
  int toSeq = 1,
  Map<String, dynamic>? control,
  int revision = 0,
}) => {
  'toSeq': toSeq,
  'payload': {
    'kind': 'snapshot',
    'snapshot': {
      'logEpoch': logEpoch,
      'revision': revision,
      'rows': {
        'window': rows,
        'totalCount': totalCount,
        'firstRowId': firstRowId,
      },
      if (control != null) 'control': control,
    },
  },
};

Map<String, dynamic> _deltaFrame({
  required int fromSeq,
  required int toSeq,
  required List<Map<String, dynamic>> deltas,
}) => {
  'fromSeq': fromSeq,
  'toSeq': toSeq,
  'payload': {'kind': 'deltas', 'deltas': deltas},
};

/// 轮询等待（测试环境负载下事件循环被拉长，上限 2s）。
Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('等待条件超时');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  late _FixBridge bridge;
  late ConversationTransport conv;

  setUp(() {
    bridge = _FixBridge();
    conv = ConversationTransport(
      session: bridge,
      scope: const {'workspacePath': r'C:\demo'},
    );
  });

  group('createSession 结果语义', () {
    test('duplicate 与 accepted 等价：返回 result.sessionId（修复前红）', () async {
      bridge.channel.createSessionReply = {
        'status': 'duplicate',
        'result': {'type': 'createSession', 'sessionId': 's-dup'},
      };
      final sid = await conv.createSession('ws-1');
      expect(sid, 's-dup', reason: 'A1 同 ID 重发命中幂等表=任务已建好');
    });

    test('pendingCreateSessionCommandId：在飞可查，成功迁位后清空', () async {
      final gate = Completer<void>();
      bridge.channel.createSessionGate = gate;
      final future = conv.createSession('ws-1', firstText: 'hi');
      // 等命令信封发出。
      await _until(
        () => bridge.channel.countOf('sendConversationCommandV4') > 0,
      );
      final commandId = conv.pendingCreateSessionCommandId();
      expect(commandId, isNotNull, reason: '在飞/结果未知窗口必须可按 pending 确权');
      gate.complete();
      final sid = await future;
      expect(conv.pendingCreateSessionCommandId(), isNull);
      expect(conv.lastCommandIdOf(sid), commandId,
          reason: '成功后 commandId 迁到真实会话键');
    });

    test('明确拒绝清 pending 确权位（超时等未知结果不在此列）', () async {
      bridge.channel.createSessionReply = {
        'status': 'rejected',
        'reasonCode': 'proto.invalidPayload',
      };
      await expectLater(
        conv.createSession('ws-1'),
        throwsA(isA<StateError>()),
      );
      expect(conv.pendingCreateSessionCommandId(), isNull,
          reason: '已知结论无需再核对（A3 只服务"结果未知"）');
    });

    test('payload 不再携带官方 schema 外的 runtimeModel', () async {
      await conv.createSession('ws-1');
      final envelope = bridge.channel.lastCommandEnvelope('createSession');
      final payload = (envelope['payload'] as Map).cast<String, dynamic>();
      expect(payload.containsKey('runtimeModel'), isFalse,
          reason: '官方 createSession schema 无此键（zod 静默剥离）');
    });
  });

  group('stop expectedForegroundExecutionId', () {
    test('取 control.activeWorks 首个非空 foregroundExecutionId 进 payload', () async {
      final sub = await conv.subscribe('s-stop');
      addTearDown(sub.dispose);
      sub.state.applyFrame(
        _snapshotFrame(
          logEpoch: 'e1',
          control: {
            'phase': 'running',
            'activeWorks': [
              {'kind': 'compact', 'startedAt': 1},
              {'kind': 'primaryTurn', 'foregroundExecutionId': 'exec-1'},
            ],
          },
        ),
        onGap: () => fail('不应 gap'),
      );
      await conv.stop('s-stop');
      final envelope = bridge.channel.lastCommandEnvelope('stop');
      expect(
        (envelope['payload'] as Map)['expectedForegroundExecutionId'],
        'exec-1',
        reason: '防迟到 stop 误杀下一轮（官方 command.ts:163-166）',
      );
    });

    test('无活跃执行时不带该键（官方可选字段）', () async {
      final sub = await conv.subscribe('s-stop-2');
      addTearDown(sub.dispose);
      sub.state.applyFrame(
        _snapshotFrame(logEpoch: 'e1', control: {'phase': 'idle'}),
        onGap: () => fail('不应 gap'),
      );
      await conv.stop('s-stop-2');
      final envelope = bridge.channel.lastCommandEnvelope('stop');
      expect((envelope['payload'] as Map).containsKey('expectedForegroundExecutionId'),
          isFalse);
    });
  });

  group('工作区键归一（官方 resolveWorkspaceKey）', () {
    test('空白 workspaceIdentity 回退 workspacePath（修复前红）', () async {
      final bridge2 = _FixBridge();
      final conv2 = ConversationTransport(
        session: bridge2,
        scope: const {
          'workspacePath': r'C:\ws-path',
          'workspaceIdentity': '   ',
        },
      );
      final si = await conv2.subscribeSessionsIndex(maxAttempts: 1);
      addTearDown(si.dispose);
      expect(si.topic, r'sessions-index/C:\ws-path',
          reason: '桌面按 path 建主题；空 identity 订阅永不命中=任务列表停更');
    });

    test('非空 identity 取 trim 后值', () async {
      final bridge2 = _FixBridge();
      final conv2 = ConversationTransport(
        session: bridge2,
        scope: const {
          'workspacePath': r'C:\ws-path',
          'workspaceIdentity': '  ident-1  ',
        },
      );
      final si = await conv2.subscribeSessionsIndex(maxAttempts: 1);
      addTearDown(si.dispose);
      expect(si.topic, 'sessions-index/ident-1');
    });

    test('tasksIndexAddressKey 同款回退（空 identity→path）', () {
      final byPath = tasksIndexAddressKey({
        'workspacePath': r'C:\a',
        'workspaceIdentity': '  ',
        'taskId': 't1',
      });
      final byPathPlain = tasksIndexAddressKey({
        'workspacePath': r'C:\a',
        'taskId': 't1',
      });
      expect(byPath, byPathPlain);
    });
  });

  group('firstRowId nullable 落地', () {
    test('空分支快照的 null 清掉旧游标（修复前红：旧值残留→canLoadOlder 恒真）',
        () {
      final state = ConversationState();
      state.applyFrame(
        _snapshotFrame(
          logEpoch: 'e1',
          rows: [
            {'rowId': 94, 'kind': 'assistantText', 'text': 't94'},
            {'rowId': 95, 'kind': 'assistantText', 'text': 't95'},
          ],
          totalCount: 300,
          firstRowId: 1,
        ),
        onGap: () => fail('不应 gap'),
      );
      expect(state.firstRowId, 1);
      state.applyFrame(
        _snapshotFrame(logEpoch: 'e2', rows: const [], totalCount: 0, firstRowId: null),
        onGap: () => fail('不应 gap'),
      );
      expect(state.firstRowId, isNull,
          reason: '官方 firstRowId nullable，null=空分支（snapshot.ts:464）');
      expect(state.canLoadOlder, isFalse, reason: '空行窗口不该露历史入口');
    });
  });

  group('resync 丢弃 pre-snapshot patch', () {
    test('resync 后旧 state.updated patch 不得叠到新快照（修复前红）', () async {
      final sub = await conv.subscribe('s-patch');
      addTearDown(sub.dispose);
      // patch 先于任何快照到达 → 进 _pendingPatch 缓冲。
      sub.state.applyFrame(
        _deltaFrame(
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
        onGap: () => fail('不应 gap'),
      );
      expect(sub.state.snapshot, isNull, reason: 'patch 先到=仅缓冲');
      // 无 applied base 的 delta 触发 resync（同时应清掉缓冲）。
      bridge.channel.emitConversationFrame('s-patch', {
        'subscriptionId': sub.subscriptionId,
        ..._deltaFrame(fromSeq: 1, toSeq: 2, deltas: const []),
      });
      await Future<void>.delayed(Duration.zero);
      expect(bridge.channel.countOf('resyncConversationV4'), 1);
      // resync 后的权威快照落地：旧 patch 不得混入。
      sub.state.applyFrame(
        _snapshotFrame(
          logEpoch: 'e2',
          toSeq: 9,
          control: {'phase': 'idle'},
        ),
        onGap: () => fail('不应 gap'),
      );
      expect(sub.state.control?['phase'], 'idle',
          reason: '旧 patch（running）叠新快照=投影内容错代');
    });
  });

  group('applied-base 门（官方 subscriptionHasAppliedBase）', () {
    test('ACK(snapshot) 后 delta 先到→resync，不拼旧投影（修复前红）', () async {
      final sub = await conv.subscribe('s-base');
      addTearDown(sub.dispose);
      expect(sub.subscriptionId, isNotNull);
      // 组装中的 delta：fromSeq 恰好等于本地 seq 也不得应用。
      bridge.channel.emitConversationFrame('s-base', {
        'subscriptionId': sub.subscriptionId,
        ..._deltaFrame(
          fromSeq: 0,
          toSeq: 1,
          deltas: [
            {
              'op': 'row.appended',
              'row': {'rowId': 1, 'kind': 'assistantText', 'text': 'x'},
            },
          ],
        ),
      });
      await Future<void>.delayed(Duration.zero);
      expect(bridge.channel.countOf('resyncConversationV4'), 1,
          reason: '无基底 delta 必须 requestRecovery，不得拼旧状态');
      expect(sub.state.rows, isEmpty);

      // 正常路径不改变：snapshot 落地 → 后续 delta 正常应用。
      bridge.channel.emitConversationFrame('s-base', {
        'subscriptionId': sub.subscriptionId,
        ..._snapshotFrame(logEpoch: 'e1', toSeq: 5),
      });
      expect(sub.state.ready, isTrue);
      bridge.channel.emitConversationFrame('s-base', {
        'subscriptionId': sub.subscriptionId,
        ..._deltaFrame(
          fromSeq: 5,
          toSeq: 6,
          deltas: [
            {
              'op': 'row.appended',
              'row': {'rowId': 1, 'kind': 'assistantText', 'text': 'x'},
            },
          ],
        ),
      });
      expect(sub.state.rows, hasLength(1));
      expect(bridge.channel.countOf('resyncConversationV4'), 1,
          reason: '基底就绪后的 delta 不再触发 resync');
    });
  });

  group('CAS 信封形状（官方 COMMANDS_REQUIRING_BASE_REVISION）', () {
    test('CAS 全集带 baseRevision；ROW_TARGETING 另带 baseLogEpoch；非 CAS 不带',
        () async {
      final sub = await conv.subscribe('s-cas');
      addTearDown(sub.dispose);
      sub.state.applyFrame(
        _snapshotFrame(logEpoch: 'e-cas', toSeq: 3, revision: 7),
        onGap: () => fail('不应 gap'),
      );

      const rowTarget = {'rowId': 1};
      final casPayloads = <String, Map<String, dynamic>>{
        'applyFileRewind': {'target': rowTarget},
        'forkAssistant': {'target': rowTarget},
        'editUserQuery': {'target': rowTarget, 'newText': 'x'},
        'retryTurn': {'target': rowTarget},
        'setAssistantFeedback': {'target': rowTarget, 'feedback': 'like'},
        'sendQueuedNow': {'queueItemId': 'q1'},
        'editQueueItem': {'queueItemId': 'q1', 'newText': 'x'},
        'reorderQueueItem': {
          'queueItemId': 'q1',
          'beforeQueueItemId': 'q0',
        },
        'deleteQueueItem': {'queueItemId': 'q1'},
        'setAutoDrain': {'autoDrain': true},
        'switchModelConfig': {
          'provider': 'glm',
          'model': 'glm-5',
          'thought': 'max',
        },
        'switchCollaborationMode': {'mode': 'build'},
        'setFollowupMode': {'mode': 'queue'},
        'pauseGoal': const <String, dynamic>{},
        'resumeGoal': const <String, dynamic>{},
      };
      const rowTargeting = {
        'applyFileRewind',
        'forkAssistant',
        'editUserQuery',
        'retryTurn',
        'setAssistantFeedback',
      };

      for (final entry in casPayloads.entries) {
        await conv.sendCommand('s-cas', entry.key, entry.value);
        final envelope = bridge.channel.lastCommandEnvelope(entry.key);
        expect(envelope['baseRevision'], 7,
            reason: '${entry.key} 属官方 CAS 集合，必带 baseRevision');
        if (rowTargeting.contains(entry.key)) {
          expect(envelope['baseLogEpoch'], 'e-cas',
              reason: '${entry.key} 属官方 ROW_TARGETING，必带 baseLogEpoch');
        } else {
          expect(envelope.containsKey('baseLogEpoch'), isFalse,
              reason: '${entry.key} 不在 ROW_TARGETING，不带 baseLogEpoch');
        }
      }

      // 非 CAS：不得夹带 baseRevision/baseLogEpoch（会被服务端判非法）。
      await conv.sendText('s-cas', 'hello');
      await conv.stop('s-cas');
      await conv.sendCompact('s-cas');
      await conv.cancelBackgroundWork('s-cas', 'w1');
      for (final type in ['sendText', 'stop', 'compact', 'cancelBackgroundWork']) {
        final envelope = bridge.channel.lastCommandEnvelope(type);
        expect(envelope.containsKey('baseRevision'), isFalse,
            reason: '$type 非 CAS 命令');
      }
    });
  });
}
