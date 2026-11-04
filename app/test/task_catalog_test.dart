import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/state/task_catalog.dart';
import 'package:zcode_pocket/state/task_list.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';

class _Channels implements ChannelClient {
  Object? readTreeError;
  final calls = <String>[];

  /// 按方法名注入应答（loadTaskIndex 四路 RPC 的脚本化应答）。
  final responses = <String, dynamic>{};

  @override
  Future<dynamic> call(
    String channel,
    String method,
    List<Object?> args, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add(method);
    if (responses.containsKey(method)) return responses[method];
    if (method == 'readTree' && readTreeError != null) throw readTreeError!;
    if (method == 'readTree') {
      return {
        'projects': [
          {'id': 'p-new', 'name': '新项目', 'roots': <Object?>[]},
        ],
        'tasks': <Object?>[],
      };
    }
    return <Object?>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Bridge implements BridgeSession {
  final channelsImpl = _Channels();
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  ChannelClient get channels => channelsImpl;
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  RpcFrameTransport get transport => throw UnimplementedError();
  @override
  String? get workspaceKey => 'ws';
  @override
  String? get initialTaskId => null;
  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) => throw UnimplementedError();
  @override
  Future<void> waitHealthy({Duration timeout = const Duration(seconds: 45)}) async {}
  @override
  void dispose() {}
}

class _TasksSub implements TasksIndexSubscription {
  _TasksSub(this.onDispose);
  @override
  final TasksIndexState state = TasksIndexState();
  @override
  void Function(List<String> removedTaskIds)? onRowsRemoved;
  final void Function() onDispose;
  bool _disposed = false;
  @override
  bool get isDisposed => _disposed;
  @override
  String? get subscriptionId => 'ti';
  @override
  String get topic => 'controller/tasks-index';
  @override
  Future<void> dispose() async {
    _disposed = true;
    onDispose();
  }
}

class _SiSub implements SessionsIndexSubscription {
  @override
  final SessionsIndexState state = SessionsIndexState();
  @override
  bool get isDisposed => false;
  @override
  String? get subscriptionId => 'si';
  @override
  String get topic => 'sessions-index/ws';
  @override
  Future<void> dispose() async {}
}

class _Conv implements ConversationTransport {
  _Conv(this.subscription);
  final TasksIndexSubscription subscription;
  @override
  Future<TasksIndexSubscription> subscribeTasksIndex({
    int maxAttempts = 2,
  }) async => subscription;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness({TasksIndexSubscription? tasksSubscription}) {
    tasksSubscription ??= _TasksSub(() {});
    conversation = _Conv(tasksSubscription);
    catalog = TaskCatalog(
      bridgeProvider: () => bridge,
      conversationProvider: () => conversation,
      activeWorkspaceProvider: () => activeWorkspace,
      workspacesProvider: () => workspaces,
      disposedProvider: () => disposed,
      onLog: (_) {},
      onNotify: () => notifyCount++,
      onCacheWrite: () => cacheWrites++,
      onTaskListChanged: () => modelNotifications++,
      onTaskListRebuilt: rebuilt.add,
    );
  }

  final bridge = _Bridge();
  late final _Conv conversation;
  late final TaskCatalog catalog;
  final activeWorkspace = <String, dynamic>{'workspacePath': 'G:/示例项目'};
  final workspaces = <Map<String, dynamic>>[
    {'workspacePath': 'G:/示例项目'},
  ];
  final rebuilt = <TaskListModel?>[];
  bool disposed = false;
  int notifyCount = 0;
  int cacheWrites = 0;
  int modelNotifications = 0;
}

DeviceCacheEntry _cache() => DeviceCacheEntry(
  deviceSid: 'sid',
  workspaces: const [],
  activeWorkspace: null,
  desktopAppVersion: null,
  sessions: const [],
  channelActive: const [
    {'taskId': 'cached-task', 'title': '缓存任务'},
  ],
  pinnedIds: const ['cached-task'],
  archivedIds: const [],
  savedAt: 1,
);

void main() {
  test('attach/detach 释放模型监听、tasks-index、Timer 与 recovered 监听', () async {
    final order = <String>[];
    final ti = _TasksSub(() => order.add('ti'));
    final h = _Harness(tasksSubscription: ti);
    await h.catalog.subscribeTasksIndex();
    expect(ti.onRowsRemoved, isNotNull);
    final si = _SiSub();
    final model = h.catalog.replaceTaskList(si, 'ws', dormant: true);
    expect(h.rebuilt.last, same(model));
    h.catalog.attachBridge(h.bridge);
    ti.onRowsRemoved?.call(['removed-task']);

    await h.catalog.detach(
      beforeTasksIndexDispose: () async => order.add('si'),
    );
    expect(order, ['si', 'ti']);
    expect(h.catalog.taskList, isNull);
    expect(h.catalog.tasksIndex, isNull);
    expect(h.rebuilt.last, isNull);
    final calls = h.bridge.channelsImpl.calls.length;
    h.bridge.recovered.value++;
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(
      h.bridge.channelsImpl.calls.length,
      calls,
      reason: 'detach 后 recovered 与 1200ms Timer 均不得再触发重载',
    );
  });

  test('readTree 失败保留旧 projects 且状态为 failed', () async {
    final h = _Harness();
    final old = [
      {'id': 'p-old', 'name': '旧项目'},
    ];
    h.catalog.projects = old;
    h.bridge.channelsImpl.readTreeError = StateError('offline');
    await h.catalog.loadProjects();
    expect(h.catalog.projects, same(old));
    expect(h.catalog.readTreeStatus, 'failed');
  });

  test('tasks-index 已有快照时 workspace-list 不覆盖', () async {
    final ti = _TasksSub(() {});
    ti.state.logEpoch = 'epoch-1';
    final h = _Harness(tasksSubscription: ti);
    await h.catalog.subscribeTasksIndex();
    expect(h.catalog.hasTasksIndexSnapshot, isTrue);
    h.catalog.storeWorkspaceTasks([
      {'taskId': 'workspace-list-task'},
    ]);
    expect(h.catalog.workspaceTasks, isEmpty);
    h.catalog.applyWorkspaceListTasks([
      {'taskId': 'workspace-list-task'},
    ]);
    expect(h.catalog.workspaceTasks, isEmpty);
    await h.catalog.detach();
  });

  test('dormant 降级与复活只替换一份 TaskListModel，缓存导出沿用同一模型', () async {
    final h = _Harness();
    final sessions = SessionsIndexState();
    final cachedModel = h.catalog.seedCachedModel(
      cached: _cache(),
      sessions: sessions,
      workspaceKey: 'ws',
    );
    expect(cachedModel.dormant, isTrue);
    expect(cachedModel.channelTasksForCache.single['taskId'], 'cached-task');

    final revived = h.catalog.replaceTaskList(_SiSub(), 'ws', dormant: false);
    expect(revived.dormant, isFalse);
    expect(h.catalog.taskList, same(revived));
    expect(h.rebuilt, [cachedModel, revived]);
    await h.catalog.detach();
  });

  test('模型变更与动态重建回调保持单源通知', () async {
    final h = _Harness();
    final first = h.catalog.replaceTaskList(_SiSub(), 'ws', dormant: true);
    first.applyWorkspaceListTasks(const [
      {
        'taskId': 't1',
        'workspaceIdentity': 'ws',
        'title': '任务',
        'updatedAt': 1,
      },
    ], 'ws');
    expect(h.modelNotifications, greaterThan(0));
    final second = h.catalog.replaceTaskList(_SiSub(), 'ws', dormant: false);
    expect(h.rebuilt, [first, second]);
    expect(h.catalog.taskList, same(second));
    await h.catalog.detach();
    expect(h.rebuilt.last, isNull);
  });

  test(
    'loadTaskIndex 全空守卫纳入 deleted（J1-4/J3 P1-2/L2/L3 四路）：三列表真空+deleted 非空=合法终态放行，负向 join 清掉已删卡',
    () async {
      final h = _Harness();
      h.bridge.channelsImpl.responses['listTasks'] = [
        {'taskId': 't1', 'title': '任务1'},
      ];
      final model = h.catalog.replaceTaskList(_SiSub(), 'ws', dormant: true);
      await h.catalog.loadTaskIndex();
      expect(model.cards.map((c) => c.sessionId), ['t1']);
      expect(model.channelLoaded, isTrue);

      // 既有抖动保护回归钉：四列表全空+已加载 → 仍按桥抖动跳过。
      h.bridge.channelsImpl.responses['listTasks'] = <Object?>[];
      await h.catalog.loadTaskIndex();
      expect(model.cards.map((c) => c.sessionId), ['t1'],
          reason: '全空+deleted 空=疑似桥抖动，保持既有数据');

      // 删光最后一个任务（官方 listTasks 契约=所有已持久化任务，含软删
      // 墓碑行）：三列表真空但 listDeletedTaskIds=['t1']——修复前守卫把
      // 这批成功结果当桥抖动丢弃，deletedIds 永不应用，60s 本地墓碑过期
      // 后已删任务复活驻留。
      h.bridge.channelsImpl.responses['listDeletedTaskIds'] = <String>['t1'];
      await h.catalog.loadTaskIndex();
      expect(model.cards, isEmpty, reason: 'deletedIds 负向 join 必须应用');
      expect(model.deletedIdsForCache, ['t1']);
      expect(h.catalog.archivedTasks, isEmpty);
      await h.catalog.detach();
    },
  );

  // J3-P2-2（批C 组3 守卫铺满）：tasks-index 行映射排序对
  // updatedAt 硬转换 `as num?`——单条畸形行抛 TypeError 落进
  // _acceptLogicalFrame 的 catch 触发 resync，快照重放再抛=无界循环。
  // 修复=安全读取（payload_guard.intOf，String 数字容忍解析、非数字
  // 按 0 兜底），notifyListeners 不得再抛。
  test('tasks-index 行 updatedAt 形态漂移不打断映射排序', () async {
    final ti = _TasksSub(() {});
    ti.state.logEpoch = 'e1';
    final h = _Harness(tasksSubscription: ti);
    await h.catalog.subscribeTasksIndex();
    ti.state.rows['k1'] = {
      'address': {'taskId': 't1', 'workspacePath': 'G:/示例项目'},
      'meta': {'taskId': 't1', 'title': 'A', 'updatedAt': '900'},
    };
    ti.state.rows['k2'] = {
      'address': {'taskId': 't2', 'workspacePath': 'G:/示例项目'},
      'meta': {'taskId': 't2', 'title': 'B', 'updatedAt': 100},
    };
    expect(() => ti.state.notifyListeners(), returnsNormally);
    expect(h.catalog.workspaceTasks, hasLength(2));
    expect(h.catalog.workspaceTasks.first['taskId'], 't1',
        reason: "'900' 容忍解析为 900 > 100，排序不变");
    await h.catalog.detach();
  });
}
