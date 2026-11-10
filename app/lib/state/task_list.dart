import 'package:flutter/foundation.dart';

import '../core/payload_guard.dart';
import '../transport/conversation.dart';

/// 任务卡视图模型：双源合并结果（sessions-index 实时 + zcodeTask 通道元数据）。
class TaskCardData {
  final String sessionId;
  final String title;
  final String phase; // 归一化 phase（见 normalizePhase）
  final String? preview;

  /// 预览当前是工作流 run 摘要（会话末尾无正文、si 的
  /// lastAssistantPreview 停在 run 行文案——用户拍板 2026-11-09：
  /// run 摘要预览未读可见、已读隐藏，不作为永久副行）。
  final bool previewIsRunDigest;
  final int lastActivityAt;
  final int createdAt;
  final bool pinned;
  final bool hasBackgroundWork;

  /// 闲时任务（B 批 2026-11-08）：meta.offPeakTaskId 随 tasks-index
  /// 行携带（官方 TaskListItem 月亮标对位）；null=普通任务。
  final String? offPeakTaskId;

  /// 工作流运行摘要（A 批 2026-11-08 拍板⑧）：activity.workflowActivity
  /// .runs（≤4 条，官方 TaskWorkflowRunLines 对位）；空=无 run。
  final List<Map<String, dynamic>> workflowRuns;
  final String? goalStatus;
  final bool unread;
  final Map<String, dynamic>? pendingInteraction;

  /// 该会话当前无运行时（sessions-index existing-only 没有它，仅来自任务索引
  /// 的历史任务）——打开时需要冷唤醒。
  final bool historical;

  const TaskCardData({
    required this.sessionId,
    required this.title,
    required this.phase,
    required this.preview,
    this.previewIsRunDigest = false,
    required this.lastActivityAt,
    required this.createdAt,
    required this.pinned,
    required this.hasBackgroundWork,
    this.offPeakTaskId,
    this.workflowRuns = const [],
    required this.goalStatus,
    required this.unread,
    required this.pendingInteraction,
    required this.historical,
  });
}

/// 归一化状态值（session.phase 全集 ∪ task.status 全集）。
/// task.status（zcodeTaskPersistStatusSchema，validation.ts:1459）：
/// running/completed/error——映射进 session phase 词汇表。
String normalizePhase(String phaseOrStatus) => switch (phaseOrStatus) {
  'completed' => 'completedSuccess',
  'failed' || 'cancelled' => 'completedInterrupted',
  _ => phaseOrStatus,
};

bool isRunningPhase(String phase) =>
    phase == 'running' || phase == 'prewarming';

/// 双源任务列表模型（阶段 2 波次 1）。
///
/// 数据源与成员关系参照官方 windowHostControllerService.readSourceTaskIndex：
/// - zcodeTask 通道 `listTasks`/`listPinnedTasks`/`listArchivedTasks` 三列表
///   给出 pinned/archived/active 成员关系（持久任务索引，覆盖历史会话）；
/// - sessions-index 实时订阅给出活跃会话的 phase/title/preview；
/// - 合并：session 数据优先（实时），任务索引兜底（历史会话显示），
///   archived/deleted 剔除（用户 2026-10-15 反馈：桌面归档后手机不消失）；
/// - `workspace-list-updated` 推送的任务标志实时维护 archived 集合。
///
/// 排序稳定性参照 zemote stabilizeTaskOrder：可见集合不变时保持当前顺序，
/// 只刷新字段——避免 running 任务因 lastActivityAt 变化在列表里跳动。
class TaskListModel extends ChangeNotifier {
  /// F1 冷工作区（si dormant）：不要求 sessions.ready，通道任务（历史/
  /// 归档，zcodeTask 三列表冷可用）直接渲染；si 复活后上层重建本模型。
  final bool dormant;

  /// 缓存预渲模型（_seedCachePreview 构建）：数据是上次落盘的陈旧快照。
  /// 通知差分禁止以它建基线或消费对账水位——陈旧 running 基线会在 live
  /// 重放时误报"完成"，预渲还会提前吃掉断连对账水位（发现1）。
  final bool cachePreview;
  final SessionsIndexState sessions;
  final String workspaceKey;
  final void Function(String line)? onLog;

  TaskListModel({
    this.dormant = false,
    this.cachePreview = false,
    required this.sessions,
    required this.workspaceKey,
    this.onLog,
  }) {
    sessions.addListener(_rebuild);
  }

  /// zcodeTask 通道三列表：active 元数据 / 置顶 id / 归档 id。
  List<Map<String, dynamic>> _channelTasks = const [];
  final Set<String> _pinnedIds = {};
  final Set<String> _archivedIds = {};

  /// 已删除任务 id 墓碑集（listDeletedTaskIds）。官方语义：sessions-index
  /// 不排除已删除会话，消费方必须做负向 join（refs taskIndexRepo.ts:2085
  /// ——"deleted task 会因不在 archived 集合被误判成普通 task，并在冷启动
  /// 后重新出现"；官方桌面 UI 同款减法见 taskListMembershipSets.ts:227）。
  /// 不做这步的实锤：离线墓碑清理后桌面干净、手机经 si 复活（2026-10-20）。
  final Set<String> _deletedIds = {};

  List<TaskCardData> _cards = const [];
  List<TaskCardData> get cards => _cards;

  // C2（2026-10-19 审查）：三区缓存（_rebuild 时重算）——原 getter 每次
  // 过滤+复制，页面/前台服务文本每通知各取一遍，流式期间每帧三份拷贝。
  List<TaskCardData> _pinnedView = const [];
  List<TaskCardData> _runningView = const [];
  List<TaskCardData> _restView = const [];

  List<TaskCardData> get pinned => _pinnedView;
  List<TaskCardData> get running => _runningView;
  List<TaskCardData> get rest => _restView;

  void _recomputePartitions() {
    _pinnedView = _cards.where((c) => c.pinned).toList();
    _runningView = _cards
        .where((c) => !c.pinned && isRunningPhase(c.phase))
        .toList();
    _restView = _cards
        .where((c) => !c.pinned && !isRunningPhase(c.phase))
        .toList();
  }

  /// 本地墓碑（归档/删除后 sessions-index 推送滞后期的防复活，zemote
  /// _recentlyRemoved 同款，60s 过期）。
  final Map<String, int> _recentlyRemoved = {};

  bool _channelLoaded = false;

  /// 任务索引三列表是否已加载（未加载时列表仅含 sessions-index 实时会话，
  /// 历史会话要等它到达才出现）。
  bool get channelLoaded => _channelLoaded;

  void _log(String line) => onLog?.call(line);

  /// 全量应用 zcodeTask 三列表 + 已删除集（工作区打开/重开时调用）。
  void applyChannelLists({
    required List<Map<String, dynamic>> active,
    required List<String> pinnedIds,
    required List<String> archivedIds,
    List<String> deletedIds = const [],
  }) {
    _channelTasks = List.of(active);
    _pinnedIds
      ..clear()
      ..addAll(pinnedIds);
    _archivedIds
      ..clear()
      ..addAll(archivedIds);
    _deletedIds
      ..clear()
      ..addAll(deletedIds);
    _channelLoaded = true;
    _log(
      '[task-list] channel lists: active=${active.length} '
      'pinned=${pinnedIds.length} archived=${archivedIds.length} '
      'deleted=${deletedIds.length}',
    );
    _rebuild();
  }

  /// `workspace-list-updated` 推送的任务增量（跨工作区广播，需按
  /// workspaceKey 过滤新 id——zemote task_home_page.dart:203-221 同款语义）。
  void applyWorkspaceListTasks(
    List<dynamic> tasks,
    String currentWorkspaceKey,
  ) {
    var changed = false;
    final byId = <String, Map<String, dynamic>>{
      for (final t in _channelTasks)
        if (t['taskId'] != null) '${t['taskId']}': t,
    };
    for (final raw in tasks) {
      if (raw is! Map || raw['taskId'] == null) continue;
      final id = '${raw['taskId']}';
      final map = raw.cast<String, dynamic>();
      final taskWorkspace =
          '${map['workspaceIdentity'] ?? map['workspacePath'] ?? ''}';
      // 已知 id 无条件更新；未知 id 仅当推送明确属于当前工作区时接受。
      if (!byId.containsKey(id) && taskWorkspace != currentWorkspaceKey) {
        continue;
      }
      if (map['archived'] == true || map['deleted'] == true) {
        final deleted = map['deleted'] == true;
        final added = deleted ? _deletedIds.add(id) : _archivedIds.add(id);
        if (added) {
          changed = true;
          _log('[task-list] task ${deleted ? 'deleted' : 'archived'}: $id');
        }
        byId.remove(id);
        _pinnedIds.remove(id);
        continue;
      }
      // 复活路径（此前在 archived/deleted 集内、推送宣布正常）：集合摘除
      // 本身就是状态变化，计入 changed——行内容可能一致（差分只跳过
      // 「完全无变化」的推送）。
      if (_archivedIds.remove(id)) changed = true;
      if (_deletedIds.remove(id)) changed = true;
      // pinned 标志实时落集（controller 行映射带来，官方 membership 语义
      // controller.ts:125-142）。workspace-list 时代 pinned 只是展示字段
      // 没落集——桌面侧置顶手机要等三列表重拉才生效，现在实时。
      if (map['pinned'] is bool) {
        final nowPinned = map['pinned'] == true;
        final wasPinned = _pinnedIds.contains(id);
        if (wasPinned != nowPinned) {
          nowPinned ? _pinnedIds.add(id) : _pinnedIds.remove(id);
          changed = true;
        }
      }
      // 内容无差异的已知 id 跳过（ J1-6/J2 P3-4，电量同源半项）：
      // tasks-index 活跃期约 5s 一推、行内容多数一致——恒 changed=true 会
      // 让每次推送都全量 merge+sort+notify+缓存写防抖重挂（磁盘侧指纹
      // 去重只兜住写盘，UI 重建链路纯浪费）。mapEquals 对标量字段（String/
      // num/bool/null）按值比较即命中；嵌套集合值按身份比较不命中时退回
      // 原行为（多重建一次，无正确性影响）。
      final merged = {...?byId[id], ...map};
      if (!mapEquals(byId[id], merged)) {
        byId[id] = merged;
        changed = true;
      }
    }
    if (!changed) return;
    _channelTasks = byId.values.toList();
    _rebuild();
  }

  /// 测试缝：把现存墓碑整体回拨 [age]（过期路径红绿用；生产禁止调用）。
  @visibleForTesting
  void debugAgeRemovedTombstonesForTest(Duration age) {
    final delta = age.inMilliseconds;
    _recentlyRemoved.updateAll((_, at) => at - delta);
  }

  /// 本地移除（乐观更新：归档/删除命令已受理，推送未到的窗口期防复活）。
  void markRemovedLocally(String id) {
    _recentlyRemoved[id] = DateTime.now().millisecondsSinceEpoch;
    _rebuild();
  }

  /// 撤销本地墓碑（归档/删除命令失败或用户撤销时）：此前只有 60s 过期
  /// 一条退路——RPC 抛错后卡片要等一分钟才回来，且过期前重拉也会被
  /// 本地墓碑继续遮蔽。
  void clearRemovedLocally(String id) {
    if (_recentlyRemoved.remove(id) == null) return;
    _rebuild();
  }

  /// 批量本地移除（ J2 P3-3）：remote 重连换代/投影重建时
  /// removedIds 成批到达——逐 id 调 markRemovedLocally 会触发 N 次全量
  /// merge+sort+notify（每次又重挂缓存写防抖）。循环只写墓碑，收尾一次
  /// 重建。
  void markRemovedLocallyAll(Iterable<String> ids) {
    if (ids.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final id in ids) {
      _recentlyRemoved[id] = now;
    }
    _rebuild();
  }

  /// 本地置顶切换（乐观更新；listPinnedTasks 重拉会校正）。
  void togglePinLocally(String id) {
    if (_pinnedIds.contains(id)) {
      _pinnedIds.remove(id);
    } else {
      _pinnedIds.add(id);
    }
    _rebuild();
  }

  /// 幂等置位（对齐目标值而非翻转）：UI 层可能重复提交同一目标值
  /// （点按抖动/失败重试），翻转语义会把目标态打成相反态。
  void setPinLocally(String id, bool pinned) {
    final was = _pinnedIds.contains(id);
    if (was == pinned) return;
    if (pinned) {
      _pinnedIds.add(id);
    } else {
      _pinnedIds.remove(id);
    }
    _rebuild();
  }

  // ---------------------------------------------- 列表缓存导出（阶段 3）

  /// 双源原始数据导出（缓存只存协议数据不存派生卡；重建路径=
  /// ComputerStack._loadDeviceCache：dormant 模型+applyChannelLists 走
  /// 同一条 mergeTaskSources 合并——呈现语义天然一致）。
  List<Map<String, dynamic>> get channelTasksForCache => List.of(_channelTasks);
  List<String> get pinnedIdsForCache => _pinnedIds.toList();
  List<String> get archivedIdsForCache => _archivedIds.toList();
  List<String> get deletedIdsForCache => _deletedIds.toList();
  List<Map<String, dynamic>> get sessionsForCache => [
    for (final s in sessions.sessions.values) s.raw,
  ];

  void _rebuild() {
    if (sessions.ready || dormant) {
      // 过期清理与 keys 迭代分离（ J1-1/J2 P1-1/J3 P1-1 三路）：
      // 原实现把 remove 放进 .where 谓词——Map.keys 是惰性活视图，迭代
      // 中改 map 必抛 ConcurrentModificationError（单条过期也炸），归档/
      // 删除任务 60s 后的下一次 rebuild 必现；notifyListeners 逐监听器
      // 吞异常把它掩盖成"偶发丢一帧+logcat 噪声"。
      _recentlyRemoved.removeWhere(
        (_, at) => DateTime.now().millisecondsSinceEpoch - at > 60000,
      );
      final removed = _recentlyRemoved.keys.toSet();
      final merged = mergeTaskSources(
        sessions: sessions.list,
        channelTasks: _channelTasks,
        pinnedIds: _pinnedIds,
        archivedIds: _archivedIds,
        deletedIds: _deletedIds,
        removedIds: removed,
      );
      _cards = stabilizeTaskOrder(_cards, merged);
    } else {
      _cards = const [];
    }
    _recomputePartitions();
    notifyListeners();
  }

  @override
  void dispose() {
    sessions.removeListener(_rebuild);
    super.dispose();
  }
}

/// 合并双源为任务卡列表（纯函数）：
/// - sessions-index 条目（剔除 archived/deleted）为活跃数据；
/// - 通道任务（剔除 archived/deleted）为兜底元数据——不在 sessions-index 里的
///   历史任务按持久 status 显示（historical=true）；
/// - 两者都在时 session 的实时字段（phase/preview）优先，title 双向兜底。
/// - deletedIds 是官方要求的 si 负向 join（见 _deletedIds 字段注释）——
///   si 不排除已删除会话，漏了这步删除任务会在冷启动后复活。
List<TaskCardData> mergeTaskSources({
  required List<SessionEntry> sessions,
  required List<Map<String, dynamic>> channelTasks,
  required Set<String> pinnedIds,
  required Set<String> archivedIds,
  Set<String> deletedIds = const {},
  Set<String> removedIds = const {},
}) {
  final out = <String, TaskCardData>{};

  void emit(String id, {SessionEntry? s, Map<String, dynamic>? task}) {
    if (archivedIds.contains(id) ||
        deletedIds.contains(id) ||
        removedIds.contains(id)) {
      return;
    }
    final phase = s != null
        ? normalizePhase(s.phase)
        : normalizePhase('${task?['status'] ?? ''}');
    final title = (s != null && s.title.trim().isNotEmpty)
        ? s.title
        : ('${task?['title'] ?? ''}');
    // 守卫（ J3-P2-2）：同 task_catalog 排序器同族——畸形行
    // 硬转换会沿 notifyListeners 上抛，改安全读取按 0 兜底。
    final activity = s != null && s.lastActivityAt > 0
        ? s.lastActivityAt
        : intOrZero(task?['updatedAt']);
    final created = s != null && s.createdAt > 0
        ? s.createdAt
        : intOrZero(task?['createdAt']);
    final prev = out[id];
    // 同一 id 可能先以 task 再以 session 出现（或反之）——保留较优字段。
    final runs = _runsOf(task?['workflowActivity']).isNotEmpty
        ? _runsOf(task?['workflowActivity'])
        : (prev?.workflowRuns ?? const []);
    final previewText = s?.lastAssistantPreview ?? prev?.preview;
    out[id] = TaskCardData(
      sessionId: id,
      title: title.isNotEmpty
          ? title
          : (prev?.title.isNotEmpty == true ? prev!.title : title),
      phase: s != null || prev == null ? phase : prev.phase,
      preview: previewText,
      previewIsRunDigest: previewText != null &&
          runs.any((r) {
            // 官方 workflowActivity.runs 行键=name（候选 15 真机实证；
            // label 兜底防御异构来源）。
            final name = '${r['name'] ?? r['label'] ?? ''}';
            return name.isNotEmpty && previewText.contains(name);
          }),
      lastActivityAt: activity > (prev?.lastActivityAt ?? 0)
          ? activity
          : (prev?.lastActivityAt ?? activity),
      createdAt: created > 0 ? created : (prev?.createdAt ?? 0),
      pinned: pinnedIds.contains(id) || (prev?.pinned ?? false),
      // hasBackgroundWork 兜底链补 task 行（ J1-8）：行映射特意
      // 携带 activity.hasBackgroundWork，但 channel-task-only 的历史卡在
      // merge 层永远读不到（恒 false）——taskHomeCardRow 兜底行丢后台
      // 工作标志。
      hasBackgroundWork:
          s?.hasBackgroundWork ??
          (prev?.hasBackgroundWork ?? (task?['hasBackgroundWork'] == true)),
      offPeakTaskId: task?['offPeakTaskId'] != null
          ? '${task?['offPeakTaskId']}'
          : prev?.offPeakTaskId,
      workflowRuns: runs,
      goalStatus: s?.goalStatus ?? prev?.goalStatus,
      unread: (task?['unreadAt'] != null) || (prev?.unread ?? false),
      pendingInteraction: s?.pendingInteraction ?? prev?.pendingInteraction,
      historical: s == null && (prev?.historical ?? true),
    );
  }

  for (final task in channelTasks) {
    final id = '${task['taskId'] ?? ''}';
    if (id.isEmpty) continue;
    emit(id, task: task);
  }
  for (final entry in sessions) {
    if (entry.sessionId.isEmpty) continue;
    emit(entry.sessionId, s: entry);
  }
  final list = out.values.toList()
    ..sort((a, b) => b.lastActivityAt.compareTo(a.lastActivityAt));
  return list;
}

/// controller/tasks-index 行 → workspace-list 任务条目形状（：
/// 官方 3.16 删 workspace-list tasks[] 后，跨工作区搜索/实时标志增量的
/// 数据源迁 controller 主题；行映射回 legacy 形状，既有消费方
/// _CrossTaskCard/filterCrossWorkspaceTasks/applyWorkspaceListTasks 零改动）。
///
/// - displayStatus ← liveStatus（displayStatus 的官方继任者，词表
///   idle/running/waiting/completed/error；waiting 为 3.16 新增——徽标
///   单源 status_badge.dart 已补"待处理"）；
/// - status 对齐官方 defaultLiveStatus 语义（projection.ts:121-132）：
///   liveStatus=idle 时只信持久**终态** completed/error——SQLite 残留的
///   running 不代表仍在运行，不复活为运行态。
List<Map<String, dynamic>> _runsOf(Object? activity) {
  if (activity is! Map || activity['runs'] is! List) return const [];
  return [
    for (final r in activity['runs'] as List)
      if (r is Map) r.cast<String, dynamic>(),
  ];
}

Map<String, dynamic> controllerRowToTaskMap(Map<String, dynamic> row) {
  Map<String, dynamic> cast(Object? v) =>
      v is Map ? v.cast<String, dynamic>() : const <String, dynamic>{};
  final address = cast(row['address']);
  final meta = cast(row['meta']);
  final membership = cast(row['membership']);
  final activity = cast(row['activity']);
  final liveStatus = '${row['liveStatus'] ?? 'idle'}';
  final persisted = '${meta['status'] ?? ''}';
  return {
    'taskId': meta['taskId'] ?? address['taskId'],
    'title': meta['title'],
    'workspacePath': address['workspacePath'],
    'workspaceIdentity': address['workspaceIdentity'],
    'createdAt': meta['createdAt'],
    'updatedAt': meta['updatedAt'],
    'unreadAt': meta['unreadAt'],
    'archived': membership['archived'] == true,
    'pinned': membership['pinned'] == true,
    'displayStatus': liveStatus,
    'status': liveStatus != 'idle'
        ? liveStatus
        : (persisted == 'completed' || persisted == 'error'
              ? persisted
              : 'idle'),
    'searchSnippets': row['searchSnippets'],
    'hasBackgroundWork': activity['hasBackgroundWork'],
    // B 批：官方 meta.offPeakTaskId（taskIndexRepo 映射）——白名单补收。
    'offPeakTaskId': meta['offPeakTaskId'],
    'workflowActivity': activity['workflowActivity'],
    'sourceAvailability': row['sourceAvailability'],
  };
}

/// listDeletedTaskIds 载荷解析。官方契约=纯字符串数组
/// （`Promise<string[]>`，refs zcodeTaskService.ts:460-464），与三列表的
/// 任务对象载荷不同。
/// 真机教训（2026-10-23）：误用对象列表解析（asMaps+取 taskId）恒得空集，
/// si 负向 join 从未生效——桌面墓碑达数百时手机仍显示两百上下旧卡。
/// 防御：字符串直读；对象条目兜底取 taskId（未来官方若改形状不至于静默失效）；
/// 非列表返回空（RPC 失败 catchError 已在上游归一为 const []）。
List<String> parseDeletedTaskIds(dynamic raw) {
  if (raw is! List) return const [];
  final out = <String>[];
  for (final e in raw) {
    if (e is String) {
      if (e.isNotEmpty) out.add(e);
    } else if (e is Map) {
      final id = '${e['taskId'] ?? ''}';
      if (id.isNotEmpty && id != 'null') out.add(id);
    }
  }
  return out;
}

/// F18 跨工作区搜索过滤（纯函数）：workspace-list 全量任务里筛非活跃
/// 工作区、未归档、不在活跃列表里的标题命中（官方 getAvailableTasks 全量
/// 载荷——webRemoteControlManager.ts:729；任务条目字段见
/// web-remote-control.ts:747 WebRemoteControlTaskTarget）。
List<Map<String, dynamic>> filterCrossWorkspaceTasks({
  required List<Map<String, dynamic>> workspaceTasks,
  required String? activeKey,
  required Set<String> activeIds,
  required String query,
}) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  return workspaceTasks.where((t) {
    if (t['archived'] == true || t['deleted'] == true) return false;
    final id = '${t['taskId'] ?? ''}';
    if (id.isEmpty || activeIds.contains(id)) return false;
    final key = '${t['workspaceIdentity'] ?? t['workspacePath'] ?? ''}';
    if (key == (activeKey ?? '')) return false;
    return '${t['title'] ?? ''}'.toLowerCase().contains(q);
  }).toList();
}

/// 官方 listTaskList 全文命中拆分（纯函数）：按工作区归属把命中分成
/// 当前工作区 taskId 集合（页面据此把"正文命中、标题/预览没命中"的
/// 本地卡片提为可见）与其他工作区任务行（跨区卡片直用，官方
/// workspaceIdentity ?? workspacePath 同 key 语义）。
({Set<String> currentIds, List<Map<String, dynamic>> crossHits})
splitSearchHitsByWorkspace({
  required List<Map<String, dynamic>> hits,
  required String? activeKey,
}) {
  final current = <String>{};
  final seen = <String>{};
  final cross = <Map<String, dynamic>>[];
  for (final h in hits) {
    final id = '${h['taskId'] ?? ''}';
    if (id.isEmpty) continue;
    final identity = '${h['workspaceIdentity'] ?? ''}'.trim();
    final key = identity.isNotEmpty ? identity : '${h['workspacePath'] ?? ''}';
    if (activeKey != null && key == activeKey) {
      current.add(id);
    } else if (seen.add('$key:$id')) {
      cross.add(h);
    }
  }
  return (currentIds: current, crossHits: cross);
}

/// 跨工作区搜索结果合并（纯函数）：官方全文命中在前（带正文片段），
/// 本地 workspace-list 标题命中补在后（官方搜索未返回/失败时的即时
/// 兜底），按 taskId 去重。
List<Map<String, dynamic>> mergeCrossSearchHits({
  required List<Map<String, dynamic>> serverHits,
  required List<Map<String, dynamic>> localHits,
}) {
  final seen = serverHits
      .map((t) => '${t['taskId'] ?? ''}')
      .where((id) => id.isNotEmpty)
      .toSet();
  return [
    ...serverHits,
    ...localHits.where((t) {
      final id = '${t['taskId'] ?? ''}';
      return id.isNotEmpty && !seen.contains(id);
    }),
  ];
}

/// 官方片段字段读取（searchSnippets 数组优先取首个非空，回退
/// searchSnippet 单段——refs zcodeTaskListTypes.ts:20-23）。
String? firstSearchSnippet(Map<String, dynamic> task) {
  final many = task['searchSnippets'];
  if (many is List) {
    for (final s in many) {
      if (s is String && s.trim().isNotEmpty) return s.trim();
    }
  }
  final one = task['searchSnippet'];
  if (one is String && one.trim().isNotEmpty) return one.trim();
  return null;
}

/// 保持当前顺序当可见集合未变（zemote task_home_page.dart:39-62 同款）：
/// running 任务的 lastActivityAt 在实时帧里持续跳动，若每帧重排会闪烁。
List<TaskCardData> stabilizeTaskOrder(
  List<TaskCardData> current,
  List<TaskCardData> merged,
) {
  if (current.isEmpty) return merged;
  final currentIds = current.map((c) => c.sessionId).toSet();
  final newIds = merged.map((c) => c.sessionId).toSet();
  if (currentIds.length != newIds.length || !currentIds.containsAll(newIds)) {
    return merged;
  }
  final byId = {for (final c in merged) c.sessionId: c};
  return [
    for (final c in current)
      if (byId[c.sessionId] != null) byId[c.sessionId]!,
  ];
}
