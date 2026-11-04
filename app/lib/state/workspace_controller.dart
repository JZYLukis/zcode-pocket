import 'dart:async';

import '../transport/companion_client.dart';
import '../transport/conversation.dart';
import '../transport/project_tree.dart';
import '../transport/protocol_drift.dart';
import '../transport/relay_client.dart';
import '../transport/z_transport.dart';
import 'conversation_registry.dart';
import 'task_catalog.dart';

/// 工作区桥与打开生命周期：bootstrap、切换、原意图重驱动、si 降级/复活。
/// relay client 与整栈 suspend/resume 仍由 ComputerStack 持有。
class WorkspaceController {
  WorkspaceController({
    required ConversationRegistry conversationRegistry,
    required TaskCatalog taskCatalog,
    required CompanionClient? Function() clientProvider,
    required bool Function() disposedProvider,
    required DeviceProfile Function() profileProvider,
    required void Function(DeviceProfile profile) profileSetter,
    required Future<void> Function(DeviceProfile profile) persistProfile,
    required void Function(String line) onLog,
    required void Function() onNotify,
    required void Function() onCacheWrite,
    required void Function() cancelDeviceCacheWrite,
    required Future<void> Function({bool awaitWrites}) flushDeviceCache,
    required void Function() onBootstrapStarted,
    required void Function(CompanionClient client) ensureWorkspaceListSubscription,
  }) : _conversationRegistry = conversationRegistry,
       _taskCatalog = taskCatalog,
       _clientProvider = clientProvider,
       _disposedProvider = disposedProvider,
       _profileProvider = profileProvider,
       _profileSetter = profileSetter,
       _persistProfileCallback = persistProfile,
       _onLog = onLog,
       _onNotify = onNotify,
       _onCacheWrite = onCacheWrite,
       _cancelDeviceCacheWrite = cancelDeviceCacheWrite,
       _flushDeviceCache = flushDeviceCache,
       _onBootstrapStarted = onBootstrapStarted,
       _ensureWorkspaceListSubscription = ensureWorkspaceListSubscription;

  final ConversationRegistry _conversationRegistry;
  final TaskCatalog _taskCatalog;
  final CompanionClient? Function() _clientProvider;
  final bool Function() _disposedProvider;
  final DeviceProfile Function() _profileProvider;
  final void Function(DeviceProfile profile) _profileSetter;
  final Future<void> Function(DeviceProfile profile) _persistProfileCallback;
  final void Function(String line) _onLog;
  final void Function() _onNotify;
  final void Function() _onCacheWrite;
  final void Function() _cancelDeviceCacheWrite;
  final Future<void> Function({bool awaitWrites}) _flushDeviceCache;
  final void Function() _onBootstrapStarted;
  final void Function(CompanionClient client) _ensureWorkspaceListSubscription;

  BridgeSession? _bridge;
  ConversationTransport? _conv;
  SessionsIndexSubscription? _sessionsIndex;
  List<Map<String, dynamic>> workspaces = const [];
  Map<String, dynamic>? activeWorkspace;
  String? desktopAppVersion;
  bool workspaceOpening = false;
  String? workspaceError;
  bool siDormant = false;
  Timer? _siRetryTimer;
  bool _siRetrying = false;
  bool _bootstrapInFlight = false;
  Future<void> Function()? _lastOpenAction;
  int _redriveAttempt = 0;
  bool _redriveInFlight = false;
  Timer? _redriveTimer;
  int _switchEpoch = 0;

  BridgeSession? get bridge => _bridge;
  set bridge(BridgeSession? value) => _bridge = value;
  ConversationTransport? get conversation => _conv;
  set conversation(ConversationTransport? value) => _conv = value;
  SessionsIndexSubscription? get sessionsIndexSubscription => _sessionsIndex;
  set sessionsIndexSubscription(SessionsIndexSubscription? value) =>
      _sessionsIndex = value;
  SessionsIndexState? get sessionsIndex => _sessionsIndex?.state;

  void prepareBootstrap(CompanionClient client) {
    _ensureWorkspaceListSubscription(client);
    _lastOpenAction = () async {
      if (_disposedProvider() || !identical(_clientProvider(), client)) return;
      await bootstrapWorkspace(client);
    };
  }

  void startBootstrapWhenPaired(CompanionClient client) {
    void listener() {
      if (client.relay.state == RelayState.paired) {
        client.relay.stateListenable.removeListener(listener);
        if (_disposedProvider() || !identical(_clientProvider(), client)) return;
        _ensureWorkspaceListSubscription(client);
        // 开源审查 J3 P1-3/J2 P2-3：与 prepareBootstrap 同款先设置
        // _lastOpenAction——本路径（waitPaired 90s 超时后配对）此前从未
        // 设置，bootstrap 一旦失败（RPC 超时/桌面无响应）：
        // ①maybeScheduleWorkspaceRedrive 的 action==null 闸直接空转，
        //   redrive 自愈链在这条路径上不存在（paired+无桥永久死端）；
        // ②unawaited 无 catch，异常仅被全局 onError 记日志。
        _lastOpenAction = () async {
          if (_disposedProvider() || !identical(_clientProvider(), client)) {
            return;
          }
          await bootstrapWorkspace(client);
        };
        unawaited(
          _lastOpenAction!().then((_) {}, onError: (Object e) {
            _onLog('[workspace] bootstrap failed (startWhenPaired): $e');
            maybeScheduleWorkspaceRedrive();
          }),
        );
      }
    }

    client.relay.stateListenable.addListener(listener);
  }

  void onRelayState() {
    if (_disposedProvider()) return;
    if (_clientProvider()?.relay.state == RelayState.paired) {
      // paired 边沿不清退避计数（开源审查 J1-10）：退避设计为 3s×10→30s，
      // 但 relay 每次重配对都把 _redriveAttempt 清零——relay 自身抖动
      // （paired↔reconnecting）+桥打不开组合下重驱动固定 3s 一锤，退避
      // 失效（既打桌面又刷日志）。清零只发生在成功开栈处
      // （openActiveWorkspace 收尾）。
      maybeScheduleWorkspaceRedrive();
    }
    _onNotify();
  }

  void maybeScheduleWorkspaceRedrive() {
    if (_disposedProvider() || _redriveInFlight || _redriveTimer != null) return;
    if (_bridge != null || workspaceOpening) return;
    final client = _clientProvider();
    if (client == null || client.relay.state != RelayState.paired) return;
    final action = _lastOpenAction;
    if (action == null) return;
    final delay = _redriveAttempt == 0
        ? Duration.zero
        : (_redriveAttempt <= 10
              ? const Duration(seconds: 3)
              : const Duration(seconds: 30));
    _redriveTimer = Timer(delay, () {
      _redriveTimer = null;
      if (_disposedProvider() || _bridge != null || workspaceOpening) {
        _onLog('[workspace] redrive skipped: workspace already open/opening');
        return;
      }
      unawaited(_runWorkspaceRedrive(action));
    });
  }

  Future<void> _runWorkspaceRedrive(Future<void> Function() action) async {
    _redriveInFlight = true;
    _redriveAttempt++;
    _onLog('[workspace] redrive open (attempt $_redriveAttempt)');
    try {
      await action();
    } catch (e) {
      _onLog('[workspace] redrive open failed: $e');
    } finally {
      _redriveInFlight = false;
    }
    if (_disposedProvider()) return;
    if (_bridge == null) maybeScheduleWorkspaceRedrive();
  }

  Future<void> retryWorkspaceOpen() async {
    final action = _lastOpenAction;
    if (action != null) {
      await action();
      return;
    }
    final ws = activeWorkspace;
    if (ws != null) await switchWorkspace(ws);
  }

  void cancelRedrive() {
    _redriveTimer?.cancel();
    _redriveTimer = null;
    _lastOpenAction = null;
  }

  void onWorkspaceList(dynamic result) {
    if (_disposedProvider() || result is! Map) return;
    noteProtocolDrift('workspace-list-updated', result, ['workspaces']);
    if (result['workspaces'] is List) {
      workspaces = (result['workspaces'] as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    _taskCatalog.storeWorkspaceTasks(result['tasks']);
    _taskCatalog.applyWorkspaceListTasks(result['tasks']);
    _onCacheWrite();
    _onNotify();
  }

  Future<void> bootstrapWorkspace(CompanionClient client) async {
    // 断线批（2026-10-26 D1）并发守卫：重驱动与 _startBootstrapWhenPaired
    // 监听会在同一 paired 边沿各自调用本函数——B3 的守卫只挡"已完成"，
    // 挡不住两个在飞 bootstrap 各开一个桥（B3 原始病灶）。在飞互斥。
    if (_bootstrapInFlight) {
      _onLog('[workspace] bootstrap skipped: another bootstrap in flight');
      return;
    }
    _bootstrapInFlight = true;
    try {
      await _doBootstrapWorkspace(client);
    } finally {
      _bootstrapInFlight = false;
    }
  }

  Future<void> _doBootstrapWorkspace(CompanionClient client) async {
    // 开源审查 J1-3/J3 P2-1：bootstrap 的多个 await（bootstrap/
    // listWorkspaces/restore-miss 2s 重试）窗口内用户可能已手动切换工作
    // 区——尾部无条件 switchWorkspace(target) 会拆掉用户刚开的桥、把
    // 选择反向跳回恢复目标。进入时快照 epoch，收尾前校验仍一致才重放。
    final epochAtStart = _switchEpoch;
    _onBootstrapStarted();
    // B3 加固（2026-10-16 夜）：bootstrap 只负责"从零建立工作区栈"。
    // 已有活跃工作区时禁止重跑——waitPaired 超时路径注册的
    // _startBootstrapWhenPaired 监听与 relay 恢复路径（bridge recovery）
    // 会在一次真实断线后同时触发，两条路径各开一个 bridge 互相打架，
    // 实测桥接工作区在两个值之间摆动（真机实录）。恢复期由
    // 桥恢复路径独占负责（订阅层自动重订阅）。
    if (activeWorkspace != null && _bridge != null) {
      _onLog('[workspace] bootstrap skipped: workspace already active');
      return;
    }
    final boot = await client.bootstrap();
    if (_disposedProvider() || !identical(_clientProvider(), client)) return;
    // 软转型+漂移留痕（开源审查 J3 P3-5）：桌面回非 String（num/map）时
    // 硬 `as String?` 抛 TypeError 直接炸掉 bootstrap（随后进 redrive 循环
    // 重试同败）；类型漂移打日志可见（本文件载荷防御惯例）。
    final bootVersion = boot['desktopAppVersion'];
    if (bootVersion != null && bootVersion is! String) {
      _onLog(
        '[workspace] desktopAppVersion type drift: '
        '${bootVersion.runtimeType}（按空处理）',
      );
    }
    desktopAppVersion = bootVersion is String ? bootVersion : null;
    final list = await client.listWorkspaces();
    if (_disposedProvider() || !identical(_clientProvider(), client)) return;
    final wsList = list is Map ? list['workspaces'] : null;
    workspaces = (wsList is List)
        ? wsList.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
        : const [];
    _taskCatalog.storeWorkspaceTasks(list is Map ? list['tasks'] : null);
    _onNotify();

    if (workspaces.isEmpty) {
      activeWorkspace = null;
      _onNotify();
      return;
    }
    Map<String, dynamic>? restoreTarget(List<Map<String, dynamic>> list) {
      final restoreKey = _profileProvider().lastWorkspaceKey;
      if (restoreKey == null) return null;
      for (final ws in list) {
        if (workspaceKeyOf(ws) == restoreKey) return ws;
      }
      return null;
    }

    var target = restoreTarget(workspaces);
    // 病B复发（真机实录）：boot 首份列表可能不含 restoreKey 指向
    // 的工作区 → 落到 default，用户被迫手切。未命中且有恢复键时重拉
    // 一次列表再匹配（2s 给桌面 workspace-list 同步窗口）。
    if (target == null &&
        _profileProvider().lastWorkspaceKey != null &&
        workspaces.isNotEmpty) {
      _onLog(
        'restore miss: key=${_profileProvider().lastWorkspaceKey} '
        'list=${workspaces.map(workspaceKeyOf).toList()} -> retry',
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      if (_disposedProvider() || !identical(_clientProvider(), client)) return;
      try {
        final retry = await client.listWorkspaces();
        if (_disposedProvider() || !identical(_clientProvider(), client)) return;
        final retryList = retry is Map ? retry['workspaces'] : null;
        if (retryList is List && retryList.isNotEmpty) {
          workspaces = retryList
              .whereType<Map>()
              .map((e) => e.cast<String, dynamic>())
              .toList();
          _onNotify();
          target = restoreTarget(workspaces);
        }
      } catch (_) {}
    }
    target ??= workspaces.first;
    if (_switchEpoch != epochAtStart) {
      _onLog('[workspace] bootstrap abandoned: workspace switched while bootstrapping');
      return;
    }
    await switchWorkspace(target);
  }

  Future<void> switchWorkspace(Map<String, dynamic> workspace) async {
    final client = _clientProvider();
    final key = workspaceKeyOf(workspace);
    if (client == null || key == null) return;
    if (workspaceKeyOf(activeWorkspace ?? const {}) == key &&
        _bridge != null &&
        _sessionsIndex != null) {
      return;
    }
    final epoch = ++_switchEpoch;
    bool isGone() =>
        _disposedProvider() ||
        !identical(_clientProvider(), client) ||
        epoch != _switchEpoch;
    _lastOpenAction = () => switchWorkspace(workspace);
    await close(awaitCacheWrites: false, invalidateInFlightOpens: false);
    if (isGone()) return;
    activeWorkspace = workspace;
    _taskCatalog.explicitProjectId = null;
    _taskCatalog.refreshActiveProject();
    await openActiveWorkspace(
      client,
      isGone: isGone,
      logKey: key,
      openWithRetry: () async {
        try {
          return await client.openBridge(key, timeout: const Duration(seconds: 60));
        } catch (e) {
          _onLog('[workspace] bridge open retry ($key): $e');
          await Future<void>.delayed(const Duration(seconds: 2));
          // 二次重试前验 isGone（开源审查 J2 P2-2）：陈旧切换对旧键的
          // 重开会被桌面拒绝，其迟到失败经外层 catch 污染新切换的错误
          // 横幅；作废即弃（外层 catch 的 isGone 守卫收尾）。
          if (isGone()) throw StateError('switch superseded');
          return client.openBridge(key, timeout: const Duration(seconds: 60));
        }
      },
    );
  }

  Future<void> switchToProject(Map<String, dynamic> project) async {
    final client = _clientProvider();
    final id = '${project['id'] ?? ''}'.trim();
    if (client == null || id.isEmpty) return;
    Map<String, dynamic> resolved = project;
    for (final p in _taskCatalog.projects) {
      if ('${p['id'] ?? ''}'.trim() == id) {
        resolved = p;
        break;
      }
    }
    final currentKey = workspaceKeyOf(activeWorkspace ?? const {});
    final atProjectRoot =
        currentKey != null && rootPathsOf(resolved).contains(currentKey);
    // 幂等门桥意图核对（开源审查 J2 P2-4/J3 P3-7）：早退的前提是在桥的
    // 「新建会话归属」与目标项目一致，否则就地选中是假象——
    // - 任务桥（taskIntent 非空）：createSession 不回落，归属恒未归类；
    //   未归类任务跑在项目根目录是常态，桥恰好占位项目根时旧门命中，
    //   UI 显示已选项目 P 而新建会话落「任务」区；
    // - 项目桥：归属=桥 projectIntent 的 projectId，多项目共享同一
    //   root 时在桥 intent 属于另一项目，同理必须走完整切换换桥；
    // - tab 桥：归属=root 直配回落（首个 roots 含当前键的项目），与
    //   createSession 的 rootMatchedProjectId 同口径。
    String? effectiveBridgeProject() {
      final bridge = _bridge;
      if (bridge == null) return null;
      if (bridge.taskIntent != null) return conversationsPseudoProjectId;
      final intentId = bridge.projectIntent?['projectId'];
      if (intentId is String && intentId.trim().isNotEmpty) return intentId;
      final key = currentKey;
      if (key == null) return null;
      for (final p in _taskCatalog.projects) {
        final pid = '${p['id'] ?? ''}'.trim();
        if (pid.isNotEmpty && rootPathsOf(p).contains(key)) return pid;
      }
      return null;
    }
    final attributionMatches = effectiveBridgeProject() == id;
    if ((atProjectRoot || _taskCatalog.explicitProjectId == id) &&
        attributionMatches &&
        _bridge != null &&
        _sessionsIndex != null) {
      if (_taskCatalog.explicitProjectId != id ||
          _taskCatalog.activeProjectId != id) {
        _taskCatalog.explicitProjectId = id;
        _taskCatalog.activeProjectId = id;
        _onNotify();
      }
      return;
    }
    final epoch = ++_switchEpoch;
    bool isGone() =>
        _disposedProvider() ||
        !identical(_clientProvider(), client) ||
        epoch != _switchEpoch;
    _lastOpenAction = () => switchToProject(project);
    await close(awaitCacheWrites: false, invalidateInFlightOpens: false);
    if (isGone()) return;
    final name = '${project['name'] ?? ''}'.trim();
    final intent = projectIntentOf(project);
    final placeholderKey = primaryRootOf(project) ?? 'project-navigation';
    _taskCatalog.explicitProjectId = id;
    _taskCatalog.activeProjectId = id;
    activeWorkspace = {
      'workspacePath': placeholderKey,
      if (name.isNotEmpty) 'label': name,
      'kind': 'local',
    };
    await openActiveWorkspace(
      client,
      isGone: isGone,
      logKey: 'project:$id',
      openWithRetry: () async {
        try {
          return await client.openBridge(
            placeholderKey,
            project: intent,
            timeout: const Duration(seconds: 60),
          );
        } catch (e) {
          _onLog('[workspace] project bridge open retry ($id): $e');
          await Future<void>.delayed(const Duration(seconds: 2));
          if (isGone()) throw StateError('switch superseded'); // J2 P2-2 同款
          return client.openBridge(
            placeholderKey,
            project: intent,
            timeout: const Duration(seconds: 60),
          );
        }
      },
      workspaceFromBridge: (bridge) =>
          workspaceFromBridgePayload(bridge, label: name),
    );
  }

  void switchToConversations() {
    if (_disposedProvider()) return;
    if (_taskCatalog.explicitProjectId == conversationsPseudoProjectId) return;
    _taskCatalog.explicitProjectId = conversationsPseudoProjectId;
    _taskCatalog.activeProjectId = conversationsPseudoProjectId;
    _onNotify();
  }

  void reportViewState({String? taskId}) {
    final client = _clientProvider();
    if (client == null || _bridge == null) return;
    final key = workspaceKeyOf(activeWorkspace ?? const {});
    if (key == null) return;
    unawaited(
      client
          .sendMobileViewState(workspaceKey: key, taskId: taskId)
          .catchError((Object _) {}),
    );
  }

  Future<Map<String, dynamic>> sessionSubagents(
    String sessionId, {
    String? endedCursor,
    int endedLimit = 20,
  }) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active workspace');
    return conv.listSessionSubagents(
      sessionId,
      endedCursor: endedCursor,
      endedLimit: endedLimit,
    );
  }

  Future<void> switchToTask(Map<String, dynamic> task, {String? label}) async {
    final client = _clientProvider();
    final taskId = '${task['taskId'] ?? ''}'.trim();
    final key = taskOpenKey(task);
    if (client == null || taskId.isEmpty || key == null) return;
    if (workspaceKeyOf(activeWorkspace ?? const {}) == key &&
        _bridge != null &&
        _sessionsIndex != null) {
      // 早退也刷新项目选中态（开源审查 J2 P2-5）：完整路径会按「未归类→
      // 伪项目/否则 null+refreshActiveProject」重置，早退不刷则上一显式
      // 选中滞留——「无项目对话」入口语义不生效（新建会话归属与草稿落
      // 点标签仍显示旧项目）。
      final unclassified = isUnclassifiedTask(task);
      final desired = unclassified ? conversationsPseudoProjectId : null;
      final beforeExplicit = _taskCatalog.explicitProjectId;
      final beforeActive = _taskCatalog.activeProjectId;
      _taskCatalog.explicitProjectId = desired;
      if (unclassified) {
        _taskCatalog.activeProjectId = desired;
      } else {
        _taskCatalog.refreshActiveProject();
      }
      if (_taskCatalog.explicitProjectId != beforeExplicit ||
          _taskCatalog.activeProjectId != beforeActive) {
        _onNotify();
      }
      return;
    }
    final epoch = ++_switchEpoch;
    bool isGone() =>
        _disposedProvider() ||
        !identical(_clientProvider(), client) ||
        epoch != _switchEpoch;
    _lastOpenAction = () => switchToTask(task, label: label);
    await close(awaitCacheWrites: false, invalidateInFlightOpens: false);
    if (isGone()) return;
    var hostId = '${task['hostId'] ?? ''}'.trim();
    if (hostId.isEmpty) hostId = 'local';
    final unclassified = isUnclassifiedTask(task);
    _taskCatalog.explicitProjectId =
        unclassified ? conversationsPseudoProjectId : null;
    _taskCatalog.activeProjectId = _taskCatalog.explicitProjectId;
    activeWorkspace = {
      'workspacePath': key,
      if (label != null && label.trim().isNotEmpty) 'label': label,
      'kind': 'local',
    };
    await openActiveWorkspace(
      client,
      isGone: isGone,
      logKey: 'task:$taskId',
      openWithRetry: () async {
        try {
          return await client.openBridge(
            key,
            taskId: taskId,
            taskHostId: hostId,
            timeout: const Duration(seconds: 60),
          );
        } catch (e) {
          _onLog('[workspace] task bridge open retry ($taskId): $e');
          await Future<void>.delayed(const Duration(seconds: 2));
          if (isGone()) throw StateError('switch superseded'); // J2 P2-2 同款
          return client.openBridge(
            key,
            taskId: taskId,
            taskHostId: hostId,
            timeout: const Duration(seconds: 60),
          );
        }
      },
      workspaceFromBridge: (bridge) =>
          workspaceFromBridgePayload(bridge, label: label),
    );
    if (!unclassified) {
      final before = _taskCatalog.activeProjectId;
      _taskCatalog.refreshActiveProject();
      if (_taskCatalog.activeProjectId != before) _onNotify();
    }
  }

  /// openActiveWorkspace 代际（回测组1 P2）：快速 A→B→C 切换时陈旧
  /// attempt 的 isGone 早退无条件复位 workspaceOpening 会偷走新 attempt
  /// 的在飞标志（spinner 消失/redrive 闸门被放行→并发重开双桥）。
  /// 进入时快照，早退复位只在代际未变（无新 open）时执行；新 attempt
  /// 或 close 负责自己的收尾。
  int _openingGeneration = 0;

  Future<void> openActiveWorkspace(
    CompanionClient client, {
    required bool Function() isGone,
    required String logKey,
    required Future<BridgeSession> Function() openWithRetry,
    Map<String, dynamic> Function(Map<String, dynamic> bridge)?
    workspaceFromBridge,
  }) async {
    final myGeneration = ++_openingGeneration;
    bool openingStillMine() => _openingGeneration == myGeneration;
    workspaceOpening = true;
    workspaceError = null;
    _onLog('[workspace] opening… $logKey (spinner on)');
    _onNotify();
    // 本尝试挂上的 si 重试定时器（开源审查 J2 P2-1 后果③）：isGone 收尾
    // 时按身份精确回收，不误伤后续尝试新挂的定时器（旧实现泄漏到下次
    // close/重试成功，60s 周期空转）。
    Timer? myRetryTimer;
    try {
      final bridge = await openWithRetry();
      if (isGone()) {
        // isGone 早退必须复位 workspaceOpening（开源审查 I2 P2-2/J2）：
        // 此前只有成功/失败两路复位，早退残留 true 会永久封死
        // maybeScheduleWorkspaceRedrive 的闸门并让开屏 spinner 卡死。
        // 回测组1 P2：复位加代际守卫——isGone 成立即可能有新 open 已
        // 再次置 true，陈旧 attempt 不得偷走（spinner 消失/闸门放行
        // →并发重开双桥）。
        if (openingStillMine()) workspaceOpening = false;
        bridge.dispose();
        return;
      }
      _bridge = bridge;
      if (workspaceFromBridge != null) {
        activeWorkspace = workspaceFromBridge(bridge.bridge);
      }
      final workspace = activeWorkspace;
      final key = workspace == null ? null : workspaceKeyOf(workspace);
      if (workspace == null || key == null) {
        throw StateError('ready 桥载荷缺少 workspaceKey/workspacePath');
      }
      // conv 局部引用（开源审查 J2 P2-1 后果①）：降级分支的 `_conv!`
      // 在 si 订阅 await 窗口内可能被 close() 置空——空指针异常落外层
      // catch 会把「Null check operator…」拼进用户横幅。
      final conv = bridge.conversation(workspaceScopeOf(workspace), onLog: _onLog);
      _conv = conv;
      _onNotify();
      unawaited(_taskCatalog.loadProjects());
      unawaited(_taskCatalog.subscribeTasksIndex());
      SessionsIndexSubscription sub;
      try {
        sub = await conv.subscribeSessionsIndex(maxAttempts: 1);
        siDormant = false;
      } catch (e) {
        if ('$e'.contains('ChannelRpcError')) {
          _onLog('[workspace] si transient ($e), one more attempt');
          try {
            await Future<void>.delayed(const Duration(seconds: 2));
            if (isGone()) {
              if (openingStillMine()) workspaceOpening = false; // 回测组1 P2：陈旧早退不得偷新 open 标志
              return;
            }
            sub = await conv.subscribeSessionsIndex(maxAttempts: 1);
            siDormant = false;
          } catch (e2) {
            if (isGone()) {
              if (openingStillMine()) workspaceOpening = false; // 回测组1 P2：陈旧早退不得偷新 open 标志
              return;
            }
            _onLog('[workspace] si retry failed -> dormant degrade: $e2');
            siDormant = true;
            sub = conv.dormantSessionsIndex();
            _siRetryTimer?.cancel();
            myRetryTimer = _siRetryTimer = Timer.periodic(
              const Duration(seconds: 60),
              (_) => unawaited(retrySessionsIndex()),
            );
          }
        } else if (isRuntimeUnavailableError(e) || e is TimeoutException) {
          // 降级分支入口先验 isGone（开源审查 J2 P2-1 后果②）：陈旧
          // open 的降级晚于新 open 完成时会把新工作区的 siDormant 翻回
          // true（假降级窗口最长 60s，靠泄漏定时器重订阅自愈）。
          if (isGone()) {
            if (openingStillMine()) workspaceOpening = false; // 回测组1 P2：陈旧早退不得偷新 open 标志
            return;
          }
          _onLog('[workspace] si dormant（runtime 未运行，冷工作区降级只读）: $e');
          siDormant = true;
          sub = conv.dormantSessionsIndex();
          _siRetryTimer?.cancel();
          myRetryTimer = _siRetryTimer = Timer.periodic(
            const Duration(seconds: 60),
            (_) => unawaited(retrySessionsIndex()),
          );
        } else {
          rethrow;
        }
      }
      if (isGone()) {
        if (openingStillMine()) workspaceOpening = false; // 回测组1 P2：陈旧早退不得偷新 open 标志
        if (myRetryTimer != null && identical(_siRetryTimer, myRetryTimer)) {
          myRetryTimer.cancel();
          _siRetryTimer = null;
        }
        await sub.dispose();
        return;
      }
      _sessionsIndex = sub;
      _taskCatalog.replaceTaskList(sub, key, dormant: siDormant);
      unawaited(_taskCatalog.loadTaskIndex());
      _taskCatalog.attachBridge(bridge);
      workspaceOpening = false;
      _lastOpenAction = null;
      _redriveAttempt = 0;
      _redriveTimer?.cancel();
      _redriveTimer = null;
      _onNotify();
      _onLog(
        '[workspace] opened $key '
        '(si ${siDormant ? "dormant" : "${sub.state.list.length} sessions"}) '
        '(spinner off)',
      );
      unawaited(_persistLastWorkspace(key));
      _onCacheWrite();
    } catch (e) {
      _onLog('open workspace failed: $e');
      // 陈旧失败不覆盖新切换的状态（开源审查 J2 P2-2）：快速连续切换
      // A→B 时 A 的迟到失败会把 B 健康态的 workspaceError 写脏（此后无
      // 人再清，跨区打开因此误判「切换未完成」放弃开任务）——isGone
      // 即弃权，也不碰 workspaceOpening（新切换的在飞标志归它自己管）。
      if (isGone()) return;
      // 半开栈收尾（开源审查 J1-11）：si 订阅抛非降级错误 rethrow 时
      // _bridge/_conv 已落位而 _sessionsIndex 未建——redrive 闸以
      // `_bridge != null` 为「已开」代理被挡，自动重驱动失效。视为失败
      // 收尾：拆掉半开桥再调度（手动重试钮不受影响）。
      if (_sessionsIndex == null && _bridge != null) {
        _bridge?.dispose();
        _bridge = null;
        _conv = null;
      }
      workspaceOpening = false;
      // 原始异常串只进日志（上方 _onLog）；横幅走人话档（开源审查
      // J1-12/J3 P3-3）。
      workspaceError = _workspaceOpenErrorMessage(e);
      _onNotify();
      maybeScheduleWorkspaceRedrive();
    }
  }

  /// workspaceError 人话档（开源审查 J1-12/J3 P3-3）：原始异常（英文
  /// 协议串/ChannelRpcError/Bad state 前缀）此前直拼进横幅。分档对齐
  /// 会话层错误文案整改方向（超时/桥拒/桌面不在/其他）。
  String _workspaceOpenErrorMessage(Object e) {
    if (e is TimeoutException) {
      return '打开工作区超时：电脑未及时响应，请确认电脑端 ZCode 正在运行后重试';
    }
    if (isRuntimeUnavailableError(e)) {
      return '打开工作区失败：桌面端运行时未就绪，稍后会自动重试';
    }
    if ('$e'.contains('workspace-bridge-error') ||
        '$e'.contains('ChannelRpcError')) {
      return '打开工作区失败：桌面端拒绝了打开请求，请稍后重试或切换工作区';
    }
    return '打开工作区失败：连接异常，请重试';
  }

  Future<void> _persistLastWorkspace(String key) async {
    final updated = _profileProvider().copyWith(lastWorkspaceKey: key);
    _profileSetter(updated);
    try {
      await _persistProfileCallback(updated);
    } catch (e) {
      _onLog('persist last workspace failed (contained): $e');
    }
  }

  Future<void> retrySessionsIndex() async {
    if (_disposedProvider() || _siRetrying || !siDormant) return;
    // C2 L1：conv 可能已被 close() 提前置空（关栈窗口）——局部非空
    // 引用替代 `_conv!`，避免未捕获空指针（unawaited 定时器回调）。
    final conv = _conv;
    if (conv == null) return;
    _siRetrying = true;
    try {
      final dormantSub = _sessionsIndex;
      final sub = await conv.subscribeSessionsIndex();
      if (_disposedProvider() || !identical(_sessionsIndex, dormantSub)) {
        await sub.dispose();
        return;
      }
      _sessionsIndex = sub;
      siDormant = false;
      _siRetryTimer?.cancel();
      _siRetryTimer = null;
      unawaited(dormantSub?.dispose().catchError((_) {}));
      final key = workspaceKeyOf(activeWorkspace ?? const {});
      if (key != null) {
        _taskCatalog.replaceTaskList(sub, key, dormant: false);
        unawaited(_taskCatalog.loadTaskIndex());
      }
      _onNotify();
      _onLog('[workspace] si revived (${sub.state.list.length} sessions)');
    } catch (_) {
      if (_disposedProvider() || !siDormant) return;
      _siRetryTimer ??= Timer.periodic(const Duration(seconds: 60), (_) {
        unawaited(retrySessionsIndex());
      });
    } finally {
      _siRetrying = false;
    }
  }

  Future<void> refreshWorkspaces() async {
    final client = _clientProvider();
    if (client == null) return;
    if (_bridge != null) unawaited(_taskCatalog.loadProjects());
    try {
      final list = await client.listWorkspaces();
      final wsList = list is Map ? list['workspaces'] : null;
      if (wsList is List &&
          !_disposedProvider() &&
          identical(_clientProvider(), client)) {
        workspaces = wsList
            .whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
        _taskCatalog.storeWorkspaceTasks(list is Map ? list['tasks'] : null);
        _onNotify();
      }
    } catch (e) {
      _onLog('refresh workspaces failed: $e');
    }
  }

  /// [invalidateInFlightOpens]=false 仅限三个 switch 入口（它们自身先
  /// ++_switchEpoch 再调 close，作废的是"别人"的在飞打开）——外部关闭
  /// （suspend/disposeStack，经 ComputerStack._closeWorkspaceStack）默认
  /// 作废在飞 open，否则 close 的多段 await 窗口内 isGone 的 client 身份
  /// 判定未变（suspend 清 _client 发生在 close 落地之后），在飞 open 会
  /// 把 _bridge/_conv 写回即将释放的 client 上：半开栈复活，恢复期
  /// bootstrap 被"已有桥"守卫跳过，假在线死链（开源审查 J1-2）。
  Future<void> close({
    bool awaitCacheWrites = true,
    bool invalidateInFlightOpens = true,
  }) async {
    if (invalidateInFlightOpens) ++_switchEpoch;
    // isGone 早退路径不复位 workspaceOpening（此前只有成功/失败两路
    // 复位），残留 true 会永久封死 redrive 闸（I2 P2-2）——close 统一
    // 兜底复位；随后若有新 open 会自行重新置位。
    workspaceOpening = false;
    _cancelDeviceCacheWrite();
    // 三轮审查 C2 L1：si 复活定时器取消与 siDormant 复位提到一切
    // await 之前——否则 _conv 提前置空后，60s 定时器恰好落在后续
    // flush/detach 的 await 窗口内时，retrySessionsIndex 会对 null
    // conv 解引用（unawaited 未捕获异常）。
    _siRetryTimer?.cancel();
    _siRetryTimer = null;
    siDormant = false;
    await _conversationRegistry.close(awaitWrites: awaitCacheWrites);
    // 对抗审查 M2：si dispose / detach 的 await 窗口内新发起的会话注册
    // 会捕获已递增的 epoch 且 transport 仍是旧 conv（isStale 恒假）→
    // 挂上即将 dispose 的桥。会话注册一关闭就先断 transport 引用，窗口
    // 内的新注册直接走"no active workspace"失败。
    _conv = null;
    await _flushDeviceCache(awaitWrites: awaitCacheWrites);
    final siSub = _sessionsIndex;
    _sessionsIndex = null;
    await _taskCatalog.detach(
      beforeTasksIndexDispose: () async {
        await siSub?.dispose();
      },
    );
    _bridge?.dispose();
    _bridge = null;
    activeWorkspace = null;
  }
}
