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

  /// 按方法注入失败（loadTaskIndex 单路失败保留用例）。
  final errors = <String, Object>{};

  /// 按方法注入闸门（在飞/代际用例）。
  final gates = <String, Completer<void>>{};
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
    final gate = gates[method];
    if (gate != null) await gate.future;
    final error = errors[method];
    if (error != null) throw error;
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

/// 订阅落地可闸门的传输（pause 与 subscribe 竞态用例）。
class _GatedTasksConv implements ConversationTransport {
  final gate = Completer<TasksIndexSubscription>();
  @override
  Future<TasksIndexSubscription> subscribeTasksIndex({
    int maxAttempts = 2,
  }) => gate.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness({
    TasksIndexSubscription? tasksSubscription,
    ConversationTransport? conversationTransport,
  }) {
    tasksSubscription ??= _TasksSub(() {});
    conversation = _Conv(tasksSubscription);
    conversationOverride = conversationTransport;
    catalog = TaskCatalog(
      bridgeProvider: () => bridge,
      conversationProvider: () => conversationOverride ?? conversation,
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
  ConversationTransport? conversationOverride;
  ConversationTransport get conv => conversationOverride ?? conversation;
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

  // （批C 组3 守卫铺满）：tasks-index 行映射排序对
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

  // 1.0.1 真机验收⑩：保活分支后台退订 tasks-index——旧订阅的 state
  // 通知不再驱动 catalog（5s notify 帧断流）；数据保留；resume 重订阅。
  test('pauseTasksIndexForBackground：断流+数据保留+resume 重订阅', () async {
    final ti = _TasksSub(() {});
    ti.state.logEpoch = 'e1';
    final h = _Harness(tasksSubscription: ti);
    await h.catalog.subscribeTasksIndex();
    ti.state.rows['k1'] = {
      'address': {'taskId': 't1', 'workspacePath': 'G:/示例项目'},
      'meta': {'taskId': 't1', 'title': 'A', 'updatedAt': 100},
    };
    ti.state.notifyListeners();
    expect(h.catalog.workspaceTasks, hasLength(1));

    // pause：订阅拆除（dispose 标记）+数据仍在。
    await h.catalog.pauseTasksIndexForBackground();
    expect(ti.isDisposed, isTrue, reason: '后台退订=拆订阅');
    expect(h.catalog.workspaceTasks, hasLength(1), reason: '数据保留（回前台对账/快照兜底）');
    // 旧 state 再通知（迟到帧模拟）不驱动 catalog——不抛不增。
    expect(() => ti.state.notifyListeners(), returnsNormally);

    // resume：重新订阅（新订阅对象接上——conversation 是 late final，
    // 经可变 provider 间接替换）。
    final ti2 = _TasksSub(() {});
    ti2.state.logEpoch = 'e2';
    h.conversationOverride = _Conv(ti2);
    await h.catalog.resumeTasksIndexFromBackground();
    ti2.state.rows['k1'] = {
      'address': {'taskId': 't1', 'workspacePath': 'G:/示例项目'},
      'meta': {'taskId': 't1', 'title': 'A2', 'updatedAt': 200},
    };
    ti2.state.notifyListeners();
    expect(h.catalog.workspaceTasks.first['title'], 'A2',
        reason: '重订阅后增量帧恢复驱动');
    await h.catalog.detach();
  });

  // 2026-11-05 反馈②A：跨工作区打开任务期间保首页旧列表（SWR 式防闪
  // 「正在加载任务…」）——keepHomePreview 保行+零额外通知；打开失败
  // clearStaleHomePreview 收口恢复 清残留语义；新工作区首帧
  // tasks-index 到达由既有 _onTasksIndexChanged 全量替换并复位标记。
  test('detach(keepHomePreview)：保首页行+stale 标记；clear 收口清空+通知', () async {
    final ti = _TasksSub(() {});
    ti.state.logEpoch = 'e1';
    final h = _Harness(tasksSubscription: ti);
    await h.catalog.subscribeTasksIndex();
    ti.state.rows['k1'] = {
      'address': {'taskId': 't1', 'workspacePath': 'G:/示例项目'},
      'meta': {'taskId': 't1', 'title': 'A', 'updatedAt': 100},
    };
    ti.state.notifyListeners();
    expect(h.catalog.workspaceTasks, hasLength(1));
    expect(h.catalog.homePreviewStale, isFalse);

    // 保数据 detach：旧行保留、stale 置位、不额外 notify（首页继续
    // 显示旧行而不是闪加载态）。
    final notifies = h.notifyCount;
    await h.catalog.detach(keepHomePreview: true);
    expect(h.catalog.workspaceTasks, hasLength(1),
        reason: '旧首页行保留（修复前 detach 即清空→首页闪「正在加载任务…」）');
    expect(h.catalog.homePreviewStale, isTrue);
    expect(h.notifyCount, notifies, reason: '保数据路径零额外通知');

    // 打开失败收口：清空 + 通知（防旧行以新作用域被消费）。
    h.catalog.clearStaleHomePreview();
    expect(h.catalog.workspaceTasks, isEmpty);
    expect(h.catalog.homePreviewStale, isFalse);
    expect(h.notifyCount, greaterThan(notifies));

    // 幂等：非 stale 态再清为 no-op。
    final after = h.notifyCount;
    h.catalog.clearStaleHomePreview();
    expect(h.notifyCount, after);
  });

  // 状态层批：单路 RPC 失败此前被 catchError 归一为空并全量应用——已删
  // 任务复活/归档清空/置顶掉落。修复=失败路保留上一轮对应集合。
  test('loadTaskIndex 单路失败保留上一轮集合（只整替成功路）', () async {
    final h = _Harness();
    final ch = h.bridge.channelsImpl;
    ch.responses['listTasks'] = [
      {'taskId': 't1', 'title': 'A'},
    ];
    ch.responses['listPinnedTasks'] = [
      {'taskId': 't1'},
    ];
    ch.responses['listArchivedTasks'] = [
      {'taskId': 'a1'},
    ];
    ch.responses['listDeletedTaskIds'] = <String>['d1'];
    final model = h.catalog.replaceTaskList(_SiSub(), 'ws', dormant: true);
    await h.catalog.loadTaskIndex();
    expect(model.pinnedIdsForCache, ['t1']);
    expect(model.archivedIdsForCache, ['a1']);
    expect(model.deletedIdsForCache, ['d1']);
    expect(h.catalog.archivedTasks.map((t) => t['taskId']), ['a1']);

    // 置顶/归档/墓碑三路全挂，仅 listTasks 成功。
    ch.errors['listPinnedTasks'] = StateError('pinned down');
    ch.errors['listArchivedTasks'] = StateError('archived down');
    ch.errors['listDeletedTaskIds'] = StateError('deleted down');
    ch.responses['listTasks'] = [
      {'taskId': 't1', 'title': 'A'},
      {'taskId': 't2', 'title': 'B'},
    ];
    await h.catalog.loadTaskIndex();

    expect(model.cards.map((c) => c.sessionId), contains('t2'),
        reason: '成功路照常应用');
    // 红：修复前失败路归一空数组 → 置顶/归档/墓碑全被清。
    expect(model.pinnedIdsForCache, ['t1'], reason: '置顶集保留');
    expect(model.archivedIdsForCache, ['a1'], reason: '归档集保留');
    expect(model.deletedIdsForCache, ['d1'], reason: '删除墓碑保留');
    expect(h.catalog.archivedTasks.map((t) => t['taskId']), ['a1'],
        reason: '归档页数据源保留');
    await h.catalog.detach();
  });

  test('loadTaskIndex 代际失效丢弃旧响应（模型换代后）', () async {
    final h = _Harness();
    final ch = h.bridge.channelsImpl;
    final gate = Completer<void>();
    ch.gates['listTasks'] = gate;
    ch.responses['listTasks'] = [
      {'taskId': 'old'},
    ];
    final modelA = h.catalog.replaceTaskList(_SiSub(), 'ws', dormant: true);
    final first = h.catalog.loadTaskIndex();
    await Future<void>.delayed(Duration.zero); // 进入闸门
    expect(ch.calls.where((m) => m == 'listTasks'), hasLength(1));

    // 模型换代（重开工作区/复活）→ 新一轮拉取先落地。
    ch.gates.remove('listTasks');
    ch.responses['listTasks'] = [
      {'taskId': 'new'},
    ];
    final modelB = h.catalog.replaceTaskList(_SiSub(), 'ws', dormant: true);
    await h.catalog.loadTaskIndex();
    expect(modelB.cards.map((c) => c.sessionId), ['new']);

    gate.complete();
    await first;
    expect(modelB.cards.map((c) => c.sessionId), ['new'],
        reason: '旧代际响应不得覆盖新结果');
    expect(modelA.cards, isEmpty,
        reason: '旧模型不得被迟到响应填充（红：修复前旧响应照常应用）');
    await h.catalog.detach();
  });

  test('并发 loadTaskIndex 合并为一轮 RPC（批量未读风暴防撞桌面负载纪律）', () async {
    final h = _Harness();
    final ch = h.bridge.channelsImpl;
    h.catalog.replaceTaskList(_SiSub(), 'ws', dormant: true);
    final before = ch.calls.length;
    await Future.wait([for (var i = 0; i < 5; i++) h.catalog.loadTaskIndex()]);
    // 红：修复前 5 次调用=5×4=20 次 RPC。
    expect(ch.calls.length - before, 4, reason: '四路各一次（在飞合并）');
    await h.catalog.detach();
  });

  // 状态层批：pause 时 _tasksIndex==null（在飞 subscribe 未落地）此前直接
  // return——订阅随后落地挂上 5s 级活订阅（保活后台电量红线）。
  test('pause 与 subscribe 竞态：落地订阅自收，最终无活订阅', () async {
    final gated = _GatedTasksConv();
    final h = _Harness(conversationTransport: gated);
    final pending = h.catalog.subscribeTasksIndex();
    await Future<void>.delayed(Duration.zero);
    await h.catalog.pauseTasksIndexForBackground();

    final late = _TasksSub(() {});
    gated.gate.complete(late);
    await pending;

    expect(late.isDisposed, isTrue, reason: '后台暂停窗口内落地的订阅必须自收');
    expect(h.catalog.tasksIndex, isNull, reason: '不得挂上活订阅');
    await h.catalog.detach();
  });

  test('F2：pause→resume 竞态不双订阅（在飞单槽合并，重复落地废弃）', () async {
    final gated = _GatedTasksConv();
    final h = _Harness(conversationTransport: gated);
    final pending = h.catalog.subscribeTasksIndex();
    await Future<void>.delayed(Duration.zero);
    await h.catalog.pauseTasksIndexForBackground();
    // 回前台：resume 与在飞订阅合并（不另起第二个 RPC）。
    final resumed = h.catalog.resumeTasksIndexFromBackground();
    final first = _TasksSub(() {});
    gated.gate.complete(first);
    await pending;
    await resumed;

    expect(first.isDisposed, isFalse, reason: '解除暂停后落地的首个订阅应保留');
    expect(h.catalog.tasksIndex, same(first));
    // 再次显式订阅（open 路径重放）：已活订阅时重复落地必须废弃。
    final gated2 = _GatedTasksConv();
    h.conversationOverride = gated2;
    final again = h.catalog.subscribeTasksIndex();
    final dup = _TasksSub(() {});
    gated2.gate.complete(dup);
    await again;
    expect(dup.isDisposed, isTrue, reason: '重复落地不得覆盖已活订阅');
    expect(h.catalog.tasksIndex, same(first));
    await h.catalog.detach();
  });
}
