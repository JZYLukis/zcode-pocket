import 'dart:async';

import 'package:flutter/foundation.dart';

import '../state/app_state.dart';
import '../state/cache_policy.dart';
import '../state/conversation_registry.dart';
import '../state/task_catalog.dart';
import '../state/task_list.dart';
import '../transport/companion_client.dart';
import '../transport/conversation.dart';
import '../transport/z_transport.dart';
import 'demo_bridge.dart';
import 'demo_data.dart';
import 'demo_script.dart';

/// 演示模式的 [AppState]：不调用 [AppState.load]、不触碰 secure
/// storage / relay / 真实网络——由 [DemoScript] 驱动**真实的**
/// [TaskCatalog]（readTree + tasks-index + 三列表）与
/// [ConversationRegistry]（订阅生命周期/缓存种子语义），会话传输走
/// 真实 [ConversationTransport]（挂 [DemoBridge]）。
///
/// 门面成员显式覆写为演示实现；生产基类的其余成员在无栈状态下
/// 均为空值/no-op 兜底，不会被演示路径触达。
class DemoAppState extends AppState {
  DemoAppState() {
    loaded = true;
    // 偏好内存就绪（ios-adaptation-3）：默认值即最终值、零存储触碰
    // ——AppLockGate 冷启动门闩由此放行。此前 asserts 环境（集成测试）
    // 曾因 gate 不兜底拉起 load() 而 demo 又跳过 load → 全树永久占位。
    uiPrefs.markMemoryReady();

    // —— 单电脑单账号档案 ——
    _demoProfile = AccountV2Profile(
      deviceSid: demoDeviceSid,
      accountId: demoAccountId,
      label: demoComputerLabel,
      addedAt: DateTime.now().subtract(const Duration(days: 30)),
    );

    // —— 传输组装：假桥 + 真实 ConversationTransport ——
    _bridge = DemoBridge();
    _script = DemoScript(_bridge);
    _conv = _bridge.conversation(
      demoWorkspace,
      onLog: (line) => debugPrint('[demo-conv] $line'),
    );

    // —— 任务目录（真 TaskCatalog，provider 喂演示桥） ——
    _catalog = TaskCatalog(
      bridgeProvider: () => _bridge,
      conversationProvider: () => _conv,
      activeWorkspaceProvider: () => _activeWs,
      workspacesProvider: () => [demoWorkspace],
      disposedProvider: () => _disposedSelf,
      onLog: _demoLog,
      onNotify: notifyListeners,
      onCacheWrite: () {},
      onTaskListChanged: notifyListeners,
      onTaskListRebuilt: (_) {},
    );
    _catalog.attachBridge(_bridge);

    // —— 会话注册表（真 ConversationRegistry，无磁盘缓存） ——
    _registry = ConversationRegistry(
      cache: null,
      deviceSid: () => demoDeviceSid,
      transportProvider: () => _conv,
      siDormantProvider: () => false,
      retrySessionsIndex: () async {},
      disposedProvider: () => _disposedSelf,
      onLog: _demoLog,
    );

    // —— 首页数据流：si 订阅 + 项目树 + tasks-index + 三列表 ——
    unawaited(_bootstrap());
  }

  late final AccountV2Profile _demoProfile;
  late final DemoBridge _bridge;
  late final DemoScript _script;
  late final ConversationTransport _conv;
  late final TaskCatalog _catalog;
  late final ConversationRegistry _registry;
  SessionsIndexSubscription? _siSub;
  Map<String, dynamic>? _activeWs = demoWorkspace;
  bool _disposedSelf = false;

  @override
  void dispose() {
    _disposedSelf = true;
    // 订阅拆除（ios-adaptation-3）：si/tasks-index 订阅与会话注册表各带
    // 周期清理定时器（_SubscriptionBase._fragmentCleanup）——必须显式
    // 拆除。整体走一个异步序列：registry.close 必须在桥活着时**await
    // 完成**（首版 unawaited 后立刻拆桥，退订尾巴撞死桥抛错——demo
    // 门面测试实证）；桥最后拆。
    final si = _siSub;
    _siSub = null;
    unawaited(() async {
      await (si?.dispose() ?? Future<void>.value());
      _catalog.dispose();
      await _registry.close(awaitWrites: false);
      _script.dispose();
      _bridge.dispose();
    }());
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      _siSub = await _conv.subscribeSessionsIndex(maxAttempts: 1);
      _catalog.replaceTaskList(_siSub!, demoWorkspaceIdentity, dormant: false);
    } catch (e) {
      _demoLog('si subscribe failed (demo): $e');
    }
    _catalog.refreshActiveProject();
    unawaited(_catalog.loadProjects());
    unawaited(_catalog.subscribeTasksIndex());
    unawaited(_catalog.loadTaskIndex());
    notifyListeners();
  }

  void _demoLog(String line) {}

  /// 测试缝：暴露内部任务目录（演示门面的断言用）。
  @visibleForTesting
  TaskCatalog get catalogForTest => _catalog;

  /// 测试缝：暴露内部脚本通道（断言 RPC 调用轨迹用）。
  @visibleForTesting
  DemoScript get scriptForTest => _script;

  // ----------------------------------------------------- 连接与身份

  @override
  LinkPhase get phase => LinkPhase.online;

  @override
  LinkPhase statusOf(DeviceProfile profile) => LinkPhase.online;

  @override
  List<DeviceProfile> get profiles => [_demoProfile];

  @override
  DeviceProfile? get activeProfile => _demoProfile;

  @override
  String? get activeAccountLabel => demoAccountLabel;

  @override
  String? get desktopAppVersion => '3.17.2';

  /// 演示模式单电脑：切换/删除等档案操作一律保持现状。
  @override
  Future<void> activate(DeviceProfile profile) async {}

  @override
  Future<void> removeComputer(DeviceProfile profile) async {}

  @override
  Future<void> reattachAfterAccountLogin() async {}

  // ----------------------------------------------------- 工作区门面

  @override
  List<Map<String, dynamic>> get workspaces => [demoWorkspace];

  @override
  Map<String, dynamic>? get activeWorkspace => _activeWs;

  @override
  bool get workspaceOpening => false;

  @override
  String? get workspaceError => null;

  @override
  bool get workspaceRestoring => false;

  @override
  Future<void> switchWorkspace(
    Map<String, dynamic> workspace, {
    bool keepHomePreview = false,
  }) async {
    _activeWs = workspace;
    notifyListeners();
  }

  @override
  Future<void> switchToProject(
    Map<String, dynamic> project, {
    bool keepHomePreview = false,
  }) async {
    final roots = project['roots'];
    final root = roots is List && roots.isNotEmpty ? roots.first : null;
    final rootPath = root is Map ? root['rootPath'] : null;
    _activeWs = {
      'workspacePath': rootPath ?? demoWorkspacePath,
      'workspaceIdentity': demoWorkspaceIdentity,
    };
    _catalog.refreshActiveProject();
    notifyListeners();
  }

  @override
  Future<void> switchToTask(
    Map<String, dynamic> task, {
    String? label,
    bool keepHomePreview = false,
  }) async {
    _activeWs = {
      'workspacePath': task['workspacePath'] ?? demoWorkspacePath,
      'workspaceIdentity':
          task['workspaceIdentity'] ?? demoWorkspaceIdentity,
    };
    notifyListeners();
  }

  @override
  void switchToConversations() => notifyListeners();

  @override
  Future<void> refreshWorkspaces() async {}

  @override
  Future<void> retryWorkspaceOpen() async {}

  @override
  Map<String, dynamic>? projectForKey(String key) =>
      _catalog.projectForKey(key);

  // ----------------------------------------------------- 任务门面

  @override
  List<Map<String, dynamic>> get workspaceTasks => _catalog.workspaceTasks;

  @override
  List<Map<String, dynamic>> get projectTasks => _catalog.projectTasks;

  @override
  List<Map<String, dynamic>> get unclassifiedTasks =>
      _catalog.unclassifiedTasks();

  @override
  List<Map<String, dynamic>> get archivedTasks => _catalog.archivedTasks;

  @override
  String get readTreeStatus => _catalog.readTreeStatus;

  @override
  List<Map<String, dynamic>> get sidebarProjects => _catalog.sidebarEntries();

  @override
  String? get activeProjectId => _catalog.activeProjectId;

  @override
  TaskListModel? get taskList => _catalog.taskList;

  @override
  SessionsIndexState? get sessionsIndex => _siSub?.state;

  @override
  bool get siDormant => false;

  @override
  Future<dynamic> setTaskPinned(String taskId, bool pinned) =>
      _catalog.setTaskPinned(taskId, pinned);

  @override
  Future<dynamic> renameTask(String taskId, String title) async {
    final res = await _catalog.renameTask(taskId, title);
    return res;
  }

  @override
  Future<dynamic> markTaskRead(String taskId, {int? expectedUnreadAt}) =>
      _catalog.markTaskRead(taskId, expectedUnreadAt: expectedUnreadAt);

  @override
  Future<dynamic> markTaskUnread(String taskId, {required bool unread}) =>
      _catalog.markTaskUnread(taskId, unread: unread);

  @override
  Future<dynamic> archiveTask(String taskId) async {
    final res = await _catalog.archiveTask(taskId);
    return res;
  }

  @override
  Future<dynamic> unarchiveTask(String taskId) async {
    final res = await _catalog.unarchiveTask(taskId);
    return res;
  }

  @override
  Future<dynamic> deleteTask(String taskId) async {
    final res = await _catalog.deleteTask(taskId);
    return res;
  }

  @override
  Future<void> moveTask(
    Map<String, dynamic> task,
    String projectId, {
    bool addMissingRoot = false,
  }) => _catalog.moveTask(task, projectId, addMissingRoot: addMissingRoot);

  @override
  Future<List<Map<String, dynamic>>?> searchTasks(String query) =>
      _catalog.searchTaskList(query);

  @override
  void reloadTaskIndex() => unawaited(_catalog.loadTaskIndex());

  // ----------------------------------------------------- 会话门面

  @override
  ConversationTransport? get conversation => _conv;

  @override
  BridgeSession? get bridge => _bridge;

  @override
  Map<String, ConversationState> get conversationStates =>
      _registry.conversationStates;

  @override
  ConversationSubscription? conversationSubscriptionOf(String sessionId) =>
      _registry.subscriptionOf(sessionId);

  @override
  Future<ConversationSubscription> ensureConversation(
    String sessionId, {
    SessionCacheEntry? seedCacheEntry,
  }) => _registry.ensureConversation(sessionId, seedCacheEntry: seedCacheEntry);

  @override
  Future<String> createSession(
    String? firstText, {
    Map<String, dynamic>? config,
  }) => _conv.createSession(
    demoWorkspacePath,
    firstText: firstText,
    config: config,
  );

  @override
  Future<dynamic> sendText(
    String sessionId,
    String text, {
    Map<String, dynamic>? modelSelection,
    String? mode,
    bool? planEnabled,
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
    String? replayCommandId,
  }) => _conv.sendText(
    sessionId,
    text,
    modelSelection: modelSelection,
    mode: mode,
    heldQueueDisposition: heldQueueDisposition,
    expectedHeldQueueItemIds: expectedHeldQueueItemIds,
    planEnabled: planEnabled,
    attachments: attachments,
    replayCommandId: replayCommandId,
  );

  @override
  Future<dynamic> stop(String sessionId) => _conv.stop(sessionId);

  @override
  Future<dynamic> sendCompact(String sessionId) =>
      _conv.sendCompact(sessionId);

  @override
  Future<dynamic> compact(String sessionId) => _conv.compact(sessionId);

  @override
  Future<dynamic> cancelBackgroundWork(String sessionId, String workId) =>
      _conv.cancelBackgroundWork(sessionId, workId);

  @override
  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) => _conv.resolveInteraction(
    sessionId,
    interactionId,
    optionId: optionId,
    freeText: freeText,
    action: action,
    content: content,
  );

  @override
  Future<dynamic> snoozeInteractionAutoResolution(
    String sessionId,
    String interactionId,
  ) => _conv.snoozeInteractionAutoResolution(sessionId, interactionId);

  @override
  Future<dynamic> sendGoalCommand(String sessionId, String text) =>
      _conv.sendGoalCommand(sessionId, text);

  @override
  Future<dynamic> pauseGoal(String sessionId) => _conv.pauseGoal(sessionId);

  @override
  Future<dynamic> resumeGoal(String sessionId) => _conv.resumeGoal(sessionId);

  @override
  Future<dynamic> switchModelConfig(
    String sessionId, {
    required String provider,
    required String model,
    required String thought,
  }) => _conv.switchModelConfig(
    sessionId,
    provider: provider,
    model: model,
    thought: thought,
  );

  @override
  Future<dynamic> switchCollaborationMode(String sessionId, String mode) =>
      _conv.switchCollaborationMode(sessionId, mode);

  @override
  Future<void> changeFollowupMode(String mode) async {
    await uiPrefs.setFollowupMode(mode);
    for (final sessionId in conversationStates.keys.toList()) {
      try {
        await _conv.setFollowupMode(sessionId, mode);
      } catch (_) {}
    }
  }

  @override
  Future<dynamic> forkAssistant(
    String sessionId,
    Map<String, dynamic> target,
  ) => _conv.forkAssistant(sessionId, target);

  @override
  Future<dynamic> editUserQuery(
    String sessionId,
    Map<String, dynamic> target,
    String newText,
  ) => _conv.editUserQuery(sessionId, target, newText);

  @override
  Future<dynamic> retryTurn(
    String sessionId,
    Map<String, dynamic> target,
  ) => _conv.retryTurn(sessionId, target);

  @override
  Future<dynamic> setAssistantFeedback(
    String sessionId,
    Map<String, dynamic> target,
    String? feedback,
  ) => _conv.setAssistantFeedback(sessionId, target, feedback);

  @override
  Future<dynamic> editQueueItem(
    String sessionId,
    String queueItemId,
    String newText,
  ) => _conv.editQueueItem(sessionId, queueItemId, newText);

  @override
  Future<dynamic> setAutoDrain(String sessionId, bool autoDrain) =>
      _conv.setAutoDrain(sessionId, autoDrain);

  @override
  Future<dynamic> fileChanges(
    String sessionId, {
    required Map<String, dynamic> target,
  }) => _conv.fileChanges(sessionId, target: target);

  @override
  Future<dynamic> fileRewindPreview(
    String sessionId, {
    required Map<String, dynamic> target,
  }) => _conv.fileRewindPreview(sessionId, target: target);

  @override
  Future<dynamic> applyFileRewind(
    String sessionId, {
    required Map<String, dynamic> target,
  }) => _conv.applyFileRewind(sessionId, target);

  @override
  Future<Map<String, dynamic>?> sessionSubagents(
    String sessionId, {
    String? endedCursor,
    int endedLimit = 20,
  }) => _conv.listSessionSubagents(
    sessionId,
    endedCursor: endedCursor,
    endedLimit: endedLimit,
  );

  @override
  Future<List<dynamic>> getTaskConfigOptions(String taskId) =>
      _conv.getTaskConfigOptions(taskId);

  @override
  Future<Map<String, dynamic>?> modelSelectionView() =>
      _conv.modelSelectionView();

  @override
  Future<List<dynamic>> modelSelectionOptions() =>
      _conv.modelSelectionOptions();

  @override
  Future<List<SkillEntry>> listSkills() => _conv.skills();

  @override
  Future<WorkspacePrep> prepareWorkspace({bool refresh = false}) =>
      _conv.prepareWorkspace(refresh: refresh);

  @override
  Future<List<Map<String, dynamic>>> searchFiles(String query) async {
    try {
      return await _conv.searchWorkspaceFiles(query);
    } catch (_) {
      return const [];
    }
  }

  // ----------------------------------------------------- 工作流门面

  @override
  Future<dynamic> workflowRuns(String sessionId, {int? limit}) =>
      _conv.workflowRuns(sessionId, limit: limit);

  @override
  Future<dynamic> workflowRunEvents(
    String sessionId,
    String runId, {
    int? afterSequence,
    int? limit,
  }) => _conv.workflowRunEvents(
    sessionId,
    runId,
    afterSequence: afterSequence,
    limit: limit,
  );

  @override
  Future<dynamic> workflowRunArtifacts(String sessionId, String runId) =>
      _conv.workflowRunArtifacts(sessionId, runId);

  @override
  Future<dynamic> workflowRunArtifactRead(
    String sessionId,
    String runId,
    String artifactId, {
    required int version,
    required int offset,
    required int limit,
  }) => _conv.workflowRunArtifactRead(
    sessionId,
    runId,
    artifactId,
    version: version,
    offset: offset,
    limit: limit,
  );

  @override
  Future<Map<String, dynamic>> createWorkspace(String name) async => {
    'success': true,
    'workspacePath': '$demoWorkspacePath/$name',
    'workspaceKey': demoWorkspaceIdentity,
  };
}
