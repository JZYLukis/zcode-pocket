import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_pocket/core/theme.dart';
import 'package:zcode_pocket/state/app_state.dart';
import 'package:zcode_pocket/state/app_state_scope.dart';
import 'package:zcode_pocket/state/cache_policy.dart';
import 'package:zcode_pocket/transport/channel_client.dart';
import 'package:zcode_pocket/transport/companion_client.dart';
import 'package:zcode_pocket/transport/conversation.dart';
import 'package:zcode_pocket/transport/rpc_frame_transport.dart';
import 'package:zcode_pocket/ui/conversation_page.dart';

/// 会话压缩命令（compact-command-1，2026-10-30 用户反馈「手机端发起
/// 上下文压缩没有任何 UI 提示」）：根因=官方 compact 是专用命令信封
/// （command.ts:165-167，空载荷/FIFO/幂等），我们此前把 /compact 当纯
/// 文本 sendText 发送=CLI 不执行压缩。锁：①/compact 精确拦截走 compact
/// 命令 ②用量详情卡「压缩上下文」动作（官方 contextUsage 压缩按钮
/// 对位）③普通文本不受影响。

class _CompactBridge implements BridgeSession {
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
  String? get workspaceKey => 'ws-compact';
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

class _CompactApp extends AppState {
  final List<String> compactCalls = [];
  final List<String> sentTexts = [];

  @override
  LinkPhase get phase => LinkPhase.online;
  @override
  BridgeSession? get bridge => _CompactBridge();
  @override
  Map<String, dynamic>? get activeWorkspace => const {
    'workspaceIdentity': 'ws-compact',
    'workspacePath': '/example-workspace',
  };
  @override
  Future<SessionCacheEntry?> readSessionCache(String id) async =>
      SessionCacheEntry(
        deviceSid: 'd1',
        sessionId: id,
        rows: const [
          {'rowId': 1, 'kind': 'userInput', 'text': 'hi'},
        ],
        logEpoch: 'e1',
        lastSeq: 1,
        firstRowId: 1,
        totalCount: 1,
        snapshotControl: {
          'title': '压缩测试',
          'control': {'phase': 'completed'},
          'usage': {
            'contextWindow': {'usedTokens': 500000, 'maxTokens': 1000000},
          },
        },
        savedAt: DateTime.now().millisecondsSinceEpoch,
        byteSize: 1024,
      );
  @override
  Future<dynamic> sendCompact(String sessionId) async {
    compactCalls.add(sessionId);
    return const {'status': 'accepted'};
  }

  @override
  Future<dynamic> sendText(
    String sessionId,
    String text, {
    Map<String, dynamic>? modelSelection,
    String? mode,
    bool? planEnabled,
    List<Map<String, dynamic>>? attachments,
    String? heldQueueDisposition,
    List<String>? expectedHeldQueueItemIds,
    String? replayCommandId,
  }) async {
    sentTexts.add(text);
    return const {'status': 'accepted'};
  }
}

Future<void> _pump(WidgetTester tester, AppState app) async {
  await tester.pumpWidget(
    AppStateScope(
      app: app,
      child: MaterialApp(
        theme: buildAppTheme(),
        home: const ConversationPage(sessionId: 's1', title: '压缩测试'),
      ),
    ),
  );
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('输入 /compact 发送 → 走 compact 命令而非文本', (tester) async {
    final app = _CompactApp();
    await _pump(tester, app);

    await tester.enterText(find.byKey(const ValueKey('chat-input')), '/compact');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send-button')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.compactCalls, ['s1'], reason: '官方 compact 命令信封（空载荷）');
    expect(app.sentTexts, isEmpty, reason: '/compact 不得当纯文本发送（根因）');
  });

  testWidgets('普通文本与带参斜杠不受拦截；用量详情卡出压缩动作', (tester) async {
    final app = _CompactApp();
    await _pump(tester, app);

    await tester.enterText(find.byKey(const ValueKey('chat-input')), '/compact 全部');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('send-button')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.sentTexts, ['/compact 全部'], reason: '带参形态维持文本由 CLI 解释');
    expect(app.compactCalls, isEmpty);

    // 状态环点开用量详情卡 → 「压缩上下文」动作行 → compact 命令。
    await tester.tap(find.byKey(const ValueKey('status-dot')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.byKey(const ValueKey('compact-context')));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(app.compactCalls, ['s1'], reason: '官方 contextUsage 压缩按钮对位');
  });
}
