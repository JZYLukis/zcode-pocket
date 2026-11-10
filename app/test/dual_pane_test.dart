import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/task_list.dart';
import 'package:zcode_pocket/transport/project_tree.dart'
    show conversationsPseudoProjectId;
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';

/// 6.5 展开态双栏（2026-10-29 批次首版，用户拍板：仿桌面端布局——窄
/// 左栏任务列表+右侧大任务窗口；fold-dual-pane-2：左栏宽度比例化收窄
/// （34% 夹 232~320dp）+任务行改官方桌面侧栏式紧凑单行「小标题+相对
/// 时间」，状态压进图标槽，选中=整行填充）：宽屏（≥600dp）点任务=右栏
/// 就地打开不跳页、返回键先收右栏、切工作区自动失效；窄屏（<600dp）
/// 保持卡片与整页推入原行为。

class _DualPaneApp extends AppState {
  _DualPaneApp({
    List<Map<String, dynamic>>? tasks,
    this.workspaceTasksOverride,
    List<Map<String, dynamic>>? workspaces,
  })  : _tasks = tasks ??
            [
              {
                'taskId': 't-1',
                'title': '示例任务',
                'status': 'completed',
                'updatedAt': 2000,
                'workspaceIdentity': 'ws-a',
              },
            ],
        _workspaces = workspaces ??
            const [
              {'workspaceIdentity': 'ws-a', 'workspacePath': 'D:/示例项目A'},
            ] {
    model.applyChannelLists(
      active: _tasks,
      pinnedIds: const [],
      archivedIds: const [],
    );
  }
  final List<Map<String, dynamic>> _tasks;

  /// 跨工作区行夹具（官方 workspace-list 全量任务）；缺省=空（沿用
  /// 当前卡兜底路径，既有用例不受影响）。
  final List<Map<String, dynamic>>? workspaceTasksOverride;

  final List<Map<String, dynamic>> _workspaces;
  Map<String, dynamic> _activeWs = const {
    'workspaceIdentity': 'ws-a',
    'workspacePath': 'D:/示例项目A',
  };

  @override
  LinkPhase get phase => LinkPhase.online;
  @override
  ConversationTransport get conversation => _FakeConv();
  @override
  String? get activeProjectId => conversationsPseudoProjectId;
  @override
  Map<String, dynamic>? get activeWorkspace => _activeWs;
  @override
  List<Map<String, dynamic>> get workspaces => _workspaces;
  @override
  List<Map<String, dynamic>> get workspaceTasks =>
      workspaceTasksOverride ?? const [];

  /// 跨工作区切换延迟一帧以上：模拟「先设右栏选中→await 切工作区」的
  /// 真实窗口（对抗审查高①的失效窗口）。
  @override
  Future<void> switchWorkspace(
    Map<String, dynamic> workspace, {
    bool keepHomePreview = false,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    _activeWs = workspace;
    notifyListeners();
  }

  final _fakeBridge = _FakeBridgeSession();
  @override
  BridgeSession? get bridge => _fakeBridge;

  late final SessionsIndexState _si = SessionsIndexState()..ready = true;
  late final TaskListModel model = TaskListModel(
    sessions: _si,
    workspaceKey: 'ws-a',
  );

  @override
  TaskListModel? get taskList => model;
}

class _FakeBridgeSession implements BridgeSession {
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

class _FakeConv implements ConversationTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(WidgetTester tester, AppState app) async {
  await tester.pumpWidget(
    AppStateScope(
      app: app,
      child: MaterialApp(theme: buildAppTheme(), home: const TaskCenterPage()),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// fold-dual-pane-2 宽度公式（与实现同源）：窗口 34% 夹 232~320dp。
double paneWidthOf(double windowWidth) =>
    (windowWidth * 0.34).clamp(232.0, 320.0);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('宽屏（840dp）：双栏布局+空态引导；点任务=右栏就地打开不跳页', (tester) async {
    await tester.binding.setSurfaceSize(const Size(840, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = _DualPaneApp();
    await _pump(tester, app);

    // 双栏结构：根 Row + 空态引导。
    expect(find.byKey(const ValueKey('dual-pane-root')), findsOneWidget);
    expect(find.text('从左侧选择任务，或点「新建」开始'), findsOneWidget);
    // 左栏宽=比例化公式（840→285.6dp），右栏占其余。
    final left = tester.getSize(
      find.descendant(
        of: find.byKey(const ValueKey('dual-pane-root')),
        matching: find.byType(Column),
      ).first,
    );
    expect(left.width, closeTo(paneWidthOf(840), 1));

    // 点任务行：ConversationPage 出现在右栏（起点在左栏右侧），TaskCenter
    // 仍是当前路由（无推入遮挡——两页同时可见=双栏语义）。
    await tester.tap(find.text('示例任务').first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final conv = find.byType(ConversationPage);
    expect(conv, findsOneWidget, reason: '右栏就地打开会话');
    final convDx = tester.getTopLeft(conv).dx;
    expect(convDx, greaterThan(paneWidthOf(840)),
        reason: '会话页在右栏（非整页推入）');
    expect(find.byKey(const ValueKey('dual-pane-root')), findsOneWidget,
        reason: '任务列表仍在左栏可见');
  });

  testWidgets('宽屏：跨工作区打开在切换窗口内保留右栏选中（不被误清）', (tester) async {
    await tester.binding.setSurfaceSize(const Size(840, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = _DualPaneApp(
      workspaceTasksOverride: [
        {
          'taskId': 't-b',
          'title': '跨区任务',
          'displayStatus': 'completed',
          'updatedAt': 2000,
          'workspaceIdentity': 'ws-b',
          'workspacePath': 'D:/示例项目B',
        },
      ],
      workspaces: const [
        {'workspaceIdentity': 'ws-a', 'workspacePath': 'D:/示例项目A'},
        {'workspaceIdentity': 'ws-b', 'workspacePath': 'D:/示例项目B'},
      ],
    );
    await _pump(tester, app);

    await tester.tap(find.text('跨区任务').first);
    // fake switch 延迟 600ms：窗口内右栏必须已显示会话页。红=旧实现
    // 按「sel.workspaceKey == 当前键」判失效，在等待窗口 post-frame
    // 清空选中，切换完成后右栏永远空态。
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ConversationPage), findsOneWidget,
        reason: '切换落地前右栏选中不得被误清（对抗审查高①）');
    expect(find.text('从左侧选择任务，或点「新建」开始'), findsNothing);

    // 切换落地后仍在右栏（等待目标转正不丢选中）。
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect((app.activeWorkspace ?? const {})['workspaceIdentity'], 'ws-b',
        reason: '跨区切换已落地');
    final conv = find.byType(ConversationPage);
    expect(conv, findsOneWidget, reason: '切换完成后右栏会话保持');
    expect(tester.getTopLeft(conv).dx, greaterThan(paneWidthOf(840)),
        reason: '会话在右栏（不是空态，也不是整页推入）');
  });

  testWidgets('宽屏无 FAB 防遮输入栏；新建入口=左栏「新建任务」行（18074 验收②）', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(840, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = _DualPaneApp();
    await _pump(tester, app);

    // 宽屏：FAB 不在场（此前悬在右栏输入栏正上方=遮挡）；左栏有
    // 「新建任务」导航行——18075 验收反馈①：位于最新/项目分组**之下**
    // （列表尾部，官方桌面侧栏新建在底部），不再在列首。
    expect(find.byKey(const ValueKey('new-session')), findsNothing,
        reason: '宽屏 FAB 遮挡右栏输入栏（用户 18074 实锤）');
    expect(find.byKey(const ValueKey('home-new-task-nav')), findsOneWidget);
    expect(find.text('新建任务'), findsOneWidget);
    final navDy = tester.getTopLeft(
      find.byKey(const ValueKey('home-new-task-nav')),
    ).dy;
    final taskRowDy = tester.getTopLeft(
      find.byKey(const ValueKey('compact-task-row-t-1')),
    ).dy;
    expect(navDy, greaterThan(taskRowDy),
        reason: '新建任务行在任务分组之下（18075 验收反馈①）');

    // 窄屏：FAB 保留原行为。
    await tester.binding.setSurfaceSize(const Size(375, 806));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('new-session')), findsOneWidget);
    expect(find.byKey(const ValueKey('home-new-task-nav')), findsNothing);
  });

  testWidgets('未读指示点=智谱蓝 brandAccent（brand 黑白单色曾致"白点"，18075 验收②）', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(840, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = _DualPaneApp(
      tasks: [
        {
          'taskId': 't-unread',
          'title': '未读任务',
          'status': 'completed',
          'updatedAt': 2000,
          'unreadAt': 1500,
        },
      ],
    );
    await _pump(tester, app);

    final row = find.byKey(const ValueKey('compact-task-row-t-unread'));
    expect(row, findsOneWidget);
    final dot = find
        .descendant(of: row, matching: find.byType(Container))
        .evaluate()
        .map((e) => e.widget as Container)
        .firstWhere(
          (c) => (c.decoration as BoxDecoration?)?.shape == BoxShape.circle,
        );
    final spec = buildAppTheme().extension<AppThemeSpec>()!;
    final decoration = dot.decoration as BoxDecoration;
    expect(
      decoration.color,
      spec.colors.brandAccent,
      reason: '未读点用智谱蓝点睛（brand 浅=纯黑/深=纯白，深色下成白点）',
    );
  });

  testWidgets('宽屏：任务行=桌面风紧凑单行，点选后整行低饱和填充', (tester) async {
    await tester.binding.setSurfaceSize(const Size(840, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = _DualPaneApp();
    await _pump(tester, app);

    // 紧凑行替代卡片；单行高 48。
    final row = find.byKey(const ValueKey('compact-task-row-t-1'));
    expect(row, findsOneWidget);
    expect(find.byKey(const ValueKey('cross-task-card-t-1')), findsNothing,
        reason: '宽屏左栏不再渲染卡片');
    expect(tester.getSize(row).height, 48);

    Material materialOf() =>
        tester.widget<Material>(find.byKey(const ValueKey('compact-task-row-t-1')));
    expect(materialOf().color, Colors.transparent, reason: '未选中=透明底');

    await tester.tap(find.text('示例任务').first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ConversationPage), findsOneWidget);
    expect(materialOf().color, isNot(Colors.transparent),
        reason: '右栏打开的行应有选中填充（官方桌面唯一选中信号）');
  });

  testWidgets('宽屏紧凑行细节：未读蓝点/超长省略/灰字再显示（无状态徽标）', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(840, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final now = DateTime.now().millisecondsSinceEpoch;
    final app = _DualPaneApp(
      tasks: [
        for (var i = 0; i < 6; i++)
          {
            'taskId': 'u-$i',
            'title': i == 0
                ? '这是一个特别长的任务标题用于验证单行省略号截断表现'
                : '未读示例 $i',
            'status': 'completed',
            'updatedAt': now - i * 60000,
            if (i == 1) 'unreadAt': now,
          },
      ],
    );
    await _pump(tester, app);

    // 切到项目视图：「任务」未归类组默认 3 条 + 展开控件。
    await tester.tap(find.text('项目').first);
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 未读行：行首图标槽 6dp 蓝点（宽屏紧凑行唯一行首标记）。
    final dotRow = find.byKey(const ValueKey('compact-task-row-u-1'));
    expect(dotRow, findsOneWidget);
    expect(
      find.descendant(of: dotRow, matching: find.byType(Container)),
      findsOneWidget,
      reason: '未读=图标槽圆点（其余行槽位留空）',
    );
    // 普通行槽位无标记。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('compact-task-row-u-2')),
        matching: find.byType(Container),
      ),
      findsNothing,
    );

    // 超长标题：单行省略。
    final titleText = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(const ValueKey('compact-task-row-u-0')),
            matching: find.byType(Text),
          )
          .first,
    );
    expect(titleText.maxLines, 1);
    expect(titleText.overflow, TextOverflow.ellipsis);

    // 「展开剩余 N 项」= 灰字文字钮（紧凑档不再用品牌色实心钮）。
    final more = find.text('展开剩余 3 项');
    expect(more, findsOneWidget);
    expect(
      find.ancestor(of: more, matching: find.byType(TextButton)),
      findsOneWidget,
      reason: '紧凑档展开控件应为 TextButton',
    );
    expect(
      find.ancestor(of: more, matching: find.byType(FilledButton)),
      findsNothing,
      reason: '紧凑档展开控件不再用品牌色实心钮',
    );
  });

  testWidgets('宽屏：返回键先收右栏（空态回来），任务中心不被退出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(840, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = _DualPaneApp();
    await _pump(tester, app);
    await tester.tap(find.text('示例任务').first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ConversationPage), findsOneWidget);

    // 系统返回 → 收右栏（PopScope 拦截，不清路由）。
    final dynamic widgetsBinding = WidgetsBinding.instance;
    await widgetsBinding.handlePopRoute();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ConversationPage), findsNothing, reason: '右栏收回');
    expect(find.text('从左侧选择任务，或点「新建」开始'), findsOneWidget,
        reason: '回空态，任务中心仍在（未退出 app）');
  });

  testWidgets('窄屏（375dp）：保持卡片与整页推入原行为', (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 806));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = _DualPaneApp();
    await _pump(tester, app);
    expect(find.byKey(const ValueKey('dual-pane-root')), findsNothing,
        reason: '窄屏无双栏');
    // 折叠态不受紧凑档影响：任务行仍为卡片。
    expect(find.byKey(const ValueKey('cross-task-card-t-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('compact-task-row-t-1')), findsNothing);

    await tester.tap(find.text('示例任务').first);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final conv = find.byType(ConversationPage);
    expect(conv, findsOneWidget);
    final convDx = tester.getTopLeft(conv).dx;
    expect(convDx, lessThan(10), reason: '整页推入（左上角贴边）');
  });
}
