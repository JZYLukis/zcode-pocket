import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../notify/notification_service.dart';
import '../transport/channel_client.dart';
import '../transport/companion_client.dart';
import '../transport/connection_params.dart';
import '../transport/conversation.dart';
import '../transport/relay_client.dart';
import '../transport/project_tree.dart';
import '../transport/relay_v2.dart';
import '../transport/z_transport.dart';
import 'account_store.dart';
import 'computer_stack.dart';
import 'draft_store.dart';
import 'device_stack_registry.dart';
import 'send_queue_store.dart';
import 'local_cache.dart';
import 'cache_policy.dart';
import 'link_phase.dart';
import 'battery_journal.dart';
import 'notify_coordinator.dart';
import 'notify_core.dart';
import 'notify_store.dart';
import 'profile_store.dart';
import 'task_list.dart';
import 'ui_prefs.dart';
import '../core/l10n.dart' show L10n, tr;

export 'link_phase.dart';
export 'session_errors.dart';
export '../transport/project_tree.dart' show workspaceKeyOf;

/// 连接编排（阶段 2 波次 3a 起多栈并行， 裁决落地）：
/// 每个档案一条完整连接栈（ComputerStack：relay 状态机 + workspace bridge +
/// v4 会话 + 任务列表）；**切换档案 = 换 UI 指针**（后台栈降级保活：
/// relay + sessions-index 维持，会话订阅释放）——阶段 3 的双电脑通知
/// 以此为地基。UI 仍只读 AppState 门面（getter 全部路由到活跃栈）。
class AppState extends ChangeNotifier {
  /// [cacheStore]/[notifyService] 测试缝：注入目录型存储/通知服务
  /// （生产 load() 时自动创建）。
  AppState({
    ProfileStore? store,
    LocalCacheStore? cacheStore,
    NotificationService? notifyService,
    NotifyStore? notifyStore,
    AccountStore? accountStore,
    this.draftStore,
  }) : store = store ?? ProfileStore(),
       accountStore = accountStore ?? AccountStore(),
       _injectedCache = cacheStore,
       _injectedNotifyService = notifyService,
       _injectedNotifyStore = notifyStore {
    // 注入的缓存存储立即对公开字段可见（load() 仍是 ??= 语义不变）：
    // 此前注入件要等 load() 才挂到 cacheStore，页面级轻量测试（如关于页
    // 清除缓存）注入后读不到。
    if (cacheStore != null) this.cacheStore = cacheStore;
    _deviceRegistry = DeviceStackRegistry(
      store: this.store,
      accountStore: this.accountStore,
      cacheProvider: () => this.cacheStore,
      notifyCoordinatorProvider: () => notifyCoordinator,
      phaseProvider: () => phase,
      onLog: _log,
      onNotify: notifyListeners,
      onStackChanged: _onStackChanged,
      onPersistProfile: _onStackProfilePersisted,
      onRemoveDeviceData: (sid) async {
        await Future.wait<void>([
          if (this.cacheStore != null) this.cacheStore!.removeDevice(sid),
          if (draftStore != null) draftStore!.removeDevice(sid),
          if (sendQueue != null) sendQueue!.removeDevice(sid),
        ]);
      },
    );
  }

  late final DeviceStackRegistry _deviceRegistry;

  final ProfileStore store;

  /// V2 账号凭据（；2026-10-25 多账号批起支持多账号并存，
  /// 档案按 accountId 绑定——详 ）。
  /// （实测无 exp，401=唯一失效信号——见 _onStackFailure auth-required）。
  final AccountStore accountStore;
  Future<bool> get hasAccount => accountStore.hasAccount;
  final LocalCacheStore? _injectedCache;
  final NotificationService? _injectedNotifyService;
  final NotifyStore? _injectedNotifyStore;

  /// 本地缓存存储（阶段 3：会话行缓存 + 设备级列表/桥缓存）。
  LocalCacheStore? cacheStore;

  /// 未发送输入草稿（电脑+账号+工作区+会话隔离）。
  DraftStore? draftStore;

  /// 断网消息排队（6.6②，2026-10-29 批次）：断连期发送入队+重连自动
  /// 发出；懒加载与草稿同款。
  SendQueueStore? sendQueue;

  /// 通知体系（阶段 3 第二段）：服务（安卓通道）+ 协调器（差分/台账）。
  NotificationService? notifyService;
  NotifyCoordinator? notifyCoordinator;
  NotifyStore? get notifyStore => notifyCoordinator?.store;
  final List<String> log = [];

  /// UI 偏好（工具显示开关等，设置页驱动）。
  final UiPrefs uiPrefs = UiPrefs();

  /// 测试自动化入口（app.dart 注入）：读 Android intent extra 的配对参数
  /// （am start --es pairing_url ...），模拟器回归免 UI 输入。生产注入的
  /// reader 本身不缺席（冷启动/持久化冒烟依赖 am start 配对）——release
  /// 由 [releaseSeamForTest]/[releasePairingHostAllowed] 的 闸门把关
  /// （origin 覆盖与凭据注入全拒、配对域白名单放行）。
  Future<Map<String, String?>?> Function()? testLaunchArgsReader;

  /// 正式包测试缝闸门（2026-10-25 审查）：release 构建不
  /// 接受 intent extra 注入的连接地址覆盖与账号凭据——MainActivity 为
  /// exported 启动入口，本机恶意应用可用显式启动参数把携带 Bearer 账号
  /// 令牌的中继请求引向自建服务器（账号令牌外发的唯一通路，静态调用链
  /// 实证；原生侧另有 debuggable 门作为第二道防线）。debug/profile 的
  /// 测试缝能力不变。测试经 [releaseSeamForTest] 在 debug 下模拟 release。
  @visibleForTesting
  static bool releaseSeamForTest = false;

  static bool get _seamBlocked => kReleaseMode || releaseSeamForTest;

  /// release 下配对链接仅放行官方中继域：release 冷启动/持久化验证依赖
  /// am start 配对，不能一刀切关闭注入；
  /// 非官方公网域一律拒绝（伪桌面对话内容外发面）。
  @visibleForTesting
  static bool releasePairingHostAllowed(String url) {
    final host = Uri.tryParse(url)?.host.toLowerCase();
    return host == 'zcode.z.ai' || host == 'localhost' || host == '127.0.0.1';
  }

  List<DeviceProfile> get profiles => _deviceRegistry.profiles;
  set profiles(List<DeviceProfile> value) => _deviceRegistry.profiles = value;
  DeviceProfile? get activeProfile => _deviceRegistry.activeProfile;
  set activeProfile(DeviceProfile? value) => _deviceRegistry.activeProfile = value;

  /// （2026-10-19 审查）：最近一次档案读取跳过的坏条目数（界面提示
  /// "N 个档案损坏"用；0=正常）。
  int get corruptedProfiles => _deviceRegistry.corruptedProfiles;
  set corruptedProfiles(int value) => _deviceRegistry.corruptedProfiles = value;

  /// 启动载入（档案读取）是否完成——未完成时 UI 显示启动页而非配对页，
  /// 避免有档案的老用户看到配对页闪现。
  bool loaded = false;

  /// 连接栈注册表（deviceSid → stack）。档案未激活过 = 无栈（离线休眠）。
  Map<String, ComputerStack> get _stacks => _deviceRegistry.stacks;
  String? get _activeSid => _deviceRegistry.activeSid;
  ComputerStack? get _active => _deviceRegistry.active;
  bool _disposed = false;

  // ----------------------------------------------------- 活跃栈门面（只读）

  LinkPhase get phase => _active?.computeStatus() ?? LinkPhase.offline;

  // ── 第一档连接诊断（2026-10-23 用户拍板）──────────────────────
  /// 最近一次 relay 失败（重试型网络失败/终态失败都会更新；UI 用
  /// relayDiagnosis 取人话文案）。getter 公开、写入走 updateRelayFailure
  /// （生产由 _onStackFailure 调、测试可注入）。
  String? get lastRelayFailReason => _deviceRegistry.lastRelayFailReason;
  String? get lastRelayFailMessage => _deviceRegistry.lastRelayFailMessage;
  DateTime? get lastRelayFailAt => _deviceRegistry.lastRelayFailAt;

  @visibleForTesting
  void updateRelayFailure(String? reason, String? message) =>
      _deviceRegistry.updateRelayFailure(reason, message);

  /// 重连中且有近期失败时给出人话诊断+可操作提示；否则 null（不渲染）。
  ({String title, String hint})? get relayDiagnosis =>
      _deviceRegistry.relayDiagnosis;

  String? get phaseDetail => _active?.computeStatusDetail();

  /// 换账号重连（多账号批 2026-10-25，device-not-owned 引导动作）：把
  /// 活跃 V2 档案改绑到最近使用账号（刚登录的那个）并重建栈——栈在
  /// 构造期闭包捕获账号 id，复用旧栈不会换凭据，必须重建。
  Future<void> retryActiveProfileWithNewAccount() =>
      _deviceRegistry.retryActiveProfileWithNewAccount();

  /// 删除账号的完整编排（真机反馈②；2026-11-03 对抗审查
  /// 调序）：**先删凭据再拆栈**——拆栈链上任一步抛异常都不该留下
  /// "账号已不在但凭据还在"的中间态；拆栈内部逐栈 try/catch（单栈
  /// 失败不阻断其余），并同步清该账号名下设备的缓存/草稿/排队数据
  /// （防下一账号连同一台电脑先闪上一账号的任务缓存）+ 活跃指针/
  /// 持久 sid 收尾（无其余账号则显式离线）。电脑档案按删除对话框
  /// 明示保留——重登后由 [reattachAfterAccountLogin] 接回。
  Future<void> removeAccount(String accountId) async {
    // legacy 档案（accountId==null）的凭据取 lastUsed——须在 removeAccount
    // 改写 lastUsed 前捕获，供拆栈侧判定（详 registry 注释）。
    final lastUsedBefore = await accountStore.lastUsedAccountId;
    await accountStore.removeAccount(accountId);
    try {
      await _deviceRegistry.disposeStacksForAccount(
        accountId,
        lastUsedBefore: lastUsedBefore,
      );
    } catch (e) {
      _log('dispose stacks for account failed (contained): $e');
    }
    notifyListeners();
    // 乙：绕过 _onStackChanged 的话常驻通知（审批提醒 FGS）不会
    // 刷新——拆完全部栈后仍显示"已连接 · N 个任务运行中"。补一次。
    _updateForegroundText();
  }

  /// 登录成功后的接回编排（反馈②：删号重登只写凭据不接回=永久
  /// 离线死态只能大退）。** ①实证修正**：旧版无条件把活跃档案改绑
  /// 到 lastUsed——"添加第二账号"会把 改绑成 B 并拆掉原账号连接
  /// （重连互踢循环），破坏多账号多电脑场景。新语义：
  /// ①活跃栈健在且其账号凭据仍在（添加账号/普通登录的常态）→**不动**；
  /// ②无活跃栈（删号拆栈后重登）→激活绑定最近账号的第一台可用档案。
  /// 改绑（换账号重连）只保留 device-not-owned 诊断按钮一条入口。
  Future<void> reattachAfterAccountLogin() async {
    final registry = _deviceRegistry;
    final active = registry.active;
    final activeProfile = registry.activeProfile;
    if (active != null) {
      if (activeProfile is AccountV2Profile) {
        final jwt = await accountStore.readJwtFor(activeProfile.accountId);
        if (jwt != null) return; // 活跃连接的账号凭据健在——新增账号不打扰
      }
      return; // 非 V2 档案（旧版直连）无账号语义，同样不动
    }
    // 批2 配套：重登录后 lastUsed 可能仍是旧账号——「刚登录的账号」
    // 取最近保存（列表首项），lastUsed 兜底。
    final recent = await accountStore.mostRecentAccountId;
    if (recent == null) return;
    DeviceProfile? candidate;
    for (final p in registry.profiles) {
      if (p is AccountV2Profile && !p.invalid && p.accountId == recent) {
        candidate = p;
        break;
      }
    }
    if (candidate != null) {
      try {
        await registry.activate(candidate);
      } catch (e) {
        _log('reattach activate failed (contained): $e');
      }
    }
  }

  List<Map<String, dynamic>> get workspaces => _active?.workspaces ?? const [];

  /// 项目全集（ 工作区列表修复）：侧栏数据源。空=未加载/桌面
  /// 不支持——UI 退回 workspaces（当前 tabs）渲染。
  List<Map<String, dynamic>> get projects => _active?.projects ?? const [];

  /// 侧栏条目缓存（状态层批）：任务主页 memo 以 record 逐字段比较输入，
  /// List 字段按 identity——每次 getter 现建新 List 会让缓存永不命中
  /// （si 活动帧期间每次重建全量重排）。判键=设备 sid+项目内容签名+
  /// 本地排序，不变时返回同一 List 实例。仅缓存一份（活跃电脑）。
  List<Map<String, dynamic>>? _sidebarProjectsCache;
  String? _sidebarProjectsCacheKey;

  /// 侧栏条目（官方同构「项目」+「任务」两区）：可见项目+未归类任务
  /// 存在时的「任务」伪项目（默认工作区入口）。应用本地排序偏好
  /// （2026-10-26 拍板③，官方 preferences.reorder 同语义不同步——按
  /// 活跃电脑分桶，uiPrefs 变更即时反映）。
  List<Map<String, dynamic>> get sidebarProjects {
    final sid = _activeSid;
    // sid==null 时 _active 必为 null（active getter 由 activeSid 查表而来）
    // ——恒空列表（//：原 `_active?.`
    // 分支是死代码，误导读者以为存在"无 sid 但有活跃栈"的状态）。
    if (sid == null) return const [];
    final entries = _active?.sidebarEntries() ?? const [];
    final order = uiPrefs.projectOrder(sid);
    final key = _sidebarSignature(sid, entries, order);
    final cached = _sidebarProjectsCache;
    if (cached != null && key == _sidebarProjectsCacheKey) return cached;
    final next = applyProjectOrder(entries, order);
    _sidebarProjectsCache = next;
    _sidebarProjectsCacheKey = key;
    return next;
  }

  static String _sidebarSignature(
    String sid,
    List<Map<String, dynamic>> entries,
    List<String>? order,
  ) {
    final buf = StringBuffer(sid)..write('#')..write(entries.length);
    for (final e in entries) {
      // 展示/点按依赖的浅字段足够识别内容变化（增删/改名/重排）。
      buf
        ..write('|')
        ..write(e['id'] ?? '')
        ..write('\u0001')
        ..write(e['name'] ?? '')
        ..write('\u0001')
        ..write(e['label'] ?? '');
    }
    if (order != null && order.isNotEmpty) {
      buf..write('#')..write(order.join('\u0001'));
    }
    return buf.toString();
  }

  /// 写入活跃电脑的项目顺序（真实项目 id 序；「任务」伪项目恒在尾）。
  Future<void> setProjectOrder(List<String> ids) async {
    final sid = _activeSid;
    if (sid == null) return;
    await uiPrefs.setProjectOrder(sid, ids);
    notifyListeners();
  }

  /// 当前选中项目 id（侧栏高亮；「任务」伪项目=id 常量）。
  String? get activeProjectId => _active?.activeProjectId;

  /// 跨工作区搜索数据源：workspace-list 全量任务（含非活跃工作区）。
  List<Map<String, dynamic>> get workspaceTasks =>
      _active?.workspaceTasks ?? const [];

  /// 2026-11-05 反馈②A：跨工作区打开失败时清保住的旧首页行。
  void clearStaleHomePreview() => _active?.clearStaleHomePreview();

  Map<String, dynamic>? get activeWorkspace => _active?.activeWorkspace;

  /// 草稿身份使用的账号与建栈凭据同口径；身份不明时返回 null，宁可
  /// 保持内存草稿也不写入可能属于另一账号的共享桶。
  Future<String?> activeDraftAccountId() async {
    final profile = activeProfile;
    if (profile is AccountV2Profile) {
      final bound = profile.accountId;
      if (bound != null) return bound;
      return accountStore.lastUsedAccountId;
    }
    if (profile is RelayProfile) return 'legacy';
    return null;
  }

  String? get desktopAppVersion => _active?.desktopAppVersion;

  bool get workspaceOpening => _active?.workspaceOpening ?? false;
  String? get workspaceError => _active?.workspaceError;

  SessionsIndexState? get sessionsIndex => _active?.sessionsIndex;
  TaskListModel? get taskList => _active?.taskList;

  /// 冷工作区降级态（si dormant）：任务中心据此提示。
  bool get siDormant => _active?.siDormant ?? false;

  /// task 级配置目录（模型/思考/模式——WR 手机目录真源）。
  Future<List<dynamic>> getTaskConfigOptions(String taskId) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.getTaskConfigOptions(taskId);
  }

  /// 官方 model-selection.getView（草稿目录真源，宿主级）。
  Future<Map<String, dynamic>?> modelSelectionView() async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.modelSelectionView();
  }

  Future<List<dynamic>> modelSelectionOptions() async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.modelSelectionOptions();
  }

  /// 工作区技能列表（官方 skills.list，composer 以 `$name` 触发——
  /// 桌面「添加」弹层 footer「$ 选择技能」的手机端等价物）。
  Future<List<SkillEntry>> listSkills() async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.skills();
  }

  /// 速赢#3：从此行分支（forkAssistant）。
  Future<dynamic> forkAssistant(
    String sessionId,
    Map<String, dynamic> target,
  ) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.forkAssistant(sessionId, target);
  }

  /// 速赢#2：排队项编辑。
  Future<dynamic> editQueueItem(
    String sessionId,
    String queueItemId,
    String newText,
  ) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.editQueueItem(sessionId, queueItemId, newText);
  }

  /// 速赢#2：排队自动排空开关。
  Future<dynamic> setAutoDrain(String sessionId, bool autoDrain) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.setAutoDrain(sessionId, autoDrain);
  }

  /// 速赢#1：压缩上下文（compact）。
  Future<dynamic> compact(String sessionId) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.compact(sessionId);
  }

  /// 重命名任务（列表刷新）。
  Future<dynamic> renameTask(String taskId, String title) async {
    final stack = _active;
    if (stack == null) throw StateError('no active computer');
    final res = await stack.renameTask(taskId, title);
    stack.reloadTaskIndex();
    return res;
  }

  /// 标为未读/已读（列表刷新）。
  Future<dynamic> markTaskUnread(String taskId, {required bool unread}) async {
    final stack = _active;
    if (stack == null) throw StateError('no active computer');
    final res = await stack.markTaskUnread(taskId, unread: unread);
    stack.reloadTaskIndex();
    return res;
  }

  ConversationTransport? get conversation => _active?.conversation;
  BridgeSession? get bridge => _active?.bridge;

  /// 测试/调试：已订阅会话的状态对象（integration_test 断言订阅复用/行数）。
  Map<String, ConversationState> get conversationStates =>
      _active?.conversationStates ?? const {};

  /// 兜底（2026-10-16 夜）：ensure 链偶发 wedge 时页面直捞活订阅。
  ConversationSubscription? conversationSubscriptionOf(String sessionId) =>
      _active?.subscriptionOf(sessionId);

  /// 会话行缓存读取（阶段 3 首帧预渲入口：页面打开会话时先渲缓存，
  /// 订阅/快照流程照常走——缓存不阻塞、不替代网络路径）。
  Future<SessionCacheEntry?> readSessionCache(String sessionId) async {
    final stack = _active;
    if (stack == null) return null;
    return stack.readSessionCache(sessionId);
  }

  /// 档案面板：某台电脑的实时状态（无栈=休眠离线）。
  /// 委托 Registry（唯一实现——独立复核低 2：门面自留一份派生读会分叉）。
  LinkPhase statusOf(DeviceProfile profile) =>
      _deviceRegistry.statusOf(profile);

  /// 三轮审查 ：经虚 getter 读（HEAD 同款）——子类测试用字段覆写
  /// profiles 时，profileOf 与覆写值一致；Registry 内部实现只服务自身
  /// activate 路径，两份读法不串台。
  DeviceProfile? profileOf(String deviceSid) =>
      profiles.where((p) => p.deviceSid == deviceSid).firstOrNull;

  void _log(String line) {
    log.add(line);
    if (log.length > 500) log.removeRange(0, log.length - 500);
    debugPrint('[app] $line');
  }

  void _onStackChanged() {
    if (_disposed) return;
    // 活跃栈变化驱动全局状态；后台栈变化也要通知（档案面板状态点）。
    final active = _active;
    if (active != null) {
      activeProfile = active.profile;
    }
    // 顶栏账号名缓存此前只在 AppState.activate 后刷新——
    // registry 内部自动 activate（removeComputer 换机/删号收尾/换账号
    // 重连）全不经过它。栈变化是活跃档案翻转的统一汇合点，在这里按
    // sid 变化检测刷新（refreshActiveAccountLabel 幂等：sid 未变直返）。
    refreshActiveAccountLabel();
    notifyListeners();
    _updateForegroundText();
  }

  // ------------------------------------------------------ 电量日志（第三段后补）

  /// 包内常驻电量统计（无 UI，只落 battery-journal.jsonl；见
  /// lib/state/battery_journal.dart 头注释与 ）。
  BatteryJournal? batteryJournal;

  /// 测试/排障读数：已落盘行数。
  int get batteryJournalLines => batteryJournal?.seq ?? 0;

  // ------------------------------------------------------ 通知（阶段 3 二段）

  /// 通知体系装配（生产：flutter_local_notifications + 应用目录存储；
  /// 测试：注入 Fake 后端 / 内存存储）。初始化失败=通知禁用，主流程
  /// 照常（事件仍进台账，outcome=noChannel——零漏发核对仍有证据）。
  Future<void> _initNotify() async {
    if (notifyService != null) return;
    final service = _injectedNotifyService;
    if (service == null) {
      // 纯测试环境（无平台通道）不构造生产后端。
      if (kDebugMode && _injectedNotifyStore != null) return;
      final backend = FlutterLocalNotificationsBackend();
      final created = NotificationService(backend: backend);
      // init 整体容错：init 内部的 setTapHandler/
      // launchPayload 平台通道异常（插件缺失/异构设备）此前会炸穿
      // load()——loaded 永假、UI 停在启动态，与"失败=通知禁用"承诺
      // 相悖。失败置 null（无通知服务，onTap 无处可挂）。
      try {
        await created.init();
      } catch (e) {
        _log('notify service init failed (contained): $e');
        return;
      }
      notifyService = created;
    } else {
      notifyService = service;
    }
    // 通知点击回调不依赖台账：存储降级环境（store
    // 创建失败）下 onTap 也要挂上——否则该次会话所有通知点击（含冷启
    // 动点击直达）失效，只剩无导航的通知。
    notifyService!.onTap = (payload) => openTaskFromNotification(
          payload.deviceSid,
          payload.taskId,
          atMs: payload.atMs,
        );
    // 冷启动点击路由推迟（状态层批）：此处 profiles 尚未加载，
    // profileOf 恒空——此前直接走打开链既不会激活目标电脑（多电脑场景
    // 永远停在错误电脑上），markClicked 也因协调器未建而静默丢失。
    // 改为暂存，load() 末尾（profiles/协调器就绪）统一消费。
    _pendingLaunchPayload = notifyService!.consumePendingLaunch();
    final store =
        _injectedNotifyStore ??
        (await (() async {
          try {
            return await NotifyStore.createDefault();
          } catch (e) {
            _log('notify store unavailable (contained): $e');
            return null;
          }
        })());
    if (store == null) return;
    await store.load();
    notifyCoordinator = NotifyCoordinator(
      store: store,
      onPost: (event) async {
        final svc = notifyService;
        if (svc == null) return false;
        return svc.post(event, deviceLabel: deviceLabelOf(event.deviceSid));
      },
      shouldSuppress: isTaskBeingViewed,
    );
    final coordinator = notifyCoordinator!;
    coordinator.onSnapshotActive = () =>
        notifyService?.activeNotificationIds() ?? const <int>{};
    coordinator.onClearStale = (pending, staleIds) async {
      await notifyService?.clearStale(
        stillPendingTaskIds: pending,
        limitToIds: staleIds,
      );
    };
    _syncNotifyPrefs();
  }

  /// 冷启动快捷入口（6.6①）：launchArgs 带入的动作挂起，任务中心消费。
  /// 在 notify 挂好后的 load 收尾调用（与通知 payload 同一时点）。
  void _consumeShortcutFromLaunch(Map<String, String?>? launchArgs) {
    final action = normalizeShortcutAction(launchArgs?['shortcut_action']);
    if (action != null) pendingShortcutAction = action;
  }

  String deviceLabelOf(String deviceSid) =>
      _deviceRegistry.deviceLabelOf(deviceSid);

  /// UiPrefs → 协调器静音矩阵同步（开关切换即生效）。
  void _syncNotifyPrefs() {
    final coordinator = notifyCoordinator;
    if (coordinator == null) return;
    coordinator.mutedChannels = {
      if (uiPrefs.muteApprovals) NotifyChannel.approvals,
      if (uiPrefs.muteTasks) NotifyChannel.tasks,
      if (uiPrefs.muteGoals) NotifyChannel.goals,
    };
    // 原此处调用空实现钩子 _fgRequestRestart（"保留
    // 给未来文本语义变化"）——静音集合走 update 通道即可，钩子删除。
  }

  /// 通知点击直达：激活对应电脑 + 打开该任务会话（TaskCenterPage 消费
  /// pendingOpenTask 导航）。栈未就绪时等恢复后导航。
  void openTaskFromNotification(String deviceSid, String taskId,
      {int atMs = 0}) {
    final profile = profileOf(deviceSid);
    final reachable = profile != null && !profile.invalid;
    if (reachable && _activeSid != deviceSid) {
      // 错误 containment（对齐 reattachAfterAccountLogin
      // 同场景）：activate 若抛（demote 链异常）此前成为未处理异步错误。
      unawaited(
        activate(profile).then((_) {}, onError: (Object e) {
          _log('notify activate failed (contained): $e');
        }),
      );
    }
    // 批3（multi-account-ux-1）：通知来自另一台电脑时短暂提示「已切换
    // 到 {电脑名}」——隐式 activate 不能让用户以为还在这台电脑上。
    final prevSid = activeProfile?.deviceSid;
    if (reachable && prevSid != null && prevSid != deviceSid) {
      final label = profileOf(deviceSid)?.label ?? '另一台电脑';
      _switchNotice = '已切换到 $label';
      // 一次性定时消费（4s）——不可在 build 里排程（每次重建都会新排
      // 一个回调 → 重建循环/测试挂起）。
      _switchNoticeTimer?.cancel();
      _switchNoticeTimer = Timer(const Duration(seconds: 4), () {
        if (_disposed) return;
        consumeSwitchNotice();
      });
    }
    pendingOpenTask = (deviceSid: deviceSid, taskId: taskId);
    // 两步式深链（2026-11-04 拍板）：会话打开后由页面弹短暂浮层询问
    // 是否定位到产生该通知的消息（atMs>0 才提示；无时间戳的老 payload
    // 维持「仅打开会话」）。
    // atMs<=0（老 payload）=清残留——旧值若不清会被下一次通知
    // 误配对（对抗审查中·陈旧 atMs 跨会话误弹）；有值时记归属 taskId。
    // 状态层批：目标电脑不可达（档案已删/失效）时同样清位——不能把
    // 深链提示留给之后打开的任意会话（失败收口）。
    if (atMs > 0 && reachable) {
      pendingDeepLinkAt = atMs;
      pendingDeepLinkTaskId = taskId;
    } else {
      pendingDeepLinkAt = null;
      pendingDeepLinkTaskId = null;
    }
    notifyListeners();
    unawaited(
      notifyStore?.markClicked(taskId, DateTime.now().millisecondsSinceEpoch),
    );
    _log('[notify] open task from notification: $taskId');
  }

  /// 清空待消费的两步式深链（含归属字段；幂等）。任务中心打开失败/
  /// 跨电脑不可达时调用，防残留值被下一次会话误配对。
  void clearPendingDeepLink() {
    if (pendingDeepLinkAt == null && pendingDeepLinkTaskId == null) return;
    pendingDeepLinkAt = null;
    pendingDeepLinkTaskId = null;
    notifyListeners();
  }

  /// 待导航任务（通知点击/冷启动 payload）——任务中心消费后清空。
  ({String deviceSid, String taskId})? pendingOpenTask;

  /// 冷启动通知 payload 暂存（_initNotify 取走、load() 末尾消费——那时
  /// profiles 与通知协调器均已就绪）。
  NotifyTapPayload? _pendingLaunchPayload;

  /// 两步式深链的目标时刻（通知产生时间）：会话页消费后清空——页面
  /// 据此弹「定位到相关消息？」浮层并滚动。
  /// （对抗审查中·陈旧残留）：配对目标 taskId——捕获方与消费方都
  /// 校验归属，防旧通知残留值被下一次 atMs==0 通知误配对给错会话。
  int? pendingDeepLinkAt;

  /// pendingDeepLinkAt 的归属会话（与 pendingOpenTask 同源设置）。
  String? pendingDeepLinkTaskId;

  /// 深链目标的会话归属（+）：归属不再依赖 pendingOpenTask
  ///（任务中心 build 早已清空它，全局 getter 恒 null=浮层永不弹的根因
  /// 之一）——pendingDeepLinkTaskId 与 at 同源设置，消费校验归属。
  ({String taskId, int atMs})? get pendingDeepLinkTarget {
    final at = pendingDeepLinkAt;
    final task = pendingDeepLinkTaskId;
    if (at == null || task == null || task.isEmpty) return null;
    return (taskId: task, atMs: at);
  }

  /// 跨电脑切换提示（批3）：任务中心横幅短暂显示后清空（见 consume）。
  String? _switchNotice;
  Timer? _switchNoticeTimer;
  String? get switchNotice => _switchNotice;
  void consumeSwitchNotice() {
    _switchNoticeTimer?.cancel();
    _switchNoticeTimer = null;
    if (_switchNotice == null) return;
    _switchNotice = null;
    notifyListeners();
  }

  /// 长按图标快捷入口（6.6①）：'new_task'（新建任务弹层）/
  /// 'last_session'（最近更新的会话）——任务中心消费后清空；冷启动随
  /// launchArgs 进来，热启动由原生→Dart 推送 [handleShortcutAction]。
  String? pendingShortcutAction;

  /// 快捷入口动作归一（纯函数供测试）：非法值返回 null 不建挂起。
  static String? normalizeShortcutAction(String? raw) {
    final action = raw?.trim();
    return action == 'new_task' || action == 'last_session' ? action : null;
  }

  void handleShortcutAction(String action) {
    final normalized = normalizeShortcutAction(action);
    if (normalized == null) return;
    pendingShortcutAction = normalized;
    notifyListeners();
  }

  /// 活跃电脑所属账号的显示名（multi-account-ux-1 批1）：备注名优先，
  /// 未设置回退短码；凭据已删→"账号已删除"；无账号维度→null（顶栏
  /// 只显示电脑名）。异步从 AccountStore 取，缓存于 [_accountLabelCache]。
  String? get activeAccountLabel => _accountLabelCache;

  String? _accountLabelCache;

  /// 缓存判键（sid + accountId）：同键且不在飞时零成本短路，避免每个
  /// 栈变化都去读一次安全存储。
  String? _accountLabelKey;
  bool _accountLabelLoading = false;

  /// 异步回调代际（状态层批）：连续切换电脑/账号时，先发的慢查询不得
  /// 覆盖后发的标签。
  int _accountLabelGeneration = 0;

  /// 刷新活跃账号显示名（activate/账号变更后调用；幂等）。
  /// [force]：设置页改名后强制重读（同键也刷新）。
  void refreshActiveAccountLabel({bool force = false}) {
    final profile = activeProfile;
    final accountId =
        profile is AccountV2Profile ? profile.accountId : null;
    if (accountId == null) {
      _accountLabelKey = null;
      _accountLabelLoading = false;
      _accountLabelGeneration++;
      if (_accountLabelCache != null) {
        _accountLabelCache = null;
        notifyListeners();
      }
      return;
    }
    final key = '${profile?.deviceSid}#$accountId';
    if (!force && key == _accountLabelKey && !_accountLabelLoading) return;
    _accountLabelKey = key;
    final generation = ++_accountLabelGeneration;
    _accountLabelLoading = true;
    unawaited(() async {
      String? label;
      try {
        final accounts = await accountStore.listAccounts();
        final match = accounts.where((a) => a.id == accountId).firstOrNull;
        label = match?.displayName ?? (accounts.isEmpty ? null : '账号已删除');
      } catch (_) {
        label = null;
      }
      if (_disposed || generation != _accountLabelGeneration) return;
      _accountLabelLoading = false;
      if (_accountLabelCache != label) {
        _accountLabelCache = label;
        notifyListeners();
      }
    }());
  }

  /// 正在查看的会话（ConversationPage 维护）：该任务的事件不发通知
  /// ——用户看得见界面，通知是噪音（台账记 viewing 留证据）。
  String? viewingSessionId;

  /// app 是否在后台（onAppPaused/onAppResumed 维护）——后台时
  /// "查看中抑制"不生效（用户并没有在看）。
  bool _appInBackground = false;

  bool isTaskBeingViewed(String taskId) =>
      !_appInBackground && viewingSessionId == taskId;

  Future<void> _onStackProfilePersisted(DeviceProfile profile) async {
    await store.updateProfile(profile);
    await _reloadProfiles();
  }

  // ------------------------------------------------------------ lifecycle

  /// 启动：载入档案，恢复上次活跃的电脑并连接。
  /// 存储读取失败（插件缺失/数据损坏）降级为空档案列表，不阻塞启动。
  Future<void> load() async {
    await uiPrefs.load();
    if (draftStore == null) {
      try {
        draftStore = await DraftStore.createDefault();
      } catch (e) {
        _log('draft store unavailable (contained): $e');
      }
    }
    if (sendQueue == null) {
      try {
        sendQueue = await SendQueueStore.createDefault();
      } catch (e) {
        _log('send queue unavailable (contained): $e');
      }
    }
    cacheStore ??= _injectedCache;
    if (cacheStore == null) {
      // 平台通道不可用（纯测试）时降级为无缓存——缓存永远不阻塞主流程。
      try {
        cacheStore = await LocalCacheStore.createDefault();
      } catch (e) {
        _log('local cache unavailable (contained): $e');
      }
    }
    await _initNotify();
    // 电量日志：失败只记一行（绝不让统计功能影响主流程）。
    try {
      final journal = BatteryJournal(onLog: _log);
      await journal.start(
        connProvider: () =>
            phase == LinkPhase.online || phase == LinkPhase.reconnecting
            ? 'conn'
            : 'disc',
        fgServiceProvider: () => uiPrefs.alertsEnabled,
        runningTurnsProvider: () =>
            conversationStates.values.where((s) => s.isRunning).length,
      );
      batteryJournal = journal;
    } catch (e) {
      _log('battery journal unavailable (contained): $e');
    }
    uiPrefs.addListener(_syncNotifyPrefs);
    // 重启后恢复"审批提醒"前台服务（开关持久化，服务不随进程存活）。
    // 启动失败与手动开关同款回弹——此前开关显示开但
    // FGS 不在，整夜通知丢失且无任何重试/提示。
    if (uiPrefs.alertsEnabled) {
      final started = await _fgStart();
      if (!started) {
        await uiPrefs.setAlertsEnabled(false);
        _log('[notify] startup FGS failed - alerts reverted to off');
      }
    }
    try {
      final r = await store.listProfilesDetailed();
      profiles = r.profiles;
      corruptedProfiles = r.skipped;
    } catch (e) {
      _log('profile store read failed: $e');
      profiles = const [];
      corruptedProfiles = 0;
    }
    // 多账号迁移（2026-10-25，multi-account-plan）：存量 V2 档案无
    // accountId——恰有一个账号时全部绑到它（旧模型只有全局单账号，历史
    // 档案必属该账号）。多账号/零账号时留空=连接退最近使用。
    try {
      final accounts = await accountStore.listAccounts();
      if (accounts.length == 1) {
        final sole = accounts.first.id;
        var changed = false;
        for (final p in profiles) {
          if (p is AccountV2Profile && p.accountId == null) {
            await store.updateProfile(p.copyWith(accountId: sole));
            changed = true;
          }
        }
        if (changed) {
          final r = await store.listProfilesDetailed();
          profiles = r.profiles;
          corruptedProfiles = r.skipped;
        }
      }
    } catch (e) {
      _log('account bind migration failed (contained): $e');
    }
    loaded = true;
    // 自动化配对（intent extra 优先于档案恢复）
    final launchArgs = await testLaunchArgsReader?.call();
    _consumeShortcutFromLaunch(launchArgs);
    // V2 测试缝：origin 覆盖（连本机 Dart fake relay）+
    // 账号凭据注入（人工登录一次取出 JWT 后 --es account_jwt 注入，
    // E2E/冒烟免 OAuth——官方 fake-relay-v2 测试 JWT 同款范式）。
    // release 构建全部忽略（闸门，见 testLaunchArgsReader 注释）。
    final seamBlocked = _seamBlocked;
    final originOverride = launchArgs?['relay_v2_origin'];
    if (originOverride != null && originOverride.isNotEmpty) {
      if (seamBlocked) {
        _log('relay v2 origin override ignored (release seam gate)');
      } else {
        relayV2EndpointOverride = originOverride;
        _log('relay v2 origin override: $originOverride');
      }
    }
    final seedJwt = launchArgs?['account_jwt'];
    if (seedJwt != null &&
        seedJwt.isNotEmpty &&
        !seamBlocked &&
        !await accountStore.hasAccount) {
      await accountStore.save(jwt: seedJwt, provider: 'injected');
      _log('account jwt seeded (${seedJwt.length} chars)');
    }
    final testUrl = launchArgs?['url'];
    if (testUrl != null && testUrl.isNotEmpty) {
      final gateRejected = seamBlocked && !releasePairingHostAllowed(testUrl);
      if (gateRejected) {
        _log(
          'test pairing ignored (release seam gate): '
          'host not on allowlist',
        );
      } else {
        _log('test pairing via intent extra');
        try {
          await addComputer(testUrl, label: launchArgs?['name']);
          return;
        } catch (e) {
          _log('test pairing failed: $e');
        }
      }
    }
    final activeSid = await store.activeDeviceSid();
    var profile = activeSid == null ? null : profileOf(activeSid);
    // 兜底：活跃档案丢失/被删时取第一个可用档案（而非停在离线态）
    profile ??= profiles.where((p) => !p.invalid).firstOrNull;
    _log(
      'loaded ${profiles.length} profile(s), '
      'active=${profile?.label ?? 'unnamed'}',
    );
    notifyListeners();
    if (profile != null) {
      await activate(profile);
    }
    // 冷启动通知最后消费（状态层批）：profiles/通知协调器就绪后——目标
    // 电脑有可用档案先激活，再走既有打开链；markClicked 可写台账。
    await _flushPendingLaunch();
  }

  /// 冷启动通知点击路由（load 末尾调用）。档案不可达也走打开链——
  /// TaskCenter 会给出「该任务属于另一台电脑/不可达」的人话提示，并清
  /// 深链残留。
  Future<void> _flushPendingLaunch() async {
    final payload = _pendingLaunchPayload;
    _pendingLaunchPayload = null;
    if (payload == null) return;
    final profile = profileOf(payload.deviceSid);
    if (profile != null &&
        !profile.invalid &&
        _activeSid != payload.deviceSid) {
      try {
        await activate(profile);
      } catch (e) {
        _log('pending launch activate failed (contained): $e');
      }
    }
    openTaskFromNotification(
      payload.deviceSid,
      payload.taskId,
      atMs: payload.atMs,
    );
  }

  /// 添加（或重扫替换）一台电脑并立即激活。
  Future<void> addComputer(String rawUrl, {String? label}) =>
      _deviceRegistry.addComputer(rawUrl, label: label);

  /// 添加 V2 账号档案（登录后设备列表选定/二维码 V2 直连）并立即激活。
  /// sid 是档案唯一键——桌面重装/重注册换 sid = 新档案（官方语义）。
  /// [accountId]：配对目标账号（多账号批 2026-10-25；null=最近使用）。
  Future<void> addV2Profile(
    CompanionV2Params params, {
    String? label,
    String? accountId,
    bool forceRebind = false,
  }) => _deviceRegistry.addV2Profile(
        params,
        label: label,
        accountId: accountId,
        forceRebind: forceRebind,
      );

  Future<void> renameComputer(DeviceProfile profile, String label) =>
      _deviceRegistry.renameComputer(profile, label);

  Future<void> removeComputer(DeviceProfile profile) =>
      _deviceRegistry.removeComputer(profile);

  Future<void> _reloadProfiles() => _deviceRegistry.reloadProfiles();

  // ------------------------------------------------------------- activate

  /// 激活一个档案：已有栈 → 换 UI 指针（秒切，后台栈降级保活）；
  /// 无栈（休眠/新档案）→ 建栈连接。不再拆除其他电脑的连接。
  Future<void> activate(DeviceProfile profile) async {
    await _deviceRegistry.activate(profile);
    refreshActiveAccountLabel();
  }

  /// 测试缝：直驱失败处理（多账号收窄红绿——绕开真实栈连接时序）。
  @visibleForTesting
  Future<void> debugStackFailure(ComputerStack stack, RelayFailure f) =>
      _deviceRegistry.debugStackFailure(stack, f);

  /// 测试缝：往连接栈注册表注入离线构造的栈（backlog 36 红绿——
  /// activate 回捞路径需要已注册栈但不发起真实连接）。生产禁止调用。
  @visibleForTesting
  void debugRegisterStackForTest(ComputerStack stack) =>
      _deviceRegistry.debugRegisterStackForTest(stack);

  /// 测试缝（backlog 36）：读某栈的失败记录 / 把记录时间拨旧（验时效窗）。
  @visibleForTesting
  ({String reason, String? message, DateTime at})? debugFailureRecordForTest(
    String sid,
  ) => _deviceRegistry.debugFailureRecordForTest(sid);

  @visibleForTesting
  void debugAgeStackFailureForTest(String sid, Duration age) =>
      _deviceRegistry.debugAgeStackFailureForTest(sid, age);

  // ------------------------------------------------------------ workspace

  Future<void> switchWorkspace(
    Map<String, dynamic> workspace, {
    bool keepHomePreview = false,
  }) async => _active?.switchWorkspace(workspace, keepHomePreview: keepHomePreview);

  /// 切换项目（：project intent 桥——项目全集不再受"当前窗口
  /// tabs"限制）。
  Future<void> switchToProject(
    Map<String, dynamic> project, {
    bool keepHomePreview = false,
  }) async => _active?.switchToProject(project, keepHomePreview: keepHomePreview);

  /// 「任务」伪项目就地选中（2026-10-25 问题③：chip 点按与其他工作区
  /// 一致——主列表就地切未归类聚合，不再推独立页；不关桥）。
  void switchToConversations() => _active?.switchToConversations();

  /// relay 已连但工作区未恢复（2026-10-26 断线批）——横幅此态下
  /// 不再说"连接恢复中"，改说正在恢复工作区。
  bool get workspaceRestoring => _active?.workspaceRestoring ?? false;

  /// 手动重试工作区打开：重放原打开意图（含 project/task intent），
  /// 优于对占位 activeWorkspace 裸重开。
  Future<void> retryWorkspaceOpen() async => _active?.retryWorkspaceOpen();

  /// 未归类任务全集（updatedAt 降序）——「任务」列表页数据源
  /// （官方桌面"任务"区同构：默认工作区历史跨目录聚合）。
  List<Map<String, dynamic>> get unclassifiedTasks =>
      _active?.unclassifiedTasks() ?? const [];

  /// readTree 任务行全集（移动归属 UI 用：按 taskId 反查 workspacePath/
  /// 归属等字段——TaskCardData 不带目录信息）。
  List<Map<String, dynamic>> get projectTasks =>
      _active?.projectTasks ?? const [];

  /// readTree 加载状态（2026-10-25 批①）：内联任务视图三态判据。
  String get readTreeStatus => _active?.readTreeStatus ?? 'loading';

  /// 任务移动归属：成功后 readTree 已重拉
  /// （归属消费面全靠它）；`project.root-confirmation-required` 异常
  /// 原样抛给调用方做二段确认（addMissingRoot 重发）。
  Future<void> moveTask(
    Map<String, dynamic> task,
    String projectId, {
    bool addMissingRoot = false,
  }) async {
    final stack = _active;
    if (stack == null) throw StateError('no active computer');
    await stack.moveTask(task, projectId, addMissingRoot: addMissingRoot);
    // 任务索引三列表（当前工作区视图）与项目树同步刷新。
    stack.reloadTaskIndex();
  }

  /// 任务 intent 开桥（跨项目任务打开的通用兜底——任意任务可达）。
  Future<void> switchToTask(
    Map<String, dynamic> task, {
    String? label,
    bool keepHomePreview = false,
  }) async =>
      _active?.switchToTask(task, label: label, keepHomePreview: keepHomePreview);

  /// git 通道调用缝（阶段 6.2 选分支）：默认走活跃桥的 ChannelClient
  /// （多电脑栈隔离=天然只打活跃电脑；契约 refs services/git/git.ts，
  /// 通道放行已由 tools/git-channel-probe.mjs 实证）。测试覆写注夹具。
  Future<dynamic> gitChannelCall(String method, List<Object?> args) async {
    final b = bridge;
    if (b == null) throw StateError('未连接电脑');
    return b.channels.call(Channels.git, method, args);
  }

  /// 按 workspace 键取所属项目（跨项目任务打开用；null=不属于已知项目）。
  Map<String, dynamic>? projectForKey(String key) =>
      _active?.projectForKey(key);

  /// 会话子代理列表（批④拍板⑥；离线/无栈返回 null 由 UI 出错误态）。
  Future<Map<String, dynamic>?> sessionSubagents(
    String sessionId, {
    String? endedCursor,
    int endedLimit = 20,
  }) async {
    final stack = _active;
    if (stack == null) return null;
    return stack.sessionSubagents(
      sessionId,
      endedCursor: endedCursor,
      endedLimit: endedLimit,
    );
  }

  Future<void> refreshWorkspaces() async =>
      unawaited(_active?.refreshWorkspaces());

  // ------------------------------------------------- 任务管理（波次 3a）

  TaskListModel? get _activeTaskList => _active?.taskList;

  Future<dynamic> setTaskPinned(String taskId, bool pinned) async {
    final stack = _active;
    if (stack == null) throw StateError('no active computer');
    final taskList = _activeTaskList;
    // 幂等置位（状态层批）：重复提交同一目标值不再翻转成相反态。
    taskList?.setPinLocally(taskId, pinned);
    try {
      final res = await stack.setTaskPinned(taskId, pinned);
      // 竞态修复（gapfix-reg 实测）：pin RPC 在途时到达的通道列表可能
      // 带过时 pinnedIds，把乐观置顶回滚——成功后重拉权威三列表。
      stack.reloadTaskIndex();
      return res;
    } catch (e) {
      // RPC 失败回滚乐观置顶：先翻集合而重拉在校正
      // 前被跳过——不回滚则本地置顶态与桌面相反，滞留到下一次无关重拉。
      taskList?.setPinLocally(taskId, !pinned);
      rethrow;
    }
  }

  /// followupMode 用户事实源变更（设置页调用）：偏好落盘 + 对全部活跃
  /// 会话订阅补发 setFollowupMode（官方 SessionPane.tsx:4173-4190 收敛
  /// 语义——设置是事实源，v4 投影只是同步结果）。失败静默（会话切换后
  /// 新订阅随 createSession config 收敛）。
  Future<void> changeFollowupMode(String mode) async {
    await uiPrefs.setFollowupMode(mode);
    final conv = conversation;
    if (conv == null) return;
    for (final sessionId in conversationStates.keys.toList()) {
      try {
        await conv.setFollowupMode(sessionId, mode);
      } catch (_) {}
    }
  }

  List<Map<String, dynamic>> get archivedTasks =>
      _active?.archivedTasks ?? const [];

  /// 重拉任务索引三列表（归档区/任务列表刷新入口）。
  void reloadTaskIndex() => _active?.reloadTaskIndex();

  Future<dynamic> deleteArchivedTask(String taskId) async {
    final stack = _active;
    if (stack == null) throw StateError('no active computer');
    final res = await stack.deleteArchivedTask(taskId);
    await draftStore?.removeSession(stack.profile.deviceSid, taskId);
    await sendQueue?.removeSession(stack.profile.deviceSid, taskId);
    stack.reloadTaskIndex();
    return res;
  }

  Future<dynamic> deleteArchivedTasks(List<String> taskIds) async {
    final stack = _active;
    if (stack == null) throw StateError('no active computer');
    final res = await stack.deleteArchivedTasks(taskIds);
    // 只清真正删掉的（官方三分=deleted/skipped/failed，每个目标
    // 恰归一类）——优先按 deletedTaskIds 正向求交；缺失时回退
    // requested - skipped - failed（旧减法把 failed（删除失败、任务
    // 仍在）也当删除 → 误清仍存在任务的草稿/排队）。
    final resMap = res is Map ? res : null;
    Set<String> readSet(String key) => resMap != null && resMap[key] is List
        ? (resMap[key] as List).map((e) => '$e').toSet()
        : const <String>{};
    final deleted = readSet('deletedTaskIds');
    final removed = deleted.isNotEmpty
        ? [for (final taskId in taskIds) if (deleted.contains(taskId)) taskId]
        : [
            for (final taskId in taskIds)
              if (!readSet('skippedTaskIds').contains(taskId) &&
                  !readSet('failedTaskIds').contains(taskId)) taskId,
          ];
    // 批量清理并行化：逐条串行 await 双 store=2N 次
    // 串行 IO（批量 50 即 100 次）；各 removeSession 操作不同会话键，
    // Future.wait 并行安全（两 store 内部均为内存变更+合并防抖落盘）。
    final sid = stack.profile.deviceSid;
    await Future.wait<void>([
      for (final taskId in removed) ...[
        if (draftStore != null) draftStore!.removeSession(sid, taskId),
        if (sendQueue != null) sendQueue!.removeSession(sid, taskId),
      ],
    ]);
    stack.reloadTaskIndex();
    return res;
  }

  Future<dynamic> archiveTask(String taskId) async {
    final stack = _active;
    if (stack == null) throw StateError('no active computer');
    final taskList = _activeTaskList;
    taskList?.markRemovedLocally(taskId);
    try {
      final res = await stack.archiveTask(taskId);
      // 归档联动清理（:30"删除任务/归档任务/电脑
      // 时清理对应草稿"）：对齐 deleteTask——不清理则断网排队中的消息会在
      // 重连后被 drain 自动发给已归档会话。
      await draftStore?.removeSession(stack.profile.deviceSid, taskId);
      await sendQueue?.removeSession(stack.profile.deviceSid, taskId);
      return res;
    } catch (e) {
      // RPC 失败清墓碑（状态层批）：不回滚则卡片要等 60s 过期才回来。
      taskList?.clearRemovedLocally(taskId);
      rethrow;
    }
  }

  Future<dynamic> unarchiveTask(String taskId) async {
    final stack = _active;
    if (stack == null) throw StateError('no active computer');
    final res = await stack.unarchiveTask(taskId);
    // 恢复成功后清本地墓碑（此前归档→撤销的卡片要等 60s 过期才可见）。
    _activeTaskList?.clearRemovedLocally(taskId);
    return res;
  }

  /// 任务全文搜索（标题 + 对话正文，官方 listTaskList）。未连接或搜索
  /// 失败返回 null——UI 退化为本地标题/预览过滤。
  Future<List<Map<String, dynamic>>?> searchTasks(String query) async {
    final stack = _active;
    if (stack == null) return null;
    return stack.searchTaskList(query);
  }

  Future<dynamic> deleteTask(String taskId) async {
    final stack = _active;
    if (stack == null) throw StateError('no active computer');
    final taskList = _activeTaskList;
    taskList?.markRemovedLocally(taskId);
    try {
      final res = await stack.deleteTask(taskId);
      await draftStore?.removeSession(stack.profile.deviceSid, taskId);
      await sendQueue?.removeSession(stack.profile.deviceSid, taskId);
      return res;
    } catch (e) {
      // RPC 失败清墓碑（状态层批）：卡片立即回到列表，不等 60s 过期。
      taskList?.clearRemovedLocally(taskId);
      rethrow;
    }
  }

  /// 打开任务时标记已读（best-effort，失败不打扰）。
  void markTaskRead(String taskId, {int? expectedUnreadAt}) {
    unawaited(_active?.markTaskRead(taskId, expectedUnreadAt: expectedUnreadAt));
  }

  // ---------------------------------------------------------- conversation

  /// 订阅一个会话（幂等；bridge 重开后由传输层自动重订阅）。
  /// [seedCacheEntry]（2026-11-05 反馈②C）：页面缓存预渲已读同一缓存时
  /// 传入复用，免同文件二次读/解码。
  Future<ConversationSubscription> ensureConversation(
    String sessionId, {
    SessionCacheEntry? seedCacheEntry,
  }) async {
    final stack = _active;
    if (stack == null) throw StateError('no active computer');
    return stack.ensureConversation(sessionId, seedCacheEntry: seedCacheEntry);
  }

  /// 被其他设备接管后的主动强制接管（新终端把对端踢下线）。
  void takeoverConnection() => _active?.retryAfterKicked();

  /// 新建会话（首条消息随 createSession 一起提交，避免新会话首命令竞态）。
  Future<String> createSession(
    String? firstText, {
    Map<String, dynamic>? config,
  }) async {
    final stack = _active;
    if (stack == null) throw StateError('no active computer');
    return stack.createSession(firstText, config: config);
  }

  ConversationTransport? get _conv => _active?.conversation;

  /// 会话压缩（compact 命令信封；详见 transport 层注释）。
  Future<dynamic> sendCompact(String sessionId) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.sendCompact(sessionId);
  }

  /// B 批（2026-11-08）：取消后台工作（官方 cancelBackgroundWork 命令）。
  Future<dynamic> cancelBackgroundWork(String sessionId, String workId) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.cancelBackgroundWork(sessionId, workId);
  }

  /// 机会项#1（2026-11-08）：在电脑 ZCodeProject 下新建项目（同名复用）
  /// 并切换到它；返回创建结果（workspacePath/Key/projectId）。
  Future<Map<String, dynamic>> createWorkspace(String name) async {
    final stack = _active;
    if (stack == null) throw StateError('no active computer');
    final res = await stack.createWorkspace(name);
    unawaited(refreshWorkspaces());
    return res;
  }

  /// E 批+：Hook 审核决策（respond 查 ACK status 由调用方负责）/
  /// 写盘开关（非选择态——transport 层注释详见；当前无调用方）。
  Future<dynamic> respondWorkspaceHookReview(
    String sessionId,
    Map<String, dynamic> target,
    List<String> reviewItemIds,
  ) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.respondWorkspaceHookReview(sessionId, target, reviewItemIds);
  }

  Future<dynamic> toggleWorkspaceHookReviewItem(
    String sessionId,
    Map<String, dynamic> target,
    String reviewItemId,
    bool enabled,
  ) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.toggleWorkspaceHookReviewItem(
        sessionId, target, reviewItemId, enabled);
  }

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
  }) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.sendText(
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
  }

  Future<dynamic> stop(String sessionId) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.stop(sessionId);
  }

  // --------------------------------------------- 审批/goal/模型/搜索/排队

  /// 审批应答（先到先得，晚到 alreadyResolved 由 UI 静默吸收）。
  Future<dynamic> resolveInteraction(
    String sessionId,
    String interactionId, {
    String? optionId,
    String? freeText,
    String? action,
    Map<String, dynamic>? content,
  }) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.resolveInteraction(
      sessionId,
      interactionId,
      optionId: optionId,
      freeText: freeText,
      action: action,
      content: content,
    );
  }

  /// 本进程内是否有该会话的发送命令记录（重启后为空——页面据此
  /// 区分"查无可查"与"查询失败"， 死键修复）。
  bool hasLastCommandRecord(String sessionId) =>
      _conv?.lastCommandIdOf(sessionId) != null;

  /// 契约（并行草稿确权批）：活跃会话传输上 createSession 在飞/结果未知
  /// 期间的命令 id（新会话尚无 sessionId，按 pending 假键可查）。上层
  /// 「结果未知先核对」用它查同一命令，不得生成新 ID 重发草稿。
  /// 无活跃传输（未连接）时返回 null。
  String? lastCommandIdForDraftRecheck() =>
      _conv?.pendingCreateSessionCommandId();

  /// 查询某会话最后一条已发出命令的确权结果
  /// （官方 queryConversationCommandsV4 对位）。返回 ack Map=权威结论；
  /// 'unknown'=查不到；null=无记录/未连接。
  Future<dynamic> queryLastSentCommand(String sessionId) async {
    final conv = _conv;
    final commandId = conv?.lastCommandIdOf(sessionId);
    if (conv == null || commandId == null) return null;
    try {
      return await conv.queryConversationCommand(
        commandId: commandId,
        sessionId: sessionId,
      );
    } catch (_) {
      return null;
    }
  }

  /// 查看态上报——打开任务带 activeTaskId；null=回
  /// 主页/退后台（官方 Home/后台立即取消对位）。
  void reportTaskView(String? taskId) {
    _active?.reportViewState(taskId: taskId);
  }

  /// 提问自动采纳 snooze（官方 interactionAutoResolution
  /// Command 对位）——见 ConversationTransport.snoozeInteractionAutoResolution。
  Future<dynamic> snoozeInteractionAutoResolution(
    String sessionId,
    String interactionId,
  ) async {
    final conv = _conv;
    // （对抗审查·并发#3）：静默 return null 会被调用方当成功——
    // _snoozed 永久锁死而服务端从未收到（交互照旧自动结束）。
    if (conv == null) throw StateError('no active computer');
    return conv.snoozeInteractionAutoResolution(sessionId, interactionId);
  }

  Future<dynamic> switchModelConfig(
    String sessionId, {
    required String provider,
    required String model,
    required String thought,
  }) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.switchModelConfig(
      sessionId,
      provider: provider,
      model: model,
      thought: thought,
    );
  }

  Future<dynamic> switchCollaborationMode(String sessionId, String mode) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.switchCollaborationMode(sessionId, mode);
  }

  Future<dynamic> sendGoalCommand(String sessionId, String text) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.sendGoalCommand(sessionId, text);
  }

  Future<dynamic> pauseGoal(String sessionId) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.pauseGoal(sessionId);
  }

  Future<dynamic> resumeGoal(String sessionId) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.resumeGoal(sessionId);
  }

  // ------------------------------------- diff / 行级操作 / 附件（波次 3b）

  /// 工作流族只读查询（workflow-runs-1；详见 transport 层注释）。
  Future<dynamic> workflowRuns(String sessionId, {int? limit}) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.workflowRuns(sessionId, limit: limit);
  }

  Future<dynamic> workflowRunEvents(
    String sessionId,
    String runId, {
    int? afterSequence,
    int? limit,
  }) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.workflowRunEvents(
      sessionId,
      runId,
      afterSequence: afterSequence,
      limit: limit,
    );
  }

  Future<dynamic> workflowRunArtifacts(String sessionId, String runId) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.workflowRunArtifacts(sessionId, runId);
  }

  /// A 批（2026-11-08）：看板产物取数（transport 层注释详见）。
  Future<dynamic> workflowRunArtifactData(
    String sessionId,
    String runId,
    String artifactId, {
    int? afterSequence,
    int? limit,
  }) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.workflowRunArtifactData(
      sessionId,
      runId,
      artifactId,
      afterSequence: afterSequence,
      limit: limit,
    );
  }

  Future<dynamic> workflowRunArtifactRead(
    String sessionId,
    String runId,
    String artifactId, {
    required int version,
    required int offset,
    required int limit,
  }) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.workflowRunArtifactRead(
      sessionId,
      runId,
      artifactId,
      version: version,
      offset: offset,
      limit: limit,
    );
  }

  Future<dynamic> fileChanges(
    String sessionId, {
    required Map<String, dynamic> target,
  }) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.fileChanges(sessionId, target: target);
  }

  Future<dynamic> fileRewindPreview(
    String sessionId, {
    required Map<String, dynamic> target,
  }) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.fileRewindPreview(sessionId, target: target);
  }

  Future<dynamic> applyFileRewind(
    String sessionId, {
    required Map<String, dynamic> target,
  }) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.applyFileRewind(sessionId, target);
  }

  /// 编辑用户消息（服务端会 rewind 该行之后的对话）。
  Future<dynamic> editUserQuery(
    String sessionId,
    Map<String, dynamic> target,
    String newText,
  ) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.editUserQuery(sessionId, target, newText);
  }

  Future<dynamic> retryTurn(
    String sessionId,
    Map<String, dynamic> target,
  ) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.retryTurn(sessionId, target);
  }

  /// like / dislike / null（取消）。
  Future<dynamic> setAssistantFeedback(
    String sessionId,
    Map<String, dynamic> target,
    String? feedback,
  ) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.setAssistantFeedback(sessionId, target, feedback);
  }

  /// 附件读取（预览）：返回 {bytes, mediaType}。
  Future<({List<int> bytes, String? mediaType})> attachmentRead(
    String sessionId,
    String ref, {
    Map<String, dynamic>? target,
    int? attachmentIndex,
  }) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    final r = await conv.attachmentRead(
      sessionId,
      ref: ref,
      target: target,
      attachmentIndex: attachmentIndex,
    );
    return (bytes: r.bytes, mediaType: r.mediaType);
  }

  /// @文件 候选（file.searchWorkspaceFiles）。
  Future<List<Map<String, dynamic>>> searchFiles(String query) async {
    final conv = _conv;
    if (conv == null) return const [];
    try {
      return await conv.searchWorkspaceFiles(query);
    } catch (_) {
      return const [];
    }
  }

  /// 斜杠命令/模型选项目录（zcode-task.prepareWorkspace，transport 内缓存）。
  Future<dynamic> prepareWorkspace({bool refresh = false}) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    return conv.prepareWorkspace(refresh: refresh);
  }

  /// 加载更早的历史（rowsRange）。
  Future<void> loadOlder(String sessionId) async {
    final conv = _conv;
    if (conv == null) return;
    final state = _subscriptionStateOf(sessionId);
    if (state == null || !state.canLoadOlder) return;
    final requestEpoch = state.logEpoch;
    final requestCursor = state.oldestRowId;
    final res = await conv.rowsRange(sessionId, beforeRowId: requestCursor);
    if (res is! Map) return;
    // 官方 conversationProjectionStore.loadOlder 陈旧读防护：跨 CLI 重启、
    // 响应纪元不匹配、在途快照替换/游标失效均整页丢弃，不复活旧历史。
    if (!identical(state, _subscriptionStateOf(sessionId)) ||
        !shouldAcceptOlderRows(
          requestLogEpoch: requestEpoch,
          currentLogEpoch: state.logEpoch,
          responseLogEpoch: res['atLogEpoch'] is String
              ? res['atLogEpoch'] as String
              : null,
          requestCursor: requestCursor,
          currentCursor: state.oldestRowId,
        )) {
      debugPrint('[history] stale rowsRange discarded session=$sessionId');
      return;
    }
    final rows = res['rows'];
    if (rows is List) {
      state.prependOlderRows(
        rows.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList(),
        (res['firstRowId'] as num?)?.toInt(),
        // hasMore 是官方到顶信号（旧实现丢弃它，历史入口只能靠计数
        // 判据收口——计数一旦损坏按钮永藏，2026-10-23 真机实锤）。
        hasMore: res['hasMore'] is bool ? res['hasMore'] as bool? : null,
      );
    }
  }

  ConversationState? _subscriptionStateOf(String sessionId) {
    final stack = _active;
    if (stack == null) return null;
    return stack.conversationStates[sessionId];
  }

  /// 排队项操作（运行中排队 UI 反馈用，协议语义见 _casCommands 注释）。
  Future<dynamic> sendQueuedNow(String sessionId, String queueItemId) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    final res = await conv.sendQueuedNow(sessionId, queueItemId);
    _subscriptionStateOf(sessionId)?.optimisticRemoveQueueItem(queueItemId);
    return res;
  }

  Future<dynamic> deleteQueueItem(String sessionId, String queueItemId) async {
    final conv = _conv;
    if (conv == null) throw StateError('no active computer');
    final res = await conv.deleteQueueItem(sessionId, queueItemId);
    _subscriptionStateOf(sessionId)?.optimisticRemoveQueueItem(queueItemId);
    return res;
  }

  // ------------------------------------------------------------ teardown

  /// 回前台探测（保活 v1：AppLifecycleListener.onResume 调用）——
  /// 所有存活栈都探（后台栈的 relay 也可能在等心跳超时）。
  void poke() {
    for (final stack in _stacks.values) {
      stack.poke();
    }
  }

  // --------------------------------------- 后台断连策略（阶段 3 第二段）

  /// 退后台默认 90s 断连（拍板区间 1-2 分钟取中）；"审批提醒"开
  /// （前台服务）则后台常连不断。回前台 ≤5s 恢复（验收线）。
  static const backgroundDisconnectDelay = Duration(seconds: 90);
  Timer? _bgDisconnectTimer;
  bool _suspendedAll = false;
  bool get suspendedAll => _suspendedAll;

  /// 生命周期代际号：回前台/再次退后台都自增——断连定时器回调执行中
  /// 用户回前台时，靠它中止后续栈的 suspend（发现8：否则 app 在
  /// 前台却被断成全离线且无自愈）。
  int _lifecycleGen = 0;

  /// 会话明细订阅已随退后台驻留（电量优化批 #16）——回前台据此对当前
  /// 打开的会话触发增量续订恢复。只在保活分支置位（90s 断连分支整栈
  /// suspend，订阅已 dispose 走既有恢复路径）。
  bool _conversationsParked = false;

  /// 保活后台的对账候选（状态层批）：退后台时在线的栈。后台若掉线
  /// （relay 实际断开），断线窗口内的完成/审批事件不会再走逐条 upsert
  /// ——恢复后首个 si 快照必须走对账模式。只在"看过在线→掉线"时记水位，
  /// 不无条件写（否则后台实时通知会被吞进聚合缓冲）。
  final _bgReconcileCandidates = <String>{};
  final Map<String, void Function()> _bgOfflineWatchers = {};

  /// 保活分支挂栈监听（幂等）：栈状态迁移到非 online 时登记对账水位。
  void _watchKeepAliveStacksForReconcile() {
    for (final entry in _stacks.entries) {
      final sid = entry.key;
      final stack = entry.value;
      if (stack.computeStatus() == LinkPhase.online) {
        _bgReconcileCandidates.add(sid);
      }
      if (_bgOfflineWatchers.containsKey(sid)) continue;
      void listener() {
        if (_disposed || !_appInBackground) return;
        if (!_bgReconcileCandidates.contains(sid)) return;
        if (stack.computeStatus() == LinkPhase.online) return;
        _bgReconcileCandidates.remove(sid);
        notifyCoordinator?.markPendingReconcile(sid);
        _log('[notify] background relay drop: reconcile watermark $sid');
      }

      stack.addListener(listener);
      _bgOfflineWatchers[sid] = listener;
    }
  }

  /// 回前台收尾（状态层批）：摘监听 + 仍不在线的候选补记对账水位。
  void _drainKeepAliveReconcileWatchers() {
    for (final entry in _bgOfflineWatchers.entries) {
      _stacks[entry.key]?.removeListener(entry.value);
    }
    _bgOfflineWatchers.clear();
    for (final sid in _bgReconcileCandidates.toList()) {
      final stack = _stacks[sid];
      if (stack != null && stack.computeStatus() != LinkPhase.online) {
        notifyCoordinator?.markPendingReconcile(sid);
      }
    }
    _bgReconcileCandidates.clear();
  }

  /// 退后台（app.dart AppLifecycleListener.onPause 调用）。
  void onAppPaused() {
    if (_disposed) return;
    _appInBackground = true;
    _lifecycleGen++;
    // 退后台即取消查看态（官方 Home/后台立即取消）——让桌面恢复
    // 未读标记；桥不活的栈无通道自然跳过。
    for (final stack in _stacks.values) {
      stack.reportViewState();
    }
    // 输入草稿不依赖 90 秒断连定时器；审批保活档也必须立即落盘。
    unawaited(draftStore?.flush());
    unawaited(sendQueue?.flush());
    // 电量档位表（battery-heartbeat-2 → 优化批 #16/#17）：
    // - 审批提醒开（保活分支）：30s 慢档心跳 + 驻留会话明细订阅
    //   （优化批 #16：保活连接下桌面活跃会话持续推流式帧是后台耗电
    //   主因，真机 660mAh/h 实证；si+tasks-index 保留=通知数据源）。
    // - 审批提醒关（90s 断连倒计时窗口）：完全静默——不发心跳、不看
    //   门狗（优化批 #17：服务器 120s 静默容忍已实证
    //   tools/relay-v2-probe.mjs --heartbeat，窗口结束连接本就拆除；
    //   此前 30s 慢档是 battery-heartbeat-2 的过渡档）。
    final keepAlive = uiPrefs.alertsEnabled && _fgRunning;
    for (final stack in _stacks.values) {
      if (keepAlive) {
        stack.setRelayBackgroundHeartbeat(true);
      } else {
        stack.setRelaySilent(true);
      }
    }
    if (keepAlive) {
      _log('[lifecycle] background: alerts on, staying connected (heartbeat 30s)');
      _conversationsParked = true;
      // 掉线对账候选（状态层批）：保活期 relay 若实际断开，恢复后需
      // 走对账模式补报断线窗口内的事件。
      _watchKeepAliveStacksForReconcile();
      for (final stack in _stacks.values) {
        unawaited(
          stack
              .suspendConversationSubscriptions()
              .then((_) {}, onError: (Object _) {}),
        );
        // 1.0.1 真机验收⑩：tasks-index 一并退订（5s notify 帧是驻留后
        // 剩余推帧大头；数据保留，回前台重订阅+对账通知兜底）。
        unawaited(
          stack
              .pauseTasksIndexForBackground()
              .then((_) {}, onError: (Object _) {}),
        );
      }
      return;
    }
    _bgDisconnectTimer?.cancel();
    final gen = _lifecycleGen;
    _bgDisconnectTimer = Timer(backgroundDisconnectDelay, () {
      if (_disposed || _lifecycleGen != gen) return;
      _suspendedAll = true;
      _log(
        '[lifecycle] background disconnect after '
        '${backgroundDisconnectDelay.inSeconds}s',
      );
      unawaited(() async {
        await notifyCoordinator?.onSuspended();
        for (final stack in _stacks.values.toList()) {
          if (_disposed || _lifecycleGen != gen) return;
          // 逐栈容错（状态层批）：单栈 suspend 抛出不阻断其余栈断开。
          try {
            await stack.suspend();
          } catch (e) {
            _log('suspend failed (contained): $e');
          }
        }
      }());
    });
  }

  /// 回前台（app.dart AppLifecycleListener.onResume 调用）：
  /// 取消未到期的断连定时器；已断连则立即重连（≤5s 恢复验收线）+
  /// 通知对账（"你不在时完成了 N 个任务"）+ 清过时。
  void onAppResumed() {
    _appInBackground = false;
    _lifecycleGen++;
    _bgDisconnectTimer?.cancel();
    _bgDisconnectTimer = null;
    // 掉线对账收尾（状态层批）：摘后台监听；仍不在线的候选补记对账水位
    // （恢复后的首个 si 快照据此走对账模式）。
    _drainKeepAliveReconcileWatchers();
    // 电量专项：先退出静默档（优化批 #17——90s 窗口静默不发心跳，此处
    // 恢复；静默期坏链路由下方 poke 探活兜底 3s 内重建），再恢复官方
    // 5s 心跳档（悬挂重建路径的连接本就是前台默认档，统一清理幂等）。
    for (final stack in _stacks.values) {
      stack.setRelaySilent(false);
      stack.setRelayBackgroundHeartbeat(false);
    }
    // 状态层批：退后台已取消查看态（让桌面恢复未读），回前台仍停在
    // 会话页时补报一次——否则该会话在桌面上一直是未读。
    final viewing = viewingSessionId;
    if (viewing != null && viewing.isNotEmpty) {
      final stack = _active;
      if (stack != null && stack.computeStatus() == LinkPhase.online) {
        stack.reportViewState(taskId: viewing);
      }
    }
    // 1.0.1 真机验收⑩：tasks-index 重订阅（增量补齐后台期间变化）。
    if (_conversationsParked) {
      final active = _active;
      if (active != null) {
        unawaited(
          active
              .resumeTasksIndexFromBackground()
              .then((_) {}, onError: (Object _) {}),
        );
      }
    }
    // 优化批 #16：驻留恢复——仅当前打开的会话（页面持有的订阅引用经
    // 驻留保持有效，增量续订后帧继续流入同一状态对象，页面自动接续）；
    // 未打开的会话保持驻留，下次进入 ensureConversation 惰性恢复。
    if (_conversationsParked) {
      _conversationsParked = false;
      final sid = viewingSessionId;
      final stack = _active;
      if (sid != null && sid.isNotEmpty && stack != null) {
        unawaited(
          stack.ensureConversation(sid).then((_) {}, onError: (Object _) {}),
        );
      }
    }
    if (!_suspendedAll) {
      poke();
      notifyCoordinator?.onResumed();
      return;
    }
    _suspendedAll = false;
    _log('[lifecycle] foreground reconnect begin');
    final stopwatch = Stopwatch()..start();
    // 活跃栈立即恢复；其余栈保持悬挂（activate 切换时再连——省电），
    // 但对账水位全栈保留：非活跃栈重连（activate）时 si 重放自然对账
    // （发现4：限制在活跃栈=断连窗口内其他电脑的事件全丢）。
    final active = _active;
    if (active != null) {
      // （2026-10-26 断线批）：统一走 pokeOrResume——resume 可能落在
      // 90s 断连定时器触发的 suspend 的 await 窗口内，按 suspended
      // （_client==null）判定会误判"未悬挂"而只 poke，栈被留在悬挂态
      // 无人恢复（真机体感：回 app 后一直转圈连不上）。
      unawaited(
        active
            .pokeOrResume()
            .then((_) {
              _log(
                '[lifecycle] foreground reconnect done in '
                '${stopwatch.elapsedMilliseconds}ms',
              );
            })
            .catchError((Object e) {
              _log('resume error (contained): $e');
            }),
      );
    } else {
      poke();
    }
    notifyCoordinator?.onResumed();
    notifyListeners();
  }

  // ---------------------------------------------------- 前台服务（审批提醒）

  static const _fgChannel = MethodChannel('companion/notify');
  bool _fgRunning = false;
  String _fgLastText = '';

  /// "审批提醒"开关（=安卓前台服务：常驻状态通知 + 后台连接保活，
  /// phase3-notify-design 档位表）。默认关。
  Future<void> setAlertsEnabled(bool enabled) async {
    if (enabled) {
      // 系统通知权限（状态层批）：被拒时开关必须回弹——否则开关显示
      // "开"、FGS 也起了，但所有通知都被系统丢弃，用户以为在监控实际
      // 全漏。提示文案由 UI 读 [alertsError] 展示（l10n 需求）。
      final service = notifyService;
      if (service != null) {
        final granted = await service.ensurePermission();
        if (!granted) {
          await uiPrefs.setAlertsEnabled(false);
          alertsError = '系统通知权限未开启，审批提醒无法生效；请在系统设置中允许通知后重试';
          _log('[notify] alerts on DENIED (permission not granted)');
          notifyListeners();
          return;
        }
      }
    }
    alertsError = null;
    await uiPrefs.setAlertsEnabled(enabled);
    if (enabled) {
      final started = await _fgStart();
      if (!started) {
        // 启动失败回弹开关（发现7）：否则开关显示"开"实际走 90s
        // 断连档，过夜等审批通知全丢且用户无感知。
        await uiPrefs.setAlertsEnabled(false);
        _log(
          '[notify] alerts on FAILED (foreground service not started) '
          '- reverted to off',
        );
        notifyListeners();
        return;
      }
    } else {
      await _fgStop();
    }
    _log('[notify] alerts ${enabled ? 'on' : 'off'}');
  }

  /// 开关失败的人话提示（目前只有通知权限被拒一条；UI 消费后应调用
  /// [clearAlertsError] 清位）。
  String? alertsError;

  void clearAlertsError() {
    if (alertsError == null) return;
    alertsError = null;
    notifyListeners();
  }

  Future<bool> _fgStart() async {
    try {
      // 初始常驻通知文案由 Dart 侧按当前语言传入
      // （原生侧仅留中文兜底；启动后 _updateForegroundText 立即覆写）。
      await _fgChannel.invokeMethod('startForeground', {
        'text': tr('已连接 · 保持后台实时通知'),
      });
      _fgRunning = true;
      _fgLastText = '';
      _updateForegroundText();
      return true;
    } catch (e) {
      _log('foreground service start failed: $e');
      return false;
    }
  }

  Future<void> _fgStop() async {
    try {
      await _fgChannel.invokeMethod('stopForeground');
    } catch (_) {}
    _fgRunning = false;
    _fgLastText = '';
  }

  /// 常驻通知文本（连接状态 + 在跑任务数，设计文档聚合样式）。
  void _updateForegroundText() {
    if (!_fgRunning) return;
    var running = 0;
    String? topRunningTitle;
    var topRunningAt = -1;
    for (final stack in _stacks.values) {
      final list = stack.taskList;
      // 状态层批：按 phase 判运行（taskList.running 视图排除置顶行——
      // 唯一运行任务被置顶时常驻文案误报「无任务运行」）。
      final runningCards =
          list?.cards.where((c) => isRunningPhase(c.phase)).toList() ??
              const <TaskCardData>[];
      running += runningCards.length;
      // 带上最新运行任务名（锁屏可见具体在跑什么；
      // 防噪拍板不变——仍只有一条常驻文本，不逐事件发通知）。
      for (final c in runningCards) {
        final at = c.lastActivityAt;
        if (at > topRunningAt) {
          topRunningAt = at;
          topRunningTitle = c.title;
        }
      }
    }
    // 常驻通知文案经词表走 tr()（参数在拼接前本地
    // 化；任务标题为用户内容保持原文——由 pattern 捕获段透传）。
    final runningSuffix = running == 0
        ? tr('无任务运行')
        : (topRunningTitle == null || topRunningTitle.trim().isEmpty
              ? tr('$running 个任务运行中')
              : tr('「${topRunningTitle.trim()}」等 $running 个任务运行中'));
    String paren(String inner) =>
        L10n.resolvedLocale == 'en-US' ? '($inner)' : '（$inner）';
    // 口径对齐：任务数聚合全栈而连接档此前只看活跃
    // 栈——后台栈在线跑任务而活跃栈离线时拼出"未连接 · N 个任务运行中"
    // 的自相矛盾文案。FGS 的语义是"app 保持连接以接收通知"：只要有任一
    // 栈在线即按在线档呈现（不新增文案，复用既有词表）。
    var anyOnline = false;
    for (final stack in _stacks.values) {
      if (stack.computeStatus() == LinkPhase.online) {
        anyOnline = true;
        break;
      }
    }
    final effectivePhase = phase == LinkPhase.online || anyOnline
        ? LinkPhase.online
        : phase;
    final text = switch (effectivePhase) {
      LinkPhase.online => '${tr('已连接')} · $runningSuffix',
      LinkPhase.connecting || LinkPhase.reconnecting =>
        '${tr('连接中…')}${relayDiagnosis == null ? '' : paren(tr(relayDiagnosis!.title))}',
      LinkPhase.waitingDesktop => tr('等待桌面端'),
      LinkPhase.kicked => tr('已被其他手机页接管'),
      LinkPhase.invalid => tr('凭据失效，请重新扫码'),
      LinkPhase.error => tr('连接异常'),
      _ => tr('未连接'),
    };
    if (text == _fgLastText) return;
    _fgLastText = text;
    _fgChannel
        .invokeMethod('updateForeground', {'text': text})
        .catchError((Object _) {});
  }

  @override
  void dispose() {
    _disposed = true;
    _bgDisconnectTimer?.cancel();
    _bgDisconnectTimer = null;
    _switchNoticeTimer?.cancel();
    _switchNoticeTimer = null;
    // 保活后台掉线监听摘除（状态层批）。
    for (final entry in _bgOfflineWatchers.entries) {
      _stacks[entry.key]?.removeListener(entry.value);
    }
    _bgOfflineWatchers.clear();
    _bgReconcileCandidates.clear();
    uiPrefs.removeListener(_syncNotifyPrefs);
    // 电量日志收尾（状态层批）：此前 dispose 不停 journal——定时器与
    // WidgetsBinding 观察者跨 dispose 生命周期残留（测试/热重载泄漏）。
    batteryJournal?.stop();
    batteryJournal = null;
    // 先拆栈（各栈 dispose 内部 flush 在途写），落定后再关缓存——否则
    // 最后一次落盘被 _closed 直接吞掉（与 LocalCacheStore.close 等在途
    // 写的双保险）。
    unawaited(
      _deviceRegistry.dispose().then((_) async {
        await cacheStore?.close();
      }),
    );
    unawaited(draftStore?.close());
    unawaited(sendQueue?.close());
    unawaited(_fgStop());
    unawaited(notifyStore?.flush());
    super.dispose();
  }
}
