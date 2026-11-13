import '../core/payload_guard.dart';
import '../state/task_list.dart';
import '../transport/project_tree.dart';

/// 任务主页（项目栏优化 B 方案，2026-10-26）：纯视图模型。
///
/// 数据源不新增协议调用：
/// - workspaceTasks（controller/tasks-index / workspace-list）= 当前桌面
///   窗口任务全集，带 liveStatus；
/// - projectTasks（project.readTree）= taskId → projectId 归属补充；
/// - currentTasks（活跃工作区合并卡）= 全局索引未就绪时的有限兜底。
///
/// 首页只消费合成后的任务行，不再让同一个导航控件在“工作区/项目”
/// 两种实体间跳变。窗口外项目不作为实时任务混入首页；它们仍经新建
/// 选择器/项目 intent 打开。
enum TaskHomeMode { recent, projects }

enum TaskHomeItemKind { section, group, task, more }

class TaskHomeItem {
  final TaskHomeItemKind kind;
  final String key;
  final String title;
  final int count;
  final int running;
  final int waiting;
  final bool collapsed;
  final String? groupKey;
  final Map<String, dynamic>? task;

  const TaskHomeItem._({
    required this.kind,
    required this.key,
    required this.title,
    this.count = 0,
    this.running = 0,
    this.waiting = 0,
    this.collapsed = false,
    this.groupKey,
    this.task,
  });

  factory TaskHomeItem.section(String key, String title, int count) =>
      TaskHomeItem._(
        kind: TaskHomeItemKind.section,
        key: 'section:$key',
        title: title,
        count: count,
      );

  factory TaskHomeItem.group({
    required String key,
    required String title,
    required int count,
    required int running,
    required int waiting,
    required bool collapsed,
  }) => TaskHomeItem._(
    kind: TaskHomeItemKind.group,
    key: 'group:$key',
    title: title,
    count: count,
    running: running,
    waiting: waiting,
    collapsed: collapsed,
    groupKey: key,
  );

  factory TaskHomeItem.task(Map<String, dynamic> task) => TaskHomeItem._(
    kind: TaskHomeItemKind.task,
    key: 'task:${task['taskId']}',
    title: '${task['title'] ?? ''}',
    task: task,
  );

  /// 项目组“再显示/全部展开”入口；count=尚未显示的任务数。
  factory TaskHomeItem.more(String groupKey, int remaining) => TaskHomeItem._(
    kind: TaskHomeItemKind.more,
    key: 'more:$groupKey',
    title: 'more',
    count: remaining,
    groupKey: groupKey,
  );
}

/// 从当前卡合成兜底任务行（仅全局任务索引未返回时使用）。
Map<String, dynamic> taskHomeCardRow(
  TaskCardData card,
  Map<String, dynamic> activeWorkspace,
) => {
  'taskId': card.sessionId,
  'title': card.title,
  'displayStatus': card.phase,
  'updatedAt': card.lastActivityAt,
  'createdAt': card.createdAt,
  'pinned': card.pinned,
  'unreadAt': card.unread ? 1 : null,
  'hasBackgroundWork': card.hasBackgroundWork,
  if (card.offPeakTaskId != null) 'offPeakTaskId': card.offPeakTaskId,
  if (card.workflowRuns.isNotEmpty) 'workflowRuns': card.workflowRuns,
  if (taskWorkspaceKey(activeWorkspace) != null)
    'workspacePath': activeWorkspace['workspacePath'],
  if (activeWorkspace['workspaceIdentity'] != null)
    'workspaceIdentity': activeWorkspace['workspaceIdentity'],
  if (activeWorkspace['label'] != null)
    'workspaceLabel': activeWorkspace['label'],
};

/// 主页任务行 → 任务操作菜单所需的 TaskCardData（置顶/重命名/归档等
/// 复用 _showTaskActions，不再为首页另写一套菜单）。
TaskCardData taskHomeEntry(Map<String, dynamic> task) {
  final pending = task['pendingInteraction'];
  return TaskCardData(
    sessionId: '${task['taskId'] ?? ''}',
    title: '${task['title'] ?? ''}',
    phase:
        '${task['homeStatus'] ?? normalizePhase('${task['displayStatus'] ?? task['status'] ?? ''}')}',
    preview: firstSearchSnippet(task),
    lastActivityAt:
        intOf(task['homeUpdatedAt']) ?? intOf(task['updatedAt']) ?? 0,
    createdAt: intOrZero(task['createdAt']),
    pinned: task['homePinned'] == true || task['pinned'] == true,
    hasBackgroundWork: task['hasBackgroundWork'] == true,
    offPeakTaskId: task['offPeakTaskId'] is String
        ? task['offPeakTaskId'] as String
        : null,
    workflowRuns: [
      for (final r in (task['workflowRuns'] as List? ?? const []))
        if (r is Map) r.cast<String, dynamic>(),
    ],
    // 守卫：本文件其余字段全部插值容错，唯此处
    // 硬 cast——非 String 形态（num/bool/map）直接 TypeError 崩长按菜单。
    goalStatus: task['goalStatus'] is String
        ? task['goalStatus'] as String
        : null,
    unread: task['unread'] == true || task['unreadAt'] != null,
    pendingInteraction: pending is Map ? pending.cast<String, dynamic>() : null,
    historical: task['historical'] == true,
  );
}

/// 离线/恢复中预览的状态清洗：缓存里的 running/waiting 只是上次现场，
/// 不得冒充当前仍在运行。持久终态 completed/error 保留；实时数据到达后
/// 由 workspaceTasks 重新覆盖。
List<Map<String, dynamic>> sanitizeTaskHomePreviewRows(
  List<Map<String, dynamic>> rows,
) => [
  for (final t in rows)
    if (_isRunning(t) || _isWaiting(t))
      ({...t})
        ..['homeStatus'] = 'idle'
        ..['displayStatus'] = 'idle'
        ..['status'] = 'idle'
        ..['pendingInteraction'] = null
    else
      t,
];

//任务行的工作区展示名（/ 收敛单源）：
/// 显式 label > identity/path 尾段 > 「其他工作区」兜底。
/// 供任务主页分组、跨工作区/搜索卡副标题共用（此前三份实现细节漂移）。
String taskRowWorkspaceLabel(Map<String, dynamic> task) {
  final explicit = '${task['workspaceLabel'] ?? ''}'.trim();
  if (explicit.isNotEmpty) return explicit;
  final path = '${task['workspaceIdentity'] ?? task['workspacePath'] ?? ''}'
      .trim();
  if (path.isEmpty) return '其他工作区';
  final parts = path
      .replaceAll('\\', '/')
      .split('/')
      .where((p) => p.isNotEmpty)
      .toList();
  return parts.isEmpty ? path : parts.last;
}

/// 相对时间（ 收敛单源）：任务卡/紧凑行/归档行共用
/// （archived 页原第二份实现不支持注入 now，游览钉时钟覆盖不一致）。
String taskHomeRelativeTime(int millis, {DateTime? now}) {
  if (millis <= 0) return '';
  final diff = (now ?? DateTime.now()).millisecondsSinceEpoch - millis;
  if (diff < 60 * 1000) return '刚刚'; // 含时钟回拨的负值（归档页原实现口径）
  if (diff < 60 * 60 * 1000) return '${diff ~/ (60 * 1000)} 分钟前';
  if (diff < 24 * 60 * 60 * 1000) return '${diff ~/ (60 * 60 * 1000)} 小时前';
  return '${diff ~/ (24 * 60 * 60 * 1000)} 天前';
}

/// 合成首页任务行：保留实时状态，补项目归属/分组/上下文名。
///
/// 只以 workspaceTasks 为主集；其尚未返回时才用 currentTasks 兜底。
/// projectTasks 不额外添加窗口外任务，避免把无实时源的历史任务伪装成
/// 当前活跃主页内容。
List<Map<String, dynamic>> prepareTaskHomeRows({
  required List<Map<String, dynamic>> workspaceTasks,
  required List<Map<String, dynamic>> projectTasks,
  required List<Map<String, dynamic>> projects,
  List<Map<String, dynamic>> currentTasks = const [],
}) {
  final projectByTaskId = <String, Map<String, dynamic>>{
    for (final t in projectTasks)
      if ('${t['taskId'] ?? ''}'.isNotEmpty) '${t['taskId']}': t,
  };
  final projectOrder = <String, int>{};
  final projectNames = <String, String>{};
  var order = 0;
  for (final p in projects) {
    final id = '${p['id'] ?? ''}';
    if (id.isEmpty || id == conversationsPseudoProjectId) continue;
    projectOrder[id] = order++;
    projectNames[id] = '${p['name'] ?? ''}'.trim();
  }

  final base = workspaceTasks.isNotEmpty ? workspaceTasks : currentTasks;
  final out = <Map<String, dynamic>>[];
  for (final raw in base) {
    final id = '${raw['taskId'] ?? ''}';
    if (id.isEmpty || raw['archived'] == true) continue;
    final meta = projectByTaskId[id];
    final hasProjectFact =
        raw.containsKey('projectId') ||
        (meta != null && meta.containsKey('projectId'));
    final projectId = hasProjectFact
        ? '${raw['projectId'] ?? meta?['projectId'] ?? ''}'.trim()
        : null;

    late final String groupKey;
    late final String groupTitle;
    late final int groupOrder;
    if (projectId != null && projectId.isNotEmpty) {
      groupKey = 'project:$projectId';
      groupTitle = projectNames[projectId]?.isNotEmpty == true
          ? projectNames[projectId]!
          : '未命名项目';
      groupOrder = projectOrder[projectId] ?? 8000;
    } else if (projectId != null) {
      // readTree 明确 projectId=null：官方「任务」未归类区，不是“未知”。
      groupKey = 'conversations';
      groupTitle = '任务';
      groupOrder = 10000;
    } else {
      // 归属尚未到达：按工作区分组，不误判为无项目任务。
      final key = taskWorkspaceKey(raw) ?? id;
      groupKey = 'workspace:$key';
      groupTitle = taskRowWorkspaceLabel(raw);
      groupOrder = 9000;
    }

    final updatedAt =
        intOf(raw['updatedAt']) ??
        intOf(raw['lastActivityAt']) ??
        intOf(raw['createdAt']) ??
        0;
    final status = normalizePhase(
      '${raw['displayStatus'] ?? raw['status'] ?? ''}',
    );
    out.add({
      ...raw,
      'taskId': id,
      'homeStatus': status,
      'homeUpdatedAt': updatedAt,
      'homePinned': raw['pinned'] == true,
      'homeGroupKey': groupKey,
      'homeGroupTitle': groupTitle,
      'homeGroupOrder': groupOrder,
      // 最近视图副标题=项目/任务/工作区上下文，不再是原始目录噪音。
      'workspaceLabel': groupTitle,
      'homeContextLabel': groupTitle,
    });
  }
  return out;
}

bool _isRunning(Map<String, dynamic> t) =>
    isRunningPhase('${t['homeStatus'] ?? ''}');

bool _isWaiting(Map<String, dynamic> t) =>
    t['homeStatus'] == 'waiting' || t['pendingInteraction'] != null;

int _updated(Map<String, dynamic> t) => intOrZero(t['homeUpdatedAt']);

/// 日期分档顺序（buildTaskHomeItems 消费）。
/// 验收#9（优化意见 D，用户拍板）：从官方九档简化回四组——
/// 今天/昨天/本周/以前（用户明确表示不需要上周/本月/上月/更早细分，
/// 偏离官方口径）。教训延续：档键必须与
/// taskHomeTimeBucket 返回值逐字相等。
const kTaskHomeTimeBuckets = ['今天', '昨天', '本周', '以前'];

/// 最近视图时间桶的组键前缀（优化批 #13）：与项目组共用
/// collapsedGroups / groupVisibleCounts / fullyExpandedGroups 机制，
/// 折叠键经 UiPrefs.homeCollapsedGroups 持久化。
const kTaskHomeRecentGroupPrefix = 'recent:';

/// 最近视图默认全展的近两日档（优化批 #13 近四日； 四组化后前天/
/// 3 天前并入本周）：单日任务量天然少，无需渐进披露；本周/以前档量大
/// （「以前」可达 100+ 条），默认 5 条渐进。
const kTaskHomeRecentFullBuckets = {'今天', '昨天'};

/// 组渐进披露默认可见条数（优化批 #13）。返回 -1=默认全展（最近视图
/// 近两日档）；项目组=3（设计定稿 3–5 档）；最近视图
/// 本周/以前档=5。
int taskHomeGroupDefaultVisible(String groupKey) {
  if (groupKey.startsWith(kTaskHomeRecentGroupPrefix)) {
    return kTaskHomeRecentFullBuckets.contains(
          groupKey.substring(kTaskHomeRecentGroupPrefix.length),
        )
        ? -1
        : 5;
  }
  return 3;
}

/// 验收#9（优化意见 D）：四组口径（用户拍板，取代 官方八档
/// 精确口径）——今天/昨天/本周（本周=同 ISO 自然周，不含今昨）/
/// 以前（更早全部）。
String taskHomeTimeBucket(int updatedAt, DateTime now) {
  if (updatedAt <= 0) return '以前';
  final date = DateTime.fromMillisecondsSinceEpoch(updatedAt);
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(date.year, date.month, date.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return '今天';
  if (diff == 1) return '昨天';
  final weekDay = now.weekday; // 1=周一
  final startOfThisWeek = today.subtract(Duration(days: weekDay - 1));
  if (!day.isBefore(startOfThisWeek)) return '本周';
  return '以前';
}

/// 将合成行展开为懒构建列表项。置顶任务只出现一次；普通区分组内均
/// 按最近活跃倒序。项目组顺序=sidebarProjects（含用户本地手动排序），
/// 未知工作区居中，「任务」恒尾。
List<TaskHomeItem> buildTaskHomeItems({
  required List<Map<String, dynamic>> rows,
  required TaskHomeMode mode,
  required Set<String> collapsedGroups,
  required DateTime now,
  Map<String, int> groupVisibleCounts = const {},
  Set<String> fullyExpandedGroups = const {},
}) {
  // （2026-10-29 审查）：官方排序=running-first+updated
  // （运行层禁 updated 决胜）——此前纯 updatedAt，运行中任务会被新完成
  // 的旧任务顶下去；taskId 决胜保证推送重放不换位（Dart List.sort 非稳定）。
  int byRecent(a, b) {
    final ar = _isRunning(a);
    final br = _isRunning(b);
    if (ar != br) return ar ? -1 : 1;
    final byTime = _updated(b).compareTo(_updated(a));
    if (byTime != 0) return byTime;
    return '${a['taskId'] ?? ''}'.compareTo('${b['taskId'] ?? ''}');
  }

  final pinned = rows.where((t) => t['homePinned'] == true).toList()
    ..sort(byRecent);
  final normal = rows.where((t) => t['homePinned'] != true).toList();
  final items = <TaskHomeItem>[];
  if (pinned.isNotEmpty) {
    items.add(TaskHomeItem.section('pinned', '已置顶', pinned.length));
    items.addAll(pinned.map(TaskHomeItem.task));
  }

  if (mode == TaskHomeMode.recent) {
    normal.sort(byRecent);
    for (final bucket in kTaskHomeTimeBuckets) {
      final group = normal
          .where((t) => taskHomeTimeBucket(_updated(t), now) == bucket)
          .toList();
      if (group.isEmpty) continue;
      // 优化批 #13：时间桶=可折叠组（与项目组同机制同组件）——折叠键
      // recent:桶名，经 UiPrefs.homeCollapsedGroups 持久化；周/月/更早
      // 档渐进披露（默认 5），近四日档全展。
      final key = '$kTaskHomeRecentGroupPrefix$bucket';
      final collapsed = collapsedGroups.contains(key);
      items.add(
        TaskHomeItem.group(
          key: key,
          title: bucket,
          count: group.length,
          running: group.where(_isRunning).length,
          waiting: group.where(_isWaiting).length,
          collapsed: collapsed,
        ),
      );
      if (!collapsed) {
        final visible = _resolveGroupVisible(
          key: key,
          group: group,
          groupVisibleCounts: groupVisibleCounts,
          fullyExpandedGroups: fullyExpandedGroups,
        );
        items.addAll(group.take(visible).map(TaskHomeItem.task));
        final remaining = group.length - visible;
        if (remaining > 0) items.add(TaskHomeItem.more(key, remaining));
      }
    }
    return items;
  }

  final groups = <String, List<Map<String, dynamic>>>{};
  for (final t in normal) {
    (groups['${t['homeGroupKey']}'] ??= []).add(t);
  }
  final keys = groups.keys.toList()
    ..sort((a, b) {
      final ao = (groups[a]!.first['homeGroupOrder'] as num).toInt();
      final bo = (groups[b]!.first['homeGroupOrder'] as num).toInt();
      if (ao != bo) return ao.compareTo(bo);
      return '${groups[a]!.first['homeGroupTitle']}'.compareTo(
        '${groups[b]!.first['homeGroupTitle']}',
      );
    });
  for (final key in keys) {
    final group = groups[key]!..sort(byRecent);
    final first = group.first;
    final collapsed = collapsedGroups.contains(key);
    items.add(
      TaskHomeItem.group(
        key: key,
        title: '${first['homeGroupTitle']}',
        count: group.length,
        running: group.where(_isRunning).length,
        waiting: group.where(_isWaiting).length,
        collapsed: collapsed,
      ),
    );
    if (!collapsed) {
      final visible = _resolveGroupVisible(
        key: key,
        group: group,
        groupVisibleCounts: groupVisibleCounts,
        fullyExpandedGroups: fullyExpandedGroups,
      );
      items.addAll(group.take(visible).map(TaskHomeItem.task));
      final remaining = group.length - visible;
      if (remaining > 0) items.add(TaskHomeItem.more(key, remaining));
    }
  }
  return items;
}

/// 组内当前应显示的条数：显式全部展开 > groupVisibleCounts（再显示累计）
/// > 组默认档（项目组 3；最近视图周/月/更早 5；近四日全展）。
int _resolveGroupVisible({
  required String key,
  required List<Map<String, dynamic>> group,
  required Map<String, int> groupVisibleCounts,
  required Set<String> fullyExpandedGroups,
}) {
  if (fullyExpandedGroups.contains(key)) return group.length;
  final defaults = taskHomeGroupDefaultVisible(key);
  if (defaults < 0) return group.length;
  return (groupVisibleCounts[key] ?? defaults).clamp(0, group.length);
}
