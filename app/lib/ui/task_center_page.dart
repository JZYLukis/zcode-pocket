import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart' hide Text;

import '../core/localized_text.dart';
import '../core/l10n.dart';

import 'package:flutter/services.dart';

import '../core/breakpoints.dart';
import '../core/payload_guard.dart' show intOf;
import '../core/theme.dart';
import 'workflow_dashboards.dart' show workflowRunStatusWord;
import '../state/app_state.dart';
import '../state/app_state_scope.dart';
import '../state/cache_policy.dart';
import '../state/task_list.dart';
import '../transport/conversation.dart';
import '../transport/project_tree.dart';
import '../transport/z_transport.dart';
import 'app_widgets.dart';
import 'login_page.dart';
import 'status_badge.dart';
import 'archived_tasks_page.dart';
import 'automation_page.dart';
import 'conversation_page.dart';
import 'pairing_page.dart';
import 'profiles_sheet.dart';
import 'settings_page.dart';
import 'task_home.dart';

/// 任务中心（home）：全部任务 + 最近｜项目分组（项目栏优化 B 方案）。
/// 折叠/展开共用同一主页；项目成为分组与新建上下文，不再是常驻导航轨。

/// 卡片摘要剥 Markdown 记号（**强调**/`代码`/标题# 等）——纯文本场景
/// 裸符号观感糙（视觉审查 2026-10-18）。
/// （2026-10-19 审查）：结果缓存——preview 串跨重建稳定（卡实例每
/// rebuild 新建，键必须用串）；上限超限整清，规模=可见卡量级。
final _stripMarkdownCache = <String, String>{};
String _stripMarkdown(String raw) {
  final hit = _stripMarkdownCache[raw];
  if (hit != null) return hit;
  final out = raw
      .replaceAll('**', '')
      .replaceAll('__', '')
      .replaceAll('`', '')
      .replaceAll(RegExp(r'^#{1,6}\s*'), '')
      .trim();
  if (_stripMarkdownCache.length > 600) _stripMarkdownCache.clear();
  return _stripMarkdownCache[raw] = out;
}

class TaskCenterPage extends StatefulWidget {
  /// 游览夹具钉时钟（生产=null=DateTime.now）：今天/昨天分组不得把
  /// 运行日期带进截图基线（跨午夜漂移实证，2026-10-27）。
  final DateTime? homeNow;
  const TaskCenterPage({super.key, this.homeNow});

  @override
  State<TaskCenterPage> createState() => _TaskCenterPageState();
}

class _TaskCenterPageState extends State<TaskCenterPage> {
  bool _searchOpen = false;
  String _searchQuery = '';

  /// 跨项目打开任务期间保留当前首页（用户⑥）：不因 phase 变化先闪
  /// “连接中/恢复中”再进会话；失败后才恢复错误呈现。
  bool _taskNavigationPending = false;

  // ---- 6.5 展开态双栏（2026-10-29 批次，用户拍板：仿桌面端布局——
  // 窄左栏任务列表+右侧大任务窗口）----
  /// 双栏右栏选中（sessionId null=新建草稿页）。workspaceKey 用于切换
  /// 工作区后自动失效（旧工作区的会话不再占据右栏）。
  ({String? sessionId, String title, String workspaceKey,
      String? waitForWorkspace, int? deepLinkAtMs})? _paneSelection;
  bool _wideLayout = false;

  // ---- 批量操作（优化批 #22）：多选归档/标已读/删除 ----
  // 状态放页面级而非 _TaskHomeView：搜索时首页视图会被结果列表替换，
  // 页面级才能“先筛再选”（多选模式下搜索照常可用）。
  bool _multiSelectMode = false;
  final Set<String> _selectedTaskIds = {};

  /// 行级工作区键（taskId → workspaceIdentity/Path）：跨工作区搜索行可能
  /// 不在 workspaceTasks 索引里（官方全文命中行），批量操作必须按行归属
  /// 执行，不能静默归当前工作区（否则 RPC 打偏必然失败）。
  final Map<String, String?> _selectedTaskWorkspaceKeys = {};
  bool _batchRunning = false;

  // ---- 主页视图状态：同样提升到页面级 ----
  // _TaskHomeView 在 hold/stale/空查询三分支的树深度不同、搜索时更被
  // 整体替换——State 级存放会让「最近/项目」页签与渐进披露计数在搜索
  // 开合/在线↔恢复切换时被静默重置。
  TaskHomeMode _homeMode = TaskHomeMode.recent;
  final Map<String, int> _homeGroupVisibleCounts = {};
  final Set<String> _homeFullyExpandedGroups = {};

  /// 会话页推入的帧级防双击门：路由 barrier 建立
  /// 前的第二次 onTap 会推入第二层会话页（返回键要按两次）。
  bool _sessionPushing = false;

  void _enterMultiSelect(String taskId, [String? workspaceKey]) => setState(() {
    _multiSelectMode = true;
    _selectedTaskIds.add(taskId);
    _selectedTaskWorkspaceKeys[taskId] = workspaceKey;
  });

  void _toggleTaskSelected(String taskId, String? workspaceKey) => setState(() {
    if (_selectedTaskIds.remove(taskId)) {
      _selectedTaskWorkspaceKeys.remove(taskId);
    } else {
      _selectedTaskIds.add(taskId);
      _selectedTaskWorkspaceKeys[taskId] = workspaceKey;
    }
  });

  void _exitMultiSelect() => setState(() {
    _multiSelectMode = false;
    _selectedTaskIds.clear();
    _selectedTaskWorkspaceKeys.clear();
  });

  /// 批量操作（优化批 #22）：按工作区分组执行——当前工作区直发并行；
  /// 其他组先切工作区再并行（zcodeTask RPC 带 activeWorkspace scope，
  /// 跨工作区任务直接发会打偏，语义同 _ensureTaskContext 的归属护栏）。
  /// 单条失败不打断整批，收集后在 SnackBar 报告。
  Future<void> _runBatchOp(
    String okLabel,
    Future<dynamic> Function(AppState app, String taskId) op,
  ) async {
    if (_batchRunning || _selectedTaskIds.isEmpty) return;
    final app = AppStateScope.of(context);
    // 任务行（含工作区上下文/标题）从全局索引反查：workspaceTasks 是
    // 当前工作区窗口全集，projectTasks（readTree 行）补跨项目行；官方
    // 全文搜索命中行可能两者都不在——此时以选择集携带的行级键为准。
    final rowById = <String, Map<String, dynamic>>{
      for (final t in app.projectTasks)
        if ('${t['taskId'] ?? ''}'.isNotEmpty) '${t['taskId']}': t,
      for (final t in app.workspaceTasks)
        if ('${t['taskId'] ?? ''}'.isNotEmpty) '${t['taskId']}': t,
    };
    final currentKey = workspaceKeyOf(app.activeWorkspace ?? const {});
    final groups = <String, List<({String id, String title})>>{};
    // 归属无法判定的行（索引未覆盖且未携带键）：跳过并计失败——静默归
    // 当前工作区会让 RPC 打偏，比明确失败更难排查。
    final unresolved = <String>[];
    for (final id in _selectedTaskIds.toList()) {
      final row = rowById[id];
      var key = _selectedTaskWorkspaceKeys[id];
      if (key == null || key.isEmpty) {
        key = row == null ? null : taskWorkspaceKey(row);
      }
      // 全局索引完全未就绪（两份索引都空，页面行来自当前卡兜底）时，
      // 可见行必然属于当前工作区——保留这一条兜底语义。
      if ((key == null || key.isEmpty) &&
          app.workspaceTasks.isEmpty &&
          app.projectTasks.isEmpty) {
        key = currentKey;
      }
      final title = '${row?['title'] ?? ''}'.trim().isEmpty
          ? '未命名任务'
          : '${row?['title']}';
      if (key == null || key.isEmpty) {
        unresolved.add(title);
        continue;
      }
      (groups[key] ??= []).add((id: id, title: title));
    }
    // 当前工作区优先（大概率覆盖大多数选择，且免切换）。
    final orderedKeys = [
      if (groups.containsKey(currentKey)) currentKey!,
      for (final k in groups.keys)
        if (k != currentKey) k,
    ];
    setState(() => _batchRunning = true);
    final failed = <String>[...unresolved];
    var ok = 0;
    try {
      for (final key in orderedKeys) {
        final group = groups[key]!;
        if (key != currentKey) {
          try {
            final ws = app.workspaces
                .where((w) => workspaceKeyOf(w) == key)
                .firstOrNull;
            if (ws != null) {
              await app.switchWorkspace(ws);
            } else {
              final project = app.projectForKey(key);
              if (project == null) throw StateError('找不到任务所属的工作区');
              await app.switchToProject(project);
            }
            if (app.workspaceError != null) {
              throw StateError('工作区切换未完成');
            }
          } catch (e) {
            failed.addAll(group.map((g) => g.title));
            continue;
          }
        }
        final results = await Future.wait(
          group.map((g) async {
            try {
              await op(app, g.id);
              return true;
            } catch (e) {
              return false;
            }
          }),
        );
        for (var i = 0; i < group.length; i++) {
          if (results[i]) {
            ok++;
          } else {
            failed.add(group[i].title);
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() => _batchRunning = false);
      } else {
        _batchRunning = false;
      }
    }
    // 批后回切原工作区：批量管理语义下逐组切换是
    // 执行手段，整批结束后停留在最后一组的工作区=“归档完页面自己跳了”
    // （左栏分组/双栏右栏选中随之失效）。原工作区仍可用才回切。
    final originalKey = currentKey;
    final originalWs = originalKey == null
        ? null
        : app.workspaces
              .where((w) => workspaceKeyOf(w) == originalKey)
              .firstOrNull;
    if (mounted &&
        originalWs != null &&
        workspaceKeyOf(app.activeWorkspace ?? const {}) != originalKey) {
      try {
        await app.switchWorkspace(originalWs);
      } catch (_) {
        // 回切失败不影响批量结果呈现（用户下次点按自然重开）。
      }
    }
    if (!mounted) return;
    _exitMultiSelect();
    final messenger = ScaffoldMessenger.of(context);
    if (failed.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text('$okLabel $ok 个')));
    } else {
      final preview = failed.take(3).join('、');
      final suffix = failed.length > 3 ? ' 等 ${failed.length} 个' : '';
      messenger.showSnackBar(
        SnackBar(
          content: Text('$okLabel $ok 个，${failed.length} 个失败：$preview$suffix'),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  // 验收#10（优化意见 F）：批量操作全量二次确认（用户拍板——
  // 误触归档/已读与删除同样是不可逆烦恼，归档可恢复但找回成本高）。
  Future<void> _batchArchive() async {
    final count = _selectedTaskIds.length;
    final ok = await showConfirmDialog(
      context,
      title: '归档选中的 $count 个任务？',
      message: '任务将移入归档，可在归档列表恢复。',
      confirmLabel: '归档',
      destructive: false,
    );
    if (!ok) return;
    await _runBatchOp('已归档', (app, id) => app.archiveTask(id));
  }

  Future<void> _batchMarkRead() async {
    final count = _selectedTaskIds.length;
    final ok = await showConfirmDialog(
      context,
      title: '将选中的 $count 个任务标为已读？',
      message: '未读标记将被清除。',
      confirmLabel: '标为已读',
      destructive: false,
    );
    if (!ok) return;
    await _runBatchOp(
      '已标为已读',
      (app, id) => app.markTaskUnread(id, unread: false),
    );
  }

  Future<void> _batchDelete() async {
    final count = _selectedTaskIds.length;
    final ok = await showConfirmDialog(
      context,
      title: '删除选中的 $count 个任务？',
      message: '选中的任务将被永久删除，不可恢复。',
    );
    if (!ok) return;
    await _runBatchOp('已删除', (app, id) => app.deleteTask(id));
  }

  /// 批3（multi-account-ux-1）：上次看到的活跃设备——切电脑（含通知
  /// 直达 activate 的隐式切换）后清掉跨电脑残留状态（搜索词/多选/右栏）。
  String? _lastSeenDeviceSid;
  AppState? _appRef;

  void _onAppChangedForSid() {
    final app = _appRef;
    if (app == null || !mounted) return;
    final sid = app.activeProfile?.deviceSid;
    if (sid == _lastSeenDeviceSid) return;
    _lastSeenDeviceSid = sid;
    // （批3）：必须走 _closeSearch ——只清开关会让在飞 300ms 防抖
    // 打到新电脑上发全文 RPC，并把 fetch/hits 状态留脏。
    if (_searchOpen) _closeSearch();
    setState(() {
      _multiSelectMode = false;
      _selectedTaskIds.clear();
      _selectedTaskWorkspaceKeys.clear();
      _paneSelection = null;
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final app = AppStateScope.of(context);
      _appRef = app;
      _lastSeenDeviceSid = app.activeProfile?.deviceSid;
      app.addListener(_onAppChangedForSid);
    });
  }

  // ---- 任务全文搜索（：官方 listTaskList，标题+对话正文）----
  Timer? _searchDebounce;
  int _searchSeq = 0;
  _SearchFetchState _searchFetch = _SearchFetchState.idle;
  List<Map<String, dynamic>>? _serverHits;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _appRef?.removeListener(_onAppChangedForSid);
    super.dispose();
  }

  void _onSearchChanged(String v) {
    setState(() => _searchQuery = v);
    _scheduleServerSearch(v);
  }

  /// 300ms 防抖 + 序号防竞态：输入停顿后才发官方全文查询，旧查询的迟到
  /// 结果按序号丢弃。清空/未连接直接回退本地标题/预览过滤。
  /// 三轮审查 ：判据从 conversation==null 改为 bridge==null——
  /// 全文查询（searchTaskList）只依赖桥；切工作区窗口内 conv 已被提前
  /// 置空但桥仍活，旧判据会让服务器搜索静默退化为本地过滤。
  void _scheduleServerSearch(String raw) {
    _searchDebounce?.cancel();
    final seq = ++_searchSeq;
    final q = raw.trim();
    if (q.isEmpty || AppStateScope.of(context).bridge == null) {
      setState(() {
        _searchFetch = _SearchFetchState.idle;
        _serverHits = null;
      });
      return;
    }
    setState(() => _searchFetch = _SearchFetchState.searching);
    _searchDebounce = Timer(const Duration(milliseconds: 300), () async {
      final hits = await AppStateScope.of(context).searchTasks(q);
      if (!mounted || seq != _searchSeq || _searchQuery.trim() != q) return;
      setState(() {
        _serverHits = hits;
        _searchFetch = hits == null
            ? _SearchFetchState.failed
            : _SearchFetchState.done;
      });
    });
  }

  void _closeSearch() {
    _searchDebounce?.cancel();
    _searchSeq++;
    // 2026-11-05 反馈②C：搜索本就未开时零 setState（进会话路径无条件
    // 调本方法，点按帧叠加一次无谓首页重建）。
    if (!_searchOpen &&
        _searchQuery.isEmpty &&
        _searchFetch == _SearchFetchState.idle &&
        _serverHits == null) {
      return;
    }
    setState(() {
      _searchOpen = false;
      _searchQuery = '';
      _searchFetch = _SearchFetchState.idle;
      _serverHits = null;
    });
  }

  /// 通知点击直达：目标栈可能仍在恢复（resume 重连中）——重试小窗内
  /// 等会话传输就绪；超时不再静默放弃（发现3），留在任务列表并
  /// 提示连接状态。
  Future<void> _openFromNotification(
    ({String deviceSid, String taskId}) target, {
    int? deepLinkAtMs,
  }) async {
    final app = AppStateScope.of(context);
    // 消费侧设备归属防御（多电脑）：通知目标可能属于另一台已添加的电脑，
    // 激活/切换由 state 层负责，这里只做「等它切过来」的短窗口。
    final targetSid = target.deviceSid.trim();
    if (targetSid.isNotEmpty) {
      for (var i = 0; i < 15; i++) {
        if (!mounted) return;
        if (app.activeProfile?.deviceSid == targetSid) break;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      if (!mounted) return;
      final activeSid = app.activeProfile?.deviceSid;
      if (activeSid != targetSid) {
        app.clearPendingDeepLink();
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              activeSid == null
                  ? '电脑连接还在准备，请稍后从任务列表打开'
                  : '该任务属于另一台电脑，已切到当前电脑的任务列表',
            ),
          ),
        );
        return;
      }
    }
    for (var i = 0; i < 25; i++) {
      if (!mounted) return;
      if (app.bridge != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!mounted) return;
    if (app.bridge == null) {
      app.clearPendingDeepLink();
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('该电脑还在重连，稍后从列表点开')));
      return;
    }
    final entry = app.taskList?.cards
        .where((c) => c.sessionId == target.taskId)
        .firstOrNull;
    if (entry != null) {
      final title = entry.title.isNotEmpty ? entry.title : '会话';
      app.markTaskRead(entry.sessionId);
      _closeSearch();
      _openConversation(target.taskId, title, deepLinkAtMs: deepLinkAtMs);
      return;
    }
    // 目标任务不在当前工作区卡集（通知发出后用户切了
    // 同设备的另一工作区）——bridge-only 判据不足以保证会话可达（读上报
    // 与订阅都会打在错误的工作区上）。从全局任务索引（workspaceTasks）
    // 与项目树任务行（projectTasks）反查行，走跨工作区打开链（先切回
    // 所属工作区再订阅）。
    final row = app.workspaceTasks
            .where((t) => '${t['taskId'] ?? ''}' == target.taskId)
            .firstOrNull ??
        app.projectTasks
            .where((t) => '${t['taskId'] ?? ''}' == target.taskId)
            .firstOrNull;
    if (row != null) {
      _closeSearch();
      unawaited(_openCrossWorkspaceTask(row, deepLinkAtMs: deepLinkAtMs));
      return;
    }
    // 查不到归属不裸开（裸开会话没有工作区 scope，RPC 必打偏）——人话
    // 提示并清掉深链残留，防之后的会话页误弹深链浮层。
    app.clearPendingDeepLink();
    _closeSearch();
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(content: Text('该任务不在当前工作区，可能已被移除')),
    );
  }

  /// 统一会话打开路由（6.5 双栏）：宽屏（≥600dp，展开态/平板）=右栏
  /// 就地选中（不跳页）；窄屏=推入整页（原行为）。
  void _openConversation(String? sessionId, String title,
      {String? waitForWorkspace, int? deepLinkAtMs}) {
    if (!_wideLayout) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ConversationPage(
            sessionId: sessionId,
            title: title,
            waitForWorkspace: waitForWorkspace,
            deepLinkAtMs: deepLinkAtMs,
          ),
        ),
      );
      return;
    }
    // （对抗审查）：宽屏右栏同传 deepLinkAtMs——平板深链浮层此前恒不弹。
    setState(() {
      _paneSelection = (
        sessionId: sessionId,
        title: title,
        // ⑤A：等待型打开的失效键=目标工作区（切换完成后仍匹配；用当前
        // 键会在切换落地瞬间误清右栏）。
        workspaceKey: waitForWorkspace ?? _currentWorkspaceKey(),
        waitForWorkspace: waitForWorkspace,
        deepLinkAtMs: deepLinkAtMs,
      );
    });
  }

  String _currentWorkspaceKey() =>
      workspaceKeyOf(AppStateScope.of(context).activeWorkspace ?? const {}) ??
      '';

  /// 长按任务的归属护栏（ 从 _TaskHomeViewState 提升到
  /// 页面级——搜索分支会销毁该 State，弹层动作 15s 在飞窗口内的
  /// ensureContext/run 回调将作用于 defunct context）：跨项目任务的
  /// zcodeTask 操作带 activeWorkspace scope，执行前切到任务所属工作区。
  Future<void> _ensureTaskContext(Map<String, dynamic> task) async {
    final app = AppStateScope.of(context);
    final key = taskWorkspaceKey(task);
    if (key == null || key == workspaceKeyOf(app.activeWorkspace ?? const {})) {
      return;
    }
    final ws = app.workspaces
        .where((w) => workspaceKeyOf(w) == key)
        .firstOrNull;
    if (ws != null) {
      await app.switchWorkspace(ws);
    } else {
      final project = app.projectForKey(key);
      if (project != null) {
        await app.switchToProject(project);
      } else {
        await app.switchToTask(task);
      }
    }
    if (app.workspaceError != null) {
      throw StateError('工作区切换未完成，请稍后重试');
    }
  }

  /// 主页/跨区/搜索行统一长按菜单入口（页面级 context 更长寿）。
  void _openTaskActionsMenu(Map<String, dynamic> task) {
    if (!mounted) return;
    // 验收#10（Bug E）：ensureTaskContext 从「弹菜单前」移到
    // 「菜单动作执行前」（run helper 统一接入）——弹菜单是零副作用
    // 轻操作；此前弹菜单前切工作区会让首页重建跳回「最近」。
    _showTaskActions(
      context,
      taskHomeEntry(task),
      // 选择集携带行级工作区键：跨区任务/搜索行的批量操作按行归属执行。
      onEnterMultiSelect: (id) =>
          _enterMultiSelect(id, taskWorkspaceKey(task)),
      ensureContext: () => _ensureTaskContext(task),
    );
  }

  Future<void> _openSession(TaskCardData entry) async {
    // 帧级防双击：第二次 onTap 落在新路由 barrier
    // 挂载前会推入第二层会话页；push 在本函数同步段完成，下一帧复位。
    if (_sessionPushing) return;
    _sessionPushing = true;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _sessionPushing = false,
    );
    final app = AppStateScope.of(context);
    // 桥未就绪不再静默吞点击（2026-10-23 真机：退出会话回列表后点卡
    // /新建均无反应，只有切工作区能恢复）——至少给出可见反馈。
    // 三轮审查 / ：判据从 conversation==null 改为 bridge==null
    // ——切工作区窗口内 conv 被提前置空但桥仍活，点任务卡应照常走
    // switchToTask（HEAD 同款窗口宽度），不再误弹"还在重连"。
    if (app.bridge == null) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('该电脑还在重连，稍后从列表点开')));
      return;
    }
    app.markTaskRead(entry.sessionId); // 打开即已读（best-effort；卡片无 unreadAt 字段不带 CAS）
    _closeSearch(); // 进入会话即收起搜索；返回首页不残留旧查询/键盘态。
    _openConversation(entry.sessionId, entry.title);
  }

  /// 跨工作区搜索：点按其他工作区的任务 → 切换工作区（等待桥与
  /// 任务索引就绪）→ 打开会话。：目标不在当前 tabs 时依次回退
  /// 项目归属（project intent）→ 任务 intent（未归类/无项目任务兜底，
  /// 官方手机壳打开侧栏任务同路径）。导航期间保留当前首页，不闪连接中。
  Future<void> _openCrossWorkspaceTask(Map<String, dynamic> task,
      {int? deepLinkAtMs}) async {
    if (_taskNavigationPending) return;
    setState(() => _taskNavigationPending = true);
    final app = AppStateScope.of(context);
    final key = '${task['workspaceIdentity'] ?? task['workspacePath'] ?? ''}'
        .trim();
    final ws = app.workspaces
        .where((w) => workspaceKeyOf(w) == key)
        .firstOrNull;
    final project = ws == null ? app.projectForKey(key) : null;
    final taskId = '${task['taskId'] ?? ''}';
    if (ws == null && project == null && taskId.isEmpty) {
      setState(() => _taskNavigationPending = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('找不到该任务所属的工作区，可能已被桌面端移除')),
      );
      return;
    }
    // 1.0.1 真机验收⑤A（用户拍板拆两段：点卡瞬间进会话页转圈，后台
    // 开桥，桥就绪自动加载）：先推会话页并携带目标工作区键；切换与
    // 未读清除在后台完成，首页保旧列表（SWR）语义不变。
    final targetKey = ws != null
        ? workspaceKeyOf(ws)
        : project != null
        ? (primaryRootOf(project) ?? 'project-navigation')
        : taskOpenKey(task);
    _closeSearch();
    _openConversation(
      taskId,
      '${task['title'] ?? ''}'.trim().isEmpty ? '会话' : '${task['title']}',
      waitForWorkspace: targetKey,
      deepLinkAtMs: deepLinkAtMs,
    );
    try {
      if (ws != null) {
        await app.switchWorkspace(ws, keepHomePreview: true);
      } else if (project != null) {
        await app.switchToProject(project, keepHomePreview: true);
      } else {
        await app.switchToTask(task, keepHomePreview: true);
      }
      if (app.workspaceError != null) {
        app.clearStaleHomePreview();
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(const SnackBar(content: Text('工作区切换未完成，请稍后重试')));
        return;
      }
      // 跨工作区打开即已读（best-effort+compare-and-clear）。
      // 对抗审查中⑥修：合成行 unreadAt=1（card.unread 布尔折叠）
      // 不是真实 CAS marker——只有 >1 的时间戳才带 CAS（==1 时传
      // null 走无条件写，未读可清）。
      final unreadAt = intOf(task['unreadAt']);
      app.markTaskRead(
        taskId,
        expectedUnreadAt: (unreadAt != null && unreadAt > 1) ? unreadAt : null,
      );
    } catch (e) {
      app.clearStaleHomePreview();
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
            ?.showSnackBar(SnackBar(content: Text('打开任务失败：$e')));
      }
    } finally {
      if (mounted) {
        setState(() => _taskNavigationPending = false);
      } else {
        _taskNavigationPending = false;
      }
    }
  }

  Future<void> _newSession() async {
    final app = AppStateScope.of(context);
    // B 方案：当前桥未就绪仍允许先选项目/工作区（选择后开桥再进草稿）；
    // 只有完全无可选上下文时才拦截。
    if (app.conversation == null &&
        app.sidebarProjects.isEmpty &&
        app.workspaces.isEmpty) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('该电脑还在重连，稍后再试')));
      return;
    }
    await showNewTaskSheet(context, openDraftRoute: _openConversation);
  }

  /// 快捷入口 last_session：当前工作区最近活跃的会话卡（无则 null）。
  TaskCardData? _shortcutRecentCard(AppState app) {
    TaskCardData? pick;
    for (final c in app.taskList?.cards ?? const <TaskCardData>[]) {
      if (c.sessionId.isEmpty) continue;
      if (pick == null ||
          c.lastActivityAt > pick.lastActivityAt ||
          (c.lastActivityAt == pick.lastActivityAt &&
              c.pinned &&
              !pick.pinned)) {
        pick = c;
      }
    }
    return pick;
  }

  /// 快捷入口 last_session 兜底：跨工作区任务里最近更新的（带完整工作区
  /// 上下文，走跨工作区打开路径；仅当当前工作区列表为空时用）。
  Map<String, dynamic>? _shortcutRecentCrossTask(AppState app) {
    Map<String, dynamic>? pick;
    int pickTs = -1;
    for (final t in app.workspaceTasks) {
      final id = '${t['taskId'] ?? ''}';
      if (id.isEmpty) continue;
      final ts = (t['updatedAt'] as num?)?.toInt() ?? 0;
      if (ts > pickTs) {
        pickTs = ts;
        pick = t;
      }
    }
    return pick;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    // 通知点击直达（通知栏点开 app / 冷启动 payload）：post-frame 导航
    // （build 内不做导航副作用），消费后清空防重放。
    if (app.pendingOpenTask != null) {
      final target = app.pendingOpenTask!;
      // 欠账盘点 接线修复（2026-11-08）：pendingOpenTask 在此清空，
      // 而会话页的 pendingDeepLinkTarget getter 依赖它——晚于此读取
      // 恒 null=深链浮层永不弹（Explore 核查实锤）。先捕获 atMs 随
      // 导航参数透传（waitForWorkspace 同款模式），不再依赖全局时序。
      final deepAt = app.pendingDeepLinkAt;
      // 归属随 pendingDeepLinkTaskId 走（pendingOpenTask 即将被清，
      // 全局 getter 不再依赖它）。
      app.pendingOpenTask = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openFromNotification(target, deepLinkAtMs: deepAt);
      });
    }
    // 长按图标快捷入口（6.6①）：new_task 直开新建弹层；
    // last_session 等最近任务数据就绪才消费（数据到达的重建再触发），
    // 列表就绪但确实无任务时给出提示并清挂起。
    final shortcut = app.pendingShortcutAction;
    if (shortcut != null) {
      if (shortcut == 'new_task') {
        app.pendingShortcutAction = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_newSession());
        });
      } else {
        final card = _shortcutRecentCard(app);
        if (card != null) {
          app.pendingShortcutAction = null;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) unawaited(_openSession(card));
          });
        } else {
          final cross = _shortcutRecentCrossTask(app);
          if (cross != null) {
            app.pendingShortcutAction = null;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) unawaited(_openCrossWorkspaceTask(cross));
            });
          } else if (app.taskList != null) {
            app.pendingShortcutAction = null;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                ScaffoldMessenger.maybeOf(
                  context,
                )?.showSnackBar(const SnackBar(content: Text('暂无最近会话，先新建一个吧')));
              }
            });
          }
        }
      }
    }
    return FormFactorBuilder(
      builder: (context, factor, size) {
        // 6.5 双栏（2026-10-29 批次）：medium/expanded（≥600dp，展开态
        // /平板）= 窄左栏+右栏；compact（折叠态）= 现行单栏不变。
        _wideLayout = factor != AppFormFactor.compact;
        final taskList = GestureDetector(
          // 搜索打开且结果不足一屏时列表不参与手势竞争——竖向滑动由此
          // 兜底收起输入法（可滚动时列表胜出走自身 onDrag 收键盘；会话
          // 页消息区同款双路径，验收 2026-10-18）。
          behavior: HitTestBehavior.translucent,
          onVerticalDragEnd: (_) =>
              FocusManager.instance.primaryFocus?.unfocus(),
          child: _TaskList(
            onOpen: _openSession,
            onNew: _newSession,
            onOpenCross: _openCrossWorkspaceTask,
            query: _searchQuery,
            serverHits: _searchFetch == _SearchFetchState.done
                ? _serverHits ?? const <Map<String, dynamic>>[]
                : null,
            searchFetch: _searchFetch,
            homeNow: widget.homeNow,
            holdForTaskNavigation: _taskNavigationPending,
            compact: _wideLayout,
            // 验收反馈①：新建任务行随列表渲染（分组之下），搜索期隐藏。
            showNewTaskNav: _wideLayout && _searchQuery.isEmpty && !_searchOpen,
            selectedSessionId: _paneSelection?.sessionId,
            // 批量操作（优化批 #22）：多选态下到任务行（首页与搜索结果）。
            multiSelectMode: _multiSelectMode,
            selectedTaskIds: _selectedTaskIds,
            onToggleTaskSelected: _toggleTaskSelected,
            onEnterMultiSelect: _enterMultiSelect,
            // 主页视图状态（ 页面级）+跨区长按。
            homeMode: _homeMode,
            onModeChanged: (mode) => setState(() => _homeMode = mode),
            groupVisibleCounts: _homeGroupVisibleCounts,
            fullyExpandedGroups: _homeFullyExpandedGroups,
            onProgressChanged: () => setState(() {}),
            onCrossLongPress: _openTaskActionsMenu,
          ),
        );
        final banner = _taskNavigationPending
            ? const SizedBox.shrink()
            : _PhaseBanner();
        void openSettings() =>
            Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const SettingsPage()));
        void openAutomations() => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const AutomationPage()));
        Widget searchRow = _SearchRow(
          open: _searchOpen,
          query: _searchQuery,
          onChanged: _onSearchChanged,
          onClosed: _closeSearch,
        );
        // B 方案：折叠/展开共用“全部任务”主页，不再让 compact 的
        // 项目 chips 与 medium 的 88dp 文字轨形成两套能力和心智。
        // 对标官方桌面左栏（用户 2026-10-29 反馈「左侧还是有点大，任务
        // 仅需一个小标题」）：桌面左栏≈窗口 18%；手机可读性与触控下限
        // 更高，取 34% 并夹 232~320dp——展开态真机（约 740dp）实际
        // ≈250dp，右栏占约三分之二。
        final paneWidth = (size.width * 0.34).clamp(232.0, 320.0);
        // 验收②（用户反馈+提案）：双栏下 Scaffold 级 FAB 悬在右栏
        // 会话输入栏正上方=遮挡——宽屏档去掉 FAB，新建入口=左栏列表尾部的
        // 「新建任务」行（验收反馈①：从列首移到最新/项目分组之下，
        // 官方桌面侧栏对位——新建在侧栏底部）；窄屏保留 FAB 原行为。
        final homeColumn = Column(
          children: [
            banner,
            // 批量操作（优化批 #22）：多选上下文操作栏——搜索行上方常驻，
            // 首页与搜索结果两视图共用（先筛再选）。
            if (_multiSelectMode)
              _MultiSelectBar(
                selectedCount: _selectedTaskIds.length,
                running: _batchRunning,
                onArchive: _batchArchive,
                onMarkRead: _batchMarkRead,
                onDelete: _batchDelete,
                onCancel: _exitMultiSelect,
              ),
            searchRow,
            Expanded(child: taskList),
          ],
        );
        return PopScope(
          // 双栏下返回键先收右栏（选中清空回空态），无选中才允许退出；
          // 多选模式下返回键先收多选（优化批 #22）；搜索打开先收搜索
          // （：窄屏搜索态按返回直接退出 app）。
          canPop:
              (!_wideLayout || _paneSelection == null) &&
              !_multiSelectMode &&
              !_searchOpen,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop || !mounted) return;
            if (_multiSelectMode) {
              _exitMultiSelect();
              return;
            }
            if (_searchOpen) {
              _closeSearch();
              return;
            }
            setState(() => _paneSelection = null);
          },
          child: Scaffold(
            appBar: _GlassAppBar(
              // multi-account-ux-1 批1（2026-11-04 拍板）：多账号时顶栏
              // 显示「电脑名 · 账号显示名」（备注名优先）；单账号/无账号
              // 维度维持电脑名。
              title: app.activeAccountLabel == null
                  ? (app.activeProfile?.label ?? 'ZCode Companion')
                  : '${app.activeProfile?.label ?? 'ZCode Companion'} · '
                      '${app.activeAccountLabel}',
              subtitle: '任务主页',
              onTitleTap: () => showProfilesSheet(context),
              onRefresh: app.refreshWorkspaces,
              onSettings: openSettings,
              onAutomations: openAutomations,
              onSearchToggle: () {
                // 关闭复用 _closeSearch——原实现只清
                // query，在飞防抖 300ms 后照常发一次全文 RPC（结果被守卫
                // 丢弃=纯浪费），_serverHits/_searchFetch 也残留旧态。
                if (_searchOpen) {
                  _closeSearch();
                } else {
                  setState(() => _searchOpen = true);
                }
              },
            ),
            // 宽屏档无 FAB（新建入口=左栏「新建任务」行，防遮挡右栏输入栏）。
            floatingActionButton: _wideLayout
                ? null
                : FloatingActionButton.extended(
                    key: const ValueKey('new-session'),
                    onPressed:
                        app.conversation != null ||
                            app.sidebarProjects.isNotEmpty ||
                            app.workspaces.isNotEmpty
                        ? _newSession
                        : null,
                    icon: const Icon(Icons.add),
                    label: const Text('新建'),
                  ),
            body: !_wideLayout
                ? homeColumn
                : Row(
                    key: const ValueKey('dual-pane-root'),
                    children: [
                      // 仿桌面端布局（用户 2026-10-29 拍板）：左栏窄
                      // （任务列表不占太多空间），右侧大任务窗口。
                      SizedBox(width: paneWidth, child: homeColumn),
                      VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: context.colors.border,
                      ),
                      Expanded(child: _dualPaneRight(app)),
                    ],
                  ),
          ),
        );
      },
    );
  }

  /// 双栏右栏：选中的会话页（工作区匹配才有效——切换工作区后旧选
  /// 中自动失效回空态）；空态给引导提示。
  Widget _dualPaneRight(AppState app) {
    final sel = _paneSelection;
    final currentKey =
        workspaceKeyOf(app.activeWorkspace ?? const {}) ?? '';
    // 对抗审查高①：跨工作区打开是「先设选中→await 切工作区」两段式——
    // 切换窗口内 sel.workspaceKey 是目标键、activeWorkspace 仍是旧键，
    // 若按「键不等」判失效会在窗口内 post-frame 清空选中（切换完成后
    // 右栏永远空态）。等待型选中（waitForWorkspace != null）在落地前
    // 恒有效，落地后由会话页自身 waitForWorkspace 兜底。
    final waiting = (sel?.waitForWorkspace ?? '').isNotEmpty;
    final valid = sel != null && (waiting || sel.workspaceKey == currentKey);
    // 等待落地：把等待目标转正（waitForWorkspace 清空、键=当前键）——
    // 否则后续用户再手动切工作区时，选中会因「有等待目标」恒有效。
    if (waiting && sel != null && sel.waitForWorkspace == currentKey) {
      final targetSessionId = sel.sessionId;
      final targetTitle = sel.title;
      final targetDeepLink = sel.deepLinkAtMs;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final cur = _paneSelection;
        if (cur == null ||
            cur.sessionId != targetSessionId ||
            cur.waitForWorkspace != currentKey) {
          return;
        }
        setState(() {
          _paneSelection = (
            sessionId: targetSessionId,
            title: targetTitle,
            workspaceKey: currentKey,
            waitForWorkspace: null,
            deepLinkAtMs: targetDeepLink,
          );
        });
      });
    }
    if (sel != null && !valid) {
      // 构建期不可 setState——post-frame 清选（下帧回空态）。
      // 仅限「无等待目标且键确不匹配」：等待型选中不在此清。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _paneSelection == sel) {
          setState(() => _paneSelection = null);
        }
      });
    }
    if (!valid) {
      return const _DualPaneEmpty();
    }
    return ConversationPage(
      key: ValueKey('dual-pane-${sel.sessionId ?? 'draft'}'),
      sessionId: sel.sessionId,
      title: sel.title,
      waitForWorkspace: sel.waitForWorkspace,
      // 右栏同传深链时刻（平板浮层此前恒不弹）。
      deepLinkAtMs: sel.deepLinkAtMs,
    );
  }
}

/// 双栏右栏空态：引导提示（首版无选中高亮联动左栏——选中态由右栏
/// 内容自证）。
class _DualPaneEmpty extends StatelessWidget {
  const _DualPaneEmpty();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 40,
            color: context.colors.foregroundSubtlest,
          ),
          const SizedBox(height: 12),
          Text(
            tr('从左侧选择任务，或点「新建」开始'),
            style: TextStyle(
              fontSize: AppType.uiSm,
              color: context.colors.foregroundSubtle,
            ),
          ),
        ],
      ),
    );
  }
}

/// 多选上下文操作栏（优化批 #22）：「已选 N 个」+ 归档/标已读/删除/
/// 取消。批量执行期间按钮禁用防双发；删除走二次确认（_batchDelete）。
class _MultiSelectBar extends StatelessWidget {
  final int selectedCount;
  final bool running;
  final VoidCallback onArchive;
  final VoidCallback onMarkRead;
  final VoidCallback onDelete;
  final VoidCallback onCancel;

  const _MultiSelectBar({
    required this.selectedCount,
    required this.running,
    required this.onArchive,
    required this.onMarkRead,
    required this.onDelete,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = !running && selectedCount > 0;
    return Material(
      key: const ValueKey('multi-select-bar'),
      color: context.colors.brandAccent.withValues(alpha: AppAlpha.faint),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
        child: Row(
          children: [
            if (running)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 1.6),
              )
            else
              Icon(
                Icons.check_circle,
                size: 16,
                color: context.colors.brandAccent,
              ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                // 整串走 pattern 翻译（教训：拼接串不留
                // 英文残留），见 custom_l10n 的 已选 (\d+) 个 模板。
                '已选 $selectedCount 个',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  fontWeight: FontWeight.w600,
                  color: context.colors.foreground,
                ),
              ),
            ),
            // 验收#10（优化意见 G）：图标+文字并示（用户实锤仅
            // 图标无法区分归档/已读/删除）；小号紧凑防挤。
            TextButton.icon(
              key: const ValueKey('multi-archive'),
              onPressed: enabled ? onArchive : null,
              icon: const Icon(Icons.archive_outlined, size: 16),
              label: Text(
                tr('归档'),
                style: const TextStyle(fontSize: AppType.uiCaption),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 40),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            TextButton.icon(
              key: const ValueKey('multi-mark-read'),
              onPressed: enabled ? onMarkRead : null,
              icon: const Icon(Icons.done_all, size: 16),
              label: Text(
                tr('已读'),
                style: const TextStyle(fontSize: AppType.uiCaption),
              ),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 40),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            TextButton.icon(
              key: const ValueKey('multi-delete'),
              onPressed: enabled ? onDelete : null,
              icon: Icon(
                Icons.delete_outline,
                size: 16,
                color: context.colors.destructive,
              ),
              label: Text(
                tr('删除'),
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  color: context.colors.destructive,
                ),
              ),
              style: TextButton.styleFrom(
                foregroundColor: context.colors.destructive,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 40),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            TextButton(
              key: const ValueKey('multi-cancel'),
              onPressed: running ? null : onCancel,
              child: Text(tr('取消')),
            ),
          ],
        ),
      ),
    );
  }
}

String? _workspaceLabelOf(Map<String, dynamic> ws) {
  final label = ws['label'];
  if (label is String && label.trim().isNotEmpty) return label.trim();
  final identity = '${ws['workspaceIdentity'] ?? ''}';
  final path = '${ws['workspacePath'] ?? ''}';
  final base = identity.contains(':') ? identity : path;
  final parts = base
      .split(RegExp(r'[\\/]'))
      .where((p) => p.isNotEmpty)
      .toList();
  return parts.isEmpty ? base : parts.last;
}

/// 顶栏（V1 审美优化 2026-10-22：GlassChrome 退役，全库 chrome 统一
/// 实体白 + 底 hairline——摘除模糊后仅剩的半透明白在纯白底上零收益）。
/// 顶栏常驻当前电脑名，点击弹出档案面板。
class _GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String title;
  final String subtitle;
  final VoidCallback onTitleTap;
  final VoidCallback onRefresh;
  final VoidCallback? onSettings;
  final VoidCallback? onSearchToggle;

  /// 定时任务列表入口（阶段 3 第三段；官方桌面在设置里，手机端放任务
  /// 中心 AppBar 更贴任务域）。
  final VoidCallback? onAutomations;

  const _GlassAppBar({
    required this.title,
    required this.subtitle,
    required this.onTitleTap,
    required this.onRefresh,
    this.onSettings,
    this.onSearchToggle,
    this.onAutomations,
  });

  @override
  // 带 bottom hairline（1px）的 delegate 应把 bottom
  // 计入 preferredSize（52+1=53）——Scaffold 布局按实测子高度定位 body
  // 无实际重叠（排除项 2 已实证），此处修契约防未来 Sliver 场景偏差。
  Size get preferredSize => const Size.fromHeight(53);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      // -7A（2026-10-29 批次）：外层 preferredSize 声明 52，内层此前
      // 用 Material 默认 56——声明与实际不符。校准为 52（设计语言
      // ui-references §V1：AppBar 统一 52 高；会话页同款）。
      toolbarHeight: 52,
      titleSpacing: 8,
      title: InkWell(
        onTap: onTitleTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          // 批次A 触控（设计审计）：竖向命中垫 ≥48——minHeight 保证与
          // 标题内容行数无关；AppBar 工具栏 56 容得下，文字仍居中。
          constraints: const BoxConstraints(minHeight: 48),
          // 左对齐（视觉验收 ：center 在展开态宽约束下把两行标题
          // 漂到可用空间中央，与折叠态左对齐不一致）。
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const Icon(Icons.expand_more, size: 18),
                      ],
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.foregroundSubtlest,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (onSearchToggle != null)
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: tr('搜索任务'),
            onPressed: onSearchToggle,
          ),
        if (onAutomations != null)
          IconButton(
            key: const ValueKey('open-automations'),
            icon: const Icon(Icons.schedule),
            tooltip: tr('定时任务'),
            onPressed: onAutomations,
          ),
        if (onSettings != null)
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: tr('设置'),
            onPressed: onSettings,
          ),
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: tr('刷新工作区列表'),
          onPressed: onRefresh,
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: context.colors.border),
      ),
    );
  }
}

/// 连接状态横幅：非 online 时显示（失效→重扫、被踢→说明、重连中→提示）。
class _PhaseBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    // 批3：跨电脑切换提示优先（一次性，展示后 4s 自动清）。
    final switchNotice = app.switchNotice;
    if (switchNotice != null) {
      // 消费定时器在 AppState 设置处一次性排好（build 内排程=重建循环）。
      return Material(
        color: context.colors.linkBlue.withValues(alpha: AppAlpha.light),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.swap_horiz, size: 16, color: context.colors.linkBlue),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  switchNotice,
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    color: context.colors.linkBlue,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final (icon, text, color, action) = switch (app.phase) {
      LinkPhase.invalid => (
        Icons.qr_code_scanner,
        '凭据已失效（桌面可能刷新了二维码）',
        context.colors.warning,
        '重新扫码',
      ),
      LinkPhase.kicked => (
        Icons.swap_horiz,
        '已被其他手机页接管',
        context.colors.destructive,
        '强制接管',
      ),
      LinkPhase.reconnecting => (
        Icons.sync,
        app.phaseDetail ?? '连接中断，自动重连中…',
        context.colors.linkBlue,
        null,
      ),
      LinkPhase.connecting => (
        Icons.sync,
        '连接中…',
        context.colors.linkBlue,
        null,
      ),
      LinkPhase.waitingDesktop => (
        Icons.hourglass_top,
        '等待桌面端确认…（ZCode 需保持运行）',
        context.colors.linkBlue,
        null,
      ),
      LinkPhase.error => (
        Icons.error_outline,
        '连接失败',
        context.colors.destructive,
        null,
      ),
      _ => (null, null, null, null),
    };
    if (icon == null || text == null || color == null) {
      return const SizedBox.shrink();
    }
    return Material(
      color: color.withValues(alpha: AppAlpha.light),
      child: InkWell(
        onTap: action == null
            ? null
            : () {
                if (app.phase == LinkPhase.kicked) {
                  // 用户需求①：新终端接管（对端被踢下线，其 5 分钟预算
                  // 内不再自救，避免互踢风暴）。
                  app.takeoverConnection();
                  return;
                }
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const PairingPage()));
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  text,
                  style: TextStyle(fontSize: AppType.uiCaption, color: color),
                ),
              ),
              if (action != null)
                Text(
                  action,
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 任务主页（项目栏优化 B 方案）：全部任务 + 最近｜项目 + 置顶/分组。
/// 不再以常驻项目 chips/88dp 文字轨充当一级导航；项目成为分组与新建
/// 上下文，任务/会话回到首页主对象（官方 mobile-task-home-design 同向）。
/// 批4：聚合区候选（纯函数供测试）——非活跃、有效、V2 档案。
List<AccountV2Profile> otherComputerCandidates(
  List<DeviceProfile> profiles,
  String? activeSid,
) => profiles
    .whereType<AccountV2Profile>()
    .where((p) => p.deviceSid != activeSid && !p.invalid)
    .toList();

/// 批4（multi-account-ux-1）：其他电脑聚合区的任务行——缓存快照只读
/// 展示（紧凑单行：标题+电脑标识前缀），点击=activate 该电脑后经
/// pendingOpenTask 打开（复用通知直达编排）。
class _OtherComputerTaskRow extends StatelessWidget {
  const _OtherComputerTaskRow({
    required this.task,
    required this.deviceLabel,
    required this.onTap,
  });

  final Map<String, dynamic> task;
  final String deviceLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final title = '${task['title'] ?? task['name'] ?? ''}'.trim();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: Row(
            children: [
              Icon(
                Icons.circle,
                size: 6,
                color: context.colors.foregroundSubtlest,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title.isEmpty ? '（无标题任务）' : title,
                  translate: false,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: AppType.uiSm),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskHomeView extends StatefulWidget {
  final void Function(Map<String, dynamic> task) onOpen;
  final DateTime? now;

  /// 非在线预览：仅显示上次内容，running/waiting 清洗为 idle。
  final bool stale;

  /// 双栏紧凑档（fold-dual-pane-2）：任务行=官方桌面侧栏式单行小标题。
  final bool compact;

  /// 右栏当前打开的会话（=taskId）——紧凑行选中填充信号。
  final String? selectedSessionId;

  /// 验收反馈①：宽屏左栏「新建任务」行（列表尾部，最新/项目
  /// 分组之下——官方桌面侧栏新建在底部的对位）。窄屏入口=FAB 不传。
  final bool showNewTaskNav;
  final VoidCallback? onNew;

  // ---- 批量操作（优化批 #22）：任务行多选态（状态在页面级，见
  // _TaskCenterPageState 注释）----
  final bool multiSelectMode;
  final Set<String> selectedTaskIds;
  final void Function(String taskId, String? workspaceKey)? onToggleTaskSelected;

  /// 长按菜单「选择任务」入口（页面级 _enterMultiSelect）。
  final void Function(String taskId)? onEnterMultiSelect;

  // ---- 视图状态（/ 提升到页面级）----
  /// 「最近/项目」页签（页面级持有——本视图在搜索开合/分支切换时销毁
  /// 重建，State 级会被重置回「最近」）。
  final TaskHomeMode mode;
  final ValueChanged<TaskHomeMode> onModeChanged;

  /// 渐进披露计数/全展组（页面级持有，语义同上）。
  final Map<String, int> groupVisibleCounts;
  final Set<String> fullyExpandedGroups;

  /// 渐进披露状态变更后的重建回调（页面 setState——map/set 由页面
  /// 持有，本视图直接变异后调用）。
  final VoidCallback onProgressChanged;

  /// 长按任务菜单（页面级实现：ensureContext 归属护栏+多选入口）。
  final void Function(Map<String, dynamic> task)? onLongPress;

  const _TaskHomeView({
    required this.onOpen,
    this.now,
    this.stale = false,
    this.compact = false,
    this.selectedSessionId,
    this.showNewTaskNav = false,
    this.onNew,
    this.multiSelectMode = false,
    this.selectedTaskIds = const {},
    this.onToggleTaskSelected,
    this.onEnterMultiSelect,
    required this.mode,
    required this.onModeChanged,
    required this.groupVisibleCounts,
    required this.fullyExpandedGroups,
    required this.onProgressChanged,
    this.onLongPress,
  });

  @override
  State<_TaskHomeView> createState() => _TaskHomeViewState();
}

class _TaskHomeViewState extends State<_TaskHomeView> {
  // 折叠组持久化（官方 localStorage 每项目
  // expanded 对位）——启动从 UiPrefs 预填，增删即时落盘。
  Set<String> _collapsedGroups = {};
  bool _collapsedSeeded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_collapsedSeeded) return;
    _collapsedSeeded = true;
    final saved = AppStateScope.of(context).uiPrefs.homeCollapsedGroups;
    if (saved.isNotEmpty) _collapsedGroups = {...saved};
  }

  // ---- 主页行合成 memoize----
  // si 活动帧/5s notify 期间每次重建全量重算+重排序（O(n log n)+全行
  // Map 复制）；输入引用未变时（record == 逐字段比较、List 按 identity）
  // 直接复用上次结果。
  Object? _preparedInputs;
  List<Map<String, dynamic>>? _preparedCache;

  List<Map<String, dynamic>> _preparedRows(AppState app) {
    // workspaceTasks 为主集（非空时 currentTasks 整体弃用——惰性构建，
    // 避免主集就绪后 card→map 转换白算）。
    final currentTasks = app.workspaceTasks.isEmpty
        ? [
            for (final card in app.taskList?.cards ?? const <TaskCardData>[])
              taskHomeCardRow(card, app.activeWorkspace ?? const {}),
          ]
        : const <Map<String, dynamic>>[];
    final inputs = (
      app.workspaceTasks,
      app.projectTasks,
      app.sidebarProjects,
      currentTasks,
    );
    final cache = _preparedCache;
    if (cache != null && inputs == _preparedInputs) {
      return cache;
    }
    final prepared = prepareTaskHomeRows(
      workspaceTasks: app.workspaceTasks,
      projectTasks: app.projectTasks,
      projects: app.sidebarProjects,
      currentTasks: currentTasks,
    );
    _preparedInputs = inputs;
    _preparedCache = prepared;
    return prepared;
  }

  // ---- 批4：其他电脑任务聚合（缓存快照，默认关）----
  List<({DeviceProfile profile, DeviceCacheEntry entry})>? _otherComputers;
  bool _otherLoading = false;
  bool _otherExpanded = true;

  /// 聚合缓存读盘 TTL（此前每次 build 都对全部候选电脑
  /// 读盘+JSON 解码——与批4 省电红线相悖）。60s 内同签名直接复用。
  DateTime? _otherLoadedAt;

  void _maybeLoadOtherComputers(AppState app) {
    if (!app.uiPrefs.showOtherComputers) {
      // 关闭档清 TTL：否则 60s 内重新打开时 on 分支被 TTL 早退，聚合
      // 区维持 null（关→开 60s 内不加载的实测空窗）。
      _otherLoadedAt = null;
      if (_otherComputers != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _otherComputers = null);
        });
      }
      return;
    }
    final candidates = otherComputerCandidates(
      app.profiles,
      app.activeProfile?.deviceSid,
    );
    if (candidates.isEmpty) {
      if (_otherComputers?.isNotEmpty ?? false) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _otherComputers = const []);
        });
      }
      return;
    }
    final store = app.cacheStore;
    if (store == null || _otherLoading) return;
    // TTL 内不重读（签名比对只在到龄后做——数据陈旧度由「缓存于 X 前」
    // 时间标注向用户诚实呈现）。
    final now = DateTime.now();
    if (_otherLoadedAt != null &&
        now.difference(_otherLoadedAt!).inSeconds < 60) {
      return;
    }
    _otherLoading = true;
    unawaited(() async {
      final out = <({DeviceProfile profile, DeviceCacheEntry entry})>[];
      for (final p in candidates) {
        try {
          final entry = await store.readDevice(p.deviceSid);
          if (entry != null && entry.workspaceTasks.isNotEmpty) {
            out.add((profile: p, entry: entry));
          }
        } catch (_) {}
      }
      _otherLoading = false;
      if (!mounted) return;
      _otherLoadedAt = DateTime.now();
      final sigNow = _otherComputers
          ?.map((e) => '${e.profile.deviceSid}@${e.entry.savedAt}')
          .join('|');
      final sigNext =
          out.map((e) => '${e.profile.deviceSid}@${e.entry.savedAt}').join('|');
      if (sigNow != sigNext) setState(() => _otherComputers = out);
    }());
  }

  Widget _buildOtherComputers(AppState app) {
    final list = _otherComputers;
    if (!app.uiPrefs.showOtherComputers || list == null || list.isEmpty) {
      return const SizedBox.shrink();
    }
    final now = DateTime.now();
    String ago(int savedAt) {
      // 时间片段先 tr 再拼——'缓存于 {time}' 的 pattern
      // 捕获段不递归（词条已有 刚刚/N 分钟前/N 小时前/N 天前）。
      final d = now.difference(DateTime.fromMillisecondsSinceEpoch(savedAt));
      if (d.inMinutes < 1) return tr('刚刚');
      if (d.inHours < 1) return tr('${d.inMinutes} 分钟前');
      if (d.inDays < 1) return tr('${d.inHours} 小时前');
      return tr('${d.inDays} 天前');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: const ValueKey('other-computers-header'),
          onTap: () => setState(() => _otherExpanded = !_otherExpanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
            child: Row(
              children: [
                Icon(
                  _otherExpanded ? Icons.expand_more : Icons.chevron_right,
                  size: 16,
                  color: context.colors.foregroundSubtle,
                ),
                const SizedBox(width: 6),
                Text(
                  '其他电脑（${list.length}）',
                  style: TextStyle(
                    fontSize: AppType.uiCaption,
                    fontWeight: FontWeight.w600,
                    color: context.colors.foregroundSubtle,
                  ),
                ),
                const Spacer(),
                Text(
                  '缓存快照',
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: context.colors.foregroundSubtlest,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_otherExpanded)
          for (final g in list) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
              child: Row(
                children: [
                  Icon(Icons.computer, size: 13,
                      color: context.colors.foregroundSubtle),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      g.profile.label,
                      translate: false,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    tr('缓存于 ') + ago(g.entry.savedAt),
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: context.colors.foregroundSubtlest,
                    ),
                  ),
                ],
              ),
            ),
            for (final task in _recentTasks(g.entry.workspaceTasks, 5))
              _OtherComputerTaskRow(
                task: task,
                deviceLabel: g.profile.label,
                onTap: () => _openOtherComputerTask(app, g.profile, task),
              ),
          ],
      ],
    );
  }

  Future<void> _openOtherComputerTask(
    AppState app,
    DeviceProfile profile,
    Map<String, dynamic> task,
  ) async {
    // 缓存白名单（cacheHomeTaskRows keys）只有 taskId——
    // 此前读 sessionId??id 恒空串早退，聚合行点击零效果。
    final taskId = '${task['taskId'] ?? task['id'] ?? ''}';
    if (taskId.isEmpty) return;
    try {
      await app.activate(profile);
    } catch (_) {
      // （批3）：静默失败=点了没反应——给人话提示。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('切换电脑失败，请重试'))),
        );
      }
      return;
    }
    // 复用通知直达编排（设置 pendingOpenTask + notify + 台账点击标记）。
    app.openTaskFromNotification(profile.deviceSid, taskId);
  }

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    // 批4：其他电脑聚合（缓存快照）按需装载（开关开才读盘）。
    _maybeLoadOtherComputers(app);
    final prepared = _preparedRows(app);
    final rows = widget.stale
        ? sanitizeTaskHomePreviewRows(prepared)
        : prepared;
    return Column(
      children: [
        _buildHeader(context),
        Expanded(child: _buildBody(context, app, rows)),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: SegmentedButton<TaskHomeMode>(
              showSelectedIcon: false,
              expandedInsets: L10n.resolvedLocale == 'en-US'
                  ? EdgeInsets.zero
                  : null,
              // 审美门建议①（用户拍板）：选中段默认色来自主题
              // colorScheme（紫系）与全局「黑白骨架+智谱蓝点睛」离群，
              // 且与 FAB 同屏双强调色——显式归一品牌蓝。
              style: SegmentedButton.styleFrom(
                padding: L10n.resolvedLocale == 'en-US'
                    ? EdgeInsets.zero
                    : null,
                minimumSize: const Size(0, 40),
                selectedBackgroundColor: context.colors.brandAccent.withValues(
                  alpha: AppAlpha.faint,
                ),
                selectedForegroundColor: context.colors.brandAccent,
              ),
              segments: const [
                ButtonSegment(
                  value: TaskHomeMode.recent,
                  label: Text(
                    '最近',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ButtonSegment(
                  value: TaskHomeMode.projects,
                  label: Text(
                    '项目',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              selected: {widget.mode},
              onSelectionChanged: (selection) =>
                  widget.onModeChanged(selection.first),
            ),
          ),
          PopupMenuButton<String>(
            key: const ValueKey('home-more'),
            tooltip: tr('更多'),
            icon: const Icon(Icons.more_vert, size: 20),
            onSelected: (value) {
              if (value == 'order') {
                showProjectOrderSheet(context);
              } else if (value == 'archived') {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ArchivedTasksPage()),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'order', child: Text('项目排序')),
              PopupMenuItem(value: 'archived', child: Text('已归档的任务')),
            ],
          ),
        ],
      ),
    );
  }

  /// 宽屏左栏「新建任务」导航行（验收② FAB 遮挡改版； 验收
  /// 反馈①从列首移到列表尾部=官方桌面侧栏新建在底部对位）。
  Widget _newTaskNavRow() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: const ValueKey('home-new-task-nav'),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: widget.onNew,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
          child: Row(
            children: [
              Icon(Icons.add, size: 18, color: context.colors.foregroundSubtle),
              const SizedBox(width: 10),
              Text(
                '新建任务',
                style: TextStyle(
                  fontSize: AppType.uiBase,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppState app,
    List<Map<String, dynamic>> rows,
  ) {
    if (rows.isEmpty) {
      final error =
          app.workspaceError ??
          (app.readTreeStatus == 'failed' ? '任务列表加载失败\n检查电脑端连接后重试' : null);
      final loading =
          error == null &&
          (app.workspaceOpening ||
              (app.readTreeStatus == 'loading' && app.taskList == null));
      return RefreshIndicator(
        onRefresh: app.refreshWorkspaces,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 96, 16, 88),
          children: [
            if (error != null) ...[
              Icon(
                Icons.cloud_off_outlined,
                size: 40,
                color: context.colors.foregroundSubtlest,
              ),
              const SizedBox(height: 12),
              Text(
                error,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.colors.destructive,
                  fontSize: AppType.uiCaption,
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: OutlinedButton.icon(
                  key: const ValueKey('home-retry'),
                  onPressed: app.readTreeStatus == 'failed'
                      ? app.refreshWorkspaces
                      : app.retryWorkspaceOpen,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('重试'),
                ),
              ),
            ] else if (loading)
              const Center(child: AppLoading('正在加载任务…'))
            else
              AppEmptyState(
                icon: Icons.chat_bubble_outline,
                // 宽屏无 FAB（起）——空态
                // 文案不得指向不存在的右下角按钮。
                text: widget.compact
                    ? '还没有任务\n点下方「新建任务」开始对话'
                    : '还没有任务\n点右下角「新建」开始对话',
              ),
            if (widget.showNewTaskNav && widget.onNew != null) ...[
              const SizedBox(height: 12),
              _newTaskNavRow(),
            ],
            // 批4：空态也渲染其他电脑聚合区（开关开且有缓存）——其他
            // 电脑的任务不依赖本机连接态。
            _buildOtherComputers(app),
          ],
        ),
      );
    }

    final items = buildTaskHomeItems(
      rows: rows,
      mode: widget.mode,
      collapsedGroups: _collapsedGroups,
      now: widget.now ?? DateTime.now(),
      groupVisibleCounts: widget.groupVisibleCounts,
      fullyExpandedGroups: widget.fullyExpandedGroups,
    );
    return RefreshIndicator(
      onRefresh: app.refreshWorkspaces,
      // 主页行也包 _MinuteTicker——「刚刚/N 分钟前」
      // 标签此前只在下一次数据 notify 才重算，停留期间不刷新（搜索路径
      // 既有同款先例）。
      child: _MinuteTicker(
        builder: (context) => ListView.builder(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(bottom: 88),
          // 批4：尾部两个附加区——其他电脑聚合（开关开且有缓存才占位）
          // 与「新建任务」行。
          itemCount: items.length +
              (widget.showNewTaskNav ? 1 : 0) +
              1,
          itemBuilder: (context, index) {
            // 批4：聚合区固定在最后（新建行之上）。
            if (index == items.length + (widget.showNewTaskNav ? 1 : 0)) {
              return KeyedSubtree(
              key: const ValueKey('home-other-computers'),
              child: _buildOtherComputers(app),
            );
            }
            // 列表尾「新建任务」行（验收反馈①：最新/项目分组之下）。
            if (index == items.length) {
              return KeyedSubtree(
              key: const ValueKey('home-new-task'),
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _newTaskNavRow(),
              ),
            );
            }
            final item = items[index];
            switch (item.kind) {
              case TaskHomeItemKind.section:
                // 2026-11-05 反馈②B：条目稳定 key——转场期间数据帧重排
                // 时同 id 条目元素复用（防重挂=动画重启/闪烁观感）。
                return KeyedSubtree(
                  key: ValueKey('home-section-${item.key}'),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      item.key == 'section:pinned' ? 4 : 16,
                      16,
                      6,
                    ),
                    child: Text(
                      // 标题先 tr 再拼数量（整串无 exact/
                      // pattern 命中=英文界面残留）。
                      '${tr(item.title)} ${item.count}',
                      style: TextStyle(
                        fontSize: AppType.uiCaption,
                        fontWeight: FontWeight.w500,
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                  ),
                );
              case TaskHomeItemKind.group:
                return KeyedSubtree(
                  key: ValueKey('home-group-${item.groupKey}'),
                  child: _HomeGroupHeader(
                    item: item,
                    onTap: () => setState(() {
                      final key = item.groupKey!;
                      final collapse = !_collapsedGroups.contains(key);
                      if (collapse) {
                        _collapsedGroups.add(key);
                      } else {
                        _collapsedGroups.remove(key);
                      }
                      AppStateScope.of(context).uiPrefs
                          .setHomeGroupCollapsed(key, collapse);
                    }),
                  ),
                );
              case TaskHomeItemKind.task:
                if (widget.compact) {
                  final rowTaskId = '${item.task!['taskId']}';
                  return KeyedSubtree(
                    key: ValueKey('home-task-$rowTaskId'),
                    child: _CompactTaskRow.fromCross(
                      task: item.task!,
                      now: widget.now,
                      selectedSessionId: widget.selectedSessionId,
                      onTap: widget.onOpen,
                      onLongPress: widget.onLongPress,
                      multiSelectMode: widget.multiSelectMode,
                      multiSelected: widget.selectedTaskIds.contains(rowTaskId),
                      onToggleSelect: widget.onToggleTaskSelected == null
                          ? null
                          : () => widget.onToggleTaskSelected!(
                                rowTaskId,
                                taskWorkspaceKey(item.task!),
                              ),
                    ),
                  );
                }
                return KeyedSubtree(
                  key: ValueKey('home-task-${item.task!['taskId']}'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: _CrossTaskCard(
                      task: item.task!,
                      onOpen: widget.onOpen,
                      showWorkspaceLabel: widget.mode == TaskHomeMode.recent,
                      now: widget.now,
                      onLongPress: widget.onLongPress,
                      multiSelectMode: widget.multiSelectMode,
                      multiSelected: widget.selectedTaskIds.contains(
                        '${item.task!['taskId']}',
                      ),
                      onToggleSelect: widget.onToggleTaskSelected,
                    ),
                  ),
                );
              case TaskHomeItemKind.more:
                final key = item.groupKey!;
                // 紧凑档（fold-dual-pane-2）：官方桌面「显示更多」=低灰文字
                // 链——窄栏里品牌色实心钮视觉过重。
                // 优化批 #13：默认档组感知（项目组 3/最近视图时间桶 5），
                // 与 buildTaskHomeItems 的 _resolveGroupVisible 同口径。
                // 计数/全展集合为页面级（widget 字段），
                // 变异后经 onProgressChanged 重建。
                void showMore() {
                  final counts = widget.groupVisibleCounts;
                  final fully = widget.fullyExpandedGroups;
                  final base = counts[key] ?? taskHomeGroupDefaultVisible(key);
                  if (base < 0) {
                    // 近四日全展档正常不产 more 项，防御性兜底=全展。
                    fully.add(key);
                  } else if (item.count > 5) {
                    counts[key] = base + 5;
                  } else {
                    fully.add(key);
                  }
                  widget.onProgressChanged();
                }
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: Row(
                    children: [
                      // 验收#9（优化意见 C）：窄屏档撤蓝底主按钮——
                      // 统一低灰文字钮（对齐 fold-dual-pane-2 宽屏档；用户
                      // 拍板弱化：原品牌色实心钮太抢眼且占空间）。
                      Expanded(
                        child: TextButton.icon(
                          key: ValueKey('home-show-more-$key'),
                          onPressed: showMore,
                          icon: Icon(
                            item.count > 5
                                ? Icons.expand_more
                                : Icons.unfold_more,
                            size: 16,
                            color: context.colors.foregroundSubtle,
                          ),
                          label: Text(
                            item.count > 5 ? '再显示 5 个' : '展开剩余 ${item.count} 项',
                            style: TextStyle(
                              fontSize: AppType.uiCaption,
                              color: context.colors.foregroundSubtle,
                            ),
                          ),
                          style: TextButton.styleFrom(
                            minimumSize: const Size(0, 44),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                        ),
                      ),
                      if (item.count > 5) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          key: ValueKey('home-expand-all-$key'),
                          onPressed: () {
                            widget.fullyExpandedGroups.add(key);
                            widget.onProgressChanged();
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: context.colors.foregroundSubtle,
                            minimumSize: const Size(0, 44),
                          ),
                          child: const Text(
                            '全部展开',
                            style: TextStyle(fontSize: AppType.uiCaption),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
            }
          },
        ),
      ),
    );
  }
}

class _HomeGroupHeader extends StatelessWidget {
  final TaskHomeItem item;
  final VoidCallback onTap;

  const _HomeGroupHeader({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final isConversations = item.groupKey == 'conversations';
    // 优化批 #13：最近视图时间桶也走组头（可折叠）；图标用时钟区分
    // 项目文件夹，桶名是界面文案需要翻译（项目名是数据内容不译）。
    final isRecentBucket = (item.groupKey ?? '').startsWith(
      kTaskHomeRecentGroupPrefix,
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('home-${item.key}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              Icon(
                isConversations
                    ? Icons.chat_bubble_outline
                    : isRecentBucket
                    ? Icons.schedule
                    : Icons.folder_outlined,
                size: 17,
                color: context.colors.foregroundSubtle,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  item.title,
                  translate: isConversations || isRecentBucket,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: AppType.uiCaption,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (item.running > 0) ...[
                Icon(
                  Icons.play_circle_outline,
                  size: 14,
                  color: context.colors.running,
                ),
                const SizedBox(width: 2),
                Text(
                  '${item.running}',
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: context.colors.running,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              if (item.waiting > 0) ...[
                Icon(
                  Icons.front_hand_outlined,
                  size: 13,
                  color: context.colors.interactionAskForeground,
                ),
                const SizedBox(width: 2),
                Text(
                  '${item.waiting}',
                  style: TextStyle(
                    fontSize: AppType.uiXs,
                    color: context.colors.interactionAskForeground,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              Text(
                '${item.count} 项',
                style: TextStyle(
                  fontSize: AppType.uiXs,
                  color: context.colors.foregroundSubtlest,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                item.collapsed ? Icons.expand_more : Icons.expand_less,
                size: 20,
                color: context.colors.foregroundSubtle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

bool _hasHomeData(AppState app) =>
    app.workspaceTasks.isNotEmpty ||
    app.projectTasks.isNotEmpty ||
    (app.taskList?.cards.isNotEmpty ?? false);

/// 非在线但有上次内容时的首页提示条：不伪装实时，也给手动刷新入口。
class _HomeStaleStrip extends StatelessWidget {
  final AppState app;
  const _HomeStaleStrip(this.app);

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey('home-stale-strip'),
      color: context.colors.linkBlue.withValues(alpha: AppAlpha.faint),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Icon(Icons.sync, size: 15, color: context.colors.linkBlue),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '显示上次同步内容 · 正在恢复连接',
                style: TextStyle(
                  fontSize: AppType.uiXs,
                  color: context.colors.linkBlue,
                ),
              ),
            ),
            TextButton(
              onPressed: app.refreshWorkspaces,
              child: const Text('刷新'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 任务列表：双源合并模型驱动（置顶/运行中/全部三区，归档剔除）。
class _TaskList extends StatelessWidget {
  final void Function(TaskCardData) onOpen;
  final VoidCallback onNew;

  /// 跨工作区任务点按（先切工作区再开会话）。
  final void Function(Map<String, dynamic> task)? onOpenCross;
  final String query;

  /// ：官方 listTaskList 全文命中（仅 done 态传值；null=未搜索/
  /// 失败，此时只用本地标题/预览过滤）。
  final List<Map<String, dynamic>>? serverHits;
  final _SearchFetchState searchFetch;
  final DateTime? homeNow;
  final bool holdForTaskNavigation;

  /// 双栏紧凑档（fold-dual-pane-2）：宽屏左栏任务行=官方桌面侧栏式
  /// 单行小标题（图标槽+标题+相对时间），窄屏保持卡片。
  final bool compact;

  /// 右栏当前打开的会话（=taskId）——紧凑行选中填充信号。
  final String? selectedSessionId;

  /// 宽屏左栏「新建任务」行显隐（主页列表尾部渲染，见 _TaskHomeView）。
  final bool showNewTaskNav;

  // ---- 批量操作（优化批 #22）：透传到首页与搜索结果任务行 ----
  final bool multiSelectMode;
  final Set<String> selectedTaskIds;

  /// 行级工作区键随选择集上报（跨区搜索行/index 未覆盖行的批量归属）。
  final void Function(String taskId, String? workspaceKey)? onToggleTaskSelected;
  final void Function(String taskId)? onEnterMultiSelect;

  // ---- 主页视图状态（ 提升页面级后的透传）----
  final TaskHomeMode homeMode;
  final ValueChanged<TaskHomeMode> onModeChanged;
  final Map<String, int> groupVisibleCounts;
  final Set<String> fullyExpandedGroups;
  final VoidCallback onProgressChanged;

  /// 跨工作区/搜索行长按菜单（：宽屏搜索跨区紧凑行
  /// 此前无长按——与同视图当前区行同权；ensureContext 护栏支持跨区）。
  final void Function(Map<String, dynamic> task)? onCrossLongPress;

  const _TaskList({
    required this.onOpen,
    required this.onNew,
    this.onOpenCross,
    this.query = '',
    this.serverHits,
    this.searchFetch = _SearchFetchState.idle,
    this.homeNow,
    this.holdForTaskNavigation = false,
    this.compact = false,
    this.selectedSessionId,
    this.showNewTaskNav = false,
    this.multiSelectMode = false,
    this.selectedTaskIds = const {},
    this.onToggleTaskSelected,
    this.onEnterMultiSelect,
    required this.homeMode,
    required this.onModeChanged,
    required this.groupVisibleCounts,
    required this.fullyExpandedGroups,
    required this.onProgressChanged,
    this.onCrossLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final app = AppStateScope.of(context);
    final index = app.sessionsIndex;
    if (holdForTaskNavigation && query.trim().isEmpty) {
      // 2026-11-05 反馈②：三分支统一 Column[strip 槽, Expanded(Home)]
      // 树形——槽位恒在（在线=SizedBox.shrink），_TaskHomeViewState 在
      // hold↔在线↔恢复三分支切换间不再销毁重建（滚动位置/展开计数
      // 静默重置的「整页刷新了一下」观感根因）。
      return Column(
        children: [
          const SizedBox.shrink(),
          Expanded(
            child: _TaskHomeView(
              onOpen: onOpenCross ?? (_) {},
              now: homeNow,
              compact: compact,
              selectedSessionId: selectedSessionId,
              showNewTaskNav: showNewTaskNav,
              onNew: onNew,
              multiSelectMode: multiSelectMode,
              selectedTaskIds: selectedTaskIds,
              onToggleTaskSelected: onToggleTaskSelected,
              onEnterMultiSelect: onEnterMultiSelect,
              mode: homeMode,
              onModeChanged: onModeChanged,
              groupVisibleCounts: groupVisibleCounts,
              fullyExpandedGroups: fullyExpandedGroups,
              onProgressChanged: onProgressChanged,
              onLongPress: onCrossLongPress,
            ),
          ),
        ],
      );
    }
    if (app.phase != LinkPhase.online) {
      // 第一档连接诊断（2026-10-23）：重连失败时把原因翻译成人话+
      // 可操作提示（VPN/DNS 场景此前完全无信息，用户只能猜）。
      final diag = app.relayDiagnosis;
      if (diag != null) {
        // 多账号批（2026-10-25）：账号与桌面归属不同——给「换账号重连」
        // 动作（登录电脑端所用账号后自动改绑重试），不再死路。
        final notOwned = app.lastRelayFailReason == 'device-not-owned';
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AppLoading(diag.title),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: Text(
                diag.hint,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppType.uiCaption,
                  color: context.colors.foregroundSubtle,
                  height: 1.5,
                ),
              ),
            ),
            if (notOwned) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: const ValueKey('switch-account-retry'),
                onPressed: () async {
                  final result = await Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const LoginPage()));
                  if (!context.mounted) return;
                  if (result is Map && result['jwt'] is String) {
                    await AppStateScope.of(context)
                        .retryActiveProfileWithNewAccount();
                  }
                },
                icon: const Icon(Icons.swap_horiz, size: 18),
                label: const Text('换账号重连'),
              ),
            ],
          ],
        );
      }
      // 性能（2026-10-27 用户⑨）：非在线但有上次内容时保留首页，
      // 明确标注恢复中，而不是整屏等待；失效/被踢终态不放开。
      if (query.trim().isEmpty &&
          app.phase != LinkPhase.invalid &&
          app.phase != LinkPhase.kicked &&
          _hasHomeData(app)) {
        return Column(
          children: [
            _HomeStaleStrip(app),
            Expanded(
              child: _TaskHomeView(
                now: homeNow,
                stale: true,
                compact: compact,
                selectedSessionId: selectedSessionId,
                showNewTaskNav: showNewTaskNav,
                onNew: onNew,
                multiSelectMode: multiSelectMode,
                selectedTaskIds: selectedTaskIds,
                onToggleTaskSelected: onToggleTaskSelected,
                onEnterMultiSelect: onEnterMultiSelect,
                mode: homeMode,
                onModeChanged: onModeChanged,
                groupVisibleCounts: groupVisibleCounts,
                fullyExpandedGroups: fullyExpandedGroups,
                onProgressChanged: onProgressChanged,
                onLongPress: onCrossLongPress,
                onOpen: (task) {
                  if (app.conversation == null) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('正在重连，稍后打开')));
                    return;
                  }
                  (onOpenCross ?? (_) {})(task);
                },
              ),
            ),
          ],
        );
      }
      return AppLoading(app.phase == LinkPhase.offline ? '未连接电脑' : '连接中…');
    }
    // B 方案：空查询=全部任务主页；搜索时仍走既有当前/跨工作区结果。
    if (query.trim().isEmpty) {
      // 同构包装（strip 槽=SizedBox.shrink，与 hold/恢复分支同树形）。
      return Column(
        children: [
          const SizedBox.shrink(),
          Expanded(
            child: _TaskHomeView(
              onOpen: onOpenCross ?? (_) {},
              now: homeNow,
              compact: compact,
              selectedSessionId: selectedSessionId,
              showNewTaskNav: showNewTaskNav,
              onNew: onNew,
              multiSelectMode: multiSelectMode,
              selectedTaskIds: selectedTaskIds,
              onToggleTaskSelected: onToggleTaskSelected,
              onEnterMultiSelect: onEnterMultiSelect,
              mode: homeMode,
              onModeChanged: onModeChanged,
              groupVisibleCounts: groupVisibleCounts,
              fullyExpandedGroups: fullyExpandedGroups,
              onProgressChanged: onProgressChanged,
              onLongPress: onCrossLongPress,
            ),
          ),
        ],
      );
    }
    // 问题③（2026-10-25 用户拍板）：「任务」伪项目=主列表就地内联聚合
    // 视图（原推独立 UnclassifiedTasksPage——点 chip 先弹列表页再选任务
    // 两步进对话，且任务卡副标题是原始目录名：时间戳-uuid 目录显示成
    // 「乱码」、workspace\default 显示「default」）。聚合数据来自
    // tasks-index，与活跃桥解耦——无活跃工作区/桥未就绪照常渲染；点卡
    // 走 onOpenCross（workspace→project→task intent 依次回退，未归类
    // 任务天然落到 task intent 开桥，与原页 _open 等效）。
    if (app.activeWorkspace == null) {
      if (app.projects.isNotEmpty) {
        return const AppEmptyState(
          icon: Icons.folder_outlined,
          text: '选择一个项目开始',
        );
      }
      if (app.workspaces.isEmpty) {
        return AppEmptyState(
          icon: Icons.dns_outlined,
          text: '桌面端没有打开的工作区\n在电脑上用 ZCode 打开一个项目文件夹',
        );
      }
      return AppEmptyState(icon: Icons.folder_outlined, text: '选择一个工作区开始');
    }
    // 病⑤终修（真机两次实录）：快照/任务列表只 notify
    // si state 与 TaskListModel——此前的转圈分支不监听它们，数据到达后
    // 界面停在转圈，直到下一个 AppState 级通知（切工作区/发消息）才
    // 强制重绘。判定体包进 merge 监听，数据一到立即刷新。
    // 阶段 3 收紧：model 存在时它已内部监听 si（TaskListModel 构造即
    // addListener），merge 里再放 si 是冗余——且 si 换代窗口会把已
    // dispose 状态塞进 merge（E2E 实锤）。si 单独进 merge 仅在 model
    // 尚未建立（转圈期）时需要。
    final model = app.taskList;
    return ListenableBuilder(
      listenable: Listenable.merge([
        if (model != null) model else if (index != null) index,
      ]),
      builder: (context, _) => _buildTaskBody(context, app, index),
    );
  }

  Widget _buildTaskBody(
    BuildContext context,
    AppState app,
    SessionsIndexState? index,
  ) {
    final model = app.taskList;
    // 病②UI根因：休眠（dormant）模式下 si 永不 ready（这正是休眠定义）
    // ——后端已降级成功+任务索引已加载，界面却永远转圈"正在连接工作区"。
    if (index == null || (!index.ready && !app.siDormant) || model == null) {
      final error = app.workspaceError;
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (error == null)
              const CircularProgressIndicator(strokeWidth: 2)
            else
              Icon(
                Icons.cloud_off_outlined,
                size: 40,
                color: context.colors.foregroundSubtlest,
              ),
            const SizedBox(height: 12),
            Text(
              error ?? '正在连接工作区…',
              style: TextStyle(
                color: error == null
                    ? context.colors.foregroundSubtle
                    : context.colors.destructive,
                fontSize: AppType.uiCaption,
              ),
              textAlign: TextAlign.center,
            ),
            if (error == null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '首次切换到该工作区需要唤醒，可能要等一会',
                  style: TextStyle(
                    color: context.colors.foregroundSubtlest,
                    fontSize: AppType.uiXs,
                  ),
                ),
              ),
            if (error != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                // （2026-10-26 断线批）：重放原打开意图（含 project/task
                // intent）——失败切换残留的 activeWorkspace 是占位键，
                // 裸 switchWorkspace 会被桌面"目标工作区不在当前窗口"再拒。
                onPressed: app.retryWorkspaceOpen,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
              ),
            ],
          ],
        ),
      );
    }
    // （2026-10-19 审查）监听收窄：外层 ListenableBuilder(merge) 已监听
    // model——原内层 AnimatedBuilder(model) 同源二重监听，每通知双份重建
    // 包整个列表。此处不再包监听；列表改 builder 化（滚出视口的卡不构建
    // ——原 children: 全量构建，250 卡积压场景是桌面冻结链同源风险）。
    final q = query.trim().toLowerCase();
    // + 双源：本地 workspace-list 标题命中（即时）+ 官方
    // listTaskList 全文命中（标题+对话正文，带片段）。纯函数单测见
    // test/segment3_features_test.dart。
    final activeKey = workspaceKeyOf(app.activeWorkspace ?? const {});
    final activeIds = model.cards.map((c) => c.sessionId).toSet();
    final crossLocal = q.isEmpty
        ? const <Map<String, dynamic>>[]
        : filterCrossWorkspaceTasks(
            workspaceTasks: app.workspaceTasks,
            activeKey: activeKey,
            activeIds: activeIds,
            query: q,
          );
    final serverSplit = (q.isEmpty || serverHits == null)
        ? (
            currentIds: const <String>{},
            crossHits: const <Map<String, dynamic>>[],
          )
        : splitSearchHitsByWorkspace(hits: serverHits!, activeKey: activeKey);
    final crossTasks = q.isEmpty
        ? const <Map<String, dynamic>>[]
        // 本地命中剔 archived/deleted（filterCross
        // WorkspaceTasks 口径），服务器全文命中此前不过滤——同一归档任务
        // 随服务器往返“闪烁”，两路口径统一为剔除。
        : [
            for (final t in mergeCrossSearchHits(
              serverHits: serverSplit.crossHits,
              localHits: crossLocal,
            ))
              if (t['archived'] != true && t['deleted'] != true) t,
          ];
    // 全文命中的正文片段表（taskId → 首个片段），卡片预览位优先展示。
    final snippetByTaskId = <String, String>{};
    for (final h in serverHits ?? const <Map<String, dynamic>>[]) {
      final id = '${h['taskId'] ?? ''}';
      final s = firstSearchSnippet(h);
      if (id.isNotEmpty && s != null) snippetByTaskId[id] = s;
    }
    // 空库早退只限空查询——搜索态（q 非空）
    // 走下方零结果/搜索状态行分支，否则“没有匹配”文案与 searching/failed
    // 状态行被这里吞掉；文案按宽窄分档（宽屏无 FAB， 起）。
    if (model.cards.isEmpty && q.isEmpty && crossTasks.isEmpty) {
      if (!model.channelLoaded) {
        return const AppLoading('正在同步任务索引…');
      }
      return AppEmptyState(
        icon: Icons.chat_bubble_outline,
        text: compact ? '暂无任务\n点下方「新建任务」开始对话' : '暂无任务\n点右下角「新建」开始对话',
      );
    }
    // 空搜索走模型缓存分区（每通知重算一次，原来每次 build 过滤+复制
    // 三份）；带搜索时对过滤子集就地分区（键入路径，量小）。
    final List<TaskCardData> pinned;
    final List<TaskCardData> running;
    final List<TaskCardData> rest;
    if (q.isEmpty) {
      pinned = model.pinned;
      running = model.running;
      rest = model.rest;
    } else {
      final visible = model.cards
          .where(
            (c) =>
                c.title.toLowerCase().contains(q) ||
                (c.preview ?? '').toLowerCase().contains(q) ||
                // 正文命中（标题/预览没命中）的当前工作区卡也提为可见。
                serverSplit.currentIds.contains(c.sessionId),
          )
          .toList();
      pinned = visible.where((c) => c.pinned).toList();
      running = visible
          .where((c) => !c.pinned && isRunningPhase(c.phase))
          .toList();
      rest = visible
          .where((c) => !c.pinned && !isRunningPhase(c.phase))
          .toList();
    }
    if (q.isNotEmpty &&
        searchFetch != _SearchFetchState.searching &&
        pinned.isEmpty &&
        running.isEmpty &&
        rest.isEmpty &&
        crossTasks.isEmpty) {
      // 零结果也必须让降级可见（此前早退把 failed 状态行一并吞掉）。
      return AppEmptyState(
        icon: Icons.search_off,
        text: searchFetch == _SearchFetchState.failed
            ? '对话内容搜索暂不可用，已按标题/预览匹配\n没有匹配「$query」的任务'
            : '没有匹配「$query」的任务，换个关键词试试',
      );
    }
    // 行描述表（轻量）+ builder 惰性构建。统一 1min ticker 只为刷新
    // 可见卡的相对时间标签（替代原"每卡每帧 DateTime.now"的隐式刷新，
    // 静默期标签也能走「刚刚→N 分钟前」）。
    const kDormant = 0,
        kHeader = 1,
        kTask = 2,
        kCross = 3,
        kArchived = 4,
        kSearchStatus = 5,
        kSummary = 6;
    final rows = <(int, Object?)>[
      // V1 审美优化：状态摘要条——审批等待数是 agent 首页最有价值的
      // 数字（此前完全不可见，评审 2.1#1）。静态信息条；点击跳转筛选
      // 按需再做。仅空搜索态显示（搜索结果自身即反馈）。
      if (q.isEmpty && model.cards.isNotEmpty)
        (
          kSummary,
          (
            running: running.length,
            waiting: model.cards
                .where(
                  (c) => c.pendingInteraction != null || c.phase == 'waiting',
                )
                .length,
            total: rest.length,
          ),
        ),
      // 全文搜索状态行（searching/failed 才占行；done 时结果本身即反馈）。
      if (q.isNotEmpty &&
          (searchFetch == _SearchFetchState.searching ||
              searchFetch == _SearchFetchState.failed))
        (kSearchStatus, searchFetch),
      if (app.siDormant) (kDormant, null),
      if (pinned.isNotEmpty) ...[
        (kHeader, '置顶 (${pinned.length})'),
        for (final s in pinned) (kTask, s),
      ],
      if (running.isNotEmpty) ...[
        (kHeader, '运行中 (${running.length})'),
        for (final s in running) (kTask, s),
      ],
      if (rest.isNotEmpty) ...[
        (kHeader, '全部 (${rest.length})'),
        for (final s in rest) (kTask, s),
      ],
      if (crossTasks.isNotEmpty && onOpenCross != null) ...[
        (kHeader, '其他工作区 (${crossTasks.length})'),
        for (final t in crossTasks) (kCross, t),
      ],
      if (app.archivedTasks.isNotEmpty) (kArchived, app.archivedTasks.length),
    ];
    return RefreshIndicator(
      onRefresh: app.refreshWorkspaces,
      child: _MinuteTicker(
        builder: (context) => ListView.builder(
          key: const ValueKey('task-list'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final (kind, data) = rows[i];
            if (kind == kSummary) {
              final s = data! as ({int running, int waiting, int total});
              return _SummaryStrip(
                running: s.running,
                waiting: s.waiting,
                total: s.total,
              );
            }
            if (kind == kTask) {
              final entry = data! as TaskCardData;
              if (compact) {
                return _CompactTaskRow.fromEntry(
                  entry: entry,
                  selectedSessionId: selectedSessionId,
                  onTap: onOpen,
                  // 宽屏搜索行补长按菜单。
                  onLongPress: (e) => _showTaskActions(
                    context,
                    e,
                    onEnterMultiSelect: onEnterMultiSelect,
                  ),
                  multiSelectMode: multiSelectMode,
                  multiSelected: selectedTaskIds.contains(entry.sessionId),
                  onToggleSelect: onToggleTaskSelected == null
                      ? null
                      : () => onToggleTaskSelected!(entry.sessionId, null),
                );
              }
              return _TaskCard(
                entry: entry,
                onOpen: onOpen,
                contentSnippet: snippetByTaskId[entry.sessionId],
                multiSelectMode: multiSelectMode,
                multiSelected: selectedTaskIds.contains(entry.sessionId),
                onToggleSelect: onToggleTaskSelected == null
                    ? null
                    : () => onToggleTaskSelected!(entry.sessionId, null),
                onEnterMultiSelect: onEnterMultiSelect,
              );
            }
            return switch (kind) {
              kDormant => _dormantBanner(context),
              kHeader => AppSectionHeader(data! as String),
              kSearchStatus => Padding(
                padding: const EdgeInsets.fromLTRB(4, 6, 4, 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (data! == _SearchFetchState.searching)
                      SizedBox(
                        width: 10,
                        height: 10,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: context.colors.foregroundSubtlest,
                        ),
                      )
                    else
                      Icon(
                        Icons.cloud_off_outlined,
                        size: 12,
                        color: context.colors.foregroundSubtlest,
                      ),
                    const SizedBox(width: 6),
                    Text(
                      data == _SearchFetchState.searching
                          ? '正在搜索对话内容…'
                          : '对话内容搜索暂不可用，已按标题/预览匹配',
                      style: TextStyle(
                        fontSize: AppType.uiXs,
                        color: context.colors.foregroundSubtlest,
                      ),
                    ),
                  ],
                ),
              ),
              kCross => () {
                final cross = data! as Map<String, dynamic>;
                final crossId = '${cross['taskId']}';
                return compact
                    ? _CompactTaskRow.fromCross(
                        task: cross,
                        selectedSessionId: selectedSessionId,
                        onTap: onOpenCross!,
                        // 跨区搜索行接长按菜单
                        // （与同视图当前区行同权——置顶/归档/删除/多选）。
                        onLongPress: onCrossLongPress,
                        multiSelectMode: multiSelectMode,
                        multiSelected: selectedTaskIds.contains(crossId),
                        onToggleSelect: onToggleTaskSelected == null
                            ? null
                            : () => onToggleTaskSelected!(
                                  crossId,
                                  taskWorkspaceKey(cross),
                                ),
                      )
                    : _CrossTaskCard(
                        task: cross,
                        onOpen: onOpenCross!,
                        onLongPress: onCrossLongPress,
                        multiSelectMode: multiSelectMode,
                        multiSelected: selectedTaskIds.contains(crossId),
                        onToggleSelect: onToggleTaskSelected,
                      );
              }(),
              _ => Padding(
                key: const ValueKey('open-archived-tasks'),
                padding: const EdgeInsets.only(top: 4, bottom: 8),
                child: Center(
                  child: TextButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const ArchivedTasksPage(),
                      ),
                    ),
                    icon: const Icon(Icons.archive_outlined, size: 16),
                    label: Text('已归档的任务 (${data as int})'),
                  ),
                ),
              ),
            };
          },
        ),
      ),
    );
  }

  /// 冷工作区降级提示（官方 dormant 语义）：历史任务照常，
  /// 点开会话自动唤醒运行时。
  Widget _dormantBanner(BuildContext context) {
    return Container(
      key: const ValueKey('si-dormant-banner'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: context.colors.warning.withValues(alpha: AppAlpha.light),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(
          color: context.colors.warning.withValues(alpha: AppAlpha.mid),
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.bedtime_outlined, size: 15, color: context.colors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '该工作区暂无活跃进程——显示历史任务，点开会话时将自动唤醒',
              style: TextStyle(
                fontSize: AppType.uiCaption,
                color: context.colors.foregroundSubtle,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 每分钟一次重建 builder 内容（可见卡相对时间标签刷新）——一个
/// ticker 服务整页可见卡，替代原每卡每帧 DateTime.now() 的散布取时。
class _MinuteTicker extends StatefulWidget {
  final WidgetBuilder builder;
  const _MinuteTicker({required this.builder});

  @override
  State<_MinuteTicker> createState() => _MinuteTickerState();
}

class _MinuteTickerState extends State<_MinuteTicker> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      // 仅前台且本路由可见时刷新（segment3 E2E 实锤回归修复）：路由被
      // 覆盖（如会话页在上）或 app 退后台时跳过 setState——周期性帧
      // 调度会让 pumpAndSettle 永不 settle，后台 tick 也是纯耗电。
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}

/// 官方全文搜索（listTaskList）拉取状态：searching/failed 在搜索行下方
/// 占一行状态提示；done 的反馈即结果本身，idle 无提示。
enum _SearchFetchState { idle, searching, done, failed }

/// 任务搜索行（波次 3a）：本地标题/预览即时过滤 + 官方 listTaskList
/// 全文搜索（标题+对话正文）——历史会话全量显示后的检索入口。
class _SearchRow extends StatelessWidget {
  final bool open;
  final String query;
  final ValueChanged<String> onChanged;
  final VoidCallback onClosed;

  const _SearchRow({
    required this.open,
    required this.query,
    required this.onChanged,
    required this.onClosed,
  });

  @override
  Widget build(BuildContext context) {
    if (!open) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: TextField(
        key: const ValueKey('task-search'),
        autofocus: true,
        onChanged: onChanged,
        decoration: InputDecoration(
          isDense: true,
          hintText: tr('搜索标题 / 预览 / 对话内容'),
          prefixIcon: const Icon(Icons.search, size: 18),
          suffixIcon: IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: onClosed,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 8,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.glassChrome),
            borderSide: BorderSide(color: context.colors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.glassChrome),
            borderSide: BorderSide(color: context.colors.border),
          ),
        ),
        style: const TextStyle(fontSize: AppType.uiCaption),
      ),
    );
  }
}

/// 任务卡：白卡 + 状态徽章胶囊 + 最新预览一行（组件基线）。
/// 长按任务菜单（波次 3a 任务管理）：置顶/归档/删除——桌面同款三件套。
/// 移动归属：项目选择 sheet → moveTask（官方 project.moveTask，
/// ）。任务目录不在目标项目 roots 时服务端抛
/// `project.root-confirmation-required`——弹官方同款"加入目录并移动"
/// 确认（ProjectSidebarNode.tsx:157-172），确认后带 addMissingRoot 重发。
Future<void> showMoveToProjectSheet(
  BuildContext context,
  TaskCardData entry,
) async {
  final app = AppStateScope.of(context);
  void snack(String t) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(t), duration: const Duration(seconds: 3)),
  );
  // TaskCardData 不带目录/归属字段——从 readTree 任务行按 taskId 反查。
  final row = app.projectTasks
      .where((t) => '${t['taskId'] ?? ''}' == entry.sessionId)
      .firstOrNull;
  if (row == null) {
    snack('任务归属数据未就绪，稍后再试');
    return;
  }
  final currentPid = '${row['projectId'] ?? ''}';
  // 同 host 才可移动（官方跨 host 拒绝）；本地项目 hostId 空=local。
  final hostId = '${row['hostId'] ?? 'local'}';
  final candidates = [
    for (final p in app.sidebarProjects)
      if ('${p['id'] ?? ''}' != conversationsPseudoProjectId &&
          '${p['hostId'] ?? 'local'}' == hostId)
        p,
  ];
  if (candidates.isEmpty) {
    snack('没有可移动到的项目');
    return;
  }
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
        ),
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  '移动「${entry.title.isEmpty ? '(未命名任务)' : entry.title}」到项目',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: AppType.uiCaption,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final p in candidates)
                ListTile(
                  key: ValueKey('move-target-${p['id']}'),
                  leading: const Icon(Icons.folder_outlined, size: 20),
                  title: Text('${p['name'] ?? p['id']}', translate: false),
                  trailing: '${p['id']}' == currentPid
                      ? const Text('当前')
                      : null,
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    _moveTaskTo(context, row, p);
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _moveTaskTo(
  BuildContext context,
  Map<String, dynamic> row,
  Map<String, dynamic> project,
) async {
  final app = AppStateScope.of(context);
  // 成功/失败提示在 RPC（最长 15s）之后——宿主视图
  // 可能已卸载，mounted 守卫防 defunct context。
  void snack(String t) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t), duration: const Duration(seconds: 3)),
    );
  }

  final pid = '${project['id']}';
  final name = '${project['name'] ?? pid}';
  Future<void> attempt({bool addMissingRoot = false}) =>
      app.moveTask(row, pid, addMissingRoot: addMissingRoot);
  try {
    await attempt();
    snack('已移动到 $name');
  } catch (e) {
    if (context.mounted && '$e'.contains('root-confirmation-required')) {
      // 官方二段确认：任务目录不在项目 roots——把目录加入项目并移动。
      final ok = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('加入目录并移动？'),
          content: Text(
            '该任务的目录不在项目「$name」的文件夹列表里。\n'
            '「${row['workspacePath'] ?? ''}」将被加入该项目，然后移动任务。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('加入并移动'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      try {
        await attempt(addMissingRoot: true);
        if (context.mounted) snack('已移动到 $name');
      } catch (e2) {
        if (context.mounted) snack('移动失败：$e2');
      }
    } else if (context.mounted) {
      snack('移动失败：$e');
    }
  }
}

void _showTaskActions(
  BuildContext context,
  TaskCardData entry, {

  /// 批量操作（优化批 #22）：非空时首项显示「选择任务」——选中当前
  /// 任务并进入多选模式（归档/标已读/删除批量执行）。
  void Function(String taskId)? onEnterMultiSelect,

  /// 验收#10（Bug E）：动作执行前的归属护栏（跨项目任务 RPC
  /// 带所属工作区 scope）；弹菜单本身不再触发（零副作用）。
  Future<void> Function()? ensureContext,
}) {
  final app = AppStateScope.of(context);
  // 弹层动作在飞最长 15s，期间宿主视图可能被卸载
  // （搜索打开/分支切换）——snack 前查 context.mounted，失效时静默丢弃
  // （归档页 _run 的 messenger 预捕获同款防线，这里以 mounted 收口）。
  void snack(String text) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 3)),
    );
  }

  Future<void> run(Future<dynamic> Function() op, String failPrefix) async {
    try {
      if (ensureContext != null) await ensureContext();
      await op();
    } catch (e) {
      snack('$failPrefix: $e');
    }
  }

  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    // 批次1 顺手：7 项菜单可滚动（字体放大时底部选项不可达——技能面板
    // 同款范式 isScrollControlled+限高+滚动容器）。
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
        ),
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  entry.title.isEmpty ? '(未命名任务)' : entry.title,
                  // 用户任务标题不得过词典
                  // （短 CJK 标题如「设置」会被整键误译）；与同文件其余
                  // 三处标题渲染同款守卫，仅空标题占位词走翻译。
                  translate: entry.title.isEmpty,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: AppType.uiCaption,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (onEnterMultiSelect != null)
                ListTile(
                  key: const ValueKey('task-action-select-tasks'),
                  leading: const Icon(Icons.checklist, size: 20),
                  title: const Text('选择任务'),
                  subtitle: const Text(
                    '多选任务批量归档/标已读/删除',
                    style: TextStyle(fontSize: AppType.uiXs),
                  ),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    onEnterMultiSelect(entry.sessionId);
                  },
                ),
              ListTile(
                leading: Icon(
                  entry.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                  size: 20,
                ),
                title: Text(entry.pinned ? '取消置顶' : '置顶'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  run(
                    () => app.setTaskPinned(entry.sessionId, !entry.pinned),
                    '置顶操作失败',
                  );
                },
              ),
              // （WR 对齐）：桌面 TaskActionMenu 同款三项。
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline, size: 20),
                title: const Text('重命名'),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  final controller = TextEditingController(text: entry.title);
                  final title = await showDialog<String>(
                    context: context,
                    builder: (dialogContext) => AlertDialog(
                      title: const Text('重命名任务'),
                      content: TextField(
                        controller: controller,
                        autofocus: true,
                        style: const TextStyle(
                          fontSize: AppType.mobileInputSafe,
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(
                            dialogContext,
                            controller.text.trim(),
                          ),
                          child: const Text('保存'),
                        ),
                      ],
                    ),
                  );
                  // 延后释放：showDialog 的 future 在 pop 瞬间完成，退场
                  // 动画期 dialog 树仍存活——立即 dispose 会被动画期编辑
                  // 事件触碰（profiles_sheet.dart 同款范式）。
                  Future<void>.delayed(
                    const Duration(milliseconds: 400),
                    controller.dispose,
                  );
                  if (title != null && title.isNotEmpty) {
                    run(() => app.renameTask(entry.sessionId, title), '重命名失败');
                  } else if (title != null) {
                    // 空保存与取消可区分（此前静默无反馈）。
                    snack('标题不能为空');
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.mark_email_unread_outlined, size: 20),
                title: const Text('标为未读'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  run(
                    () => app.markTaskUnread(entry.sessionId, unread: true),
                    '操作失败',
                  );
                },
              ),
              // 移动归属（用户 2026-10-24 立项拍板）：
              // 归属只在创建时写，旧任务/改主意的任务靠官方 moveTask 归位。
              ListTile(
                leading: const Icon(Icons.drive_file_move_outlined, size: 20),
                title: const Text('移动到项目…'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  showMoveToProjectSheet(context, entry);
                },
              ),
              ListTile(
                leading: const Icon(Icons.copy_outlined, size: 20),
                title: const Text('复制会话 ID'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  Clipboard.setData(ClipboardData(text: entry.sessionId));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('会话 ID 已复制'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.archive_outlined, size: 20),
                title: const Text('归档'),
                subtitle: const Text(
                  '从列表移入归档，可通过撤销恢复',
                  style: TextStyle(fontSize: AppType.uiXs),
                ),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  // 成功提示与撤销入口等 RPC 真成功后再给——
                  // 旧实现先弹"已归档"，失败时两条信息自相矛盾。
                  // 归档与同菜单其余动作同走 run（先
                  // ensureContext 归属护栏）——跨工作区任务直发
                  // archiveTask 会把当前工作区 scope 打偏。
                  run(() async {
                    await app.archiveTask(entry.sessionId);
                    if (!context.mounted) return;
                    // 验收（用户两轮反馈不消失）：duration 显式 3s——旧的
                    // 6s hideCurrentSnackBar 兜底会误关后续提示条，已移除。
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        behavior: SnackBarBehavior.floating,
                        content: Text(
                          '已归档「${entry.title.isEmpty ? '未命名任务' : entry.title}」',
                        ),
                        duration: const Duration(milliseconds: 3000),
                        action: SnackBarAction(
                          label: '撤销',
                          onPressed: () => run(
                            () => app.unarchiveTask(entry.sessionId),
                            '撤销失败',
                          ),
                        ),
                      ),
                    );
                  }, '归档失败');
                },
              ),
              ListTile(
                leading: Icon(
                  Icons.delete_outline,
                  size: 20,
                  color: context.colors.destructive,
                ),
                title: Text(
                  '删除任务',
                  style: TextStyle(color: context.colors.destructive),
                ),
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  final ok = await showConfirmDialog(
                    context,
                    title: '删除这个任务？',
                    message:
                        '「${entry.title.isEmpty ? '未命名任务' : entry.title}」将被永久删除，不可恢复。',
                  );
                  if (ok) {
                    await run(() => app.deleteTask(entry.sessionId), '删除失败');
                  }
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 跨工作区搜索结果行：workspace-list 任务条目（非活跃工作区）——
/// 标题 + 工作区标签 + 状态 pill；点按=切工作区后打开。
class _CrossTaskCard extends StatelessWidget {
  final Map<String, dynamic> task;
  final void Function(Map<String, dynamic> task) onOpen;

  /// 是否显示目录名副标题行（问题③ 2026-10-25：「任务」内联视图关——
  /// 原始目录名（时间戳-uuid/default）是用户实锤的乱码噪音；搜索结果
  /// 视图保留（区分来源工作区有用）。
  final bool showWorkspaceLabel;

  /// 游览钉时钟（仅主页传入；搜索/其他调用方=null 保持实时）。
  final DateTime? now;

  /// 首页长按任务菜单（恢复重命名/置顶/归档等；搜索卡仍只点按）。
  final void Function(Map<String, dynamic> task)? onLongPress;

  // ---- 批量操作（优化批 #22）：多选态下点按=切换选中，不再打开 ----
  final bool multiSelectMode;
  final bool multiSelected;

  /// 行级工作区键随选择集上报（批量操作按行归属执行）。
  final void Function(String taskId, String? workspaceKey)? onToggleSelect;

  const _CrossTaskCard({
    required this.task,
    required this.onOpen,
    this.showWorkspaceLabel = true,
    this.now,
    this.onLongPress,
    this.multiSelectMode = false,
    this.multiSelected = false,
    this.onToggleSelect,
  });

  @override
  Widget build(BuildContext context) {
    final title = '${task['title'] ?? ''}'.trim();
    final label = _workspaceLabel();
    // displayStatus 来自 controller/tasks-index 行映射（liveStatus，词表
    // idle/running/waiting/completed/error）；兜底 status
    // （zcodeTask 词表）。
    final status = normalizePhase(
      '${task['displayStatus'] ?? task['status'] ?? ''}',
    );
    // 批次4（2026-10-19 审查）：徽标视觉收敛单源（原独立 switch 的
    // 词表漂移——completedInterrupted 在此为"出错"红色、主列表为
    // "已停止"橙色，"已完成/完成"标签不一——统一到 status_badge.dart）。
    final b = taskPhaseBadge(context.colors, status);
    final (color, surface, statusLabel) = (b.color, b.surface, b.label);
    final updatedAt = (task['updatedAt'] as num?)?.toInt() ?? 0;
    // 官方全文命中的正文片段（searchSnippet/searchSnippets）。
    final snippet = firstSearchSnippet(task);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.colors.borderFaint),
        boxShadow: context.shadows.xs,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('cross-task-card-${task['taskId']}'),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: multiSelectMode
              ? (onToggleSelect == null
                    ? null
                    : () => onToggleSelect!(
                          '${task['taskId']}',
                          taskWorkspaceKey(task),
                        ))
              : () => onOpen(task),
          onLongPress: onLongPress == null ? null : () => onLongPress!(task),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 批量操作（优化批 #22）：多选态行首勾选圈。
                    if (multiSelectMode) ...[
                      Icon(
                        multiSelected
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        size: 20,
                        color: multiSelected
                            ? context.colors.brandAccent
                            : context.colors.foregroundSubtlest,
                      ),
                      const SizedBox(width: 8),
                    ],
                    // 未读蓝点（官方行未读标记对位；
                    // home 行由 card.unread 映射 unreadAt，跨工作区/搜索行
                    // 同判 unread 字段）。
                    if (task['unreadAt'] != null || task['unread'] == true)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            // 未读=智谱蓝点睛（brand 是黑白单色 token——
                            // 深色下纯白被用户看成"白点"， 验收②）。
                            color: context.colors.brandAccent,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    // B 批（2026-11-08 拍板⑤）：闲时月亮（home 窄卡）。
                    if (task['offPeakTaskId'] is String &&
                        (task['offPeakTaskId'] as String).isNotEmpty) ...[
                      Icon(
                        Icons.bedtime_outlined,
                        size: 12,
                        color: context.colors.foregroundSubtlest,
                      ),
                      const SizedBox(width: 4),
                    ],
                    // B 批（拍板①）：后台工作小点（非运行态才有，运行态
                    // 状态行自带 spinner）。
                    if (task['hasBackgroundWork'] == true &&
                        normalizePhase('${task['displayStatus'] ?? task['status'] ?? ''}') != 'running')
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: context.colors.running,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        title.isEmpty ? '(未命名任务)' : title,
                        translate: title.isEmpty,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: AppType.uiBase,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: surface,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 状态图标化（2026-10-27 视觉优化）：运行中细旋转，
                          // 完成/等待/失败/空闲用形状区分，不再一律实心圆点。
                          taskPhaseIcon(status, color),
                          const SizedBox(width: 5),
                          Text(
                            statusLabel,
                            style: TextStyle(
                              fontSize: AppType.uiSm,
                              color: color,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                // A 批（拍板⑧）：工作流运行行（home 窄卡）。
                // 候选 15 验收 ：未读可见/已读隐藏（同窄卡门）。
                if (_cardRuns(task).isNotEmpty &&
                    (task['unreadAt'] != null || task['unread'] == true))
                  WorkflowRunLines(runs: _cardRuns(task)),
                if (snippet != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.manage_search,
                        size: 13,
                        color: context.colors.foregroundSubtlest,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          snippet,
                          translate: false,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppType.uiCaption,
                            color: context.colors.foregroundSubtle,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (showWorkspaceLabel) ...[
                      Icon(
                        Icons.folder_outlined,
                        size: 12,
                        color: context.colors.foregroundSubtlest,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          label,
                          translate: false,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppType.uiXs,
                            color: context.colors.foregroundSubtlest,
                          ),
                        ),
                      ),
                    ],
                    if (updatedAt > 0) ...[
                      if (showWorkspaceLabel) const SizedBox(width: 8),
                      Text(
                        _relativeTime(updatedAt, now: now),
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.foregroundSubtlest,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _workspaceLabel() {
    // 与任务主页分组标签收敛单源（此前 identity 优先
    // 与否等细节漂移）。
    return taskRowWorkspaceLabel(task);
  }
}

/// 状态摘要条（V1 审美优化 2026-10-22）：运行中/待处理/全部计数一行
/// 可见——运行中=琥珀（对齐官方运行态色）、待处理>0 用审批蓝强调、
/// 全部=最弱灰。与任务卡同款卡材质（borderFaint+context.shadows.xs）。
class _SummaryStrip extends StatelessWidget {
  final int running;
  final int waiting;
  final int total;

  const _SummaryStrip({
    required this.running,
    required this.waiting,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    Widget seg(String label, int n, Color color) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 计数图标：运行中才旋转；空闲/无活动仅保留静态形状。
        running > 0
            ? taskPhaseIcon('running', color)
            : taskPhaseIcon('idle', color),
        const SizedBox(width: 5),
        Text(
          '$n $label',
          style: TextStyle(
            fontSize: AppType.uiSm,
            color: context.colors.foregroundSubtle,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.colors.borderFaint),
        boxShadow: context.shadows.xs,
      ),
      child: Wrap(
        // 多机型批（阶段 6.1）：Row→Wrap——三段计数在 320dp+
        // 1.3 倍字号下超宽（实测右溢 37px），Wrap 窄屏自动换到次行；
        // 常规宽度单行容纳观感不变（w320s13 游览档钉死不溢出）。
        // crossAxisAlignment=center：对齐原 Row 的垂直居中（默认 start
        // 会挪动脉冲点/文本纵向位置→基线哈希差）。
        spacing: 14,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          seg('运行中', running, context.colors.running),
          seg(
            '待处理',
            waiting,
            waiting > 0
                ? context.colors.interactionAskForeground
                : context.colors.foregroundSubtlest,
          ),
          seg('全部', total, context.colors.foregroundSubtlest),
        ],
      ),
    );
  }
}

/// 双栏左栏紧凑任务行（fold-dual-pane-2，用户 2026-10-29 反馈「任务仅需
/// 一个小标题」）：对标官方桌面侧栏——单行「图标槽+标题+相对时间」，
/// 无卡片无状态徽标；状态压进图标槽（运行=spinner、未读=蓝点、其余
/// 留白），选中=整行低饱和填充（官方唯一信号，文字不变色）。
class _CompactTaskRow extends StatelessWidget {
  const _CompactTaskRow({
    required this.taskId,
    required this.title,
    required this.running,
    required this.unread,
    required this.updatedAt,
    this.offPeakTaskId,
    this.workflowRuns = const [],
    this.selectedSessionId,
    this.now,
    this.onTap,
    this.onLongPress,
    this.multiSelectMode = false,
    this.multiSelected = false,
    this.onToggleSelect,
  });

  final String taskId;
  final String title;
  final bool running;
  final bool unread;
  final int updatedAt;

  /// B 批：闲时任务月亮标（官方对位）。
  final String? offPeakTaskId;

  /// 工作流运行行（官方 compact 同款第二行）。
  final List<Map<String, dynamic>> workflowRuns;
  final String? selectedSessionId;

  /// 游览钉时钟（仅主页传入；搜索/其他调用方=null 保持实时）。
  final DateTime? now;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  // ---- 批量操作（优化批 #22）：多选态图标槽换成勾选圈，点按=切换 ----
  final bool multiSelectMode;
  final bool multiSelected;
  final VoidCallback? onToggleSelect;

  /// 跨工作区/主页行（workspaceTasks 与 taskHomeCardRow 同构）。
  factory _CompactTaskRow.fromCross({
    required Map<String, dynamic> task,
    String? selectedSessionId,
    DateTime? now,
    void Function(Map<String, dynamic> task)? onTap,
    void Function(Map<String, dynamic> task)? onLongPress,
    bool multiSelectMode = false,
    bool multiSelected = false,
    VoidCallback? onToggleSelect,
  }) => _CompactTaskRow(
    taskId: '${task['taskId'] ?? ''}',
    title: '${task['title'] ?? ''}'.trim(),
    running:
        normalizePhase('${task['displayStatus'] ?? task['status'] ?? ''}') ==
        'running',
    unread: task['unreadAt'] != null || task['unread'] == true,
    offPeakTaskId: task['offPeakTaskId'] is String
        ? task['offPeakTaskId'] as String
        : null,
    workflowRuns: _cardRuns(task),
    updatedAt: (task['updatedAt'] as num?)?.toInt() ?? 0,
    selectedSessionId: selectedSessionId,
    now: now,
    onTap: onTap == null ? null : () => onTap(task),
    onLongPress: onLongPress == null ? null : () => onLongPress(task),
    multiSelectMode: multiSelectMode,
    multiSelected: multiSelected,
    onToggleSelect: onToggleSelect,
  );

  /// 当前工作区任务索引行（搜索结果）。
  factory _CompactTaskRow.fromEntry({
    required TaskCardData entry,
    String? selectedSessionId,
    void Function(TaskCardData entry)? onTap,
    // 宽屏搜索行补长按菜单（与主页行/窄屏同
    // 权——置顶/归档/删除/移动此前在该路径不可达）。
    void Function(TaskCardData entry)? onLongPress,
    bool multiSelectMode = false,
    bool multiSelected = false,
    VoidCallback? onToggleSelect,
  }) => _CompactTaskRow(
    taskId: entry.sessionId,
    title: entry.title.trim(),
    running: normalizePhase(entry.phase) == 'running',
    unread: entry.unread,
    updatedAt: entry.lastActivityAt,
    // fromEntry 补 offPeak/runs（宽屏搜索行与主页行同权）。
    offPeakTaskId: entry.offPeakTaskId,
    workflowRuns: entry.workflowRuns,
    selectedSessionId: selectedSessionId,
    onTap: onTap == null ? null : () => onTap(entry),
    onLongPress: onLongPress == null ? null : () => onLongPress(entry),
    multiSelectMode: multiSelectMode,
    multiSelected: multiSelected,
    onToggleSelect: onToggleSelect,
  );

  @override
Widget build(BuildContext context) {
    final selected = selectedSessionId != null && selectedSessionId == taskId;
    final timeLabel = updatedAt > 0 ? _relativeTime(updatedAt, now: now) : null;
    final rowHeight = compactTaskRowHeight(
      workflowRuns.length,
      MediaQuery.textScalerOf(context),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Material(
        key: ValueKey('compact-task-row-$taskId'),
        color: selected ? context.colors.selected : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          // 批量操作（优化批 #22）：多选态点按=切换选中，不再打开。
          onTap: multiSelectMode ? onToggleSelect : onTap,
          onLongPress: onLongPress,
          child: SizedBox(
            height: rowHeight,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 22,
                      height: 48,
                      // 多选态图标槽=勾选圈（批量操作，优化批 #22）。
                      child: multiSelectMode
                          ? Center(
                              child: Icon(
                                multiSelected
                                    ? Icons.check_circle
                                    : Icons.circle_outlined,
                                size: 20,
                                color: multiSelected
                                    ? context.colors.brandAccent
                                    : context.colors.foregroundSubtlest,
                              ),
                            )
                          : running
                          ? Center(
                              child: SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                  color: context.colors.foregroundSubtle,
                                ),
                              ),
                            )
                          : unread
                          ? Center(
                              child: Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  // 未读=智谱蓝点睛（brand 黑白单色， 验收②）。
                                  color: context.colors.brandAccent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            )
                          : null,
                    ),
                    const SizedBox(width: 2),
                    Expanded(
                      child: Text(
                        title.isEmpty ? '(未命名任务)' : title,
                        translate: title.isEmpty,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: AppType.uiBase,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    // （对抗审查·月亮压未读）：月亮归元信息列
                    //（官方 TaskListItem 月亮在时间前 meta 位）。
                    if ((offPeakTaskId ?? '').isNotEmpty) ...[
                      Icon(
                        Icons.bedtime_outlined,
                        size: 13,
                        color: context.colors.foregroundSubtlest,
                      ),
                      const SizedBox(width: 4),
                    ],
                    if (timeLabel != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        timeLabel,
                        style: TextStyle(
                          fontSize: AppType.uiXs,
                          color: context.colors.foregroundSubtle,
                        ),
                      ),
                    ],
                    const SizedBox(width: 6),
                  ],
                ),
                // 紧凑行 run 线（官方 TaskWorkflowRunLines compact 对位）。
                // 候选 15 验收 ：未读可见/已读隐藏。
                if (workflowRuns.isNotEmpty && unread)
                  Padding(
                    padding: const EdgeInsets.only(left: 24),
                    child: WorkflowRunLines(runs: workflowRuns, compact: true),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  final TaskCardData entry;
  final void Function(TaskCardData) onOpen;

  /// ：官方全文命中的正文片段——有值时优先于本地预览展示。
  final String? contentSnippet;

  // ---- 批量操作（优化批 #22）：多选态下点按=切换选中，不再打开 ----
  final bool multiSelectMode;
  final bool multiSelected;
  final VoidCallback? onToggleSelect;

  /// 长按菜单「选择任务」入口（页面级 _enterMultiSelect）。
  final void Function(String taskId)? onEnterMultiSelect;

  const _TaskCard({
    required this.entry,
    required this.onOpen,
    this.contentSnippet,
    this.multiSelectMode = false,
    this.multiSelected = false,
    this.onToggleSelect,
    this.onEnterMultiSelect,
  });

  @override
  Widget build(BuildContext context) {
    final (color, surface, label) = _statusOf(context, entry);
    // 方向 B 真机验收裁决（2026-10-24 用户）：两版归属标注均撤——
    // 用户工作流=工作区维度浏览（列表本就是同工作区窗口），主列表上的
    // 项目归属是冗余信息；归属可见性需求不存在（官方语义仲裁结论
    // "目录列表保留已移走任务"即正确形态）。
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: context.colors.card,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: context.colors.borderFaint),
        boxShadow: context.shadows.xs,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          key: ValueKey('task-card-${entry.sessionId}'),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          onTap: multiSelectMode ? onToggleSelect : () => onOpen(entry),
          onLongPress: () => _showTaskActions(
            context,
            entry,
            onEnterMultiSelect: onEnterMultiSelect,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // 批量操作（优化批 #22）：多选态行首勾选圈。
                    if (multiSelectMode) ...[
                      Icon(
                        multiSelected
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        size: 20,
                        color: multiSelected
                            ? context.colors.brandAccent
                            : context.colors.foregroundSubtlest,
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (entry.pinned) ...[
                      Icon(
                        Icons.push_pin,
                        size: 13,
                        color: context.colors.foregroundSubtlest,
                      ),
                      const SizedBox(width: 4),
                    ],
                    if (entry.unread) ...[
                      Container(
                        width: 7,
                        height: 7,
                        decoration: BoxDecoration(
                          // 未读=智谱蓝点睛统一
                          // brandAccent（第三处——窄屏主卡此前用 linkBlue）。
                          color: context.colors.brandAccent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                    ],
                    if ((entry.goalStatus ?? '').isNotEmpty) ...[
                      const Icon(Icons.flag_outlined, size: 11),
                      const SizedBox(width: 4),
                    ],
                    // B 批（2026-11-08 拍板⑤）：闲时任务月亮标（官方
                    // TaskListItem offPeakTaskLabel 对位）。
                    if ((entry.offPeakTaskId ?? '').isNotEmpty) ...[
                      Icon(
                        Icons.bedtime_outlined,
                        size: 12,
                        color: context.colors.foregroundSubtlest,
                      ),
                      const SizedBox(width: 4),
                    ],
                    // B 批（拍板①）：后台工作小点（sessions-index
                    // hasBackgroundWork，官方列表小圆点对位）。
                    if (entry.hasBackgroundWork && entry.phase != 'running')
                      Padding(
                        padding: const EdgeInsets.only(right: 5),
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: context.colors.running,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        entry.title.isEmpty ? '(未命名任务)' : entry.title,
                        translate: entry.title.isEmpty,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: AppType.uiBase,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: surface,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 状态图标化（2026-10-27 视觉优化）：运行中细旋转，
                          // 完成/等待/失败/空闲用形状区分，不再一律实心圆点。
                          taskPhaseIcon(entry.phase, color),
                          const SizedBox(width: 5),
                          Text(
                            label,
                            style: TextStyle(
                              fontSize: AppType.uiSm,
                              color: color,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                // A 批（拍板⑧）：工作流运行行（搜索/列表窄卡）。
                // 候选 15 验收 修正：run 行同样未读可见/已读隐藏
                //（上一轮只门了 preview——真机实锤常驻的是这条 run 线）。
                if (entry.workflowRuns.isNotEmpty && entry.unread)
                  WorkflowRunLines(runs: entry.workflowRuns),
                if (contentSnippet != null) ...[
                  const SizedBox(height: 6),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.manage_search,
                        size: 13,
                        color: context.colors.foregroundSubtlest,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          contentSnippet!,
                          translate: false,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppType.uiCaption,
                            color: context.colors.foregroundSubtle,
                          ),
                        ),
                      ),
                    ],
                  ),
// 候选 13 验收反馈（2026-11-09 用户拍板）：run 摘要预览未读可见、
                  // 已读隐藏——si 的 lastAssistantPreview 在会话末尾是
                  // run 行且无后续正文时不会更新，读后仍常驻副行。
                ] else if ((entry.preview ?? '').isNotEmpty &&
                    (entry.unread || !entry.previewIsRunDigest)) ...[
                  const SizedBox(height: 6),
                  Text(
                    // 视觉审查修订（2026-10-18）：卡片摘要是纯文本场景，
                    // 桌面下发的行文常带 **强调**/`代码`——裸符号直接显示
                    // 观感糙，剥掉后再呈示。
                    _stripMarkdown(entry.preview!),
                    translate: false,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppType.uiCaption,
                      color: context.colors.foregroundSubtle,
                    ),
                  ),
                ],
                if (entry.lastActivityAt > 0) ...[
                  const SizedBox(height: 4),
                  Text(
                    entry.historical
                        ? '${_relativeTime(entry.lastActivityAt)} · 冷启动需唤醒'
                        : _relativeTime(entry.lastActivityAt),
                    style: TextStyle(
                      fontSize: AppType.uiXs,
                      color: context.colors.foregroundSubtlest,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  (Color, Color, String) _statusOf(BuildContext context, TaskCardData entry) {
    if (entry.pendingInteraction != null) {
      return (
        context.colors.interactionAskForeground,
        context.colors.interactionAskSurface,
        '待处理',
      );
    }
    // 批次4：phase→徽标视觉收敛单源（与跨工作区卡同源，见 status_badge.dart）。
    final b = taskPhaseBadge(context.colors, entry.phase);
    return (b.color, b.surface, b.label);
  }
}

// 相对时间收敛到 task_home 单源（归档页原第二份实现）。
String _relativeTime(int millis, {DateTime? now}) =>
    taskHomeRelativeTime(millis, now: now);

// ------------------------------------------------- 新建对话 · 工作区选择层

/// 新建对话前先选落点（官方 mobile-task-home-design.md「2026-05-02 补充：
/// workspace 级新建任务入口」对位——新建=悬浮按钮+工作区选择弹层；同
/// 工作区直接草稿，跨工作区切换后进草稿，即 switchWorkspace(chat) 语义）。
///
/// 无项目对话（2026-10-22 用户诉求）：官方远程协议不提供"切到会话工作
/// 区"的直连 intent（conversation-workspace-target/resolve.ts 明示远程不
/// 提供该操作）——借**最新未归类任务**的任务 intent 切到默认会话区
/// （resolveSessionDirectories 对未归类任务同样可达，validation.ts:921-933），
/// 再进草稿，新会话即落在无项目区；一个未归类任务都没有时置灰（首次
/// 需在电脑端创建一个）。
/// [openDraftRoute]：草稿会话的打开路由（6.5 双栏）：宽屏传
/// TaskCenter 的 _openConversation（右栏就地选中草稿）；缺省=推入整页
/// （其他调用方/窄屏原行为）。

/// 机会项#1：新建项目流程——名字对话框（校验非空/无分隔符）→
/// workspace-create（可取消进度）→ 成功切换进新项目并直接开新会话。
Future<void> _createProjectFlow(
  BuildContext sheetCtx,
  AppState app, {
  void Function(String? sessionId, String title)? openDraftRoute,
}) async {
  // 注意顺序：先在 sheet 上叠对话框（sheet 弹层仍在树中 context 才
  // 活着），确认后再连 pop 两层（dialog→sheet）。
  final controller = TextEditingController();
  String? error;
  final bs = String.fromCharCode(92); // 反斜杠
  // 与「创建」按钮同一校验函数（onSubmitted 此前绕过校验直接 pop 空名/
  // 带分隔符名字，服务端必拒且用户拿不到错误上下文）。
  String? validate(String value) {
    if (value.isEmpty) return '名字不能为空';
    if (value.contains('/') || value.contains(bs)) {
      return '名字不能包含 / 或 $bs';
    }
    return null;
  }

  final name = await showDialog<String>(
    context: sheetCtx,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (dialogCtx, setDialog) => AlertDialog(
        title: const Text('新建项目'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('new-project-name'),
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '项目名（电脑 ZCodeProject 下创建）',
                errorText: error,
              ),
              onSubmitted: (v) {
                final value = v.trim();
                final err = validate(value);
                if (err != null) {
                  setDialog(() => error = err);
                  return;
                }
                Navigator.of(dialogCtx).pop(value);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const ValueKey('new-project-cancel'),
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('new-project-confirm'),
            onPressed: () {
              final value = controller.text.trim();
              final err = validate(value);
              if (err != null) {
                setDialog(() => error = err);
                return;
              }
              Navigator.of(dialogCtx).pop(value);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    ),
  );
  // 对话框退场动画期 dialog 树仍存活——延后释放防动画期编辑事件触碰。
  Future<void>.delayed(
    const Duration(milliseconds: 400),
    controller.dispose,
  );
  if (name == null || name.isEmpty) {
    return;
  }
  // 名字已定：关掉 sheet，创建/切换全程挂可取消进度对话框（真实 RPC
  // 最长 45s，原实现零反馈且无法中断）。navigator/messenger 必须先捕
  // 获——sheetCtx 随 sheet 退场动画卸载，进度层挂 Navigator 上下文。
  final navigator = Navigator.of(sheetCtx);
  final messenger = ScaffoldMessenger.maybeOf(sheetCtx);
  navigator.pop(); // sheet（dialog 已随返回值关闭）

  var cancelled = false;
  var progressOpen = false;
  var createdDone = false;
  late Map<String, dynamic> created;
  // （复审）：进度层必须整段持有自己的 route、用 removeRoute 精确
  // 摘除——此前 closeProgress 裸 pop 顶层，创建窗口内任何程序化导航
  // （通知深链推会话页）会先把新页压到进度层之上，pop 弹掉的是**新页**
  // 而进度层被永久钉死（barrier 不可点 + 返回键被 PopScope 吞）。
  DialogRoute<void>? progressRoute;
  void closeProgress() {
    final route = progressRoute;
    progressRoute = null;
    if (!progressOpen || route == null || !navigator.mounted) return;
    progressOpen = false;
    navigator.removeRoute(route);
  }

  progressOpen = true;
  progressRoute = DialogRoute<void>(
    context: navigator.context,
    barrierDismissible: false,
    builder: (dialogCtx) => PopScope(
        // 系统返回不得静默关掉进度层（关了之后 pop 会误关下一页）。
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text('正在创建项目 $name…')),
            ],
          ),
          actions: [
            TextButton(
              key: const ValueKey('new-project-progress-cancel'),
              onPressed: () {
                // 取消=放弃等待，但创建可能已提交到电脑端（结果未知）。
                cancelled = true;
                closeProgress();
                messenger?.showSnackBar(
                  SnackBar(
                    content: Text(
                      !createdDone
                          ? '已提交创建，结果未知——稍后刷新项目列表查看'
                          : '项目已创建，已取消进入——可从项目列表打开',
                    ),
                    duration: const Duration(seconds: 4),
                  ),
                );
              },
              child: const Text('取消等待'),
            ),
          ],
        ),
      ),
  );
  // 挂载进度层（持有 route 引用，closeProgress 用 removeRoute 精确摘除）。
  unawaited(navigator.push(progressRoute!));

  try {
    created = await app.createWorkspace(name);
    createdDone = true;
  } catch (e) {
    if (cancelled) return;
    closeProgress();
    messenger?.showSnackBar(SnackBar(content: Text('创建失败：$e')));
    return;
  }
  if (cancelled) return;
  // （对抗审查高·并发路）：官方约定=workspace-bridge-open.project
  //（无 project intent 的开桥只在当前窗口 tabs 里找，workspace-create
  // 只建目录不建 tab——全新项目（主用例）必失败）。走 project intent：
  // 构造项目档案交 switchToProject（projectId 随创建返回携带）。
  final path = '${created['workspacePath'] ?? ''}';
  final key = '${created['workspaceKey'] ?? ''}';
  if (path.isEmpty || key.isEmpty) {
    closeProgress();
    await app.refreshWorkspaces();
    return;
  }
  final project = {
    'id': '${created['projectId'] ?? ''}',
    'name': name,
    if (created['projectId'] == null) 'id': key,
    // rootPathsOf/primaryRootOf 契约=roots[].rootPath（字符串数组是
    // 旧实现的自造形状，项目 intent 解析拿不到根目录）。
    'roots': [
      {'rootPath': path, 'isPrimary': true},
    ],
  };
  try {
    await app.switchToProject(project);
  } catch (e) {
    if (cancelled) return;
    closeProgress();
    messenger?.showSnackBar(
      SnackBar(content: Text('进入新项目失败：$e（可从项目列表手动打开）')),
    );
    return;
  }
  if (cancelled) return;
  closeProgress();
  if (app.workspaceError != null) {
    messenger?.showSnackBar(
      const SnackBar(content: Text('工作区切换未完成，请稍后从项目列表打开')),
    );
    return;
  }
  // 注释语义：成功后切换进新项目，直接开新会话继续新建对话流程。
  if (openDraftRoute != null) {
    openDraftRoute(null, '新会话');
  } else if (navigator.mounted) {
    navigator.push(
      MaterialPageRoute(
        builder: (_) => const ConversationPage(sessionId: null, title: '新会话'),
      ),
    );
  }
}

Future<void> showNewTaskSheet(
  BuildContext context, {
  void Function(String? sessionId, String title)? openDraftRoute,
}) async {
  final app = AppStateScope.of(context);
  final currentKey = workspaceKeyOf(app.activeWorkspace ?? const {});
  final currentProject = currentKey == null
      ? null
      : app.projectForKey(currentKey);
  final currentProjectId = app.conversation == null
      ? null
      : (app.activeProjectId ?? '${currentProject?['id'] ?? ''}');

  final projects = [
    for (final p in app.sidebarProjects)
      if ('${p['id'] ?? ''}' != conversationsPseudoProjectId &&
          '${p['id'] ?? ''}' != currentProjectId)
        p,
  ];
  // 选择器按项目最近活跃排序（官方新建工作区选择同向）；无任务的
  // 项目保持既有本地顺序在后。手动项目顺序仍作用于「项目」分组视图。
  final lastActivity = <String, int>{};
  for (final t in app.projectTasks) {
    final pid = '${t['projectId'] ?? ''}';
    if (pid.isEmpty) continue;
    final at = (t['updatedAt'] as num?)?.toInt() ?? 0;
    if (at > (lastActivity[pid] ?? 0)) lastActivity[pid] = at;
  }
  final originalOrder = <String, int>{
    for (var i = 0; i < projects.length; i++) '${projects[i]['id']}': i,
  };
  projects.sort((a, b) {
    final aid = '${a['id'] ?? ''}';
    final bid = '${b['id'] ?? ''}';
    final byActivity = (lastActivity[bid] ?? -1).compareTo(
      lastActivity[aid] ?? -1,
    );
    if (byActivity != 0) return byActivity;
    return (originalOrder[aid] ?? 0).compareTo(originalOrder[bid] ?? 0);
  });

  final unclassified = app.unclassifiedTasks;
  Map<String, dynamic>? unclassifiedSeed;
  for (final t in unclassified) {
    final k = taskWorkspaceKey(t) ?? '';
    if (k.endsWith('workspace\\default') || k.endsWith('workspace/default')) {
      unclassifiedSeed = t;
      break;
    }
  }
  unclassifiedSeed ??= unclassified.isNotEmpty ? unclassified.first : null;
  final currentLabel =
      _workspaceLabelOf(app.activeWorkspace ?? const {}) ?? '当前工作区';

  void openDraft() {
    Navigator.of(context).pop(); // sheet
    final route = openDraftRoute;
    if (route != null) {
      route(null, '新会话');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ConversationPage(sessionId: null, title: '新会话'),
      ),
    );
  }

  Future<void> switchThen(String label, Future<void> Function() sw) async {
    Navigator.of(context).pop(); // sheet
    var cancelled = false;
    var loadingVisible = true;
    void closeLoading() {
      if (!loadingVisible || !context.mounted) return;
      loadingVisible = false;
      Navigator.of(context).pop();
    }

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: context.colors.foreground.withValues(alpha: 0.32),
      builder: (dialogContext) => PopScope(
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            cancelled = true;
            loadingVisible = false;
          }
        },
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 16),
              Expanded(child: Text('正在切换到 $label…')),
            ],
          ),
          actions: [
            TextButton(
              key: const ValueKey('new-task-switch-cancel'),
              onPressed: () {
                cancelled = true;
                loadingVisible = false;
                Navigator.of(dialogContext).pop();
              },
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
    try {
      await sw();
    } catch (e) {
      closeLoading();
      if (context.mounted && !cancelled) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('切换失败，请重试：$e'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return;
    }
    if (cancelled) return; // 后台开桥可继续，但不得再擅自进入新会话。
    closeLoading();
    if (!context.mounted) return;
    if (app.workspaceError != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('工作区切换未完成，请稍后重试')));
      return;
    }
    final route = openDraftRoute;
    if (route != null) {
      route(null, '新会话');
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ConversationPage(sessionId: null, title: '新会话'),
      ),
    );
  }

  var query = '';
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.colors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.card)),
    ),
    builder: (sheetCtx) => StatefulBuilder(
      builder: (sheetCtx, setSheetState) {
        final q = query.trim().toLowerCase();
        bool matches(String text) =>
            q.isEmpty || text.toLowerCase().contains(q);
        final visibleProjects = [
          for (final p in projects)
            if (matches('${p['name'] ?? ''} ${primaryRootOf(p) ?? ''}')) p,
        ];
        final showCurrent =
            app.conversation != null && matches('当前工作区 $currentLabel');
        final showUnclassified = matches('无项目对话 任务');
        // 键盘弹出时把选择器整体抬到输入法上方，并按剩余高度约束
        // 列表（此前仅 isScrollControlled，选项变少后会被键盘遮住）。
        final keyboardInset = MediaQuery.of(sheetCtx).viewInsets.bottom;
        final availableHeight =
            MediaQuery.of(sheetCtx).size.height - keyboardInset;
        return AnimatedPadding(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(bottom: keyboardInset),
          child: SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: availableHeight * 0.75),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 8),
                  Center(
                    child: Container(
                      width: 32,
                      height: 4,
                      decoration: BoxDecoration(
                        color: context.colors.border,
                        borderRadius: BorderRadius.circular(AppRadius.pill),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      '新建对话',
                      style: TextStyle(
                        fontSize: AppType.uiBase,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: TextField(
                      key: const ValueKey('new-task-project-search'),
                      autofocus: false,
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search, size: 20),
                        hintText: tr('搜索项目或路径'),
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) => setSheetState(() => query = value),
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      children: [
                        if (showCurrent)
                          ListTile(
                            leading: const Icon(
                              Icons.chat_bubble_outline,
                              size: 20,
                            ),
                            title: const Text('当前工作区'),
                            subtitle: Text(
                              currentLabel,
                              translate: false,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: AppType.uiXs),
                            ),
                            dense: true,
                            onTap: openDraft,
                          ),
                        // 机会项#1（2026-11-08 拍板）：新建项目行——
                        // workspace-create 直发（电脑 ~/ZCodeProject/
                        // <名字> 建目录，同名复用），成功后切换进新项目
                        /// 继续新建对话流程。
                        ListTile(
                          key: const ValueKey('new-project-row'),
                          leading: const Icon(
                            Icons.create_new_folder_outlined,
                            size: 20,
                          ),
                          title: const Text('新建项目'),
                          subtitle: const Text(
                            '在电脑 ZCodeProject 下创建并进入',
                            style: TextStyle(fontSize: AppType.uiXs),
                          ),
                          dense: true,
                          onTap: () => _createProjectFlow(
                            sheetCtx,
                            app,
                            openDraftRoute: openDraftRoute,
                          ),
                        ),
                        for (final p in visibleProjects)
                          ListTile(
                            leading: const Icon(
                              Icons.folder_outlined,
                              size: 20,
                            ),
                            title: Text(
                              '${p['name'] ?? ''}',
                              translate: false,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              primaryRootOf(p) ?? '暂无任务记录',
                              translate: primaryRootOf(p) == null,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: AppType.uiXs),
                            ),
                            dense: true,
                            onTap: () => switchThen(
                              '${p['name'] ?? ''}',
                              () => app.switchToProject(p),
                            ),
                          ),
                        if (showUnclassified)
                          ListTile(
                            leading: const Icon(Icons.dns_outlined, size: 20),
                            title: const Text('无项目对话'),
                            subtitle: Text(
                              unclassified.isEmpty
                                  ? '需先在电脑端创建一个无项目对话'
                                  : '不归属任何项目，出现在「任务」列表',
                              style: const TextStyle(fontSize: AppType.uiXs),
                            ),
                            dense: true,
                            enabled: unclassified.isNotEmpty,
                            onTap: unclassified.isEmpty
                                ? null
                                : () => switchThen(
                                    '无项目对话',
                                    () => app.switchToTask(
                                      unclassifiedSeed ?? unclassified.first,
                                      label: '无项目对话',
                                    ),
                                  ),
                          ),
                        if (!showCurrent &&
                            visibleProjects.isEmpty &&
                            !showUnclassified)
                          const Padding(
                            padding: EdgeInsets.all(24),
                            child: Center(child: Text('没有匹配的项目')),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// 项目排序弹层（2026-10-26 拍板③，官方 preferences.reorder 同语义=
/// 本地偏好不同步）：竖排拖动调序（官方桌面拖拽手感），拖完即存、
/// 完成关闭。「任务」伪项目不参与（恒排尾部）。
Future<void> showProjectOrderSheet(BuildContext context) {
  final app = AppStateScope.of(context);
  final entries = app.sidebarProjects
      .where((p) => '${p['id'] ?? ''}' != conversationsPseudoProjectId)
      .toList();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => SafeArea(
      child: _ProjectOrderSheet(entries: entries, onSaved: app.setProjectOrder),
    ),
  );
}

class _ProjectOrderSheet extends StatefulWidget {
  final List<Map<String, dynamic>> entries;
  final Future<void> Function(List<String> ids) onSaved;
  const _ProjectOrderSheet({required this.entries, required this.onSaved});

  @override
  State<_ProjectOrderSheet> createState() => _ProjectOrderSheetState();
}

class _ProjectOrderSheetState extends State<_ProjectOrderSheet> {
  late final List<Map<String, dynamic>> _items = List.of(widget.entries);

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.6,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              '调整项目顺序',
              style: TextStyle(
                fontSize: AppType.uiBase,
                fontWeight: FontWeight.w600,
                color: context.colors.foreground,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '按住右侧手柄拖动调整；顺序保存在本机（与桌面端各自独立）',
              style: TextStyle(
                fontSize: AppType.uiXs,
                color: context.colors.foregroundSubtle,
              ),
            ),
          ),
          Flexible(
            child: ReorderableListView(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              onReorder: (oldIndex, newIndex) {
                // messenger 在同步段捕获（：落盘失败不
                // 静默丢单；跨 async gap 用 State.context 会被 lint 拦）。
                final messenger = ScaffoldMessenger.maybeOf(context);
                setState(() {
                  if (newIndex > oldIndex) newIndex -= 1;
                  final item = _items.removeAt(oldIndex);
                  _items.insert(newIndex, item);
                });
                () async {
                  try {
                    await widget.onSaved([
                      for (final e in _items) '${e['id'] ?? ''}',
                    ]);
                  } catch (e) {
                    messenger?.showSnackBar(
                      SnackBar(content: Text('顺序保存失败，请重试：$e')),
                    );
                  }
                }();
              },
              children: [
                for (var i = 0; i < _items.length; i++)
                  ListTile(
                    // id 为空串（畸形 readTree 数据）时
                    // 回落索引，防同级重复 key（'order-'）断言崩溃。
                    key: ValueKey(
                      'order-${'${_items[i]['id'] ?? ''}'.trim().isEmpty ? i : _items[i]['id']}',
                    ),
                    dense: true,
                    title: Text(
                      '${_items[i]['name'] ?? ''}',
                      translate: false,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppType.uiBase,
                        color: context.colors.foreground,
                      ),
                    ),
                    trailing: ReorderableDragStartListener(
                      index: i,
                      child: Icon(
                        Icons.drag_handle,
                        size: 20,
                        color: context.colors.foregroundSubtle,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: context.colors.brand,
                  foregroundColor: context.colors.onBrand,
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('完成'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// （批3）：其他电脑聚合只取最近任务——缓存行带 updatedAt，
/// 此前直接 take(5) 恒取缓存序前 5 条，可能展示很久以前的而藏掉最近的。
List<Map<String, dynamic>> _recentTasks(
    List<Map<String, dynamic>> tasks, int count) {
  final sorted = [...tasks]..sort((a, b) {
      final au = (a['updatedAt'] as num?)?.toInt() ?? 0;
      final bu = (b['updatedAt'] as num?)?.toInt() ?? 0;
      return bu.compareTo(au);
    });
  return sorted.take(count).toList();
}

/// 双栏紧凑行高度（含 workflow run 线）：官方
/// WORKFLOW_RUN_LINE_MAX_LINES=2——最多画 2 条 run 行 + 「+n」尾巴，
/// 固定 68px 在 ≥2 条或大字号下必溢出；行高按实际行数×textScaler 算。
@visibleForTesting
double compactTaskRowHeight(int runCount, TextScaler scaler) {
  final lines = runCount == 0
      ? 0
      : (runCount > WorkflowRunLines.maxLines
          ? WorkflowRunLines.maxLines + 1
          : runCount);
  // （复审）：系数按 M3 bodyMedium 实际行高 1.43 取 1.45（+逐行
  // padding 预算 3px）——1.25 会让 3 行 + 1.3× 字号仍轻微溢出。
  return 48 + lines * (scaler.scale(10) * 1.45 + 3);
}

/// A 批（2026-11-08 拍板⑧）：任务卡工作流运行行（官方
/// TaskWorkflowRunLines compact 对位——图标+名+状态词，非按钮）。
class WorkflowRunLines extends StatelessWidget {
  final List<Map<String, dynamic>> runs;

  /// 紧凑行档（图标/字号再收一档）。
  final bool compact;
  const WorkflowRunLines({super.key, required this.runs, this.compact = false});

  /// 官方 WORKFLOW_RUN_LINE_MAX_LINES=2（workflowRunLine.ts:13）。
  static const int maxLines = 2;

  @override
  Widget build(BuildContext context) {
    final visible = runs.length <= maxLines
        ? runs
        : runs.sublist(0, maxLines);
    final overflow = runs.length - visible.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < visible.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 2 : 1),
            child: Row(
              children: [
                Icon(
                  Icons.account_tree_outlined,
                  size: compact ? 10 : 11,
                  color: '${visible[i]['status'] ?? ''}' == 'running'
                      ? context.colors.running
                      : context.colors.foregroundSubtlest,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _runLine(visible[i]),
                    translate: false,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 10 : AppType.uiXs,
                      color: '${visible[i]['status'] ?? ''}' == 'running'
                          ? context.colors.running
                          : context.colors.foregroundSubtlest,
                    ),
                  ),
                ),
              ],
            ),
          ),
        // 官方同款「+n」尾：被折叠的 run 数（不是逐条堆叠）。
        if (overflow > 0)
          Padding(
            padding: EdgeInsets.only(top: visible.isEmpty ? 2 : 1),
            child: Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Text(
                '+$overflow',
                translate: false,
                style: TextStyle(
                  fontSize: compact ? 10 : AppType.uiXs,
                  color: context.colors.foregroundSubtlest,
                ),
              ),
            ),
          ),
      ],
    );
  }

  static String _runLine(Map<String, dynamic> run) {
    // 整串 translate:false（run 名/phase 是用户内容），状态词必须先 tr
    // 再拼——否则英文界面残留中文状态后缀。
    final name = '${run['name'] ?? tr('工作流')}';
    final status = '${run['status'] ?? ''}';
    final waiting = '${run['waitingHole'] ?? ''}';
    if (waiting.isNotEmpty) return '$waiting · ${tr('等待补全')}';
    if (status == 'running' || status == 'pending') {
      final phase = '${run['currentPhase'] ?? ''}';
      if (phase.isNotEmpty) return '$name · $phase';
      // pending 不是「运行中」——官方状态词等待中。
      return '$name · ${tr(workflowRunStatusWord(status))}';
    }
    return '$name · ${tr(workflowRunStatusWord(status))}';
  }
}

/// A 批+：任务行携带的 workflow 运行摘要。live 首页行键=
/// workflowActivity.runs（controllerRowToTaskMap 直通）；兜底行
/// （workspaceTasks 空时的 taskHomeCardRow 序列化）键=workflowRuns。
List<Map<String, dynamic>> _cardRuns(Map<String, dynamic> task) {
  for (final k in const ['workflowActivity', 'workflowRuns']) {
    final w = k == 'workflowRuns' ? task['workflowRuns'] : (task[k] as Map?)?['runs'];
    if (w is List && w.isNotEmpty) {
      return [for (final r in w) if (r is Map) r.cast<String, dynamic>()];
    }
  }
  return const [];
}
