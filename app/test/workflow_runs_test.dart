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

  /// 快照 workflowRuns 投影（唯一携带 lastEventSequence 的源——官方
  /// run 目录 schema 没有该字段）。
  final ConversationState projectionState = ConversationState();

  /// 事件查询实参（断言「最新一页」反推）。
  final eventCalls = <int?>[];

  /// 事件分页脚本（call 次数, afterSequence）→ 页；null=按 detailResult
  /// 返回单页（hasMore 缺省 false）。
  Map<String, dynamic> Function(int call, int? afterSequence)? eventPageBuilder;

  void seedProjection(List<Map<String, dynamic>> runs) {
    projectionState.snapshot = {
      'workflowRuns': {'revision': 1, 'runs': runs},
    };
  }

  @override
  Map<String, ConversationState> get conversationStates => {
        's1': projectionState,
      };

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
  /// ：注入加载失败（empty-error 销账用例）。
  bool throwRuns = false;
  @override
  Future<dynamic> workflowRuns(String sessionId, {int? limit}) async {
    if (throwRuns) throw StateError('rpc down');
    return runsResult;
  }
  @override
  Future<dynamic> workflowRunEvents(String sessionId, String runId,
      {int? afterSequence, int? limit}) async {
    eventCalls.add(afterSequence);
    final builder = eventPageBuilder;
    if (builder != null) return builder(eventCalls.length, afterSequence);
    return {
      'events': detailResult['events'] ?? const [],
      'hasMore': detailResult['hasMore'] ?? false,
    };
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
      // 官方 run 目录 schema（transport.ts 706-749，.strict()）：
      // 无 lastEventSequence——投影才是最后事件序号的权威源。
      runsResult: const {
        'runs': [
          {
            'runId': 'run-abc123def456',
            'toolCallId': 'tc-abc',
            'label': '每日简报',
            'status': 'completed',
            'updatedAt': 1,
            'resumable': false,
          },
        ],
      },
      // 事件官方升序（journal 追加序）；渲染层 reversed=最新在前。
      detailResult: const {
        'events': [
          {'sequence': 1, 'type': 'run.started', 'payload': {}},
          {'sequence': 2, 'type': 'node.completed', 'payload': {}},
        ],
        'hasMore': false,
        'artifacts': [
          {
            'id': 'art-1',
            'kind': 'file',
            'title': '简报正文',
            'version': 2,
            'versions': [
              {'version': 2, 'publishedAt': 2},
            ],
            'itemCount': 0,
          },
          {
            'id': 'art-2',
            'kind': 'markdown',
            'title': '简报摘要',
            'version': 1,
            'versions': [
              {'version': 1, 'publishedAt': 1},
            ],
            'itemCount': 0,
          },
        ],
      },
      artifactText: '今日完成 3 项工作',
    );
    app.seedProjection(const [
      {
        'runId': 'run-abc123def456',
        'toolCallId': 'tc-abc',
        'status': 'completed',
        'lastEventSequence': 1200,
      },
    ]);
    await _pump(tester, _host(app, const WorkflowRunsPage(sessionId: 's1')));

    expect(find.text('每日简报'), findsOneWidget);
    expect(find.text('已完成'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('workflow-run-run-abc123def456')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 目录入口按投影联接反推最新页：afterSequence = 1200-500。
    expect(app.eventCalls, [700],
        reason: '官方目录无 lastEventSequence，必须走投影联接（红=旧实现恒 null 从头取）');
    // 详情：追平后标题诚实（复用可翻译的最新 N 条形态）+ 事件倒序
    // 首条=#2 + 产物清单。
    expect(find.text('事件（最新 2 条）'), findsOneWidget);
    expect(find.text('node.completed'), findsOneWidget);
    // 官方升序夹具 + reversed 渲染：最新事件在上。
    final newestY = tester.getTopLeft(find.text('#2')).dy;
    final oldestY = tester.getTopLeft(find.text('#1')).dy;
    expect(newestY, lessThan(oldestY),
        reason: '事件区必须「最新在前」（降序夹具此前掩盖了 reversed 语义）');
    expect(find.textContaining('简报正文'), findsOneWidget);
    expect(find.textContaining('简报摘要'), findsOneWidget);
    // （视觉审查 1109）：产物卡此前零间距叠放+行高 39.7——两张卡
    // 像一整块且低于 44 触控/可读下限。修=相邻 6dp 间距+行高 ≥44。
    final cardA = tester.getRect(
      find.byKey(const ValueKey('workflow-artifact-art-1')),
    );
    final cardB = tester.getRect(
      find.byKey(const ValueKey('workflow-artifact-art-2')),
    );
    expect(cardB.top - cardA.bottom, greaterThanOrEqualTo(6),
        reason: '相邻产物卡垂直间距 ≥6dp（修复前=0）');
    expect(cardA.height, greaterThanOrEqualTo(44),
        reason: '产物卡行高 ≥44（修复前 39.7）');
    expect(cardB.height, greaterThanOrEqualTo(44));

    // 点产物 → 分块读取 → 文本预览页。
    await tester.tap(find.byKey(const ValueKey('workflow-artifact-art-1')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('今日完成 3 项工作'), findsOneWidget);
  });

  // 视觉补跑必修（Visual B 审查实测 87dp 死区）：
  // run 行状态/时间必须贴卡片右缘——旧实现 Expanded+Flexible 双分，
  // 状态只画半行宽的一小段、剩余空间全落行尾（时间不靠右+长标题提前
  // 省略）。红=修复前 card.right - time.right ≈ 99dp（87 死区+12 内边距）。
  testWidgets('视觉：run 行状态/时间贴卡片右缘（红=右侧 87dp 死区）',
      (tester) async {
    tester.view.physicalSize = const Size(375, 806);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final app = _WfApp(
      runsResult: const {
        'runs': [
          {
            'runId': 'run-align',
            'toolCallId': 'tc-align',
            'label': '每日简报',
            'status': 'completed',
            'updatedAt': 1,
            'resumable': false,
          },
        ],
      },
      detailResult: const {'events': [], 'artifacts': []},
      artifactText: '',
    );
    app.seedProjection(const [
      {'runId': 'run-align', 'toolCallId': 'tc-align', 'status': 'completed'},
    ]);
    await _pump(tester, _host(app, const WorkflowRunsPage(sessionId: 's1')));
    expect(find.text('每日简报'), findsOneWidget);
    final card =
        tester.getRect(find.byKey(const ValueKey('workflow-run-run-align')));
    final time = tester.getRect(find.textContaining('天前'));
    expect(card.right - time.right, lessThan(20),
        reason: '时间贴卡片右缘（12 内边距；修复前≈99dp=87 死区+内边距）');
    // 状态紧跟时间左侧，同簇右对齐（不再各自参差）。
    final status = tester.getRect(find.text('已完成'));
    expect(time.left - status.right, lessThan(10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('目录入口 + 投影联接：hasMore 未追平 → 加载更多在场且继续翻页',
      (tester) async {
    final app = _WfApp(
      runsResult: const {
        'runs': [
          {'runId': 'run-more', 'toolCallId': 'tc-more', 'status': 'running'},
        ],
      },
      detailResult: const {'events': [], 'artifacts': []},
      artifactText: '',
    );
    app.seedProjection(const [
      {
        'runId': 'run-more',
        'toolCallId': 'tc-more',
        'status': 'running',
        'lastEventSequence': 1200,
      },
    ]);
    // 每页前进 100 个序号且恒 hasMore=true：首载追平到 #1200 时
    // hasMore 仍真（自动翻页上限外还有更晚事件）。
    app.eventPageBuilder = (call, afterSequence) {
      final base = afterSequence ?? 0;
      return {
        'events': [
          {'sequence': base + 1, 'type': 'node.started', 'payload': {}},
          {'sequence': base + 100, 'type': 'node.completed', 'payload': {}},
        ],
        'hasMore': true,
      };
    };
    await _pump(tester, _host(app, const WorkflowRunsPage(sessionId: 's1')));
    await tester.tap(find.byKey(const ValueKey('workflow-run-run-more')));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // 首载从 700 起逐页追到 >=1200（5 页），未到顶 → 诚实标题+按钮。
    expect(app.eventCalls.first, 700);
    expect(app.eventCalls.length, 5,
        reason: '追平即停（700→800→900→1000→1100→末页 1200）');
    expect(find.textContaining('已加载至 #1200'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('workflow-events-load-more')),
      findsOneWidget,
      reason: 'hasMore 未排空必须给「加载更多」（红=旧实现标最新且无出路）',
    );

    await tester.tap(find.byKey(const ValueKey('workflow-events-load-more')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.eventCalls.last, 1200, reason: '手动续页从已加载末条之后继续');
    expect(find.text('#1300'), findsOneWidget,
        reason: '续页事件已追加渲染（精确匹配行文本，标题的 #1300 不算）');
  });

  testWidgets('无投影序号：官方语义从头取，标题只敢称「最早」', (tester) async {
    final app = _WfApp(
      runsResult: const {'runs': []},
      detailResult: const {
        'events': [
          {'sequence': 1, 'type': 'run.started', 'payload': {}},
          {'sequence': 2, 'type': 'node.completed', 'payload': {}},
        ],
        'hasMore': false,
        'artifacts': [],
      },
      artifactText: '',
    );
    await _pump(
      tester,
      _host(
        app,
        const WorkflowRunDetailPage(
          sessionId: 's1',
          runId: 'run-no-projection',
          title: '无投影',
        ),
      ),
    );
    expect(app.eventCalls, [null], reason: '无序号=不传 afterSequence（官方从头取）');
    expect(find.text('最早 2 条'), findsOneWidget,
        reason: '从头取的页不许标「最新」（旧实现标题撒谎的红绿）');
  });
}
