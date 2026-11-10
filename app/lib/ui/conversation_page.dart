import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/l10n.dart';

import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../core/theme.dart';
import '../core/payload_guard.dart';
import '../core/retry_backoff.dart';
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../state/git_branch_service.dart';
import '../state/send_queue_controller.dart';
import '../state/send_queue_store.dart';
import '../transport/id.dart' show generateUuid;
import '../state/task_list.dart';
import '../transport/project_tree.dart';
import 'app_widgets.dart';
import 'anchored_chat_list.dart';
import 'branch_sheet.dart';
import 'brand_logo.dart';
import 'attachments_compose.dart';
import 'attachment_annotate_page.dart';
import 'quota_banner.dart';
import 'voice_input_sheet.dart';
import '../state/cache_policy.dart';
import '../state/draft_store.dart';
import '../transport/channel_client.dart';
import '../transport/conversation.dart';

import 'dart:typed_data';

import 'composer_panels.dart';
import 'background_works_page.dart';
import 'status_tray.dart';
import 'conversation_composer.dart';
import 'conversation_turn_view.dart';
import 'conversation_file_summary_card.dart';
import 'conversation_message_cells.dart';
import 'conversation_composer_meta.dart';
import 'conversation_queue_strip.dart';
import 'conversation_search.dart';
import 'conversation_view_store.dart';
import 'workflow_runs_page.dart';
import 'goal_panel.dart';
import 'interaction_banner.dart';
import 'subagent_list_sheet.dart';
import 'motion.dart';
import 'turn_model.dart';

/// 会话页（对话流）：v4 订阅 + 消息流渲染 + 输入栏。
/// [sessionId] == null 为草稿模式：首条消息经 createSession(firstInput) 提交
/// （避免新会话首命令竞态，与官方 composer 同路，zemote chat_page.dart:678-687）。
///
/// 渲染（2.1 核心，桌面对齐基准=用户截图 2026-10-15）：
/// - turn 分组见 turn_model.dart：已完成 turn 折叠「已工作 X 分 X 秒」条，
///   运行中保持思考条/工具卡可见 + turn 条实时计时；
/// - 思考条 🧠「思考 X 秒」：展开内容限高内滚动，收起钮常驻可点
///   （修复流式思维链把收起钮顶出屏幕的用户反馈 ③b）；
/// - 工具显示开关（设置页第一项）关闭时隐藏工具活动；
/// - 运行中发送排队：输入栏上方排队条（立即发送/删除）。
/// 模式选择落地决策（纯函数）：已有会话 → 立即下发
/// switchCollaborationMode（官方桌面行为，v4 命令值域含 plan，refs
/// command.ts:258-260）；新会话草稿 → 挂起随 createSession.config 提交。
enum ModePickAction { immediate, pending }

ModePickAction resolveModePickAction({required String? sessionId}) =>
    sessionId != null ? ModePickAction.immediate : ModePickAction.pending;

/// held 二选一弹层被用户取消（点取消/点外部关闭）——主动放弃发送，
/// 走和气路径（不置错误红条、正文回填），与真实发送失败区分。
class SendCancelled implements Exception {
  const SendCancelled();
  @override
  String toString() => 'send cancelled';
}

/// 空态欢迎屏分时问候语（2026-10-23 用户反馈批⑥，对齐官方
/// ConversationDraftEmptyState.tsx:32-44 六档原文 zh-CN.ts:4591-4596）：
/// 不插用户名/workspace 名（官方设计文档明令，避免与工作区身份混淆）。
String chatEmptyGreeting(int hour) => switch (hour) {
  >= 5 && < 9 => '早上好呀，新的一天开始啦',
  >= 9 && < 12 => '上午好呀，有什么想让我帮忙的吗',
  >= 12 && < 14 => '中午好呀，要不要先休息一下',
  >= 14 && < 18 => '下午好呀，接下来交给我吧',
  >= 18 && < 23 => '晚上好呀，今天辛苦啦',
  _ => '夜深啦，别忘了照顾好自己哦',
};

/// 最新回合的起点是 turnHeader 后第一条普通用户输入；guided 追问只属于
/// 回合内分段，不能冒充回合开始（官方 TurnNavigator query 目录同义）。
int? latestTurnStartRowId(List<Map<String, dynamic>> rows) {
  var lastHeader = -1;
  for (var i = rows.length - 1; i >= 0; i--) {
    if (rows[i]['kind'] == 'turnHeader') {
      lastHeader = i;
      break;
    }
  }
  if (lastHeader >= 0) {
    for (var i = lastHeader + 1; i < rows.length; i++) {
      final row = rows[i];
      if (row['kind'] == 'userInput' && row['guided'] != true) {
        return intOf(row['rowId']);
      }
    }
    return null;
  }
  for (var i = rows.length - 1; i >= 0; i--) {
    final row = rows[i];
    if (row['kind'] == 'userInput' && row['guided'] != true) {
      return intOf(row['rowId']);
    }
  }
  return null;
}

/// 程序化滚动登记判据（#14 低修，公开给单测）：只有真实位移才登记
/// 豁免——ScrollPosition.jumpTo 在目标 == 当前偏移时不产生 ScrollEnd，
/// 预登记会让此后一次用户滚动的落点裁决被误豁免（滚动记忆丢失一次）。
@visibleForTesting
bool shouldMarkProgrammaticScroll(double from, double to) => from != to;

/// 用户可见错误文案：剥掉 StateError.toString() 的「Bad state: 」英文
/// 前缀（否则红条里出现内部术语，与周边中文人话文案不一致）。
String humanizeError(Object error) {
  final raw = '$error';
  const prefix = 'Bad state: ';
  return raw.startsWith(prefix) ? raw.substring(prefix.length) : raw;
}

/// String/bool 安全读取（协议载荷形态漂移守卫同族；payload_guard 只
/// 覆盖数值/容器）：非目标类型返回 null，不抛 TypeError。
String? _stringOf(dynamic v) => v is String ? v : null;
bool? _boolOf(dynamic v) => v is bool ? v : null;

class ConversationPage extends StatefulWidget {
  /// 测试缝：清空会话级工具行折叠记忆（深浅双侧游览共用 sessionId，
  /// 防跨轮状态污染——深色轮起始态须与浅色轮一致）。
  @visibleForTesting
  static void debugResetToolFoldMemory() =>
      ConversationViewStore.resetToolFoldMemory();

  /// 测试缝：清空会话级滚动记忆（游览多轮共用 sessionId，上一轮的
  /// 记忆还原会在新一轮开场 50/300ms 校正窗口内把视口拽回旧位置，
  /// 干扰轮内交互（S11 展开后滚动即被拽回=收起条离场）。
  @visibleForTesting
  static void debugResetScrollMemory() =>
      _ConversationPageState._scrollMemory.clear();

  /// 视觉审查缝（同 S28 debugImage 先例）：asserts 态默认抑制一次性
  /// 引导（保测试确定性），置 true 可强制渲染引导态供审美审查取证。
  static bool debugFabHintForce = false;

  /// 深链定位测试缝（#3）：最近一次成功定位采用的顶层条目锚键。
  @visibleForTesting
  static String? debugLastJumpAnchorKey;

  /// 深链定位测试缝（#3）：滚动记忆里该会话的锚键（断言未被写坏）。
  @visibleForTesting
  static String? debugScrollMemoryAnchor(String sessionId) =>
      _ConversationPageState._scrollMemory[sessionId]?.$1;

  /// 深链定位测试缝（#15）：深链提示 postFrame 排程次数——修复后每页
  /// 实例只在就绪时排（尝试过即置位，不再逐帧空转）。
  @visibleForTesting
  static int debugDeepLinkScheduleCount = 0;

  /// waitForWorkspace 等待时限（测试缝，S28/debugFabHintForce 同款
  /// static 形态）：生产 75s；测试可缩短驱动超时分支。
  static Duration waitForWorkspaceTimeout = const Duration(seconds: 75);

  /// 附件选择器测试缝（#17）：注入后替代 FilePicker.pickFiles——用于
  /// 钉「选择在途退页不得 setState-after-dispose」。
  @visibleForTesting
  static Future<List<PlatformFile>> Function()? debugPickFiles;

  /// 1.0.1 真机验收⑤A：跨工作区打开任务时先推本页（转圈）后台开桥
  /// ——非空=等待 activeWorkspace 键匹配且桥就绪后再订阅（超时/切换
  /// 失败走页面错误态可重试）；null=原行为（当前栈直接订阅）。
  final String? waitForWorkspace;

  /// 欠账盘点 B5 接线修复（2026-11-08）：通知深链时刻随导航参数透传
  ///（task_center 消费 pendingOpenTask 后全局 getter 恒 null 的时序洞）
  /// ——非空时优先于全局 pendingDeepLinkTarget；消费后仍清全局防重放。
  final int? deepLinkAtMs;

  final String? sessionId;
  final String title;

  /// 只读视图（子代理下钻，官方 SubagentSessionSidePane 同款语义，
  /// refs app-shell/SubagentSessionSidePane.tsx:31 readOnly）：隐藏输入区，
  /// 仅浏览会话流。
  final bool readOnly;

  /// 空态欢迎屏问候语取值时刻（测试缝：游览基线需要确定性时段）。
  /// 默认运行时取 DateTime.now()——官方 ConversationDraftEmptyState
  /// 按本地小时分档并在档位边界自动换档；手机草稿页是短命页面，
  /// build 时取值即可，不设边界定时器。
  final DateTime? greetingNow;

  /// 订阅超时测试缝；生产 null=普通会话 60s、只读子代理 180s（冷恢复
  /// 大历史可能超过 60s，不能让在途订阅被误报为失败）。
  final Duration? subscribeTimeout;

  const ConversationPage({
    super.key,
    required this.sessionId,
    required this.title,
    this.readOnly = false,
    this.greetingNow,
    this.subscribeTimeout,
    this.waitForWorkspace,
    this.deepLinkAtMs,
  });

  @override
  State<ConversationPage> createState() => _ConversationPageState();
}

class _ConversationPageState extends State<ConversationPage> {
  // AppState 引用（dispose 时清 viewingSessionId——dispose 不能 of(context)）
  AppState? _appRef;
  final _input = TextEditingController();

  DraftIdentity? _draftIdentity;
  Future<void>? _draftRestoreFuture;
  /// 草稿身份恢复在飞/待重跑标记（didChangeDependencies 每次 app 通知都
  /// 会触发——身份必须可重算，旧实现首帧一次性闩锁后，跨工作区
  /// push-first 的等待期输入与离线入队全记在旧工作区桶上）。
  bool _draftRestoreInFlight = false;
  bool _draftRestoreAgain = false;
  int _draftRevision = 0;
  bool _restoringDraft = false;
  bool _suppressDraftSync = false;
  String? _submittedDraftText;
  int _submittedDraftRevision = 0;
  String _draftTextSnapshot = '';
  bool _draftResultUnknown = false;

  /// 待发送附件（阶段 3 第三段）：草稿态停留 waitingSession，发送时统一
  /// 上传（官方 SessionPane.tsx:3520+ 兜底路径的手机端适配）。
  final List<PendingAttachment> _pendingAtts = [];
  bool _attPumpRunning = false;
  int _attLastValidationVersion = -1;
  final _inputFocusNode = FocusNode();
  final _scroll = ScrollController();
  late final ConversationSearchController _search =
      ConversationSearchController(
        stateProvider: () => _sub?.state,
        itemsProvider: (state) => _cachedItemsIdentical(state.rows, state)
            ? _cachedChatItems
            : _rebuildChatItems(state.rows, state),
        loadOlder: _loadOlder,
        isAlive: () => mounted,
        onNotify: () {
          if (mounted) setState(() {});
        },
        onLocate: _locateActiveSearchMatch,
        onAnchorMigrate: (previous, current) {
          if (_listCenterItemKey == previous) _listCenterItemKey = current;
        },
      );
  TextEditingController get _searchController => _search.controller;
  FocusNode get _searchFocusNode => _search.focusNode;
  final _searchTargetKey = GlobalKey(debugLabel: 'conversation-search-target');
  bool get _searchOpen => _search.isOpen;
  bool get _searchLoading => _search.loading;
  bool get _searchTruncated => _search.truncated;
  String? get _searchError => _search.error;
  List<ConversationSearchMatch> get _searchMatches => _search.matches;
  int get _searchActiveIndex => _search.activeIndex;
  int get _searchNavigationId => _search.navigationId;

  ConversationSearchMatch? get _activeSearchMatch => _search.activeMatch;

  /// 双向懒列表的稳定锚点：值为 itemBuilder 的 row/turn key。
  /// 前插历史时保持该 key，center index 随数据自动后移，阅读坐标不变。
  String? _listCenterItemKey;
  ConversationSubscription? _sub;

  /// 当前已挂 _onStateChanged 的 ConversationState（ A1-P2-1：
  /// 重试重订阅按实例配对摘挂，防幻影监听器驻留 registry 长寿命 notifier）。
  ChangeNotifier? _listenedState;
  String? _sessionId;
  bool _sending = false;
  String? _error;

  /// 订阅路径错误专档（ A2-P3-1）：`_error` 还承载发送/停止
  /// 失败——cache-sync strip 只认订阅错误（否则发送错误会被误标成
  /// 「同步失败：…点按重试」，点按触发的是重订阅）。
  String? _syncError;

  /// 离线入队在飞哨兵（ A1-P2-4）：入队的清输入发生在
  /// `await store.add`（真实文件 IO）之后，双击窗口内第二次 tap 读到
  /// 未清空输入=同文条目双入队（重连后双发）。
  bool _enqueueingOffline = false;

  /// 发送失败原文暂存（A2，2026-10-19 审查）：输入框被等待期新输入
  /// 占用时不回填（避免覆盖新内容），暂存于此，横幅下提供恢复入口。
  String? _unsentDraft;

  // ── 断网消息排队（6.6②，2026-10-29 批次）────────────────────
  late final OfflineSendQueueController _queue = OfflineSendQueueController(
    host: OfflineQueueHost(
      bucketProvider: () => _sendQueueBucket,
      isAlive: () => mounted,
      readOnly: () => widget.readOnly,
      sending: () => _sending,
      replay: _replayQueuedSend,
      onNotify: () {
        if (mounted) setState(() {});
      },
      scheduleDrain: (action) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) action();
        });
      },
    ),
  );
  List<SendQueueEntry> get _queueEntries => _queue.entries;

  /// 状态托盘展开态（status-tray-1109）：≥2 源合并时的折叠开关；
  /// 单源直通路径不读它。会话内保持。
  bool _statusTrayExpanded = false;
  bool _stickToBottom = true;

  bool _initialSubscribePending = false;

  // ------------------------------------------------ 会话缓存首帧（阶段 3）
  // 订阅快照到达前的本地预渲（重开零流量目标）：缓存渲染不阻塞、不替代
  // 订阅流程——live state.ready 后自动让位。断网/冷启时用户立即看到
  // 上次内容（设计文档"读路径"）。
  ConversationState? _cachePreview;
  final Stopwatch _openStopwatch = Stopwatch();
  bool _perfContentLoaded = false;
  bool _perfLiveLogged = false;

  final _viewStore = ConversationViewStore();
  Set<String> get _seenRowKeys => _viewStore.seenRowKeys;

  /// 消息区上一次视口高度（键盘/输入卡展开时粘底跟随用）。
  double? _lastViewportH;

  /// 回到底部悬浮球：拖动中位置/松手停靠位（null=默认右下）。
  Offset? _fabDragging;
  Offset? _fabRest;

  /// 悬浮球指针直跟（2026-10-22 真机反馈④：GestureDetector pan 要先赢
  /// 手势竞技场——前 ~18px 位移被吞（不跟手），微拖松手被判 tap 直接
  /// 跳底（难拖动）。改 Listener 零延迟跟手，tap 自判：总位移 <8px）。
  int? _fabPointer;
  Offset? _fabPointerDown;
  Offset? _fabDragStartPos;

  /// 末段折叠键（ P1-1）：chatItems 逆序找最后一个 TurnBarItem，
  /// 取其 work.collapseKeyId——与 TurnBar 读写键严格同源。找不到（窗口
  /// 无 TurnBar 快照）返回 null 由调用方回退裸 headerId（旧行为）。
  int? get _lastTurnCollapseKeyFromItems {
    final items = _cachedChatItems;
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      if (it is TurnBarItem) return it.work.collapseKeyId;
    }
    return null;
  }

  int? get _lastTurnHeaderIdFromRows {
    final rows = _sub?.state.rows ?? const [];
    for (var i = rows.length - 1; i >= 0; i--) {
      if (rows[i]['kind'] == 'turnHeader') {
        return intOf(rows[i]['rowId']);
      }
    }
    return null;
  }

  void _showTurnQuickActions() {
    // A1-P3-3：实时行扫值优先——_lastTurnHeaderId 由懒列表
    // itemBuilder 赋值，末轮滚出视口后持旧值（期间新回合开始时快捷
    // 菜单会作用于陈旧回合）。菜单打开才执行一次，O(rows) 可承受。
    //
    // P1-1（批E-1 漏改面）：折叠键必须与 TurnBar/TurnWork 同源
    // （collapseKeyId=header rowId*1000+segmentIndex）——guided 多段回合
    // 的可见末段键≠裸 headerId，直接用 headerId 会写错段（末段无反应、
    // 首段被静默翻转）。经最后 TurnBarItem 的 work 取当前末段键。
    final lastTurnCollapseKey = _lastTurnCollapseKeyFromItems;
    final headerId = lastTurnCollapseKey ??
        (_lastTurnHeaderIdFromRows ?? _lastTurnHeaderId);
    final collapsed = headerId != null && _liveCollapsedByRow[headerId] == true;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('turn-start'),
              leading: const Icon(Icons.vertical_align_top),
              title: const Text('回到本回合开始'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_jumpToLastTurnStart());
              },
            ),
            ListTile(
              key: const ValueKey('turn-collapse'),
              leading: Icon(collapsed ? Icons.expand_more : Icons.expand_less),
              title: Text(collapsed ? '展开本回合输出' : '收起本回合输出'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                if (headerId != null) {
                  setState(() {
                    _liveCollapsedByRow[headerId] = !collapsed;
                  });
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 悬浮球松手吸边（拖动位置优先，退回当前停靠位/默认位）。
  void _fabSnapToEdge(Offset fallback, BoxConstraints viewportCons) {
    final cur = _fabDragging ?? fallback;
    setState(() {
      _fabRest = Offset(
        cur.dx + 24 < viewportCons.maxWidth / 2
            ? 14
            : viewportCons.maxWidth - 48 - 14,
        // A2-P3-7/A3-P3-6：num.clamp 要求下限 ≤ 上限——视口
        // <48px（键盘+多横幅极限压缩）时上限为负直接抛 ArgumentError；
        // 上限先钳到 ≥0（回拉路径同款守卫）。
        cur.dy.clamp(0.0, math.max(0.0, viewportCons.maxHeight - 48)),
      );
      _fabDragging = null;
    });
  }

  /// 工具行独立折叠记忆（会话级）：由 ViewStore 跨页面保存并限制容量。
  Map<int, bool> get _toolOpenByRow => _viewStore.toolOpenFor(_sessionId);

  /// 文件变更卡状态提升（ #3）：lazy list 会 dispose 滚出视口的
  /// State——展开态与已载明细放页面级，按轮 header rowId 索引，回滚
  /// 零延迟不重发 RPC。
  Map<int, bool> get _fileCardOpen => _viewStore.fileCardOpen;
  Map<int, List<Map<String, dynamic>>> get _fileCardItems =>
      _viewStore.fileCardItems;

  /// 回合快捷菜单：当前轮折叠覆盖与定位（长按 FAB 打开）。
  Map<int, bool> get _liveCollapsedByRow => _viewStore.liveCollapsedByRow;
  int? _lastTurnHeaderId;
  bool _fabLongPressTriggered = false;

  /// 2026-11-05 反馈③：本页悬浮球引导是否已查过（真值源在 UiPrefs
  /// 持久标记，这里只防同页多帧重复查）。
  bool _fabHintChecked = false;

  /// ⑤A：正在等目标工作区就绪（loading 副文案切换用）。
  bool _waitingWorkspace = false;

  /// 挂起选型（早期反馈①官方语义）：面板选择 → 随下次 sendText 提交。
  String? _pendingModelProvider;
  String? _pendingModelId;
  String? _pendingThought;
  String? _pendingMode;

  /// 计划模式挂起值（2026-10-23 用户反馈批⑦）：null=跟随会话当前值，
  /// true/false=用户已切换（随下条 sendText/createSession 提交——官方
  /// V4ComposerModeControls 菜单只编辑草稿，运行中切换命令
  /// switchCollaborationMode 无 planEnabled 字段，计划只能草稿态切）。
  bool? _pendingPlan;

  /// A5 水位式清理兜底（2026-10-24 修复批）：accepted 但乐观写回被跳过
  /// （快照未就绪）时挂起等待 config 回显确认；回显丢失超时退位给 config。
  Timer? _planEchoTimer;

  /// 输入补全面板状态（斜杠命令 / @文件）
  List<Map<String, dynamic>> _slashCandidates = const [];

  /// 子代理补全候选（官方 slash 面板 subagents 分区；懒加载缓存，
  /// 仅 enabled、按 name 去重、user>内置>插件——subagentsMentionProvider
  /// .ts:36-51 同款）。
  List<Map<String, dynamic>> _subagentCandidates = const [];
  bool _subagentsLoaded = false;
  List<Map<String, dynamic>> _fileCandidates = const [];
  Timer? _fileDebounce;
  List<dynamic> _slashCommands = const []; // SlashCommand 列表（prepareWorkspace）

  /// 用量详情卡（状态点开关）：entitlement/重置机会拉取缓存。
  bool _usageCardOpen = false;
  Map<String, dynamic>? _entCache;
  // 18077 验收#2：缓存所属套餐档——档位切换后旧快照不得复用。
  String? _entCachePlanKind;
  DateTime? _entLoadedAt;

  /// A4 退避（2026-10-19 审查）：失败后 1→2→4→5min 指数退避，替代
  /// "失败即复位"（最坏每通知一次）。stale 判据与在途守卫结构不动。
  DateTime? _entLastAttemptAt;
  int _entFailCount = 0;

  /// 配额低额度提醒去重（官方按桶周期 reminderKey）。
  /// _quotaDismissedKeys=本页实例内手动关闭；_quotaShownKeys=本页实例
  /// 已展示过的键（官方 owner 语义：展示实例内继续显示，跨页/重启由
  /// UiPrefs 持久记录隐藏——PF-1 修复批）。
  final Set<String> _quotaDismissedKeys = {};
  final Set<String> _quotaShownKeys = {};
  bool _entLoading = false;
  Map<String, dynamic>? _resetStatusCache;

  /// 构成明细缓存（sessionId → 最近一份非空 breakdown）：官方协议
  /// conflation 值未变不下发——用户拍板「一直展示」，缺发时用上次数据。
  final Map<String, List<Map>> _lastBreakdown = {};

  /// 工具栏常驻选型的官方显示名（mode.label.glm.*，zh-CN.ts:6135+）。
  static const _modeNames = <String, String>{
    'plan': '计划模式',
    'build': '变更前确认',
    'edit': '自动编辑',
    'guarded': '自主模式',
    'yolo': '完全访问',
  };
  static const _modeDescriptions = <String, String>{
    'plan': '编辑前先出计划',
    'build': '改文件前先问我',
    'edit': '自动编辑文件',
    'guarded': '有风险时询问',
    'yolo': '减少确认次数',
  };
  static const _thoughtNames = <String, String>{
    'low': '低',
    'medium': '中',
    'high': '高',
    'max': '最高',
    'off': '关闭',
    'none': '无',
    'minimal': '极少',
  };

  @override
  void initState() {
    super.initState();
    _sessionId = widget.sessionId;
    final sid = _sessionId;
    final memory = (sid == null || sid.isEmpty) ? null : _scrollMemory[sid];
    if (memory != null && !memory.$3) {
      _listCenterItemKey = memory.$1;
    }
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      // 粘底真修（③粘底真机复发）：内容增长把 maxScrollExtent 顶开时
      // offset 距底 >120px——旧逻辑据此解除粘底，把"加载中的视口顶开"
      // 误判成"用户上滚"。这里不再改粘底态（改由用户拖拽通知解除），
      // 只负责自动加载更早的触发。
      // 官方触发距离（timelineScrollAnchor historyPrefetchTriggerPx，
      // 2026-10-26 对齐批 C）：距顶 ≤ max(64, 2×视口高) 预取（原 60 无
      // 预取量）。
      final prefetch = (!_scroll.hasClients)
          ? 64.0
          : (64.0 > _scroll.position.viewportDimension * 2
                ? 64.0
                : _scroll.position.viewportDimension * 2);
      final distanceToTop = _scroll.offset - _scroll.position.minScrollExtent;
      if (distanceToTop <= prefetch && !_stickToBottom) {
        _maybeAutoLoadOlder();
      }
    });
    _input.addListener(_onInputChanged);
    // 不能在 initState 里调 _subscribe：其内部 AppStateScope.of(context)
    // 会在依赖建立前抛 FlutterError（fire-and-forget 吞异常→页面永远停在
    // 载入态。真机 2026-10-15 终极定位：所有"打开已有会话"必挂的根因，
    // 而新建会话经按钮回调访问 scope 合法所以能成）。
    if (widget.sessionId != null) {
      _initialSubscribePending = true;
    }
    // AppStateScope.of 不能在 initState 同步调用（阶段 1 根因陷阱）——
    // 斜杠命令目录加载延到首帧后。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_loadSlashCommands());
      // A5：打开任务即上报查看态（桌面据此抑未读）。
      final sid = _sessionId;
      if (mounted && sid != null && sid.isNotEmpty) {
        AppStateScope.of(context).reportTaskView(sid);
      }
    });
  }

  Future<void> _loadSlashCommands() async {
    final app = AppStateScope.of(context);
    try {
      // B20：目录刷新直拉（绕缓存）——桌面改命令/模式后
      // 长驻会话页的斜杠面板不再陈旧（官方热订阅为服务内部消费，UI 侧
      // 官方同样按需重拉；此处对齐按需刷新语义）。
      final prep = await app.prepareWorkspace(refresh: true);
      if (mounted) {
        // 入页闪烁收口（2026-10-29）：命令名序列不变不重建。
        final next = prep.slashCommands;
        final cur = _slashCommands;
        final same =
            next.length == cur.length &&
            next
                    .map((c) => '${c['command'] ?? c['name'] ?? ''}')
                    .join('\u0000') ==
                cur
                    .map((c) => '${c['command'] ?? c['name'] ?? ''}')
                    .join('\u0000');
        if (same) return;
        setState(() => _slashCommands = next);
      }
    } catch (_) {
      // 斜杠面板退化：命令目录不可用（冷工作区等），面板不出现
    }
  }

  Future<void> _loadSubagentCandidates() async {
    if (_subagentsLoaded) return;
    _subagentsLoaded = true; // 在飞防抖（失败回滚见下方，允许再拉）
    final app = AppStateScope.of(context);
    final bridge = app.bridge;
    final ws = app.activeWorkspace;
    // A1-P3-1/A3-P3-4：桥/工作区未就绪是瞬时态——旧实现先置
    // 闩锁再查前置条件，瞬时失败后本页实例子代理补全永久不可用（注释
    // 承诺的「下次打开面板再拉」不存在）。失败回滚闩锁，下次输入/打开
    // 面板重试。
    if (bridge == null || ws == null) {
      _subagentsLoaded = false;
      return;
    }
    try {
      final res = await bridge.channels.call(Channels.subagents, 'list', [
        {
          'workspacePath': ws['workspacePath'],
          if (ws['workspaceIdentity'] != null)
            'workspaceIdentity': ws['workspaceIdentity'],
        },
      ], timeout: const Duration(seconds: 15));
      if (!mounted || res is! Map) return;
      final out = <String, Map<String, dynamic>>{};
      void take(List? section) {
        if (section == null) return;
        for (final raw in section.whereType<Map>()) {
          final m = raw.cast<String, dynamic>();
          if (m['enabled'] == false) continue;
          final name = '${m['name'] ?? ''}'.trim();
          if (name.isEmpty || out.containsKey(name)) continue;
          out[name] = {
            'name': name,
            'description': '${m['description'] ?? m['prompt'] ?? ''}',
          };
        }
      }

      take(listOf(res['userAgents']));
      take(listOf(res['agents']));
      take(listOf(res['pluginAgents']));
      if (out.isEmpty) return;
      // A1-P3-1：候选真正到达时若当前仍是 slash token，就地
      // 重算补全列表（旧实现只 setState 换候选字段，_slashCandidates
      // 不重算——第一次输入 / 看不到子代理分区，再敲一键才出现）。
      final cur = activeCompletionToken(_input.text);
      setState(() {
        _subagentCandidates = out.values.toList();
        if (cur != null && cur.type == 'slash') {
          _slashCandidates = filterSlashCommands(
            _slashCommands.cast<SlashCommand>(),
            cur.token,
            subagents: _subagentCandidates,
          );
        }
      });
    } catch (_) {
      // 子代理候选拉不到不影响 slash 命令补全；瞬时失败允许重拉。
      _subagentsLoaded = false;
    }
  }

  void _onInputChanged() {
    _draftTextSnapshot = _input.text;
    if (!_restoringDraft && !_suppressDraftSync) _onDraftMutated();
    // D3-P3-13：按光标位置解析 token——旧版只看文尾，中段
    // 编辑时任意键入都会弹文尾 token 的面板、点选把光标拽到文尾。
    final sel = _input.selection;
    final token = activeCompletionToken(
      _input.text,
      cursor: sel.isValid ? sel.baseOffset : null,
    );
    if (token == null) {
      if (_slashCandidates.isNotEmpty || _fileCandidates.isNotEmpty) {
        setState(() {
          _slashCandidates = const [];
          _fileCandidates = const [];
        });
      }
      return;
    }
    if (token.type == 'slash') {
      _loadSubagentCandidates();
      // A3-P3-9：先算后比——斜杠输入期每个字符都无条件
      // setState 整页重建（含 O(rows) 投影检查）；候选不变不重建。
      final next = filterSlashCommands(
        _slashCommands.cast<SlashCommand>(),
        token.token,
        subagents: _subagentCandidates,
      );
      final same =
          next.length == _slashCandidates.length &&
          next
              .map((c) => '${c['kind']}:${c['name']}')
              .join('\u0000') ==
          _slashCandidates
              .map((c) => '${c['kind']}:${c['name']}')
              .join('\u0000');
      if (!same) {
        setState(() {
          _fileCandidates = const [];
          _slashCandidates = next;
        });
      }
      return;
    }
    // file 补全：去抖 250ms（searchWorkspaceFiles 是 host 索引查询）
    _fileDebounce?.cancel();
    final query = token.token;
    if (query.isEmpty) {
      setState(() {
        _slashCandidates = const [];
        _fileCandidates = const [];
      });
      return;
    }
    _fileDebounce = Timer(const Duration(milliseconds: 250), () async {
      final app = AppStateScope.of(context);
      final results = await app.searchFiles(query);
      if (!mounted) return;
      final sel = _input.selection;
      final current = activeCompletionToken(
        _input.text,
        cursor: sel.isValid ? sel.baseOffset : null,
      );
      if (current == null || current.type != 'file' || current.token != query) {
        return; // token 已变，丢弃过期结果
      }
      setState(() {
        _slashCandidates = const [];
        _fileCandidates = results;
      });
    });
  }

  void _insertCompletion(String insertion) {
    final text = _input.text;
    // D1-P3-14：token 定位复用 activeCompletionToken 同款语义
    // （页面侧自拼 lastIndexOf(' ') 与函数版漂移——换行前 @token、光标
    // 中位两大差异一并收敛）。
    final sel = _input.selection;
    final cursor = sel.isValid && sel.baseOffset >= 0
        ? sel.baseOffset.clamp(0, text.length)
        : text.length;
    final head = text.substring(0, cursor);
    var replaceFrom = head.length;
    if (head.startsWith('/') && !head.contains(' ')) {
      replaceFrom = 0;
    } else {
      final lastSpace = math.max(head.lastIndexOf(' '), head.lastIndexOf('\n'));
      final token = head.substring(lastSpace + 1);
      if (token.startsWith('@')) replaceFrom = lastSpace + 1;
    }
    // D3-P3-12：子代理插入串 '@name ' 自带尾空格，再统一补
    // 一个='@name  ' 双空格——插入串已带尾空白不重复补。
    final tail = sep(insertion);
    _input.text =
        '${text.substring(0, replaceFrom)}$insertion$tail${text.substring(cursor)}';
    _input.selection = TextSelection.collapsed(
      offset: replaceFrom + insertion.length + tail.length,
    );
    setState(() {
      _slashCandidates = const [];
      _fileCandidates = const [];
    });
  }

  /// 插入补全的收尾分隔（已带尾空格的插入串不重复补）。
  static String sep(String insertion) => insertion.endsWith(' ') ? '' : ' ';

  /// 草稿默认选型（用户 2026-10-18 需求）：新建窗口预选上次使用的
  /// 模型+思考档（prefs 记忆），随 createSession.config 生效。
  bool _draftSeedPending = true;

  void _seedDraftSelection() {
    if (!_draftSeedPending) return;
    _draftSeedPending = false;
    if (_sessionId != null) return;
    final prefs = AppStateScope.of(context).uiPrefs;
    final last = prefs.lastModel;
    if (last != null && last.contains('/')) {
      _pendingModelProvider = last.substring(0, last.indexOf('/'));
      _pendingModelId = last.substring(last.indexOf('/') + 1);
    }
    final t = prefs.lastThought;
    if (t != null && t.isNotEmpty) _pendingThought = t;
  }

  List<PendingAttachment> _restoredAttachments(ComposerDraft saved) => [
    for (var i = 0; i < saved.attachments.length; i++)
      () {
        final a = saved.attachments[i];
        final ref = a.reference;
        return PendingAttachment(
          id: 'restored-${saved.revision}-$i',
          fileName: a.fileName,
          mime: a.mime,
          bytes: Uint8List(0),
          progress: ref == null ? -1 : 1,
          error: ref == null ? '源文件已失效，请重新选择' : null,
          uploaded: ref == null ? null : Map<String, dynamic>.of(ref),
          sourceUnavailable: ref == null,
          persistedByteSize: a.byteSize,
        );
      }(),
  ];

  /// 返回恢复期间是否已有用户编辑。有编辑时合并，不用未水合页面覆盖旧稿。
  bool _applySavedDraft(ComposerDraft saved, {required bool updateController}) {
    final currentText = _draftTextSnapshot;
    final currentAttachments = List<PendingAttachment>.of(_pendingAtts);
    final hadEdits =
        _draftRevision != 0 ||
        currentText.isNotEmpty ||
        currentAttachments.isNotEmpty;
    final mergedText = !hadEdits || currentText.trim().isEmpty
        ? saved.text
        : saved.text.trim().isEmpty || currentText == saved.text
        ? currentText
        : '${saved.text}\n$currentText';
    _draftTextSnapshot = mergedText;
    _unsentDraft ??= saved.unsentText;
    final restored = _restoredAttachments(saved);
    _pendingAtts
      ..clear()
      // 恢复期间新加的附件优先保留；超过 8 个时不静默丢弃，发送门会提示。
      ..addAll([...currentAttachments, ...restored]);
    _draftResultUnknown = saved.submissionInFlight;
    if (saved.submissionInFlight) {
      // 结果未知态以 _submittedDraftText 承载「已提交原文」——确权
      // accepted 要按它清空输入框/草稿，failed 要按它回填（与进程内
      // frame-lost 路径同一表示；旧实现恢复后原文只在输入框，确权成功
      // 仍留在框里，再点发送=对已送达消息重发）。
      _submittedDraftText ??= saved.text;
      _submittedDraftRevision = saved.revision;
    }
    _draftRevision = hadEdits
        ? math.max(saved.revision, _draftRevision) + 1
        : saved.revision;
    if (updateController) {
      _restoringDraft = true;
      try {
        _input.text = mergedText;
        _input.selection = TextSelection.collapsed(offset: mergedText.length);
      } finally {
        _restoringDraft = false;
      }
    }
    return hadEdits;
  }

  Future<void> _restoreDraft() async {
    final app = AppStateScope.of(context);
    final initialSessionId = _sessionId;
    final profile = app.activeProfile;
    final store = app.draftStore;
    // push-first 等待期：身份键优先用目标工作区（此时 activeWorkspace 仍
    // 是旧工作区——用它建身份会把等待期输入/入队全记进错桶）。
    final waitKey = widget.waitForWorkspace;
    final activeWs = app.activeWorkspace;
    final workspaceKey = (waitKey != null && waitKey.isNotEmpty)
        ? waitKey
        : (activeWs == null ? null : workspaceKeyOf(activeWs));
    if (profile == null || workspaceKey == null || store == null) return;
    final accountId = await app.activeDraftAccountId();
    if (accountId == null || initialSessionId != _sessionId) return;
    final identity = initialSessionId == null
        ? DraftIdentity.newDraft(
            deviceSid: profile.deviceSid,
            accountId: accountId,
            workspaceKey: workspaceKey,
            projectId: app.activeProjectId,
          )
        : DraftIdentity.session(
            deviceSid: profile.deviceSid,
            accountId: accountId,
            workspaceKey: workspaceKey,
            sessionId: initialSessionId,
          );
    final identityChanged = identity.key != _draftIdentity?.key;
    _draftIdentity = identity;
    if (identityChanged) {
      // 身份重建（切工作区/换电脑/等待目标工作区就绪）：队列桶键同步
      // 换代——旧实现一次性闩锁后队列照旧读旧桶（跨区排队错绑）。
      unawaited(_refreshQueueEntries(app));
    }
    final saved = await store.read(identity);
    if (identity.key != _draftIdentity?.key) return;
    if (saved == null) {
      if (_draftRevision != 0 ||
          _draftTextSnapshot.isNotEmpty ||
          _pendingAtts.isNotEmpty) {
        await _saveDraft();
        if (!mounted) await store.flush();
      }
      return;
    }
    final hadEdits = _applySavedDraft(saved, updateController: mounted);
    if (mounted) {
      setState(() {});
      unawaited(_scheduleAttachmentValidation(reset: true));
    }
    if (hadEdits || !mounted) {
      await _saveDraft();
      if (!mounted) await store.flush();
    }
  }

  /// 草稿身份恢复的驱动（可重算）：目标工作区键变化（切工作区/换电脑/
  /// push-first 等待完成）时重建身份并重跑恢复；profile/工作区未就绪的
  /// 早退不闩死——下一次 app 通知（didChangeDependencies）继续重试。
  /// 队列桶由身份派生，身份换代时 `_restoreDraft` 内同步刷新。
  void _scheduleDraftRestore() {
    final app = _appRef;
    if (app == null) return;
    if (_draftRestoreInFlight) {
      _draftRestoreAgain = true;
      return;
    }
    final profile = app.activeProfile;
    final waitKey = widget.waitForWorkspace;
    final activeWs = app.activeWorkspace;
    final targetKey = (waitKey != null && waitKey.isNotEmpty)
        ? waitKey
        : (activeWs == null ? null : workspaceKeyOf(activeWs));
    if (profile == null || targetKey == null) return;
    final current = _draftIdentity;
    if (current != null &&
        current.deviceSid == profile.deviceSid &&
        current.workspaceKey == targetKey) {
      return; // 身份已就绪且目标未变
    }
    _draftRestoreInFlight = true;
    _draftRestoreFuture = _restoreDraft().whenComplete(() {
      _draftRestoreInFlight = false;
      if (_draftRestoreAgain) {
        _draftRestoreAgain = false;
        _scheduleDraftRestore();
      }
    });
  }

  Future<void> _scheduleAttachmentValidation({bool reset = false}) async {
    if (reset) _attLastValidationVersion = -1;
    final version = _sub?.state.dataVersion ?? 0;
    if (_attLastValidationVersion >= 0 &&
        version - _attLastValidationVersion < 5) {
      return;
    }
    _attLastValidationVersion = version;
    await _validateRestoredAttachments();
  }

  Future<void> _validateRestoredAttachments() async {
    final sessionId = _sessionId;
    final app = _appRef;
    if (sessionId == null || app == null) return;
    final restored = _pendingAtts
        .where((a) => a.uploaded != null && a.bytes.isEmpty)
        .toList();
    for (final attachment in restored) {
      final ref = '${attachment.uploaded!['ref'] ?? ''}';
      if (ref.isEmpty) continue;
      try {
        final result = await app.attachmentRead(sessionId, ref);
        // A1-P3-11/A3-P3-3/D3-P2-7：附件被移除只该跳过本项
        // ——旧 return 中止整轮，剩余恢复附件的失效检测要等下轮
        // dataVersion 闸（≥5）才补。
        if (!mounted) return;
        if (!_pendingAtts.contains(attachment)) continue;
        attachment.bytes = Uint8List.fromList(result.bytes);
      } catch (error) {
        if (!mounted) return;
        if (!_pendingAtts.contains(attachment)) continue;
        final reason = '$error'.toLowerCase();
        if (reason.contains('not found') ||
            reason.contains('missing') ||
            reason.contains('invalid') ||
            reason.contains('expired') ||
            reason.contains('unauthorized')) {
          attachment.sourceUnavailable = true;
          attachment.error = '附件引用已失效，请重新选择';
          setState(() {});
          await _saveDraft();
        }
      }
    }
    if (mounted) setState(() {});
  }

  void _onDraftMutated() {
    if (!mounted || _restoringDraft || _suppressDraftSync) return;
    _draftRevision++;
    unawaited(_saveDraft());
  }

  Future<void> _saveDraft() async {
    final store = _appRef?.draftStore;
    final identity = _draftIdentity;
    if (store == null || identity == null) return;
    final visibleText = _draftTextSnapshot;
    final text = visibleText.trim().isEmpty && _submittedDraftText != null
        ? _submittedDraftText!
        : visibleText;
    await store.save(
      ComposerDraft(
        identity: identity,
        text: text,
        unsentText: _unsentDraft,
        attachments: [
          for (final a in _pendingAtts)
            DraftAttachment(
              fileName: a.fileName,
              mime: a.mime,
              byteSize: a.effectiveByteSize,
              reference: a.uploaded == null
                  ? null
                  : {
                      'ref': '${a.uploaded!['ref'] ?? ''}',
                      'fileName': '${a.uploaded!['fileName'] ?? a.fileName}',
                      'mime': '${a.uploaded!['mime'] ?? a.mime}',
                      'bytes':
                          intOf(a.uploaded!['bytes']) ?? a.effectiveByteSize,
                    },
            ),
        ],
        updatedAt: DateTime.now().millisecondsSinceEpoch,
        revision: _draftRevision,
        submissionInFlight: _submittedDraftText != null,
      ),
    );
  }

  Future<void> _promoteDraftToSession(String sessionId) async {
    final store = _appRef?.draftStore;
    final previous = _draftIdentity;
    if (store == null || previous == null) return;
    final next = previous.forSession(sessionId);
    if (next.key == previous.key) return;
    final sourceRevision = _draftRevision;
    _draftIdentity = next;
    await _saveDraft();
    await store.delete(previous, expectedRevision: sourceRevision);
  }

  Future<void> _finishDraftSubmission() async {
    final submittedRevision = _submittedDraftRevision;
    _submittedDraftText = null;
    _draftResultUnknown = false;
    final store = _appRef?.draftStore;
    final identity = _draftIdentity;
    if (store == null || identity == null) return;
    if (!mounted) {
      await store.delete(identity, expectedRevision: submittedRevision);
      return;
    }
    if (_draftRevision == submittedRevision &&
        _draftTextSnapshot.trim().isEmpty &&
        (_unsentDraft?.trim().isEmpty ?? true)) {
      await store.delete(identity, expectedRevision: submittedRevision);
    } else {
      await _saveDraft();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ownRoute ??= ModalRoute.of(context);
    _seedDraftSelection();
    if (!widget.readOnly) {
      _appRef = AppStateScope.of(context);
      _scheduleDraftRestore();
    }
    if (_initialSubscribePending) {
      _initialSubscribePending = false;
      _subscribe(widget.sessionId!);
    }
    _armSendQueueWatch();
    // 批3：切电脑后本页属旧电脑——app 通知同样驱动自动退出（旧实现
    // 只在会话流通知里检查；切电脑时旧订阅可能已静默=页面不退出）。
    _maybeExitForDeviceSwitch();
  }

  /// 断网消息排队（6.6②）：app 状态变化（桥恢复/断连）驱动队列刷新与
  /// 自动发出；首挂即读一次（重启后队列在场且已连接则直接补发）。
  /// 三轮审查 B2 L1：只读页在解析 scope 之前先返回（HEAD 同款——
  /// 避免任何 scope 外挂载的只读页在此抛空指针）。
  void _armSendQueueWatch() {
    if (widget.readOnly) return;
    _queue.arm(AppStateScope.of(context), draftRestore: _draftRestoreFuture);
  }

  @override
  void dispose() {
    // 滚动记忆兜底（正常路径在每次滚动静止落点已 upsert——dispose 时
    // 树拆除中 hasClients 常为 false，实证踩坑）。
    _saveScrollMemory();
    unawaited(_appRef?.draftStore?.flush());
    // 通知查看中抑制解除（仅当仍是本会话——快速切换时新页面已改写）。
    final app = _appRef;
    if (app != null &&
        _sessionId != null &&
        app.viewingSessionId == _sessionId) {
      app.viewingSessionId = null;
    }
    _queue.dispose();
    // A5：页面关闭即取消查看态上报（best-effort，栈还活着才发得出）。
    // 归属校验（#16）：子会话页退出动画晚于父页接回——父页已重报
    // 自己时（viewingSessionId 已指向别人）不得再把查看态清成 null。
    final closedSid = _sessionId;
    if (closedSid != null && closedSid.isNotEmpty) {
      final appRef = _appRef;
      if (appRef != null &&
          (appRef.viewingSessionId == null ||
              appRef.viewingSessionId == closedSid)) {
        appRef.reportTaskView(null);
      }
    }
    _input.removeListener(_onInputChanged);
    _input.dispose();
    _inputFocusNode.dispose();
    _scroll.dispose();
    _search.dispose();
    _fileDebounce?.cancel();
    _followTick?.cancel();
    _planEchoTimer?.cancel();
    _sidPopRetry?.cancel();
    _renderThrottle?.cancel();
    _searchRefreshTrail?.cancel();
    _searchChangeDebounce?.cancel();
    _sub?.state.removeListener(_onStateChanged);
    _listenedState?.removeListener(_onStateChanged);
    super.dispose();
  }

  /// A5 超时兜底：乐观写回被跳过（快照未就绪）且 config 回显迟迟未到
  /// 时，挂起值退位给 config 当前值——不让用户切换永驻挂起态。
  void _armPlanEchoFallback() {
    _planEchoTimer?.cancel();
    _planEchoTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted || _pendingPlan == null) return;
      setState(() => _pendingPlan = null);
    });
  }

  /// 批3（multi-account-ux-1）：本会话页所属电脑——切电脑后 push 进来
  /// 的旧电脑会话必须自动退出（否则对旧栈订阅会失败且用户看到"假死"）。
  String? _ownerDeviceSid;
  bool _sidPopScheduled = false;

  /// 切电脑自动退出的一次性修复：_ownerDeviceSid 只在 pop 真正执行后
  /// 推进——旧实现先把 owner 改成新电脑再看能否 pop，被弹层/子页压顶
  /// （isTop=false）的那一帧 pop 不执行后，待退出标记永久丢失。
  Timer? _sidPopRetry;

  /// 切电脑后退出本页（push 场景）。嵌入宽屏（根路由不可 pop）按已
  /// 接管处理，右栏清空由任务中心负责；被弹层/子页压顶时保留待退标记，
  /// 500ms 后重试直到路由恢复栈顶。
  void _maybeExitForDeviceSwitch() {
    final nowSid = _appRef?.activeProfile?.deviceSid;
    final owner = _ownerDeviceSid;
    if (owner == null || nowSid == null || nowSid == owner) {
      _sidPopRetry?.cancel();
      _sidPopRetry = null;
      return;
    }
    if (_sidPopScheduled) return;
    _sidPopScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sidPopScheduled = false;
      if (!mounted) return;
      final nav = Navigator.maybeOf(context);
      final isTop = _ownRoute?.isCurrent ?? false;
      if (nav != null && nav.canPop() && isTop) {
        nav.pop();
        _ownerDeviceSid = nowSid;
        _sidPopRetry?.cancel();
        _sidPopRetry = null;
        return;
      }
      if (nav == null || !nav.canPop()) {
        // 嵌入/根路由：不可 pop（右栏清空由父页面处理），按已接管收口。
        _ownerDeviceSid = nowSid;
        _sidPopRetry?.cancel();
        _sidPopRetry = null;
        return;
      }
      // 被弹层/子页压顶：保留待退标记，路由恢复栈顶后再试。
      _sidPopRetry?.cancel();
      _sidPopRetry = Timer(const Duration(milliseconds: 500), () {
        _sidPopRetry = null;
        if (mounted) _maybeExitForDeviceSwitch();
      });
    });
  }

  /// 本页路由引用（ P2-2）：跨电脑自动退出必须确认**本页仍是
  /// 栈顶**再 pop——此前只查 canPop（=栈里有>1 路由），设置页/子会话
  /// 页/弹层压顶时会关错页面。didChangeDependencies 是 dependOnInherited
  /// 的合法调用点（build 阶段族）。
  ModalRoute<Object?>? _ownRoute;
  Future<void> _subscribe(String sessionId) async {
    final app = AppStateScope.of(context);
    _appRef = app;
    _ownerDeviceSid ??= app.activeProfile?.deviceSid;
    app.viewingSessionId = sessionId;
    _openStopwatch
      ..reset()
      ..start();
    // 1.0.1 真机验收⑤A：跨区 push-first——等待目标工作区就绪（键匹配
    // 且桥在场）再订阅；切换失败（workspaceError）/超时走错误态可重试。
    // 对抗审查高②：等待循环的 throw 原在 try 外（_subscribe 是
    // fire-and-forget，异常被 PlatformDispatcher 吞→页面永久转圈）。
    // 收进本 try-catch，走 _syncError 错误态+重试按钮。
    final waitKey = widget.waitForWorkspace;
    if (waitKey != null && waitKey.isNotEmpty) {
      try {
        final deadline =
            DateTime.now().add(ConversationPage.waitForWorkspaceTimeout);
        while (!mounted ||
            workspaceKeyOf(app.activeWorkspace ?? const {}) != waitKey ||
            app.bridge == null) {
          if (!mounted) return;
          if (app.workspaceError != null) {
            throw StateError('工作区切换未完成，请稍后重试');
          }
          if (DateTime.now().isAfter(deadline)) {
            throw TimeoutException('等待工作区就绪超时');
          }
          final route = _ownRoute;
          // 路由"出栈"才放弃等待——isCurrent=false 可能只是被弹层/子页
          // 压顶（旧实现直接 return=等待永久中止，页面停在转圈态）。
          if (route != null && !route.isActive) return;
          if (!_waitingWorkspace) setState(() => _waitingWorkspace = true);
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        if (_waitingWorkspace && mounted) {
          setState(() => _waitingWorkspace = false);
        }
      } on Object catch (e) {
        if (!mounted) return;
        // 对抗审查遗留核实修（2026-11-07）：等待超时/切换失败时，首页
        // 仍挂着 keepHomePreview 保住的旧工作区列表——本页已判死，旧
        // 列表不能再以可用状态示人；与 task_center 失败路径同语义
        // （clearStaleHomePreview 幂等，双清无害）。
        app.clearStaleHomePreview();
        // 失败必须可见（旧实现只写 _syncError，loading 视图只认 _error
        // ——用户永远停在「正在载入对话历史…」且没有重试钮）。
        final friendly = e is TimeoutException
            ? tr('打开工作区超时，请稍后重试')
            : humanizeError(e);
        setState(() {
          _syncError = friendly;
          _error = friendly;
          _waitingWorkspace = false;
        });
        return;
      }
    }
    // 缓存首帧（2026-11-05 反馈②C）：同文件只读一次——条目先供预渲、
    // 再作订阅种子传入（此前页面与 ensureConversation 各读各的=同文件
    // 双读/双解码，均在主 isolate）。
    final cacheEntry = await _readCacheEntry(app, sessionId);
    unawaited(_applyCachePreview(cacheEntry));
    try {
      final sub = await app
          .ensureConversation(sessionId, seedCacheEntry: cacheEntry)
          .timeout(
            widget.subscribeTimeout == null
                ? (widget.readOnly
                      ? const Duration(seconds: 180)
                      : const Duration(seconds: 60))
                : (widget.readOnly
                      ? widget.subscribeTimeout! * 3
                      : widget.subscribeTimeout!),
            onTimeout: () {
              // B1（2026-10-16 夜，间歇竞态结构免疫）：ensure 链在负载下偶发
              // wedge（页面 await 不复活，而订阅经自愈路径已 ready——真机
              // "永远正在载入"实测 3/3）。超时兜底：直捞缓存活订阅；没有
              // 才把超时抛给页面错误态（可重试）。
              final recovered = app.conversationSubscriptionOf(sessionId);
              if (recovered != null) return recovered;
              throw TimeoutException('ensureConversation timeout');
            },
          );
      if (!mounted) return;
      // 订阅成功即清错误专档（旧错误不再经 strip 显形）。
      setState(() {
        _sub = sub;
        _syncError = null;
      });
      if (sub.state.ready && !sub.hasLiveFrames && !_perfContentLoaded) {
        _perfContentLoaded = true;
        debugPrint(
          '[perf] conv_first_content src=seed rows=${sub.state.rows.length} '
          'ms=${_openStopwatch.elapsedMilliseconds}',
        );
      }
      // A1-P2-1/A2-P3-3/A3-P2-1：按实例配对——ensureConversation
      // 对同一 sid 返回同一驻留实例，重试路径二次 addListener 会注册
      // 双份监听（40ms 节流被翻倍架空 + dispose 只摘一份=已 dispose 的
      // 整页 State 被驻留 notifier 钉在内存）。先摘旧监听再挂新。
      _listenedState?.removeListener(_onStateChanged);
      sub.state.addListener(_onStateChanged);
      _listenedState = sub.state;
      unawaited(_scheduleAttachmentValidation(reset: true));
      // 打开会话一律先粘底（F2 真机反馈）：空闲历史会话若不粘底，首帧
      // jump 时快照未到（maxScrollExtent=0 即顶部），快照到达后监听器又因
      // stick=false 早退——页面停在顶部，用户需手动下划。粘底后用户上滚
      // 超过 120px 才解除（监听器语义不变）。
      // 阶段 3 补修（介入点 1 用户实锤"不粘底"）：缓存种子让内容先于任何
      // 状态通知渲染——原靠数据通知触发的 followUntilStable 修正循环（治
      // 懒列表 extent 估算偏差）不再被触发。初始落位必须自带修正循环。
      // A1-P2/A3-P1：缓存预渲已还原过非贴底记忆时不翻粘底
      //（否则温重开的阅读位置必被跳底覆盖）；live 快照比预渲确有新
      // 输出（离开期间会话推进）时仍贴底。
      final preview = _cachePreview;
      final hasNewOutput =
          preview != null &&
          (sub.state.seq > preview.seq ||
              sub.state.rows.length > preview.rows.length);
      if (hasNewOutput || !_memoryRestored || _stickToBottom) {
        _stickToBottom = true;
      }
      _snapToBottom();
    } catch (e) {
      // 18075 验收 C（子代理下钻）：lineage-invalid=子会话工作目录≠父任务
      // 根目录（如 refs/app 子目录），3.16.x CLI 订阅校验拒绝且重试必然
      // 循环失败——人话化；3.17 虽重写解析区，但严格 path 等价校验仍在，
      // refs/app 子目录场景升级后仍可能被拒（对抗审查 D6b 源码复核）。
      // 三轮审查 A1/D1：新增三类内部 StateError 的人话映射——不再把
      // 「Bad state:」英文前缀裸给用户，桥自建场景也不再误称"已切换"。
      final raw = '$e';
      final friendly = raw.contains('session-lineage-invalid')
          ? tr('该会话归属其他项目目录，当前桌面版本无法从手机打开')
          : raw.contains('会话订阅已重置')
          ? tr('正在切换电脑或工作区，请稍后重试')
          : raw.contains('no active workspace')
          ? tr('工作区尚未打开，请稍后重试')
          : raw.contains('computer stack disposed')
          ? tr('电脑连接已关闭，请重新连接')
          : '订阅会话失败：$e';
      if (mounted) {
        // 双写（ A2-P3-1）：loading 态照旧消费 _error；strip 只
        // 认订阅专档 _syncError——发送/停止失败不再被误标「同步失败」。
        setState(() {
          _error = friendly;
          _syncError = friendly;
        });
      }
    }
  }

  /// 缓存条目单次读取（2026-11-05 反馈②C：预渲与订阅种子共用）。
  Future<SessionCacheEntry?> _readCacheEntry(
    AppState app,
    String sessionId,
  ) async {
    try {
      return await app.readSessionCache(sessionId);
    } on Object {
      return null; // 缓存读取失败=无缓存，不干扰订阅路径
    }
  }

  /// 缓存预渲应用（读本地文件，快照到达前有效）。对账语义：
  /// live ready → 缓存条目使命结束（logEpoch 不一致=历史重写，本地条目
  /// 由下次一致水位落盘整体覆盖——见 cache_policy.reconcileSessionCache）。
  Future<void> _applyCachePreview(SessionCacheEntry? entry) async {
    if (!mounted || entry == null || entry.rows.isEmpty) return;
    final live = _sub?.state;
    if (live != null && live.ready) return;
    if (_cachePreview != null) return;
    final preview = ConversationState();
    // 预渲层清洗陈旧审批（订阅种子不清洗——官方水位不变量，见
    // ConversationSeed 注释；两者用途不同）。
    final control = entry.snapshotControl == null
        ? null
        : Map<String, dynamic>.of(entry.snapshotControl!);
    if (control != null) control['pendingInteractions'] = const [];
    preview.snapshot = control;
    preview.rows = entry.rows;
    preview.logEpoch = entry.logEpoch;
    preview.seq = entry.lastSeq;
    preview.firstRowId = entry.firstRowId;
    preview.totalCount = entry.totalCount;
    preview.ready = true;
    preview.historyExhausted = true; // 缓存视图无传输层，不给"加载更早"
    setState(() => _cachePreview = preview);
    if (!_perfContentLoaded) {
      _perfContentLoaded = true;
      debugPrint(
        '[perf] conv_first_content src=cache rows=${entry.rows.length} '
        'ms=${_openStopwatch.elapsedMilliseconds}',
      );
    }
    _snapToBottom();
  }

  /// 流式渲染节流（优化批 #8）：流式期 ConversationState 每帧 notify，无条件整页重建=全部可见条目重建+每个
  /// MarkdownBody 全文重解析。两级节流：①页面级 40ms 合帧（窗口首次通知立即渲染，窗口内后续通知
  /// 合并为一次尾沿 setState）；②稳定行渲染缓存 CachedContent（正文未变则整棵子树短路）。审批横幅等
  /// 交互态时效不受损——每个窗口的首次通知都是即时渲染。
  Timer? _renderThrottle;
  bool _renderPending = false;
  static const Duration _renderThrottleWindow = Duration(milliseconds: 40);

  /// 搜索索引刷新节流（ A2-P3-10）：流式期 500ms 上限+尾沿补跳。
  DateTime? _searchRefreshAt;
  Timer? _searchRefreshTrail;

  void _onStateChanged() {
    if (_renderThrottle != null && _renderThrottle!.isActive) {
      _renderPending = true; // 合并到当前窗口尾沿
      return;
    }
    _doRender(); // 窗口首次通知立即渲染
    _renderThrottle = Timer(_renderThrottleWindow, () {
      if (_renderPending) {
        _renderPending = false;
        _doRender();
      }
    });
  }

  void _doRender() {
    if (!mounted) return;
    // 批3：切电脑后本页属旧电脑——push 场景自动退出（嵌入宽屏由父页面
    // 清右栏，不在此 pop）。
    _maybeExitForDeviceSwitch();
    // 无条件 setState——chrome 层（审批横幅/排队条/停止键/用量
    // 条/appbar 状态）全靠页面重建；旧的"非粘底早退"会让上滑回看历史时
    // 审批横幅永不出现、回合结束后运行态残留。
    final state = _sub?.state;
    // A5 水位式清理（2026-10-24 修复批）：仅当 config 回显与挂起计划值
    // 一致才清挂起——禁"patch 到达即清"（旧回显/桌面端外部改档的 patch
    // 值不同，到达即清会把在途挂起误杀，手机自切档闪烁竞态）。
    final cfgPlan = state?.config?['planEnabled'];
    if (_pendingPlan != null && cfgPlan is bool && cfgPlan == _pendingPlan) {
      _pendingPlan = null;
      _planEchoTimer?.cancel();
    }
    if (state != null && state.ready && state.rows.isNotEmpty) {
      if (_cachePreview != null) _cachePreview = null;
      if (!_perfContentLoaded) {
        _perfContentLoaded = true;
        debugPrint(
          '[perf] conv_first_content src=live rows=${state.rows.length} '
          'ms=${_openStopwatch.elapsedMilliseconds}',
        );
      }
      if (_sub?.hasLiveFrames == true && !_perfLiveLogged) {
        _perfLiveLogged = true;
        debugPrint(
          '[perf] conv_live_frames ms=${_openStopwatch.elapsedMilliseconds}',
        );
      }
      // 两步式深链：行就绪后下一帧弹「定位到相关消息？」（只弹一次；
      // 未尝试前每帧最多排一个回调，尝试后不再排——见 _maybePromptDeepLink）。
      if (!_deepLinkPromptShown) {
        ConversationPage.debugDeepLinkScheduleCount++;
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => _maybePromptDeepLink(),
        );
      }
    }
    if (state != null &&
        state.ready &&
        _pendingAtts.any(
          (a) => a.uploaded != null && a.bytes.isEmpty && !a.sourceUnavailable,
        )) {
      unawaited(_scheduleAttachmentValidation());
    }
    if (_searchOpen && state != null) {
      // A2-P3-10/D3-P2-4：流式期每 40ms 合帧都全量重建搜索
      // 索引（O(rows×文本)）——搜索刷新自身加宽到 500ms 节流+尾沿补一
      // 次（渲染节流不变；计数最多滞后半秒）。
      final now = DateTime.now();
      if (_searchRefreshAt == null ||
          now.difference(_searchRefreshAt!) >=
              const Duration(milliseconds: 500)) {
        _searchRefreshAt = now;
        _searchRefreshTrail?.cancel();
        _refreshConversationSearch();
        unawaited(_pumpSearchHistory());
      } else {
        _searchRefreshTrail?.cancel();
        _searchRefreshTrail = Timer(const Duration(milliseconds: 500), () {
          if (!mounted || !_searchOpen) return;
          _searchRefreshAt = DateTime.now();
          _refreshConversationSearch();
          unawaited(_pumpSearchHistory());
        });
      }
    }
    setState(() {});
    if (!_stickToBottom) return;
    // 粘底跟随改 jump（animate 180ms 在长列表真机上输给布局增长）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || !_stickToBottom) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
    _followUntilStable();
  }

  /// 粘底跟随窗口：连续 12 帧（约 1.2s）内反复贴底，抗布局抖动。
  void _followUntilStable() {
    _followFrames = 12;
    _followTick?.cancel();
    _followTick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted || !_stickToBottom || _followFrames <= 0) {
        _followTick?.cancel();
        return;
      }
      _followFrames--;
      if (_scroll.hasClients) {
        final max = _scroll.position.maxScrollExtent;
        if ((max - _scroll.offset) > 1) {
          _markProgrammatic();
          _scroll.jumpTo(max);
        }
      }
    });
  }

  int _followFrames = 0;
  Timer? _followTick;

  /// 程序化滚动豁免（官方 markProgrammaticScroll 同义，2026-10-26 对齐
  /// 批 C）：我们自己的 jumpTo 也会产生 ScrollEnd——豁免计数内不参与
  /// 落点裁决。帧驱动计数而非时间窗：widget 测试的 fake_async 不劫持
  /// DateTime.now（墙钟不走，时间窗在测试里永久——批 C 实证踩坑）。
  int _programmaticScrollEndSkips = 0;

  /// 回合定位期间的布局通知守卫：center 切换使 max/min 同时变化，不能把
  /// “新坐标系里恰好距底 ≤48”误读为用户主动回底（官方 layoutScrollGuard）。
  int _followingReconcileGuard = 0;

  /// 会话滚动记忆（官方 chatSessionScrollMemory 内存 Map 同义，上限
  /// 200 条）：dispose 存 {稳定 center key, 绝对 offset（锚定还原后
  /// clamp 校正——非相对锚偏移， A1-P3-9 勘正注释）, 是否贴底}，
  /// 重进先恢复锚点再恢复位置——前插过历史后裸像素不再冒充绝对坐标。
  static const _scrollMemoryMax = 200;
  static final _scrollMemory = <String,
          (String? centerKey, double offset, bool pinned,
              int savedAtMs)>{};

  /// 滚动记忆 5 分钟过期（验收⑧）：隔了一阵再打开旧对话直接跳底看最新
  /// 消息；仅同一使用会话内的对话切换保留阅读位置。
  static const _scrollMemoryTtlMs = 5 * 60 * 1000;
  (String?, double, bool)? _scrollMemoryOf(String? sid) {
    if (sid == null || sid.isEmpty) return null;
    final m = _scrollMemory[sid];
    if (m == null) return null;
    if (DateTime.now().millisecondsSinceEpoch - m.$4 >
        _scrollMemoryTtlMs) {
      return null;
    }
    return (m.$1, m.$2, m.$3);
  }


  /// C6：上次构建的键盘 inset（变化检测）。
  double _lastInsetBottom = -1;

  // ── 6.2 选分支：顶栏分支标签（工作区级 git 状态，通道放行实证见
  //    git_branch_service.dart 头注）─────────────────────────────
  /// 缓存键=活跃工作区键（workspaceKeyOf 同款键序；换桥/切工作区即重拉，
  /// draft 页在 switchToProject 完成后进入，拿到的已是新工作区）。
  String? _branchCacheKey;
  String? _branchCurrent;

  void _maybeLoadBranchInfo(AppState app) {
    final ws = app.activeWorkspace;
    final key = ws == null ? null : workspaceKeyOf(ws);
    if (key == null || key == _branchCacheKey) return;
    _branchCacheKey = key;
    _branchCurrent = null;
    final workspacePath = '${ws?['workspacePath'] ?? key}';
    app
        .gitChannelCall('getWorkspaceRepositoryInfo', [
          {'workspacePath': workspacePath},
        ])
        .then((info) {
          final overview = parseGitOverview(info is Map ? info : null, null);
          if (!overview.isRepository) return null;
          return app.gitChannelCall('getLocalBranches', [
            {'workspacePath': workspacePath},
          ]);
        })
        .then((list) {
          if (!mounted || list is! Map) return;
          // 完成时可能已切工作区/电脑（竞态）——key 失配丢弃。
          if (workspaceKeyOf(
                AppStateScope.of(context).activeWorkspace ?? const {},
              ) !=
              key) {
            return;
          }
          setState(() {
            _branchCurrent = list['currentBranchName'] is String
                ? list['currentBranchName'] as String?
                : null;
          });
        })
        .catchError((Object e) {
          // 分支标签是锦上添花：静默（桥降级/超时），不打扰会话主路径。
          debugPrint('[branch] load skipped: $e');
        });
  }

  Future<void> _openBranchSheet(AppState app) async {
    final ws = app.activeWorkspace;
    if (ws == null) return;
    final key = workspaceKeyOf(ws);
    if (key == null) return;
    final workspacePath = '${ws['workspacePath'] ?? key}';
    final workspaceLabel = '${ws['label'] ?? workspacePath}'.trim();
    // 全局生效守卫数据：该工作区运行中任务数（readTree 全集跨目录）。
    var running = 0;
    for (final t in app.projectTasks) {
      if (taskWorkspaceKey(t) != key) continue;
      if (isRunningPhase(
        normalizePhase('${t['displayStatus'] ?? t['status'] ?? ''}'),
      )) {
        running++;
      }
    }
    await showBranchSheet(
      context,
      call: app.gitChannelCall,
      workspacePath: workspacePath,
      workspaceLabel: workspaceLabel.isEmpty ? '当前工作区' : workspaceLabel,
      runningTaskCount: running,
      onChanged: (current) {
        if (!mounted || current == null) return;
        setState(() => _branchCurrent = current);
      },
    );
  }

  void _scrollToBottom() {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (shouldMarkProgrammaticScroll(_scroll.position.pixels, target)) {
        _markProgrammatic();
      }
      _scroll.jumpTo(target);
    });
  }

  bool _inProgrammaticWindow() => _programmaticScrollEndSkips > 0;

  /// 滚动记忆 upsert（官方 chatSessionScrollMemory 持续保存语义：每次
  /// 静止落点更新——不依赖退出时机）。 A2-P3-5：remove+assign
  /// 重排到插入序尾——高频使用的老会话不再比闲置新会话更易被逐出
  /// （LinkedHashMap 对既有 key 赋值不改变位次=按插入序逐出）。
  void _saveScrollMemory() {
    final sid = _sessionId;
    if (sid == null || sid.isEmpty || !_scroll.hasClients) return;
    final existed = _scrollMemory.remove(sid);
    if (existed == null &&
        _scrollMemory.length >= _scrollMemoryMax) {
      _scrollMemory.remove(_scrollMemory.keys.first);
    }
    _scrollMemory[sid] = (
      _listCenterItemKey,
      _scroll.offset,
      _stickToBottom || _scroll.position.maxScrollExtent - _scroll.offset <= 48,
      DateTime.now().millisecondsSinceEpoch,
    );
  }

  void _markProgrammatic() => _programmaticScrollEndSkips++;

  /// 初始落位到最底（阶段 3）：jump 一次不够——懒加载长列表的
  /// maxScrollExtent 是估算值，首跳常落在半路；followUntilStable 的
  /// 多帧修正循环原来只由数据通知触发，缓存路径没有通知，必须自带。
  ///
  /// 滚动记忆优先（2026-10-26 对齐批 C，官方 wasPinnedToBottom 语义）：
  /// 上次离开时非贴底 → 还原静止位置（clamp 新 max，懒 extent 两次
  /// 校正）且不粘底；贴底/无记忆 → 默认吸底。
  bool _memoryRestored = false;
  void _snapToBottom() {
    if (!_memoryRestored) {
      _memoryRestored = true;
      final sid = _sessionId;
      final m = _scrollMemoryOf(sid);
      if (m != null && !m.$3) {
        _stickToBottom = false;
        _listCenterItemKey = m.$1 ?? _listCenterItemKey;
        // 直接赋值发生在缓存 setState 之后——不补一次重建则 FAB 块
        // （条件含 !_stickToBottom）永不重算（批 C 实证踩坑）。
        setState(() {});
        _restoreOffset(m.$2);
        return;
      }
    } else if (!_stickToBottom) {
      // A1-P2/A3-P1（温重开还原必被覆盖）：还原过的非贴底
      // 记忆不被第二个触发源（live ready / 慢预渲）的跳底+1.2s 粘底
      // 跟随覆盖——阅读位置保持；后续新输出由既有落点回吸语义承接
      //（用户滚到底 48px 内恢复跟随，_doRender 的 stick 门不变）。
      // 补充（position 重建）：live ready 使 cache-sync strip 退场，
      // 消息列表在无 key 的 Column children 中上移一位=Element 重建、
      // Scrollable position 复位 0——重放一次记忆校正把阅读位置接回。
      final sid = _sessionId;
      final m = _scrollMemoryOf(sid);
      if (m != null && !m.$3) {
        _listCenterItemKey = m.$1 ?? _listCenterItemKey;
        setState(() {});
        _restoreOffset(m.$2);
      }
      return;
    }
    _jumpToBottom();
    _followUntilStable();
  }

  /// 记忆位置还原：等 Scrollable attach（restore 发生在缓存 setState 同
  /// 步链内，列表下一帧才挂——定时首试会扑空，批 C 实证踩坑）；随后
  /// 50ms/300ms 两次 clamp 校正（懒列表 extent 首帧估算偏小；单次失败
  /// 不终止——下轮再试）。
  Future<void> _restoreOffset(double target) async {
    for (var i = 0; i < 20 && mounted && !_scroll.hasClients; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    for (final delay in const [
      Duration(milliseconds: 50),
      Duration(milliseconds: 300),
    ]) {
      await Future<void>.delayed(delay);
      // A1-P3-10：校正跳前查用户接管——300ms 窗口内点 FAB 回底
      // （_stickToBottom 已翻真）时不再把视口拽回记忆位置（视觉抖动）。
      if (!mounted || !_scroll.hasClients || _stickToBottom) continue;
      final targetPos = target.clamp(
        _scroll.position.minScrollExtent,
        _scroll.position.maxScrollExtent,
      );
      if (shouldMarkProgrammaticScroll(_scroll.position.pixels, targetPos)) {
        _markProgrammatic();
        _scroll.jumpTo(targetPos);
      }
    }
  }

  // ------------------------------------------------------ 附件上传

  /// 常见扩展名 → mime（file_picker 只给扩展名；官方 begin schema 要求
  /// type/subtype 结构，mime 影响预览授权面）。
  static String _mimeOfExtension(String ext) => switch (ext.toLowerCase()) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'bmp' => 'image/bmp',
    'heic' => 'image/heic',
    'mp4' => 'video/mp4',
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    'pdf' => 'application/pdf',
    'txt' || 'md' || 'log' => 'text/plain',
    'json' => 'application/json',
    'csv' => 'text/csv',
    'html' || 'htm' => 'text/html',
    'zip' => 'application/zip',
    _ => 'application/octet-stream',
  };

  /// 添加宫格「附件文件」：系统选择器多选 + 官方边界（8 个/单文件 20MB/
  /// 无类型限制）。部分厂商机型压缩路径有崩溃前科（ 批调研），依赖
  /// 默认 compressionQuality=0 不压缩。
  /// 语音输入（2026-10-20 交互定稿）：面板内预览可编辑（含整理结果
  /// 状态行与"用原文"切换）→ 用户点发送直接走发送链路（复用手动发送
  /// 同一条路，不再进输入框绕一圈；整理成功/失败在面板内可见）。
  Future<void> _startVoiceInput() async {
    // 面板先顶上来（2026-10-23 真机反馈"输入法与语音面板互相覆盖"）：
    // 主输入法先收起，听写阶段面板独占；预览编辑聚焦时由
    // showVoiceInputSheet 的 viewInsets 垫高避让键盘。
    FocusManager.instance.primaryFocus?.unfocus();
    await showVoiceInputSheet(
      context,
      onSend: (text) {
        if (!mounted) return;
        unawaited(_sendText(text));
      },
    );
  }

  Future<void> _pickAttachments() async {
    final messenger = ScaffoldMessenger.of(context);
    List<PlatformFile> files;
    try {
      files = await (ConversationPage.debugPickFiles?.call() ??
          FilePicker.pickFiles());
    } catch (_) {
      // 等待期可能已退页：用守卫后的 messenger，不再取 context。
      if (mounted) {
        messenger.showSnackBar(const SnackBar(content: Text('文件选择器不可用')));
      }
      return;
    }
    if (!mounted || files.isEmpty) return;
    var added = 0;
    for (final f in files) {
      if (_pendingAtts.length >= kMaxChatAttachments) {
        messenger.showSnackBar(
          SnackBar(content: Text('最多 $kMaxChatAttachments 个附件')),
        );
        break;
      }
      // 先按选择器已知大小拦截超限，再读字节（避免大文件整读进内存）。
      final knownLen = f.lengthSync();
      if (knownLen != null && knownLen > kAttachmentMaxBytes) {
        messenger.showSnackBar(
          SnackBar(content: Text('「${f.name}」超过 20MB 上限')),
        );
        continue;
      }
      final Uint8List bytes;
      try {
        bytes = await f.readAsBytes();
      } catch (_) {
        continue;
      }
      // 读字节期间退页（大文件异步读）：不再向已销毁页面写状态。
      if (!mounted) return;
      if (bytes.length > kAttachmentMaxBytes) {
        messenger.showSnackBar(
          SnackBar(content: Text('「${f.name}」超过 20MB 上限')),
        );
        continue;
      }
      _pendingAtts.add(
        PendingAttachment(
          id: 'att-${DateTime.now().microsecondsSinceEpoch}-$_pendingAttsLen',
          fileName: f.name,
          mime: _mimeOfExtension(f.extension ?? ''),
          bytes: bytes,
        ),
      );
      added++;
    }
    if (added > 0 && mounted) {
      setState(() {});
      _onDraftMutated();
      _pumpAttachmentUploads(_sessionId);
    }
  }

  int get _pendingAttsLen => _pendingAtts.length;

  /// 上传进度 UI 合帧时间戳（ A3-P3-10）。
  DateTime? _attUiAt;

  /// 串行上传队列（官方并发 2，手机端取串行足够）。幂等：已在跑则返回。
  Future<void> _pumpAttachmentUploads(String? sessionId) async {
    if (_attPumpRunning) return;
    if (sessionId == null) return; // waitingSession：发送时统一处理
    final conv = AppStateScope.of(context).conversation;
    if (conv == null) return;
    _attPumpRunning = true;
    try {
      while (true) {
        if (!mounted) break;
        final next = _pendingAtts
            .where((a) => !a.ready && a.error == null && a.progress < 0)
            .firstOrNull;
        if (next == null) break;
        next.progress = 0;
        if (mounted) setState(() {});
        try {
          next.uploaded = await conv.attachmentPut(
            sessionId,
            fileName: next.fileName,
            mime: next.mime,
            bytes: next.bytes,
            onProgress: (p) {
              next.progress = p.clamp(0.0, 1.0);
              // A3-P3-10：20MB 分块上传的每块回调都整页
              // setState——100ms 合帧（终值由循环尾部的统一 setState 兜）。
              final now = DateTime.now();
              if (p >= 1.0 ||
                  _attUiAt == null ||
                  now.difference(_attUiAt!) >=
                      const Duration(milliseconds: 100)) {
                _attUiAt = now;
                if (mounted) setState(() {});
              }
            },
          );
          next.progress = 1;
        } catch (e) {
          next.error = '$e';
        }
        if (mounted) {
          setState(() {});
          await _saveDraft();
        }
      }
    } finally {
      _attPumpRunning = false;
    }
  }

  void _removeAttachment(String id) {
    setState(() => _pendingAtts.removeWhere((a) => a.id == id));
    _onDraftMutated();
  }

  /// 截图圈点标注（6.6④）：字节在手直接进编辑器；恢复图先取回字节。
  /// 保存后替换字节并作废上传引用（旧 ref 不再代表内容），排队重传。
  Future<void> _annotateAttachmentById(String id) async {
    final a = _pendingAtts.where((x) => x.id == id).firstOrNull;
    if (a == null || !a.annotatable) return;
    final messenger = ScaffoldMessenger.of(context);
    var bytes = a.bytes;
    if (bytes.isEmpty && a.uploaded != null) {
      final sessionId = _sessionId;
      final ref = '${a.uploaded!['ref'] ?? ''}';
      if (sessionId == null || ref.isEmpty) return;
      try {
        final r = await AppStateScope.of(context)
            .attachmentRead(sessionId, ref);
        bytes = Uint8List.fromList(r.bytes);
      } catch (_) {
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(
            content: const Text('暂时取不回原图，稍后再试'),
            duration: const Duration(seconds: 2),
          ),
        );
        return;
      }
    }
    if (bytes.isEmpty || !mounted) return;
    final edited = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) =>
            AttachmentAnnotatePage(imageBytes: bytes, fileName: a.fileName),
      ),
    );
    if (edited == null || edited.isEmpty || !mounted) return;
    if (!_pendingAtts.contains(a)) return;
    setState(() {
      a.bytes = edited;
      a.uploaded = null;
      a.error = null;
      a.progress = -1;
      a.sourceUnavailable = false;
      a.persistedByteSize = null;
    });
    _onDraftMutated();
    if (_sessionId != null) _pumpAttachmentUploads(_sessionId);
  }

  void _retryAttachment(String id) {
    final a = _pendingAtts.where((x) => x.id == id).firstOrNull;
    if (a == null || a.sourceUnavailable) return;
    setState(() {
      a.error = null;
      a.progress = -1;
    });
    _onDraftMutated();
    _pumpAttachmentUploads(_sessionId);
  }

  /// 发送路径：等待全部待发附件就绪。有失败者抛错（发送中断、正文回填、
  /// 附件留在托盘可重试）——官方 prepareForSend 的 attachment_not_ready
  /// 门禁同语义。
  Future<List<Map<String, dynamic>>> _awaitAttachments(
    String sessionId,
    List<PendingAttachment> attachments,
  ) async {
    if (attachments.isEmpty) return const [];
    if (attachments.length > kMaxChatAttachments) {
      throw StateError('附件超过 $kMaxChatAttachments 个，请先移除多余附件');
    }
    final unavailable = attachments.where((a) => a.sourceUnavailable).toList();
    if (unavailable.isNotEmpty) {
      throw StateError(
        '附件需重新选择：${unavailable.map((a) => a.fileName).join('、')}（请先移除失效附件）',
      );
    }
    _pumpAttachmentUploads(sessionId);
    final deadline = DateTime.now().add(const Duration(minutes: 5));
    // A2-P2-1：等待期按 _pendingAtts 实时成员过滤——旧实现轮询
    // 发送瞬间的快照，用户移除的排队态附件（progress=-1）不再被 pump
    // 拾取也永无 error/ready，会挂满 5 分钟才抛「附件上传超时」。移除
    // 即放行（用户意图：不要这个了，让消息先走）。
    while (attachments.any(
      (a) => a.error == null && !a.ready && _pendingAtts.contains(a),
    )) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('附件上传超时');
      }
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    final live = attachments.where((a) => _pendingAtts.contains(a)).toList();
    final failed = live.where((a) => a.error != null).toList();
    if (failed.isNotEmpty) {
      throw StateError(
        '附件上传失败：${failed.map((a) => a.fileName).join('、')}（在输入框上方点重试）',
      );
    }
    return [for (final a in live) a.uploaded!];
  }

  void _clearSubmittedAttachments(List<PendingAttachment> submitted) {
    _pendingAtts.removeWhere(
      (current) => submitted.any((a) => identical(a, current)),
    );
  }

  /// 发起会话压缩：反馈=时间线「正在压缩上下文」标记行（B11 已渲染，
  /// 本批文案对齐官方）；失败人话提示。
  /// ：ack 非 accepted 族（rejected/failed）时
  /// sendCommand 不抛——此前零反馈（用户按了没反应，恰是本批原病征
  /// 的残留形态）。
  Future<void> _sendCompact(AppState app) async {
    final sessionId = _sessionId;
    final messenger = ScaffoldMessenger.of(context);
    if (sessionId == null || app.bridge == null) {
      messenger.showSnackBar(const SnackBar(content: Text('未连接电脑，暂不能压缩上下文')));
      return;
    }
    try {
      final ack = await app.sendCompact(sessionId);
      final status = ack is Map ? '${ack['status']}' : '';
      if (status == 'rejected' || status == 'failed') {
        final reason = ack is Map
            ? '${ack['reasonCode'] ?? ack['reason'] ?? ''}'
            : '';
        messenger.showSnackBar(
          SnackBar(
            content: Text('${tr('压缩被拒绝：')}${reason.isEmpty ? status : reason}'),
          ),
        );
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('压缩发起失败：$e')));
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    // 用户拍板（2026-10-23）：点发送即收起输入法——回复期间键盘常驻
    // 挡半屏。发送失败回填草稿后用户点输入框自然再聚焦。
    FocusManager.instance.primaryFocus?.unfocus();
    await _sendText(text, clearInput: true);
  }

  /// B1（官方 ConversationComposer.tsx:1323-1336 对位）：
  /// 发送前读快照 inputRouting——reject=禁发（人话提示）；choice=held
  /// 态弹「清空队列后发送/保留队列发送」二选一（heldQueueDisposition
  /// 随 sendText 提交）。返回 null=可直发；非 null=应带的 disposition；
  /// 抛 StateError=拒发。
  /// 返回 (disposition, 弹框打开时的队列项快照)。：
  /// 官方 held 二选一携带 expectedHeldQueueItemIds——手机弹框期间桌面新
  /// 排队的消息不在用户确认范围，CLI 校验不一致即拒，防止"清空队列"
  /// 误杀没确认过的新排队项（官方 ConversationComposer 同款快照）。
  Future<(String?, List<String>?)> _resolveHeldDisposition() async {
    final effState = (_sub?.state ?? _cachePreview);
    final routing = effState?.snapshot?['inputRouting'];
    final mode = routing is Map
        ? '${routing['mode'] ?? 'startNow'}'
        : 'startNow';
    if (mode == 'reject') {
      final reason = routing is Map ? '${routing['reasonCode'] ?? ''}' : '';
      // P1 P3-1：闭括号随语言取半/全角（tr 不覆盖全角标点，
      // hasCjk 判 False——条件式直接选字形，保持 EN 括号成对）。
      throw StateError(
        reason.isEmpty
            ? tr('当前回合不接受新输入')
            : tr('当前回合不接受新输入（') +
                  reason +
                  (L10n.resolvedLocale == 'en-US' ? ')' : '）'),
      );
    }
    if (mode != 'choice') return (null, null);
    List<String> snapshotQueueIds() {
      final queue = effState?.snapshot?['queue'];
      final items = queue is Map ? queue['items'] : null;
      if (items is! List) return const [];
      return [
        for (final it in items)
          if (it is Map)
            if ('${it['queueItemId'] ?? it['id'] ?? ''}'.isNotEmpty)
              '${it['queueItemId'] ?? it['id']}',
      ];
    }

    final expectedIds = snapshotQueueIds();
    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const ValueKey('held-queue-disposition'),
        title: Text(tr('有排队的消息')),
        content: Text(tr('回合已结束但队列里有待发消息。清空队列后发送，还是保留队列立即发送？')),
        actions: [
          TextButton(
            key: const ValueKey('held-disposition-clear'),
            onPressed: () => Navigator.pop(dialogContext, 'clearQueueAndSend'),
            child: Text(tr('清空队列后发送')),
          ),
          FilledButton(
            key: const ValueKey('held-disposition-keep'),
            onPressed: () => Navigator.pop(dialogContext, 'keepQueueAndSend'),
            child: Text(tr('保留队列发送')),
          ),
        ],
      ),
    );
    // 取消=用户主动放弃（不是发送失败）：专用异常走和气收尾。
    if (picked == null) throw const SendCancelled();
    return (picked, expectedIds);
  }

  /// 队列重放的正文不属于输入框草稿（#1 高）：发送前为结果未知机制
  /// 先后落的 in-flight 草稿必须在失败分支收口——无用户编辑时按发送前
  /// revision 删除（队列条目仍在队重试）；用户期间有新输入时重写为
  /// 「无 in-flight 标记 + 新输入」，不让队列正文污染草稿/重启后误报。
  Future<void> _retractQueuedDraftPollution() async {
    final store = _appRef?.draftStore;
    final identity = _draftIdentity;
    final sentRevision = _submittedDraftRevision;
    final idle =
        _draftRevision == sentRevision &&
        _draftTextSnapshot.trim().isEmpty &&
        (_unsentDraft?.trim().isEmpty ?? true);
    if (idle && store != null && identity != null) {
      // 按发送前落盘的 revision 删除——期间若有新保存，revision 已变，
      // 存储侧 expectedRevision 不匹配=天然不动用户新内容。
      await store.delete(identity, expectedRevision: sentRevision);
      return;
    }
    _draftRevision++;
    await _saveDraft();
  }

  /// 发送核心（语音直发复用：附件/建会话/错误回填链路完全一致）。
  /// [clearInput]=手动发送清输入框；语音直发不动输入框（可能有草稿）。
  /// [fromQueue]=断网排队重放（6.6②）：失败不清稿不回填输入框（条目
  /// 留在队列，重连再试），也不再次入队。返回值=是否成功（供 drain）。
  Future<bool> _sendText(
    String text, {
    bool clearInput = false,
    SendQueueEntry? fromQueue,
  }) async {
    final app = AppStateScope.of(context);
    if (text.trim().isEmpty || _sending) return false;
    // 会话压缩（compact-command-1，用户反馈「手机发起压缩无任何提示」
    // 根因：官方 compact 是专用命令信封，我们此前按纯文本发送=CLI 不
    // 执行。官方 compact 无参数——精确匹配 /compact 走命令通道；其余
    // 带参形态维持文本由 CLI 自行解释。维护命令不进离线队列。
    if (fromQueue == null && text.trim() == '/compact') {
      // 命令发出后清输入——此前 "/compact" 残留
      // 在输入框（草稿还会存它），再点一次=busy 期双压缩进 FIFO。
      // A2-P3-8：语音直发（clearInput=false）路径输入框可能正
      // 恰残留同一命令文本——按内容判定清理，不误清无关草稿。
      if (clearInput || _input.text.trim() == '/compact') {
        _suppressDraftSync = true;
        try {
          _input.clear();
          _draftTextSnapshot = '';
        } finally {
          _suppressDraftSync = false;
        }
        _draftRevision++;
        unawaited(_saveDraft());
      }
      await _sendCompact(app);
      return true;
    }
    // 断网消息排队（6.6②）：无桥或链路未在线=断连（90s 后台断连窗口/
    // 冷启动未连/切工作区期/飞行模式）——文本消息入队等重连自动发出，
    // 不发起注定失败的 RPC。验收修复（18076 反馈#6）：此前只看
    // bridge==null，飞行模式下桥为恢复保留 → 发送走 45s waitHealthy
    // 超时才失败（转圈很久、第二条也进不了队）。relay 断链后 phase
    // 秒降 reconnecting，以此快速判定（offline/connecting 时桥本就为
    // null 或在建，由前一条件覆盖）。带附件不排队（上传依赖连接）。
    if (fromQueue == null &&
        _pendingAtts.isEmpty &&
        (app.bridge == null || app.phase == LinkPhase.reconnecting)) {
      // A1-P2-4：入队在飞哨兵——清输入发生在 await store.add
      // （真实文件 IO）之后，双击窗口内第二次 tap 读到未清空输入=同文
      // 条目双入队（重连 drain 双发）。首击已在途即视为本条已受理。
      if (_enqueueingOffline) return true;
      _enqueueingOffline = true;
      try {
        await _enqueueOffline(app, text, clearInput: clearInput);
      } finally {
        _enqueueingOffline = false;
      }
      return true;
    }
    _submittedDraftText = text;
    _draftResultUnknown = false;
    unawaited(_saveDraft());
    setState(() {
      _sending = true;
      _error = null;
      _stickToBottom = true;
    });
    if (clearInput) {
      _suppressDraftSync = true;
      try {
        _input.clear();
        // 18076 反馈#5：快照必须与输入框同步清空——失败回填路径以
        // 快照判"等待期新输入"，残留旧值会把正文误入暂存（输入框空=
        // 用户体感"消息消失"）。
        _draftTextSnapshot = '';
      } finally {
        _suppressDraftSync = false;
      }
    }
    try {
      await _draftRestoreFuture;
      _submittedDraftRevision = _draftRevision;
      await _saveDraft();
      final submittedAttachments = List<PendingAttachment>.of(_pendingAtts);
      var sessionId = _sessionId;
      if (sessionId == null) {
        // 草稿期挂起选型随首条消息（官方 createSessionRequestedConfig：
        // provider/model/thought/mode/planEnabled 均为请求覆盖字段）。
        // 介入点 2 真机实锤修复（2026-10-19，sess_demo）：记忆的选型
        // 可能陈旧（桌面端供应商阵容变化后 provider/modelId 已不在目录）
        // ——原样提交会让服务端约 200ms 打挂整个回合且页面无提示。
        // 提交前对照活目录验证：陈旧或不成对的一律丢弃，退回服务端默认。
        if (_pendingModelId != null || _pendingModelProvider != null) {
          final pairOk =
              _pendingModelProvider != null && _pendingModelId != null;
          var dirHit = false;
          if (pairOk) {
            try {
              final opts = await app.modelSelectionOptions();
              dirHit = opts.any(
                (o) => o.value == '$_pendingModelProvider/$_pendingModelId',
              );
            } catch (_) {
              dirHit = true; // 目录暂不可用不拦发送（网络态不给用户添堵）
            }
          }
          if (!pairOk || !dirHit) {
            debugPrint(
              '[draft] drop stale selection: '
              '$_pendingModelProvider/$_pendingModelId',
            );
            _pendingModelProvider = null;
            _pendingModelId = null;
          }
        }
        final draftConfig = <String, dynamic>{
          if (_pendingModelProvider != null) 'provider': _pendingModelProvider,
          if (_pendingModelId != null) 'model': _pendingModelId,
          if (_pendingThought != null) 'thought': _pendingThought,
          // 批⑦（2026-10-23）：mode=权限档（build/edit/guarded/yolo），
          // planEnabled=独立开关——两字段并行（官方 create-session-config
          // 同款双字段；旧「plan 作为 mode」兼容值不再从这里发）。
          if (_pendingMode != null) 'mode': _pendingMode,
          if (_pendingPlan != null) 'planEnabled': _pendingPlan,
          // followupMode 随新建收敛（官方 buildDraftCreateConfigPayload
          // 携带 appFollowupMode 同款）。
          'followupMode': app.uiPrefs.followupMode,
        };
        final hasAtts = submittedAttachments.isNotEmpty;
        try {
          sessionId = await app.createSession(
            hasAtts ? null : text,
            config: draftConfig.isEmpty ? null : draftConfig,
          );
        } on SessionCreatedSubscriptionError catch (error) {
          sessionId = error.sessionId;
        }
        if (!mounted) {
          // A2-P1-2：建会话已提交（config 已随 createSession
          // 消费）——同步清挂起选型，防 _replayQueuedSend 的还原分支把
          // 已消费选型当「未消费」误还原（退页无法 setState，纯字段写，
          // 与附件路径 1804-1812 的成功清理对齐）。
          _pendingModelProvider = null;
          _pendingModelId = null;
          _pendingThought = null;
          _pendingMode = null;
          _pendingPlan = null;
          await _promoteDraftToSession(sessionId);
          if (!hasAtts) await _finishDraftSubmission();
          return true;
        }
        _appRef?.viewingSessionId = sessionId;
        setState(() => _sessionId = sessionId);
        await _promoteDraftToSession(sessionId);
        await _subscribe(sessionId);
        if (hasAtts) {
          // 草稿附件无法预传（无会话可挂）——官方兜底路径的手机端适配：
          // 空会话先建、上传完成再 sendText。不采用官方"预热会话"（弃置
          // 会残留空任务卡，污染任务列表—— 批决策）。
          final refs = await _awaitAttachments(sessionId, submittedAttachments);
          final (heldDisp, heldIds) = await _resolveHeldDisposition();
          final res = await app.sendText(
            sessionId,
            text,
            attachments: refs,
            heldQueueDisposition: heldDisp,
            expectedHeldQueueItemIds: heldIds,
            replayCommandId: fromQueue?.commandId,
          );
          _throwIfSendRejected(res);
          if (mounted) {
            setState(() {
              _pendingModelProvider = null;
              _pendingModelId = null;
              _pendingThought = null;
              _pendingMode = null;
              _pendingPlan = null;
              _clearSubmittedAttachments(submittedAttachments);
            });
          } else {
            _clearSubmittedAttachments(submittedAttachments);
          }
          await _finishDraftSubmission();
          return true;
        }
        // A2-P3-2：非附件草稿路径 createSession 成功后清理挂起
        // 选型（config 已随建会话消费）——与附件路径 1845-1853 对齐；
        // 旧实现不清，药丸整个首回合保持「挂起」高亮、下次 sendText
        // 还把同值选型重发一遍。
        if (mounted) {
          setState(() {
            _pendingModelProvider = null;
            _pendingModelId = null;
            _pendingThought = null;
            _pendingMode = null;
            _pendingPlan = null;
          });
        }
        await _finishDraftSubmission();
        return true;
      } else {
        // 挂起选型随提交携带（官方 command.ts:109-112 语义）。
        // providerId/modelId strict 非空——组装前校验；缺则
        // 降级不带选型（思考档等配置就绪后再挂）。
        // reasoningLevel 必须完整（官方提交时非空断言 + 模型校验：
        // 不完整选型会被 admission 静默丢弃——sel2 实测）。
        final config = _sub?.state.config;
        var effProvider = _pendingModelProvider;
        var effModel = _pendingModelId;
        effProvider ??= '${config?['provider'] ?? ''}';
        if (effModel == null) {
          final cm = '${config?['model'] ?? ''}';
          effModel = cm.contains('/') ? cm.substring(cm.indexOf('/') + 1) : cm;
        }
        final effThought = _pendingThought ?? '${config?['thought'] ?? ''}';
        final hasSel = _pendingModelId != null || _pendingThought != null;
        Map<String, dynamic>? modelSel;
        if (hasSel &&
            effProvider.isNotEmpty &&
            effModel.isNotEmpty &&
            effThought.isNotEmpty) {
          modelSel = {
            'providerId': effProvider,
            'modelId': effModel,
            'options': {'reasoningLevel': effThought},
          };
        }
        // 批⑦（2026-10-23）：mode=权限档、planEnabled=独立开关并行提交
        // （官方 composerSubmissionConfig.ts:35-37 同款；_pendingMode 不再
        // 承载 'plan'——计划从开关来，可为显式 false=关闭会话已开的计划）。
        // 对抗审查 A1（2026-10-24）：服务端 resolveExecutionState 对
        // "带 mode 无 planEnabled"的提交按 mode.success⇒false 收敛——
        // 本次提交带 mode 时必须成对冻结当前计划生效值（官方提交瞬间
        // 冻结同款），否则挂起回退场景下计划被静默关闭。
        final submitMode = _pendingMode;
        final planEnabled =
            _pendingPlan ??
            (submitMode != null ? _planEnabledOf(_sub?.state) : null);
        // 待发附件先就绪（官方 attachment_not_ready 门禁同语义：失败即
        // 中断发送，正文回填、附件留托盘重试）。
        final attRefs = await _awaitAttachments(
          sessionId,
          submittedAttachments,
        );
        final (heldDisp, heldIds) = await _resolveHeldDisposition();
        final res = await app.sendText(
          sessionId,
          text,
          modelSelection: modelSel,
          mode: submitMode,
          planEnabled: planEnabled,
          attachments: attRefs.isEmpty ? null : attRefs,
          heldQueueDisposition: heldDisp,
          expectedHeldQueueItemIds: heldIds,
          replayCommandId: fromQueue?.commandId,
        );
        // 被拒的 sendText 不能当成功（否则正文+草稿双丢、零
        // 反馈）——非 accepted/duplicate 抛入既有 catch（回填正文、保留
        // 草稿、错误条可见）。
        _throwIfSendRejected(res);
        // A3+A5 乐观写回（2026-10-24 修复批）：accepted 即把本次提交的
        // 选型写进本地 config——药丸/计划开关立即反映提交值，消灭
        // "accepted 清挂起→config 回显前窗口期回摆"（旧实现计划开关
        // 标记消失再回摆实锤）。服务端 config patch 回显同值零闪烁。
        // 写回目标：活订阅，退而缓存预渲层；两者皆空（无快照可写）时
        // 挂起保留作显示载体，由 _onStateChanged 水位式清理（config
        // 回显匹配才清）+_armPlanEchoFallback 超时兜底退位。
        final wbTarget = _sub?.state ?? _cachePreview;
        final wrote =
            wbTarget?.writeBackConfig({
              'mode': ?submitMode,
              'planEnabled': ?planEnabled,
              if (modelSel != null) ...{
                'provider': effProvider,
                'model': effModel,
                'thought': effThought,
              },
            }) ??
            false;
        if (mounted) {
          setState(() {
            if (wrote) {
              _pendingModelProvider = null;
              _pendingModelId = null;
              _pendingThought = null;
              _pendingMode = null;
              _pendingPlan = null;
            } else if (_pendingPlan != null) {
              _armPlanEchoFallback();
            }
            _clearSubmittedAttachments(submittedAttachments);
          });
        } else {
          _clearSubmittedAttachments(submittedAttachments);
        }
        await _finishDraftSubmission();
        return true;
      }
    } catch (e) {
      // 用户在 held 二选一弹层点取消/点遮罩=主动放弃，不是发送失败
      // ——旧实现落通用 catch，红条「发送失败：Bad state: 已取消发送」。
      if (e is SendCancelled) {
        _submittedDraftText = null;
        _draftResultUnknown = false;
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text(tr('已取消发送')),
              duration: const Duration(seconds: 2),
            ),
          );
        }
        if (fromQueue != null) {
          // 队列重放被取消：条目留队，草稿里不得残留队列正文/in-flight。
          await _retractQueuedDraftPollution();
          return false;
        }
        // 主动取消：正文回填输入框（等待期有新输入则进暂存，不覆盖）。
        final hasNewInput =
            _draftTextSnapshot.isNotEmpty && _draftTextSnapshot != text;
        if (hasNewInput) {
          _unsentDraft = _unsentDraft == null
              ? text
              : '${_unsentDraft!}\n\n$text';
        } else {
          _draftTextSnapshot = text;
          if (mounted) {
            _suppressDraftSync = true;
            try {
              setState(() => _input.text = text);
            } finally {
              _suppressDraftSync = false;
            }
          }
        }
        _draftRevision++;
        await _saveDraft();
        return false;
      }
      // relay seq gap=在途 RPC 的响应帧丢失
      // ——请求很可能已被服务端执行，按失败暂存+用户重发=双投递。归
      // "结果未知"（保留提交态+横幅「重新核对」，可确权收敛）。
      if ('$e'.contains('response frame lost')) {
        if (fromQueue != null) {
          // 队列重放的结果未知不是输入框草稿的提交态（条目仍在队列，
          // 幂等 commandId 会在退避后重试）——旧实现把队列正文按
          // in-flight 草稿落盘，重启后误显「结果未知」+可重发正文。
          // F3（复审）：盘上收口前必须先清内存 _submittedDraftText——
          // 否则后续任意一次 _saveDraft（键入/附件/再入队）会把队列
          // 正文+in-flight 标记重新写回盘上（污染换触发口复活）。
          _submittedDraftText = null;
          _draftResultUnknown = false;
          if (mounted) {
            setState(() => _error = tr('发送结果未知，稍后会自动重试'));
          }
          await _retractQueuedDraftPollution();
          return false;
        }
        if (mounted) {
          setState(() {
            _sending = false;
            _draftResultUnknown = true;
            _error = tr('发送结果未知（连接抖动），稍后可点「重新核对」确认');
          });
        }
        _draftRevision++;
        await _saveDraft();
        return false;
      }
      _submittedDraftText = null;
      _draftResultUnknown = false;
      // 18076 反馈#5：裸 TimeoutException 怼脸不可读——统一人话（正文
      // 已回填输入框/暂存，草稿可重发）；StateError 剥英文前缀。
      final friendlyError = e is TimeoutException
          ? tr('连接中断，消息未发出，正文已放回输入框')
          : '发送失败：${humanizeError(e)}';
      if (fromQueue != null) {
        // 排队重放失败：条目留在队列（重连再试），不清稿不回填输入框
        //——避免同一条消息在队列与暂存双份。错误横幅照常呈现；队列
        // 正文不属于输入框草稿，按发送前 revision 收口（#1 高）。
        if (mounted) {
          setState(() => _error = friendlyError);
        }
        await _retractQueuedDraftPollution();
        return false;
      }
      final hasNewInput = _draftTextSnapshot.isNotEmpty;
      if (hasNewInput) {
        _unsentDraft = _unsentDraft == null
            ? text
            : '${_unsentDraft!}\n\n$text';
      } else {
        _draftTextSnapshot = text;
      }
      if (mounted) {
        // 等待期新输入不被原文覆盖；连续失败原文追加暂存，不覆盖旧暂存。
        _suppressDraftSync = true;
        try {
          setState(() {
            _error = friendlyError;
            if (!hasNewInput) _input.text = text;
          });
        } finally {
          _suppressDraftSync = false;
        }
      }
      _draftRevision++;
      await _saveDraft();
      return false;
    } finally {
      // 18077 验收#12（Bug J 防御兜底）：字段先行复位——mounted 判定
      // 只该影响 setState（防 dispose 后重建 UI），不该让 _sending
      // 在任何路径下滞留 true（发送按钮永转圈+吞掉后续发送）。
      _sending = false;
      if (mounted) setState(() {});
    }
  }

  // ── 断网消息排队（6.6②，2026-10-29 批次）──────────────────────

  SendQueueBucket? get _sendQueueBucket {
    final id = _draftIdentity;
    if (id == null) return null;
    return SendQueueBucket(
      deviceSid: id.deviceSid,
      accountId: id.accountId,
      workspaceKey: id.workspaceKey,
      scopeId: id.scopeId,
    );
  }

  /// 无桥（断连期）发送 → 入队。新建草稿桶携带挂起选型快照（重放时
  /// 恢复为 _pending*，随首条消息建会话；陈旧选型在重放发送时照常被
  /// 目录校验丢弃）。
  Future<void> _enqueueOffline(
    AppState app,
    String text, {
    required bool clearInput,
  }) async {
    final store = app.sendQueue;
    final bucket = _sendQueueBucket;
    if (store == null || bucket == null) {
      // 队列基建不可用（极早期/异常环境）——回落既有失败呈现。
      setState(() => _error = tr('当前未连接电脑，稍后再试'));
      return;
    }
    final isNewDraft = _sessionId == null;
    await store.add(
      bucket,
      SendQueueEntry(
        id: generateUuid(),
        text: text,
        config: isNewDraft
            ? <String, dynamic>{
                if (_pendingModelProvider != null)
                  'provider': _pendingModelProvider,
                if (_pendingModelId != null) 'model': _pendingModelId,
                if (_pendingThought != null) 'thought': _pendingThought,
                if (_pendingMode != null) 'mode': _pendingMode,
                if (_pendingPlan != null) 'planEnabled': _pendingPlan,
              }
            : null,
        queuedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    // A2-P2-2：store.add 是真实文件 IO 往返——期间退页后
    // _input.clear() 打在已 dispose 的 controller 上（debug 抛
    // FlutterError）。条目已持久化，UI 收尾可弃。
    if (!mounted) return;
    if (clearInput) {
      _suppressDraftSync = true;
      try {
        _input.clear();
      } finally {
        _suppressDraftSync = false;
      }
    }
    _draftRevision++;
    await _saveDraft();
    await _refreshQueueEntries(app);
    debugPrint('[send-queue] queued offline (${bucket.scopeId})');
  }

  Future<void> _refreshQueueEntries(AppState _) => _queue.refresh();

  /// 排队重放：新建草稿条目恢复挂起选型（成功即被发送链路消费；失败
  /// 由 _sendText 的 fromQueue 分支呈现，选型还原不丢用户当前值）。
  Future<bool> _replayQueuedSend(SendQueueEntry entry) async {
    final cfg = entry.config;
    final restore = (
      _pendingModelProvider,
      _pendingModelId,
      _pendingThought,
      _pendingMode,
      _pendingPlan,
    );
    if (cfg != null && _sessionId == null) {
      setState(() {
        _pendingModelProvider = _stringOf(cfg['provider']);
        _pendingModelId = _stringOf(cfg['model']);
        _pendingThought = _stringOf(cfg['thought']);
        _pendingMode = _stringOf(cfg['mode']);
        _pendingPlan = _boolOf(cfg['planEnabled']);
      });
    }
    try {
      return await _sendText(entry.text, fromQueue: entry);
    } finally {
      // A3-P3-8：只要发生过覆盖就还原（旧条件还要求
      // _pendingModelId != null——快照只带 provider 不带 model 的条目
      // 重放失败后，用户原挂起的 provider 残留为队列快照值）。
      if (cfg != null && _sessionId == null) {
        // 发送链路没消费掉（失败/半途）——还原用户当前挂起值。
        // A2-P1-2（重放期间退页重复建会话）：字段写不依赖
        // mounted（18077 同款——mounted 只挡 setState）——此前无守卫
        // 的 setState 在退页后抛异常，drain 的 store.remove 被跳过，
        // 条目留存再次重放=重复建会话+重复首条消息。
        _pendingModelProvider = restore.$1;
        _pendingModelId = restore.$2;
        _pendingThought = restore.$3;
        _pendingMode = restore.$4;
        _pendingPlan = restore.$5;
        if (mounted) setState(() {});
      }
    }
  }

  bool _resultUnknownConverged = false;
  bool _busyResultRecheck = false;

  /// A3：「结果未知」确权回捞——官方 queryConversation
  /// CommandsV4 查同一命令（adapter.ts:2065-2078）；accepted/duplicate/
  /// noop=已送达（清横幅+按已提交收尾），failed=未送达（清未知态走
  /// 失败暂存语义），unknown 维持横幅等人工核对。
  Future<void> _recheckLastSendResult() async {
    final sid = _sessionId;
    if (sid == null || _busyResultRecheck) return;
    // 三轮审查 B1/A2：按钮点击时 context 有效，直接取 scope——不再
    // 复用草稿链引用（其赋值条件与队列链不同，属隐性耦合）。
    final app = AppStateScope.of(context);
    if (app.bridge == null) return;
    setState(() => _busyResultRecheck = true);
    try {
      // 重启后进程内账本为空=查无可查——此前
      // 静默无反应（死键），给明确人话而非留用户猜。
      final hasRecord = app.hasLastCommandRecord(sid);
      final result = await app.queryLastSentCommand(sid);
      if (!mounted || result is! Map) {
        if (mounted && !hasRecord) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(tr('重启后无法自动核对，请对照电脑端确认'))));
        }
        return;
      }
      final status = '${result['status'] ?? ''}';
      if (status == 'accepted' || status == 'duplicate' || status == 'noop') {
        final original = _submittedDraftText;
        setState(() => _resultUnknownConverged = true);
        _draftResultUnknown = false;
        // 已确认送达：原文不得继续留在输入框/草稿里（再点发送=对已送达
        // 消息重发）。仅当没有"新输入"时清空——恢复的 in-flight 稿里
        // 正文就是已提交原文，同样视为无新输入；用户新打的字保留。
        final noNewInput =
            _draftTextSnapshot.trim().isEmpty ||
            (original != null && _draftTextSnapshot == original);
        if (noNewInput) {
          _suppressDraftSync = true;
          try {
            _input.clear();
            _draftTextSnapshot = '';
          } finally {
            _suppressDraftSync = false;
          }
        }
        _submittedDraftText = null;
        await _finishDraftSubmission();
        Future<void>.delayed(const Duration(seconds: 6), () {
          if (mounted) setState(() => _resultUnknownConverged = false);
        });
      } else if (status == 'failed' ||
          status == 'discarded' ||
          status == 'rejected' ||
          status == 'stale') {
        // rejected/stale=确定性未送达（官方 ack 六态），
        // 此前两态不命中=横幅永挂。原文回填输入框（无新输入时），
        // 草稿按 submissionInFlight:false 重写——可安心重发。
        final original = _submittedDraftText;
        setState(() => _draftResultUnknown = false);
        _submittedDraftText = null;
        if (original != null &&
            original.trim().isNotEmpty &&
            _draftTextSnapshot != original) {
          final hasNewInput = _draftTextSnapshot.trim().isNotEmpty;
          if (hasNewInput) {
            _unsentDraft = _unsentDraft == null
                ? original
                : '${_unsentDraft!}\n\n$original';
          } else {
            _draftTextSnapshot = original;
            _suppressDraftSync = true;
            try {
              setState(() => _input.text = original);
            } finally {
              _suppressDraftSync = false;
            }
          }
        }
        _draftRevision++;
        await _saveDraft();
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(tr('已确认上次发送未送达，草稿可重发'))));
        }
      }
    } finally {
      if (mounted) setState(() => _busyResultRecheck = false);
    }
  }

  /// 用户逐条撤销排队。
  Future<void> _cancelQueuedEntry(SendQueueEntry entry) => _queue.cancel(entry);

  /// 发送被服务端拒（非 accepted/duplicate/noop）按失败处理（ 同源：
  /// 被拒不能当成功——正文+草稿双丢零反馈）。
  void _throwIfSendRejected(dynamic res) {
    if (res is! Map || res['status'] is! String) {
      throw StateError('发送结果缺少有效状态，请核对会话后再试');
    }
    final st = res['status'] as String;
    if (st != 'accepted' && st != 'duplicate' && st != 'noop') {
      throw StateError('${res['reasonCode'] ?? st} ${res['message'] ?? ''}');
    }
  }

  Future<void> _stop() async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    try {
      final res = await AppStateScope.of(context).stop(sessionId);
      // 桌面对齐：stop 被拒（如回合其实已结束）时给出可见反馈，而不是
      // 静默无响应（真机 2026-10-16 反馈"停止按钮点了没反应"的一半根因）。
      if (mounted &&
          res is Map &&
          res['status'] != null &&
          res['status'] != 'accepted') {
        final why = '${res['reasonCode'] ?? res['message'] ?? res['status']}';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('停止未生效：$why'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '停止失败：$e');
    }
  }

  bool _loadingOlder = false;
  Future<bool>? _olderLoadInFlight;
  bool _turnStartJumpInFlight = false;

  void _maybeAutoLoadOlder() {
    final sessionId = _sessionId;
    if (sessionId == null || _loadingOlder) return;
    final state = _sub?.state;
    if (state == null || !state.canLoadOlder) return;
    unawaited(_loadOlder());
  }

  /// 所有历史入口共享同一在途 Future；双向锚定列表负责保持阅读位置，
  /// 不再于绘制后按 maxScrollExtent 差值补跳。
  Future<bool> _loadOlder() {
    final running = _olderLoadInFlight;
    if (running != null) return running;
    final sessionId = _sessionId;
    if (sessionId == null) return Future.value(false);
    final state = _sub?.state;
    if (state == null || !state.canLoadOlder) return Future.value(false);
    final future = _performLoadOlder(sessionId, state);
    _olderLoadInFlight = future;
    return future;
  }

  Future<bool> _performLoadOlder(
    String sessionId,
    ConversationState state,
  ) async {
    final beforeCursor = state.oldestRowId;
    setState(() => _loadingOlder = true);
    try {
      await AppStateScope.of(context).loadOlder(sessionId);
      final current = _sub?.state;
      return identical(current, state) && current!.oldestRowId != beforeCursor;
    } finally {
      _olderLoadInFlight = null;
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  /// 两步式深链（2026-11-04 拍板）：通知点进来后弹一次「定位到相关
  /// 消息？」浮层——atMs 是通知产生时刻，据此找最接近的回合行。
  /// 消费后清 app.pendingDeepLinkAt，防重复弹。
  bool _deepLinkPromptShown = false;

  /// 深链提示的会话归属（ P2-3：pendingDeepLinkAt 此前无归属，
  /// 目标会话未打开时残留被下一个打开的无关会话消费——误弹+跳错行）。
  String? _deepLinkPromptShownFor;

  /// 行号 → 顶层条目锚键（#3 高）：chatItemKey 只有 UserItem/时间线
  /// 标记/文件卡发 'row-*' 键；回合内工作行（思考/工具/正文）没有独立
  /// 条目——直接拼 'row-$rowId' 必然落空，center 回退 0=整列跳到最老，
  /// 滚动记忆也被写坏。这里把行号映射到其所属回合/条目的真实锚键。
  String? _anchorKeyForRow(int rowId) {
    final state = _sub?.state;
    if (state == null) return null;
    final items = _cachedItemsIdentical(state.rows, state)
        ? _cachedChatItems
        : _rebuildChatItems(state.rows, state);
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item is UserItem) {
        if (intOf(item.row['rowId']) == rowId) return chatItemKey(item, i);
      } else if (item is TimelineMarkerItem) {
        if (intOf(item.row['rowId']) == rowId) return chatItemKey(item, i);
      } else if (item is FileSummaryItem) {
        if (intOf(item.header?['rowId']) == rowId) return chatItemKey(item, i);
        if (intOf(item.tailRow?['rowId']) == rowId) return chatItemKey(item, i);
      } else if (item is TurnBarItem) {
        if (intOf(item.work.header?['rowId']) == rowId ||
            item.work.work.any((r) => intOf(r['rowId']) == rowId)) {
          return chatItemKey(item, i);
        }
      }
    }
    return null;
  }

  /// 按通知时刻找最接近的可见行（work/turnHeader 的 createdAt 最近者）。
  int? _rowIdNearestMs(int atMs) {
    final state = _sub?.state;
    if (state == null) return null;
    int? bestId;
    var bestDelta = 1 << 62;
    for (final row in state.rows) {
      // state.rows 元素即行 Map（data/seq 等键平铺在 Map 内）。
      final created = intOf(row['createdAt']);
      if (created == null) continue;
      final delta = (created - atMs).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        bestId = intOf(row['rowId']);
      }
    }
    // 超出一天说明该通知属于更早历史（窗口未加载）——不硬跳。
    final rowId = bestId;
    if (rowId == null || bestDelta > 24 * 3600 * 1000) return null;
    return rowId;
  }

  /// 消费待办深链：会话行就绪后弹一次短暂浮层（SnackBar + 定位动作，
  /// 不阻塞阅读，5s 自动消失）。
  void _maybePromptDeepLink() {
    final sessionId = widget.sessionId;
    if (!mounted || sessionId == null) return;
    if (_deepLinkPromptShown || _deepLinkPromptShownFor == sessionId) return;
    if (_sub?.state.rows.isEmpty ?? true) return; // 行未就绪，等下一次通知
    final app = AppStateScope.of(context);
    // B5：导航参数优先（pendingOpenTask 已被 task_center 清空的时序洞）；
    // 参数只对本页构造传入，归属即本会话，无需再校验 taskId。
    final paramAt = widget.deepLinkAtMs;
    final target = paramAt != null
        ? (taskId: sessionId, atMs: paramAt)
        : app.pendingDeepLinkTarget;
    // 本页深链处理只尝试一次（含无目标/目标属别的会话）——旧实现该
    // 标记恒 false，每次重建都排一个无用的 postFrame 回调。
    _deepLinkPromptShown = true;
    if (target == null) return;
    // 会话归属校验（P2-3a）：通知的目标会话不是本页时不动 pending——
    // 目标页随后打开时再消费。宽屏 keyed 复用（P2-3b）按会话闩锁。
    if (target.taskId != sessionId) return;
    _deepLinkPromptShownFor = sessionId;
    app.pendingDeepLinkAt = null;
    app.pendingDeepLinkTaskId = null;
    final rowId = _rowIdNearestMs(target.atMs);
    if (rowId == null) {
      // P2-3c：零反馈缺陷——给轻提示而非静默吞。
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('相关消息不在当前已加载范围')),
      );
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(
        key: const ValueKey('deeplink-prompt'),
        duration: const Duration(seconds: 5),
        content: const Text('已打开会话——要定位到产生通知的消息吗？'),
        action: SnackBarAction(
          label: tr('定位'),
          onPressed: () {
            if (!mounted) return;
            if (!_jumpToRowStart(rowId)) {
              // 目标不在当前窗口（更早历史）：提示而不静默失败。
              // （外层 ?. 已把 messenger 提升为非空，此处直接调用。）
              messenger.showSnackBar(
                const SnackBar(content: Text('该消息在更早的历史中，请上滑加载')),
              );
            }
          },
        ),
      ),
    );
  }

  bool _jumpToRowStart(int rowId) {
    if (!mounted || !_scroll.hasClients) return false;
    // 行号必须是顶层条目锚键（#3）：回合内工作行映射到所属回合条目，
    // 映射失败=目标不在当前窗口——不写 center/滚动记忆，交调用方提示。
    final anchorKey = _anchorKeyForRow(rowId);
    if (anchorKey == null) {
      ConversationPage.debugLastJumpAnchorKey = null;
      return false;
    }
    ConversationPage.debugLastJumpAnchorKey = anchorKey;
    _followTick?.cancel();
    _followingReconcileGuard++;
    // 成功定位顺带展开所属回合（折叠态下否则只见状态条，看不到命中的
    // 那一行）。collapsed=false 即展开（TurnBar 的覆盖语义两个分支同向）。
    final targetTurn = _cachedChatItems
        .whereType<TurnBarItem>()
        .where(
          (t) =>
              intOf(t.work.header?['rowId']) == rowId ||
              t.work.work.any((r) => intOf(r['rowId']) == rowId),
        )
        .firstOrNull;
    setState(() {
      _stickToBottom = false;
      _listCenterItemKey = anchorKey;
      if (targetTurn != null) {
        _liveCollapsedByRow[targetTurn.work.collapseKeyId] = false;
      }
    });
    if (shouldMarkProgrammaticScroll(_scroll.offset, 0)) {
      _markProgrammatic();
      _scroll.jumpTo(0);
    }
    // 官方 scrollToQuery 在目标挂载后再精对齐；切换 center 后若已有滚动
    // activity 改写了 offset，下一帧有限校正一次并终止旧 activity。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scroll.hasClients || _listCenterItemKey != anchorKey) {
        _followingReconcileGuard--;
        return;
      }
      if (shouldMarkProgrammaticScroll(_scroll.offset, 0)) {
        _markProgrammatic();
        _scroll.jumpTo(0);
      }
      _saveScrollMemory();
      _followingReconcileGuard--;
    });
    _saveScrollMemory();
    return true;
  }

  Future<void> _jumpToLastTurnStart() async {
    if (_turnStartJumpInFlight) return;
    _turnStartJumpInFlight = true;
    try {
      while (mounted) {
        final state = _sub?.state;
        if (state == null) return;
        var target = latestTurnStartRowId(state.rows);
        // A2-P3-11：turnHeader 已到、userInput delta 未落的
        // 窗口期 target 为 null——缺的输入在**新端**而非旧端，等一帧
        // 重查（通常自愈）再考虑拉历史，避免慢链路下连拉多页更早。
        if (target == null) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          if (!mounted) return;
          target = latestTurnStartRowId(_sub?.state.rows ?? const []);
        }
        if (target != null) {
          if (_jumpToRowStart(target)) return;
          // A3-P3-7：目标在 rows 里但列表尚未挂载（内容未建
          // 完成长按 FAB）——等挂载重试，而不是误报「没有找到」。
          for (var i = 0; i < 10 && mounted && !_scroll.hasClients; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          if (!mounted) return;
          if (_scroll.hasClients && _jumpToRowStart(target)) return;
        }
        final st = _sub?.state;
        if (st == null || !st.canLoadOlder) break;
        final progressed = await _loadOlder();
        if (!mounted) return;
        if (!progressed && latestTurnStartRowId(st.rows) == target) break;
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('没有找到本回合开始'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('回到本回合开始失败：$error'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      _turnStartJumpInFlight = false;
    }
  }

  void _openConversationSearch() {
    if (_sessionId == null || _sub?.state == null) return;
    _search.open();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchOpen) _searchFocusNode.requestFocus();
    });
  }

  void _closeConversationSearch() {
    // P3-5（D-8 批4）：关面板取消防抖尾巴——200ms 内关闭时尾沿仍会把
    // query/命中写回控制器，下次打开残留旧词。
    _searchChangeDebounce?.cancel();
    final active = _search.close().activeMatch;
    final reconcile = active != null && _scroll.hasClients
        ? active.kind != ConversationSearchKind.user ||
              (active.sourceText.length / 20).ceil() * 21 > 180
        : false;
    if (reconcile) _followingReconcileGuard++;
    if (reconcile) {
      setState(() {
        _stickToBottom = false;
        _listCenterItemKey = active.anchorKey;
      });
      if (_scroll.offset != 0) {
        _markProgrammatic();
        _scroll.jumpTo(0);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _followingReconcileGuard--;
        _saveScrollMemory();
      });
    }
  }

  void _refreshConversationSearch({bool reset = false}) =>
      _search.refresh(reset: reset);

  /// 搜索输入防抖（ D1-P2-1/D2-05/D3-P2-4）：每键全量重扫
  /// （行文本提取+jsonEncode+全文折叠，1200 行上限）——200ms 合并，
  /// 计数条随输入即时、结果与定位随尾沿。
  Timer? _searchChangeDebounce;
  void _onConversationSearchChanged(String value) {
    _searchChangeDebounce?.cancel();
    _searchChangeDebounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) _search.change(value);
    });
  }

  void _stepConversationSearch(int direction) => _search.step(direction);

  Future<void> _pumpSearchHistory() => _search.pumpHistory();

  String? get _searchPartialNotice => _search.partialNotice;

  Future<void> _locateActiveSearchMatch(ConversationSearchMatch match) async {
    if (!mounted || !_scroll.hasClients) return;
    _search.markLocated(match);
    _search.cancelNavigation();
    final navigation = _searchNavigationId;
    _followTick?.cancel();
    _followingReconcileGuard++;
    try {
      setState(() {
        _stickToBottom = false;
        _listCenterItemKey = match.anchorKey;
      });
      if (_scroll.offset != 0) {
        _markProgrammatic();
        _scroll.jumpTo(0);
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || navigation != _searchNavigationId) return;
      final first = _searchTargetKey.currentContext;
      if (first != null) {
        await Scrollable.ensureVisible(
          first,
          alignment: 0.35,
          duration: Duration.zero,
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 320));
      if (!mounted || navigation != _searchNavigationId) return;
      final settled = _searchTargetKey.currentContext;
      if (settled != null) {
        await Scrollable.ensureVisible(
          settled,
          alignment: 0.35,
          duration: Duration.zero,
        );
      }
      _saveScrollMemory();
    } finally {
      _followingReconcileGuard--;
    }
  }

  /// F17：窗口内任务菜单动作。
  bool _currentTaskPinned(AppState app) {
    final sessionId = _sessionId;
    if (sessionId == null) return false;
    final inModel = app.taskList?.cards.any(
      (c) => c.sessionId == sessionId && c.pinned,
    );
    if (inModel == true) return true;
    return app.workspaceTasks.any(
      (t) => '${t['taskId'] ?? ''}' == sessionId && t['pinned'] == true,
    );
  }

  Future<void> _onTaskMenu(String action) async {
    final app = AppStateScope.of(context);
    final sessionId = _sessionId;
    if (sessionId == null) return;
    // await 后不再解析 context——先取 messenger，防页面退出后
    // deactivated-widget 异常。
    final messenger = ScaffoldMessenger.of(context);
    void snack(String t) => messenger.showSnackBar(
      SnackBar(content: Text(t), duration: const Duration(seconds: 2)),
    );
    try {
      switch (action) {
        case 'workflowRuns':
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => WorkflowRunsPage(sessionId: sessionId),
            ),
          );
          return;
        case 'bgWorks':
          final sub = _sub;
          if (sub == null) return;
          await Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => BackgroundWorksPage(
                sessionId: sessionId,
                state: sub.state,
                onCancel: (sid, workId) async {
                  await AppStateScope.of(context)
                      .cancelBackgroundWork(sid, workId);
                },
              ),
            ),
          );
          return;
        case 'rename':
          final controller = TextEditingController(text: _sessionTitle());
          final title = await showDialog<String>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              title: const Text('重命名任务'),
              content: TextField(
                controller: controller,
                autofocus: true,
                style: const TextStyle(fontSize: AppType.mobileInputSafe),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.pop(dialogContext, controller.text.trim()),
                  child: const Text('保存'),
                ),
              ],
            ),
          );
          controller.dispose();
          if (title != null && title.isNotEmpty) {
            await app.renameTask(sessionId, title);
            snack('已重命名');
          }
          break;
        case 'pin':
          final pinned = _currentTaskPinned(app);
          await app.setTaskPinned(sessionId, !pinned);
          snack(pinned ? '已取消置顶' : '已置顶');
          break;
        case 'unread':
          await app.markTaskUnread(sessionId, unread: true);
          snack('已标为未读');
          break;
        case 'archive':
          await app.archiveTask(sessionId);
          snack('已归档');
          if (mounted) Navigator.of(context).maybePop();
          break;
        case 'copyId':
          await Clipboard.setData(ClipboardData(text: sessionId));
          snack('会话 ID 已复制');
          break;
      }
    } catch (e) {
      snack('操作失败：$e');
    }
  }

  static String _shortModel(String model) {
    if (model.isEmpty) return '';
    final parts = model.split('/');
    return parts.length > 1 ? parts.last : model;
  }

  /// 药丸模型简称（用户 2026-10-18 拍标命名思路）：长名在窄空间不可读，
  /// 语义无歧义优先——deepseek→DPSK；后缀压缩 -flash→F / -air→A /
  /// -lite→L。完整名仍在模型面板里。
  /// 例：GLM-5.3-Flash→GLM-5.3F；deepseek-flash→DPSK-F。
  static String _pillModelLabel(String model) {
    var m = _shortModel(model);
    if (m.isEmpty) return m;
    if (m.toLowerCase().startsWith('deepseek')) {
      m = 'DPSK${m.substring(8)}';
    }
    m = m
        .replaceAllMapped(RegExp('-flash', caseSensitive: false), (_) => 'F')
        .replaceAllMapped(RegExp('-air', caseSensitive: false), (_) => 'A')
        .replaceAllMapped(RegExp('-lite', caseSensitive: false), (_) => 'L');
    return m;
  }

  // ── 工具栏常驻选型（2026-10-17 输入区对齐桌面）──────────────────

  /// 生效权限档（2026-10-23 用户反馈批⑦）：计划=独立开关可并行——
  /// 官方 V4ComposerModeControls.tsx:63 权限单选组排除 plan；
  /// 旧 config.mode='plan' 兼容折算为 build+计划开（官方
  /// execution-state.ts resolveExecutionState 同款折算）。
  /// A3（2026-10-24 修复批）：_appliedMode 退役——accepted 即乐观写回
  /// config（writeBackConfig），桌面端外部改档后 config 变化药丸自然跟随。
  String _effectiveModeOf(ConversationState? state) {
    final cfgMode = '${state?.config?['mode'] ?? ''}';
    final m = _pendingMode ?? (cfgMode == 'plan' ? 'build' : cfgMode);
    return m.isEmpty || m == 'plan' ? 'build' : m;
  }

  /// 计划模式生效值：挂起优先；config.planEnabled 与旧 mode=plan 折算。
  bool _planEnabledOf(ConversationState? state) =>
      _pendingPlan ??
      (state?.config?['planEnabled'] == true ||
          '${state?.config?['mode'] ?? ''}' == 'plan');

  /// 当前权限档显示名（计划另出标记药丸，不再折叠进本药丸）。
  String _modeLabelOf(ConversationState? state) =>
      _modeNames[_effectiveModeOf(state)] ?? '模式';

  /// 当前思考档显示名（挂起优先）。
  String _thoughtLabelOf(ConversationState? state) {
    final v = _pendingThought ?? '${state?.config?['thought'] ?? ''}';
    if (v.isEmpty) return '';
    return _thoughtNames[v] ?? v;
  }

  /// 合并药丸标签（用户 2026-10-19 拍板，参考 Claude 系 App 连排格式）：
  /// 模型与思考档本是一个提交单元（modelSelection），UI 合为一枚药丸
  /// 「模型 · 档」；点开同一面板选择。空档只显模型名，全空回退「模型」。
  // Paseo 参考（2026-10-23）：药丸两级文字——模型名（亮）+档位（暗）。
  String _selectionMain(ConversationState? state) {
    final m = _pillModelLabel(
      _pendingModelId ?? '${state?.config?['model'] ?? ''}',
    );
    if (m.isNotEmpty) return m;
    return _thoughtLabelOf(state).isEmpty ? '模型' : '思考';
  }

  String? _selectionSub(ConversationState? state) {
    final m = _pillModelLabel(
      _pendingModelId ?? '${state?.config?['model'] ?? ''}',
    );
    final t = _thoughtLabelOf(state);
    // 模型缺位时思考档为主体，无次级。
    if (m.isEmpty) return null;
    return t.isEmpty ? null : t;
  }

  /// 在光标处插入触发文本并回焦输入框（+ 弹层 / 技能面板共用）。
  void _insertAtCursor(String text) {
    final sel = _input.selection;
    final offset = sel.isValid ? sel.baseOffset : _input.text.length;
    final t = _input.text;
    final at = offset.clamp(0, t.length);
    _input.text = '${t.substring(0, at)}$text${t.substring(at)}';
    _input.selection = TextSelection.collapsed(offset: at + text.length);
    FocusScope.of(context).requestFocus(_inputFocusNode);
  }

  /// 连接状态点颜色（V2 曾随输入栏 5→4 键整组移除，2026-10-22 用户
  /// 发现常亮状态信号消失——恢复为信息行行首点，语义不变）。
  Color _statusDotColor(BuildContext context) {
    final app = AppStateScope.of(context);
    return switch (app.phase) {
      LinkPhase.online => context.colors.success,
      LinkPhase.reconnecting ||
      LinkPhase.connecting ||
      LinkPhase.waitingDesktop => context.colors.warning,
      LinkPhase.kicked || LinkPhase.invalid => context.colors.destructive,
      _ => context.colors.foregroundSubtlest,
    };
  }

  /// 上下文窗口占用（0..1；无会话/无数据=null）——驱动输入栏状态环。
  double? _contextUsageProgress(ConversationState? state) {
    final cw = state?.usage?['contextWindow'];
    if (cw is! Map) return null;
    final used = numOf(cw['usedTokens']) ?? 0;
    final max = numOf(cw['maxTokens']) ?? 0;
    if (max <= 0) return null;
    return (used / max).clamp(0.0, 1.0);
  }

  /// 状态点开关：用量详情卡（桌面绿色圆圈悬停卡的手机等价物——
  /// 用户 2026-10-17 提议，点击开/再点关）。首次开启拉一次额度快照。
  void _toggleUsageCard() {
    setState(() => _usageCardOpen = !_usageCardOpen);
    // 18077 验收#2：卡关期间套餐可能已切换（挂起选中/发送提交），
    // 开卡时档位与缓存不一致即作废旧快照重拉——否则永远吃旧档数据。
    if (_usageCardOpen &&
        _entCache != null &&
        _entCachePlanKind != _entPlanKind()) {
      _entCache = null;
      _resetStatusCache = null;
    }
    if (_usageCardOpen && _entCache == null && !_entLoading) {
      _loadEntitlement();
    }
  }

  /// 用户反馈：模型/套餐切换后额度卡自动刷新（不等手动关/开）。
  /// 由模型选择的 onPick 回调（_saveDraft 后）和会话 config 变更触发。
  void _refreshEntitlementForPlanChange() {
    // 18077 验收#2：无论卡开关都作废旧档缓存——卡关时不清会让下次
    // 开卡复用旧档快照（toggleUsageCard 的档位比对是双保险）。
    _entCache = null;
    if (_usageCardOpen) {
      _loadEntitlement();
      _loadResetStatus();
    }
  }

  /// 官方 getCodingPlanResetStatus/useCodingPlanReset（coding-plan-reset.ts）。
  /// idempotencyKey：时间戳+随机段（单次核销幂等）。
  Future<Map<String, dynamic>?> _callReset(
    String method,
    Map<String, dynamic> extra,
  ) async {
    final bridge = AppStateScope.of(context).bridge;
    if (bridge == null) return null;
    final res = await bridge.channels.call(Channels.usageStats, method, [
      {
        'preferredProviderId': 'account:${_entFamily()}-${_entPlanKind()}',
        'accountAccess': {
          'type': 'zhipu-account',
          'accountType': _entFamily(),
          'mode': _entPlanKind(),
          'entitled': true,
        },
        ...extra,
      },
    ], timeout: const Duration(seconds: 30));
    return res is Map ? res.cast<String, dynamic>() : null;
  }

  Future<void> _loadResetStatus() async {
    try {
      final s = await _callReset('getCodingPlanResetStatus', const {});
      if (mounted) setState(() => _resetStatusCache = s);
    } catch (_) {}
  }

  /// 核销一次 5 小时重置（确认后调用；成功后双刷新）。
  Future<void> _useReset(String resetType) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重置额度？'),
        content: const Text('将核销一次重置机会，把 5 小时窗口额度恢复满额。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _callReset('useCodingPlanReset', {
        'idempotencyKey':
            'pocket-${DateTime.now().millisecondsSinceEpoch}-'
            '${_sessionId ?? 'draft'}',
        'resetType': resetType,
      });
      messenger.showSnackBar(const SnackBar(content: Text('已重置，额度刷新中')));
      // A3-P3-1：30s RPC 窗口内退页——旧无守卫的 setState 抛
      // dispose 异常被 catch 捕获，误报「重置失败：setState() called
      // after dispose()」（核销其实已成功）。
      if (!mounted) return;
      setState(() {
        _entCache = null;
        _resetStatusCache = null;
      });
      await _loadEntitlement();
      await _loadResetStatus();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('重置失败：$e')));
    }
  }

  Future<void> _loadEntitlement() async {
    final app = AppStateScope.of(context);
    final bridge = app.bridge;
    if (bridge == null) return;
    _entLastAttemptAt = DateTime.now();
    setState(() => _entLoading = true);
    try {
      final res = await bridge.channels.call(
        Channels.usageStats,
        'getEntitlementSnapshot',
        [
          {
            'includeSubscription': true,
            'preferredProviderId':
                'account:${_entFamily()}-${_entPlanKind()}',
            'accountAccess': {
              'type': 'zhipu-account',
              'accountType': _entFamily(),
              'mode': _entPlanKind(),
              'entitled': true,
            },
            'allowDisabledPreferredProvider': true,
          },
        ],
        timeout: const Duration(seconds: 30),
      );
      if (mounted) {
        setState(() {
          _entCache = res is Map ? res.cast<String, dynamic>() : null;
          // 18077 验收#2：记住快照所属档位，供开卡时比对失效。
          _entCachePlanKind = _entPlanKind();
          _entLoadedAt = DateTime.now();
          _entLoading = false;
          _entFailCount = 0;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _entLoading = false;
          _entFailCount++;
        });
      }
    }
  }

  String _entFamily() {
    for (final s in AppStateScope.of(context).conversationStates.values) {
      final p = '${s.config?['provider'] ?? ''}';
      if (p.contains('zai')) return 'zai';
      if (p.contains('bigmodel')) return 'bigmodel';
    }
    return 'bigmodel';
  }

  /// 用户反馈（2026-10-31）：状态环/用量卡跟随当前模型的套餐——此前
  /// 硬编码 individual-coding-plan，切到 Start Plan 模型后额度不变。
  /// 18077 验收#2 修正：当前会话 config 优先（多会话不同套餐互不串档），
  /// 草稿页用挂起 provider；两者皆无才扫全局会话保底。
  String _entPlanKind() => inferEntPlanKind(
        currentProvider: _sessionId == null
            ? null
            : '${AppStateScope.of(context).conversationStates[_sessionId]?.config?['provider'] ?? ''}',
        draftProvider: _pendingModelProvider,
        allProviders: [
          for (final s in AppStateScope.of(context).conversationStates.values)
            '${s.config?['provider'] ?? ''}',
        ],
      );

  Future<void> _showAddSheet() async {
    // entry-polish-1：面板回归纯"添加"语义 5 项（3+2 两行），撤
    // workflow-runs-1 为 7 项溢出加的滚动限高。
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '添加',
                style: TextStyle(
                  fontSize: AppType.uiLg,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              // 2026-10-23 真机反馈：第 6 个入口（语音输入）后单行
              // Row 溢出（6×86=516 > 360 屏可用宽），右缘截断——改
              // Wrap，3×2 两行网格（86+16 间距 = 3 列 290 ≤ 320）。
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 16,
                runSpacing: 18,
                children: [
                  AddAction(
                    icon: Icons.alternate_email,
                    label: '添加上下文',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      final t = _input.text;
                      _insertAtCursor(
                        t.isEmpty || t.endsWith(' ') ? '@' : ' @',
                      );
                    },
                  ),
                  AddAction(
                    icon: Icons.terminal,
                    label: '选择能力',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _loadSubagentCandidates();
                      setState(() {
                        _fileCandidates = const [];
                        _slashCandidates = filterSlashCommands(
                          _slashCommands.cast<SlashCommand>(),
                          '',
                          subagents: _subagentCandidates,
                        );
                      });
                    },
                  ),
                  AddAction(
                    icon: Icons.auto_awesome_outlined,
                    label: '选择技能',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _showSkillsSheet();
                    },
                  ),
                  AddAction(
                    key: const ValueKey('add-attachment'),
                    icon: Icons.attach_file,
                    label: '附件文件',
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _pickAttachments();
                    },
                  ),
                  // 验收回填（2026-10-22）：长按发送键=语音无可发现性——
                  // 补稳定入口于加号面板（与桌面「选择能力/技能」同层）。
                  // 无 AGC 配置构建（开源自建包）隐藏（2026-10-28）。
                  if (voiceRecognitionAvailable)
                    AddAction(
                      key: const ValueKey('add-voice'),
                      icon: Icons.mic_rounded,
                      label: '语音输入',
                      onTap: () {
                        Navigator.pop(sheetContext);
                        _startVoiceInput();
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// `$ 选择技能`：官方 skills.list（conversation.skills() 已备），
  /// 选中插入 `$name `（桌面 ChatPromptActionMenu 同语义）。
  Future<void> _showSkillsSheet() async {
    final app = AppStateScope.of(context);
    List<SkillEntry> skills;
    try {
      skills = await app.listSkills();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('技能列表获取失败：$e')));
      }
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.6,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Text(
                  '选择技能',
                  style: const TextStyle(
                    fontSize: AppType.uiLg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (skills.isEmpty)
                Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Text(
                      '此工作区暂无技能（桌面端安装后可用）',
                      style: TextStyle(color: context.colors.foregroundSubtle),
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: skills.length,
                    itemBuilder: (_, i) {
                      final s = skills[i];
                      return ListTile(
                        leading: const Icon(
                          Icons.auto_awesome_outlined,
                          size: 20,
                        ),
                        title: Text('\$${s.name}'),
                        subtitle:
                            s.description == null || s.description!.isEmpty
                            ? null
                            : Text(
                                s.description!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: AppType.uiSm,
                                  color: context.colors.foregroundSubtle,
                                ),
                              ),
                        trailing: s.enabled
                            ? null
                            : Text(
                                '已禁用',
                                style: TextStyle(
                                  fontSize: AppType.uiSm,
                                  color: context.colors.foregroundSubtlest,
                                ),
                              ),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          _insertAtCursor('\$${s.name} ');
                        },
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 模式选择（2026-10-20 真机反馈修复 + 2026-10-23 用户反馈批⑦重构）：
  /// 计划模式=独立开关、与权限档**并行**（官方
  /// V4ComposerModeControls.tsx:40「Plan 是独立勾选项，三种权限仍为
  /// 单选；只编辑草稿」+ e2e 断言 {mode:'yolo', planEnabled:true} 可叠加）。
  /// - 权限档（build/edit/guarded/yolo）：已有会话**立即下发**
  /// switchCollaborationMode（；CAS 收敛重试扛运行中
  ///   revision 推进）。失败回退挂起随下条 sendText 提交。
  /// - 计划开关：**草稿语义**（官方同款——运行中切换命令
  ///   switchCollaborationMode 无 planEnabled 字段，只能随下条提交）；
  ///   开启后药丸右侧出「计划」标记（官方 plan marker 灯泡同款）。
  Future<void> _showModeSheet(ConversationState? state) async {
    if (widget.readOnly) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('子智能体会话为只读，模式跟随主会话'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    var sheetPlan = _planEnabledOf(state);
    // 批次4：弹层骨架组件化（批次1 内联范式收敛进 app_widgets.showAppSheet）。
    final picked = await showAppSheet<String>(
      context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheet) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                '模式',
                style: TextStyle(
                  fontSize: AppType.uiLg,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            SwitchListTile(
              key: const ValueKey('plan-switch'),
              title: const Text('计划模式'),
              subtitle: Text(
                '先规划再动手，可与权限档并行；随下条消息生效',
                style: TextStyle(
                  fontSize: AppType.uiSm,
                  color: sheetContext.colors.foregroundSubtle,
                ),
              ),
              value: sheetPlan,
              onChanged: (v) {
                setSheet(() => sheetPlan = v);
                // 官方菜单只编辑草稿（不向 Runtime 发命令）——挂起态
                // 即时落到父级，关闭弹层即生效到下条提交。
                setState(() => _pendingPlan = v);
              },
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '权限',
                  style: TextStyle(
                    fontSize: AppType.uiSm,
                    color: sheetContext.colors.foregroundSubtle,
                  ),
                ),
              ),
            ),
            // RadioGroup 祖先管理单选（RadioListTile 的 groupValue/
            // onChanged 自 Flutter 3.32 起废弃）。
            RadioGroup<String>(
              groupValue: _effectiveModeOf(state),
              onChanged: (m) => Navigator.pop(sheetContext, m!),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final m in const ['build', 'edit', 'guarded', 'yolo'])
                    RadioListTile<String>(
                      key: ValueKey('mode-$m'),
                      value: m,
                      // 完全访问=warning 橙（官方 text-warning 药丸铁证，
                      // 用户截图实锤）；自主=icon-blue（官方同款）。
                      activeColor: m == 'yolo'
                          ? sheetContext.colors.warning
                          : m == 'guarded'
                          ? sheetContext.colors.brandAccent
                          : null,
                      title: Text(
                        _modeNames[m] ?? m,
                        style: _effectiveModeOf(state) == m && m == 'yolo'
                            ? TextStyle(color: sheetContext.colors.warning)
                            : null,
                      ),
                      subtitle: Text(
                        _modeDescriptions[m] ?? '',
                        style: TextStyle(
                          fontSize: AppType.uiSm,
                          color: sheetContext.colors.foregroundSubtle,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    // 未点权限档（仅切了计划开关或直接关闭）：计划已随开关即时挂起，
    // 无需进一步动作。
    if (picked == null || !mounted) return;
    if (resolveModePickAction(sessionId: _sessionId) ==
        ModePickAction.pending) {
      setState(() => _pendingMode = picked);
      return;
    }
    // 立即下发：先挂起显示（药丸即时反馈），accepted 后转本地已生效。
    setState(() => _pendingMode = picked);
    // 对抗审查 A1（2026-10-24）：switchCollaborationMode 无 planEnabled
    // 字段，服务端 resolveExecutionState 对任何 success 态权限档都会把
    // planEnabled 置 false（execution-state.ts:12-23）——切档必然关计划
    // （协议无法成对携带，官方桌面靠"切档只改草稿、提交时成对冻结"避开
    // 此坑；我们的立即下发是 用户拍板的偏离）。诚实处置：切档
    // 时计划若开着，提示用户并挂起 planEnabled=false 随下条提交确认——
    // 不让计划静默消失。
    final planWasOn = _planEnabledOf(state);
    // A1-P3-5：权限单选值域只有 build/edit/guarded/yolo 四档
    // ——`picked != 'plan'` 恒真（三处重复的恒真判断误导读者以为存在
    // plan 提交路径），删除。
    if (planWasOn) {
      setState(() => _pendingPlan = false);
    }
    try {
      final res = await AppStateScope.of(context)
          .switchCollaborationMode(_sessionId!, picked);
      if (!mounted) return;
      final status = res is Map ? '${res['status']}' : '';
      if (status == 'accepted' || status == 'duplicate' || status == 'noop') {
        // A3 乐观写回（2026-10-24 修复批）：accepted 即落本地 config，
        // 药丸立即反映提交档；服务端回显同值零闪烁；桌面端外部改档由
        // config 变化自然跟随（_appliedMode 退役——旧记账永不失效，
        // 外部改档后药丸滞留旧值即 A3 病灶）。写回落空（无快照）时
        // 挂起保留作显示载体（随下条提交重携，同值无害）。
        final wbTarget = _sub?.state ?? _cachePreview;
        final wrote =
            wbTarget?.writeBackConfig({
              'mode': picked,
              if (planWasOn) 'planEnabled': false,
            }) ??
            false;
        if (!mounted) return;
        setState(() {
          if (wrote) {
            _pendingMode = null;
            // 计划已随切档被服务端关闭（success 档必关计划）：写回已承载
            // planEnabled=false，挂起同步清。
            if (planWasOn) _pendingPlan = null;
          }
        });
        if (planWasOn) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('计划模式已随权限切换关闭（重新打开请用计划开关）'),
              duration: Duration(seconds: 3),
            ),
          );
        }
      } else {
        // stale（重试耗尽）/rejected/failed：保留挂起，随下条消息提交。
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('「${_modeNames[picked] ?? picked}」将在下条消息时生效（会话正忙）'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('切换失败（$e）；已挂起，将随下条消息提交'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  /// 行级消息操作（波次 3b）：复制/编辑用户消息/重试/点赞点踩。
  void _showRowActions(Map<String, dynamic> row) {
    final app = AppStateScope.of(context);
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final kind = '${row['kind']}';
    final hasEntity = '${row['entityId'] ?? ''}'.trim().isNotEmpty;
    // H1（审计）：conversationRowTargetSchema 的 entityId 必填（strict），
    // 官方 UI 从不发无 entityId 的 target——旧快照行缺 entityId 时只留
    // 纯本地操作（复制），协议操作入口禁用。
    final target = {
      'rowId': row['rowId'],
      if (hasEntity) 'entityId': row['entityId'],
    };
    // A3-P3-2：await RPC 后用 context 查 ScaffoldMessenger 会
    // 抛 deactivated-widget（与 _onTaskMenu 同款）——入口先取。
    final rowMessenger = ScaffoldMessenger.of(context);
    void snack(String t) => rowMessenger.showSnackBar(
      SnackBar(content: Text(t), duration: const Duration(seconds: 3)),
    );
    Future<void> run(Future<dynamic> Function() op) async {
      try {
        // ack status 检查（对抗审查 A2）：sendCommand 对 rejected/stale
        // 耗尽只打日志正常返回——被拒不能当成功。
        final res = await op();
        if (res is Map && res['status'] is String) {
          final st = res['status'] as String;
          if (st != 'accepted' && st != 'duplicate' && st != 'noop') {
            snack('操作未生效（${res['reasonCode'] ?? st}）');
          }
        }
      } catch (e) {
        snack('操作失败：$e');
      }
    }

    final options = <(String, IconData, VoidCallback)>[
      if (kind == 'userInput' || kind == 'assistantText')
        (
          '复制',
          Icons.copy_outlined,
          () {
            // 2026-10-23 用户反馈批⑧：补 SnackBar 反馈（原先静默复制，
            // 用户不知道复制成功了）。
            Clipboard.setData(ClipboardData(text: '${row['text'] ?? ''}'));
            snack('已复制');
          },
        ),
      if (kind == 'assistantText' && row['state'] != 'streaming') ...[
        // H1（target schema entityId 必填）：缺 entityId 的旧快照行禁用
        // 协议入口（服务端 strict 校验必拒；纯本地操作只留复制）。
        if (hasEntity)
          (
            '重试这轮',
            Icons.refresh,
            () => run(() => app.retryTurn(sessionId, target)),
          ),
        if (hasEntity)
          (
            '从这里分支',
            Icons.account_tree_outlined,
            () => run(() => app.forkAssistant(sessionId, target)),
          ),
        (
          row['feedback'] == 'like' ? '取消点赞' : '点赞',
          Icons.thumb_up_outlined,
          () => run(
            () => app.setAssistantFeedback(
              sessionId,
              target,
              row['feedback'] == 'like' ? null : 'like',
            ),
          ),
        ),
        (
          row['feedback'] == 'dislike' ? '取消点踩' : '点踩',
          Icons.thumb_down_outlined,
          () => run(
            () => app.setAssistantFeedback(
              sessionId,
              target,
              row['feedback'] == 'dislike' ? null : 'dislike',
            ),
          ),
        ),
      ],
      if (kind == 'userInput' && hasEntity)
        (
          '编辑并重发',
          Icons.edit_outlined,
          () => _editUserRow(app, sessionId, target, '${row['text'] ?? ''}'),
        ),
    ];
    if (options.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (label, icon, action) in options)
              ListTile(
                leading: Icon(icon, size: 20),
                title: Text(
                  label,
                  style: const TextStyle(fontSize: AppType.uiBase),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  action();
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _editUserRow(
    AppState app,
    String sessionId,
    Map<String, dynamic> target,
    String original,
  ) async {
    final controller = TextEditingController(text: original);
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('编辑消息'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '重发后，这条消息之后的所有回复将被丢弃并重新生成。',
              style: TextStyle(
                fontSize: AppType.uiCaption,
                color: context.colors.warning,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: controller,
              maxLines: 4,
              autofocus: true,
              style: const TextStyle(fontSize: AppType.mobileInputSafe),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('重发'),
          ),
        ],
      ),
    );
    // #14：对话框关闭即释放 controller（此前每次编辑泄漏一个）。
    controller.dispose();
    if (text != null && text.isNotEmpty && mounted) {
      try {
        final res = await app.editUserQuery(sessionId, target, text);
        if (!mounted) return;
        // 复用 run() 的 ack 范式（#11）：sendCommand 对 rejected/stale
        // 耗尽只打日志正常返回——被拒不能当成功。
        if (res is Map && res['status'] is String) {
          final st = res['status'] as String;
          if (st != 'accepted' && st != 'duplicate' && st != 'noop') {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('操作未生效（${res['reasonCode'] ?? st}）'),
                duration: const Duration(seconds: 3),
              ),
            );
          }
        }
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('编辑失败：${humanizeError(e)}'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  /// 附件查看（波次 3b → 阶段 3 第三段按官方语义仲裁重写）：
  /// 授权面只有 userInput 行自身（v4-gateway resolveReadableMediaAttachment，
  /// v4-gateway.ts:2204-2277）——image/* 与 video/* 与 application/pdf、
  /// 以及 text/plain 且 sourceKind∈{topic-history,clipboard-text} 可预览；
  /// 调用构造=官方 openXxxPreview（video/pdf/text 必须 target{rowId,
  /// entityId=消息id}+attachmentIndex 成对，image 可 ref-only）。
  /// 工具结果 ref（toolCall 行输出）不在授权面——previewRefNotAuthorized
  /// 是官方设计边界（阶段 2 遗留 P1 定论， 批）。
  Future<void> _openAttachmentAt(Map<String, dynamic> row, int index) async {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    final list = _attachmentsOf(row);
    if (index < 0 || index >= list.length) return;
    final att = list[index];
    final fileName = '${att['fileName'] ?? att['filename'] ?? '附件'}';
    final mime = '${att['mime'] ?? ''}'.toLowerCase();
    final sourceKind = '${att['sourceKind'] ?? ''}';
    final isTextMaterial =
        mime == 'text/plain' &&
        (sourceKind == 'topic-history' || sourceKind == 'clipboard-text');
    // 视频/PDF 没有播放/渲染插件（协议读取返回原始字节，Image.memory 只会
    // 显示「非图片附件」）：明确前置提示且**不发起读取**——旧实现把它们
    // 算进 previewable，专用提示分支永不可达，还会白拉整包字节。
    final isVideoOrPdf = mime.startsWith('video/') || mime == 'application/pdf';
    final previewable = mime.startsWith('image/') || isTextMaterial;
    if (!previewable) {
      if (isVideoOrPdf) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('视频/PDF 预览排在后续版本，当前可在电脑端查看'),
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('该附件类型不支持预览（仅图片/文本材料）'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    // 官方 target 构造：rowId+entityId（userInput 行的 entityId=消息id）。
    final rowId = row['rowId'];
    final entityId = '${row['entityId'] ?? ''}';
    Map<String, dynamic>? target;
    int? attIdx;
    if (rowId is int && entityId.isNotEmpty) {
      target = {'rowId': rowId, 'entityId': entityId};
      attIdx = index;
    }
    // 带 target 时官方 matchesRef 双匹配（ref‖previewRef），用原始 ref；
    // 无 target 的 image 走 legacy 路径必须 previewRef ?? ref。
    final refForRead = target != null
        ? '${att['ref']}'
        : '${att['previewRef'] ?? att['ref']}';
    try {
      final data = await AppStateScope.of(context).attachmentRead(
        sessionId,
        refForRead,
        target: target,
        attachmentIndex: attIdx,
      );
      if (!mounted) return;
      if (isTextMaterial) {
        // A1-P2-3/A3-P2-2：attachmentRead 返回原始文件字节
        // （UTF-8）——String.fromCharCodes 逐字节当码元，中文/emoji 全
        // 乱码；allowMalformed 容忍残缺尾字节。
        final text = utf8.decode(data.bytes, allowMalformed: true);
        showDialog<void>(
          context: context,
          builder: (dialogContext) => Dialog(
            insetPadding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    fileName,
                    style: const TextStyle(fontSize: AppType.uiCaption),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Text(
                        text,
                        style: const TextStyle(
                          fontSize: AppType.uiCaption,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('关闭'),
                ),
              ],
            ),
          ),
        );
        return;
      }
      showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  fileName,
                  style: const TextStyle(fontSize: AppType.uiCaption),
                ),
              ),
              Flexible(
                child: InteractiveViewer(
                  maxScale: 4,
                  child: Image.memory(
                    Uint8List.fromList(data.bytes),
                    errorBuilder: (_, _, _) => Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        '非图片附件（${data.mediaType ?? '未知类型'}，'
                        '${data.bytes.length} 字节）',
                        style: TextStyle(
                          fontSize: AppType.uiCaption,
                          color: context.colors.foregroundSubtle,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('附件读取失败：$e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  /// 用户行的附件引用列表（attachmentRefSchema：kind/filename/ref/mimeType）。
  List<Map<String, dynamic>> _attachmentsOf(Map<String, dynamic> row) {
    final list = row['attachments'];
    if (list is! List) return const [];
    return list.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
  }

  void _captureReasoningElapsed(List<Map<String, dynamic>> rows) =>
      _viewStore.captureReasoningElapsed(rows);

  int? _reasoningElapsedOf(Map<String, dynamic> row) =>
      _viewStore.reasoningElapsedOf(row);

  DateTime? _firstSeenOf(Map<String, dynamic> row) =>
      _viewStore.firstSeenOf(row);

  Future<void> _openConversationSession(
    BuildContext context, {
    required String sessionId,
    required String title,
    required bool readOnly,
  }) async {
    // A1-P3-8/A3-P2-3：进入子页前留 app 引用——子页 pop 后
    // 其 dispose 会清 viewingSessionId，父页（常驻其下）无人回填=正在
    // 查看的会话失去通知抑制（用户盯着看仍发系统通知）。返回时只在
    // 无人认领（null）时恢复本会话，不抢新顶层的上报。
    final app = AppStateScope.of(context);
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConversationPage(
          sessionId: sessionId,
          title: title,
          readOnly: readOnly,
        ),
      ),
    );
    if (mounted && _sessionId != null) {
      // 子页 pop 的 await 先于退出动画完成，dispose 往往还没清查看态
      // ——按"仍是子会话认领中"也允许接回；父页重报后子页 dispose 的
      // 归属校验（见本类 dispose）不会再把它清掉。
      final claimed = app.viewingSessionId;
      if (claimed == null || claimed == sessionId) {
        app.viewingSessionId = _sessionId;
        // 子页 dispose 已/将上报退出查看态（reportTaskView(null)）——
        // 回到本页必须重报，否则桌面端仍按"未查看"抑未读/推通知。
        app.reportTaskView(_sessionId);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final app2 = AppStateScope.of(context);
    // 6.2 选分支：顶栏分支标签懒加载（缓存键守卫，见方法注）。
    _maybeLoadBranchInfo(app2);
    final state = _sub?.state;
    // C6（2026-10-19 审查）：键盘弹起（insets 变化）时粘底会话重新贴底
    // ——原唯一触发是数据通知，流式静默期弹键盘会把输入栏压到内容之下。
    // 只加触发；12 帧自驱动核心与拖拽即停阀不动（介入点 1 修出的粘底
    // 机制一行不改）。
    final insets = MediaQuery.of(context).viewInsets.bottom;
    if (insets != _lastInsetBottom) {
      _lastInsetBottom = insets;
      if (_stickToBottom && _scroll.hasClients) {
        _followUntilStable();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients || !_stickToBottom) return;
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        });
      }
    }
    // #8：草稿发送期（_sending、会话未建立）没有可停的回合——
    // 显示停止键点了必静默无效。
    // 批4 反馈①链上发现（2026-10-23）：缓存预渲期（live 快照未到）
    // running 也应认缓存 control——运行中任务从任务卡点入，停止键随
    // 首帧即可用，不必等 live 订阅到位（消息列表同款回落条件；
    // sessionId null 草稿不走缓存预渲，#8 约束不受影响）。
    final effState = (state == null || (!state.ready && state.rows.isEmpty))
        ? (_cachePreview ?? state)
        : state;
    final running = effState?.isRunning == true;
    final draftWorkspace = _draftWorkspaceLabel(app2);
    return Scaffold(
      appBar: AppBar(
        // V1 审美优化：顶栏高度全库统一 52（任务中心同款）。
        toolbarHeight: 52,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _sessionTitle(),
              translate: false,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: AppType.uiBase),
            ),
            // Paseo 参考（2026-10-23）：副行标当前电脑——多电脑场景核心
            // 诉求"这条会话连的是哪台"常驻可见（浅灰小字+电脑图标；
            // 无活跃档案时不占位）。6.2 选分支：分支标签同排尾接
            // （工作区级 git 状态；两者独立出现，任一存在即渲染本行；
            // 非 git 仓库/加载失败分支段不占位；点按进分支弹层——draft
            // 态切完再发消息=会话跑在新分支上）。
            if (_deviceLabel != null || _branchCurrent != null)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_deviceLabel != null) ...[
                    Icon(
                      Icons.computer,
                      size: 10,
                      color: context.colors.foregroundSubtlest,
                    ),
                    const SizedBox(width: 3),
                    Flexible(
                      child: Text(
                        _deviceLabel!,
                        translate: false,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.foregroundSubtle,
                        ),
                      ),
                    ),
                  ],
                  if (_branchCurrent != null) ...[
                    if (_deviceLabel != null) const SizedBox(width: 8),
                    Flexible(
                      child: InkWell(
                        key: const ValueKey('branch-entry'),
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                        onTap: () => _openBranchSheet(app2),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 2,
                            horizontal: 4,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.call_split,
                                size: 10,
                                color: context.colors.foregroundSubtlest,
                              ),
                              const SizedBox(width: 3),
                              Flexible(
                                child: Text(
                                  _branchCurrent!,
                                  translate: false,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: AppType.uiXs,
                                    color: context.colors.foregroundSubtle,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            if (running)
              Text(
                '运行中…',
                style: TextStyle(
                  fontSize: AppType.uiXs,
                  color: context.colors.foregroundSubtle,
                ),
              ),
          ],
        ),
        actions: [
          if (state != null && _sessionId != null)
            IconButton(
              key: const ValueKey('conversation-search-entry'),
              icon: Icon(
                Icons.search,
                size: 20,
                color: _searchOpen ? context.colors.accent : null,
              ),
              tooltip: tr('任务内查找'),
              onPressed: _openConversationSearch,
            ),
          // 子代理列表入口（2026-10-26 批④拍板⑥）：长会话免翻找，直达
          // 本会话全部子智能体（运行中/已结束+下钻只读会话）。
          if (state != null && _sessionId != null)
            IconButton(
              key: const ValueKey('subagents-entry'),
              icon: const Icon(Icons.smart_toy_outlined, size: 20),
              tooltip: tr('子智能体'),
              onPressed: () => showSubagentListSheet(
                context,
                sessionId: _sessionId!,
                openSession: _openConversationSession,
              ),
            ),
          // F17（WR 对齐）：窗口内任务操作菜单（桌面 TaskActionMenu 对位）。
          if (state != null && _sessionId != null)
            PopupMenuButton<String>(
              key: const ValueKey('task-menu'),
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (v) => _onTaskMenu(v),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'rename', child: Text('重命名')),
                PopupMenuItem(
                  value: 'pin',
                  child: Text(_currentTaskPinned(app2) ? '取消置顶' : '置顶'),
                ),
                const PopupMenuItem(value: 'unread', child: Text('标为未读')),
                const PopupMenuItem(value: 'archive', child: Text('归档')),
                // 工作流运行入口（entry-polish-1，用户拍板方案 A）：
                // 低频查看型入口归任务菜单，加号面板回归纯"添加"语义。
                const PopupMenuItem(
                  value: 'workflowRuns',
                  child: Text('工作流运行'),
                ),
                // 后台工作二级页入口（compactness-feedback-1109 反馈②）：
                // 完全撤出输入区一级空间——有后台工作才出现在菜单，带
                // 计数；一级感知=任务卡后台小点（B 批既有）。
                if ((_sub?.state.backgroundWorks ?? const []).isNotEmpty)
                  PopupMenuItem(
                    value: 'bgWorks',
                    child: Text(
                        '后台工作 · ${_sub!.state.backgroundWorks.length}'),
                  ),
                const PopupMenuItem(value: 'copyId', child: Text('复制会话 ID')),
              ],
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: context.colors.border),
        ),
      ),
      body: Column(
        children: [
          if (_searchOpen)
            ConversationSearchBar(
              controller: _searchController,
              focusNode: _searchFocusNode,
              query: _searchController.text,
              matches: _searchMatches,
              activeIndex: _searchActiveIndex,
              loading: _searchLoading,
              truncated: _searchTruncated,
              error: _searchError,
              partialNotice: _searchPartialNotice,
              onChanged: _onConversationSearchChanged,
              onPrevious: () => _stepConversationSearch(-1),
              onNext: () => _stepConversationSearch(1),
              onClose: _closeConversationSearch,
              onRetry: _search.retry,
            ),
          // 桥降级/恢复期反馈（P2-4 统一叙事的一部分）：会话页不再静默
          if (state != null && app2.phase != LinkPhase.online)
            Material(
              color: context.colors.linkBlue.withValues(alpha: AppAlpha.light),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 5,
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        // D2（2026-10-26 断线批）：relay 已连而桥未建时
                        // "连接恢复中"是假话——横幅说正在恢复工作区；
                        // 其余档的括号内容来自 computeStatusDetail（不再
                        // 出现空括号——此前 error/reconnecting 档返回空串）。
                        app2.workspaceRestoring
                            ? '连接已恢复，正在重新打开工作区…'
                            : '连接恢复中…（${tr(app2.phaseDetail ?? '网络波动')}）消息将在恢复后继续',
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.linkBlue,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // 缓存同步中提示（阶段 3）：当前内容来自本地缓存（页面预渲或
          // 订阅种子），实时帧到达后自动切换（点按可重试订阅）。
          if (_cachePreview != null &&
                  (state == null || (!state.ready && state.rows.isEmpty)) ||
              _sub != null &&
                  state != null &&
                  state.ready &&
                  !_sub!.hasLiveFrames)
            Material(
              key: const ValueKey('cache-sync-strip'),
              // A2-P3-1：strip 只认订阅错误专档（_syncError）——
              // 发送/停止失败渗入 _error 时不得被误标成「同步失败」。
              color:
                  (_syncError == null
                          ? context.colors.linkBlue
                          : context.colors.destructive)
                      .withValues(alpha: AppAlpha.faint),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 5,
                ),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _syncError == null ? null : _retrySubscribe,
                  child: Row(
                    children: [
                      if (_syncError == null)
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        const Icon(Icons.error_outline, size: 13),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _syncError == null
                              ? '正在同步最新消息…（当前显示本地缓存）'
                              : '同步失败：$_syncError（当前显示本地缓存，点按重试）',
                          style: TextStyle(
                            fontSize: AppType.uiXs,
                            color: _syncError == null
                                ? context.colors.linkBlue
                                : context.colors.destructive,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // 发送类错误显示顶部横幅；订阅类错误在内容区带重试按钮展示。
          // 回合失败可见性（介入点 2 实锤修复）：createSession 已受理但
          // 服务端约 200ms 打挂回合（phase=error，如选了不可用模型）——
          // 此前零提示用户只能干等。与发送错误同横幅。
          // A1（2026-10-19 审查）：原门禁 `_sub?.state != null` 把草稿态
          // （无订阅）的发送错误全部吞掉——createSession 本身失败时界面
          // 退回"发送第一条消息"零提示。现在 _error 在草稿态或已有订阅
          // 时都渲染；已有会话的 phase=error 路径语义不变（订阅失败仍由
          // 内容区加载态+重试呈现，不进本横幅）。
          if ((_error != null && (_sub?.state != null || _sessionId == null)) ||
              (_sub?.state != null &&
                  _sub!.state.phase == 'error' &&
                  !_sub!.state.isRunning))
            Material(
              color: context.colors.destructive.withValues(
                alpha: AppAlpha.faint,
              ),
              child: Padding(
                // 独立视觉复核必修3（2026-11-07）：3 行形态时 6dp 上下
                // 内距糊成红墙——提到 12dp（横向 16 不变）。
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 14,
                      color: context.colors.destructive,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _error ??
                            '这条消息服务端处理失败（常见原因：所选模型不可'
                                '用）。换模型后重发即可',
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.destructive,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, viewportCons) {
                // 视口缩小（键盘弹起/输入卡多行展开）时粘底跟随——
                // ListView 视口变小不会自动滚，最后一条会沉到输入卡后
                // （用户实锤「输入框展开挡住对话底部」）。
                final last = _lastViewportH;
                if (last != null &&
                    viewportCons.maxHeight < last - 1 &&
                    _stickToBottom) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _jumpToBottom();
                  });
                }
                _lastViewportH = viewportCons.maxHeight;
                // 视口缩小（键盘弹起/审批横幅出现）后旧停靠位可能沉出
                // 界外被 Stack 裁掉——拉回界内（球消失的用户观感即此）。
                final rest = _fabRest;
                final maxDx = viewportCons.maxWidth - 48;
                final maxDy = viewportCons.maxHeight - 48;
                if (_fabDragging == null &&
                    rest != null &&
                    maxDx >= 0 &&
                    maxDy >= 0 &&
                    (rest.dx > maxDx || rest.dy > maxDy)) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) {
                      setState(() {
                        _fabRest = Offset(
                          rest.dx.clamp(0.0, maxDx),
                          rest.dy.clamp(0.0, maxDy),
                        );
                      });
                    }
                  });
                }
                return GestureDetector(
                  // 验收①：详情卡开着时，点消息区任意位置收起（除绿点开关
                  // 外的第二关闭路径，桌面 hover 消失语义的手机等价）。
                  behavior: HitTestBehavior.translucent,
                  onTap: _usageCardOpen
                      ? () => setState(() => _usageCardOpen = false)
                      : null,
                  // 验收（2026-10-18）：内容不足一屏时列表不参与手势竞争，
                  // 竖向下滑由此兜底接收 → 收起输入法（可滚动时列表胜出，
                  // 既有 F19 滚动收键盘路径不变）。
                  onVerticalDragEnd: (_) => _inputFocusNode.unfocus(),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        // 缓存首帧（阶段 3）：live 快照未到且本地缓存可用 →
                        // 先渲缓存（复用同一渲染器），快照到达自动让位。
                        child: () {
                          final cacheState =
                              (state == null ||
                                  (!state.ready && state.rows.isEmpty))
                              ? _cachePreview
                              : null;
                          if (cacheState != null) {
                            return _buildMessageList(cacheState);
                          }
                          return state == null
                              ? _buildLoadingOrDraft()
                              : _buildMessageList(state);
                        }(),
                      ),
                      // F15：回到底部（官方常见聊天 UX；回溯历史后一键回底）。
                      // 2026-10-22 用户反馈补：悬浮球可拖动、松手吸左右边
                      // （tap=跳底，pan=拖动，手势不冲突）。
                      // 2026-10-25 问题②：缓存预渲期也要有——冻结重进
                      // live state 尚未就绪时列表已是缓存渲染，用户上滑
                      // 翻读后没箭头回不了底（真机实锤「展开之后没有
                      // 一键到底」的主场景）。
                      if ((state != null || _cachePreview != null) &&
                          !_stickToBottom)
                        () {
                          Offset fabDefault() => Offset(
                            viewportCons.maxWidth - 48 - 14,
                            viewportCons.maxHeight - 48 - 14,
                          );
                          final fabPos =
                              _fabDragging ?? _fabRest ?? fabDefault();
                          // 2026-11-05 反馈③（A 一次性引导）：悬浮球首次
                          // 出现时 SnackBar 提示长按菜单，持久化标记只提
                          // 一次（每页 State 只查一次，读写走 postFrame）。
                          if (!_fabHintChecked) {
                            _fabHintChecked = true;
                            // asserts 态（flutter test 全生态）抑制引导：
                            // 测试环境 UiPrefs 恒为未展示，SnackBar 会混进
                            // 像素基线且动画帧不定；release/profile 真机
                            // 照常展示一次。
                            bool assertsOn = false;
                            assert(() {
                              assertsOn = true;
                              return true;
                            }());
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (!mounted ||
                                  (assertsOn &&
                                      !ConversationPage.debugFabHintForce)) {
                                return;
                              }
                              final app = AppStateScope.of(context);
                              if (app.uiPrefs.fabMenuHintShown) return;
                              app.uiPrefs.setFabMenuHintShown();
                              ScaffoldMessenger.of(context).showSnackBar(
                                // 独立视觉复核必修1（2026-11-07）：默认
                                // fixed 行为整条压住输入栏（实测盖掉输入
                                // 框 78%+整颗发送键）——floating+底缘
                                // margin 抬到输入栏之上。
                                SnackBar(
                                  behavior: SnackBarBehavior.floating,
                                  margin: const EdgeInsets.only(
                                    left: 16,
                                    right: 16,
                                    bottom: 96,
                                  ),
                                  content: const Text(
                                    // 晚到一路复核必修2：原 20 字在
                                    // 343dp 宽度换行出单字孤行——去两「本」。
                                    '长按悬浮球：回到回合开始 / 收起输出',
                                  ),
                                  duration: const Duration(seconds: 4),
                                ),
                              );
                            });
                          }
                          return AnimatedPositioned(
                            key: const ValueKey('jump-bottom'),
                            duration: _fabDragging == null
                                ? const Duration(milliseconds: 250)
                                : Duration.zero,
                            curve: Curves.easeOutCubic,
                            left: fabPos.dx,
                            top: fabPos.dy,
                            child: Listener(
                              behavior: HitTestBehavior.opaque,
                              onPointerDown: (e) {
                                _fabPointer = e.pointer;
                                _fabPointerDown = e.position;
                                _fabDragStartPos = fabPos;
                                _fabLongPressTriggered = false;
                              },
                              onPointerMove: (e) {
                                if (e.pointer != _fabPointer ||
                                    _fabPointerDown == null) {
                                  return;
                                }
                                final total = e.position - _fabPointerDown!;
                                if (total.distance < 4) return; // 抖动死区
                                setState(() {
                                  _fabDragging = Offset(
                                    // A2-P3-7/A3-P3-6：视口 <48px
                                    // 时上限为负=clamp 抛 ArgumentError
                                    // ——上限先钳到 ≥0。
                                    (_fabDragStartPos!.dx + total.dx).clamp(
                                      0.0,
                                      math.max(
                                        0.0,
                                        viewportCons.maxWidth - 48,
                                      ),
                                    ),
                                    (_fabDragStartPos!.dy + total.dy).clamp(
                                      0.0,
                                      math.max(
                                        0.0,
                                        viewportCons.maxHeight - 48,
                                      ),
                                    ),
                                  );
                                });
                              },
                              onPointerUp: (e) {
                                if (e.pointer != _fabPointer) return;
                                final total = _fabPointerDown == null
                                    ? Offset.zero
                                    : e.position - _fabPointerDown!;
                                if (_fabLongPressTriggered) {
                                  _fabPointer = null;
                                  _fabPointerDown = null;
                                  _fabLongPressTriggered = false;
                                  return;
                                }
                                _fabPointer = null;
                                _fabPointerDown = null;
                                if (total.distance < 8) {
                                  setState(() => _stickToBottom = true);
                                  _scrollToBottom();
                                  return;
                                }
                                _fabSnapToEdge(fabPos, viewportCons);
                              },
                              onPointerCancel: (e) {
                                if (e.pointer != _fabPointer) return;
                                _fabLongPressTriggered = false;
                                _fabPointer = null;
                                _fabPointerDown = null;
                                _fabSnapToEdge(fabPos, viewportCons);
                              },
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onLongPress: () {
                                  _fabLongPressTriggered = true;
                                  _showTurnQuickActions();
                                },
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: Stack(
                                    clipBehavior: Clip.none,
                                    children: [
                                      Center(
                                        child: Material(
                                          color: context.colors.card,
                                          elevation: 2,
                                          shape: const CircleBorder(),
                                          child: SizedBox(
                                            width: 40,
                                            height: 40,
                                            child: Icon(
                                              Icons.arrow_downward,
                                              size: 18,
                                              color: context
                                                  .colors
                                                  .foregroundSubtle,
                                            ),
                                          ),
                                        ),
                                      ),
                                      // 2026-11-05 反馈③（B 常驻角标）：
                                      // 右下小「⋮」暗示藏有长按菜单
                                      //（回到本回合开始/收起展开——纯
                                      // 长按无任何发现性）。
                                      Positioned(
                                        right: 0,
                                        bottom: 0,
                                        child: Container(
                                          width: 14,
                                          height: 14,
                                          decoration: BoxDecoration(
                                            color: context.colors.card,
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: context.colors.border,
                                            ),
                                          ),
                                          child: Icon(
                                            Icons.more_horiz,
                                            size: 10,
                                            color: context
                                                .colors
                                                .foregroundSubtle,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }(),
                    ],
                  ),
                );
              },
            ),
          ),
          // 配额横幅（官方 ConversationQuotaBanner 手机版；快照陈旧>10min
          // 才重拉——外部 API，避免每次进页都打；失败后按 A4 退避压制）。
          Builder(
            builder: (_) {
              final stale = entitlementShouldReload(
                now: DateTime.now(),
                loadedAt: _entLoadedAt,
                lastAttemptAt: _entLastAttemptAt,
                failCount: _entFailCount,
              );
              if (stale && !_entLoading) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _loadEntitlement();
                });
              }
              // PF-1 修复批：官方总门——活跃 provider 为 Start Plan 家族
              // 且与快照一致才出桶式横幅（Coding Pro 载荷整路拦截）；
              // 低额提醒走"展示即记录"持久化（UiPrefs，官方 reminderStore
              // 语义），本页实例已展示过的键继续显示（owner 语义）。
              final cfg = _sub?.state.config;
              final cfgModel = '${cfg?['model'] ?? ''}';
              final qs = buildQuotaBannerState(
                _entCache,
                activeProviderId: '${cfg?['provider'] ?? ''}',
                modelId: cfgModel.contains('/')
                    ? cfgModel.substring(cfgModel.indexOf('/') + 1)
                    : cfgModel,
              );
              if (qs == null) return const SizedBox.shrink();
              if (!qs.exhausted) {
                if (_quotaDismissedKeys.contains(qs.reminderKey)) {
                  return const SizedBox.shrink();
                }
                final shownHere = _quotaShownKeys.contains(qs.reminderKey);
                if (!shownHere) {
                  final prefs = AppStateScope.of(context).uiPrefs;
                  if (prefs.isQuotaReminderHidden(
                    qs.reminderKey,
                    qs.referenceTime ?? 0,
                  )) {
                    return const SizedBox.shrink();
                  }
                  _quotaShownKeys.add(qs.reminderKey);
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    AppStateScope.of(context).uiPrefs.markQuotaReminderShown(
                      qs.reminderKey,
                      qs.reminderExpiresAt ?? 0,
                      qs.referenceTime ?? 0,
                    );
                  });
                }
              }
              return QuotaBanner(
                state: qs,
                dismissedKeys: _quotaDismissedKeys,
                onDismiss: () =>
                    setState(() => _quotaDismissedKeys.add(qs.reminderKey)),
              );
            },
          ),
          // Goal 面板（有目标时置顶于 chrome 区）
          if (state != null) GoalPanel(state: state, sessionId: _sessionId),
          // 审批横幅（pendingInteractions，先到先得）
          if (state != null)
            // V3 动效包#4：审批横幅从输入栏方向滑入（250ms 一次性）。
            SlideIn(
              child: InteractionBanner(state: state, sessionId: _sessionId),
            ),
          if (state != null) QueueStrip(state: state, sessionId: _sessionId),
          ComposerPanels(
            slashCandidates: _slashCandidates,
            fileCandidates: _fileCandidates,
            onPick: _insertCompletion,
            // ②：不选也能收起（原仅输入变化路径可关——空输入时触不到）。
            onClose: () => setState(() {
              _slashCandidates = const [];
              _fileCandidates = const [];
            }),
          ),
          // 用量详情卡（状态点开关，桌面悬停卡的手机等价物——用户设计）。
          if (_usageCardOpen)
            Builder(
              builder: (_) {
                final cwNow = state?.usage?['contextWindow'];
                final bdNow = cwNow is Map ? cwNow['breakdown'] : null;
                if (bdNow is List && bdNow.isNotEmpty) {
                  _lastBreakdown[_sessionId ?? ''] = bdNow
                      .whereType<Map>()
                      .toList();
                }
                return ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.55,
                  ),
                  child: SingleChildScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    child: ContextDetailsCard(
                      state: state ?? ConversationState(),
                      entitlement: _entCache,
                      entitlementLoading: _entLoading,
                      resetStatus: _resetStatusCache,
                      onUseReset: _useReset,
                      cachedBreakdown: _lastBreakdown[_sessionId ?? ''],
                      onCompact:
                          _sessionId != null &&
                              (state != null || _cachePreview != null)
                          ? () => _sendCompact(AppStateScope.of(context))
                          : null,
                    ),
                  ),
                );
              },
            ),
          // 信息条（用户 2026-10-17 设计定稿二）：上下文用量+模式紧凑左组，

          // 模型/思考/状态开关在输入卡内——各归其位，无大片空白。

          // 2026-10-22：数据源兼容缓存预渲（订阅种子到达前的打开瞬间

          // 信息条常驻，不闪没；视觉验收 S03 工装同路径）。
          if (state != null || _cachePreview != null)
            InfoRow(
              state: state ?? _cachePreview!,

              sessionId: _sessionId,

              modeLabel: _modeLabelOf(effState),

              modeIcon: switch (_effectiveModeOf(effState)) {
                // 官方图标映射 display.tsx:252-275：yolo=ShieldAlert、

                // build=Hand、edit/guarded=ShieldCheck。
                'yolo' => Icons.gpp_maybe_outlined,

                'edit' || 'guarded' => Icons.verified_user_outlined,

                _ => Icons.front_hand_outlined,
              },

              // 完全访问=warning 橙（官方 yolo 选中→text-warning #ff8a30，

              // 用户截图实锤）；自主=icon-blue 同官方。
              modeIconColor: switch (_effectiveModeOf(effState)) {
                'yolo' => context.colors.warning,

                'guarded' => context.colors.brandAccent,

                _ => context.colors.foreground,
              },

              modeLabelColor: _effectiveModeOf(effState) == 'yolo'
                  ? context.colors.warning
                  : null,

              modePending: _pendingMode != null,

              planEnabled: _planEnabledOf(effState),

              onModeTap: () => _showModeSheet(effState),
            ),

          // ── 状态托盘（status-tray-1109，用户拍板）：输入侧状态合并
          // 治理——结果未知/暂存/排队 三源（compactness-feedback-1109
          // 反馈②：后台工作整类撤出输入区，归 ⋮ 二级页）。单源直通原
          // 条带（零回归），≥2 源合并成一行摘要（段点+计数），展开=
          // 限高 240 堆叠原条带（撤销/核对动作原样）。
          Builder(builder: (_) {
            Widget unknownBody() => Padding(
              key: const ValueKey('draft-submission-unknown'),
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
              child: Row(
                children: [
                  Icon(
                    Icons.help_outline,
                    size: 15,
                    color: context.colors.warning,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _resultUnknownConverged
                          ? tr('已确认上次发送送达（无需重发），横幅稍后消失')
                          : tr('上次发送结果未知，请核对会话后再决定是否重发'),
                      style: TextStyle(
                        fontSize: AppType.uiXs,
                        color: _resultUnknownConverged
                            ? context.colors.success
                            : context.colors.warning,
                      ),
                    ),
                  ),
                  if (!_resultUnknownConverged)
                    TextButton(
                      key: const ValueKey('draft-unknown-recheck'),
                      onPressed: _busyResultRecheck
                          ? null
                          : () => unawaited(_recheckLastSendResult()),
                      child: Text(tr('重新核对')),
                    ),
                ],
              ),
            );
            Widget unsentBody() => Row(
              key: const ValueKey('status-tray-unsent'),
              children: [
                Expanded(
                  child: Text(
                    '有一条发送失败的消息已暂存',
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: context.colors.warning,
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey('restore-unsent'),
                  onPressed: _restoreUnsentDraft,
                  child: const Text('恢复'),
                ),
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    key: const ValueKey('discard-unsent'),
                    padding: EdgeInsets.zero,
                    iconSize: 16,
                    tooltip: tr('丢弃暂存消息'),
                    onPressed: () {
                      setState(() => _unsentDraft = null);
                      _onDraftMutated();
                    },
                    icon: const Icon(Icons.close),
                  ),
                ),
              ],
            );
            Widget queueBody() => OfflineSendQueueStrip(
              entries: _queueEntries,
              expanded: true,
              onToggle: () => setState(_queue.toggleExpanded),
              onCancel: _cancelQueuedEntry,
            );
            final sections = <StatusTraySection>[
              if (_draftResultUnknown || _resultUnknownConverged)
                StatusTraySection(
                  id: 'unknown',
                  label: _resultUnknownConverged ? tr('已确认送达') : tr('结果未知'),
                  detail: '',
                  accent: _resultUnknownConverged
                      ? context.colors.success
                      : context.colors.warning,
                  body: unknownBody,
                ),
              if (_unsentDraft != null)
                StatusTraySection(
                  id: 'unsent',
                  label: tr('暂存消息'),
                  detail: '',
                  accent: context.colors.warning,
                  body: unsentBody,
                ),
              if (_queueEntries.isNotEmpty && !widget.readOnly)
                StatusTraySection(
                  id: 'queue',
                  label: tr('排队'),
                  detail: '${_queueEntries.length} ${tr('条')}',
                  accent: context.colors.brandAccent,
                  body: queueBody,
                ),
            ];
            return StatusTray(
              sections: sections,
              expanded: _statusTrayExpanded,
              onToggle: () =>
                  setState(() => _statusTrayExpanded = !_statusTrayExpanded),
            );
          }),
          if (draftWorkspace != null && !widget.readOnly)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  key: const ValueKey('draft-workspace-chip'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: context.colors.accent.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                    border: Border.all(
                      color: context.colors.accent.withValues(alpha: 0.22),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.folder_outlined,
                        size: 14,
                        color: context.colors.accent,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          '新建于 $draftWorkspace',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppType.uiXs,
                            fontWeight: FontWeight.w500,
                            color: context.colors.foreground,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (widget.readOnly)
            ReadOnlyBar()
          else
            InputBar(
              controller: _input,
              focusNode: _inputFocusNode,
              running: running,
              sending: _sending,
              onSend: _send,
              onStop: _stop,
              // 合并药丸（2026-10-19）：模型+思考档一体展示，挂起点统一
              // （任一挂起即亮）—— 角标语义延续。批4 同族回落：
              // 缓存预渲期 config 也从缓存读（离线/首帧药丸不空转「模型」）。
              selectionMain: _selectionMain(effState),
              selectionSub: _selectionSub(effState),
              selectionBrand: brandLogoAsset(
                _pendingModelId ?? '${effState?.config?['model'] ?? ''}',
              ),
              selectionPending:
                  _pendingModelId != null || _pendingThought != null,
              // A1-P3-7：面板数据源与药丸同用 effState（含缓存
              // 回落）——离线/缓存首帧点开不再显示空「模型/思考档」。
              onSelectionTap: () => _openModelSheet(effState),
              onAdd: _sending ? null : _showAddSheet,
              onVoice: voiceRecognitionAvailable ? _startVoiceInput : null,
              statusColor: _statusDotColor(context),
              statusProgress: _contextUsageProgress(effState),
              onStatusTap: _toggleUsageCard,
              attachmentsBar: _pendingAtts.isEmpty
                  ? null
                  : PendingAttachmentChips(
                      attachments: _pendingAtts,
                      onRemove: _removeAttachment,
                      onRetry: _retryAttachment,
                      onAnnotate: _annotateAttachmentById,
                    ),
            ),
        ],
      ),
    );
  }

  /// 选型面板（合并药丸唯一入口，2026-10-19：模型列表+底部思考档 chips
  /// 同页——两药合一后思考档不再有专属入口）。 #5 解冻：草稿态合法，
  /// 目录走 model-selection.getView，选型随 createSession.config 提交。
  void _openModelSheet(ConversationState? state) {
    final sessionId = _sessionId;
    showModelSheet(
      context,
      sessionId: sessionId,
      state: state ?? ConversationState(),
      pendingModelProvider: _pendingModelProvider,
      pendingModelId: _pendingModelId,
      pendingThought: _pendingThought,
      onDraftModel: (p, m) {
        // 记忆上次选型（新建窗口默认预选）。
        AppStateScope.of(context).uiPrefs.setLastModel(p, m);
        setState(() {
          _pendingModelProvider = p;
          _pendingModelId = m;
        });
        // 用户反馈：模型/套餐切换后额度卡自动刷新。
        _refreshEntitlementForPlanChange();
      },
      onDraftThought: (v) {
        AppStateScope.of(context).uiPrefs.setLastThought(v);
        setState(() => _pendingThought = v);
      },
      // 弹层联动作废思考档（新模型不含旧档）：页面挂起值同步清除——
      // 否则发送时照旧提交不支持的思考档（弹层与页面两份真值漂移）。
      onDraftThoughtCleared: () => setState(() => _pendingThought = null),
      onClearDraft: () => setState(() {
        _pendingModelProvider = null;
        _pendingModelId = null;
        _pendingThought = null;
      }),
    );
  }

  /// 订阅等待态（区分草稿/已有会话）：打开已有会话时桌面可能要先唤醒
  /// 会话运行时（冷会话可能要等较久），不能让用户误以为这是草稿页。
  Widget _buildLoadingOrDraft() {
    if (_sessionId == null) {
      // 2026-10-23 用户反馈批⑥：草稿空态对齐官方欢迎屏
      // ConversationDraftEmptyState——分时问候语（六档原文）+ 若隐若现
      // Z 水印垫底（官方=水印绝对居中、问候语覆盖其上；建议 chips 是
      // 手机端对官方 suggested prompts 的既有形态，保留）。
      if (_sending) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      final greeting = chatEmptyGreeting(
        (widget.greetingNow ?? DateTime.now()).hour,
      );
      // 官方水印宽 min(72vw, 25rem)、aspect 5:4；手机端按目检放大到
      // 0.9vw 让 Z 顶边高出问候语（官方构图：大 Z+文字压中腹部）。
      final vw = MediaQuery.sizeOf(context).width;
      final wmW = vw * 0.9 > 440 ? 440.0 : vw * 0.9;
      final welcomeHeightFactor = L10n.resolvedLocale == 'en-US'
          ? (MediaQuery.textScalerOf(context).scale(1.0) > 1.1 ? 1.25 : 0.9)
          : 0.8;
      return Center(
        child: SizedBox(
          width: wmW,
          // 英文及大字号需要更多纵向空间；中文保持原构图与水印尺寸。
          height: wmW * welcomeHeightFactor,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  // 官方 -mt-10：水印整体上提，问候语保持正中。
                  child: Transform.translate(
                    offset: const Offset(0, -40),
                    child: ShaderMask(
                      // 下端渐隐遮罩（theme.dart 单源 kBottomFadeMask：
                      // 官方浅色 mask-image 同款 70%→100% 渐隐）。
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (b) => kBottomFadeMask.createShader(b),
                      child: Opacity(
                        opacity: AppAlpha.watermark,
                        child: SvgPicture.asset(
                          'assets/brand_logos/zhipu.svg',
                          fit: BoxFit.contain,
                          colorFilter: ColorFilter.mode(
                            context.colors.foreground,
                            BlendMode.srcIn,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      greeting,
                      style: TextStyle(
                        color: context.colors.foreground,
                        fontSize: AppType.uiXl,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 36),
                    // 建议 chips（点击只填入不发送，防误触；评审 2.2#6）。
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        for (final s in const ['总结这个项目', '解释最近改动', '跑一下测试'])
                          ActionChip(
                            label: Text(s),
                            onPressed: () {
                              _input.text = s;
                              _input.selection = TextSelection.collapsed(
                                offset: s.length,
                              );
                              _inputFocusNode.requestFocus();
                            },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 2),
          const SizedBox(height: 12),
          Text(
            _error ?? '正在载入对话历史…',
            style: TextStyle(
              color: _error == null
                  ? context.colors.foregroundSubtle
                  : context.colors.destructive,
              fontSize: AppType.uiCaption,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            _waitingWorkspace ? '正在打开工作区…' : '首次打开需要唤醒会话，可能要等一会',
            style: TextStyle(
              color: context.colors.foregroundSubtlest,
              fontSize: AppType.uiXs,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _retrySubscribe,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('重试'),
            ),
          ],
        ],
      ),
    );
  }

  void _retrySubscribe() {
    final sessionId = _sessionId;
    if (sessionId == null) return;
    setState(() {
      _error = null;
      _syncError = null;
    });
    _subscribe(sessionId);
  }

  /// A2 暂存恢复：插入光标处（输入框可能已有新内容，不整体替换）。
  void _restoreUnsentDraft() {
    final t = _unsentDraft;
    if (t == null || t.isEmpty) return;
    setState(() => _unsentDraft = null);
    _insertAtCursor(t);
  }

  String _sessionTitle() {
    final state = _sub?.state;
    final title =
        '${state?.snapshot?['title'] ?? _cachePreview?.snapshot?['title'] ?? ''}'
            .trim();
    if (title.isNotEmpty) return title;
    return widget.title;
  }

  /// 当前电脑备注名（Paseo 参考 2026-10-23 顶栏副行）。
  String? get _deviceLabel {
    final label = '${AppStateScope.of(context).activeProfile?.label ?? ''}'
        .trim();
    return label.isEmpty ? null : label;
  }

  /// 草稿落点（2026-10-27 用户④）：新会话发送前必须能看出会建在
  /// 哪个工作区/项目；既有会话不占位。
  String? _draftWorkspaceLabel(AppState app) {
    if (_sessionId != null) return null;
    if (app.activeProjectId == conversationsPseudoProjectId) {
      return '无项目对话';
    }
    final ws = app.activeWorkspace;
    if (ws == null) return null;
    final explicit = '${ws['label'] ?? ''}'.trim();
    if (explicit.isNotEmpty) return explicit;
    final path = '${ws['workspaceIdentity'] ?? ws['workspacePath'] ?? ''}'
        .trim();
    if (path.isEmpty) return null;
    final parts = path
        .replaceAll('\\', '/')
        .split('/')
        .where((p) => p.isNotEmpty)
        .toList();
    return parts.isEmpty ? path : parts.last;
  }

  List<ChatItem> _cachedChatItems = const [];
  List<Map<String, dynamic>> _cachedRowsRef = const [];
  int _cachedDataVersion = -1;

  /// 上次投影行数（ A1-P3-4：行数回退才触发 ViewStore 裁剪）。
  int _lastRowCount = 0;

  /// R1-part2：deltas 对 rows 原地变更，identical 永真——必须以
  /// state.dataVersion 为第一失效键（引用同一性仅作辅助）。
  bool _cachedItemsIdentical(
    List<Map<String, dynamic>> rows,
    ConversationState state,
  ) =>
      identical(rows, _cachedRowsRef) &&
      state.dataVersion == _cachedDataVersion;

  List<ChatItem> _rebuildChatItems(
    List<Map<String, dynamic>> rows,
    ConversationState state,
  ) {
    _cachedRowsRef = rows;
    _cachedDataVersion = state.dataVersion;
    return _cachedChatItems = buildChatItems(rows);
  }

  Widget _buildMessageList(ConversationState state) {
    final app = AppStateScope.of(context);
    // 同时监听会话状态与工具显示开关（开关即时生效）
    return ListenableBuilder(
      // 流式渲染节流（优化批 #8）：会话状态不再直连本 builder——否则页面级
      // 40ms 合帧被这个直连架空，列表仍每 notify 全量重建；行数据经页面 setState
      //（已节流）流入。工具显示开关保持即时生效。
      listenable: app.uiPrefs,
      builder: (context, _) {
        if (!state.ready && state.rows.isEmpty) {
          return const Center(child: CircularProgressIndicator(strokeWidth: 2));
        }
        // 性能：rows 引用未变时复用上次投影（流式期间状态通知频繁，
        // 全量重分组 O(rows) 是每帧成本）。
        // 页面级定格（见 _reasoningElapsedMs 注释）——在条目构建前扫描。
        _captureReasoningElapsed(state.rows);
        final cachedHit = _cachedItemsIdentical(state.rows, state);
        final items = cachedHit
            ? _cachedChatItems
            : _rebuildChatItems(state.rows, state);
        // A1-P3-4：行数回退（编辑重发/回滚的 row.removed）时
        // 裁剪 ViewStore 页面级 Map（只增不减=长会话单调驻留）；行数
        // 增长不裁（流式常态）。
        if (state.rows.length < _lastRowCount) {
          _viewStore.pruneAfterRowShrink(
            state.rows,
            liveKeys: {
              for (var i = 0; i < items.length; i++) chatItemKey(items[i], i),
            },
          );
        }
        _lastRowCount = state.rows.length;
        // 末轮下标（问题② 2026-10-25：末轮默认展开——冻结重进/回 app
        // 的最近对话内容常可见，不再整页收起只剩一句正文）。
        var lastTurnIdx = -1;
        for (var k = items.length - 1; k >= 0; k--) {
          if (items[k] is TurnBarItem) {
            lastTurnIdx = k;
            break;
          }
        }
        String itemKeyFor(int idx) => chatItemKey(items[idx], idx);

        var centerIndex = 0;
        if (items.isEmpty) {
          _listCenterItemKey = null;
        } else {
          centerIndex = -1;
          if (_listCenterItemKey != null) {
            for (var i = 0; i < items.length; i++) {
              if (itemKeyFor(i) == _listCenterItemKey) {
                centerIndex = i;
                break;
              }
            }
          }
          if (centerIndex < 0) {
            // 前插键迁移（2026-10-29 跳转根因）：半截回合补齐头部后键
            // 从 turn-tail-* 切到 turn-h-*——按旧锚行号找回该回合续锚，找不
            // 到才回退首条（回退=整列跳到最老，即真机"突然跳转"）。
            final anchorKey = _listCenterItemKey;
            if (anchorKey != null) {
              final migrated = migrateAnchorIndexAfterPrepend(anchorKey, items);
              if (migrated >= 0) {
                centerIndex = migrated;
                _listCenterItemKey = itemKeyFor(migrated);
              }
            }
          }
          if (centerIndex < 0) {
            centerIndex = 0;
            _listCenterItemKey = itemKeyFor(0);
          }
        }
        return NotificationListener<ScrollNotification>(
          // 用户拖拽滚动时立即取消粘底跟随——否则 100ms 一次的
          // jumpTo 会把慢速上滑反复钉回底部（流式期间尤甚）。
          onNotification: (n) {
            if (n is ScrollUpdateNotification && n.dragDetails != null) {
              if (_searchOpen) _search.cancelNavigation();
              final draggingUp = n.dragDetails!.delta.dy > 0;
              if (draggingUp && _stickToBottom) {
                // 只有用户真的向上拖才解除粘底（FAB 可见性联动）。
                _followTick?.cancel();
                setState(() => _stickToBottom = false);
              } else if ((_followTick?.isActive ?? false)) {
                _followTick?.cancel();
              }
            } else if ((n is ScrollEndNotification ||
                    (n is ScrollUpdateNotification && n.dragDetails == null)) &&
                _scroll.hasClients) {
              if (_inProgrammaticWindow()) {
                // 自己的 jump 序列——消费豁免（每序列一个 End）。
                if (n is ScrollEndNotification) {
                  _programmaticScrollEndSkips--;
                }
                return false;
              }

              if (_followingReconcileGuard > 0) {
                _saveScrollMemory();
                return false;
              }

              // 官方落点裁决（timelineScrollAnchor nextFollowingAfterScroll，
              // 2026-10-26 对齐批 C）：用户滚动序列（含惯性 fling）结束的
              // 静止落点距底 ≤48 → 贴底回跟；>48 → 解除跟随——原实现仅
              // 手指拖拽可解除，惯性滑出后被粘底 tick 拉回（自造怪象，
              // audit §六.5 实证）。回吸保持 2026-10-23 语义（贴底即恢复）。
              final dist =
                  _scroll.position.maxScrollExtent - _scroll.position.pixels;
              if (dist <= 48) {
                if (!_stickToBottom) {
                  setState(() => _stickToBottom = true);
                  _followUntilStable();
                }
              } else if (_stickToBottom) {
                _followTick?.cancel();
                setState(() => _stickToBottom = false);
              }
              _saveScrollMemory();
            }
            return false;
          },
          child: AnchoredChatList(
            key: const ValueKey('chat-scroll'),
            controller: _scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            centerIndex: centerIndex,
            itemCount: items.length,
            leading: state.canLoadOlder
                ? Center(
                    child: TextButton.icon(
                      key: const ValueKey('load-older'),
                      onPressed: _loadOlder,
                      icon: const Icon(Icons.history, size: 16),
                      label: const Text('加载更早消息'),
                    ),
                  )
                : null,
            trailing:
                (state.control?['phase'] == 'running' &&
                    items.isNotEmpty &&
                    items.last is UserItem &&
                    state.pendingInteractions.isEmpty)
                ? Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ShimmerText(
                        text: '正在思考…',
                        style: TextStyle(
                          fontSize: AppType.uiBase,
                          color: context.colors.running,
                        ),
                      ),
                    ),
                  )
                : null,
            itemBuilder: (context, idx) {
              final item = items[idx];
              // 所有条目使用稳定 key；前插时 center index 后移而阅读位置不变。
              final itemKey = itemKeyFor(idx);
              if (item is TurnBarItem && idx == lastTurnIdx) {
                _lastTurnHeaderId = intOf(item.work.header?['rowId']);
              }
              // 轮距（对抗审查收敛项 2026-10-22 对位官方 56=pt-14）：
              // 候选 15 验收 B5 用户拍板紧凑优先——轮顶 56→28（手机档
              // 减半；轮内首条 20/条目间 16 不变）。官方节奏在手机长会话
              // 里观感过松（真机实测轮间 ≈84dp 起步）。
              final startsTurn = item is UserItem;
              final prev = idx > 0 ? items[idx - 1] : null;
              // 窗口起点不是逻辑起点：还有更早历史时先按同类间距预留，
              // 前插后该条目才不会凭空多出 56/20/16dp（逐帧回归实证）。
              final top = startsTurn
                  ? (idx == 0 && !state.canLoadOlder ? 0.0 : 28.0)
                  : (prev == null
                        ? (state.canLoadOlder
                              ? (item is TurnBarItem ? 20.0 : 16.0)
                              : 0.0)
                        : (prev is TurnBarItem || prev is UserItem
                              ? 20.0
                              : 16.0));
              Widget child = switch (item) {
                UserItem() => SearchTargetFrame(
                  rowId: intOf(item.row['rowId']),
                  activeRowId: _activeSearchMatch?.rowId,
                  targetKey: _searchTargetKey,
                  child: UserBubble(
                    text: item.text,
                    attachments: _attachmentsOf(item.row),
                    onLongPress: () => _showRowActions(item.row),
                    onAttachment: (i) => _openAttachmentAt(item.row, i),
                    searchReveal:
                        _activeSearchMatch?.rowId ==
                        intOf(item.row['rowId']),
                    // 18077 验收#11（Bug H）：提问内容同享词级高亮。
                    searchQuery: _searchOpen
                        ? _searchController.text.trim()
                        : null,
                  ),
                ),
                TurnBarItem() => TurnBar(
                workflowRuns: state.workflowRunsList,
                  sessionId: _sessionId,
                  work: item.work,
                  showTools: app.uiPrefs.showToolCalls,
                  firstSeenOf: _firstSeenOf,
                  elapsedMsOf: _reasoningElapsedOf,
                  toolOpen: _toolOpenByRow,
                  onRowActions: _showRowActions,
                  isLastTurn: idx == lastTurnIdx,
                  // 运行中窗口的末轮承接（2026-10-26 澄清修复）：会话
                  // phase=running 时末轮按运行中呈现（含缓存预渲期——
                  // 冻结重进 header 停在旧完成态的场景）。
                  phaseRunning: idx == lastTurnIdx && state.phase == 'running',
                  liveCollapsedByRow: _liveCollapsedByRow,
                  searchTargetRowId: _activeSearchMatch?.rowId,
                  searchTargetKey: _searchTargetKey,
                  searchStart: _activeSearchMatch?.start,
                  searchSourceText: _activeSearchMatch?.sourceText,
                  searchSnippet: _activeSearchMatch?.snippet,
                  searchQuery: _searchOpen
                      ? _searchController.text.trim()
                      : null,
                  openSession: _openConversationSession,
                  onLiveCollapsedChanged: (collapsed) {
                    // B1-P3-4：与 TurnBar._turnId 同源
                    // collapseKeyId（无头半截回合按段内首行 rowId）——侧写键
                    // 与读键不一致会让覆盖写进孤儿 -1 键。
                    _liveCollapsedByRow[item.work.collapseKeyId] = collapsed;
                  },
                ),
                FileSummaryItem() => FileSummaryCard(
                  sessionId: _sessionId,
                  header: item.header,
                  fileChanges: item.fileChanges,
                  subagentCount: item.subagentCount,
                  tailRow: item.tailRow,
                  tailCopyText: item.tailCopyText,
                  openByCard: _fileCardOpen,
                  itemsByCard: _fileCardItems,
                  openSession: _openConversationSession,
                ),
                // B2-1：标记行渲染收敛 TimelineMarkerDivider
                //（段内 mid-turn compact 同款，两处不漂移）。
                TimelineMarkerItem() => TimelineMarkerDivider(
                  label: item.label,
                  running: item.running,
                ),
              };
              final fresh = _seenRowKeys.add(itemKey);
              // 原 Builder 只为收集 itemContext
              // 进只写不读的 map（持有已 dispose 的 Element=内存泄漏）——
              // 整层删除，直接返回。
              return KeyedSubtree(
                key: ValueKey(itemKey),
                child: top > 0
                    ? Padding(
                        padding: EdgeInsets.only(top: top),
                        child: fresh ? EntryFadeSlide(child: child) : child,
                      )
                    : fresh
                    ? EntryFadeSlide(child: child)
                    : child,
              );
            },
          ),
        );
      },
    );
  }
}

String inferEntPlanKind({
  String? currentProvider,
  String? draftProvider,
  Iterable<String> allProviders = const [],
}) {
  if (currentProvider != null && currentProvider.isNotEmpty) {
    return currentProvider.contains('start-plan')
        ? 'start-plan'
        : 'individual-coding-plan';
  }
  if (draftProvider != null && draftProvider.contains('start-plan')) {
    return 'start-plan';
  }
  for (final p in allProviders) {
    if (p.contains('start-plan')) return 'start-plan';
  }
  return 'individual-coding-plan';
}
