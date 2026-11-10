import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/task_list.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/ipc_codec.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/ui/status_badge.dart';

/// controller/tasks-index：帧状态机 + 行映射 + 模型接线单测。
/// 帧契约 = 官方 windowHostControllerTaskFrameSchema（refs controller.ts:
/// 189-252），语义对齐 windowControllerTaskListRegistry.ts:145-218。
void main() {
  Map<String, dynamic> frame({
    required String subId,
    required String epoch,
    required int fromSeq,
    required int toSeq,
    required Map<String, dynamic> payload,
  }) => {
    'topic': 'controller/tasks-index',
    'subscriptionId': subId,
    'logEpoch': epoch,
    'fromSeq': fromSeq,
    'toSeq': toSeq,
    'sentAt': 1,
    'payload': payload,
  };

  Map<String, dynamic> snapshotPayload(
    String epoch,
    List<Map<String, dynamic>> tasks,
  ) => {
    'kind': 'snapshot',
    'snapshot': {'protocolVersion': 1, 'logEpoch': epoch, 'tasks': tasks},
  };

  Map<String, dynamic> deltasPayload(List<Map<String, dynamic>> deltas) => {
    'kind': 'deltas',
    'deltas': deltas,
  };

  Map<String, dynamic> row(
    String taskId, {
    String? workspaceIdentity,
    String workspacePath = 'G:\\proj',
    String? remote,
    bool archived = false,
    bool pinned = false,
    String liveStatus = 'idle',
    String? status,
    String title = '标题',
    int updatedAt = 2,
    Map<String, dynamic>? activity,
  }) => {
    'address': {
      'remoteSessionId': ?remote,
      'workspacePath': workspacePath,
      'workspaceIdentity': ?workspaceIdentity,
      'taskId': taskId,
    },
    'meta': {
      'taskId': taskId,
      'title': title,
      'createdAt': 1,
      'updatedAt': updatedAt,
      'status': ?status,
    },
    'membership': {'pinned': pinned, 'archived': archived, 'active': !archived},
    'sourceAvailability': 'online',
    'liveStatus': liveStatus,
    if (activity != null) 'activity': activity,
  };

  group('tasksIndexAddressKey', () {
    test('本地源=local；remote 换代即换键；identity 优先于 path', () {
      final local = tasksIndexAddressKey({
        'workspacePath': 'G:\\a',
        'taskId': 't1',
      });
      final remote1 = tasksIndexAddressKey({
        'remoteSessionId': 'r1',
        'workspacePath': 'G:\\a',
        'taskId': 't1',
      });
      final remote2 = tasksIndexAddressKey({
        'remoteSessionId': 'r2',
        'workspacePath': 'G:\\a',
        'taskId': 't1',
      });
      expect(local, isNot(remote1));
      expect(remote1, isNot(remote2));
      expect(
        tasksIndexAddressKey({
          'workspacePath': 'ignored',
          'workspaceIdentity': 'ident',
          'taskId': 't1',
        }),
        tasksIndexAddressKey({
          'workspacePath': 'other',
          'workspaceIdentity': 'ident',
          'taskId': 't1',
        }),
      );
      expect(tasksIndexAddressKey({'taskId': ''}), isNull);
    });
  });

  group('TasksIndexState.applyFrame', () {
    test('快照整表替换并落游标', () {
      final state = TasksIndexState();
      final r = state.applyFrame(frame(
        subId: 's1',
        epoch: 'e1',
        fromSeq: 0,
        toSeq: 5,
        payload: snapshotPayload('e1', [
          row('a', workspaceIdentity: 'ws'),
          row('b', workspaceIdentity: 'ws', archived: true),
        ]),
      ));
      expect(r.applied, isTrue);
      expect(r.gap, isFalse);
      expect(state.hasSnapshot, isTrue);
      expect(state.rows.length, 2);
      expect(state.subscriptionId, 's1');
      expect(state.logEpoch, 'e1');
      expect(state.seq, 5);
    });

    test('第二份快照无条件整替（旧行不残留）', () {
      final state = TasksIndexState();
      state.applyFrame(frame(
        subId: 's1',
        epoch: 'e1',
        fromSeq: 0,
        toSeq: 0,
        payload: snapshotPayload('e1', [row('a'), row('b')]),
      ));
      state.applyFrame(frame(
        subId: 's2',
        epoch: 'e2',
        fromSeq: 0,
        toSeq: 3,
        payload: snapshotPayload('e2', [row('b')]),
      ));
      expect(state.rows.length, 1);
      expect(rowTaskId(state.rows.values.first), 'b');
      expect(state.subscriptionId, 's2');
    });

    test('增量 upsert/remove 按 seq 连续推进', () {
      final state = TasksIndexState();
      state.applyFrame(frame(
        subId: 's1',
        epoch: 'e1',
        fromSeq: 0,
        toSeq: 0,
        payload: snapshotPayload('e1', [row('a'), row('b')]),
      ));
      final r = state.applyFrame(frame(
        subId: 's1',
        epoch: 'e1',
        fromSeq: 0,
        toSeq: 1,
        payload: deltasPayload([
          {'op': 'task.upserted', 'task': row('a', title: '新标题', updatedAt: 9)},
          {
            'op': 'task.removed',
            'address': {'workspacePath': 'G:\\proj', 'taskId': 'b'},
          },
        ]),
      ));
      expect(r.applied, isTrue);
      expect(r.removedIds, ['b']);
      expect(state.rows.length, 1);
      expect(state.seq, 1);
      final a = state.rows.values.first;
      expect((a['meta'] as Map)['title'], '新标题');
    });

    test('remote 重连同帧删旧地址+加新地址：不算移除（不误报 60s 墓碑）', () {
      final state = TasksIndexState();
      state.applyFrame(frame(
        subId: 's1',
        epoch: 'e1',
        fromSeq: 0,
        toSeq: 0,
        payload: snapshotPayload('e1', [row('t', remote: 'r1')]),
      ));
      final r = state.applyFrame(frame(
        subId: 's1',
        epoch: 'e1',
        fromSeq: 0,
        toSeq: 1,
        payload: deltasPayload([
          {
            'op': 'task.removed',
            'address': {'remoteSessionId': 'r1', 'workspacePath': 'G:\\proj', 'taskId': 't'},
          },
          {'op': 'task.upserted', 'task': row('t', remote: 'r2')},
        ]),
      ));
      expect(r.applied, isTrue);
      expect(r.removedIds, isEmpty);
      expect(state.rows.length, 1);
      expect(
        (state.rows.values.first['address'] as Map)['remoteSessionId'],
        'r2',
      );
    });

    test('seq 断档/epoch 换代/异 subId 的 delta = gap，状态不动', () {
      final state = TasksIndexState();
      state.applyFrame(frame(
        subId: 's1',
        epoch: 'e1',
        fromSeq: 0,
        toSeq: 2,
        payload: snapshotPayload('e1', [row('a')]),
      ));
      // 断档：fromSeq 必须 == 当前 seq
      var r = state.applyFrame(frame(
        subId: 's1',
        epoch: 'e1',
        fromSeq: 99,
        toSeq: 100,
        payload: deltasPayload([
          {'op': 'task.upserted', 'task': row('x')},
        ]),
      ));
      expect(r.gap, isTrue);
      // epoch 换代
      r = state.applyFrame(frame(
        subId: 's1',
        epoch: 'e2',
        fromSeq: 2,
        toSeq: 3,
        payload: deltasPayload([
          {'op': 'task.upserted', 'task': row('x')},
        ]),
      ));
      expect(r.gap, isTrue);
      // 异 subId
      r = state.applyFrame(frame(
        subId: 's9',
        epoch: 'e1',
        fromSeq: 2,
        toSeq: 3,
        payload: deltasPayload([
          {'op': 'task.upserted', 'task': row('x')},
        ]),
      ));
      expect(r.gap, isTrue);
      expect(state.rows.length, 1); // 全部未应用
      expect(state.seq, 2);
    });

    test('未知 payload kind 忽略不抛', () {
      final state = TasksIndexState();
      final r = state.applyFrame(frame(
        subId: 's1',
        epoch: 'e1',
        fromSeq: 0,
        toSeq: 0,
        payload: {'kind': 'bogus'},
      ));
      expect(r.applied, isFalse);
      expect(r.gap, isFalse);
      expect(state.hasSnapshot, isFalse);
    });

    test('状态变化才 notify', () {
      final state = TasksIndexState();
      var notifications = 0;
      state.addListener(() => notifications++);
      state.applyFrame(frame(
        subId: 's1',
        epoch: 'e1',
        fromSeq: 0,
        toSeq: 0,
        payload: snapshotPayload('e1', [row('a')]),
      ));
      expect(notifications, 1);
      // 空增量（无 upsert/remove 命中）不通知
      state.applyFrame(frame(
        subId: 's1',
        epoch: 'e1',
        fromSeq: 0,
        toSeq: 1,
        payload: deltasPayload([]),
      ));
      expect(notifications, 1);
    });
  });

  group('controllerRowToTaskMap', () {
    test('offPeakTaskId 随 meta 携带（B 批白名单补收）', () {
      final m = controllerRowToTaskMap({
        ...row('t'),
        'meta': {'taskId': 't', 'offPeakTaskId': 'op-7'},
      });
      expect(m['offPeakTaskId'], 'op-7');
      // 无字段行=null（普通任务）。
      expect(controllerRowToTaskMap(row('t2'))['offPeakTaskId'], isNull);
    });

    test('完整映射：displayStatus←liveStatus，membership→archived/pinned', () {
      final m = controllerRowToTaskMap(row(
        't1',
        workspaceIdentity: 'ws-a',
        pinned: true,
        liveStatus: 'running',
        updatedAt: 77,
      ));
      expect(m['taskId'], 't1');
      expect(m['workspaceIdentity'], 'ws-a');
      expect(m['workspacePath'], 'G:\\proj');
      expect(m['archived'], isFalse);
      expect(m['pinned'], isTrue);
      expect(m['displayStatus'], 'running');
      expect(m['status'], 'running');
      expect(m['updatedAt'], 77);
    });

    test('waiting 新词直传（徽标单源已补"待处理"）', () {
      final m = controllerRowToTaskMap(row('t', liveStatus: 'waiting'));
      expect(m['displayStatus'], 'waiting');
      expect(taskPhaseBadge(AppThemeSpec.light.colors, normalizePhase('waiting')).label, '待处理');
    });

    test('idle 时只信持久终态——SQLite 残留 running 不复活（官方 defaultLiveStatus）', () {
      expect(controllerRowToTaskMap(row('a', status: 'running'))['status'], 'idle');
      expect(
        controllerRowToTaskMap(row('b', status: 'completed'))['status'],
        'completed',
      );
      expect(controllerRowToTaskMap(row('c', status: 'error'))['status'], 'error');
      expect(controllerRowToTaskMap(row('d'))['status'], 'idle');
    });

    test('archived 行与 searchSnippets 透传', () {
      final m = controllerRowToTaskMap({
        ...row('t', archived: true),
        'searchSnippets': const ['正文片段'],
      });
      expect(m['archived'], isTrue);
      expect(m['searchSnippets'], const ['正文片段']);
    });

    // 状态层批：activity 两分支（hasBackgroundWork / workflowActivity.runs）
    // 此前夹具无 activity 字段 = 零覆盖。
    test('activity 映射：hasBackgroundWork 与 workflowActivity.runs 透传，缺省为 null', () {
      final m = controllerRowToTaskMap(row(
        't-a',
        activity: {
          'hasBackgroundWork': true,
          'workflowActivity': {
            'runs': [
              {'runId': 'r1', 'status': 'running'},
            ],
          },
        },
      ));
      expect(m['hasBackgroundWork'], isTrue);
      final activity = m['workflowActivity'] as Map;
      expect((activity['runs'] as List).single['runId'], 'r1');

      final empty = controllerRowToTaskMap(row('t-b'));
      expect(empty['hasBackgroundWork'], isNull);
      expect(empty['workflowActivity'], isNull);
    });
  });

  group('TaskListModel × controller 行映射（接线）', () {
    test('当前工作区行喂 applyWorkspaceListTasks：新增/归档剔除/置顶落集', () {
      final si = SessionsIndexState()..ready = true;
      final model = TaskListModel(sessions: si, workspaceKey: 'ws-a');
      model.applyChannelLists(
        active: const [
          {'taskId': 't1', 'title': '任务1'},
        ],
        pinnedIds: const [],
        archivedIds: const [],
      );
      model.applyWorkspaceListTasks([
        // 未知 id 但属于当前工作区 → 接受为历史任务卡
        controllerRowToTaskMap(row('t2', workspaceIdentity: 'ws-a', title: '新增')),
        // 已知 id 被归档 → 剔除
        controllerRowToTaskMap(row('t1', workspaceIdentity: 'ws-a', archived: true)),
        // 跨工作区未知 id → 拒绝
        controllerRowToTaskMap(row('tx', workspaceIdentity: 'ws-b', title: '别区')),
      ], 'ws-a');
      expect(
        model.cards.map((c) => c.sessionId),
        contains('t2'),
      );
      expect(model.cards.map((c) => c.sessionId), isNot(contains('t1')));
      expect(model.cards.map((c) => c.sessionId), isNot(contains('tx')));
    });

    test('pinned 标志实时落集（workspace-list 时代不落集的缺口补上）', () {
      final si = SessionsIndexState()..ready = true;
      final model = TaskListModel(sessions: si, workspaceKey: 'ws-a');
      model.applyChannelLists(
        active: const [
          {'taskId': 't1', 'title': '任务1'},
        ],
        pinnedIds: const [],
        archivedIds: const [],
      );
      model.applyWorkspaceListTasks([
        controllerRowToTaskMap(row('t1', workspaceIdentity: 'ws-a', pinned: true)),
      ], 'ws-a');
      expect(model.cards.firstWhere((c) => c.sessionId == 't1').pinned, isTrue);
      // 再推 pinned:false → 实时取消
      model.applyWorkspaceListTasks([
        controllerRowToTaskMap(row('t1', workspaceIdentity: 'ws-a', pinned: false)),
      ], 'ws-a');
      expect(model.cards.firstWhere((c) => c.sessionId == 't1').pinned, isFalse);
    });

    test('取消归档（archived:false）实时恢复', () {
      final si = SessionsIndexState()..ready = true;
      final model = TaskListModel(sessions: si, workspaceKey: 'ws-a');
      model.applyChannelLists(
        active: const [],
        pinnedIds: const [],
        archivedIds: const ['t1'],
      );
      expect(model.cards.map((c) => c.sessionId), isNot(contains('t1')));
      model.applyWorkspaceListTasks([
        controllerRowToTaskMap(row('t1', workspaceIdentity: 'ws-a', title: '恢复')),
      ], 'ws-a');
      expect(model.cards.map((c) => c.sessionId), contains('t1'));
    });
  });

  group('waiting 徽标', () {
    test('taskPhaseBadge 词表含 waiting→待处理，未知词兜底空闲', () {
      expect(taskPhaseBadge(AppThemeSpec.light.colors, 'waiting').label, '待处理');
      expect(taskPhaseBadge(AppThemeSpec.light.colors, 'idle').label, '空闲');
      expect(taskPhaseBadge(AppThemeSpec.light.colors, 'nonsense').label, '空闲');
    });
  });

  group('TasksIndexSubscription 静默看门狗（开源审查 G1 P2-4/G2 P2-4）', () {
    // tasks-index 此前是三个订阅类中唯一没有静默看门狗的：半开连接/桌面
    // 停推时任务列表永久冻结在旧水位。对照 si 的、看门狗补齐。
    test('快照静默 >90s 未到达 → fresh 重订阅', () {
      fakeAsync((async) async {
        final bridge = _TiBridge();
        final conv = ConversationTransport(
          session: bridge,
          scope: const {'workspacePath': r'G:\Demo App'},
        );
        final sub = await conv.subscribeTasksIndex();
        addTearDown(sub.dispose);
        expect(bridge.channel.subscribeCalls, 1);

        // 无任何帧到达（快照丢失/订阅被静默驱逐）→ 90s 静默后看门狗重订阅。
        async.elapse(const Duration(seconds: 95));
        expect(
          bridge.channel.subscribeCalls,
          2,
          reason: '红：旧实现无看门狗——快照静默时任务列表永久转圈',
        );
      });
    });

    test('有快照+running 行静默 >90s → forceSnapshot resync', () {
      fakeAsync((async) async {
        final bridge = _TiBridge();
        final conv = ConversationTransport(
          session: bridge,
          scope: const {'workspacePath': r'G:\Demo App'},
        );
        final sub = await conv.subscribeTasksIndex();
        addTearDown(sub.dispose);
        // 投一帧含 running 行的快照（经事件监听真实路径）。
        bridge.channel.fireEvent(0, {
          'topic': 'controller/tasks-index',
          'subscriptionId': 'sub-1',
          'logEpoch': 'e1',
          'fromSeq': 0,
          'toSeq': 0,
          'payload': {
            'kind': 'snapshot',
            'snapshot': {
              'tasks': [
                row('t-run', workspaceIdentity: 'ws', liveStatus: 'running'),
              ],
            },
          },
        });
        expect(sub.state.hasSnapshot, isTrue);
        expect(bridge.channel.resyncCalls, 0);

        // 之后连接半开静默：任务行停在 running、无新帧——看门狗 resync。
        async.elapse(const Duration(seconds: 95));
        expect(
          bridge.channel.resyncCalls,
          1,
          reason: '红：旧实现丢最后一帧后无任何机制发现停滞',
        );
      });
    });
  });
}

/// window-controller 通道 fake（tasks-index 看门狗测试）。
class _TiChannel extends ChannelClient {
  _TiChannel() : super(sendBody: (_) {});

  int subscribeCalls = 0;
  int resyncCalls = 0;

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    switch (method) {
      case 'helloConversationV4':
        return {'connectionId': 'conn-ti'};
      case 'initializeConversationV4':
        return {'ok': true};
      case 'subscribeControllerV4':
        subscribeCalls++;
        return {
          'ack': {
            'subscriptionId': 'sub-$subscribeCalls',
            'mode': 'snapshot',
          },
        };
      case 'unsubscribeControllerV4':
        return {'ok': true};
      case 'resyncControllerV4':
        resyncCalls++;
        return {'ok': true};
      default:
        return <String, dynamic>{};
    }
  }

  /// 向 [listenerId] 触发一帧事件（真实 IPC 编码路径）。
  void fireEvent(int listenerId, Map<String, dynamic> data) {
    final writer = ValueWriter();
    encodeValue(writer, [ChannelClient.resEventFire, listenerId]);
    encodeValue(writer, data);
    handleMessage(writer.toBytes());
  }
}

class _TiBridge implements BridgeSession {
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
  final _TiChannel channel = _TiChannel();
  @override
  String? get workspaceKey => 'ws-ti';
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
