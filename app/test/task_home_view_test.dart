import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/project_tree.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';

class _FakeConversation implements ConversationTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _HomeBridge implements BridgeSession {
  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  Future<void> waitHealthy({Duration timeout = const Duration(seconds: 45)}) async {}
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _HomeApp extends AppState {
  @override
  bool get loaded => true;
  LinkPhase homePhase = LinkPhase.online;
  @override
  LinkPhase get phase => homePhase;
  @override
  ConversationTransport get conversation => _FakeConversation();
  @override
  String? get activeProjectId => 'p1';
  Map<String, dynamic>? _baseWs = const {
    'workspacePath': r'D:\示例项目A',
    'label': '示例项目A',
  };
  @override
  Map<String, dynamic>? get activeWorkspace => _switchedWs ?? _baseWs;

  List<Map<String, dynamic>> tasks = const [];
  @override
  List<Map<String, dynamic>> get workspaceTasks => tasks;
  @override
  List<Map<String, dynamic>> get projectTasks => tasks;
  @override
  List<Map<String, dynamic>> get unclassifiedTasks =>
      tasks.where((t) => t['projectId'] == null).toList();
  @override
  List<Map<String, dynamic>> get sidebarProjects => const [
        {'id': 'p1', 'name': '示例项目A'},
        {'id': 'p2', 'name': '示例项目B'},
        {'id': '__conversations__', 'name': '任务'},
      ];

  Completer<void>? switchCompleter;
  String? errorAfterSwitch;
  String? _workspaceError;
  @override
  String? get workspaceError => _workspaceError;
  @override
  Map<String, dynamic>? projectForKey(String key) {
    if (key.contains('A')) return {'id': 'p1', 'name': '示例项目A'};
    if (key.contains('B')) return {'id': 'p2', 'name': '示例项目B'};
    return null;
  }

  int projectSwitches = 0;
  int pinCalls = 0;
  @override
  Future<dynamic> setTaskPinned(String taskId, bool pinned) async {
    pinCalls++;
    tasks = [
      for (final t in tasks)
        if ('${t['taskId']}' == taskId) {...t, 'pinned': pinned} else t,
    ];
    notifyListeners();
  }

  // 批量操作（优化批 #22）：归档/标已读计数与列表就地剔除。
  final List<String> archivedIds = [];
  final List<String> markedReadIds = [];
  @override
  Future<dynamic> archiveTask(String taskId) async {
    archivedIds.add(taskId);
    tasks = [
      for (final t in tasks)
        if ('${t['taskId']}' != taskId) t,
    ];
    notifyListeners();
  }

  @override
  Future<dynamic> markTaskUnread(String taskId, {required bool unread}) async {
    if (!unread) markedReadIds.add(taskId);
  }

  Map<String, dynamic>? _switchedWs;
  final _fakeBridge = _HomeBridge();
  @override
  BridgeSession? get bridge => _fakeBridge;
  @override
  Future<void> switchToProject(Map<String, dynamic> project,
      {bool keepHomePreview = false}) async {
    projectSwitches++;
    homePhase = LinkPhase.connecting;
    await switchCompleter?.future;
    _workspaceError = errorAfterSwitch;
    if (_workspaceError == null) homePhase = LinkPhase.online;
    // ⑤A 等待循环：切到位（项目主根）+桥在场。
    _switchedWs = {'workspacePath': primaryRootOf(project) ?? 'project-navigation'};
    notifyListeners();
  }
}

Finder _sheetText(String text) => find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text(text),
    );

Finder _sheetTile(String text) => find.descendant(
      of: find.byType(BottomSheet),
      matching: find.widgetWithText(ListTile, text),
    );

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: const MaterialApp(home: TaskCenterPage()),
    );

Map<String, dynamic> _task(
  String id,
  String title,
  String? projectId,
  int updatedAt, {
  String status = 'completed',
  bool pinned = false,
}) => {
  'taskId': id,
  'title': title,
  'projectId': projectId,
  'updatedAt': updatedAt,
  'displayStatus': status,
  'pinned': pinned,
  'workspacePath': projectId == null
      ? r'D:\示例工作区\default'
      : projectId == 'p1'
          ? r'D:\示例项目A'
          : r'D:\示例项目B',
};

/// 早前批次（2026-10-29）：测试默认画布 800×600≥600dp 会走双栏
/// 紧凑行；本文件用例对象=窄屏卡片路径（紧凑行归 dual_pane_test）。
Future<void> _narrow(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  final now = DateTime.now().millisecondsSinceEpoch;

  List<Map<String, dynamic>> rows() => [
    _task('t1', '项目A运行任务', 'p1', now - 1000, status: 'running'),
    _task('t2', '项目B待处理任务', 'p2', now - 86400000, status: 'waiting'),
    _task('t3', '无项目任务', null, now - 2000),
    _task('t4', '项目A置顶任务', 'p1', now - 90000, pinned: true),
  ];

  // 候选 15 验收 ：run 线未读可见/已读隐藏（真机实锤常驻的是
  // WorkflowRunLines 而非 preview——三种卡变体全部加未读门）。
  testWidgets('run 线：未读任务可见 run 行，已读任务隐藏', (tester) async {
    await _narrow(tester);
    Map<String, dynamic> withRuns(Map<String, dynamic> t) => {
          ...t,
          'workflowActivity': {
            'runs': [
              {'name': '看板验收数据', 'status': 'completed'},
            ],
          },
        };
    final app = _HomeApp()
      ..tasks = [
        withRuns({
          ..._task('tr-unread', '未读带run任务', 'p1', now - 1000),
          'unreadAt': now,
        }),
        withRuns(_task('tr-read', '已读带run任务', 'p1', now - 2000)),
      ];
    await tester.pumpWidget(_host(app));
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 两个任务都在场（标题可寻）。
    expect(find.text('未读带run任务'), findsOneWidget);
    expect(find.text('已读带run任务'), findsOneWidget);
    // run 线全文只该出现一次（未读卡）；已读卡隐藏（红=仍常驻）。
    expect(find.textContaining('看板验收数据'), findsOneWidget,
        reason: '两任务同带 run——只未读卡渲染 run 线');
  });

  testWidgets('B 首页旅程：默认最近→项目分组→折叠，置顶不重复', (tester) async {
    await _narrow(tester);
    final app = _HomeApp()..tasks = rows();
    await tester.pumpWidget(_host(app));
    await tester.pump();

    expect(find.text('最近'), findsOneWidget);
    expect(find.text('已置顶 1'), findsOneWidget);
    expect(find.text('项目A运行任务'), findsOneWidget);
    expect(find.text('无项目任务'), findsOneWidget);
    expect(find.text('项目A置顶任务'), findsOneWidget);

    await tester.tap(find.text('项目'));
    await tester.pump();
    expect(find.byKey(const ValueKey('home-group:project:p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-group:project:p2')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-group:conversations')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home-group:project:p1')));
    await tester.pump();
    expect(find.text('项目A运行任务'), findsNothing,
        reason: '折叠普通项目组后隐藏组内任务');
    expect(find.text('项目A置顶任务'), findsOneWidget,
        reason: '置顶区独立，不随项目组折叠');
  });

  testWidgets('新建选择器：当前项目去重，搜索项目/空结果', (tester) async {
    await _narrow(tester);
    final app = _HomeApp()..tasks = rows();
    await tester.pumpWidget(_host(app));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('new-session')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(_sheetText('当前工作区'), findsOneWidget);
    expect(_sheetText('示例项目A'), findsOneWidget,
        reason: '当前项目只作为当前工作区副标题出现，不重复列项目行');
    expect(_sheetTile('示例项目B'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('new-task-project-search')),
      '示例项目B',
    );
    await tester.pump();
    expect(_sheetTile('示例项目B'), findsOneWidget);
    expect(_sheetText('当前工作区'), findsNothing);
    expect(find.text('无项目对话'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('new-task-project-search')),
      '不存在的项目',
    );
    await tester.pump();
    expect(_sheetText('没有匹配的项目'), findsOneWidget);
  });

  testWidgets('跨项目打开任务不闪连接中，保留首页直到进入会话', (tester) async {
    await _narrow(tester);
    final app = _HomeApp()
      ..tasks = rows()
      ..switchCompleter = Completer<void>();
    await tester.pumpWidget(_host(app));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('cross-task-card-t2')));
    await tester.pump();
    expect(find.byKey(const ValueKey('home-stale-strip')), findsNothing,
        reason: '导航等待期间不得先闪“恢复中/连接中”状态');
    expect(find.text('正在连接工作区…'), findsNothing);

    app.switchCompleter!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('项目B待处理任务'), findsWidgets,
        reason: '切换完成后才进入目标会话');
  });

  testWidgets('非在线有缓存时保留首页，运行态清洗且明确恢复中', (tester) async {
    await _narrow(tester);
    final app = _HomeApp()
      ..tasks = rows()
      ..homePhase = LinkPhase.connecting;
    await tester.pumpWidget(_host(app));
    await tester.pump();

    expect(find.byKey(const ValueKey('home-stale-strip')), findsOneWidget);
    expect(find.text('项目A运行任务'), findsOneWidget,
        reason: '连接恢复中不得把已有首页整屏替换为转圈');
    expect(find.text('运行中'), findsNothing,
        reason: '缓存 running 不得冒充当前仍运行');
    expect(find.text('空闲'), findsWidgets);
  });

  testWidgets('invalid 终态即使有缓存也不伪装可用首页', (tester) async {
    await _narrow(tester);
    final app = _HomeApp()
      ..tasks = rows()
      ..homePhase = LinkPhase.invalid;
    await tester.pumpWidget(_host(app));
    await tester.pump();

    expect(find.byKey(const ValueKey('home-stale-strip')), findsNothing);
    expect(find.text('项目A运行任务'), findsNothing);
  });

  testWidgets('长按恢复任务菜单，置顶文案随状态切换', (tester) async {
    await _narrow(tester);
    final app = _HomeApp()..tasks = rows();
    await tester.pumpWidget(_host(app));
    await tester.pump();

    Future<void> openMenu() async {
      await tester.longPress(find.byKey(const ValueKey('cross-task-card-t1')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    await openMenu();
    expect(find.text('置顶'), findsOneWidget);
    await tester.tap(find.text('置顶'));
    await tester.pump();
    expect(app.pinCalls, 1);
    expect(app.projectSwitches, 0,
        reason: '当前项目长按不再切工作区，直接对任务操作');
    expect(
      app.tasks.firstWhere((t) => t['taskId'] == 't1')['pinned'],
      isTrue,
    );

    await openMenu();
    expect(find.text('取消置顶'), findsOneWidget,
        reason: '已置顶任务必须显示取消置顶，不再固定写「置顶/取消置顶」');
  });

  testWidgets('剩余超过 5 条时同时提供再显示与全部展开', (tester) async {
    await _narrow(tester);
    final app = _HomeApp()
      ..tasks = [
        for (var i = 0; i < 10; i++)
          _task('many-$i', '长项目任务 $i', 'p1', now - i * 1000),
      ];
    await tester.pumpWidget(_host(app));
    await tester.pump();
    await tester.tap(find.text('项目'));
    await tester.pump();

    expect(find.byKey(const ValueKey('home-show-more-project:p1')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-expand-all-project:p1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('home-expand-all-project:p1')));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('长项目任务 9'), 120);
    expect(find.text('长项目任务 9'), findsOneWidget);
  });

  testWidgets('新建搜索时键盘不遮项目选项（viewInsets 透传）', (tester) async {
    // 本用例自管画布（375×806+键盘 viewInsets），不走 _narrow。
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _HomeApp()..tasks = rows();
    await tester.pumpWidget(_host(app));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('new-session')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.enterText(
      find.byKey(const ValueKey('new-task-project-search')),
      '示例项目B',
    );
    await tester.pump();

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(() => tester.view.viewInsets = FakeViewPadding.zero);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final rect = tester.getRect(_sheetTile('示例项目B'));
    expect(rect.bottom, lessThanOrEqualTo(806 - 300),
        reason: '项目选项必须整体位于输入法上方（此前会被键盘遮住）');
  });

  testWidgets('切换等待可取消：取消后即使开桥完成也不再进入新会话', (tester) async {
    await _narrow(tester);
    final app = _HomeApp()
      ..tasks = rows()
      ..switchCompleter = Completer<void>();
    await tester.pumpWidget(_host(app));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('new-session')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(_sheetTile('示例项目B'));
    await tester.pump();

    expect(find.byKey(const ValueKey('new-task-switch-cancel')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('new-task-switch-cancel')));
    await tester.pump();
    app.switchCompleter!.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(app.projectSwitches, 1);
    expect(find.text('新会话'), findsNothing,
        reason: '取消只放弃进入草稿；后台切换完成不得再擅自导航');
  });

  testWidgets('切换失败留在主页并提示，不进入新会话', (tester) async {
    await _narrow(tester);
    final app = _HomeApp()
      ..tasks = rows()
      ..errorAfterSwitch = '打开工作区失败：模拟';
    await tester.pumpWidget(_host(app));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('new-session')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(_sheetTile('示例项目B'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.textContaining('工作区切换未完成'), findsOneWidget);
    expect(find.text('新会话'), findsNothing);
  });

  testWidgets('项目组默认 3 条，再显示 5 个后全部出现', (tester) async {
    await _narrow(tester);
    final app = _HomeApp()
      ..tasks = [
        for (var i = 0; i < 8; i++)
          _task('many-$i', '长项目任务 $i', 'p1', now - i * 1000),
      ];
    await tester.pumpWidget(_host(app));
    await tester.pump();
    await tester.tap(find.text('项目'));
    await tester.pump();

    expect(find.text('长项目任务 0'), findsOneWidget);
    expect(find.text('长项目任务 2'), findsOneWidget);
    expect(find.text('长项目任务 3'), findsNothing);
    expect(find.byKey(const ValueKey('home-show-more-project:p1')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home-show-more-project:p1')));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('长项目任务 7'), 120);
    expect(find.text('长项目任务 7'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-show-more-project:p1')), findsNothing);
  });

  testWidgets('时间桶可折叠+周月档渐进披露（优化批 #13）', (tester) async {
    await _narrow(tester);
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final app = _HomeApp()
      ..tasks = [
        // 8 条更早（120-127 天前，远离自然周月边界必落「更早」）+ 1 条今天。
        for (var i = 0; i < 8; i++)
          _task('old-$i', '更早任务 $i', 'p1', nowMs - (120 + i) * 86400000),
        _task('today-0', '今天任务', 'p1', nowMs - 60000),
      ];
    await tester.pumpWidget(_host(app));
    await tester.pump();

    // 更早档组头在场且默认只显示 5 条 + 再显示入口。
    expect(find.byKey(const ValueKey('home-group:recent:以前')), findsOneWidget);
    expect(find.text('更早任务 0'), findsOneWidget);
    expect(find.text('更早任务 4'), findsOneWidget);
    expect(find.text('更早任务 5'), findsNothing, reason: '更早档默认 5 条');
    expect(
      find.byKey(const ValueKey('home-show-more-recent:以前')),
      findsOneWidget,
    );

    // 点组头折叠：桶内任务与再显示入口全部隐藏。
    await tester.tap(find.byKey(const ValueKey('home-group:recent:以前')));
    await tester.pump();
    expect(find.text('更早任务 0'), findsNothing, reason: '折叠时间桶隐藏任务');
    expect(
      find.byKey(const ValueKey('home-show-more-recent:以前')),
      findsNothing,
    );
    expect(find.text('今天任务'), findsOneWidget, reason: '今天档不受影响');

    // 再点展开恢复。
    await tester.tap(find.byKey(const ValueKey('home-group:recent:以前')));
    await tester.pump();
    expect(find.text('更早任务 0'), findsOneWidget);
  });


  testWidgets('验收#10（Bug E）：跨项目任务长按弹菜单不切工作区，动作执行时才切', (tester) async {
    await _narrow(tester);
    final app = _HomeApp()..tasks = rows();
    await tester.pumpWidget(_host(app));
    await tester.pump();

    // 项目B任务（跨项目：workspacePath=B ≠ 活动工作区A）。
    await tester.longPress(find.byKey(const ValueKey('cross-task-card-t2')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('置顶'), findsOneWidget, reason: '菜单已弹出');
    expect(app.projectSwitches, 0,
        reason: 'Bug E：弹菜单零副作用（修前先切工作区→首页重建跳回最近）');

    // 动作执行时才切（zcodeTask RPC 带所属工作区 scope）。
    await tester.tap(find.text('置顶'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(app.projectSwitches, 1,
        reason: '动作执行前的归属护栏');
    expect(app.pinCalls, 1);
  });

  testWidgets('批量操作：长按进入多选→选 2 条→归档→退出（优化批 #22）', (tester) async {
    await _narrow(tester);
    final app = _HomeApp()..tasks = rows();
    await tester.pumpWidget(_host(app));
    await tester.pump();

    // 长按 t1 → 菜单首项「选择任务」。
    await tester.longPress(find.byKey(const ValueKey('cross-task-card-t1')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byKey(const ValueKey('task-action-select-tasks')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('task-action-select-tasks')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 多选栏出现；长按项自动入选（已选 1 个）。
    expect(find.byKey(const ValueKey('multi-select-bar')), findsOneWidget);
    expect(find.text('已选 1 个'), findsOneWidget);
    // t1 行首=实心勾选圈（选中），t2=空心圈（未选）。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('cross-task-card-t1')),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('cross-task-card-t2')),
        matching: find.byIcon(Icons.circle_outlined),
      ),
      findsOneWidget,
    );

    // 多选模式下点按 t2=切换选中（不打开会话）。
    await tester.tap(find.byKey(const ValueKey('cross-task-card-t2')));
    await tester.pump();
    expect(find.text('已选 2 个'), findsOneWidget);
    expect(find.byType(ConversationPage), findsNothing,
        reason: '多选模式点行=切换选中，不进会话');

    // 归档： 优化意见 F——先出二次确认，确认后才执行。
    await tester.tap(find.byKey(const ValueKey('multi-archive')));
    await tester.pump();
    expect(find.text('归档选中的 2 个任务？'), findsOneWidget,
        reason: '批量归档须二次确认（优化意见 F）');
    await tester.tap(find.text('归档').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(app.archivedIds, containsAll(['t1', 't2']),
        reason: '选中两条均逐条归档');
    expect(app.archivedIds.length, 2);
    expect(find.byKey(const ValueKey('multi-select-bar')), findsNothing,
        reason: '批量操作完成退出多选');
    expect(find.text('已归档 2 个'), findsOneWidget);
    expect(find.text('项目A运行任务'), findsNothing, reason: '归档后列表剔除');
    expect(find.text('项目B待处理任务'), findsNothing);
    expect(find.text('无项目任务'), findsOneWidget, reason: '未选中任务不受影响');
  });

  testWidgets('批量标已读与取消退出多选（优化批 #22）', (tester) async {
    await _narrow(tester);
    final app = _HomeApp()..tasks = rows();
    await tester.pumpWidget(_host(app));
    await tester.pump();

    // t1/t2 属当前工作区（fake 的 p1/p2 可达）；t3 在第三工作区不可切换，
    // 批量语义见 _runBatchOp 的失败收集——本用例聚焦取消与标已读主路径。
    Future<void> enterVia(String id) async {
      await tester.longPress(find.byKey(ValueKey('cross-task-card-$id')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('task-action-select-tasks')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    await enterVia('t1');
    await tester.tap(find.byKey(const ValueKey('cross-task-card-t2')));
    await tester.pump();
    expect(find.text('已选 2 个'), findsOneWidget);

    // 取消：退出多选且不产生任何 RPC。
    await tester.tap(find.byKey(const ValueKey('multi-cancel')));
    await tester.pump();
    expect(find.byKey(const ValueKey('multi-select-bar')), findsNothing);
    expect(app.markedReadIds, isEmpty);
    expect(app.archivedIds, isEmpty);

    // 再次进入并批量标已读（同款二次确认）。
    await enterVia('t1');
    await tester.tap(find.byKey(const ValueKey('multi-mark-read')));
    await tester.pump();
    expect(find.text('将选中的 1 个任务标为已读？'), findsOneWidget);
    await tester.tap(find.text('标为已读').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(app.markedReadIds, ['t1']);
    expect(find.text('已标为已读 1 个'), findsOneWidget);
    expect(find.byKey(const ValueKey('multi-select-bar')), findsNothing);
  });
  // B 批（2026-11-08 拍板①⑤）：闲时月亮标+后台工作小点。
  testWidgets('任务卡闲时月亮+后台点（offPeakTaskId/hasBackgroundWork）',
      (tester) async {
    // 窄屏走 _TaskCard（宽屏是紧凑行，月亮在其图标槽）。
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _HomeApp();
    app.tasks = [
      {
        ..._task('t-offpeak', '闲时整理', 'p1', now - 2000, status: 'idle'),
        'offPeakTaskId': 'op-1',
      },
      {
        ..._task('t-bg', '后台构建', 'p1', now - 3000, status: 'idle'),
        'hasBackgroundWork': true,
      },
    ];
    await tester.pumpWidget(_host(app));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 闲时任务=月亮（bedtime）。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('cross-task-card-t-offpeak')),
        matching: find.byIcon(Icons.bedtime_outlined),
      ),
      findsOneWidget,
      reason: 'B 批拍板⑤：offPeakTaskId → 月亮标（官方 TaskListItem 对位）',
    );
    // 后台工作=运行色小点（running 态自身有 spinner，idle 态才出点）。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('cross-task-card-t-bg')),
        matching: find.byIcon(Icons.bedtime_outlined),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

}
