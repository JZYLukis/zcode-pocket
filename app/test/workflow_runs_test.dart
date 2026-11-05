import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/l10n.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';
import 'package:zcode_pocket/ui/workflow_runs_page.dart';

/// 工作流 run 查询族 + 闲时任务卡（workflow-runs-1，2026-10-30 用户拍板
/// 「更新工作流及闲时执行部分」）：官方 v4 只读族（workflowRuns/Events/
/// Artifacts/ArtifactRead）+ OffPeakCreate 工具行卡片（官方
/// offpeak-create.tsx 输出解析语义对位）。

class _WfBridge implements BridgeSession {
  @override
  Map<String, dynamic>? get projectIntent => null;
  @override
  Map<String, dynamic>? get taskIntent => null;
  @override
  final ValueNotifier<String?> degraded = ValueNotifier(null);
  @override
  final ValueNotifier<int> recovered = ValueNotifier(0);
  @override
  Future<void> waitHealthy({
    Duration timeout = const Duration(seconds: 45),
  }) async {}
  @override
  Map<String, dynamic> get bridge => const {};
  @override
  RpcFrameTransport get transport => throw UnimplementedError();
  @override
  ChannelClient get channels => throw UnimplementedError();
  @override
  String? get workspaceKey => 'ws-wf';
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

class _WfSub implements ConversationSubscription {
  _WfSub(this.sessionId);
  @override
  final String sessionId;
  @override
  final ConversationState state = ConversationState();
  @override
  bool get hasLiveFrames => true;
  @override
  String? get subscriptionId => 'sub-wf';
  @override
  bool get isDisposed => false;
  @override
  String get topic => 'conversation/\$sessionId';
  @override
  Future<void> dispose() async {}
}

class _WfApp extends AppState {
  final Map<String, dynamic> runsResult;
  final Map<String, dynamic> detailResult;
  final String artifactText;
  _WfApp({required this.runsResult, required this.detailResult, required this.artifactText});

  @override
  LinkPhase get phase => LinkPhase.online;
  @override
  BridgeSession? get bridge => _WfBridge();
  @override
  Map<String, dynamic>? get activeWorkspace => const {
    'workspaceIdentity': 'ws-wf',
    'workspacePath': '/example-workspace',
  };
  @override
  Future<ConversationSubscription> ensureConversation(String sessionId,
      {Object? seedCacheEntry}) async {
    final sub = _WfSub(sessionId);
    sub.state.applySeed(
      ConversationSeed(
        rows: const [
          {'rowId': 1, 'kind': 'userInput', 'text': '闲时整理文档'},
          {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess', 'entityId': 'e1'},
        ],
        logEpoch: 'e1',
        seq: 2,
        firstRowId: 1,
        totalCount: 2,
        snapshot: const {
          'title': '工作流测试',
          'control': {'phase': 'completed'},
        },
      ),
    );
    return sub;
  }

  @override
  Future<SessionCacheEntry?> readSessionCache(String id) async =>
      SessionCacheEntry(
        deviceSid: 'd1',
        sessionId: id,
        rows: const [
          {'rowId': 1, 'kind': 'userInput', 'text': '闲时整理文档'},
          {'rowId': 2, 'kind': 'turnHeader', 'state': 'completedSuccess', 'entityId': 'e1'},
        ],
        logEpoch: 'e1',
        lastSeq: 2,
        firstRowId: 1,
        totalCount: 2,
        snapshotControl: {
          'title': '工作流测试',
          'control': {'phase': 'completed'},
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );
 /// 注入加载失败（empty-error 销账用例）。
  bool throwRuns = false;
  @override
  Future<dynamic> workflowRuns(String sessionId, {int? limit}) async {
    if (throwRuns) throw StateError('rpc down');
    return runsResult;
  }
  @override
  Future<dynamic> workflowRunEvents(String sessionId, String runId,
      {int? afterSequence, int? limit}) async {
    return {'events': detailResult['events']};
  }

  @override
  Future<dynamic> workflowRunArtifacts(String sessionId, String runId) async {
    return {'artifacts': detailResult['artifacts']};
  }

  @override
  Future<dynamic> workflowRunArtifactRead(
    String sessionId,
    String runId,
    String artifactId, {
    required int version,
    required int offset,
    required int limit,
  }) async {
    final bytes = utf8.encode(artifactText);
    return {
      'dataBase64': base64.encode(bytes),
      'mediaType': 'text/plain',
      'totalBytes': bytes.length,
      'nextOffset': null,
    };
  }
}

Widget _host(AppState app, Widget home) => AppStateScope(
  app: app,
  child: MaterialApp(theme: buildAppTheme(), home: home),
);

Future<void> _pump(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  test('offPeakCreateSummary：JSON 串/嵌套/平铺/缺 id 回退', () {
 // 官方语义：output 可为 JSON 字符串；{task:{…}} 或平铺。
    final json = jsonEncode({
      'task': {
        'offPeakTaskId': 'op-1',
        'title': '整理收件箱',
        'queuePosition': 2,
      },
    });
    final s1 = offPeakCreateSummary({
      'toolName': 'OffPeakCreate',
      'output': json,
    });
    expect(s1?.offPeakTaskId, 'op-1');
    expect(s1?.title, '整理收件箱');
    expect(s1?.queuePosition, 2);
    final s2 = offPeakCreateSummary({
      'output': {'offPeakTaskId': 'op-2'},
    });
    expect(s2?.offPeakTaskId, 'op-2');
    expect(s2?.queuePosition, isNull);
 // 缺 id=无效，回退普通工具行。
    expect(offPeakCreateSummary({'output': {'title': 'x'}}), isNull);
    expect(offPeakCreateSummary({'output': 'not-json'}), isNull);
    expect(offPeakCreateSummary(const {}), isNull);
  });

  testWidgets('review-fix-1 销账：目录空态呈现（empty-error 账实一致）', (tester) async {
    final app = _WfApp(
      runsResult: const {'runs': []},
      detailResult: const {'events': [], 'artifacts': []},
      artifactText: '',
    );
 // 直接泵目录页（菜单入口旅程已由入口用例覆盖；此处锁空/错状态本体）。
    await _pump(tester, _host(app, const WorkflowRunsPage(sessionId: 's1')));
    expect(find.textContaining(tr('本会话没有工作流运行')), findsOneWidget,
        reason: '空态文案（此前 ui-coverage 声称覆盖但零断言）');
  });

  testWidgets('review-fix-1 销账：目录加载失败可重试（empty-error 账实一致）', (tester) async {
    final app = _WfApp(
      runsResult: const {'runs': []},
      detailResult: const {'events': [], 'artifacts': []},
      artifactText: '',
    );
    app.throwRuns = true;
 // 直接泵目录页（菜单入口旅程已由入口用例覆盖；此处锁空/错状态本体）。
    await _pump(tester, _host(app, const WorkflowRunsPage(sessionId: 's1')));
    expect(find.textContaining(tr('加载失败')), findsOneWidget,
        reason: '错误态呈现（此前零断言）');
    expect(find.text(tr('重试')), findsOneWidget, reason: '失败可重试');
  });

  testWidgets('旅程：闲时任务卡渲染 + 加号面板工作流入口', (tester) async {
    final app = _WfApp(
      runsResult: const {'runs': []},
      detailResult: const {},
      artifactText: 'x',
    );
 // 会话行里放一个 OffPeakCreate 工具行（输出=JSON 串）。
    await _pump(
      tester,
      _host(
        app,
        const ConversationPage(sessionId: 's1', title: '工作流测试'),
      ),
    );
 // 直接单测卡片渲染（会话 fixture 注入工具行走缓存行链路较重，
 // 卡片本体为纯函数+静态 UI，这里钉 UI 形态）。
    await tester.pumpWidget(
      _host(
        app,
        Scaffold(
          body: OffPeakTaskCard(
            row: {
              'toolName': 'OffPeakCreate',
              'output': jsonEncode({
                'task': {
                  'offPeakTaskId': 'op-1',
                  'title': '整理收件箱',
                  'queuePosition': 3,
                },
              }),
            },
          ),
        ),
      ),
    );
    expect(find.text('整理收件箱'), findsOneWidget);
    expect(find.textContaining('已加入闲时队列（第 3 位）'), findsOneWidget);
    expect(find.textContaining('运行在当前会话'), findsOneWidget);

 // 入口在任务菜单（entry-polish-1 方案 A：加号面板回归纯"添加"）。
    await _pump(
      tester,
      _host(
        app,
        const ConversationPage(sessionId: 's1', title: '工作流测试'),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('task-menu')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('工作流运行'), findsOneWidget);
 // 面板不再有查看型入口（工作流/用量详情都不在加号面板）。
    await tester.tapAt(const Offset(200, 40)); // 关菜单
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('add-trigger')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('工作流运行'), findsNothing);
    expect(find.text('用量详情'), findsNothing);
  });

  testWidgets('旅程：run 目录 → 详情（事件+产物）→ 文本产物预览', (tester) async {
    final app = _WfApp(
      runsResult: const {
        'runs': [
          {
            'runId': 'run-abc123def456',
            'label': '每日简报',
            'status': 'completed',
            'updatedAt': 1,
          },
        ],
      },
      detailResult: const {
        'events': [
          {'sequence': 2, 'type': 'node.completed', 'payload': {}},
          {'sequence': 1, 'type': 'run.started', 'payload': {}},
        ],
        'artifacts': [
          {'id': 'art-1', 'kind': 'text', 'title': '简报正文', 'version': 2},
        ],
      },
      artifactText: '今日完成 3 项工作',
    );
    await _pump(tester, _host(app, const WorkflowRunsPage(sessionId: 's1')));

    expect(find.text('每日简报'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workflow-run-run-abc123def456')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

 // 详情：事件时间线（倒序首条=#2）+ 产物清单。
    expect(find.textContaining('事件（最新 2 条）'), findsOneWidget);
    expect(find.text('node.completed'), findsOneWidget);
    expect(find.textContaining('简报正文'), findsOneWidget);

 // 点产物 → 分块读取 → 文本预览页。
    await tester.tap(find.byKey(const ValueKey('workflow-artifact-art-1')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('今日完成 3 项工作'), findsOneWidget);
  });
}
