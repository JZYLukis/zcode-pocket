import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/task_list.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/project_tree.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';

/// 长按图标快捷入口（6.6①）：动作归一、挂起与任务中心消费
/// （new_task→新建弹层 / last_session→跨工作区最近任务直达；原生层
/// shortcuts.xml/Manifest/MainActivity 转发属设备路径，真机复验）。

class _ShortcutAppState extends AppState {
  @override
  LinkPhase get phase => LinkPhase.online;

  List<Map<String, dynamic>> tasks = const [];
  @override
  List<Map<String, dynamic>> get workspaceTasks => tasks;

  @override
  List<Map<String, dynamic>> get sidebarProjects => [
    {'id': 'proj-1', 'name': '示例项目'},
    conversationsPseudoProject(),
  ];

  List<Map<String, dynamic>> openedTasks = [];
  @override
  Future<void> switchToTask(Map<String, dynamic> task, {String? label}) async {
    openedTasks.add(task);
  }

  TaskListModel? fakeTaskList;
  @override
  TaskListModel? get taskList => fakeTaskList;

  @override
  String get readTreeStatus => 'ok';
}

Widget _host(AppState app) => AppStateScope(
  app: app,
  child: const MaterialApp(home: TaskCenterPage()),
);

Map<String, dynamic> _task(String id, String title, {required int updatedAt}) => {
  'taskId': id,
  'title': title,
  'updatedAt': updatedAt,
  'displayStatus': 'idle',
  'projectId': null,
  'workspacePath': r'D:\示例工作区\default',
};

void main() {
  test('动作归一：仅认 new_task/last_session，其余一律 null 不建挂起', () {
    expect(AppState.normalizeShortcutAction('new_task'), 'new_task');
    expect(AppState.normalizeShortcutAction(' last_session '), 'last_session');
    expect(AppState.normalizeShortcutAction(null), isNull);
    expect(AppState.normalizeShortcutAction(''), isNull);
    expect(
      AppState.normalizeShortcutAction('wipe_data'),
      isNull,
      reason: 'exported 入口的 extra 可被任意应用伪造，白名单外动作必须忽略',
    );
  });

  test('handleShortcutAction 建挂起并通知；非法动作零副作用', () {
    final app = AppState();
    var notified = 0;
    app.addListener(() => notified++);
    app.handleShortcutAction('new_task');
    expect(app.pendingShortcutAction, 'new_task');
    expect(notified, 1);
    app.handleShortcutAction('rm -rf');
    expect(app.pendingShortcutAction, 'new_task');
    expect(notified, 1);
    app.dispose();
  });

  testWidgets('new_task：挂起消费后打开新建任务弹层', (tester) async {
    final app = _ShortcutAppState();
    await tester.pumpWidget(_host(app));
    await tester.pump();
    app.handleShortcutAction('new_task');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(app.pendingShortcutAction, isNull, reason: '消费后必须清挂起防重放');
    expect(
      find.byType(BottomSheet),
      findsOneWidget,
      reason: '快捷入口 new_task 应打开新建选择弹层',
    );
  });

  testWidgets('last_session：数据未到保留挂起，任务就绪后直达该会话', (tester) async {
    final app = _ShortcutAppState();
    await tester.pumpWidget(_host(app));
    await tester.pump();
    app.handleShortcutAction('last_session');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      app.pendingShortcutAction,
      'last_session',
      reason: '任务数据未到不得消费，数据到达触发的重建再导航',
    );

    app.tasks = [
      _task('t-101', '整理桌面', updatedAt: 1000),
      _task('t-102', '写周报', updatedAt: 2000),
    ];
    app.notifyListeners();
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.pendingShortcutAction, isNull);
    expect(app.openedTasks.map((t) => '${t['taskId']}'), contains('t-102'));
    expect(find.byType(ConversationPage), findsOneWidget);
  });

  testWidgets('last_session：列表就绪但无任何任务→提示并清挂起', (tester) async {
    final app = _ShortcutAppState();
    final si = SessionsIndexState()..ready = true;
    app.fakeTaskList = TaskListModel(sessions: si, workspaceKey: 'ws-a');
    await tester.pumpWidget(_host(app));
    await tester.pump();
    app.handleShortcutAction('last_session');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      app.pendingShortcutAction,
      isNull,
      reason: 'taskList 已建仍空=确实无任务，必须清挂起不得死等',
    );
    expect(find.textContaining('暂无最近会话'), findsOneWidget);
  });
}
