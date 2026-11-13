// 顶栏运行中计数角标（早前批次，用户拍板：工作流与子代理
// 两图标同挂动态角标——点完「收集产物」瞄一眼图标即知在跑/跑完）。
// 纯逻辑（子代理行状态推导）+widget 旅程（角标在场性/计数/零运行纯图标）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/turn_model.dart' show countRunningSubagents;

class _BadgeBridge implements BridgeSession {
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
  RpcFrameTransport get transport => throw UnimplementedError();
  @override
  ChannelClient get channels => throw UnimplementedError();
  @override
  String? get workspaceKey => 'ws-b';
  @override
  String? get initialTaskId => null;
  @override
  ConversationTransport conversation(
    Map<String, dynamic> scope, {
    void Function(String line)? onLog,
  }) => throw UnimplementedError();
  @override
  void dispose() {}
}

class _BadgeApp extends AppState {
  _BadgeApp({this.withRunning = true});

  final bool withRunning;

  @override
  bool get loaded => true;
  @override
  LinkPhase get phase => LinkPhase.online;
  @override
  BridgeSession? get bridge => _BadgeBridge();

  @override
  Future<ConversationSubscription> ensureConversation(String sessionId,
      {Object? seedCacheEntry}) async {
    final sub = _Sub(sessionId);
    sub.state.applySeed(
      ConversationSeed(
        rows: withRunning
            ? const [
                {'rowId': 1, 'kind': 'userInput', 'text': '收集产物'},
                {'rowId': 2, 'kind': 'subagent', 'status': 'running',
                 'subagentType': 'general'},
                {'rowId': 3, 'kind': 'subagent', 'status': 'success',
                 'subagentType': 'general'},
                {'rowId': 4, 'kind': 'toolCall', 'toolName': 'CreateWorkflow',
                 'status': 'completed'},
              ]
            : const [
                {'rowId': 1, 'kind': 'userInput', 'text': '你好'},
                {'rowId': 2, 'kind': 'subagent', 'status': 'success',
                 'subagentType': 'general'},
              ],
        logEpoch: 'e1',
        seq: 4,
        firstRowId: 1,
        totalCount: 4,
        snapshot: withRunning
            ? const {
                'title': '角标测试',
                'control': {'phase': 'running'},
                'workflowRuns': {
                  'revision': 1,
                  'runs': [
                    {'runId': 'r1', 'status': 'running'},
                    {'runId': 'r2', 'status': 'completed'},
                  ],
                },
              }
            : const {
                'title': '角标测试',
                'control': {'phase': 'completed'},
                'workflowRuns': {
                  'revision': 1,
                  'runs': [
                    {'runId': 'r2', 'status': 'completed'},
                  ],
                },
              },
      ),
    );
    return sub;
  }
}

class _Sub implements ConversationSubscription {
  _Sub(this.sessionId);
  @override
  final String sessionId;
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-b';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/\$sessionId';
  @override
  Future<void> dispose() async {}
}

Widget _host(AppState app) => AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const ConversationPage(sessionId: 's1', title: '角标测试'),
      ),
    );

Future<void> _pump(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  for (var i = 0; i < 14; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('countRunningSubagents：白名单 running/streaming 计入，其余不计', () {
    // 对抗审查 C-（2026-11-14）：fail-open 改显式白名单——演示行
    // status:'done' 与未知状态/缺席不得点亮（宁少勿多）。
    expect(
      countRunningSubagents(const [
        {'kind': 'subagent', 'status': 'running'},
        {'kind': 'subagent', 'status': 'streaming'},
        {'kind': 'subagent'}, // 无 status：行级无配对上下文，不计
        {'kind': 'subagent', 'status': 'success'},
        {'kind': 'subagent', 'status': 'failed'},
        {'kind': 'subagent', 'status': 'cancelled'},
        {'kind': 'subagent', 'status': 'done'}, // 演示数据形态
        {'kind': 'toolCall', 'status': 'running'}, // 非子代理行
      ]),
      2,
    );
    expect(countRunningSubagents(const []), 0);
  });

  testWidgets('运行中：工作流挂计数角标；子代理=warning 高亮图标（无角标）',
      (tester) async {
    await _pump(tester, _host(_BadgeApp(withRunning: true)));
    final wfBadge = find.byKey(const ValueKey('topbar-badge-workflow'));
    expect(wfBadge, findsOneWidget,
        reason: '1 个运行中 run（投影活数据）→ 工作流图标挂角标');
    expect(
      find.descendant(of: wfBadge, matching: find.text('1')),
      findsOneWidget,
    );
    // 真机反馈（2026-11-14）：计数徽喧宾夺主——子代理改图标本身高亮
    //（warning 色，与 run 卡 spinner 同色系），角标退役。
    expect(find.byKey(const ValueKey('topbar-badge-subagents')), findsNothing,
        reason: '子代理计数徽已退役（真机反馈喧宾夺主）');
    final icon = tester.widget<Icon>(
      find
          .descendant(
            of: find.byKey(const ValueKey('subagents-entry')),
            matching: find.byType(Icon),
          )
          .first,
    );
    expect(icon.color, const Color(0xFFB45309),
        reason: '有运行中子代理时图标 warning 高亮（浅色主题 warning）');
  });

  testWidgets('零运行：角标缺席+子代理图标默认色（纯图标零干扰）',
      (tester) async {
    await _pump(tester, _host(_BadgeApp(withRunning: false)));
    expect(find.byKey(const ValueKey('topbar-badge-workflow')), findsNothing);
    expect(find.byKey(const ValueKey('topbar-badge-subagents')), findsNothing);
    final icon = tester.widget<Icon>(
      find
          .descendant(
            of: find.byKey(const ValueKey('subagents-entry')),
            matching: find.byType(Icon),
          )
          .first,
    );
    expect(icon.color, isNull, reason: '零运行时子代理图标用默认前景色');
  });
}
