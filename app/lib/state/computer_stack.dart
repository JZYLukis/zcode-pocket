import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../transport/companion_client.dart';
import '../transport/project_tree.dart';
import '../transport/relay_v2.dart';
import '../transport/conversation.dart';
import '../transport/relay_client.dart';
import '../transport/z_transport.dart';
import 'cache_policy.dart';
import 'conversation_registry.dart';
import 'link_phase.dart';
import 'local_cache.dart';
import 'session_errors.dart';
import 'task_catalog.dart';
import 'task_list.dart';
import 'workspace_controller.dart';

/// createSession 的归属 projectId 取值（2026-10-23 真机反馈"手机选了
/// 工作区新建、桌面却落『任务』默认区"的修复）：host 端 reserveCreatedTask
/// 按 params.projectId 写 tasks.project_id（node.ts:2217-2224），缺省=null
/// =未归类。仅 project intent 桥携带——普通 tab 桥/任务桥不带（官方
/// cwd-not-in-roots：非项目根 workspacePath 带 projectId 会被桌面拒绝，
/// project-repository.ts:393-397；activeProjectId 可能是 __conversations__
/// 伪 id 也不可用，故只认桥的 intent）。
String? createSessionProjectId(Map<String, dynamic>? projectIntent) {
  final id = projectIntent?['projectId'];
  return id is String && id.trim().isNotEmpty ? id : null;
}

/// 归属回落（对抗审查 B1）：suspend/重启恢复路径按 workspace-list 恢复
/// 开的是**tab 桥**（无 project intent）——若恢复键恰为某项目根，用户
/// 在该项目下新建的归属会静默丢失（症状与本批修复的原始 bug 相同）。
/// 仅"工作区键=rootPath 直配"时回落；任务归属/projectForWorkspaceKey
/// 的其他匹配路径不参与（workspacePath ∉ roots 带 projectId 会被桌面
/// cwd-not-in-roots 拒）。
String? rootMatchedProjectId(String? key, List<Map<String, dynamic>> projects) {
  if (key == null) return null;
  for (final p in projects) {
    final id = '${p['id'] ?? ''}'.trim();
    if (id.isEmpty) continue;
    if (rootPathsOf(p).contains(key)) return id;
  }
  return null;
}

/// 一台电脑的完整连接栈（波次 3a，D4 多电脑并行）：
/// relay client + 工作区 bridge + v4 会话传输 + 订阅集合。
///
/// - AppState 持有栈注册表（deviceSid → ComputerStack），切换电脑 = 换
///   UI 指针，不再拆除旧栈；
/// - **后台栈降级保活**：relay + sessions-index + 任务索引维持（秒切回来、
///   为阶段 3 双电脑通知打底），会话订阅随切出释放（重新进入时
///   ensureConversation 重订阅，服务端即时重放快照）；
/// - 每栈一份 LinkPhase（computeStatus 派生），档案面板显示各电脑实时状态。
///
/// KICKED 语义安全：协议每桌面仅一个 mobile terminal——两台电脑两个
/// deviceSid，手机同时作为两台电脑的 terminal 合法且互不干扰。
class ComputerStack extends ChangeNotifier {
  ComputerStack({
    required this.profile,
    required this.onLog,
    required this.onFailure,
    this.cache,
    this.accountJwtProvider,
  }) {
    _taskCatalog = TaskCatalog(
      bridgeProvider: () => _bridge,
      conversationProvider: () => _conv,
      activeWorkspaceProvider: () => activeWorkspace,
      workspacesProvider: () => workspaces,
      disposedProvider: () => _disposed,
      onLog: _log,
      onNotify: notifyListeners,
      onCacheWrite: _scheduleDeviceCacheWrite,
      onTaskListChanged: _onTaskListChangedForCache,
      onTaskListRebuilt: (model) => onTaskListRebuilt?.call(model),
    );
    _conversationRegistry = ConversationRegistry(
      cache: cache,
      deviceSid: () => profile.deviceSid,
      transportProvider: () => _conv,
      siDormantProvider: () => siDormant,
      retrySessionsIndex: _retrySessionsIndex,
      disposedProvider: () => _disposed,
      onLog: _log,
    );
    _workspaceController = WorkspaceController(
      conversationRegistry: _conversationRegistry,
      taskCatalog: _taskCatalog,
      clientProvider: () => _client,
      disposedProvider: () => _disposed,
      profileProvider: () => profile,
      profileSetter: (value) => profile = value,
      persistProfile: (value) async {
        await onPersistProfile?.call(value);
      },
      onLog: _log,
      onNotify: notifyListeners,
      onCacheWrite: _scheduleDeviceCacheWrite,
      cancelDeviceCacheWrite: _cancelDeviceCacheWrite,
      flushDeviceCache: ({awaitWrites = true}) =>
          _flushDeviceCache(awaitWrites: awaitWrites),
      onBootstrapStarted: () => _bootstrapStarted = true,
      ensureWorkspaceListSubscription: (client) {
        // 三轮审查 C2 L2：HEAD 的 start() 用直赋值 `=`（残留旧订阅会被
        // 覆盖泄漏但绝不误绑）；`??=` 则在假想的"清 client 漏 cancel"
        // 路径下静默绑死旧流。先 cancel 再赋值，两头都安全。
        unawaited(_workspaceListSub?.cancel() ?? Future<void>.value());
        _workspaceListSub = client.workspaceListUpdated.listen(_onWorkspaceList);
      },
    );
  }

  DeviceProfile profile;
  final void Function(String line) onLog;
  final void Function(ComputerStack stack, RelayFailure failure) onFailure;

  /// 本地缓存（阶段 3，可空=测试/无平台环境）：设备级预渲 + 会话行缓存。
  final LocalCacheStore? cache;

  /// V2 账号 JWT 读取器（AppState 注入 AccountStore；V1 档案不使用）。
  final Future<String?> Function()? accountJwtProvider;

  CompanionClient? _client;
  StreamSubscription? _failureSub;
  StreamSubscription? _workspaceListSub;
  BridgeSession? get _bridge => _workspaceController.bridge;
  set _bridge(BridgeSession? value) => _workspaceController.bridge = value;
  ConversationTransport? get _conv => _workspaceController.conversation;
  set _conv(ConversationTransport? value) =>
      _workspaceController.conversation = value;
  late final ConversationRegistry _conversationRegistry;
  late final TaskCatalog _taskCatalog;
  late final WorkspaceController _workspaceController;
  SessionsIndexSubscription? get _sessionsIndex =>
      _workspaceController.sessionsIndexSubscription;
  set _sessionsIndex(SessionsIndexSubscription? value) =>
      _workspaceController.sessionsIndexSubscription = value;

  /// 最近一次 relay 失败的人话（computeStatusDetail error 档用）。
  String? _lastFailureMessage;

  /// 悬挂中的栈恢复统一入口判定用：suspend 落地中 resume 不得抢跑
  /// （2026-10-26 断线批 D4：回前台落在 suspend 的 await 窗口内时，
  /// resume 见 _client 未清而空转，栈被留在悬挂态无人恢复）。
  Future<void>? _suspendInFlight;

  /// controller/tasks-index 订阅（：跨工作区搜索数据源+任务
  /// 实时标志增量的官方继任通道；随 bridge 生命周期，si dormant 不影响）。
  List<Map<String, dynamic>> get workspaces => _workspaceController.workspaces;
  set workspaces(List<Map<String, dynamic>> value) =>
      _workspaceController.workspaces = value;

  List<Map<String, dynamic>> get projects => _taskCatalog.projects;
  set projects(List<Map<String, dynamic>> value) => _taskCatalog.projects = value;
  List<Map<String, dynamic>> get projectTasks => _taskCatalog.projectTasks;
  set projectTasks(List<Map<String, dynamic>> value) =>
      _taskCatalog.projectTasks = value;
  String get readTreeStatus => _taskCatalog.readTreeStatus;
  set readTreeStatus(String value) => _taskCatalog.readTreeStatus = value;
  String? get activeProjectId => _taskCatalog.activeProjectId;
  set activeProjectId(String? value) => _taskCatalog.activeProjectId = value;
  List<Map<String, dynamic>> get archivedTasks => _taskCatalog.archivedTasks;
  set archivedTasks(List<Map<String, dynamic>> value) =>
      _taskCatalog.archivedTasks = value;
  List<Map<String, dynamic>> get workspaceTasks => _taskCatalog.workspaceTasks;
  set workspaceTasks(List<Map<String, dynamic>> value) =>
      _taskCatalog.workspaceTasks = value;
  TaskListModel? get _taskList => _taskCatalog.taskList;

  Map<String, dynamic>? get activeWorkspace =>
      _workspaceController.activeWorkspace;
  set activeWorkspace(Map<String, dynamic>? value) =>
      _workspaceController.activeWorkspace = value;
  String? get desktopAppVersion => _workspaceController.desktopAppVersion;
  set desktopAppVersion(String? value) =>
      _workspaceController.desktopAppVersion = value;
  bool get workspaceOpening => _workspaceController.workspaceOpening;
  set workspaceOpening(bool value) =>
      _workspaceController.workspaceOpening = value;

  /// F1 冷工作区降级：si 订阅 dormant（runtime 未运行）——任务索引照常，
  /// 点开会话冷启动后自动复活（官方 sessionsIndexStore dormant 语义）。
  bool get siDormant => _workspaceController.siDormant;
  set siDormant(bool value) => _workspaceController.siDormant = value;
  String? get workspaceError => _workspaceController.workspaceError;
  set workspaceError(String? value) => _workspaceController.workspaceError = value;

  bool _disposed = false;
  bool get disposed => _disposed;

  void _log(String line) => onLog(line);

  // ------------------------------------------------------------ 派生状态

  /// 栈级 LinkPhase（UI 视角）。invalid 优先（凭据作废），其余由 relay +
  /// bridge 派生——与单栈时代 AppState 的语义一致。
  LinkPhase computeStatus() {
    if (profile.invalid) return LinkPhase.invalid;
    final client = _client;
    if (client == null) return LinkPhase.offline;
    switch (client.relay.state) {
      case RelayState.paired:
        return _bridge != null ? LinkPhase.online : LinkPhase.connecting;
      case RelayState.reconnecting:
        return LinkPhase.reconnecting;
      case RelayState.waiting:
        return LinkPhase.waitingDesktop;
      case RelayState.kicked:
        return LinkPhase.kicked;
      case RelayState.error:
        return LinkPhase.error;
      case RelayState.connecting:
      case RelayState.authenticating:
        return LinkPhase.connecting;
      case RelayState.idle:
      case RelayState.closed:
        return LinkPhase.offline;
    }
  }

  String? computeStatusDetail() {
    if (profile.invalid) return '桌面已刷新二维码，请重新扫码';
    final client = _client;
    if (client == null) return null;
    switch (computeStatus()) {
      case LinkPhase.online:
        return desktopAppVersion == null ? null : '桌面 $desktopAppVersion';
      case LinkPhase.kicked:
        return '已被其他设备接管（每台桌面仅允许一个手机连接）';
      case LinkPhase.waitingDesktop:
        return '等待桌面端配对';
      case LinkPhase.connecting:
        // 真话区分（2026-10-26 断线批 D2）：relay 已配上但桥未建≠连接
        // 恢复中——此前空串让横幅渲染成"连接恢复中…（）"空括号。
        if (client.relay.state == RelayState.paired && _bridge == null) {
          return '中继已连，正在恢复工作区';
        }
        return '正在建立连接';
      case LinkPhase.reconnecting:
        return '连接已断开，自动重连中';
      case LinkPhase.error:
        return _lastFailureMessage ?? '连接已中断';
      default:
        return null;
    }
  }

  /// relay 已 paired 但桥未建立（断线后工作区未恢复/切换中断线）。
  /// 横幅用：此态下"连接恢复中"是假话，真话是工作区在恢复。
  bool get workspaceRestoring =>
      _bridge == null &&
      _client != null &&
      _client!.relay.state == RelayState.paired;

  // ------------------------------------------------------- 本地缓存（阶段 3）

  /// 缓存预渲是否已应用过（幂等守卫：seed 一次，之后只让位给真实数据）。
  bool _cacheSeeded = false;

  /// bootstrap 已启动（同步置位）：迟到的缓存读结果不得覆盖进行中的
  /// 工作区恢复（R2/R3 类迟到写入防复发）。
  bool _bootstrapStarted = false;
  Timer? _deviceCacheWriteTimer;

  /// 设备级缓存预渲（工作区栏 + 任务列表 + 桥身份标记）。
  ///
  /// **桥缓存红线**（phase3-cache-design）：这里只把"上次呈现"放上去，
  /// 让锁屏唤醒/重进 app 的工作区栏与任务列表不空转等网络；恢复路径
  /// （bootstrap → workspace-list → workspace-bridge-open → si 订阅）
  /// 一步不减——本函数不触碰任何连接/桥逻辑。
  /// 测试缝（电量批 2026-10-30，设备缓存去重红绿）：单独驱动设备缓存
  /// 恢复路径（生产由 start() 异步触发，会连带真实中继连接，测试不可用）。
  /// 生产禁止调用。
  @visibleForTesting
  Future<void> debugLoadDeviceCacheForTest() => _loadDeviceCache();

  Future<void> _loadDeviceCache() async {
    final store = cache;
    if (store == null || _disposed) return;
    final cached = await store.readDevice(profile.deviceSid);
    if (_disposed || cached == null) return;
    // 对账守卫：真实数据已到（桥已开/活任务列表已建/已 seed 过）→ 让位。
    if (_bridge != null ||
        _sessionsIndex != null ||
        _cacheSeeded ||
        _bootstrapStarted ||
        (_taskList != null)) {
      return;
    }
    _cacheSeeded = true;
    workspaces = cached.workspaces;
    activeWorkspace = cached.activeWorkspace;
    desktopAppVersion = cached.desktopAppVersion;
    // B 首页增量：项目/全局任务也预渲（仅当 live 值为空才填，避免迟到
    // 缓存覆盖先到真实数据）。running/waiting 在读取时清洗为 idle。
    if (projects.isEmpty && cached.projects.isNotEmpty) {
      projects = cached.projects;
    }
    if (projectTasks.isEmpty && cached.projectTasks.isNotEmpty) {
      projectTasks = cached.projectTasks;
    }
    if (workspaceTasks.isEmpty && cached.workspaceTasks.isNotEmpty) {
      workspaceTasks = cacheHomeTaskRows(
        cached.workspaceTasks,
        sanitizeLive: true,
      );
    }
    _refreshActiveProject();
    final si = SessionsIndexState();
    for (final raw in _sanitizePreviewSessions(cached.sessions)) {
      final entry = SessionEntry(raw);
      if (entry.sessionId.isNotEmpty) si.sessions[entry.sessionId] = entry;
    }
    final key =
        workspaceKeyOf(cached.activeWorkspace ?? const {}) ??
        profile.lastWorkspaceKey ??
        '';
    final model = _taskCatalog.seedCachedModel(
      cached: cached,
      sessions: si,
      workspaceKey: key,
    );
    _log(
      '[cache] device preview: workspaces=${cached.workspaces.length} '
      'tasks=${model.cards.length} projects=${projects.length} '
      'globalTasks=${workspaceTasks.length} savedAt=${cached.savedAt}',
    );
    notifyListeners();
  }

  void _onTaskListChangedForCache() => _scheduleDeviceCacheWrite();

  /// 预渲 si 条目 running 清洗（ J3 P3-6）：si 原始条目 phase 可
  /// 能是 running（缓存落盘于回合进行中）——两路任务行（workspaceTasks/
  /// channelActive）已有 sanitize，sessions 这一路此前原样进预渲，dormant
  /// 模型把已结束回合渲染成"运行中"。落盘保留原值（真实数据到达自然
  /// 覆盖），仅读取侧清洗为 idle；running 行的 pendingInteraction 一并
  /// 清空（陈旧交互提示在预渲窗口是死按钮）。与 2026-10-27 用户⑨
  /// "running/waiting 清洗、不冒充当前仍运行"契约对齐。
  static List<Map<String, dynamic>> _sanitizePreviewSessions(
    List<Map<String, dynamic>> sessions,
  ) {
    return [
      for (final s in sessions)
        if (s['phase'] == 'running' ||
            s['phase'] == 'prewarming' ||
            s['phase'] == 'waiting')
          {...s, 'phase': 'idle', 'pendingInteraction': null}
        else
          s,
    ];
  }

  /// 设备级缓存写入（debounce 1.5s：si 流式期间通知频繁，静默后才落盘；
  /// 乐观操作（置顶/归档/删除/已读）经同一 notify 路径即时反映）。
  void _scheduleDeviceCacheWrite() {
    final store = cache;
    if (store == null || _disposed) return;
    _deviceCacheWriteTimer?.cancel();
    _deviceCacheWriteTimer = Timer(const Duration(milliseconds: 1500), () {
      if (_disposed) return;
      unawaited(_writeDeviceCacheNow());
    });
  }

  /// 上次成功落盘的内容指纹（不含 savedAt——它每次都变，去重必须排除）。
  /// 电量（18075 验收实证）：后台保活期订阅持续推帧，任务列表模型每
  /// ~5s notify 一次但内容大多无差异——真机日志 [cache] device saved
  /// 连续多次写同内容。内容未变不落盘。
  String? _lastDeviceCacheContentJson;

  /// 设备写串行链（ A8/B-2）：防抖定时器写与 flush 直呼
  /// 并发时 tmp+rename 落序无保证——链式排队后终态恒为最后发起的内容。
  Future<void> _deviceWriteChain = Future<void>.value();

  Future<void> _writeDeviceCacheNow() async {
    final store = cache;
    final model = _taskList;
    if (store == null || model == null || _disposed) return;
    final entry = DeviceCacheEntry(
      deviceSid: profile.deviceSid,
      workspaces: workspaces,
      projects: projects,
      projectTasks: cacheHomeTaskRows(projectTasks),
      workspaceTasks: cacheHomeTaskRows(workspaceTasks),
      activeWorkspace: activeWorkspace,
      desktopAppVersion: desktopAppVersion,
      sessions: model.sessionsForCache,
      channelActive: model.channelTasksForCache,
      pinnedIds: model.pinnedIdsForCache,
      archivedIds: model.archivedIdsForCache,
      deletedIds: model.deletedIdsForCache,
      savedAt: DateTime.now().millisecondsSinceEpoch,
    );
    // encode 包裹（ B-1）：jsonEncode 已从 store 的吞错圈移
    // 出——未来塞入不可编码值不得把 flush/suspend 炸成半关态。
    String contentJson;
    try {
      contentJson = jsonEncode(entry.toJson()..remove('savedAt'));
    } on Object catch (e) {
      _log('[cache] device encode failed (contained): $e');
      return;
    }
    if (contentJson == _lastDeviceCacheContentJson) return;
    final write = _deviceWriteChain.then((_) async {
      try {
        if (_disposed) return;
        // 写失败不更新指纹（A8 主修）：瞬时 IO 失败后同内容下轮 notify
        // 仍会重试，去重不再把"丢一次写"放大成"丢到内容再变"。
        final ok = await store.writeDevice(entry);
        if (!ok) return;
        _lastDeviceCacheContentJson = contentJson;
        _log(
          '[cache] device saved: workspaces=${workspaces.length} '
          'tasks=${model.cards.length}',
        );
      } on Object catch (e) {
        _log('[cache] device write chain (contained): $e');
      }
    });
    _deviceWriteChain = write;
    await write;
  }

  void _cancelDeviceCacheWrite() {
    _deviceCacheWriteTimer?.cancel();
    _deviceCacheWriteTimer = null;
  }

  /// 设备级缓存最终态：调用方先完成会话 writer flush，再走到这里；
  /// 此时 TaskListModel 必须仍然可用。
  Future<void> _flushDeviceCache({bool awaitWrites = true}) async {
    if (_taskList != null) {
      if (awaitWrites) {
        await _writeDeviceCacheNow();
      } else {
        unawaited(_writeDeviceCacheNow().catchError((_) {}));
      }
    }
  }

  /// 会话缓存读取（页面首帧预渲入口，经 AppState 门面路由）。
  Future<SessionCacheEntry?> readSessionCache(String sessionId) =>
      _conversationRegistry.readSessionCache(sessionId);

  // ------------------------------------------------------------- lifecycle

  /// 建栈并连接（activate 的连接部分原样搬移）。bootstrap 失败不抛——
  /// 状态横幅由派生状态驱动。
  /// 被踢终态后的用户主动接管（用户需求①）。
  void retryAfterKicked() => _client?.relay.retryAfterKicked();

  Future<void> start() async {
    if (_disposed || _client != null) return;
    // 设备级缓存预渲（先渲后对账）：本地快，先于网络把它放上去；
    // 真实 bootstrap/订阅到达后按既有路径整体覆盖。
    unawaited(_loadDeviceCache());
    final client = switch (profile) {
      // 双栈选栈：V1=pass_hash 档案；V2=账号档案（JWT 经
      // AccountStore 注入；缺 provider=测试环境 → auth-required 降级）。
      RelayProfile p => CompanionClient(p.params, onLog: _log),
      AccountV2Profile p => CompanionClient.v2(
        config: RelayV2Config(
          endpointOrigin: relayV2DefaultOrigin(),
          deviceSid: p.deviceSid,
          deviceMid: p.deviceMid,
          deviceName: p.deviceName,
          appVersion: p.appVersion,
        ),
        jwtProvider: accountJwtProvider ?? () async => null,
        onLog: _log,
      ),
      LanProfile() => throw StateError('局域网档案未实装'),
      // DeviceProfile 非密封：防御未来新档案类型（V1/V2 之外的都拦）。
      _ => throw StateError('未知档案类型：${profile.runtimeType}'),
    };
    _client = client;
    _failureSub = client.relay.failures.listen((f) {
      // D2：error 档人话（此前 computeStatusDetail 对 error 返回空串，
      // 横幅渲染成"连接恢复中…（）"）。
      _lastFailureMessage = f.message;
      onFailure(this, f);
      notifyListeners();
    });
    client.relay.stateListenable.addListener(_onRelayState);
    unawaited(client.connect());
    try {
      await client.waitPaired(timeout: const Duration(seconds: 90));
      if (_disposed || !identical(_client, client)) return;
    } catch (e) {
      if (_disposed || !identical(_client, client)) return;
      _log('connect failed: $e');
      // 配对超时/中继不可达：连接栈内部会继续重试，状态由派生呈现。
      _startBootstrapWhenPaired(client);
      notifyListeners();
      return;
    }

    _workspaceController.prepareBootstrap(client);
    try {
      await _bootstrapWorkspace(client);
    } catch (e) {
      if (_disposed || !identical(_client, client)) return;
      _log('bootstrap failed: $e');
      notifyListeners();
      _maybeScheduleWorkspaceRedrive();
    }
  }

  /// waitPaired 超时后 relay 仍在自动重连——恢复在线时再走 bootstrap。
  void _startBootstrapWhenPaired(CompanionClient client) =>
      _workspaceController.startBootstrapWhenPaired(client);

  void _onRelayState() => _workspaceController.onRelayState();

  void _maybeScheduleWorkspaceRedrive() =>
      _workspaceController.maybeScheduleWorkspaceRedrive();

  /// 手动重试入口（任务中心 workspaceError 态按钮）：优先重放原意图
  /// ——失败切换残留的 activeWorkspace 是占位键（不带 project/task
  /// intent），直接重开会再吃一次"目标工作区不在当前桌面窗口中"。
  Future<void> retryWorkspaceOpen() => _workspaceController.retryWorkspaceOpen();

  void _onWorkspaceList(dynamic result) =>
      _workspaceController.onWorkspaceList(result);

  Future<void> _bootstrapWorkspace(CompanionClient client) =>
      _workspaceController.bootstrapWorkspace(client);

  // ------------------------------------------------------------- workspace

  /// 切换工作区 = 切换 bridge（retro 1.2）。会话订阅全部随旧 bridge 释放。
  /// [keepHomePreview]（2026-11-05 反馈②A）：跨工作区打开任务时为 true。
  Future<void> switchWorkspace(
    Map<String, dynamic> workspace, {
    bool keepHomePreview = false,
  }) => _workspaceController.switchWorkspace(
    workspace,
    keepHomePreview: keepHomePreview,
  );

  /// 切换项目（ 工作区列表修复）：3.16 workspace-list=当前窗口
  /// tabs，项目全集在 project.readTree；未开 tab 的项目走
  /// workspace-bridge-open 的 project intent（桌面现场 prepareProjectWorkspace）。
  /// 请求 workspaceKey 为主根目录占位（官方 web 同款语义），真实工作区以
  /// ready 桥载荷重建 activeWorkspace。
  Future<void> switchToProject(
    Map<String, dynamic> project, {
    bool keepHomePreview = false,
  }) => _workspaceController.switchToProject(
    project,
    keepHomePreview: keepHomePreview,
  );

  /// 「任务」伪项目就地选中（2026-10-25 用户拍板：与其他工作区一致——
  /// chip 点按不再推独立聚合页，主列表就地切到未归类任务全集）。
  /// 不关桥不切 intent：聚合数据来自 tasks-index/projectTasks，与活跃桥
  /// 解耦；保留当前桥（新建草稿/快切回项目不重连）。PF-3③ 显式选中
  /// 机制复用——readTree 重拉不覆盖。
  void switchToConversations() => _workspaceController.switchToConversations();

  /// A5：查看态上报（官方 mobileTaskView 逐次变化上报、
  /// Home/后台立即取消，task-realtime-sync.ts:225 对位）——桌面据此抑
  /// 未读。开桥时已发一次；此处补"打开任务=带 activeTaskId、退后台/
  /// 回主页=不带"两态。失败静默（best-effort）。
  void reportViewState({String? taskId}) =>
      _workspaceController.reportViewState(taskId: taskId);

  /// 会话子代理列表（2026-10-26 批④拍板⑥）：活跃工作区会话传输上的
  /// listSessionSubagents 透传（官方 zcodeAgentService 对位）。
  Future<Map<String, dynamic>> sessionSubagents(
    String sessionId, {
    String? endedCursor,
    int endedLimit = 20,
  }) => _workspaceController.sessionSubagents(
    sessionId,
    endedCursor: endedCursor,
    endedLimit: endedLimit,
  );

  /// 任务 intent 开桥（taskId+taskHostId——官方手机壳打开侧栏任务的
  /// 路径，validation.ts:921-933：桌面经 resolveSessionDirectories 解析
  /// 任意任务的执行目录，未归类/已删项目任务同样可达）。request 的
  /// workspaceKey 为任务 workspace 键，真实 target 随 ready 桥返回。
  Future<void> switchToTask(
    Map<String, dynamic> task, {
    String? label,
    bool keepHomePreview = false,
  }) => _workspaceController.switchToTask(
    task,
    label: label,
    keepHomePreview: keepHomePreview,
  );

  /// 2026-11-05 反馈②A：跨工作区打开失败时清保住的旧首页行。
  void clearStaleHomePreview() => _taskCatalog.clearStaleHomePreview();

  /// PF-3③（2026-10-24 修复批）：选中项目派生重算——显式选中优先；
  /// 否则按当前工作区键反查项目归属（无归属=清除，不滞留旧值）。
  /// readTree 重拉与归属变化后都走这里，防侧栏高亮滞留。
  void _refreshActiveProject() => _taskCatalog.refreshActiveProject();

  /// 测试缝（H10 红绿，2026-10-25 批①）：种子"桥已就绪+项目全集已载"
  /// 的稳态——switchToProject/switchToConversations 的门逻辑（幂等门
  /// 病根）跑的是本尊状态机，桥/索引/客户端由测试注入离线替身。
  /// 不动 _explicitProjectId（重复调用=模拟 readTree 重拉后重算派生）。
  /// 生产禁止调用。
  @visibleForTesting
  void debugSeedProjectWorkspaceForTest({
    required Map<String, dynamic> workspace,
    required List<Map<String, dynamic>> seedProjects,
    required List<Map<String, dynamic>> seedTasks,
    required BridgeSession bridge,
    required SessionsIndexSubscription sessionsIndex,
    required CompanionClient client,
  }) {
    projects = seedProjects;
    projectTasks = seedTasks;
    activeWorkspace = workspace;
    _bridge = bridge;
    _sessionsIndex = sessionsIndex;
    _client = client;
    _refreshActiveProject();
    notifyListeners();
  }

  /// 侧栏条目（官方 ProjectSidebar 同构：「项目」区 + 「任务」区）：
  /// 可见项目在前，存在未归类任务时追加「任务」伪项目（默认工作区）。
  List<Map<String, dynamic>> sidebarEntries() => _taskCatalog.sidebarEntries();

  /// 未归类任务全集（updatedAt 降序）——「任务」列表页数据源。
  List<Map<String, dynamic>> unclassifiedTasks() =>
      _taskCatalog.unclassifiedTasks();

  /// 档案持久化回调（AppState 注入：写 store + 刷新 profiles 列表）。
  Future<void> Function(DeviceProfile profile)? onPersistProfile;

  /// 任务列表重建回调（阶段 3 通知协调器挂接：切工作区/dormant 复活/
  /// 缓存预渲都会重建 TaskListModel，监听者须跟随重挂）。
  void Function(TaskListModel? model)? onTaskListRebuilt;

  /// 任务移动归属（官方 project.moveTask：
  /// contract.ts:42-47）。[task] 为 readTree 任务行（workspacePath/
  /// workspaceIdentity?/taskId/hostId 齐备）。目标目录不在项目 roots 时
  /// 服务端抛 `project.root-confirmation-required`——调用方弹确认后带
  /// [addMissingRoot] 重发（官方 ProjectSidebarNode.tsx:157-172 同款
  /// 二段流）。成功后重拉 readTree（归属消费面全靠它）。
  Future<void> moveTask(
    Map<String, dynamic> task,
    String projectId, {
    bool addMissingRoot = false,
  }) => _taskCatalog.moveTask(
    task,
    projectId,
    addMissingRoot: addMissingRoot,
  );

  /// UI 门面：按 workspace 键取项目条目（跨项目任务打开用）。
  Map<String, dynamic>? projectForKey(String key) =>
      _taskCatalog.projectForKey(key);

  // ---------------------------------------- controller/tasks-index

  /// 拉取 zcodeTask 任务索引三列表（listTasks/listPinnedTasks/listArchivedTasks，
  /// 官方 windowHostControllerService.readSourceTaskIndex 同款成员关系语义）。
  /// 任一列表失败不阻塞其余（12s 超时， zemote 同款容错）。
  /// 任务索引重载入口（F17 操作后由 AppState 调用刷新列表）。
  void reloadTaskIndex() => _taskCatalog.reloadTaskIndex();

  /// 任务全文搜索（官方 listTaskList：title + searchable_text 对话正文
  /// LIKE 命中并返回 searchSnippet 片段，refs zcodeTaskService.ts:472、
  /// taskIndexRepo.ts:2166-2189）。注意官方 kind 语义：active = 置顶除外
  /// 未归档、pinned = 仅置顶——要覆盖全部未归档任务须两路各查一次合并。
  /// scopes = 该设备全部已知工作区（官方 TaskSearchDialog 传全部工作区
  /// tab 同语义；空 scopes 官方直接返回空）。失败/未连接返回 null（UI
  /// 退化为本地标题/预览过滤）。
  Future<List<Map<String, dynamic>>?> searchTaskList(
    String query, {
    int limit = 50,
  }) => _taskCatalog.searchTaskList(query, limit: limit);

  // -------------------------------------------------- 任务管理（波次 3a）

  Future<dynamic> setTaskPinned(String taskId, bool pinned) =>
      _taskCatalog.setTaskPinned(taskId, pinned);

  /// F17（WR 对齐）：重命名任务（官方 renameTask{title}）。
  Future<dynamic> renameTask(String taskId, String title) =>
      _taskCatalog.renameTask(taskId, title);

  /// 归档（桌面归档同款 RPC；列表剔除由墓碑+archived 双保险）。
  Future<dynamic> archiveTask(String taskId) => _taskCatalog.archiveTask(taskId);

  /// 删除单个归档任务（官方 deleteArchivedTask：仅归档态可删，硬删除）。
  Future<dynamic> deleteArchivedTask(String taskId) =>
      _taskCatalog.deleteArchivedTask(taskId);

  /// 批量删除归档任务（官方 deleteArchivedTasks：返回三分计数）。
  Future<dynamic> deleteArchivedTasks(List<String> taskIds) =>
      _taskCatalog.deleteArchivedTasks(taskIds);

  /// 取消归档（撤销入口，snackbar 撤销用）。
  Future<dynamic> unarchiveTask(String taskId) =>
      _taskCatalog.unarchiveTask(taskId);

  /// 删除（不可逆，UI 必须二次确认）。
  Future<dynamic> deleteTask(String taskId) => _taskCatalog.deleteTask(taskId);

  /// 标记已读（打开任务时调用，best-effort）。
  Future<dynamic> markTaskRead(String taskId, {int? expectedUnreadAt}) =>
      _taskCatalog.markTaskRead(taskId, expectedUnreadAt: expectedUnreadAt);

  /// F17：主动标为未读（桌面 TaskActionMenu 同款）。
  Future<dynamic> markTaskUnread(String taskId, {required bool unread}) =>
      _taskCatalog.markTaskUnread(taskId, unread: unread);

  /// 下拉刷新：重拉 workspace-list（sessions-index 本身是实时订阅）+
  /// 项目全集。
  Future<void> refreshWorkspaces() => _workspaceController.refreshWorkspaces();

  // ---------------------------------------------------------- conversation

  ConversationTransport? get conversation => _conv;
  BridgeSession? get bridge => _bridge;
  SessionsIndexState? get sessionsIndex => _sessionsIndex?.state;
  TaskListModel? get taskList => _taskList;

  /// B1 兜底：按 sessionId 取缓存中的活订阅（页面 ensure 超时后直捞）。
  ConversationSubscription? subscriptionOf(String sessionId) =>
      _conversationRegistry.subscriptionOf(sessionId);

  Map<String, ConversationState> get conversationStates =>
      _conversationRegistry.conversationStates;

  @visibleForTesting
  void debugOnRelayStateForTest() => _onRelayState();

  /// 会话注册生命周期测试注入缝：只替换当前工作区传输，不触发开桥。
  /// 生产禁止调用。
  @visibleForTesting
  void debugSeedConversationTransportForTest(ConversationTransport value) {
    _conv = value;
  }

  /// 包装层（三轮审查 C1 M1/D1 M1）：demote/close 的清场竞态让在飞
  /// 注册以「会话订阅已重置」收场——这里等清场完成后**重试一次**：
  /// 切电脑场景桥仍活，重试即恢复（比 HEAD 的静默泄漏订阅更自愈）；
  /// 关栈场景 transport 已空，重试抛「no active workspace」给页面
  /// 错误态（可重开）。交付即死（防御分支）同样重试。
  //识别走专用异常类型：此前按错误文案
  /// 子串匹配，文案改动/本地化会静默失去这层自愈。
  Future<ConversationSubscription> ensureConversation(
    String sessionId, {
    SessionCacheEntry? seedCacheEntry,
  }) async {
    ConversationSubscription sub;
    try {
      sub = await _conversationRegistry.ensureConversation(
        sessionId,
        seedCacheEntry: seedCacheEntry,
      );
    } on SessionSubscriptionResetError {
      await _conversationRegistry.quiesce();
      // 重试路径不带缓存种子（清场后桥身份已换，重读一次更稳）。
      sub = await _conversationRegistry.ensureConversation(sessionId);
    }
    if (sub.isDisposed) {
      await _conversationRegistry.quiesce();
      return _conversationRegistry.ensureConversation(sessionId);
    }
    return sub;
  }

  /// si 复活（dormant → live）：成功后重建 TaskListModel 绑定真实订阅态。
  Future<void> _retrySessionsIndex() =>
      _workspaceController.retrySessionsIndex();

  Future<String> createSession(
    String? firstText, {
    Map<String, dynamic>? config,
  }) async {
    final conv = _conv;
    final workspace = activeWorkspace;
    final key = workspace == null ? null : workspaceKeyOf(workspace);
    if (conv == null || key == null) {
      throw StateError('no active workspace');
    }
    // 新会话归属（2026-10-23 真机反馈"手机选了工作区、桌面落任务区"）：
    // host 端 reserveCreatedTask 按 params.projectId 写 tasks.project_id，
    // 缺省即落桌面「任务」默认区。取值规则见 createSessionProjectId；
    // 桥 intent 缺席时按项目根直配回落（rootMatchedProjectId——恢复路径
    // 的 tab 桥场景，对抗审查 B1）。
    // 任务桥不回落（2026-10-24 真机实锤"选任务工作区新建却建到项目里"）：
    // 任务桥的 workspaceKey 可能恰为项目根（未归类任务跑在项目根目录，
    // 如临时性验证任务场景）——任务入口的语义是"跟随该任务目录"，
    // 官方对无归属创建（params 缺省）即未归类，回落只属恢复路径 tab 桥。
    final String? projectId = _bridge?.taskIntent != null
        ? createSessionProjectId(_bridge?.projectIntent)
        : createSessionProjectId(_bridge?.projectIntent) ??
              rootMatchedProjectId(key, projects);
    final sessionId = await conv.createSession(
      key,
      firstText: firstText,
      config: config,
      projectId: projectId,
    );
    try {
      await ensureConversation(sessionId);
    } on Object catch (error) {
      throw SessionCreatedSubscriptionError(sessionId, error);
    }
    return sessionId;
  }

  // ------------------------------------------------------ demote / dispose

  /// 后台驻留会话明细订阅（电量优化批 #16，2026-10-31）：保活分支
  /// （审批提醒开）退后台时 relay/bridge/si/tasks-index 全活——桌面活跃
  /// 会话的流式帧持续唤醒无线电是后台耗电主因（真机实证 660mAh/h，见
  /// 2026-10-30 节）。驻留=协议层退订全部会话
  /// 订阅但保留对象与状态（打开中的会话页引用继续有效），si+tasks-index
  /// 保留（通知数据源）。回前台 ensureConversation 惰性恢复（增量续订，
  /// 服务端只补 delta）。FGS 保活下预期 -250~400 mAh/h。
  Future<void> suspendConversationSubscriptions() =>
      _conversationRegistry.suspendForBackground();

  /// 1.0.1 真机验收⑩：保活分支后台再退订 tasks-index（5s notify 帧=
  /// 驻留后剩余推帧大头），数据保留，回前台重订阅增量补齐。
  Future<void> pauseTasksIndexForBackground() =>
      _workspaceController.pauseTasksIndexForBackground();
  Future<void> resumeTasksIndexFromBackground() =>
      _workspaceController.resumeTasksIndexFromBackground();

  /// 切后台：保留 relay + bridge + sessions-index + 任务索引（秒切回来、
  /// 阶段 3 通知打底），释放会话订阅（重新进入即重订阅，桌面重放快照）。
  Future<void> demote() async {
    _cancelDeviceCacheWrite();
    await _conversationRegistry.demote();
    await _flushDeviceCache();
    notifyListeners();
  }

  Future<void> _closeWorkspaceStack({bool awaitCacheWrites = true}) =>
      _workspaceController.close(awaitCacheWrites: awaitCacheWrites);

  /// 释放整栈（删除档案/凭据失效时）。保留 profile 记录由上层决定。
  Future<void> disposeStack() async {
    if (_disposed) return;
    _disposed = true;
    _workspaceController.cancelRedrive();
    await _failureSub?.cancel();
    _failureSub = null;
    await _workspaceListSub?.cancel();
    _workspaceListSub = null;
    await _closeWorkspaceStack();
    await _client?.dispose();
    _client = null;
    workspaces = const [];
    projects = const [];
    projectTasks = const [];
    activeProjectId = null;
    _taskCatalog.explicitProjectId = null;
    desktopAppVersion = null;
  }

  /// 测试面收尾（生产走 disposeStack）：ChangeNotifier.dispose 不携带
  /// 栈内清理——redrive 定时器不取消会在测试结束后继续触发 open。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _conversationRegistry.dispose();
    _workspaceController.cancelRedrive();
    super.dispose();
  }

  /// 退后台断连（阶段 3 第二段：默认档退后台约 90s 断开，回前台秒连）。
  /// 释放全部连接（relay/桥/si/会话订阅 + 缓存 flush），保留栈注册与
  /// 档案——resume（=start()）重建：缓存预渲 → relay → bootstrap → 桥。
  /// 与 demote 的区别：demote 只释放会话订阅（前台切电脑的降级保活），
  /// suspend 释放整条连接（app 退后台的省电断开）。
  ///
  /// D4（2026-10-26 断线批）：幂等 + 落地中追踪——回前台（resume/
  /// pokeOrResume）可能落在 _closeWorkspaceStack 的 await 窗口内，若不
  /// 等待落地就判定，会因 _client 尚未清空而误判"未悬挂"，栈被留在
  /// 悬挂态且无人再恢复（真机体感：回 app 后一直转圈连不上）。
  Future<void> suspend() {
    if (_disposed) return Future.value();
    return _suspendInFlight ??= _doSuspend().whenComplete(() {
      _suspendInFlight = null;
    });
  }

  Future<void> _doSuspend() async {
    _workspaceController.cancelRedrive();
    await _closeWorkspaceStack();
    _client?.relay.stateListenable.removeListener(_onRelayState);
    await _failureSub?.cancel();
    _failureSub = null;
    await _workspaceListSub?.cancel();
    _workspaceListSub = null;
    final client = _client;
    _client = null;
    await client?.dispose();
    _bootstrapStarted = false;
    _cacheSeeded = false;
    workspaces = const [];
    activeWorkspace = null;
    notifyListeners();
  }

  /// 恢复（suspend 后重连）。守卫与 start() 一致：已连接/已释放则跳过。
  Future<void> resume() async {
    if (_disposed || _client != null) return;
    await start();
  }

  /// 悬挂态（连接已断，栈仍在注册表等待回前台恢复）。
  bool get suspended => _client == null && !_disposed;

  /// 回前台探测（保活 v1）。
  void poke() => _client?.pokeRelay();

  /// 后台自适应心跳（电量专项）：审批提醒保活退后台时放宽心跳档。
  void setRelayBackgroundHeartbeat(bool enabled) =>
      _client?.setRelayBackgroundHeartbeat(enabled);

  /// 完全静默档（电量优化批 #17）：90s 断连倒计时窗口内不发心跳不看门狗。
  void setRelaySilent(bool silent) => _client?.setRelaySilent(silent);

  /// 机会项#1（2026-11-08）：workspace-create L2 直发（详见
  /// CompanionClient.createWorkspace）。
  Future<Map<String, dynamic>> createWorkspace(String name) async {
    final client = _client;
    if (client == null) throw StateError('stack not connected');
    return client.createWorkspace(name);
  }

  /// 回前台统一入口（D4）：悬挂中或悬挂落地中→恢复；已连接→poke。
  Future<void> pokeOrResume() async {
    final suspending = _suspendInFlight;
    if (suspending != null) await suspending;
    if (_disposed) return;
    if (suspended) {
      await resume();
      return;
    }
    poke();
  }
}
