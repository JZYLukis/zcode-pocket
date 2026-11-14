import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/task_list.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/project_tree.dart';
import 'package:zcode_pocket/ui/task_center_page.dart';

class _FakeConversation implements ConversationTransport {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeBridge implements BridgeSession {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _SearchApp extends AppState {
  _SearchApp(this.onSearch);
  final List<Map<String, dynamic>>? Function(String query) onSearch;

  @override
  LinkPhase get phase => LinkPhase.online;
  @override
  ConversationTransport get conversation => _FakeConversation();
  /// 服务器搜索/任务卡守卫的判据是 bridge（三轮审查 改判）——
  /// fake 须覆写非空桥，否则测试误判离线。
  @override
  BridgeSession get bridge => _FakeBridge();
  @override
  String? get activeProjectId => conversationsPseudoProjectId;
  @override
  Map<String, dynamic>? get activeWorkspace => const {
        'workspaceIdentity': 'ws-a',
        'workspacePath': 'D:/示例项目A',
      };
  @override
  List<Map<String, dynamic>> get workspaces => const [
        {'workspaceIdentity': 'ws-a', 'workspacePath': 'D:/示例项目A'},
        {'workspaceIdentity': 'ws-b', 'workspacePath': 'D:/示例项目B'},
      ];

  late final SessionsIndexState _si = SessionsIndexState()..ready = true;
  late final TaskListModel _model = TaskListModel(
    sessions: _si,
    workspaceKey: 'ws-a',
  )..applyChannelLists(
      active: [
        {
          'taskId': 't1',
          'title': '普通标题',
          'status': 'completed',
          'updatedAt': 1800000000000,
          'createdAt': 1800000000000,
        },
      ],
      pinnedIds: const [],
      archivedIds: const [],
    );
  @override
  SessionsIndexState? get sessionsIndex => _si;
  @override
  TaskListModel? get taskList => _model;

  @override
  List<Map<String, dynamic>> get workspaceTasks => const [
        {
          'taskId': 't1',
          'title': '普通标题',
          'workspaceIdentity': 'ws-a',
          'workspacePath': 'D:/示例项目A',
          'status': 'completed',
          'updatedAt': 1800000000000,
        },
        {
          'taskId': 't2',
          'title': '另一个任务',
          'workspaceIdentity': 'ws-b',
          'workspacePath': 'D:/示例项目B',
          'status': 'completed',
          'updatedAt': 1800000000000,
        },
      ];

  int searchCalls = 0;
  @override
  Future<List<Map<String, dynamic>>?> searchTasks(String query) async {
    searchCalls++;
    return onSearch(query);
  }
}

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: const MaterialApp(home: TaskCenterPage()),
    );

Future<void> _enterQuery(WidgetTester tester, String query) async {
  await tester.tap(find.byTooltip('搜索任务'));
  await tester.pump();
  await tester.enterText(find.byKey(const ValueKey('task-search')), query);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

/// fold-dual-pane-2（2026-10-29）：测试默认画布 800×600≥600dp 会走双栏
/// 紧凑行；本文件用例对象=窄屏卡片路径（紧凑行归 dual_pane_test）。
Future<void> _narrow(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
}

void main() {
  testWidgets('伪项目态也走全文搜索：正文命中当前工作区任务并显示片段', (tester) async {
    await _narrow(tester);
    final app = _SearchApp((query) => [
      {
        'taskId': 't1',
        'title': '普通标题',
        'workspaceIdentity': 'ws-a',
        'workspacePath': 'D:/示例项目A',
        'searchSnippet': '这里是正文关键词片段',
        'status': 'completed',
        'updatedAt': 1800000000000,
      },
    ]);
    await tester.pumpWidget(_host(app));
    await tester.pump();
    await _enterQuery(tester, '正文关键词');

    expect(app.searchCalls, 1);
    expect(find.text('普通标题'), findsOneWidget,
        reason: '标题不含关键词，只有服务端正文命中才能把它提为可见');
    expect(find.textContaining('正文关键词片段'), findsWidgets);
  });

  testWidgets('跨工作区正文命中也显示，不退化为标题过滤', (tester) async {
    await _narrow(tester);
    final app = _SearchApp((query) => [
      {
        'taskId': 't2',
        'title': '另一个任务',
        'workspaceIdentity': 'ws-b',
        'workspacePath': 'D:/示例项目B',
        'searchSnippet': '另一个工作区的正文关键词',
        'status': 'completed',
        'updatedAt': 1800000000000,
      },
    ]);
    await tester.pumpWidget(_host(app));
    await tester.pump();
    await _enterQuery(tester, '正文关键词');

    expect(find.text('另一个任务'), findsOneWidget);
    expect(find.textContaining('另一个工作区的正文关键词'), findsWidgets);
  });

  testWidgets('零结果时正文搜索失败提示仍可见', (tester) async {
    await _narrow(tester);
    final app = _SearchApp((query) => null);
    await tester.pumpWidget(_host(app));
    await tester.pump();
    await _enterQuery(tester, '完全不存在的关键词');

    expect(find.textContaining('对话内容搜索暂不可用'), findsOneWidget,
        reason: '零结果早退不得吞掉 failed 降级说明');
  });

  testWidgets('长按归档先切所属工作区再发 archiveTask（L2/L3 P1 护栏）', (
    tester,
  ) async {
    await _narrow(tester);
    final app = _ArchiveOrderApp((query) => null);
    await tester.pumpWidget(_host(app));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 主页跨工作区行（ws-b 的 t2）长按 → 动作菜单。
    await tester.longPress(find.text('另一个任务'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text('归档'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    // 修复前：归档是菜单里唯一绕过 run()（ensureContext 归属护栏）的
    // 动作——跨工作区任务直发会把当前工作区 scope 打偏。
    expect(app.log, ['switch:ws-b', 'archive:t2'],
        reason: '归档必须与同菜单其余动作一样先走归属护栏');
  });
}

//归档护栏用：记录 switchWorkspace/archiveTask 的触发顺序。
class _ArchiveOrderApp extends _SearchApp {
  _ArchiveOrderApp(super.onSearch);

  final List<String> log = [];

  @override
  Future<void> switchWorkspace(Map<String, dynamic> workspace,
      {bool keepHomePreview = false}) async {
    log.add('switch:${workspace['workspaceIdentity']}');
  }

  @override
  Future<dynamic> archiveTask(String taskId) async {
    log.add('archive:$taskId');
    return <String, dynamic>{'ok': true};
  }
}
