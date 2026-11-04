import 'dart:async';

import '../core/payload_guard.dart';
import '../transport/channel_client.dart';
import '../transport/companion_client.dart';
import '../transport/conversation.dart';
import '../transport/project_tree.dart';
import '../transport/protocol_drift.dart';
import 'cache_policy.dart';
import 'task_list.dart';

/// 工作区 scope 构造（唯一真源—— J2 P3-9/J3 P3-4 轻量合并）：
/// TaskCatalog 与 WorkspaceController 此前各持一份逐字重复，TaskCatalog
/// 内部另有 _taskScope 与 deleteArchivedTasks 的手写内联共三份，协议
/// scope 字段演进时漏改面 ×3。
Map<String, dynamic> workspaceScopeOf(Map<String, dynamic> workspace) => {
  'workspacePath': workspace['workspacePath'],
  if (workspace['workspaceIdentity'] != null)
    'workspaceIdentity': workspace['workspaceIdentity'],
};

/// 当前电脑的任务目录：任务/项目索引、TaskListModel 与任务 RPC。
/// bridge/conv/workspace 由组合根动态提供，本模块不反向依赖 ComputerStack。
class TaskCatalog {
  TaskCatalog({
    required BridgeSession? Function() bridgeProvider,
    required ConversationTransport? Function() conversationProvider,
    required Map<String, dynamic>? Function() activeWorkspaceProvider,
    required List<Map<String, dynamic>> Function() workspacesProvider,
    required bool Function() disposedProvider,
    required void Function(String line) onLog,
    required void Function() onNotify,
    required void Function() onCacheWrite,
    required void Function() onTaskListChanged,
    required void Function(TaskListModel? model) onTaskListRebuilt,
  }) : _bridgeProvider = bridgeProvider,
       _conversationProvider = conversationProvider,
       _activeWorkspaceProvider = activeWorkspaceProvider,
       _workspacesProvider = workspacesProvider,
       _disposedProvider = disposedProvider,
       _onLog = onLog,
       _onNotify = onNotify,
       _onCacheWrite = onCacheWrite,
       _onTaskListChanged = onTaskListChanged,
       _onTaskListRebuilt = onTaskListRebuilt;

  final BridgeSession? Function() _bridgeProvider;
  final ConversationTransport? Function() _conversationProvider;
  final Map<String, dynamic>? Function() _activeWorkspaceProvider;
  final List<Map<String, dynamic>> Function() _workspacesProvider;
  final bool Function() _disposedProvider;
  final void Function(String line) _onLog;
  final void Function() _onNotify;
  final void Function() _onCacheWrite;
  final void Function() _onTaskListChanged;
  final void Function(TaskListModel? model) _onTaskListRebuilt;

  TasksIndexSubscription? _tasksIndex;
  Timer? _taskIndexReloadTimer;
  bool _tasksIndexSnapshotLogged = false;
  TaskListModel? _taskList;
  BridgeSession? _attachedBridge;

  List<Map<String, dynamic>> projects = const [];
  List<Map<String, dynamic>> projectTasks = const [];
  String readTreeStatus = 'loading';
  String? activeProjectId;
  String? _explicitProjectId;
  List<Map<String, dynamic>> archivedTasks = const [];
  List<Map<String, dynamic>> workspaceTasks = const [];
  int _loadProjectsGeneration = 0;

  TaskListModel? get taskList => _taskList;
  TasksIndexSubscription? get tasksIndex => _tasksIndex;
  String? get explicitProjectId => _explicitProjectId;
  set explicitProjectId(String? value) => _explicitProjectId = value;
  bool get hasTasksIndexSnapshot => _tasksIndex?.state.hasSnapshot ?? false;

  TaskListModel seedCachedModel({
    required DeviceCacheEntry cached,
    required SessionsIndexState sessions,
    required String workspaceKey,
  }) {
    final model = TaskListModel(
      dormant: true,
      cachePreview: true,
      sessions: sessions,
      workspaceKey: workspaceKey,
      onLog: _onLog,
    );
    model.applyChannelLists(
      // channelActive 预渲 running 清洗（ J3 P3-6）：tasks-index
      // 合并把 liveStatus='running' 写进通道行 status——workspaceTasks 路
      // 已在读取侧 sanitize，本路原样落 dormant 模型会把已结束回合渲染
      // 成运行中。白名单裁剪覆盖合并层消费的全部键。
      active: cacheHomeTaskRows(cached.channelActive, sanitizeLive: true),
      pinnedIds: cached.pinnedIds,
      archivedIds: cached.archivedIds,
      deletedIds: cached.deletedIds,
    );
    model.addListener(_onTaskListChanged);
    _taskList = model;
    _onTaskListRebuilt(model);
    return model;
  }

  TaskListModel replaceTaskList(
    SessionsIndexSubscription subscription,
    String workspaceKey, {
    required bool dormant,
  }) {
    // 先摘引用再 dispose（D2 L-3，HEAD 同序）：dispose 的 await 窗口内
    // 任何重入读 taskList 不得摸到已死模型。
    final oldModel = _taskList;
    _taskList = null;
    oldModel?.removeListener(_onTaskListChanged);
    oldModel?.dispose();
    final model = TaskListModel(
      sessions: subscription.state,
      workspaceKey: workspaceKey,
      dormant: dormant,
      onLog: _onLog,
    );
    model.addListener(_onTaskListChanged);
    _taskList = model;
    _onTaskListRebuilt(model);
    return model;
  }

  void attachBridge(BridgeSession bridge) {
    if (identical(_attachedBridge, bridge)) return;
    _attachedBridge?.recovered.removeListener(_onBridgeRecoveredReloadTasks);
    _attachedBridge = bridge;
    bridge.recovered.addListener(_onBridgeRecoveredReloadTasks);
  }

  void _onBridgeRecoveredReloadTasks() {
    if (_taskList != null) unawaited(loadTaskIndex());
    // 恢复边沿两类数据收敛对称（ J1-7）：桥短暂断链期间
    // loadProjects 失败会置 readTreeStatus='failed'——桥恢复后任务三列表
    // 自动重拉而项目树不会，侧栏停留 tabs 兜底+失败提示直到手动刷新。
    // 仅失败态重拉（ok/loading 态无需）。
    if (readTreeStatus == 'failed') unawaited(loadProjects());
  }

  void storeWorkspaceTasks(dynamic tasks) {
    if (tasks is! List || hasTasksIndexSnapshot) return;
    workspaceTasks = [
      for (final t in tasks.whereType<Map>()) t.cast<String, dynamic>(),
    ];
  }

  void applyWorkspaceListTasks(dynamic tasks) {
    final model = _taskList;
    if (tasks is List && model != null && !hasTasksIndexSnapshot) {
      model.applyWorkspaceListTasks(tasks, model.workspaceKey);
    }
  }

  void refreshActiveProject() {
    activeProjectId =
        _explicitProjectId ??
        projectIdForKey(workspaceKeyOf(_activeWorkspaceProvider() ?? const {}));
  }

  String? projectIdForKey(String? key) {
    if (key == null) return null;
    final project = projectForWorkspaceKey(
      projects: projects,
      tasks: projectTasks,
      key: key,
    );
    final id = '${project?['id'] ?? ''}'.trim();
    if (id.isNotEmpty) return id;
    for (final t in projectTasks) {
      if (taskWorkspaceKey(t) == key && isUnclassifiedTask(t)) {
        return conversationsPseudoProjectId;
      }
    }
    return null;
  }

  Map<String, dynamic>? projectForKey(String key) =>
      projectForWorkspaceKey(projects: projects, tasks: projectTasks, key: key);

  List<Map<String, dynamic>> sidebarEntries() {
    if (projects.isEmpty) return const [];
    return [
      ...projects,
      if (latestUnclassifiedTask(projectTasks) != null)
        conversationsPseudoProject(),
    ];
  }

  List<Map<String, dynamic>> unclassifiedTasks() =>
      unclassifiedTasksOf(projectTasks);

  Future<void> loadProjects() async {
    final bridge = _bridgeProvider();
    if (bridge == null) return;
    // 代际计数（ J3 P3-8）：多入口并发（openActiveWorkspace/
    // refreshWorkspaces/moveTask/bridge recovered）只校验 bridge 身份不
    // 校验"更新鲜"——15s 超时窗口内慢的旧请求后到覆盖新树（瞬时错树，
    // 下一次拉取才自愈）。旧代际结果整体丢弃。
    final generation = ++_loadProjectsGeneration;
    readTreeStatus = 'loading';
    _onNotify();
    try {
      final res = await bridge.channels.call(Channels.project, 'readTree', [
        {'includeDeleted': true, 'includeDeletedTasks': true},
      ], timeout: const Duration(seconds: 15));
      if (_disposedProvider() ||
          !identical(_bridgeProvider(), bridge) ||
          generation != _loadProjectsGeneration) {
        return;
      }
      noteProtocolDrift(
        'project-readTree',
        res is Map ? res.cast<String, dynamic>() : null,
        ['projects', 'tasks'],
        onLog: _onLog,
      );
      final parsed = parseProjectTree(res);
      projects = visibleProjectsOf(parsed.projects);
      projectTasks = parsed.tasks;
      readTreeStatus = 'ok';
      refreshActiveProject();
      _onLog(
        '[projects] readTree: ${projects.length} visible '
        '(${parsed.projects.length} total), ${projectTasks.length} tasks',
      );
      _onCacheWrite();
      _onNotify();
    } catch (e) {
      if (generation != _loadProjectsGeneration) return;
      readTreeStatus = 'failed';
      _onNotify();
      _onLog('[projects] readTree failed: $e（侧栏退回工作区 tabs 列表）');
    }
  }

  Future<void> moveTask(
    Map<String, dynamic> task,
    String projectId, {
    bool addMissingRoot = false,
  }) async {
    final bridge = _bridgeProvider();
    if (bridge == null) throw StateError('no active bridge');
    var hostId = '${task['hostId'] ?? ''}'.trim();
    if (hostId.isEmpty) hostId = 'local';
    final identity = '${task['workspaceIdentity'] ?? ''}'.trim();
    await bridge.channels.call(Channels.project, 'moveTask', [
      {
        'task': {
          'workspacePath': '${task['workspacePath'] ?? ''}',
          if (identity.isNotEmpty) 'workspaceIdentity': identity,
          'taskId': '${task['taskId'] ?? task['sessionId'] ?? ''}',
        },
        'projectId': projectId,
        'hostId': hostId,
        if (addMissingRoot) 'addMissingRoot': true,
      },
    ], timeout: const Duration(seconds: 15));
    _onLog(
      '[projects] moveTask ok -> $projectId'
      '${addMissingRoot ? ' (addMissingRoot)' : ''}',
    );
    await loadProjects();
  }

  Future<void> subscribeTasksIndex() async {
    final conv = _conversationProvider();
    if (conv == null) return;
    try {
      final sub = await conv.subscribeTasksIndex();
      if (_disposedProvider() || !identical(_conversationProvider(), conv)) {
        await sub.dispose();
        return;
      }
      _tasksIndex = sub;
      sub.onRowsRemoved = _onTasksIndexRowsRemoved;
      sub.state.addListener(_onTasksIndexChanged);
      _onLog('[tasks-index] subscribed');
      // 订阅 call 返回前快照帧可能已 staged 应用——立即喂一次。
      if (sub.state.hasSnapshot) _onTasksIndexChanged();
    } catch (e) {
      _onLog(
        '[tasks-index] subscribe failed: $e'
        '（跨工作区搜索/实时标志退回 workspace-list 兜底）',
      );
    }
  }

  void _onTasksIndexChanged() {
    if (_disposedProvider()) return;
    final state = _tasksIndex?.state;
    if (state == null || !state.hasSnapshot) return;
    if (!_tasksIndexSnapshotLogged) {
      _tasksIndexSnapshotLogged = true;
      _onLog('[tasks-index] snapshot: ${state.rows.length} rows');
    }
    // 守卫（ J3-P2-2）：updatedAt 硬转换抛 TypeError 会落在
    // _acceptLogicalFrame 的 catch 里触发 _resync——同一快照重放再抛，
    // 形成 resync 无界循环；改安全读取按 0 兜底。
    final mapped =
        [for (final row in state.rows.values) controllerRowToTaskMap(row)]
          ..sort(
            (a, b) => (intOf(b['updatedAt']) ?? 0).compareTo(
              intOf(a['updatedAt']) ?? 0,
            ),
          );
    workspaceTasks = mapped;
    final model = _taskList;
    if (model != null) model.applyWorkspaceListTasks(mapped, model.workspaceKey);
    _onCacheWrite();
    _onNotify();
  }

  void _onTasksIndexRowsRemoved(List<String> taskIds) {
    _onLog('[tasks-index] rows removed: ${taskIds.length}');
    final model = _taskList;
    if (model != null) model.markRemovedLocallyAll(taskIds);
    _taskIndexReloadTimer?.cancel();
    _taskIndexReloadTimer = Timer(const Duration(milliseconds: 1200), () {
      if (!_disposedProvider()) unawaited(loadTaskIndex());
    });
  }

  void reloadTaskIndex() {
    if (_taskList != null) unawaited(loadTaskIndex());
  }

  Future<void> loadTaskIndex() async {
    final bridge = _bridgeProvider();
    final model = _taskList;
    final workspace = _activeWorkspaceProvider();
    if (bridge == null || model == null || workspace == null) return;
    final scope = workspaceScopeOf(workspace);
    Future<dynamic> fetch(String method) => bridge.channels
        .call(Channels.zcodeTask, method, [
          scope,
        ], timeout: const Duration(seconds: 12))
        .catchError((Object _) => const []);
    final results = await Future.wait([
      fetch('listTasks'),
      fetch('listPinnedTasks'),
      fetch('listArchivedTasks'),
      fetch('listDeletedTaskIds'),
    ]);
    if (_disposedProvider() || _taskList != model) return;
    List<Map<String, dynamic>> asMaps(dynamic raw) => raw is List
        ? raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
        : const [];
    List<String> ids(dynamic raw) => asMaps(raw)
        .map((t) => '${t['taskId'] ?? ''}')
        .where((id) => id.isNotEmpty)
        .toList();
    final active = asMaps(results[0]);
    final pinned = ids(results[1]);
    final archivedRaw = asMaps(results[2]);
    final archived = archivedRaw
        .map((t) => '${t['taskId'] ?? ''}')
        .where((id) => id.isNotEmpty)
        .toList();
    // 注意：listDeletedTaskIds 官方契约是纯字符串数组（Promise<string[]>，
    // refs zcodeTaskService.ts:460-464），与三列表的对象载荷不同——必须走
    // 专用解析（2026-10-23 真机实锤：误用 ids() 对象解析恒空，负向 join
    // 从未生效，桌面墓碑达数百时手机仍显示两百上下旧卡）。
    final deleted = parseDeletedTaskIds(results[3]);
    // 桥抖动窗口内 RPC 失败会拿到全空三列表——直接应用会把已剔除的
    // 归档任务复活、清掉置顶。全空且已有数据时跳过（bridge 恢复会重拉）。
    // 守卫必须纳入 deleted（ J1-4/J3 P1-2/L2/L3 四路）：官方
    // listTasks 契约=所有已持久化任务（含软删墓碑行，refs
    // zcodeTaskService.ts:428-432），"三列表全空+deleted 非空"是删光最后
    // 一个任务的合法终态——照旧跳过会把 deletedIds 负向 join 一起冻结，
    // 60s 本地墓碑过期后已删任务复活驻留到重开工作区；且任一路 RPC 失败
    // 时 deleted 同为空（catchError 归一），抖动保护不受影响。
    if (active.isEmpty &&
        pinned.isEmpty &&
        archived.isEmpty &&
        deleted.isEmpty &&
        model.channelLoaded) {
      _onLog('[task-list] channel lists empty (bridge jitter?), keeping previous');
      return;
    }
    archivedTasks = archivedRaw;
    model.applyChannelLists(
      active: active,
      pinnedIds: pinned,
      archivedIds: archived,
      deletedIds: deleted,
    );
  }

  Future<List<Map<String, dynamic>>?> searchTaskList(
    String query, {
    int limit = 50,
  }) async {
    final bridge = _bridgeProvider();
    final q = query.trim();
    if (bridge == null || q.isEmpty) return null;
    // scopes = 全部已知工作区：workspace-list（当前 tabs）+ 项目任务聚合
    // （：3.16 workspace-list 只剩 1 tab，项目全集补全搜索覆盖）
    // + controller/tasks-index 当前窗口任务（B 首页同源补齐：避免 readTree
    // 未就绪时"首页看得到、正文搜不到"）。
    final scopesByKey = <String, Map<String, dynamic>>{};
    void addScope(Map<String, dynamic> w) {
      final path = '${w['workspacePath'] ?? ''}';
      if (path.trim().isEmpty) return;
      final identity = '${w['workspaceIdentity'] ?? ''}'.trim();
      final key = identity.isNotEmpty ? identity : path;
      scopesByKey.putIfAbsent(
        key,
        () => {
          'workspacePath': path,
          if (identity.isNotEmpty) 'workspaceIdentity': identity,
        },
      );
    }

    for (final w in _workspacesProvider()) {
      addScope(w);
    }
    for (final t in projectTasks) {
      addScope(t);
    }
    for (final t in workspaceTasks) {
      addScope(t);
    }
    final scopes = scopesByKey.values.toList();
    // 没有可查询的 scope 是"搜索不可用"，不是"零匹配"。
    if (scopes.isEmpty) return null;
    Future<List<Map<String, dynamic>>> fetch(String kind) async {
      final res = await bridge.channels.call(
        Channels.zcodeTask,
        'listTaskList',
        [
          {
            'kind': kind,
            'workspaceScopes': scopes,
            'sortBy': 'updated',
            'search': q,
            'limit': limit,
          },
        ],
        timeout: const Duration(seconds: 12),
      );
      final items = res is Map ? res['items'] : null;
      if (items is! List) return const [];
      return items.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }

    Future<List<Map<String, dynamic>>?> tryFetch(String kind) async {
      try {
        return await fetch(kind);
      } catch (_) {
        return null;
      }
    }

    // 双路允许部分成功：pinned 失败不再拖掉 active 已命中的正文结果；
    // 只有两路都失败才判定全文搜索不可用。
    final results = await Future.wait([tryFetch('active'), tryFetch('pinned')]);
    if (results[0] == null && results[1] == null) return null;
    // taskId 去重（置顶行只来自 pinned 路，理论上不重叠，防御性合并）。
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final hit in [...results[0] ?? const [], ...results[1] ?? const []]) {
      final id = '${hit['taskId'] ?? ''}';
      if (id.isEmpty || !seen.add(id)) continue;
      out.add(hit);
    }
    return out;
  }

  Map<String, dynamic> _taskScope(String taskId) => {
    ...workspaceScopeOf(_activeWorkspaceProvider() ?? const {}),
    'taskId': taskId,
  };

  Future<dynamic> _taskCall(String method, Map<String, dynamic> args) async {
    final bridge = _bridgeProvider();
    if (bridge == null) throw StateError('no active workspace');
    return bridge.channels.call(Channels.zcodeTask, method, [
      args,
    ], timeout: const Duration(seconds: 15));
  }

  Future<dynamic> setTaskPinned(String taskId, bool pinned) =>
      _taskCall('setTaskPinned', {..._taskScope(taskId), 'pinned': pinned});

  Future<dynamic> renameTask(String taskId, String title) =>
      _taskCall('renameTask', {..._taskScope(taskId), 'title': title});

  Future<dynamic> archiveTask(String taskId) async {
    final res = await _taskCall('archiveTask', _taskScope(taskId));
    unawaited(loadTaskIndex());
    return res;
  }

  Future<dynamic> deleteArchivedTask(String taskId) =>
      _taskCall('deleteArchivedTask', _taskScope(taskId));

  Future<dynamic> deleteArchivedTasks(List<String> taskIds) =>
      _taskCall('deleteArchivedTasks', {
        ...workspaceScopeOf(_activeWorkspaceProvider() ?? const {}),
        'taskIds': taskIds,
      });

  Future<dynamic> unarchiveTask(String taskId) async {
    final res = await _taskCall('unarchiveTask', _taskScope(taskId));
    unawaited(loadTaskIndex());
    return res;
  }

  Future<dynamic> deleteTask(String taskId) async {
    final res = await _taskCall('deleteTask', _taskScope(taskId));
    unawaited(loadTaskIndex());
    return res;
  }

  Future<dynamic> markTaskRead(String taskId) =>
      _taskCall('setTaskUnread', {..._taskScope(taskId), 'unread': false});

  Future<dynamic> markTaskUnread(String taskId, {required bool unread}) =>
      _taskCall('setTaskUnread', {..._taskScope(taskId), 'unread': unread});

  Future<void> detach({Future<void> Function()? beforeTasksIndexDispose}) async {
    final tiSub = _tasksIndex;
    _tasksIndex = null;
    _taskIndexReloadTimer?.cancel();
    _taskIndexReloadTimer = null;
    _tasksIndexSnapshotLogged = false;
    // 切工作区清残留（ J2 P3-2）：workspaceTasks/archivedTasks 是
    // 上一工作区的现场——不清则开桥窗口内首页/跨区搜索继续消费旧行，
    // 点旧行会以新工作区的 conv/作用域去开旧任务（服务端找不到/开错
    // 目录）。projects/projectTasks 按设计保留（同电脑切换数据仍有效，
    // J2 排除项 12）；首页在 workspaceTasks 空时自有 currentTasks 兜底。
    workspaceTasks = const [];
    archivedTasks = const [];
    final oldModel = _taskList;
    _taskList = null;
    _onTaskListRebuilt(null);
    tiSub?.state.removeListener(_onTasksIndexChanged);
    if (beforeTasksIndexDispose != null) await beforeTasksIndexDispose();
    await tiSub?.dispose();
    _attachedBridge?.recovered.removeListener(_onBridgeRecoveredReloadTasks);
    _attachedBridge = null;
    oldModel?.removeListener(_onTaskListChanged);
    oldModel?.dispose();
  }
}
