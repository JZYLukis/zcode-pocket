// 通知深链消费侧回归（对抗审查中⑦）：任务查不到归属时不裸开会话
//（裸开没有工作区 scope，RPC 必打偏），人话提示并清深链残留；目标属于
// 另一台电脑时等激活窗口后提示等待/切换。红=旧实现直接
// _openConversation(taskId,'会话') 裸开。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/task_list.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/connection_params.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/project_tree.dart'
    show conversationsPseudoProjectId;
import 'package:zcode_pocket/transport/z_transport.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
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

class _NotifyApp extends AppState {
  _NotifyApp({this.profile});

  final DeviceProfile? profile;

  @override
  LinkPhase get phase => LinkPhase.online;
  @override
  ConversationTransport get conversation => _FakeConv();
  @override
  DeviceProfile? get activeProfile => profile;
  @override
  BridgeSession? get bridge => _fakeBridge;
  @override
  Map<String, dynamic>? get activeWorkspace => const {
        'workspaceIdentity': 'ws-a',
        'workspacePath': 'D:/示例项目A',
      };
  @override
  String? get activeProjectId => conversationsPseudoProjectId;
  @override
  List<Map<String, dynamic>> get workspaceTasks => const [];
  @override
  List<Map<String, dynamic>> get projectTasks => const [];

  final _fakeBridge = _FakeBridgeSession();
  late final SessionsIndexState _si = SessionsIndexState()..ready = true;
  late final TaskListModel model = TaskListModel(
    sessions: _si,
    workspaceKey: 'ws-a',
  );

  @override
  TaskListModel? get taskList => model;
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

void main() {
  testWidgets('通知深链：任务查不到归属→人话提示、不裸开会话', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _NotifyApp();
    app.pendingOpenTask = (deviceSid: '', taskId: 'ghost-task');
    app.pendingDeepLinkAt = 1700000000000;
    app.pendingDeepLinkTaskId = 'ghost-task';
    await _pump(tester, app);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(ConversationPage), findsNothing,
        reason: '查不到工作区归属不得裸开会话（RPC 必打偏）');
    expect(find.text('该任务不在当前工作区，可能已被移除'), findsOneWidget,
        reason: '给人话提示而不是静默失败');
    expect(app.pendingDeepLinkAt, isNull,
        reason: '失败收口清深链残留（防后续会话误弹浮层）');
    expect(tester.takeException(), isNull);
  });

  testWidgets('通知深链：目标属于另一台电脑→等待后提示、不裸开', (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final profile = RelayProfile(
      params: CompanionConnectionParams(
        deviceSid: 'dev-a',
        passHash: 'h',
        timestamp: 1,
        source: Uri.parse('https://zcode.z.ai/remote/v4'),
      ),
      label: '示例电脑A',
      addedAt: DateTime(2026, 1, 1),
    );
    final app = _NotifyApp(profile: profile);
    app.pendingOpenTask = (deviceSid: 'dev-b', taskId: 't-b');
    await _pump(tester, app);
    // 设备等待窗口 15×200ms：泵够 3.2s。
    for (var i = 0; i < 32; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(ConversationPage), findsNothing);
    expect(find.text('该任务属于另一台电脑，已切到当前电脑的任务列表'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
