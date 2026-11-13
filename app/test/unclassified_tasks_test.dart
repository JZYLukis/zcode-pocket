import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/project_tree.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';

/// 「任务」未归类区在 B 方案任务主页中的行为（2026-10-26 项目栏优化）：
/// 不再有伪项目 chip；默认最近直接展示，项目视图归入「任务」分组。
/// 保留原 三态、无目录噪音、任务 intent 开桥与下拉刷新约束。

class _UncBridge implements BridgeSession {
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

class _FakeAppState extends AppState {
  @override
  LinkPhase get phase => LinkPhase.online;

  List<Map<String, dynamic>> tasks = const [];
  @override
  List<Map<String, dynamic>> get unclassifiedTasks => tasks;
  @override
  List<Map<String, dynamic>> get workspaceTasks => tasks;
  @override
  List<Map<String, dynamic>> get projectTasks => tasks;

  @override
  List<Map<String, dynamic>> get sidebarProjects => [
        {'id': 'proj-1', 'name': '示例项目'},
        conversationsPseudoProject(),
      ];

  List<Map<String, dynamic>> openedTasks = [];
  Map<String, dynamic>? _activeWs;
  @override
  Map<String, dynamic>? get activeWorkspace =>
      _activeWs ?? super.activeWorkspace;
  final _fakeBridge = _UncBridge();
  @override
  BridgeSession? get bridge => _fakeBridge;
  @override
  Future<void> switchToTask(Map<String, dynamic> task,
      {String? label, bool keepHomePreview = false}) async {
    openedTasks.add(task);
    // ⑤A 等待循环：切到位+桥在场。
    _activeWs = {'workspacePath': '${task['workspacePath'] ?? ''}'};
    notifyListeners();
  }

  @override
  String get readTreeStatus => treeStatus;
  String treeStatus = 'ok';

  int refreshCalls = 0;
  @override
  Future<void> refreshWorkspaces() async => refreshCalls++;
}

Widget _host(AppState app, {DateTime? now}) => AppStateScope(
      app: app,
      child: MaterialApp(home: TaskCenterPage(homeNow: now)),
    );

Map<String, dynamic> _task(
  String id,
  String title, {
  String? dir,
  DateTime? updatedAt,
}) =>
    {
      'taskId': id,
      'title': title,
      'updatedAt': (updatedAt ?? DateTime.now()).millisecondsSinceEpoch,
      'displayStatus': 'idle',
      'projectId': null,
      'workspacePath': dir ?? r'D:\示例工作区\default',
    };

/// 早前批次（2026-10-29）：测试默认画布 800×600≥600dp 会走双栏
/// 紧凑行；本文件用例对象=窄屏卡片路径（紧凑行归 dual_pane_test）。
Future<void> _narrow(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  testWidgets('B：默认最近直接展示未归类任务，无 chip、无第二层路由', (tester) async {
    await _narrow(tester);
    final app = _FakeAppState();
    app.tasks = [_task('t-101', '整理桌面'), _task('t-102', '写周报')];
    await tester.pumpWidget(_host(app));
    await tester.pump();

    expect(find.text('最近'), findsOneWidget);
    expect(find.text('整理桌面'), findsOneWidget);
    expect(find.text('写周报'), findsOneWidget);
    expect(
      Navigator.of(tester.element(find.text('整理桌面'))).canPop(),
      isFalse,
    );
  });

  testWidgets('B：项目视图归「任务」组；无目录副标题，保留相对时间', (tester) async {
    await _narrow(tester);
    // 固定时钟（对抗审查低⑮）：此前依赖墙钟，「刚刚」在分钟边界会
    // 变成「1 分钟前」随机红。
    final now = DateTime(2026, 11, 8, 12);
    final app = _FakeAppState();
    app.tasks = [
      _task('t-101', '整理桌面',
          dir: r'D:\示例工作区\default', updatedAt: now),
      _task('t-102', '写周报',
          dir: r'D:\示例工作区\1758000000-aaaa-bbbb',
          updatedAt: now.subtract(const Duration(minutes: 3))),
    ];
    await tester.pumpWidget(_host(app, now: now));
    await tester.pump();
    await tester.tap(find.text('项目'));
    await tester.pump();

    expect(find.byKey(const ValueKey('home-group:conversations')), findsOneWidget);
    expect(find.text('default'), findsNothing, reason: '目录名不得再作副标题');
    expect(find.textContaining('1758000000'), findsNothing,
        reason: '时间戳-uuid 目录名（用户口中的乱码）不得显示');
    expect(find.byIcon(Icons.folder_outlined), findsNothing,
        reason: '项目视图卡片不再重复显示来源；未归类组头是对话图标');
    expect(find.text('刚刚'), findsOneWidget, reason: '相对时间保留');
    expect(find.text('3 分钟前'), findsOneWidget);
  });

  testWidgets('空态与数据到达刷新', (tester) async {
    await _narrow(tester);
    final app = _FakeAppState();
    await tester.pumpWidget(_host(app));
    await tester.pump();
    expect(find.textContaining('还没有任务'), findsOneWidget);

    app.tasks = [_task('t-101', '整理桌面'), _task('t-102', '写周报')];
    app.notifyListeners();
    await tester.pump();
    expect(find.text('整理桌面'), findsOneWidget);
  });

  testWidgets('点任务卡走任务 intent 开桥（switchToTask）', (tester) async {
    await _narrow(tester);
    final app = _FakeAppState();
    final target = _task('t-101', '整理桌面');
    app.tasks = [target];
    await tester.pumpWidget(_host(app));
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('早前批次')));
    await tester.pump();

    expect(app.openedTasks, hasLength(1));
    expect('${app.openedTasks.first['taskId']}', 't-101');
  });

  testWidgets('H13 三态：readTree 未返回=加载中，不冒充空数据', (tester) async {
    await _narrow(tester);
    final app = _FakeAppState();
    app.treeStatus = 'loading';
    await tester.pumpWidget(_host(app));
    await tester.pump();
    expect(find.textContaining('正在加载任务'), findsOneWidget);
    expect(find.textContaining('还没有任务'), findsNothing,
        reason: '未加载≠空数据（审查 H13-3）');
  });

  testWidgets('H13 三态：失败=可重试，点重试触发刷新', (tester) async {
    await _narrow(tester);
    final app = _FakeAppState();
    app.treeStatus = 'failed';
    await tester.pumpWidget(_host(app));
    await tester.pump();
    expect(find.textContaining('任务列表加载失败'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('home-retry')));
    await tester.pump();
    expect(app.refreshCalls, 1, reason: '重试走 refreshWorkspaces（readTree 重拉）');
  });

  testWidgets('H13：数据态有下拉刷新+底距 88 防新建按钮遮末卡+builder 化', (tester) async {
    await _narrow(tester);
    final app = _FakeAppState();
    app.tasks = [for (var i = 0; i < 3; i++) _task('t-$i', '任务 $i')];
    await tester.pumpWidget(_host(app));
    await tester.pump();

    expect(find.byType(RefreshIndicator), findsOneWidget);
    final list = tester.widget<ListView>(
      find.descendant(
        of: find.byType(RefreshIndicator),
        matching: find.byType(ListView),
      ),
    );
    expect((list.padding as EdgeInsets?)?.bottom, 88);
  });
}
