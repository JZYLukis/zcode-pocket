import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/transport/project_tree.dart';
import 'package:zcode_pocket/ui/task_home.dart';

/// 项目栏优化 B 方案纯视图模型红绿：默认最近/置顶不重复/项目分组与
/// 状态计数/归属未到达不误判/全局索引未就绪时的有限兜底。
void main() {
  final now = DateTime(2026, 10, 26, 12);
  int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;

  final projects = <Map<String, dynamic>>[
    {'id': 'p2', 'name': '示例项目B'},
    {'id': 'p1', 'name': '示例项目A'},
    conversationsPseudoProject(),
  ];
  final projectTasks = <Map<String, dynamic>>[
    {'taskId': 't1', 'projectId': 'p1'},
    {'taskId': 't2', 'projectId': 'p2'},
    {'taskId': 't3', 'projectId': null},
    {'taskId': 't4', 'projectId': 'p1'},
  ];

  Map<String, dynamic> row(
    String id,
    String title,
    int updatedAt, {
    String status = 'completed',
    bool pinned = false,
    bool archived = false,
    String? workspacePath,
  }) => {
    'taskId': id,
    'title': title,
    'updatedAt': updatedAt,
    'displayStatus': status,
    'pinned': pinned,
    'archived': archived,
    'workspacePath': workspacePath ?? r'D:\示例工作区\default',
  };

  List<Map<String, dynamic>> workspaceRows() => [
    row('t1', '今天运行任务', ago(const Duration(minutes: 30)), status: 'running', workspacePath: r'D:\示例项目A'),
    row('t2', '昨天待处理任务', ago(const Duration(hours: 26)), status: 'waiting', workspacePath: r'D:\示例项目B'),
    row('t3', '今天无项目任务', ago(const Duration(hours: 2))),
    row('t4', '置顶完成任务', ago(const Duration(days: 3)), pinned: true, workspacePath: r'D:\示例项目A'),
    row('t5', '归档任务', ago(const Duration(days: 1)), archived: true),
  ];

  List<Map<String, dynamic>> prepared() => prepareTaskHomeRows(
    workspaceTasks: workspaceRows(),
    projectTasks: projectTasks,
    projects: projects,
  );

  test('合成：实时状态保留、归属补齐、归档剔除、未知归属不冒充无项目', () {
    final rows = prepared();
    expect(rows.map((t) => t['taskId']), isNot(contains('t5')));
    expect(rows.firstWhere((t) => t['taskId'] == 't1')['homeStatus'], 'running');
    expect(rows.firstWhere((t) => t['taskId'] == 't1')['homeGroupKey'], 'project:p1');
    expect(rows.firstWhere((t) => t['taskId'] == 't3')['homeGroupKey'], 'conversations');

    final unknown = prepareTaskHomeRows(
      workspaceTasks: [row('unknown', '归属未加载', ago(Duration.zero))],
      projectTasks: const [],
      projects: projects,
    );
    expect(unknown.single['homeGroupKey'], startsWith('workspace:'),
        reason: 'readTree 未返回归属≠官方 projectId=null 无项目任务');
  });

  test('最近：置顶单独成组且不重复，今天/昨天按时间分组并倒序', () {
    final items = buildTaskHomeItems(
      rows: prepared(),
      mode: TaskHomeMode.recent,
      collapsedGroups: const {},
      now: now,
    );
    expect(items.first.title, '已置顶');
    expect(items[1].task?['taskId'], 't4');
    expect(items.where((i) => i.task?['taskId'] == 't4').length, 1,
        reason: '每个任务只出现一次');

    // 优化批 #13：时间桶=组项（可折叠），键 group:recent:桶名。
    final today = items.firstWhere((i) => i.key == 'group:recent:今天');
    expect(today.count, 2);
    final todayIndex = items.indexOf(today);
    expect(items[todayIndex + 1].task?['taskId'], 't1');
    expect(items[todayIndex + 2].task?['taskId'], 't3');
    expect(items.any((i) => i.key == 'group:recent:昨天'), isTrue);
    expect(items.any((i) => i.key == 'group:recent:本周'), isFalse,
        reason: '空时间桶不占位');
  });

  test('最近：前天/3 天前的任务不丢（A2 教训钉；18077 四组化后归本周）', () {
    final rows = prepareTaskHomeRows(
      workspaceTasks: [
        row('d2', '前天任务', ago(const Duration(days: 2))),
        row('d3', '三天前任务', ago(const Duration(days: 3))),
      ],
      projectTasks: const [],
      projects: const [],
    );
    final items = buildTaskHomeItems(
      rows: rows,
      mode: TaskHomeMode.recent,
      collapsedGroups: const {},
      now: now,
    );
    final taskIds = items
        .where((i) => i.kind == TaskHomeItemKind.task)
        .map((i) => i.task?['taskId'])
        .toList();
    expect(taskIds, containsAll(['d2', 'd3']),
        reason: '修复前：桶常量 N天前 与返回值 前天/3 天前 永不匹配=整条丢失');
    // 18077 验收#9（四组）：夹具 now=10-26 周一——前天/3 天前落上周
    // →「以前」档（不丢的核心语义：档键与返回值匹配）。
    expect(items.any((i) => i.key == 'group:recent:以前'), isTrue);
  });

  test('项目：按本地项目顺序分组，状态计数不含置顶，「任务」恒尾，折叠生效', () {
    final items = buildTaskHomeItems(
      rows: prepared(),
      mode: TaskHomeMode.projects,
      collapsedGroups: const {},
      now: now,
    );
    final groups = items.where((i) => i.kind == TaskHomeItemKind.group).toList();
    expect(groups.map((g) => g.groupKey), ['project:p2', 'project:p1', 'conversations']);
    expect(groups[0].waiting, 1);
    expect(groups[1].running, 1);
    expect(groups[1].count, 1, reason: '置顶 t4 不计入普通项目组');

    final collapsed = buildTaskHomeItems(
      rows: prepared(),
      mode: TaskHomeMode.projects,
      collapsedGroups: const {'project:p1'},
      now: now,
    );
    expect(collapsed.any((i) => i.task?['taskId'] == 't1'), isFalse);
    expect(collapsed.any((i) => i.task?['taskId'] == 't2'), isTrue);
  });

  test('全局索引未就绪才用当前卡兜底；有全局行时不混入当前卡重复项', () {
    final current = [
      {
        'taskId': 'current',
        'title': '当前卡',
        'displayStatus': 'running',
        'updatedAt': ago(Duration.zero),
        'workspacePath': r'D:\示例项目A',
      },
    ];
    final fallback = prepareTaskHomeRows(
      workspaceTasks: const [],
      projectTasks: projectTasks,
      projects: projects,
      currentTasks: current,
    );
    expect(fallback.single['taskId'], 'current');

    final authoritative = prepareTaskHomeRows(
      workspaceTasks: workspaceRows(),
      projectTasks: projectTasks,
      projects: projects,
      currentTasks: current,
    );
    expect(authoritative.any((t) => t['taskId'] == 'current'), isFalse);
  });

  test('项目组渐进展开：默认 3、再展 5、全部展开', () {
    final many = prepareTaskHomeRows(
      workspaceTasks: [
        for (var i = 0; i < 9; i++)
          row('many-$i', '长项目任务 $i', ago(Duration(minutes: i)),
              workspacePath: r'D:\示例项目A'),
      ],
      projectTasks: [
        for (var i = 0; i < 9; i++) {'taskId': 'many-$i', 'projectId': 'p1'},
      ],
      projects: projects,
    );
    List<TaskHomeItem> build({
      Map<String, int> visible = const {},
      Set<String> full = const {},
    }) => buildTaskHomeItems(
      rows: many,
      mode: TaskHomeMode.projects,
      collapsedGroups: const {},
      now: now,
      groupVisibleCounts: visible,
      fullyExpandedGroups: full,
    );

    expect(build().where((i) => i.kind == TaskHomeItemKind.task).length, 3);
    expect(build().singleWhere((i) => i.kind == TaskHomeItemKind.more).count, 6);

    final more = build(visible: const {'project:p1': 8});
    expect(more.where((i) => i.kind == TaskHomeItemKind.task).length, 8);
    expect(more.singleWhere((i) => i.kind == TaskHomeItemKind.more).count, 1);

    final all = build(full: const {'project:p1'});
    expect(all.where((i) => i.kind == TaskHomeItemKind.task).length, 9);
    expect(all.any((i) => i.kind == TaskHomeItemKind.more), isFalse);
  });

  test('最近：本周/以前档渐进披露（默认 5+再展 5+全展），近两日全展；时间桶可折叠（优化批 #13）', () {
    final rows = prepareTaskHomeRows(
      workspaceTasks: [
        // 12 条更早（2026-01，跨自然月）+ 3 条今天。
        for (var i = 0; i < 12; i++)
          row('old-$i', '更早任务 $i', DateTime(2026, 1, 10).millisecondsSinceEpoch + i * 1000),
        for (var i = 0; i < 3; i++)
          row('now-$i', '今天任务 $i', ago(Duration(minutes: i + 1))),
      ],
      projectTasks: const [],
      projects: const [],
    );
    List<TaskHomeItem> build({
      Set<String> collapsed = const {},
      Map<String, int> visible = const {},
      Set<String> full = const {},
    }) => buildTaskHomeItems(
      rows: rows,
      mode: TaskHomeMode.recent,
      collapsedGroups: collapsed,
      now: now,
      groupVisibleCounts: visible,
      fullyExpandedGroups: full,
    );

    // 以前档：默认 5 条 + more 剩 7；今天档（近两日）默认全展 3 条无 more。
    final def = build();
    final earlier = def.firstWhere((i) => i.key == 'group:recent:以前');
    expect(earlier.count, 12);
    expect(earlier.collapsed, isFalse);
    final earlierIdx = def.indexOf(earlier);
    final earlierTasks = def
        .skip(earlierIdx + 1)
        .takeWhile((i) => i.kind == TaskHomeItemKind.task)
        .toList();
    expect(earlierTasks.length, 5, reason: '以前档默认 5 条（渐进披露）');
    expect(
      def.singleWhere((i) => i.key == 'more:recent:以前').count,
      7,
      reason: '再显示入口余量=12-5',
    );
    final todayTasks = def
        .skip(def.indexOf(def.firstWhere((i) => i.key == 'group:recent:今天')) + 1)
        .takeWhile((i) => i.kind == TaskHomeItemKind.task)
        .toList();
    expect(todayTasks.length, 3, reason: '今天档默认全展（近两日不渐进）');
    expect(def.any((i) => i.key == 'more:recent:今天'), isFalse);

    // 再显示 +5 → 10 条，余 2；全部展开 → 12 条无 more。
    final more = build(visible: const {'recent:以前': 10});
    expect(
      more
          .skip(more.indexOf(more.firstWhere((i) => i.key == 'group:recent:以前')) + 1)
          .takeWhile((i) => i.kind == TaskHomeItemKind.task)
          .length,
      10,
    );
    final all = build(full: const {'recent:以前'});
    expect(
      all
          .skip(all.indexOf(all.firstWhere((i) => i.key == 'group:recent:以前')) + 1)
          .takeWhile((i) => i.kind == TaskHomeItemKind.task)
          .length,
      12,
    );
    expect(all.any((i) => i.key == 'more:recent:以前'), isFalse);

    // 折叠：collapsedGroups 含 recent:更早 → 组头在、任务与 more 全隐藏。
    final collapsed = build(collapsed: const {'recent:以前'});
    expect(
      collapsed.firstWhere((i) => i.key == 'group:recent:以前').collapsed,
      isTrue,
    );
    expect(
      collapsed.any(
        (i) =>
            i.kind == TaskHomeItemKind.task &&
            '${i.task?['taskId']}'.startsWith('old-'),
      ),
      isFalse,
      reason: '折叠时间桶不渲染桶内任务',
    );
    expect(collapsed.any((i) => i.key == 'more:recent:以前'), isFalse);
    // 今天档不受影响。
    expect(
      collapsed.any((i) => i.kind == TaskHomeItemKind.task && i.task?['taskId'] == 'now-0'),
      isTrue,
    );
  });

  test('taskHomeGroupDefaultVisible：项目组 3/近两日 -1 全展/其余时间桶 5', () {
    expect(taskHomeGroupDefaultVisible('project:p1'), 3);
    expect(taskHomeGroupDefaultVisible('conversations'), 3);
    expect(taskHomeGroupDefaultVisible('recent:今天'), -1);
    expect(taskHomeGroupDefaultVisible('recent:昨天'), -1);
    expect(taskHomeGroupDefaultVisible('recent:本周'), 5);
    expect(taskHomeGroupDefaultVisible('recent:以前'), 5);
  });

  test('时间桶：18077 四组口径（今天/昨天/本周/以前）', () {
    // 用户拍板四组（偏离官方八档）：前天/3 天前归本周，9 天前/跨月全归
    // 以前。
    // 夹具 now=10-26 周一：前天/3 天前在上周 → 以前。
    expect(taskHomeTimeBucket(ago(Duration.zero), now), '今天');
    expect(taskHomeTimeBucket(ago(const Duration(days: 1)), now), '昨天');
    expect(taskHomeTimeBucket(ago(const Duration(days: 2)), now), '以前');
    expect(taskHomeTimeBucket(ago(const Duration(days: 3)), now), '以前');
    expect(taskHomeTimeBucket(ago(const Duration(days: 9)), now), '以前',
        reason: '9 天前必在以前（四组无上周/月档）');
    expect(taskHomeTimeBucket(0, now), '以前');
    // 周三夹具：前天（周一）= startOfThisWeek → 本周归档验证。
    final mid = DateTime(2026, 10, 28, 12);
    expect(
      taskHomeTimeBucket(mid.subtract(const Duration(days: 2)).millisecondsSinceEpoch, mid),
      '本周',
    );
    expect(
      taskHomeTimeBucket(mid.subtract(const Duration(days: 4)).millisecondsSinceEpoch, mid),
      '以前',
    );
  });

  test('时间桶：跨月与周日 23:59 边界（ISO 周起点/相对日差不得被月界打断）', () {
    // 2026-11-01 是周日；now 取当日 23:59。
    final sundayLate = DateTime(2026, 11, 1, 23, 59);
    expect(
      taskHomeTimeBucket(
        DateTime(2026, 10, 31, 23, 59).millisecondsSinceEpoch,
        sundayLate,
      ),
      '昨天',
      reason: '跨月（10-31→11-01）仍是昨天',
    );
    expect(
      taskHomeTimeBucket(
        DateTime(2026, 11, 1, 0, 1).millisecondsSinceEpoch,
        sundayLate,
      ),
      '今天',
    );
    expect(
      taskHomeTimeBucket(
        DateTime(2026, 10, 26, 9).millisecondsSinceEpoch,
        sundayLate,
      ),
      '本周',
      reason: '本周一 10-26 在周日 23:59 仍属同一 ISO 自然周',
    );
    expect(
      taskHomeTimeBucket(
        DateTime(2026, 10, 25, 23, 59).millisecondsSinceEpoch,
        sundayLate,
      ),
      '以前',
      reason: '上周日 10-25 已越过本周起点',
    );
  });
}
