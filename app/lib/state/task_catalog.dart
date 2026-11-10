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
    _taskIndexGeneration++;
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
    // 模型换代即作废在飞任务索引拉取（旧响应不得落到新模型的账上）。
    _taskIndexGeneration++;
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

  /// 订阅在飞单槽（fullsweep-fix2 F2）：pause→resume 竞态下第二个
  /// subscribe 会与在飞的第一个并行落地，后者覆盖 _tasksIndex 后前者
  /// 永不 dispose（5s 级活订阅=电量红线）。全部入口共享同一在飞 Future。
  Future<void>? _subscribeInFlight;

  Future<void> subscribeTasksIndex() {
    final existing = _subscribeInFlight;
    if (existing != null) return existing;
    final done = _subscribeTasksIndexOnce();
    _subscribeInFlight = done;
    return done.whenComplete(() => _subscribeInFlight = null);
  }

  Future<void> _subscribeTasksIndexOnce() async {
    final conv = _conversationProvider();
    if (conv == null) return;
    try {
      final sub = await conv.subscribeTasksIndex();
      // 后台暂停窗口（状态层批）：pause 先于订阅落地时，此前直接挂上
      // 5s 级活订阅（电量红线）。落地即收，等回前台重订阅。
      if (_disposedProvider() ||
          !identical(_conversationProvider(), conv) ||
          _pausedForBackground) {
        await sub.dispose();
        if (_pausedForBackground) {
          _onLog('[tasks-index] subscribe landed while paused: disposed');
        }
        return;
      }
      // F2：resume 竞态下另一路订阅可能已先落地——保留先到者，废弃
      // 重复者（此前直接覆盖=先到者永不 dispose）。
      if (_tasksIndex != null) {
        await sub.dispose();
        _onLog('[tasks-index] subscribe landed but already active: dup disposed');
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

  /// 后台暂停标志（状态层批）：pauseTasksIndexForBackground 在任何 await
  /// 之前同步置位——在飞 subscribe 落地时据此自收，不再挂活订阅。
  bool _pausedForBackground = false;

  /// 1.0.1 真机验收⑩（后台 583mAh/h，第五轮）：保活分支退后台再退订
  /// tasks-index——5s 级 notify 帧（内容多数无差异）是驻留后剩余推帧
  /// 大头；数据保留（回前台重订阅增量补齐+对账通知兜底），审批通知
  /// 数据源（si）不动。
  Future<void> pauseTasksIndexForBackground() async {
    _pausedForBackground = true;
    final sub = _tasksIndex;
    _tasksIndex = null;
    if (sub == null) {
      // 在飞订阅：落地时由 subscribeTasksIndex 的暂停检查自收。
      _onLog('[tasks-index] paused (subscribe in flight)');
      return;
    }
    sub.onRowsRemoved = null;
    sub.state.removeListener(_onTasksIndexChanged);
    await sub.dispose();
    _onLog('[tasks-index] paused for background');
  }

  Future<void> resumeTasksIndexFromBackground() async {
    _pausedForBackground = false;
    if (_tasksIndex != null) return;
    // F2：经公共入口（在飞单槽）——pause 期间在飞的订阅落地与此处
    // 的重订阅合并为一次，不再各起一个。
    await subscribeTasksIndex();
  }

  /// 2026-11-05 反馈②A：跨工作区打开任务时保住的旧首页列表是否仍在
  /// 展示（新工作区首帧 tasks-index 到达即被整体替换并复位）。
  bool homePreviewStale = false;

  void _onTasksIndexChanged() {
    if (_disposedProvider()) return;
    final state = _tasksIndex?.state;
    if (state == null || !state.hasSnapshot) return;
    homePreviewStale = false;
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

  /// 任务索引重拉代际（对齐 loadProjects 范式）：模型换代/重开时自增，
  /// 旧响应整体丢弃。
  int _taskIndexGeneration = 0;

  /// 在飞去重（状态层批）：每条 [markTaskUnread] 都触发一次 4×RPC 重拉，
  /// 批量 50 条=200 RPC——撞 ADR 0020 桌面负载纪律。同模型并发调用合并
  /// 到同一 Future；模型换代后的调用另起一轮（旧轮代际失效丢弃）。
  Future<void>? _taskIndexInFlight;
  TaskListModel? _taskIndexInFlightModel;

  Future<void> loadTaskIndex() {
    final bridge = _bridgeProvider();
    final model = _taskList;
    final workspace = _activeWorkspaceProvider();
    if (bridge == null || model == null || workspace == null) {
      return Future<void>.value();
    }
    final inFlight = _taskIndexInFlight;
    if (inFlight != null && identical(_taskIndexInFlightModel, model)) {
      return inFlight;
    }
    final generation = ++_taskIndexGeneration;
    late final Future<void> run;
    run = _loadTaskIndexOnce(bridge, model, workspace, generation).whenComplete(
      () {
        if (identical(_taskIndexInFlight, run)) {
          _taskIndexInFlight = null;
          _taskIndexInFlightModel = null;
        }
      },
    );
    _taskIndexInFlight = run;
    _taskIndexInFlightModel = model;
    return run;
  }

  /// 一次四路拉取。单路失败保留上一轮对应集合（不整替），全部成功且
  /// 全空才按桥抖动跳过——半空结果（如只删光最后一个归档任务）必须能
  /// 应用。
  Future<void> _loadTaskIndexOnce(
    BridgeSession bridge,
    TaskListModel model,
    Map<String, dynamic> workspace,
    int generation,
  ) async {
    final scope = workspaceScopeOf(workspace);
    Future<({bool ok, dynamic raw})> fetch(String method) async {
      try {
        final raw = await bridge.channels.call(
          Channels.zcodeTask,
          method,
          [scope],
          timeout: const Duration(seconds: 12),
        );
        return (ok: true, raw: raw);
      } catch (_) {
        // 失败路不归一为空数组：调用方保留上一轮集合。
        return (ok: false, raw: null);
      }
    }

    final results = await Future.wait([
      fetch('listTasks'),
      fetch('listPinnedTasks'),
      fetch('listArchivedTasks'),
      fetch('listDeletedTaskIds'),
    ]);
    if (_disposedProvider() ||
        _taskList != model ||
        generation != _taskIndexGeneration) {
      return;
    }
    List<String> ids(List<Map<String, dynamic>> rows) => rows
        .map((t) => '${t['taskId'] ?? ''}')
        .where((id) => id.isNotEmpty)
        .toList();
    // listDeletedTaskIds 官方契约是纯字符串数组（Promise<string[]>，
    // refs zcodeTaskService.ts:460-464），与三列表的对象载荷不同——必须走
    // 专用解析（2026-10-23 真机实锤：误用 ids() 对象解析恒空，负向 join
    // 从未生效，桌面墓碑达数百时手机仍显示两百上下旧卡）。
    final rActive = results[0];
    final rPinned = results[1];
    final rArchived = results[2];
    final rDeleted = results[3];
    final active = rActive.ok
        ? _asTaskMaps(rActive.raw)
        : model.channelTasksForCache;
    final pinned = rPinned.ok
        ? ids(_asTaskMaps(rPinned.raw))
        : model.pinnedIdsForCache;
    final archivedRaw = rArchived.ok
        ? _asTaskMaps(rArchived.raw)
        : archivedTasks;
    final archived = rArchived.ok
        ? ids(archivedRaw)
        : model.archivedIdsForCache;
    final deleted = rDeleted.ok
        ? parseDeletedTaskIds(rDeleted.raw)
        : model.deletedIdsForCache;
    // 桥抖动窗口内 RPC 失败会拿到全空三列表——直接应用会把已剔除的
    // 归档任务复活、清掉置顶。**四路都成功且全空**才跳过（bridge 恢复
    // 会重拉）；任一路失败时用上一轮集合补齐，不构成"全空"。
    // 守卫必须纳入 deleted（ J1-4/J3 P1-2/L2/L3 四路）：官方
    // listTasks 契约=所有已持久化任务（含软删墓碑行，refs
    // zcodeTaskService.ts:428-432），"三列表全空+deleted 非空"是删光最后
    // 一个任务的合法终态——照旧跳过会把 deletedIds 负向 join 一起冻结，
    // 60s 本地墓碑过期后已删任务复活驻留到重开工作区。
    final allOk = rActive.ok && rPinned.ok && rArchived.ok && rDeleted.ok;
    if (allOk &&
        active.isEmpty &&
        pinned.isEmpty &&
        archived.isEmpty &&
        deleted.isEmpty &&
        model.channelLoaded) {
      _onLog('[task-list] channel lists empty (bridge jitter?), keeping previous');
      return;
    }
    if (rArchived.ok) archivedTasks = archivedRaw;
    model.applyChannelLists(
      active: active,
      pinnedIds: pinned,
      archivedIds: archived,
      deletedIds: deleted,
    );
  }

  static List<Map<String, dynamic>> _asTaskMaps(dynamic raw) => raw is List
      ? raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
      : const [];

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

  /// 2026-11-05 反馈②B：官方 compare-and-clear（task-unread-state.md
  /// :52-58——tasks-index 当前 unreadAt 仍等于 expectedUnreadAt 才清除）。
  /// 此前每次打开都无条件发写，转场窗口内引来一次 meta 变更帧=首页
  /// 整页重建观感；携带期望值后未读未变时服务端无变更推送。
  Future<dynamic> markTaskRead(String taskId, {int? expectedUnreadAt}) =>
      _taskCall('setTaskUnread', {
        ..._taskScope(taskId),
        'unread': false,
        if (expectedUnreadAt != null) 'expectedUnreadAt': expectedUnreadAt,
      });

  Future<dynamic> markTaskUnread(String taskId, {required bool unread}) =>
      _taskCall('setTaskUnread', {..._taskScope(taskId), 'unread': unread});

  Future<void> detach({
    Future<void> Function()? beforeTasksIndexDispose,
    bool keepHomePreview = false,
  }) async {
    // 在飞拉取代际失效（状态层批）：detach 后旧响应不得再落到任何模型
    // （桥已换/窗口已关），并复位后台暂停标志等下次开桥重新订阅。
    _taskIndexGeneration++;
    _pausedForBackground = false;
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
    // 2026-11-05 反馈②A（keepHomePreview）：跨工作区打开任务的窗口内
    // 保留旧首页行（SWR 式防闪「正在加载任务…」）——安全边界：旧行
    // 点按走跨区路径按任务自身工作区解析（_openCrossWorkspaceTask），
    // 不走 sessionId 直开；打开失败由调用方 clearStaleHomePreview()
    // 收口恢复 J2 清残留语义。
    if (keepHomePreview && workspaceTasks.isNotEmpty) {
      homePreviewStale = true;
    } else {
      workspaceTasks = const [];
      archivedTasks = const [];
      homePreviewStale = false;
    }
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

  /// 2026-11-05 反馈②A：打开失败时显式清保住的旧首页行（恢复 J2
  /// 清残留语义——防旧行以新工作区作用域被消费）。
  void clearStaleHomePreview() {
    if (!homePreviewStale) return;
    homePreviewStale = false;
    workspaceTasks = const [];
    archivedTasks = const [];
    _onNotify();
  }
}
