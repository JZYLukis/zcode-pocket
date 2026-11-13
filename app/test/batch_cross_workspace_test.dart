// 批量操作跨区行归属回归（对抗审查中⑩）：跨工作区搜索行可能不在
// workspaceTasks 索引（官方全文命中行），选择集必须携带行级工作区键，
// 批量操作按行归属切工作区执行——不再静默归当前工作区（RPC 必打偏）。
// 红=旧 _runBatchOp 只查 workspaceTasks，row==null 时归当前键。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/task_list.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/project_tree.dart'
    show conversationsPseudoProjectId;
import 'package:zcode_pocket/ui/task_center_page.dart';

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

class _BatchApp extends AppState {
  final List<String> switchLog = [];
  final List<String> archived = [];
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
  List<Map<String, dynamic>> get workspaces => const [
        {'workspaceIdentity': 'ws-a', 'workspacePath': 'D:/示例项目A'},
        {'workspaceIdentity': 'ws-b', 'workspacePath': 'D:/示例项目B'},
      ];
  // 索引里没有这条命中行（官方 listTaskList 全文命中行不在
  // workspace-list 全量索引）——旧实现反查 row==null 归当前工作区。
  @override
  List<Map<String, dynamic>> get workspaceTasks => const [];
  @override
  List<Map<String, dynamic>> get projectTasks => const [];

  @override
  Future<void> switchWorkspace(
    Map<String, dynamic> workspace, {
    bool keepHomePreview = false,
  }) async {
    switchLog.add('${workspace['workspaceIdentity'] ?? ''}');
    _activeWs = workspace;
    notifyListeners();
  }

  @override
  Future<List<Map<String, dynamic>>?> searchTasks(String query) async => [
        {
          'taskId': 't-cross',
          'title': '跨区命中任务',
          'workspaceIdentity': 'ws-b',
          'workspacePath': 'D:/示例项目B',
          'updatedAt': 2000,
          'displayStatus': 'completed',
        },
      ];

  @override
  Future<dynamic> archiveTask(String taskId) async {
    archived.add(taskId);
    return true;
  }

  final _fakeBridge = _FakeBridgeSession();
  @override
  BridgeSession? get bridge => _fakeBridge;

  late final SessionsIndexState _si = SessionsIndexState()..ready = true;
  @override
  SessionsIndexState? get sessionsIndex => _si;
  late final TaskListModel model = TaskListModel(
    sessions: _si,
    workspaceKey: 'ws-a',
  );

  @override
  TaskListModel? get taskList => model;
}

void main() {
  testWidgets('批量归档跨区搜索行：按行级工作区键切换执行，不归当前工作区', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _BatchApp();
    await tester.pumpWidget(
      AppStateScope(
        app: app,
        child: MaterialApp(theme: buildAppTheme(), home: const TaskCenterPage()),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 打开搜索并触发全文命中（300ms 防抖）。
    await tester.tap(find.byIcon(Icons.search).first);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.enterText(find.byKey(const ValueKey('task-search')), '跨区');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final card = find.byKey(const ValueKey('cross-task-card-t-cross'));
    expect(card, findsOneWidget, reason: '搜索命中跨区任务行');

    // 长按→选择任务（多选态）。
    await tester.longPress(card);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('task-action-select-tasks')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('multi-select-bar')), findsOneWidget);

    // 批量归档（全量二次确认）。
    await tester.tap(find.byKey(const ValueKey('multi-archive')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '归档'));
    await tester.pumpAndSettle();

    expect(app.archived, ['t-cross'],
        reason: '跨区任务实际执行归档（旧实现归当前工作区打偏失败）');
    expect(app.switchLog, ['ws-b', 'ws-a'],
        reason: '按行级键切到 ws-b 执行，批后回切原工作区');
    expect(find.textContaining('已归档 1 个'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
